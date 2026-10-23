package com.rhymeai.app

import android.content.Context
import android.os.SystemClock
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.sync.BackupManifest
import com.rhymeai.app.data.sync.BackupStatus
import com.rhymeai.app.data.sync.DriveAuthorization
import com.rhymeai.app.data.sync.DriveAuthorizer
import com.rhymeai.app.data.sync.DriveClient
import com.rhymeai.app.data.sync.DriveFileMetadata
import com.rhymeai.app.data.sync.SyncBlob
import com.rhymeai.app.ui.components.BackupSection
import com.rhymeai.app.ui.components.BackupSectionActions
import com.rhymeai.app.ui.components.BackupSectionState
import com.rhymeai.app.ui.theme.RhymeAITheme
import com.rhymeai.app.data.sync.backupStatusLine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test

/** Settings Backup rows rendered for each status, with no Drive involved. */
class BackupSectionUiTest {
    @get:Rule val compose = createComposeRule()

    private val state = mutableStateOf(BackupSectionState())
    private var disconnects = 0

    private fun show() {
        compose.setContent {
            RhymeAITheme {
                val current = state.value
                BackupSection(
                    state = current,
                    actions = BackupSectionActions(onDisconnect = { disconnects++ }),
                    statusLine = backupStatusLine(current.status, 10 * 60_000L),
                    subtleColor = androidx.compose.ui.graphics.Color.Gray,
                    textFieldColors = OutlinedTextFieldDefaults.colors()
                )
            }
        }
    }

    @Test fun rowsFollowTheStatus() {
        show()
        compose.onNodeWithText("Not connected").assertIsDisplayed()
        compose.onNodeWithText("Connect Google Drive").assertIsEnabled()
        compose.onNodeWithText("Back up now").assertIsNotEnabled()
        compose.onNodeWithText("Restore from backup").assertIsNotEnabled()
        compose.onNodeWithText("Export all songs…").assertIsEnabled()
        compose.onNodeWithText("Import from file…").assertIsEnabled()
        compose.onNodeWithText(
            "Songs, trash and recordings are backed up to your Google Drive's private app storage. API keys are never included."
        ).assertIsDisplayed()

        compose.runOnIdle { state.value = BackupSectionState(status = BackupStatus.Connected(8 * 60_000L), legacyBackupPresent = true) }
        compose.onNodeWithText("Last backed up 2 min ago · Google Drive").assertIsDisplayed()
        compose.onNodeWithText("Back up now").assertIsEnabled()
        compose.onNodeWithText("Migrate older encrypted backup…").assertIsDisplayed()
        compose.onNodeWithText("Disconnect").performClick()
        compose.runOnIdle { assertEquals(1, disconnects) }

        compose.runOnIdle { state.value = BackupSectionState(status = BackupStatus.Pending) }
        compose.onNodeWithText("Waiting to back up · Google Drive").assertIsDisplayed()

        compose.runOnIdle { state.value = BackupSectionState(status = BackupStatus.BackingUp) }
        compose.onNodeWithText("Backing up…").assertIsDisplayed()
        compose.onNodeWithTag("backup_restore").assertIsNotEnabled()

        compose.runOnIdle {
            state.value = BackupSectionState(status = BackupStatus.Failed(BackupManifest.DAMAGED_MESSAGE, null))
        }
        compose.onNodeWithText("Backup file is damaged; it was not merged.").assertIsDisplayed()
        compose.onNodeWithText("Retry").assertIsEnabled()
    }
}

