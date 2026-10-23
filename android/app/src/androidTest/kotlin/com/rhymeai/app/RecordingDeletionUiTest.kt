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
import org.junit.Assert.assertEquals
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

    private val drive = InMemoryDrive()

    private fun backupPrefs() = InstrumentationRegistry.getInstrumentation().targetContext
        .getSharedPreferences("rhymeai_backup", android.content.Context.MODE_PRIVATE)

    @Before fun openEditor() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.grantRuntimePermission(instrumentation.targetContext.packageName, Manifest.permission.RECORD_AUDIO)
        check(instrumentation.targetContext.packageName == "com.rhymeai.app.motionqa") { "Restore fixtures require the owned isolated QA app." }
        // The app's real Restore runs against an in-memory Drive (read when the view model is built).
        BackupTestHooks.driveClient = drive
        BackupTestHooks.authorizer = object : com.rhymeai.app.data.sync.DriveAuthorizer {
            override suspend fun authorize() = com.rhymeai.app.data.sync.DriveAuthorization.Granted("token")
        }
        backupPrefs().edit().clear().putBoolean("drive_connected", true).commit()
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
        BackupTestHooks.driveClient = null
        BackupTestHooks.authorizer = null
        backupPrefs().edit().clear().commit()
    }

    @Test fun aDeletionThatWinsWhileTheSheetIsOpenHidesStopsAndBlocksPlayback() {
        val service = viewModel.voiceMemoService
        val catalog = requireNotNull(service.catalog)
        TestRecordings.recordFinalizedM4a(
            InstrumentationRegistry.getInstrumentation().targetContext,
            File(RecordingFiles.memoDirectory(filesDir, projectId), "Take.m4a")
        )
        // Adoption gives the file its id name (A36); "Take.m4a" becomes its display name.
        val (memo, record) = runBlocking {
            val listed = RecordingTransitions.snapshot(catalog, filesDir, emptySet()).single { it.entry.projectId == projectId }
            listed.file to catalog.recordingRecords().single { it.id == listed.entry.id }
        }
        assertEquals("Take.m4a", record.displayName)

        compose.onNodeWithTag("songActionsMenuButton").performClick()
        compose.onNodeWithTag("songRecordings").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("Rename recording").fetchSemanticsNodes().isNotEmpty() }
        compose.onAllNodesWithContentDescription("Play").onFirst().performClick()
        compose.waitUntil(10_000) { service.playingFile?.name == "${record.id}.m4a" }

        // A Restore commits the winning tombstone; its quarantine move has not happened.
        runBlocking { requireNotNull(service.recordingDeletionRecorder)(projectId, record.displayName, record.id, System.currentTimeMillis() + 60_000L) }

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

    @Test fun aRealRestoreLeavesAPlayingTakeAloneAndAQuarantineStopsItFirst() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        try {
            val service = viewModel.voiceMemoService
            val catalog = requireNotNull(service.catalog)
            val dir = RecordingFiles.memoDirectory(filesDir, projectId)
            // Long enough that playback cannot end on its own while Restore runs.
            TestRecordings.recordFinalizedM4a(context, File(dir, "take.m4a"), millis = 12_000L)
            val (x, xId) = runBlocking {
                val listed = RecordingTransitions.snapshot(catalog, filesDir, emptySet()).single { it.entry.projectId == projectId }
                listed.file to listed.entry.id
            }
            // Drive holds an earlier recording Y with the same display name.
            val yBytes = TestRecordings.recordFinalizedM4a(context, File(filesDir, "y-${projectId}.m4a")).readBytes()
            val y = com.rhymeai.app.data.sync.RecordingManifestEntry(
                projectId, "take.m4a", sizeBytes = yBytes.size.toLong(), modifiedAt = 0L,
                sha256 = com.rhymeai.app.data.sync.BackupManifest.sha256Hex(yBytes), uploadedAt = 1_000L,
                id = "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2"
            )
            drive.put(com.rhymeai.app.data.sync.BackupManifest.recordingDriveName(y.id), yBytes)
            drive.put(
                com.rhymeai.app.data.sync.BackupManifest.FILE_NAME,
                com.rhymeai.app.data.sync.BackupManifest.encode(com.rhymeai.app.data.sync.SyncBlob(recordings = listOf(y)), 0L, "other-device")
            )

            // At the move boundary: what was playing just before the hook, and after it.
            val boundary = java.util.Collections.synchronizedList(mutableListOf<Triple<Set<String>, File?, File?>>())
            val hook = requireNotNull(RecordingTransitions.beforeBytesMove)
            RecordingTransitions.beforeBytesMove = { ids ->
                val before = service.playingFile
                hook(ids)
                boundary += Triple(ids, before, service.playingFile)
            }
            compose.runOnIdle { service.play(VoiceMemo(x, "take", 12_000L)) }
            compose.waitUntil(10_000) { service.playingFile == x.canonicalFile || service.playingFile == x }
            compose.runOnIdle { viewModel.restoreFromBackup() }
            val yFile = File(dir, "${y.id}.m4a")
            try {
                compose.waitUntil(30_000) { yFile.exists() && viewModel.backupBusyLabel == null }
            } catch (e: Throwable) {
                throw AssertionError("restore: notice=${viewModel.backupNotice} status=${viewModel.backupStatus} files=${dir.list()?.toList()}", e)
            }
            // A36: Y lands under its own id beside X; nothing of X moved, so X kept playing.
            assertTrue(x.exists())
            assertTrue(boundary.toString(), boundary.none { (ids, _, _) -> xId in ids })
            assertEquals(x.canonicalFile, service.playingFile?.canonicalFile)
            assertEquals(listOf("take.m4a", "take.m4a"), runBlocking { catalog.recordingRecords() }.filter { it.projectId == projectId }.map { it.displayName })

            // A deletion of X arrives through the next Restore.
            val manifest = com.rhymeai.app.data.sync.BackupManifest.decode(requireNotNull(drive.bytes(com.rhymeai.app.data.sync.BackupManifest.FILE_NAME)))
            drive.put(
                com.rhymeai.app.data.sync.BackupManifest.FILE_NAME,
                com.rhymeai.app.data.sync.BackupManifest.encode(
                    manifest.copy(deletions = manifest.deletions + com.rhymeai.app.data.sync.SyncDeletion(
                        projectId, "take.m4a", System.currentTimeMillis() + 60_000L, recordingId = xId
                    )),
                    0L, "other-device"
                )
            )
            compose.runOnIdle { viewModel.restoreFromBackup() }
            compose.waitUntil(30_000) { !x.exists() && viewModel.backupBusyLabel == null }
            // At the quarantine move nothing is playing: the committed tombstone already stopped it
            // (the deletion observer), or the hook did.
            assertTrue(boundary.toString(), boundary.any { (ids, _, after) -> xId in ids && after == null })
            assertTrue(boundary.toString(), boundary.none { (_, before, after) -> before != null && after != null })
            assertNull(service.playingFile)
            assertEquals(listOf("$xId.m4a"), RecordingFiles.quarantineDirectory(filesDir, projectId).walk().filter { it.isFile }.map { it.name }.toList())
            assertTrue(yFile.exists())
        } finally {
            RecordingTransitions.beforeBytesMove = viewModel.voiceMemoService::stopPlayingIds
            RecordingFiles.quarantineDirectory(filesDir, projectId).deleteRecursively()
            File(filesDir, "y-${projectId}.m4a").delete()
        }
    }
}
