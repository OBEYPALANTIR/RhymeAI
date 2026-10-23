package com.rhymeai.app

import android.app.Application
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rhymeai.app.data.recording.RecordingCatalog
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.sync.RecordingRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Metadata write failures reach the user through the real editor and recordings UI (A24). */
@RunWith(AndroidJUnit4::class)
class RecordingFailureUiTest {
    @get:Rule val compose = createEmptyComposeRule()
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var viewModel: MainViewModel
    private var original: RecordingCatalog? = null
    private val failing = FailingCatalog()
    private lateinit var filesDir: File
    private lateinit var projectId: String

    private class FailingCatalog : RecordingCatalog {
        var records = listOf<RecordingRecord>()
        var failWrites = true
        override suspend fun recordingRecords() = records
        override suspend fun updateRecordingRecords(transform: (List<RecordingRecord>) -> List<RecordingRecord>) {
            if (failWrites) throw java.io.IOException("injected metadata write failure")
            records = transform(records)
        }
    }

    @Before fun openEditor() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        compose.onNodeWithText("New Song").performClick()
        scenario.onActivity { viewModel = ViewModelProvider(it)[MainViewModel::class.java] }
        // New Song finishes asynchronously (it clears the current song, then opens the editor);
        // reserving the recording song before that would race it and cancel with "Song changed".
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("songActionsMenuButton").fetchSemanticsNodes().isNotEmpty() }
        projectId = runBlocking(Dispatchers.Main) { viewModel.ensureProjectForRecording() }
        filesDir = viewModel.getApplication<Application>().filesDir
        compose.runOnIdle {
            original = viewModel.voiceMemoService.catalog
            viewModel.voiceMemoService.catalog = failing
        }
    }

    @After fun closeEditor() {
        if (::projectId.isInitialized) {
            compose.runOnIdle { viewModel.voiceMemoService.catalog = original }
            RecordingFiles.memoDirectory(filesDir, projectId).deleteRecursively()
            RecordingFiles.stagingDirectory(filesDir, projectId).deleteRecursively()
        }
        scenario.close()
    }

    /**
     * Steps the Compose clock one frame at a time while polling. With the auto-advancing
     * test clock a snackbar's display delay can elapse between two polls, so the
     * message could come and go unseen.
     */
    private fun awaitManually(what: String, condition: () -> Boolean) {
        compose.mainClock.autoAdvance = false
        val deadline = System.currentTimeMillis() + 10_000
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { "Timed out waiting for $what" }
            compose.mainClock.advanceTimeByFrame()
            Thread.sleep(20)
        }
    }

    private fun waitForText(text: String) =
        awaitManually(text) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }

    @Test fun aTakeThatCannotBeSavedWaitsInTheRecordingsSheetUntilRetrySavesIt() {
        val service = viewModel.voiceMemoService
        val take = File(RecordingFiles.stagingDirectory(filesDir, projectId).apply { mkdirs() }, "1700000000000.m4a")
            .apply { writeBytes(ByteArray(64) { it.toByte() }) }
        TestRecordings.startMarker(take, "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b")
        compose.runOnIdle { service.seedRecordingForTesting(take) }

        compose.mainClock.autoAdvance = false
        compose.onAllNodesWithContentDescription("Stop recording").onFirst().performClick()
        waitForText("Couldn't save the recording. Free up storage, then tap Retry.")
        compose.mainClock.autoAdvance = true

        assertTrue(take.exists())
        assertTrue(RecordingFiles.memoDirectory(filesDir, projectId).listFiles().orEmpty().isEmpty())
        assertFalse(service.isRecording)

        // The recordings sheet lists the waiting take and saves it on Retry.
        failing.failWrites = false
        compose.onNodeWithTag("songActionsMenuButton").performClick()
        compose.onNodeWithTag("songRecordings").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("1 recording waiting to be saved").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("retryWaitingTakes").performClick()
        compose.waitUntil(10_000) { !take.exists() && runBlocking { service.waitingTakes(projectId) }.isEmpty() }
        assertEquals(listOf("1700000000000.m4a"), RecordingFiles.memoDirectory(filesDir, projectId).list().orEmpty().toList())
        assertEquals("1700000000000.m4a", failing.records.single().fileName)
        compose.waitUntil(10_000) { compose.onAllNodesWithText("1 recording waiting to be saved").fetchSemanticsNodes().isEmpty() }
    }

    @Test fun aRenameWhoseRecordCannotBeWrittenShowsAnErrorAndKeepsTheName() {
        val take = File(RecordingFiles.memoDirectory(filesDir, projectId).apply { mkdirs() }, "Take.m4a")
            .apply { writeBytes(ByteArray(64) { it.toByte() }) }
        compose.onNodeWithTag("songActionsMenuButton").performClick()
        compose.onNodeWithTag("songRecordings").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("Rename recording").fetchSemanticsNodes().isNotEmpty() }

        compose.onNodeWithContentDescription("Rename recording").performClick()
        // The dialog composes on the running clock; pause it only once the confirm button is there.
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("renameRecordingConfirm").fetchSemanticsNodes().isNotEmpty() }
        compose.mainClock.autoAdvance = false
        compose.onNodeWithTag("renameRecordingConfirm").performClick()
        waitForText("Couldn't rename recording. Check free storage, then try again.")
        compose.mainClock.autoAdvance = true

        assertTrue(take.exists())
        assertEquals(listOf("Take.m4a"), RecordingFiles.memoDirectory(filesDir, projectId).list().orEmpty().toList())
        assertNull(failing.records.firstOrNull())
    }
}