/** The real MainActivity and view model against an in-memory Drive (isolated QA app only). */
class BackupFlowInstrumentedTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val drive = MemoryDrive()
    private lateinit var repo: ProjectRepository
    private var savedProjects: List<SongProject> = emptyList()
    private var savedTrash: List<TrashedSongProject> = emptyList()
    private var scenario: ActivityScenario<MainActivity>? = null

    private fun launchConnectedWithEmptyLibrary(): MainViewModel {
        check(context.packageName == "com.rhymeai.app.motionqa") { "Backup fixtures require the owned isolated QA app." }
        repo = ProjectRepository(context)
        runBlocking {
            savedProjects = repo.projectsFlow.first()
            savedTrash = repo.trashedProjectsFlow.first()
            repo.saveProjects(emptyList())
            repo.saveTrashedProjects(emptyList())
        }
        drive.put(
            BackupManifest.FILE_NAME,
            BackupManifest.encode(
                SyncBlob(projects = listOf(SongProject(id = "drive-a", title = "From Drive A"), SongProject(id = "drive-b", title = "From Drive B"))),
                0L, "other-device"
            )
        )
        BackupTestHooks.driveClient = drive
        BackupTestHooks.authorizer = object : DriveAuthorizer {
            override suspend fun authorize() = DriveAuthorization.Granted("token")
        }
        prefs().edit().clear().putBoolean("drive_connected", true).commit()
        lateinit var vm: MainViewModel
        scenario = ActivityScenario.launch(MainActivity::class.java).also { s ->
            s.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
        }
        return vm
    }

    private fun prefs() = context.getSharedPreferences("rhymeai_backup", Context.MODE_PRIVATE)

    @After fun restore() {
        scenario?.close()
        BackupTestHooks.driveClient = null
        BackupTestHooks.authorizer = null
        prefs().edit().clear().commit()
        if (::repo.isInitialized) runBlocking {
            repo.saveProjects(savedProjects)
            repo.saveTrashedProjects(savedTrash)
        }
    }

    @Test fun firstRunSheetOffersTheBackupAndRestoreMergesIt() {
        launchConnectedWithEmptyLibrary()
        waitForText("Restore your songs?")
        compose.onNodeWithText("We found 2 songs and 0 recordings in your Google Drive backup.").assertIsDisplayed()
        compose.onNodeWithText("Not now").assertIsDisplayed()
        compose.onNodeWithText("Restore").performClick()

        waitUntil { runBlocking { repo.projectsFlow.first().map { it.id }.toSet() } == setOf("drive-a", "drive-b") }
        assertEquals(0, compose.onAllNodesWithText("Restore your songs?").fetchSemanticsNodes().size)
    }

    @Test fun disconnectRevokesAndClearsBackupState() {
        val vm = launchConnectedWithEmptyLibrary()
        waitForText("Restore your songs?")
        compose.onNodeWithText("Not now").performClick()
        waitUntil { runBlocking { repo.projectsFlow.first().isEmpty() } }

        instrumentation.runOnMainSync { vm.disconnectDrive() }

        waitUntil { vm.backupNotice?.startsWith("Disconnected from Google Drive") == true }
        assertEquals(BackupStatus.NotConnected, vm.backupStatus)
        assertFalse(prefs().getBoolean("drive_connected", false))
        assertEquals(listOf("token"), drive.revoked)
        // Disconnected: a change no longer schedules a backup.
        instrumentation.runOnMainSync { vm.scheduleAutoBackup() }
        assertEquals(BackupStatus.NotConnected, vm.backupStatus)
    }

    @Test fun tombstonesAndRecordingChangesQueueTheDebouncedBackup() {
        val vm = launchConnectedWithEmptyLibrary()
        waitForText("Restore your songs?")
        compose.onNodeWithText("Not now").performClick()
        waitUntil { vm.backupStatus is BackupStatus.Connected }

        // A recording tombstone alone changes no song list.
        runBlocking {
            repo.recordRecordingDeletion("drive-a", "take.m4a", java.util.UUID.randomUUID().toString(), System.currentTimeMillis())
        }
        waitUntil { vm.backupStatus == BackupStatus.Pending }

        instrumentation.runOnMainSync { vm.backUpNow() }
        waitUntil { vm.backupStatus is BackupStatus.Connected }

        // So does a recording saved, renamed or deleted on disk.
        val memoDir = com.rhymeai.app.data.recording.RecordingFiles.memoDirectory(context.filesDir, "drive-a").also { it.mkdirs() }
        java.io.File(memoDir, "trigger.m4a").writeBytes(byteArrayOf(1, 2, 3))
        runBlocking {
            val memo = vm.voiceMemoService.memosForProject("drive-a").single { it.file.name == "trigger.m4a" }
            vm.voiceMemoService.deleteMemo(memo)
        }
        waitUntil { vm.backupStatus == BackupStatus.Pending }
    }

    @Test fun importThatAddsOnlyRecordingsQueuesTheDebouncedBackup() {
        val vm = launchConnectedWithEmptyLibrary()
        waitForText("Restore your songs?")
        compose.onNodeWithText("Not now").performClick()
        waitUntil { vm.backupStatus is BackupStatus.Connected }

        val audio = byteArrayOf(7, 7, 7)
        val source = java.io.File(context.cacheDir, "import-source.m4a").apply { writeBytes(audio) }
        val entry = com.rhymeai.app.data.sync.RecordingManifestEntry(
            "solo", "imported.m4a", sizeBytes = 3L, modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(audio)
        )
        val zip = java.io.File(context.cacheDir, "recording-only.zip")
        zip.outputStream().use {
            com.rhymeai.app.data.sync.BackupArchive.write(
                it, SyncBlob(), listOf(com.rhymeai.app.data.sync.LocalRecordingFile(entry, source)), 0L, "test"
            )
        }
        try {
            instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(zip)) }
            waitUntil({ "notice was ${vm.backupNotice}" }) { vm.backupNotice == "Imported 0 songs and added 1 recording." }
            waitUntil { vm.backupStatus == BackupStatus.Pending }
        } finally {
            zip.delete()
            source.delete()
            com.rhymeai.app.data.recording.RecordingFiles.memoDirectory(context.filesDir, "solo").deleteRecursively()
        }
    }

    @Test fun exportLeavesOutAndReportsARecordingStillAwaitingItsNewName() {
        val vm = launchConnectedWithEmptyLibrary()
        val dir = com.rhymeai.app.data.recording.RecordingFiles.memoDirectory(context.filesDir, "export-legacy").also { it.mkdirs() }
        val legacy = java.io.File(dir, "take.m4a").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        // Other bytes hold its id name, so no launch check can rename it while this runs.
        val id = com.rhymeai.app.data.sync.RecordingManifestEntry.legacyRecordingId("export-legacy", "take.m4a", BackupManifest.sha256Hex(legacy.readBytes()))
        java.io.File(dir, "$id.m4a").writeBytes(byteArrayOf(9, 9))
        val zip = java.io.File(context.cacheDir, "export-legacy.zip")
        try {
            instrumentation.runOnMainSync { vm.exportBackup(android.net.Uri.fromFile(zip)) }
            waitUntil({ "notice was ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Exported") == true }
            assertTrue(vm.backupNotice!!, vm.backupNotice!!.contains("1 recording with an old file name left out."))
            assertTrue(legacy.exists())
        } finally {
            zip.delete()
            dir.deleteRecursively()
        }
    }

    @Test fun aPreExistingMemoKeepsItsStampedTimeAcrossRestartAndRename() {
        launchConnectedWithEmptyLibrary()
        val dir = com.rhymeai.app.data.recording.RecordingFiles.memoDirectory(context.filesDir, "stamped").also { it.mkdirs() }
        java.io.File(dir, "old take.m4a").apply { writeBytes(byteArrayOf(4, 5, 6)); setLastModified(1_000_000L) }
        try {
            val listed = runBlocking { com.rhymeai.app.data.sync.snapshotLocalRecordings(repo, context.filesDir, emptySet()) }
                .single { it.entry.projectId == "stamped" }
            val stamped = listed.entry
            // A36: adoption named the file by its id; its old name is the display name.
            val memo = listed.file
            assertEquals("${stamped.id}.m4a", memo.name)
            assertEquals("old take.m4a", stamped.fileName)
            assertEquals(1_000_000L, stamped.uploadedAt)
            fun record(r: ProjectRepository) = runBlocking { r.recordingRecords() }.single { it.id == stamped.id }

            // The file time changes, the activity and view model are recreated, and a fresh
            // repository reads the stored record: the stamp does not move.
            memo.setLastModified(2_000_000L)
            scenario?.close()
            lateinit var vm: MainViewModel
            scenario = ActivityScenario.launch(MainActivity::class.java).also { s ->
                s.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
            }
            val reopened = ProjectRepository(context)
            runBlocking { com.rhymeai.app.data.sync.snapshotLocalRecordings(reopened, context.filesDir, emptySet()) }
            assertEquals(1_000_000L, record(reopened).uploadedAt)

            // A rename through the app changes the record only and keeps its time.
            runBlocking {
                val live = vm.voiceMemoService.memosForProject("stamped").single()
                checkNotNull(vm.voiceMemoService.renameMemo(live, "renamed take"))
            }
            // Same id, time and file; only the display name changed.
            assertEquals(1_000_000L, record(reopened).uploadedAt)
            assertEquals("renamed take.m4a", record(reopened).displayName)
            assertEquals(listOf(memo.name), dir.list()!!.toList())
        } finally {
            dir.deleteRecursively()
        }
    }

    private fun waitForText(text: String) =
        compose.waitUntil(10_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }

    private fun waitUntil(detail: () -> String = { "" }, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return
            SystemClock.sleep(25)
        }
        fail("Backup fixture did not reach the expected state ${detail()}")
    }

    private class MemoryDrive : DriveClient {
        private val files = LinkedHashMap<String, Pair<String, ByteArray>>()
        private var nextId = 0
        val revoked = mutableListOf<String>()

        fun put(name: String, bytes: ByteArray) {
            val id = files.entries.firstOrNull { it.value.first == name }?.key ?: "id-${nextId++}"
            files[id] = name to bytes
        }

        override suspend fun findFileByName(accessToken: String, name: String) =
            files.entries.firstOrNull { it.value.first == name }?.let { DriveFileMetadata(it.key, name, version = it.value.second.size.toString()) }
        override suspend fun listFilesByNamePrefix(accessToken: String, namePrefix: String) =
            files.filter { it.value.first.startsWith(namePrefix) }.map { DriveFileMetadata(it.key, it.value.first) }
        override suspend fun downloadFile(accessToken: String, fileId: String, maxBytes: Long) = files.getValue(fileId).second
        override suspend fun uploadNewFile(
            accessToken: String, name: String, mimeType: String, content: ByteArray, appProperties: Map<String, String>
        ): String = "id-${nextId++}".also { files[it] = name to content }
        override suspend fun updateFile(
            accessToken: String, fileId: String, mimeType: String, content: ByteArray, appProperties: Map<String, String>
        ) {
            files[fileId] = files.getValue(fileId).first to content
        }
        override suspend fun deleteFile(accessToken: String, fileId: String) {
            files.remove(fileId)
        }
        override suspend fun revokeToken(token: String) {
            revoked += token
        }
    }
}
