package com.rhymeai.app

import android.Manifest
import android.app.Application
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onFirst
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.recording.RecordingTransitions
import com.rhymeai.app.service.VoiceMemo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * A28: a recording whose deletion wins while the recordings sheet is open (a Restore
 * that committed its tombstone but could not quarantine the bytes) leaves the list,
 * stops playing, and cannot be played again.
 */
@RunWith(AndroidJUnit4::class)
class RecordingDeletionUiTest {
    @get:Rule val compose = createEmptyComposeRule()
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var viewModel: MainViewModel
    private lateinit var filesDir: File
    private lateinit var projectId: String

    @Before fun openEditor() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.grantRuntimePermission(instrumentation.targetContext.packageName, Manifest.permission.RECORD_AUDIO)
        scenario = ActivityScenario.launch(MainActivity::class.java)
        compose.onNodeWithText("New Song").performClick()
        scenario.onActivity { viewModel = ViewModelProvider(it)[MainViewModel::class.java] }
        compose.waitUntil(10_000) { compose.onAllNodesWithTag("songActionsMenuButton").fetchSemanticsNodes().isNotEmpty() }
        projectId = runBlocking(Dispatchers.Main) { viewModel.ensureProjectForRecording() }
        filesDir = viewModel.getApplication<Application>().filesDir
    }

    @After fun closeEditor() {
        if (::projectId.isInitialized) RecordingFiles.memoDirectory(filesDir, projectId).deleteRecursively()
        scenario.close()
    }

    @Test fun aDeletionThatWinsWhileTheSheetIsOpenHidesStopsAndBlocksPlayback() {
        val service = viewModel.voiceMemoService
        val catalog = requireNotNull(service.catalog)
        val memo = TestRecordings.recordFinalizedM4a(
            InstrumentationRegistry.getInstrumentation().targetContext,
            File(RecordingFiles.memoDirectory(filesDir, projectId), "Take.m4a")
        )
        val record = runBlocking {
            RecordingTransitions.snapshot(catalog, filesDir, emptySet())
            catalog.recordingRecords().single { it.path == RecordingTransitions.relativePath(filesDir, memo) }
        }

        compose.onNodeWithTag("songActionsMenuButton").performClick()
        compose.onNodeWithTag("songRecordings").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("Rename recording").fetchSemanticsNodes().isNotEmpty() }
        compose.onAllNodesWithContentDescription("Play").onFirst().performClick()
        compose.waitUntil(10_000) { service.playingFile?.name == "Take.m4a" }

        // A Restore commits the winning tombstone; its quarantine move has not happened.
        runBlocking { requireNotNull(service.recordingDeletionRecorder)(projectId, record.fileName, record.id, System.currentTimeMillis() + 60_000L) }

        compose.waitUntil(10_000) {
            service.playingFile == null &&
                compose.onAllNodesWithContentDescription("Rename recording").fetchSemanticsNodes().isEmpty()
        }
        assertTrue(memo.exists())

        // Playback refuses it even when asked directly.
        compose.runOnIdle { service.play(VoiceMemo(memo, "Take", 1_000L)) }
        Thread.sleep(1_000)
        compose.runOnIdle { assertNull(service.playingFile) }
    }
}
