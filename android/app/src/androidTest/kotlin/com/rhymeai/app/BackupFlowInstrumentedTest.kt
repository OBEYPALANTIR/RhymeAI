package com.rhymeai.app

import android.content.Context
import android.os.SystemClock
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.datastore.preferences.core.edit
import com.rhymeai.app.data.repository.dataStore
import kotlinx.coroutines.Job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.SongCreation
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
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.RhymeAITheme
import com.rhymeai.app.util.PronunciationDictionary
import com.rhymeai.app.data.sync.backupStatusLine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test

/**
 * Cancels and joins view models a test built by hand (no Activity clears them), so none keeps saving or backing up
 * into the next test, and empties [viewModels]. All are cancelled before any is joined, so one that never finishes still
 * leaves the others stopped; the joint wait is bounded and fails the test instead of hanging the run.
 */
internal fun stopViewModels(viewModels: MutableList<MainViewModel>) {
    try {
        val jobs = viewModels.map { it.viewModelScope.coroutineContext[Job]!! }
        jobs.forEach { it.cancel() }
        runBlocking { withTimeout(10_000) { jobs.joinAll() } }
    } finally {
        viewModels.clear()
    }
}

/** Settings Backup rows rendered for each status, with no Drive involved. */
class BackupSectionUiTest {
    @get:Rule val compose = createComposeRule()

    private val state = mutableStateOf(BackupSectionState())
    private var disconnects = 0

    private fun show(animations: Boolean = true) {
        compose.setContent {
            RhymeAITheme {
                androidx.compose.runtime.CompositionLocalProvider(LocalAnimationsEnabled provides animations) {
                    // On the app's surface, as in Settings, so rendered ink can be measured against the canvas.
                    androidx.compose.material3.Surface {
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
        }
    }

    /** "Backing up…" settles into "just now" with a cross-fade and the success check, instead of a one-frame swap. */
    @Test fun statusCrossFadesOnTheStateTierAndJustNowWearsTheCheck() {
        state.value = BackupSectionState(status = BackupStatus.BackingUp)
        show(animations = true)
        compose.onNodeWithText("Backing up… · Google Drive").assertIsDisplayed()
        compose.onNodeWithTag("backup_status_check", useUnmergedTree = true).assertDoesNotExist()
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { state.value = BackupSectionState(status = BackupStatus.Connected(10 * 60_000L - 5_000L)) }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Backing up… · Google Drive").assertExists()
        compose.onNodeWithText("Last backed up just now · Google Drive").assertExists()
        // The arriving line is longer than the leaving one: its tail is the one region only it paints.
        val leavingRight = compose.onNodeWithText("Backing up… · Google Drive").getBoundsInRoot().right
        val arriving = compose.onNodeWithText("Last backed up just now · Google Drive").getBoundsInRoot()
        compose.mainClock.advanceTimeBy(64)
        val tailInkMidway = ink(leavingRight + 8.dp, arriving.right, arriving.top, arriving.bottom)
        compose.mainClock.advanceTimeBy(400)
        compose.onNodeWithText("Backing up… · Google Drive").assertDoesNotExist()
        compose.onNodeWithText("Last backed up just now · Google Drive").assertIsDisplayed()
        val tailInkSettled = ink(leavingRight + 8.dp, arriving.right, arriving.top, arriving.bottom)
        assertTrue("Arriving text must fade in, not snap: $tailInkMidway / $tailInkSettled", tailInkMidway > 0.0 && tailInkMidway < tailInkSettled * 0.8)
        compose.onNodeWithTag("backup_status_check", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Back up now").assertIsDisplayed()
        compose.mainClock.autoAdvance = true
    }

    /** Mean darkness of a root-relative region (1 = all ink). */
    private fun ink(left: androidx.compose.ui.unit.Dp, right: androidx.compose.ui.unit.Dp, top: androidx.compose.ui.unit.Dp, bottom: androidx.compose.ui.unit.Dp): Double {
        // The test clock is paused; the renderer still needs a real vsync to present the last frame.
        Thread.sleep(48)
        val pixels = compose.onRoot().captureToImage().toPixelMap()
        val d = compose.density.density
        val x0 = (left.value * d).toInt().coerceIn(0, pixels.width - 1); val x1 = (right.value * d).toInt().coerceIn(x0 + 1, pixels.width)
        val y0 = (top.value * d).toInt().coerceIn(0, pixels.height - 1); val y1 = (bottom.value * d).toInt().coerceIn(y0 + 1, pixels.height)
        var sum = 0.0
        for (y in y0 until y1) for (x in x0 until x1) {
            val p = pixels[x, y]; sum += 1f - (0.299f * p.red + 0.587f * p.green + 0.114f * p.blue)
        }
        return sum / ((y1 - y0) * (x1 - x0))
    }

    @Test fun reducedMotionSwapsTheStatusInOneFrame() {
        state.value = BackupSectionState(status = BackupStatus.BackingUp)
        show(animations = false)
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { state.value = BackupSectionState(status = BackupStatus.Connected(10 * 60_000L - 5_000L)) }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Backing up… · Google Drive").assertDoesNotExist()
        compose.onNodeWithText("Last backed up just now · Google Drive").assertIsDisplayed()
        compose.onNodeWithTag("backup_status_check", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Back up now").assertIsDisplayed()
        compose.mainClock.autoAdvance = true
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
    /** View models built here without an Activity; [stopViewModels] ends them before the stored state is reset. */
    private val handBuilt = mutableListOf<MainViewModel>()

    // Each launch while the dictionary is still loading starts another full load; this class relaunches
    // fast enough to stack them past the 192 MB heap. Loaded once here, no launch loads it again.
    @Before fun loadDictionaryOnce() {
        if (PronunciationDictionary.shared.wordCount == 0) context.assets.open("cmudict-rhymeai.tsv").use(PronunciationDictionary::initialize)
    }

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

    /**
     * Not now on the empty phone: backup pauses and Drive keeps its bytes; a song saved here then ends the pause.
     *
     * The save reaches the backup scheduler through the view model's change collector, at a time the test cannot see,
     * and Not now decides its pause from a library read that can also land after the save. A Back up now started before
     * either of them made that change arrive mid-run, which queues one more backup and leaves the status Pending for the
     * 30 s debounce. So the pause is ended by the queued automatic backup itself: the background flush runs a backup only
     * once a change is queued (after one first flush, made here while the restore offer stops any run).
     *
     * Not now's own coroutine is joined before the save (launch already shows the same Paused(2), so the status cannot
     * tell): its read then sees the empty library and pauses instead of starting a run of its own. The only thing that
     * can queue the run is the save's change reaching the scheduler, so Connected means that change was consumed and
     * backed up, and nothing from this setup can turn a later test's status Pending.
     */
    private fun declineThenEndThePauseWithASongHere(vm: MainViewModel) {
        val before = drive.bytes(BackupManifest.FILE_NAME)
        val scope = vm.viewModelScope.coroutineContext[Job]!!
        var notNow = emptyList<Job>()
        instrumentation.runOnMainSync {
            check(vm.restoreOffer != null) { "The first background flush must run while the restore offer stops it." }
            vm.triggerBackgroundDriveSync()
            val running = scope.children.toSet()
            vm.declineRestoreOffer()
            notNow = scope.children.filterNot(running::contains).toList()
        }
        runBlocking { withTimeout(10_000) { notNow.joinAll() } }
        assertEquals(BackupStatus.Paused(2), vm.backupStatus)
        assertTrue(before.contentEquals(drive.bytes(BackupManifest.FILE_NAME)))
        runBlocking { repo.saveProjects(listOf(SongProject(id = "here", title = "Here"))) }
        waitUntil({ "status ${vm.backupStatus} notice ${vm.backupNotice} confirm ${vm.emptyBackupConfirm} songs ${runBlocking { repo.projectsFlow.first().map { it.id } }}" }) {
            var connected = false
            instrumentation.runOnMainSync {
                connected = vm.backupStatus is BackupStatus.Connected
                if (!connected) vm.triggerBackgroundDriveSync()
            }
            connected
        }
    }

    @After fun restore() {
        try {
            stopViewModels(handBuilt)
        } finally {
            scenario?.close()
            BackupTestHooks.driveClient = null
            BackupTestHooks.authorizer = null
            BackupTestHooks.beforeHoldResolve = null
            BackupTestHooks.beforeHoldListRefresh = null
            BackupTestHooks.beforeHoldTicketRead = null
            RecoveryTestHooks.onRevokeRead = null
            com.rhymeai.app.data.repository.RepositoryTestHooks.afterUpdateCheck = null
            com.rhymeai.app.data.repository.RepositoryTestHooks.afterInsertCheck = null
            RecoveryTestHooks.beforeRecoveryInsert = null
            RecoveryTestHooks.failNextRecovery.set(false)
            NotebookTestHooks.afterJoinBeforeSettle = null
            NotebookTestHooks.onJoinWait = null
            NotebookTestHooks.beforeLoadedNotebookWrite = null
            DraftSaveTestHooks.beforeWrite = null
            DraftSaveTestHooks.beforeReread = null
            BackupTestHooks.beforeMenuSend = null
            BackupTestHooks.afterSendMarked = null
            BackupTestHooks.afterHoldCopyRead = null
            BackupTestHooks.beforeHoldCopyRead = null
            DraftSaveTestHooks.insideCopyLock = null
            SongOpenTestHooks.beforeSwap = null
            prefs().edit().clear().commit()
            if (::repo.isInitialized) runBlocking {
                repo.saveProjects(savedProjects)
                repo.saveTrashedProjects(savedTrash)
            }
            // After every fixture writer stopped, also when the test failed.
            foundWorkspaces?.let { found ->
                runBlocking { context.dataStore.edit { prefs -> found()?.let { prefs[workspacesKey] = it } ?: prefs.remove(workspacesKey) } }
                foundWorkspaces = null
            }
        }
    }

    @Test fun firstRunSheetOffersTheBackupAndRestoreMergesIt() {
        launchConnectedWithEmptyLibrary()
        waitForText("Restore your songs?")
        compose.onNodeWithText(
            "We found 2 songs and 0 recordings in your Google Drive backup. Not now leaves Drive as it is; backup stays paused until you restore."
        ).assertIsDisplayed()
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

    /** Not now reads the library before it pauses; a Disconnect in that gap must stay Not connected. */
    @Test fun disconnectRightAfterNotNowStaysNotConnected() {
        val vm = launchConnectedWithEmptyLibrary()
        waitForText("Restore your songs?")
        // One main-thread turn: Not now's coroutine suspends on the library read, then Disconnect runs.
        instrumentation.runOnMainSync {
            vm.declineRestoreOffer()
            vm.disconnectDrive()
        }

        waitUntil { vm.backupNotice?.startsWith("Disconnected from Google Drive") == true }
        // Let Not now's coroutine finish its library read and resume.
        SystemClock.sleep(500)
        instrumentation.waitForIdleSync()
        assertEquals(BackupStatus.NotConnected, vm.backupStatus)
        assertFalse(prefs().getBoolean("drive_connected", false))
    }

    @Test fun tombstonesAndRecordingChangesQueueTheDebouncedBackup() {
        val vm = launchConnectedWithEmptyLibrary()
        waitForText("Restore your songs?")
        declineThenEndThePauseWithASongHere(vm)

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
            val memo = vm.voiceMemoService.memosForProject("drive-a").single()
            checkNotNull(vm.voiceMemoService.trashMemo(memo))
        }
        waitUntil { vm.backupStatus == BackupStatus.Pending }
    }

    @Test fun importThatAddsOnlyRecordingsQueuesTheDebouncedBackup() {
        val vm = launchConnectedWithEmptyLibrary()
        waitForText("Restore your songs?")
        declineThenEndThePauseWithASongHere(vm)

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

    @Test fun aMigrationThatNeedsDriveConsentResumesAsAMigrationAfterIt() {
        launchConnectedWithEmptyLibrary()
        val consent = android.app.PendingIntent.getActivity(
            context, 0, android.content.Intent(context, MainActivity::class.java), android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val needConsent = java.util.concurrent.atomic.AtomicBoolean(true)
        val authorizations = java.util.concurrent.atomic.AtomicInteger()
        BackupTestHooks.authorizer = object : DriveAuthorizer {
            override suspend fun authorize(): DriveAuthorization {
                authorizations.incrementAndGet()
                return if (needConsent.get()) DriveAuthorization.NeedsConsent(consent) else DriveAuthorization.Granted("token")
            }
        }
        // The service reads the hook when the view model builds it, so rebuild the activity.
        scenario?.close()
        lateinit var fresh: MainViewModel
        scenario = ActivityScenario.launch(MainActivity::class.java).also { s -> s.onActivity { fresh = ViewModelProvider(it)[MainViewModel::class.java] } }
        val before = authorizations.get()

        instrumentation.runOnMainSync { fresh.migrateLegacyBackup("correct horse battery staple") }
        waitUntil({ "authorizations ${authorizations.get()}" }) { authorizations.get() > before && !fresh.migrationInProgress }
        // Consent granted: the retry is the migration again (with the passphrase kept in memory), not a plain backup.
        needConsent.set(false)
        var resumedAsMigration = false
        instrumentation.runOnMainSync {
            fresh.retryAfterDriveAuthorization()
            resumedAsMigration = fresh.migrationInProgress
        }
        assertTrue(resumedAsMigration)
        waitUntil { !fresh.migrationInProgress }
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

    @Test fun exportRefusesTwoSongsSharingAnIdAndLeavesTheOldFileIntact() {
        val vm = launchConnectedWithEmptyLibrary()
        runBlocking { repo.saveProjects(listOf(SongProject(id = "twin", title = "First"), SongProject(id = "twin", title = "Second"))) }
        val zip = java.io.File(context.cacheDir, "export-twins.zip")
        val old = byteArrayOf(4, 3, 2, 1)
        zip.writeBytes(old)
        try {
            instrumentation.runOnMainSync { vm.exportBackup(android.net.Uri.fromFile(zip)) }
            waitUntil({ "notice was ${vm.backupNotice}" }) { vm.backupNotice != null }
            assertEquals("Export failed: Two songs on this device share the id twin, so nothing was exported.", vm.backupNotice)
            assertTrue(old.contentEquals(zip.readBytes()))
        } finally {
            zip.delete()
        }
    }

    @Test fun exportStillWritesAnActiveAndATrashedSongSharingAnId() {
        val vm = launchConnectedWithEmptyLibrary()
        runBlocking {
            repo.saveProjects(listOf(SongProject(id = "twin", title = "Active")))
            repo.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "twin", title = "Trashed"), deletedAt = System.currentTimeMillis())))
        }
        val zip = java.io.File(context.cacheDir, "export-active-and-trash.zip")
        try {
            instrumentation.runOnMainSync { vm.exportBackup(android.net.Uri.fromFile(zip)) }
            waitUntil({ "notice was ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Exported") == true }
            java.util.zip.ZipFile(zip).use { archive ->
                assertEquals(1, archive.entries().asSequence().count { it.name == "songs/twin.json" })
                val manifest = BackupManifest.decode(
                    archive.getInputStream(archive.getEntry(com.rhymeai.app.data.sync.BackupArchive.MANIFEST_ENTRY)).use { it.readBytes() }
                )
                assertEquals(listOf("twin"), manifest.projects.map { it.id })
                assertEquals(listOf("twin"), manifest.trashed.map { it.project.id })
                assertEquals("Active", kotlinx.serialization.json.Json { ignoreUnknownKeys = true }.decodeFromString(SongProject.serializer(), archive.getInputStream(archive.getEntry("songs/twin.json")).bufferedReader().readText()).title)
            }
        } finally {
            zip.delete()
        }
    }

    /** Delete forever of a Trash copy whose id is also active: the active song keeps its notebook and recording, even after an import. */
    @Test fun deleteForeverOfATrashCopyKeepsTheActiveSongNotebookAndRecordingThroughImport() {
        val vm = launchConnectedWithEmptyLibrary()
        instrumentation.runOnMainSync { vm.disconnectDrive() }
        waitUntil { vm.backupNotice?.startsWith("Disconnected from Google Drive") == true }
        val id = "p1-${System.nanoTime()}"
        val audio = byteArrayOf(5, 4, 3, 2, 1)
        val source = java.io.File(context.cacheDir, "p1-source.m4a").apply { writeBytes(audio) }
        val entry = com.rhymeai.app.data.sync.RecordingManifestEntry(
            id, "take.m4a", sizeBytes = audio.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(audio), uploadedAt = 2_000L
        )
        val seedZip = java.io.File(context.cacheDir, "p1-seed.zip")
        val emptyZip = java.io.File(context.cacheDir, "p1-empty.zip")
        seedZip.outputStream().use {
            com.rhymeai.app.data.sync.BackupArchive.write(
                it, SyncBlob(projects = listOf(SongProject(id, title = "Active", updatedAt = 1_000L))),
                listOf(com.rhymeai.app.data.sync.LocalRecordingFile(entry, source)), 0L, "test"
            )
        }
        emptyZip.outputStream().use { com.rhymeai.app.data.sync.BackupArchive.write(it, SyncBlob(), emptyList(), 0L, "test") }
        fun record() = runBlocking { repo.recordingRecords() }.singleOrNull { it.projectId == id }
        fun fileBytes(path: String?) = path?.let { com.rhymeai.app.data.recording.RecordingFiles.containedRecordingFile(context.filesDir, it) }
            ?.takeIf { it.exists() }?.readBytes()
        fun keeps(workspace: com.rhymeai.app.data.model.SongWorkspace?) = workspace?.alternates?.any { it.text == "kept line" } == true
        try {
            instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(seedZip)) }
            waitUntil({ "notice was ${vm.backupNotice}" }) { vm.backupNotice == "Imported 1 song and added 1 recording." }
            val seeded = checkNotNull(record())
            assertEquals(2_000L, seeded.uploadedAt)
            assertFalse(seeded.precedenceRepaired)
            assertTrue(audio.contentEquals(fileBytes(checkNotNull(seeded.path))))

            val active = runBlocking { repo.projectsFlow.first() }.single { it.id == id }
            instrumentation.runOnMainSync { vm.loadProject(active) { vm.keepAlternate("kept line") } }
            waitUntil { keeps(runBlocking { repo.workspacesFlow.first()[id] }) }
            runBlocking {
                repo.saveTrashedProjects(listOf(TrashedSongProject(
                    SongProject(id, title = "Trashed", updatedAt = 1_500L), deletedAt = 1_600L,
                    deleteAfter = System.currentTimeMillis() + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
                )))
            }

            instrumentation.runOnMainSync { vm.permanentlyDeleteTrashedProject(id) }
            waitUntil { runBlocking { repo.trashedProjectsFlow.first() }.none { it.project.id == id } }
            // The view model applies its half after the store's edit returns.
            waitUntil { var done = false; instrumentation.runOnMainSync { done = vm.trashedProjects.none { it.project.id == id } }; done }
            val storedNotebook = runBlocking { repo.workspacesFlow.first()[id] }
            var viewNotebook: com.rhymeai.app.data.model.SongWorkspace? = null
            instrumentation.runOnMainSync { viewNotebook = vm.songWorkspace }

            instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(emptyZip)) }
            waitUntil({ "notice was ${vm.backupNotice}" }) { vm.backupNotice == "Imported 0 songs and added 0 recordings." }

            // Every check is collected, so the first loss does not hide the others.
            val problems = mutableListOf<String>()
            fun expect(what: String, ok: Boolean) { if (!ok) problems += what }
            expect("stored notebook kept right after delete forever", keeps(storedNotebook))
            expect("view-model notebook kept right after delete forever", keeps(viewNotebook))
            expect("stored notebook kept after import", keeps(runBlocking { repo.workspacesFlow.first()[id] }))
            var viewAfter: com.rhymeai.app.data.model.SongWorkspace? = null
            instrumentation.runOnMainSync { viewAfter = vm.songWorkspace }
            expect("view-model notebook kept after import", keeps(viewAfter))
            val stillActive = runBlocking { repo.projectsFlow.first() }.singleOrNull { it.id == id }
            expect("active song kept as Active at 1000 (was $stillActive)", stillActive?.title == "Active" && stillActive.updatedAt == 1_000L)
            expect("no Trash row holds the id", runBlocking { repo.trashedProjectsFlow.first() }.none { it.project.id == id })
            val kept = record()
            expect("recording record kept with its path (was $kept)", kept?.path != null)
            expect("recording file holds the seeded bytes", audio.contentEquals(fileBytes(kept?.path)))
            val memos = runBlocking { vm.voiceMemoService.memosForProject(id) }
            expect("recording listed for the song (memos ${memos.map { it.file.name }})", kept?.path != null && memos.any { it.file.name == java.io.File(kept.path!!).name })
            val tombstones = runBlocking { repo.syncDeletions() }.filter { it.projectId == id }
            expect("no tombstone for the id (was $tombstones)", tombstones.isEmpty())
            expect("no pending recording deletion for the id", id !in runBlocking { repo.pendingRecordingDeletionIds() })
            assertTrue(problems.joinToString("; "), problems.isEmpty())
        } finally {
            seedZip.delete()
            emptyZip.delete()
            source.delete()
            com.rhymeai.app.data.recording.RecordingFiles.memoDirectory(context.filesDir, id).deleteRecursively()
            runBlocking {
                runCatching { repo.saveWorkspace(id, null) }
                runCatching { repo.updateRecordingRecords { records -> records.filterNot { it.projectId == id } } }
            }
        }
    }

    /** Two Trash copies sharing an id: delete forever refuses, says why, and both stay. */
    @Test fun deleteForeverRefusesTwoTrashCopiesSharingAnIdAndSaysWhy() {
        val vm = launchConnectedWithEmptyLibrary()
        val id = "p1-twin-${System.nanoTime()}"
        val now = System.currentTimeMillis()
        val keepUntil = now + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
        runBlocking {
            repo.saveTrashedProjects(listOf(
                TrashedSongProject(SongProject(id, lyrics = "one"), deletedAt = now, deleteAfter = keepUntil),
                TrashedSongProject(SongProject(id, lyrics = "two"), deletedAt = now, deleteAfter = keepUntil)
            ))
        }

        instrumentation.runOnMainSync { vm.permanentlyDeleteTrashedProject(id) }

        waitUntil({ "error was ${vm.persistenceError}" }) {
            vm.persistenceError == "Trash holds more than one copy of this song, so none was deleted. Stored songs were left untouched."
        }
        assertEquals(setOf("one", "two"), runBlocking { repo.trashedProjectsFlow.first() }.filter { it.project.id == id }.map { it.project.lyrics }.toSet())
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

    private val openSong = SongProject("open-song", "Open Song", "older words W1", "", 100L)
    /** Notebook entries the fixture replaced, by song id (null: there was none); put back while their rows still exist. */
    private var seededWorkspaces: Map<String, com.rhymeai.app.data.model.SongWorkspace?> = emptyMap()
    private val workspacesKey = androidx.datastore.preferences.core.stringPreferencesKey("local_song_workspaces_json")
    /** The raw notebook preference before this test's first fixture write (the lambda returns null when it was absent). */
    private var foundWorkspaces: (() -> String?)? = null
    private val newerWords = "newer words W2"

    /** Song A with W1 open in the editor of a real view model, Drive connected to [drive]. */
    private fun openSongInEditor(
        trash: List<TrashedSongProject> = emptyList(), otherSongs: List<SongProject> = emptyList(), draft: String? = null,
        workspaces: Map<String, com.rhymeai.app.data.model.SongWorkspace> = emptyMap(),
        mark: com.rhymeai.app.data.repository.PreservationTicket? = null, activity: Boolean = false
    ): MainViewModel {
        check(context.packageName == "com.rhymeai.app.motionqa") { "Backup fixtures require the owned isolated QA app." }
        repo = ProjectRepository(context)
        runBlocking {
            // The raw notebook map as found, once per test: the test starts without it and teardown puts it back.
            if (foundWorkspaces == null) {
                val found = context.dataStore.data.first()[workspacesKey]
                foundWorkspaces = { found }
                context.dataStore.edit { it.remove(workspacesKey) }
            }
            savedProjects = repo.projectsFlow.first()
            savedTrash = repo.trashedProjectsFlow.first()
            repo.saveProjects(emptyList())
            repo.saveTrashedProjects(emptyList())
            repo.saveActiveState(openSong, SongCreation(), openSong.title, openSong.lyrics, openSong.theme)
            // After the save: a same-id Trash entry makes saveActiveState refuse to create the song.
            repo.saveTrashedProjects(trash)
            if (otherSongs.isNotEmpty()) repo.saveProjects(repo.projectsFlow.first() + otherSongs)
            seededWorkspaces = repo.workspacesFlow.first().let { stored -> workspaces.keys.associateWith { stored[it] } }
            workspaces.forEach { (id, workspace) -> repo.saveWorkspace(id, workspace) }
            // A held flush stored this ticket for the open song before the app died.
            if (mark != null) repo.saveActiveState(openSong, null, openSong.title, openSong.lyrics, openSong.theme, preserveAs = mark)
            // An interrupted save's draft: the editor's saved words differ from the song's row.
            if (draft != null) repo.saveEditorState(openSong.title, draft, openSong.theme)
        }
        BackupTestHooks.driveClient = drive
        BackupTestHooks.authorizer = object : DriveAuthorizer {
            override suspend fun authorize() = DriveAuthorization.Granted("token")
        }
        prefs().edit().clear().putBoolean("drive_connected", true).commit()
        // [activity]: the editor is the Activity's own view model, with its lifecycle observer (ON_STOP saves the draft).
        lateinit var vm: MainViewModel
        if (activity) scenario = ActivityScenario.launch(MainActivity::class.java).also { s -> s.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] } }
        else vm = MainViewModel(context.applicationContext as android.app.Application).also(handBuilt::add)
        waitUntil({ "id ${vm.currentProjectId} lyrics ${vm.lyrics}" }) { vm.currentProjectId == openSong.id && vm.lyrics == (draft ?: openSong.lyrics) }
        instrumentation.runOnMainSync { vm.showStartMenu = false }
        return vm
    }

    private fun storedOpenSong() = runBlocking { repo.projectsFlow.first() }.single { it.id == openSong.id }

    /** After the operation stored W2: the next save of the open song keeps W2 and the editor shows it. */
    private fun assertNextSaveKeepsNewerWords(vm: MainViewModel) {
        waitUntil({ "stored ${storedOpenSong()}" }) { storedOpenSong().lyrics == newerWords }
        // The hold has ended and the editor has reloaded, so the save below is the one that could write W1 back.
        waitUntil({ "held ${vm.editorHeld} editor ${vm.lyrics}" }) { !vm.editorHeld && vm.lyrics == newerWords }
        waitUntil({ "view model ${vm.projects}" }) { vm.projects.any { it.id == openSong.id && it.lyrics == newerWords } }
        instrumentation.runOnMainSync { vm.flushCurrentDraft() }
        waitUntil { !vm.savingBeforeNavigation }
        instrumentation.waitForIdleSync()
        val stored = storedOpenSong()
        assertEquals(
            "(stored words, editor words); stored time ${stored.updatedAt}",
            newerWords to newerWords, stored.lyrics to vm.lyrics
        )
    }

    /** Ends the hand-built view models first, so no queued save of theirs writes after the reset. */
    private fun resetOpenSong() {
        try {
            // Closed first: its ON_STOP save then lands before the reset, not after it.
            scenario?.close()
            scenario = null
            stopViewModels(handBuilt)
        } finally {
            runBlocking {
                repo.setCurrentProjectId(null)
                repo.saveEditorState("", "", "")
                for ((id, prior) in seededWorkspaces) {
                    // A row the test removed took its notebook out of reach; the others get theirs back.
                    try { repo.saveWorkspace(id, prior) } catch (_: com.rhymeai.app.data.repository.MissingActiveProjectException) {}
                }
                seededWorkspaces = emptyMap()
            }
        }
    }

    @Test fun aRestoresNewerWordsForTheOpenSongSurviveTheNextSave() {
        drive.put(
            BackupManifest.FILE_NAME,
            BackupManifest.encode(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L))), 0L, "other-device")
        )
        val vm = openSongInEditor()
        try {
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "status ${vm.backupStatus} notice ${vm.backupNotice}" }) { vm.backupStatus is BackupStatus.Connected }
            assertEquals("precondition: the restore stored W2", newerWords, storedOpenSong().lyrics)
            assertNextSaveKeepsNewerWords(vm)
        } finally {
            resetOpenSong()
        }
    }

    @Test fun anImportsNewerWordsForTheOpenSongSurviveTheNextSave() {
        val vm = openSongInEditor()
        val zip = java.io.File(context.cacheDir, "open-song.zip")
        zip.outputStream().use {
            com.rhymeai.app.data.sync.BackupArchive.write(
                it, SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L))), emptyList(), 0L, "test"
            )
        }
        try {
            instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(zip)) }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true }
            assertEquals("precondition: the import stored W2 under the same id", newerWords, storedOpenSong().lyrics)
            assertNextSaveKeepsNewerWords(vm)
        } finally {
            zip.delete()
            resetOpenSong()
        }
    }

    /** Another window saved W2 while this editor still showed W1 untouched: an import must not write W1 back. */
    @Test fun anImportWithAnUntouchedEditorKeepsWordsAnotherWindowSaved() {
        val vm = openSongInEditor()
        val zip = java.io.File(context.cacheDir, "unrelated.zip")
        zip.outputStream().use {
            com.rhymeai.app.data.sync.BackupArchive.write(
                it, SyncBlob(projects = listOf(SongProject("unrelated", "Unrelated", "other words", "", 100L))), emptyList(), 0L, "test"
            )
        }
        try {
            // The import starts at once, whether or not this view model has seen the other window's save yet.
            // What another window's save writes: the row and the saved editor state. Off the main thread: a store write
            // blocking it can wait forever behind a view-model write whose edit runs on the main thread.
            runBlocking { repo.saveActiveState(openSong.copy(lyrics = newerWords, updatedAt = 200L), null, openSong.title, newerWords, openSong.theme) }
            instrumentation.runOnMainSync {
                assertEquals("precondition: the editor still shows W1", openSong.lyrics, vm.lyrics)
                vm.importBackup(android.net.Uri.fromFile(zip))
            }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true }
            waitUntil({ "held ${vm.editorHeld} editor ${vm.lyrics}" }) { !vm.editorHeld && vm.lyrics == newerWords }
            val songs = runBlocking { repo.projectsFlow.first() }
            assertEquals(newerWords, storedOpenSong().lyrics)
            assertEquals(setOf(openSong.id, "unrelated"), songs.map { it.id }.toSet())
        } finally {
            zip.delete()
            resetOpenSong()
        }
    }

    private fun unrelatedArchive(): java.io.File = java.io.File(context.cacheDir, "unrelated-archive.zip").also { zip ->
        zip.outputStream().use {
            com.rhymeai.app.data.sync.BackupArchive.write(
                it, SyncBlob(projects = listOf(SongProject("unrelated", "Unrelated", "other words", "", 100L))), emptyList(), 0L, "test"
            )
        }
    }

    /** A template is an edit until a save of it completes: a hold during its autosave's debounce saves it. */
    @Test fun aTemplateAppliedJustBeforeAnImportIsSavedNotDropped() {
        val vm = openSongInEditor()
        val zip = unrelatedArchive()
        try {
            instrumentation.runOnMainSync { vm.applyTemplate("Verse", "", "template words") }
            waitUntil({ "editor ${vm.lyrics}" }) { vm.lyrics == "template words" }
            instrumentation.runOnMainSync {
                assertTrue("precondition: the template's autosave has not written yet",
                    runBlocking { repo.projectsFlow.first() }.none { it.lyrics == "template words" })
                vm.importBackup(android.net.Uri.fromFile(zip))
            }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true }
            waitUntil { !vm.editorHeld }
            instrumentation.waitForIdleSync()
            val template = runBlocking { repo.projectsFlow.first() }.single { it.lyrics == "template words" }
            assertEquals(template.id to "template words", vm.currentProjectId to vm.lyrics)
        } finally {
            zip.delete()
            resetOpenSong()
        }
    }

    /** A one-liner's own save leaves the editor clean: a later import never writes those words over another window's. */
    @Test fun aSavedOneLinerIsNotWrittenAgainOverAnotherWindowsWordsByAnImport() {
        val vm = openSongInEditor()
        val zip = unrelatedArchive()
        val line = runBlocking { vm.oneLinersStore.add("a sent line") }
        val sent = kotlinx.coroutines.CompletableDeferred<String>()
        try {
            instrumentation.runOnMainSync { vm.sendOneLinerToSong(line, storedOpenSong()) { sent.complete(it) } }
            runBlocking { kotlinx.coroutines.withTimeout(10_000) { sent.await() } }
            assertTrue(storedOpenSong().lyrics.contains("a sent line"))
            // What another window's save writes, off the main thread as above.
            runBlocking { repo.saveActiveState(storedOpenSong().copy(lyrics = newerWords, updatedAt = System.currentTimeMillis()), null, openSong.title, newerWords, openSong.theme) }
            instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(zip)) }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true }
            waitUntil({ "held ${vm.editorHeld} editor ${vm.lyrics}" }) { !vm.editorHeld && vm.lyrics == newerWords }
            assertEquals(newerWords, storedOpenSong().lyrics)
        } finally {
            zip.delete()
            runBlocking { vm.oneLinersStore.permanentlyDelete(line.id) }
            resetOpenSong()
        }
    }

    /** Sends a one-liner to the open song from behind the start menu and runs [edit] while the send is suspended. */
    private fun editDuringOneLinerSend(vm: MainViewModel, edit: (MainViewModel) -> Unit): com.rhymeai.app.data.model.OneLiner {
        val line = runBlocking { vm.oneLinersStore.add("a sent line") }
        val sent = kotlinx.coroutines.CompletableDeferred<String>()
        instrumentation.runOnMainSync {
            vm.showStartMenu = true
            vm.sendOneLinerToSong(line, storedOpenSong()) { sent.complete(it) }
            // The send is suspended in its write: the song is opened and edited before its callback runs.
            vm.showStartMenu = false
            edit(vm)
        }
        runBlocking { kotlinx.coroutines.withTimeout(10_000) { sent.await() } }
        instrumentation.waitForIdleSync()
        return line
    }

    /** A title edited while a one-liner's send was suspended is not marked saved by its callback: an import keeps it and the line. */
    @Test fun aTitleEditedWhileAOneLinerIsSentIsSavedByAnImport() {
        val vm = openSongInEditor()
        val zip = unrelatedArchive()
        var line: com.rhymeai.app.data.model.OneLiner? = null
        try {
            line = editDuringOneLinerSend(vm) { it.onTitleChanged("edited title") }
            instrumentation.runOnMainSync {
                assertEquals("precondition: the title's autosave has not written yet", openSong.title, storedOpenSong().title)
                vm.importBackup(android.net.Uri.fromFile(zip))
            }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true }
            waitUntil { !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertEquals("edited title" to "edited title", storedOpenSong().title to vm.title)
            // The words were not touched: the sent line is in them, so the hold's save keeps it.
            assertTrue("row ${storedOpenSong()}", storedOpenSong().lyrics.contains("a sent line"))
        } finally {
            zip.delete()
            line?.let { runBlocking { vm.oneLinersStore.permanentlyDelete(it.id) } }
            resetOpenSong()
        }
    }

    /** Words typed while a one-liner's send was suspended are not replaced by the song its callback read. */
    @Test fun wordsTypedWhileAOneLinerIsSentAreNotReplacedByItsCallback() {
        val vm = openSongInEditor()
        var line: com.rhymeai.app.data.model.OneLiner? = null
        try {
            line = editDuringOneLinerSend(vm) { it.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue("typed words")) }
            assertEquals("typed words", vm.lyrics)
        } finally {
            // The typing queued an autosave that would otherwise write "typed words" into the next test's open song.
            // Bounded: a join that never returns fails the test instead of hanging the run.
            try {
                stopViewModels(handBuilt)
            } finally {
                line?.let { runBlocking { vm.oneLinersStore.permanentlyDelete(it.id) } }
                resetOpenSong()
            }
        }
    }

    /** Two one-liners sent at once: the first callback's load is not an edit, so the second still loads and a background save keeps both. */
    @Test fun twoOneLinersSentAtOnceBothSurviveTheBackgroundSave() {
        val vm = openSongInEditor()
        val first = runBlocking { vm.oneLinersStore.add("first sent line") }
        val second = runBlocking { vm.oneLinersStore.add("second sent line") }
        val firstSent = kotlinx.coroutines.CompletableDeferred<String>()
        val secondSent = kotlinx.coroutines.CompletableDeferred<String>()
        val song = storedOpenSong()
        try {
            instrumentation.runOnMainSync {
                vm.showStartMenu = true
                // Both sends read the words' revision before either write returns.
                vm.sendOneLinerToSong(first, song) { firstSent.complete(it) }
                vm.sendOneLinerToSong(second, song) { secondSent.complete(it) }
                // The song is opened before the callbacks run.
                vm.showStartMenu = false
            }
            runBlocking { kotlinx.coroutines.withTimeout(10_000) { firstSent.await(); secondSent.await() } }
            instrumentation.waitForIdleSync()
            // Going to the background saves the open song.
            instrumentation.runOnMainSync { vm.flushCurrentDraft() }
            waitUntil { !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            val stored = storedOpenSong().lyrics
            assertTrue("stored $stored editor ${vm.lyrics}",
                listOf(stored, vm.lyrics).all { it.contains("first sent line") && it.contains("second sent line") })
        } finally {
            try {
                stopViewModels(handBuilt)
            } finally {
                runBlocking { listOf(first, second).forEach { vm.oneLinersStore.permanentlyDelete(it.id) } }
                resetOpenSong()
            }
        }
    }

    /** Opening the song is a load, not an edit: a send started behind the start menu still loads the song with its line. */
    @Test fun anOpenOfTheSameSongDoesNotMakeAPendingSendSkipItsLoad() {
        val vm = openSongInEditor()
        val line = runBlocking { vm.oneLinersStore.add("a sent line") }
        val sent = kotlinx.coroutines.CompletableDeferred<String>()
        try {
            // Another window saved W2, so the open loads words the editor does not show yet. Off the main thread, as above.
            runBlocking { repo.saveActiveState(openSong.copy(lyrics = newerWords, updatedAt = 200L), null, openSong.title, newerWords, openSong.theme) }
            val song = storedOpenSong()
            instrumentation.runOnMainSync {
                vm.showStartMenu = true
                // The open takes the song store's lock at once and reads W2; the send records the words' revision and
                // appends only after the open has read, so the open's load lands between the send's start and its callback.
                vm.loadProject(song)
                vm.sendOneLinerToSong(line, song) { sent.complete(it) }
            }
            runBlocking { kotlinx.coroutines.withTimeout(10_000) { sent.await() } }
            waitUntil({ "menu ${vm.showStartMenu} opening ${vm.openingSong}" }) { !vm.showStartMenu && !vm.openingSong }
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync { vm.flushCurrentDraft() }
            waitUntil { !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            val stored = storedOpenSong().lyrics
            assertTrue("stored $stored editor ${vm.lyrics}",
                listOf(stored, vm.lyrics).all { it.contains(newerWords) && it.contains("a sent line") })
        } finally {
            try {
                stopViewModels(handBuilt)
            } finally {
                runBlocking { vm.oneLinersStore.permanentlyDelete(line.id) }
                resetOpenSong()
            }
        }
    }

    /** A restore's reload of the open song is a load: a send started before it still loads W2 and its line, and a save keeps both. */
    @Test fun aSendPendingAcrossARestoreKeepsTheRestoredWordsAndTheLine() {
        // Dated ahead, so Drive's words win over the stored W1.
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L))))
        val vm = openSongInEditor()
        val line = runBlocking { vm.oneLinersStore.add("a sent line") }
        val sent = kotlinx.coroutines.CompletableDeferred<String>()
        val held = kotlinx.coroutines.CompletableDeferred<Unit>()
        val song = storedOpenSong()
        try {
            BackupTestHooks.beforeMenuSend = held
            instrumentation.runOnMainSync {
                vm.showStartMenu = true
                // Records the words' revision, then waits before its write.
                vm.sendOneLinerToSong(line, song) { sent.complete(it) }
            }
            waitUntil { BackupTestHooks.beforeMenuSend == null }
            instrumentation.runOnMainSync { vm.loadProject(song) }
            waitUntil({ "menu ${vm.showStartMenu} opening ${vm.openingSong}" }) { !vm.showStartMenu && !vm.openingSong }
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld} editor ${vm.lyrics}" }) {
                vm.backupStatus is BackupStatus.Connected && !vm.editorHeld && vm.lyrics == newerWords
            }
            held.complete(Unit)
            runBlocking { kotlinx.coroutines.withTimeout(10_000) { sent.await() } }
            instrumentation.waitForIdleSync()
            // Going to the background saves the open song.
            instrumentation.runOnMainSync { vm.flushCurrentDraft() }
            waitUntil { !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            val stored = storedOpenSong().lyrics
            assertTrue("stored $stored editor ${vm.lyrics}",
                listOf(stored, vm.lyrics).all { it.contains(newerWords) && it.contains("a sent line") })
        } finally {
            BackupTestHooks.beforeMenuSend = null
            held.complete(Unit)
            try {
                stopViewModels(handBuilt)
            } finally {
                runBlocking { vm.oneLinersStore.permanentlyDelete(line.id) }
                resetOpenSong()
            }
        }
    }

    /** Words typed away and back to a saved draft W2 while a one-liner is sent are not replaced by W1 and the line. */
    @Test fun aDraftTypedAwayAndBackWhileAOneLinerIsSentIsSavedByAnImport() {
        val vm = openSongInEditor(draft = newerWords)
        val zip = unrelatedArchive()
        var line: com.rhymeai.app.data.model.OneLiner? = null
        try {
            line = editDuringOneLinerSend(vm) {
                it.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue("typed away"))
                it.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue(newerWords))
            }
            assertEquals(newerWords, vm.lyrics)
            instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(zip)) }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true }
            waitUntil { !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertEquals(newerWords to newerWords, storedOpenSong().lyrics to vm.lyrics)
        } finally {
            zip.delete()
            line?.let { runBlocking { vm.oneLinersStore.permanentlyDelete(it.id) } }
            resetOpenSong()
        }
    }

    /** A template equal to the last document is still a new document: a hold during its debounce saves it under its own id. */
    @Test fun aTemplateEqualToTheLastDocumentIsSavedAsItsOwnSongByAnImport() {
        val vm = openSongInEditor()
        val zip = unrelatedArchive()
        fun templates() = runBlocking { repo.projectsFlow.first() }.filter { it.lyrics == "template words" }
        try {
            instrumentation.runOnMainSync { vm.applyTemplate("Verse", "", "template words") }
            waitUntil({ "templates ${templates()} id ${vm.currentProjectId}" }) { templates().size == 1 && vm.currentProjectId == templates().single().id }
            val first = templates().single().id
            instrumentation.runOnMainSync { vm.applyTemplate("Verse", "", "template words") }
            waitUntil({ "id ${vm.currentProjectId}" }) { vm.currentProjectId == null && vm.lyrics == "template words" }
            instrumentation.runOnMainSync {
                assertEquals("precondition: the second template's autosave has not written yet", 1, templates().size)
                vm.importBackup(android.net.Uri.fromFile(zip))
            }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true }
            waitUntil { !vm.editorHeld }
            instrumentation.waitForIdleSync()
            val second = templates().map { it.id }.single { it != first }
            assertEquals(second, vm.currentProjectId)
        } finally {
            zip.delete()
            resetOpenSong()
        }
    }

    /** An interrupted save's draft over an untouched row: an unrelated import writes nothing and the draft stays. */
    @Test fun aSavedDraftOverAnUntouchedRowStaysAfterAnUnrelatedImport() {
        val vm = openSongInEditor(draft = newerWords)
        val zip = unrelatedArchive()
        try {
            instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(zip)) }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true }
            waitUntil { !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertEquals(newerWords, vm.lyrics)
            assertEquals(newerWords, runBlocking { repo.editorStateFlow().first() }.second)
            assertEquals(openSong, storedOpenSong())
        } finally {
            zip.delete()
            resetOpenSong()
        }
    }

    /** The same, when a mark a dead window left for the song gives the unedited hold a ticket the import never acts on. */
    @Test fun aSavedDraftOverAnUntouchedRowStaysWhenTheHoldHasAnUnusedMark() {
        val vm = openSongInEditor(draft = newerWords)
        val marks = androidx.datastore.preferences.core.stringPreferencesKey("preserved_songs_json")
        runBlocking { context.dataStore.edit { it[marks] = """{"${openSong.id}":{"copyId":"unused-copy","token":"dead-window"}}""" } }
        val zip = unrelatedArchive()
        try {
            instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(zip)) }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true && !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertEquals(openSong.id to newerWords, vm.currentProjectId to vm.lyrics)
            assertEquals(Triple(openSong.title, newerWords, openSong.theme), runBlocking { repo.editorStateFlow().first() })
            assertEquals(openSong, storedOpenSong())
        } finally {
            zip.delete()
            runBlocking { context.dataStore.edit { it.remove(marks) } }
            resetOpenSong()
        }
    }

    /** Typed away and back to the loaded words is still an edit: the hold saves it and a replacing restore keeps it. */
    @Test fun wordsTypedBackToTheLoadedValueAreStillSavedAndKept() {
        assertHeldEditIsKept(otherWindowSave = {
            repo.saveProjects(repo.projectsFlow.first().map { if (it.id == openSong.id) it.copy(lyrics = "another window's words", updatedAt = 150L) else it })
        }) { vm ->
            vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("typed away")
            vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(openSong.lyrics)
        }.let { copy -> assertEquals(openSong.lyrics, copy.lyrics) }
    }

    /** A theme-only edit is an edit too. */
    @Test fun aThemeOnlyEditUnderARestoreIsKept() {
        assertHeldEditIsKept { vm -> vm.theme = "a new theme" }.let { copy -> assertEquals(openSong.lyrics to "a new theme", copy.lyrics to copy.theme) }
    }

    /**
     * Runs [otherWindowSave] off the main thread (a store write blocking it can deadlock), then [edit] on the open editor
     * and a restore whose newer row replaces the song; returns the kept copy the editor shows.
     */
    private fun assertHeldEditIsKept(otherWindowSave: suspend () -> Unit = {}, edit: (MainViewModel) -> Unit): SongProject {
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L))))
        val vm = openSongInEditor()
        try {
            runBlocking { otherWindowSave() }
            instrumentation.runOnMainSync { edit(vm); vm.restoreFromBackup() }
            waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertEquals(newerWords, storedOpenSong().lyrics)
            val copy = runBlocking { repo.projectsFlow.first() }.single { it.id != openSong.id }
            assertEquals(copy.id, vm.currentProjectId)
            return copy
        } finally {
            resetOpenSong()
        }
    }

    @Test fun aTrashRestoreOfTheOpenSongsIdKeepsItAndReturnsTheTrashCopyAsANewSong() {
        val vm = openSongInEditor(trash = listOf(TrashedSongProject(openSong.copy(lyrics = newerWords, updatedAt = 200L), deletedAt = 300L)))
        val notebook = com.rhymeai.app.data.model.SongWorkspace(checkpointAt = 123L)
        runBlocking { repo.saveWorkspace(openSong.id, notebook) }
        try {
            instrumentation.runOnMainSync { vm.restoreTrashedProject(openSong.id) }
            waitUntil({ "trash ${runBlocking { repo.trashedProjectsFlow.first() }}" }) { runBlocking { repo.trashedProjectsFlow.first() }.isEmpty() }
            val songs = runBlocking { repo.projectsFlow.first() }
            assertTrue("$songs", songs.any { it.id != openSong.id && it.lyrics == newerWords })
            assertEquals(openSong.lyrics, storedOpenSong().lyrics)
            assertEquals("the active song keeps its notebook and versions", notebook, runBlocking { repo.workspacesFlow.first() }[openSong.id])
            assertEquals("This song was already in your songs, so its Trash copy was restored as a new song.", vm.persistenceError)
            instrumentation.runOnMainSync { vm.flushCurrentDraft() }
            waitUntil { !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            assertEquals(openSong.lyrics to openSong.lyrics, storedOpenSong().lyrics to vm.lyrics)
        } finally {
            resetOpenSong()
        }
    }

    private val refusedNotice =
        "Your open draft could not be saved, so your songs were not restored. Some recordings may have been downloaded already; restore again to finish."

    /** A new view-model over the stored state, as after a relaunch; it shows [lyrics] for the open song. */
    private fun relaunchedViewModel(lyrics: String): MainViewModel {
        val vm = MainViewModel(context.applicationContext as android.app.Application).also(handBuilt::add)
        waitUntil({ "id ${vm.currentProjectId} lyrics ${vm.lyrics}" }) { vm.currentProjectId == openSong.id && vm.lyrics == lyrics }
        return vm
    }

    private fun putDriveSongs(blob: SyncBlob) = drive.put(BackupManifest.FILE_NAME, BackupManifest.encode(blob, 0L, "other-device"))

    @Test fun aDraftThatCannotBeSavedStopsTheRestoreAndStaysInTheEditor() {
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L))))
        val vm = openSongInEditor()
        try {
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("unsaved edit")
                DraftSaveTestHooks.failNext.set(true)
                vm.restoreFromBackup()
            }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice == refusedNotice }
            instrumentation.waitForIdleSync()
            assertEquals("nothing restored or overwritten", openSong.lyrics, storedOpenSong().lyrics)
            assertEquals("unsaved edit", vm.lyrics)
            assertEquals(SaveStatus.FAILED, vm.saveStatus)
            assertFalse(vm.editorHeld)
        } finally {
            DraftSaveTestHooks.failNext.set(false)
            resetOpenSong()
        }
    }

    @Test fun aSaveInFlightWhenTheRestoreStartsIsDrainedAndNeverReplayed() {
        // Dated ahead, so Drive's words win the merge over the in-flight save.
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L))))
        val vm = openSongInEditor()
        val held = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("in flight")
                DraftSaveTestHooks.beforeWrite = held
                vm.flushCurrentDraft()
                vm.restoreFromBackup()
            }
            waitUntil { DraftSaveTestHooks.beforeWrite == null }
            assertTrue(vm.savingBeforeNavigation)
            held.complete(Unit)
            waitUntil({ "status ${vm.backupStatus}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            SystemClock.sleep(1_000)
            instrumentation.waitForIdleSync()
            assertEquals(newerWords to newerWords, storedOpenSong().lyrics to vm.lyrics)
        } finally {
            DraftSaveTestHooks.beforeWrite = null
            resetOpenSong()
        }
    }

    @Test fun typingAutosaveAndDraftWritesDuringTheRestoreChangeNothing() {
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L))))
        val vm = openSongInEditor()
        val resume = kotlinx.coroutines.CompletableDeferred<Unit>()
        fun alternates() = runBlocking { repo.workspacesFlow.first() }[openSong.id]?.alternates.orEmpty()
        try {
            instrumentation.runOnMainSync { vm.keepAlternate("seeded line") }
            waitUntil({ "alternates ${alternates()}" }) { alternates().any { it.text == "seeded line" } }
            val seeded = alternates().single { it.text == "seeded line" }.id
            // Paused inside the hold, right before the commit. The editor is untouched, so the hold writes no draft.
            val reached = kotlinx.coroutines.CompletableDeferred<Unit>()
            BackupTestHooks.beforeHeldOperation = { reached.complete(Unit); resume.await() }
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil { reached.isCompleted && vm.editorHeld }
            SystemClock.sleep(300)
            val notebook = runBlocking { repo.workspacesFlow.first() }[openSong.id]
            instrumentation.runOnMainSync {
                vm.onTitleChanged("typed title")
                vm.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue("typed words"))
                vm.onThemeChanged("typed theme")
                vm.triggerAutoSave(retry = true)
                vm.saveDraftVersion()
                vm.keepAlternate("kept line")
                vm.removeAlternate(seeded)
                vm.rememberEditorPosition(40f)
            }
            SystemClock.sleep(500)
            instrumentation.waitForIdleSync()
            assertTrue(vm.editorHeld)
            assertEquals(Triple(openSong.title, openSong.lyrics, openSong.theme), Triple(vm.title, vm.lyrics, vm.theme))
            assertEquals(openSong.lyrics, storedOpenSong().lyrics)
            assertEquals("notebook unchanged", notebook, runBlocking { repo.workspacesFlow.first() }[openSong.id])
            resume.complete(Unit)
            waitUntil({ "status ${vm.backupStatus}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            assertNextSaveKeepsNewerWords(vm)
            assertEquals(null, vm.persistenceError)
        } finally {
            DraftSaveTestHooks.beforeWrite = null
            BackupTestHooks.beforeHeldOperation = null
            resume.complete(Unit)
            resetOpenSong()
        }
    }

    @Test fun aSongOpenedDuringTheRestoreOpensAfterIt() {
        val other = SongProject("other-song", "Other Song", "other words", "", 150L)
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L))))
        val vm = openSongInEditor(otherSongs = listOf(other))
        val resume = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            val reached = kotlinx.coroutines.CompletableDeferred<Unit>()
            BackupTestHooks.beforeHeldOperation = { reached.complete(Unit); resume.await() }
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil { reached.isCompleted && vm.editorHeld }
            instrumentation.runOnMainSync {
                vm.loadProject(other)
                // Going to the background meanwhile saves; it must not drop the waiting open.
                vm.flushCurrentDraft()
            }
            SystemClock.sleep(300)
            instrumentation.waitForIdleSync()
            assertEquals(openSong.id to openSong.lyrics, vm.currentProjectId to vm.lyrics)
            resume.complete(Unit)
            waitUntil({ "id ${vm.currentProjectId} lyrics ${vm.lyrics}" }) { vm.currentProjectId == other.id && vm.lyrics == other.lyrics }
            assertEquals(newerWords, storedOpenSong().lyrics)
        } finally {
            DraftSaveTestHooks.beforeWrite = null
            BackupTestHooks.beforeHeldOperation = null
            resume.complete(Unit)
            resetOpenSong()
        }
    }

    @Test fun unsavedWordsStayOpenAndAreSavedWhenTheSameSongIsRestoredFromTrash() {
        val vm = openSongInEditor(trash = listOf(TrashedSongProject(openSong.copy(lyrics = newerWords, updatedAt = 200L), deletedAt = 300L)))
        try {
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("unsaved edit")
                vm.restoreTrashedProject(openSong.id)
            }
            waitUntil({ "songs ${runBlocking { repo.projectsFlow.first() }}" }) {
                runBlocking { repo.projectsFlow.first() }.any { it.id != openSong.id && it.lyrics == newerWords }
            }
            instrumentation.runOnMainSync { vm.flushCurrentDraft() }
            waitUntil { !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            assertEquals(Triple("unsaved edit", "unsaved edit", openSong.id), Triple(storedOpenSong().lyrics, vm.lyrics, vm.currentProjectId))
        } finally {
            resetOpenSong()
        }
    }

    @Test fun editsSavedJustBeforeARestoreReplacesTheSongAreKeptAsANewSong() {
        // Dated ahead, so Drive's words win over the edits the hold saves first.
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L))))
        val vm = openSongInEditor()
        try {
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("edited before restore")
                vm.restoreFromBackup()
            }
            waitUntil({ "status ${vm.backupStatus}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            waitUntil { !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            assertEquals(newerWords, storedOpenSong().lyrics)
            val copy = runBlocking { repo.projectsFlow.first() }.single { it.id != openSong.id }
            assertEquals("edited before restore", copy.lyrics)
            assertEquals(copy.id to "edited before restore", vm.currentProjectId to vm.lyrics)
            assertEquals("This song was replaced from a backup, so your latest edits were saved as a new song.", vm.persistenceError)
            assertKeptCopySurvivesTheNextSave(vm, copy.id)
        } finally {
            resetOpenSong()
        }
    }

    /** The next save writes the kept copy in place: no third song, no second notice. */
    private fun assertKeptCopySurvivesTheNextSave(vm: MainViewModel, copyId: String) {
        val notice = vm.persistenceError
        instrumentation.runOnMainSync { vm.flushCurrentDraft() }
        waitUntil { !vm.savingBeforeNavigation }
        instrumentation.waitForIdleSync()
        val songs = runBlocking { repo.projectsFlow.first() }
        assertEquals("$songs", 2, songs.size)
        assertEquals(newerWords, storedOpenSong().lyrics)
        assertEquals("edited before restore", songs.single { it.id == copyId }.lyrics)
        assertEquals(copyId to notice, vm.currentProjectId to vm.persistenceError)
    }

    @Test fun editsSavedJustBeforeAnImportReplacesTheSongAreKeptAsANewSong() {
        val vm = openSongInEditor()
        val zip = java.io.File(context.cacheDir, "replacing.zip")
        zip.outputStream().use {
            com.rhymeai.app.data.sync.BackupArchive.write(
                it, SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L))),
                emptyList(), 0L, "test"
            )
        }
        try {
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("edited before restore")
                vm.importBackup(android.net.Uri.fromFile(zip))
            }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true && !vm.editorHeld }
            waitUntil { !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            val copy = runBlocking { repo.projectsFlow.first() }.single { it.id != openSong.id }
            assertEquals(copy.id to "edited before restore", vm.currentProjectId to vm.lyrics)
            assertKeptCopySurvivesTheNextSave(vm, copy.id)
        } finally {
            zip.delete()
            resetOpenSong()
        }
    }

    @Test fun aStalledDriveReadNeverHoldsTheEditor() {
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L))))
        val vm = openSongInEditor()
        val paused = kotlinx.coroutines.CompletableDeferred<Unit>()
        val resume = kotlinx.coroutines.CompletableDeferred<Unit>()
        drive.beforeDownload = { paused.complete(Unit); resume.await() }
        try {
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil { paused.isCompleted }
            instrumentation.runOnMainSync { vm.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue("typed while Drive stalls")) }
            SystemClock.sleep(300)
            assertFalse(vm.editorHeld)
            assertEquals("typed while Drive stalls", vm.lyrics)
            drive.beforeDownload = null
            resume.complete(Unit)
            waitUntil({ "status ${vm.backupStatus}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld && !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            // The typed words were saved before the commit and are newer than Drive's, so they stay.
            assertEquals("typed while Drive stalls" to "typed while Drive stalls", storedOpenSong().lyrics to vm.lyrics)
        } finally {
            drive.beforeDownload = null
            resume.complete(Unit)
            resetOpenSong()
        }
    }

    @Test fun aStalledImportFileNeverHoldsTheEditor() {
        val vm = openSongInEditor()
        val fifo = java.io.File(context.cacheDir, "stalled-import")
        fifo.delete()
        android.system.Os.mkfifo(fifo.path, 0x180) // 0600
        val bytes = java.io.ByteArrayOutputStream().also {
            com.rhymeai.app.data.sync.BackupArchive.write(
                it, SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L))), emptyList(), 0L, "test"
            )
        }.toByteArray()
        try {
            instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(fifo)) }
            SystemClock.sleep(500)
            instrumentation.runOnMainSync { vm.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue("typed while the file stalls")) }
            assertFalse(vm.editorHeld)
            assertEquals("typed while the file stalls", vm.lyrics)
            fifo.outputStream().use { it.write(bytes) }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true && !vm.editorHeld }
            waitUntil { !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            // Saved before the commit and newer than the file's words, so they stay.
            assertEquals("typed while the file stalls" to "typed while the file stalls", storedOpenSong().lyrics to vm.lyrics)
        } finally {
            fifo.delete()
            resetOpenSong()
        }
    }

    @Test fun aOneLinerWriteInFlightWhenTheRestoreCommitsIsDrainedFirst() {
        // Dated ahead, so Drive's words win over the line written first.
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L))))
        val vm = openSongInEditor()
        val line = runBlocking { vm.oneLinersStore.add("a sent line") }
        val held = kotlinx.coroutines.CompletableDeferred<Unit>()
        val downloaded = java.util.concurrent.atomic.AtomicBoolean(false)
        drive.beforeDownload = { downloaded.set(true) }
        try {
            DraftSaveTestHooks.beforeWrite = held
            instrumentation.runOnMainSync { vm.sendOneLinerToSong(line, storedOpenSong()) {} }
            waitUntil { DraftSaveTestHooks.beforeWrite == null }
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil { downloaded.get() }
            SystemClock.sleep(700)
            assertEquals("the commit waits for the line's write", openSong.lyrics, storedOpenSong().lyrics)
            held.complete(Unit)
            assertNextSaveKeepsNewerWords(vm)
        } finally {
            DraftSaveTestHooks.beforeWrite = null
            held.complete(Unit)
            drive.beforeDownload = null
            runBlocking { vm.oneLinersStore.permanentlyDelete(line.id) }
            resetOpenSong()
        }
    }

    @Test fun anOpenInProgressWhenTheRestoreCommitsFinishesFirstAndThenShowsTheRestoredWords() {
        val other = SongProject("other-song", "Other Song", "other words", "", 150L)
        putDriveSongs(SyncBlob(projects = listOf(openSong, other.copy(lyrics = newerWords, updatedAt = 200L))))
        val vm = openSongInEditor(otherSongs = listOf(other))
        val swap = kotlinx.coroutines.CompletableDeferred<Unit>()
        val downloaded = java.util.concurrent.atomic.AtomicBoolean(false)
        drive.beforeDownload = { downloaded.set(true) }
        try {
            SongOpenTestHooks.beforeSwap = swap
            instrumentation.runOnMainSync { vm.loadProject(other) }
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil { downloaded.get() }
            SystemClock.sleep(700)
            // The restore reached its commit but waits: the open has not swapped in yet.
            assertFalse(vm.editorHeld)
            assertEquals(other.lyrics, runBlocking { repo.projectsFlow.first() }.single { it.id == other.id }.lyrics)
            swap.complete(Unit)
            waitUntil({ "id ${vm.currentProjectId} lyrics ${vm.lyrics}" }) {
                vm.backupStatus is BackupStatus.Connected && !vm.editorHeld && vm.currentProjectId == other.id && vm.lyrics == newerWords
            }
            instrumentation.runOnMainSync { vm.flushCurrentDraft() }
            waitUntil { !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            assertEquals(newerWords, runBlocking { repo.projectsFlow.first() }.single { it.id == other.id }.lyrics)
        } finally {
            SongOpenTestHooks.beforeSwap = null
            swap.complete(Unit)
            drive.beforeDownload = null
            resetOpenSong()
        }
    }

    /**
     * The production hold saves the edited words, then stops before the commit and never resumes, so its cleanup
     * (clearing the mark, reloading) never runs: the closest this harness gets to the process dying there. The
     * stopped view model stays in memory until the end; a fresh one over the same storage retries with the notebook failing.
     */
    @Test fun aRetryAfterTheAppDiedBetweenTheDraftSaveAndTheCommitKeepsTheSavedWordsAsANewSong() {
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L))))
        val dying = openSongInEditor()
        val saved = "saved before the crash"
        val incoming = "words from a later backup"
        val reached = kotlinx.coroutines.CompletableDeferred<Unit>()
        val workspacesKey = androidx.datastore.preferences.core.stringPreferencesKey("local_song_workspaces_json")
        var workspaces: String? = null
        var corrupted = false
        BackupTestHooks.beforeHeldOperation = { reached.complete(Unit); kotlinx.coroutines.awaitCancellation() }
        try {
            instrumentation.runOnMainSync {
                dying.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(saved)
                dying.restoreFromBackup()
            }
            runBlocking { kotlinx.coroutines.withTimeout(30_000) { reached.await() } }
            BackupTestHooks.beforeHeldOperation = null
            assertEquals("precondition: the hold's draft save stored the words", saved, storedOpenSong().lyrics)
            // Newer than that save, so the retry replaces the saved words.
            putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = incoming, updatedAt = System.currentTimeMillis() + 3_600_000L))))
            // The notebook cannot be read at relaunch, so it holds no version of the saved words: only the mark keeps them.
            runBlocking {
                context.dataStore.edit { workspaces = it[workspacesKey]; it[workspacesKey] = "{not json"; corrupted = true }
            }
            val vm = relaunchedViewModel(saved)
            waitUntil({ "notebook ${vm.notebookError}" }) { vm.notebookError != null }
            instrumentation.runOnMainSync { vm.showStartMenu = false; vm.restoreFromBackup() }
            waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertEquals(incoming, storedOpenSong().lyrics)
            val copy = runBlocking { repo.projectsFlow.first() }.single { it.id != openSong.id }
            assertEquals(saved, copy.lyrics)
            assertEquals(copy.id to saved, vm.currentProjectId to vm.lyrics)
        } finally {
            BackupTestHooks.beforeHeldOperation = null
            try {
                // Ends the stopped view model (and the relaunched one); its cleanup runs now, after the checks.
                stopViewModels(handBuilt)
                waitUntil({ "dying held ${dying.editorHeld}" }) { !dying.editorHeld }
            } finally {
                // The corrupted notebook goes back even when stopping failed; no other teardown knows it.
                if (corrupted) runBlocking {
                    context.dataStore.edit { if (workspaces == null) it.remove(workspacesKey) else it[workspacesKey] = workspaces!! }
                }
                resetOpenSong()
            }
        }
    }

    /**
     * Another window selects song B after A's draft save and before A's commit. A's reload goes to the copy its own
     * commit kept, never to B, and A's next save leaves B's words alone.
     */
    @Test fun aSongSelectedElsewhereDuringARestoreIsNeverTakenOverByTheEditorsWords() {
        val songB = SongProject("song-b", "Song B", "b words", "", 100L)
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L))))
        val vm = openSongInEditor(otherSongs = listOf(songB))
        val edits = "edits in window A"
        BackupTestHooks.beforeHeldOperation = { repo.selectProject(songB.id) }
        try {
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(edits)
                vm.restoreFromBackup()
            }
            waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertEquals(newerWords, storedOpenSong().lyrics)
            val copy = runBlocking { repo.projectsFlow.first() }.single { it.id != openSong.id && it.id != songB.id }
            assertEquals(edits, copy.lyrics)
            assertEquals(copy.id to edits, vm.currentProjectId to vm.lyrics)
            instrumentation.runOnMainSync { vm.flushCurrentDraft() }
            waitUntil { !vm.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            val stored = runBlocking { repo.projectsFlow.first() }
            assertEquals("b words", stored.single { it.id == songB.id }.lyrics)
            assertEquals(edits, stored.single { it.id == copy.id }.lyrics)
        } finally {
            BackupTestHooks.beforeHeldOperation = null
            resetOpenSong()
        }
    }

    private val heldEdits = "edits in window A"
    private val songU = SongProject("song-u", "Song U", "u words", "", 100L)
    private fun newerOpenSong(words: String = newerWords, aheadMillis: Long = 3_600_000L) =
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = words, updatedAt = System.currentTimeMillis() + aheadMillis))))
    private fun songs() = runBlocking { repo.projectsFlow.first() }

    /** Another leg of one test on a fresh open song; teardown still restores the library the test found. */
    private fun openSongAgain(otherSongs: List<SongProject> = emptyList(), activity: Boolean = false): MainViewModel {
        resetOpenSong()
        val found = savedProjects to savedTrash
        return openSongInEditor(otherSongs = otherSongs, activity = activity).also { savedProjects = found.first; savedTrash = found.second }
    }

    /** The hold's kept copy asks for [id] (its first id draw). */
    private fun <T> firstSongIdIs(id: String, block: () -> T): T {
        val saved = SongIdAllocator.next
        var drawn = false
        SongIdAllocator.next = { if (drawn) saved() else { drawn = true; id } }
        try {
            return block()
        } finally {
            SongIdAllocator.next = saved
        }
    }

    private fun editAndRestore(vm: MainViewModel, words: String = heldEdits) {
        instrumentation.runOnMainSync {
            vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(words)
            vm.restoreFromBackup()
        }
        waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
        instrumentation.waitForIdleSync()
    }

    private fun saveNow(vm: MainViewModel) {
        instrumentation.runOnMainSync { vm.flushCurrentDraft() }
        waitUntil { !vm.savingBeforeNavigation }
        instrumentation.waitForIdleSync()
    }

    private val keptNotice = "This song was replaced from a backup, so your latest edits were saved as a new song."

    /**
     * Window A's kept copy asked for unrelated U's id, so the commit gave it another. Window B, unedited, starts its hold
     * after A's draft save and commits first: both read A's one ticket and follow the copy actually made.
     */
    @Test fun twoReadersGetTheSameRemappedCopy() {
        newerOpenSong()
        val a = openSongInEditor(otherSongs = listOf(songU), activity = true)
        val b = relaunchedViewModel(openSong.lyrics)
        instrumentation.runOnMainSync { b.showStartMenu = false }
        val first = java.util.concurrent.atomic.AtomicBoolean(true)
        BackupTestHooks.beforeHeldOperation = {
            if (first.compareAndSet(true, false)) {
                b.restoreFromBackup()
                while (b.editorHeld || b.backupStatus !is BackupStatus.Connected) kotlinx.coroutines.delay(20)
            }
        }
        try {
            firstSongIdIs(songU.id) { editAndRestore(a) }
            val copy = songs().single { it.id != openSong.id && it.id != songU.id }
            assertEquals(heldEdits, copy.lyrics)
            for (vm in listOf(a, b)) {
                assertEquals(copy.id, vm.currentProjectId)
                assertEquals(Triple(copy.title, heldEdits, copy.theme), Triple(vm.title, vm.lyrics, vm.theme))
            }
            // Each window's next changed save writes that copy in place; A's goes through its Activity going to the background.
            instrumentation.runOnMainSync { a.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("saved by window A") }
            saveByGoingToTheBackground(copy.id, "saved by window A")
            assertEquals(mapOf(openSong.id to newerWords, songU.id to "u words", copy.id to "saved by window A"), songs().associate { it.id to it.lyrics })
            instrumentation.runOnMainSync { b.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("saved by window B") }
            saveNow(b)
            assertEquals(mapOf(openSong.id to newerWords, songU.id to "u words", copy.id to "saved by window B"), songs().associate { it.id to it.lyrics })
        } finally {
            BackupTestHooks.beforeHeldOperation = null
            resetOpenSong()
        }
    }

    /** The Activity goes to the background, so its lifecycle observer saves the draft; it then comes back. */
    private fun saveByGoingToTheBackground(id: String, words: String) {
        scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
        waitUntil({ "stored ${songs()}" }) { songs().any { it.id == id && it.lyrics == words } }
        scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
        instrumentation.waitForIdleSync()
    }

    /**
     * Window B's edited hold of the same song writes its own ticket over A's before the commit, which keeps B's words.
     * A's ticket names no result: A stays on the song, with no notice, and its next save writes there.
     */
    @Test fun aDifferentTicketForTheSameSongStaysOnTheSourceWithoutANotice() {
        newerOpenSong()
        val a = openSongInEditor(activity = true)
        val b = relaunchedViewModel(openSong.lyrics)
        instrumentation.runOnMainSync { b.showStartMenu = false }
        val first = java.util.concurrent.atomic.AtomicBoolean(true)
        BackupTestHooks.beforeHeldOperation = {
            if (first.compareAndSet(true, false)) {
                b.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("edits in window B")
                b.restoreFromBackup()
                while (b.editorHeld || b.backupStatus !is BackupStatus.Connected) kotlinx.coroutines.delay(20)
            }
        }
        try {
            editAndRestore(a)
            val copy = songs().single { it.id != openSong.id }
            assertEquals("edits in window B", copy.lyrics)
            assertEquals(copy.id to "edits in window B", b.currentProjectId to b.lyrics)
            assertEquals(Triple(openSong.id, newerWords, null), Triple(a.currentProjectId, a.lyrics, a.persistenceError))
            instrumentation.runOnMainSync { a.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("saved by window A") }
            saveByGoingToTheBackground(openSong.id, "saved by window A")
            assertEquals(mapOf(openSong.id to "saved by window A", copy.id to "edits in window B"), songs().associate { it.id to it.lyrics })
        } finally {
            BackupTestHooks.beforeHeldOperation = null
            resetOpenSong()
        }
    }

    private fun replacingZip(): java.io.File = java.io.File(context.cacheDir, "replacing.zip").also { zip ->
        zip.outputStream().use {
            com.rhymeai.app.data.sync.BackupArchive.write(
                it, SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L))),
                emptyList(), 0L, "test"
            )
        }
    }

    private fun importAndWait(vm: MainViewModel, zip: java.io.File) {
        instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(zip)) }
        waitUntil({ "notice ${vm.backupNotice} held ${vm.editorHeld}" }) { vm.backupNotice?.startsWith("Imported") == true && !vm.editorHeld }
        instrumentation.waitForIdleSync()
    }

    /** The copy is open and selected, U is untouched, and the next changed save (through the Activity) writes the copy. */
    private fun assertOnTheActualCopy(vm: MainViewModel, words: String) {
        val copy = songs().single { it.id != openSong.id && it.id != songU.id }
        assertEquals(words, copy.lyrics)
        assertEquals(Triple(copy.id, words, keptNotice), Triple(vm.currentProjectId, vm.lyrics, vm.persistenceError))
        assertEquals(copy.id, runBlocking { repo.currentProjectIdFlow.first() })
        assertEquals(mapOf(openSong.id to newerWords, songU.id to "u words", copy.id to words), songs().associate { it.id to it.lyrics })
        instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("after the import") }
        saveByGoingToTheBackground(copy.id, "after the import")
        assertEquals(mapOf(openSong.id to newerWords, songU.id to "u words", copy.id to "after the import"), songs().associate { it.id to it.lyrics })
    }

    @Test fun anEditedArchiveHoldWithAnOccupiedTicketIdOpensTheActualCopy() {
        val vm = openSongInEditor(otherSongs = listOf(songU), activity = true)
        val zip = replacingZip()
        try {
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(heldEdits) }
            firstSongIdIs(songU.id) { importAndWait(vm, zip) }
            assertOnTheActualCopy(vm, heldEdits)
        } finally {
            zip.delete()
            resetOpenSong()
        }
    }

    /** A flush stored the ticket (asking for U's id) before the app died; the unedited hold reads it. */
    @Test fun anUneditedArchiveHoldReadingAStoredTicketOpensTheActualCopy() {
        val vm = openSongInEditor(otherSongs = listOf(songU), mark = com.rhymeai.app.data.repository.PreservationTicket(songU.id), activity = true)
        val zip = replacingZip()
        try {
            importAndWait(vm, zip)
            assertOnTheActualCopy(vm, openSong.lyrics)
        } finally {
            zip.delete()
            resetOpenSong()
        }
    }

    /** The stored ticket cannot be read before the operation: the commit still keeps the marked words, listed but not opened. */
    @Test fun aTicketReadFailureBeforeTheHoldReloadsTheSourceWithoutANotice() {
        val vm = openSongInEditor(otherSongs = listOf(songU), mark = com.rhymeai.app.data.repository.PreservationTicket(songU.id), activity = true)
        val zip = replacingZip()
        val reads = java.util.concurrent.atomic.AtomicInteger()
        BackupTestHooks.beforeHoldTicketRead = { reads.incrementAndGet(); throw java.io.IOException("injected ticket read failure") }
        try {
            importAndWait(vm, zip)
            assertEquals(1, reads.get())
            assertEquals(Triple(openSong.id, newerWords, null), Triple(vm.currentProjectId, vm.lyrics, vm.persistenceError))
            val copy = songs().single { it.id != openSong.id && it.id != songU.id }
            assertEquals(mapOf(openSong.id to newerWords, songU.id to "u words", copy.id to openSong.lyrics), songs().associate { it.id to it.lyrics })
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("after the import") }
            saveByGoingToTheBackground(openSong.id, "after the import")
            assertEquals(mapOf(openSong.id to "after the import", songU.id to "u words", copy.id to openSong.lyrics), songs().associate { it.id to it.lyrics })
        } finally {
            BackupTestHooks.beforeHoldTicketRead = null
            zip.delete()
            resetOpenSong()
        }
    }

    /** A follows its own copy without taking the durable selection or the raw editor fields another window or the commit set. */
    @Test fun holdReloadLeavesOtherWindowsSelectionAndRawDraftAlone() {
        val songB = SongProject("song-b", "Song B", "b words", "", 100L)
        newerOpenSong()
        val vm = openSongInEditor(activity = true, otherSongs = listOf(songB))
        // Another window selects B after A's draft save and leaves a raw draft with an empty title.
        BackupTestHooks.beforeHeldOperation = { repo.selectProject(songB.id); repo.saveEditorState("", "b raw draft", "b theme") }
        try {
            editAndRestore(vm)
            val copy = songs().single { it.id != openSong.id && it.id != songB.id }
            assertEquals(copy.id to heldEdits, vm.currentProjectId to vm.lyrics)
            // Before A saves again.
            assertEquals(songB.id, runBlocking { repo.currentProjectIdFlow.first() })
            assertEquals(Triple("", "b raw draft", "b theme"), runBlocking { repo.editorStateFlow().first() })
        } finally {
            BackupTestHooks.beforeHeldOperation = null
        }
        // Another window's saved draft of the song differs from A's edits: the commit keeps it as its own song and selects it.
        newerOpenSong()
        val second = openSongAgain(activity = true)
        BackupTestHooks.beforeHeldOperation = { repo.saveEditorState(openSong.title, "other window draft", "") }
        try {
            editAndRestore(second)
            val copy = songs().single { it.lyrics == heldEdits }
            val editorCopy = songs().single { it.lyrics == "other window draft" }
            assertEquals(copy.id to heldEdits, second.currentProjectId to second.lyrics)
            assertEquals(editorCopy.id, runBlocking { repo.currentProjectIdFlow.first() })
            assertEquals(Triple(openSong.title, "other window draft", ""), runBlocking { repo.editorStateFlow().first() })
        } finally {
            BackupTestHooks.beforeHeldOperation = null
            resetOpenSong()
        }
    }

    @Test fun reuseAndClaimReadFailureReportOnlyWhatCommitted() {
        // The incoming backup already holds the held words under the id the hold asked for: that row is reused, silently.
        putDriveSongs(SyncBlob(projects = listOf(
            openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L),
            SongProject("reuse-x", openSong.title, heldEdits, "", 100L)
        )))
        val vm = openSongInEditor(activity = true)
        try {
            firstSongIdIs("reuse-x") { editAndRestore(vm) }
            assertEquals("reuse-x" to heldEdits, vm.currentProjectId to vm.lyrics)
            assertEquals(null, vm.persistenceError)
            assertEquals(mapOf(openSong.id to newerWords, "reuse-x" to heldEdits), songs().associate { it.id to it.lyrics })

            // The result cannot be read: the open words stay and are kept apart; U, at the requested id, is never selected.
            newerOpenSong()
            val failed = openSongAgain(activity = true, otherSongs = listOf(songU))
            BackupTestHooks.beforeHoldResolve = { throw java.io.IOException("injected read failure") }
            firstSongIdIs(songU.id) { editAndRestore(failed) }
            BackupTestHooks.beforeHoldResolve = null
            assertEquals(heldEdits, failed.lyrics)
            assertTrue("${failed.persistenceError}", failed.persistenceError.orEmpty().contains("could not be reread"))
            assertTrue(failed.currentProjectId != songU.id && runBlocking { repo.currentProjectIdFlow.first() } != songU.id)
            assertEquals("u words", songs().single { it.id == songU.id }.lyrics)

            // The result was read and the song list refresh fails: the editor stays on the copy and its next save writes it in place.
            newerOpenSong()
            val refreshed = openSongAgain(activity = true, otherSongs = listOf(songU))
            BackupTestHooks.beforeHoldListRefresh = { throw java.io.IOException("injected list failure") }
            firstSongIdIs(songU.id) { editAndRestore(refreshed) }
            BackupTestHooks.beforeHoldListRefresh = null
            val copy = songs().single { it.id != openSong.id && it.id != songU.id }
            assertEquals(copy.id to heldEdits, refreshed.currentProjectId to refreshed.lyrics)
            assertEquals(keptNotice, refreshed.persistenceError)
            saveNow(refreshed)
            assertEquals(mapOf(openSong.id to newerWords, songU.id to "u words", copy.id to heldEdits), songs().associate { it.id to it.lyrics })
        } finally {
            BackupTestHooks.beforeHoldResolve = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** The kept copy is a row the library already had, with the same words: the editor opens it as that song. */
    @Test fun adoptingAReusedRowWithTheSameWordsOpensItAsThatSong() {
        val reused = SongProject("reuse-x", "Untitled Song", heldEdits, "", 100L)
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L), reused)))
        val position = com.rhymeai.app.data.model.SongWorkspace(selectionStart = 3, selectionEnd = 7, scrollOffset = 55f)
        val vm = openSongInEditor(activity = true, otherSongs = listOf(reused), workspaces = mapOf(reused.id to position))
        try {
            val opened = vm.openRevision
            // A's edits: an empty raw title and new words, undoable.
            instrumentation.runOnMainSync {
                vm.onTitleChanged("")
                vm.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue(heldEdits))
            }
            assertTrue(vm.canUndoLyrics)
            // The kept copy asks for the reused row's id; that row already holds the same title, words and theme.
            firstSongIdIs(reused.id) {
                instrumentation.runOnMainSync { vm.restoreFromBackup() }
                waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
                instrumentation.waitForIdleSync()
            }
            assertEquals(mapOf(openSong.id to newerWords, reused.id to heldEdits), songs().associate { it.id to it.lyrics })
            assertEquals(reused.id, vm.currentProjectId)
            assertEquals(androidx.compose.ui.text.TextRange(3, 7) to 55f, vm.lyricsFieldValue.selection to vm.editorScrollOffset)
            assertEquals(Triple(reused.title, reused.lyrics, reused.theme), Triple(vm.title, vm.lyrics, vm.theme))
            assertTrue(vm.openRevision > opened)
            assertFalse(vm.canUndoLyrics)
            assertEquals(null, vm.persistenceError)
        } finally {
            resetOpenSong()
        }
    }

    /** Another window trashes the copy while A refreshes its list after adopting it: A's next save keeps its words as a new song. */
    @Test fun aCopyTrashedDuringTheListRefreshIsNotSavedOverByTheNextSave() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        BackupTestHooks.beforeHoldListRefresh = {
            BackupTestHooks.beforeHoldListRefresh = null
            repo.moveProjectToTrash(repo.projectsFlow.first().single { it.id != openSong.id }.id, System.currentTimeMillis())
        }
        try {
            editAndRestore(vm)
            val copy = runBlocking { repo.trashedProjectsFlow.first() }.single().project
            assertEquals(heldEdits, copy.lyrics)
            assertEquals(heldEdits, vm.lyrics)
            saveNow(vm)
            val kept = songs().filter { it.lyrics == heldEdits }
            assertEquals(1, kept.size)
            assertTrue(kept.single().id != copy.id)
            assertEquals(newerWords, storedOpenSong().lyrics)
            assertEquals(copy, runBlocking { repo.trashedProjectsFlow.first() }.single().project)
            assertEquals(kept.single().id, vm.currentProjectId)
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** During the list refresh another window trashes the copy and a sync brings back a different song at its id. */
    @Test fun aCopyReplacedDuringTheListRefreshIsNotSavedOverByTheNextSave() {
        newerOpenSong()
        val vm = openSongInEditor()
        val other = "other words at the copy's id"
        BackupTestHooks.beforeHoldListRefresh = {
            BackupTestHooks.beforeHoldListRefresh = null
            val copy = repo.projectsFlow.first().single { it.id != openSong.id }
            repo.moveProjectToTrash(copy.id, System.currentTimeMillis())
            repo.saveProjects(repo.projectsFlow.first() + SongProject(copy.id, "Other Song", other, "", System.currentTimeMillis()))
        }
        try {
            editAndRestore(vm)
            val copyId = runBlocking { repo.trashedProjectsFlow.first() }.single().project.id
            saveNow(vm)
            assertEquals(other, songs().single { it.id == copyId }.lyrics)
            assertEquals(newerWords, storedOpenSong().lyrics)
            // The held words are saved as a new song by the save that follows the refused one.
            waitUntil({ "stored ${songs()}" }) { songs().any { it.lyrics == heldEdits } && !vm.savingBeforeNavigation }
            val kept = songs().filter { it.lyrics == heldEdits }
            assertEquals("${songs()}", 1, kept.size)
            assertEquals(kept.single().id to heldEdits, vm.currentProjectId to vm.lyrics)
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    private val windowBWords = "words window B wrote in place"
    private val changedNotice = "This song was changed elsewhere while it was being restored. Your draft stays open and will be saved as a new song."

    /** Window B edits the kept copy in place (same id and generation, new words) and keeps a line in its notebook; returns its id. */
    private suspend fun editCopyInPlaceInWindowB(): String {
        val copy = repo.projectsFlow.first().single { it.id != openSong.id && it.id != songY.id }
        repo.saveActiveState(copy.copy(lyrics = windowBWords), null, copy.title, windowBWords, copy.theme)
        repo.saveWorkspace(copy.id, (repo.workspacesFlow.first()[copy.id] ?: com.rhymeai.app.data.model.SongWorkspace()).keep("window B line", 1L))
        return copy.id
    }

    /** Every stored row as (id, words), repeats kept, against [expected]. */
    private fun assertRows(vararg expected: Pair<String, String>) =
        assertEquals(expected.sortedBy { it.first }, songs().map { it.id to it.lyrics }.sortedBy { it.first })

    /** Window B's words and notebook line are still at the copy, and none of window A's [aWords] went there. */
    private fun assertWindowBKeptTheCopy(copyId: String, aWords: String) {
        assertEquals(windowBWords, songs().single { it.id == copyId }.lyrics)
        val notebook = runBlocking { repo.workspacesFlow.first() }[copyId]
        assertTrue("$notebook", notebook?.alternates.orEmpty().any { it.text == "window B line" })
        assertTrue("$notebook", notebook?.versions.orEmpty().none { it.lyrics == aWords })
    }

    /** During the list refresh another window edits the copy in place; the held editor's first save then runs. */
    @Test fun aCopyEditedInPlaceDuringTheListRefreshKeepsBothWritersWords() {
        newerOpenSong()
        val vm = openSongInEditor()
        val typed = "typed in window A after the hold"
        BackupTestHooks.beforeHoldListRefresh = {
            BackupTestHooks.beforeHoldListRefresh = null
            editCopyInPlaceInWindowB()
        }
        try {
            editAndRestore(vm)
            assertEquals(heldEdits, vm.lyrics)
            // K0: the refresh found the copy changed, so the held words were kept as one new song before the editor was released.
            val early = songs().filter { it.lyrics == heldEdits }
            assertEquals("${songs()}", 1, early.size)
            assertEquals(early.single().id, vm.currentProjectId)
            val copyId = songs().single { it.lyrics == windowBWords }.id
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(typed) }
            saveNow(vm)
            assertWindowBKeptTheCopy(copyId, typed)
            waitUntil({ "stored ${songs()}" }) { songs().any { it.lyrics == typed } && !vm.savingBeforeNavigation }
            val kept = songs().single { it.lyrics == typed }
            assertEquals(early.single().id, kept.id)
            assertEquals(mapOf(openSong.id to newerWords, copyId to windowBWords, kept.id to typed), songs().associate { it.id to it.lyrics })
            assertEquals(Triple(kept.id, typed, changedNotice), Triple(vm.currentProjectId, vm.lyrics, vm.persistenceError))
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** The same edit by another window, with the first save being the lifecycle save queued while held: nothing typed. */
    @Test fun aCopyEditedInPlaceDuringTheListRefreshIsNotOverwrittenByTheQueuedSaveAtRelease() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        val reached = kotlinx.coroutines.CompletableDeferred<Unit>()
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        BackupTestHooks.beforeHoldListRefresh = {
            BackupTestHooks.beforeHoldListRefresh = null
            reached.complete(Unit)
            gate.await()
        }
        try {
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(heldEdits)
                vm.restoreFromBackup()
            }
            waitUntil({ "held ${vm.editorHeld} status ${vm.backupStatus}" }) { reached.isCompleted }
            var copyId: String? = null
            instrumentation.runOnMainSync { copyId = vm.currentProjectId }
            runBlocking { editCopyInPlaceInWindowB() }
            // Going to the background while held: the lifecycle observer's save waits for the hold to end.
            scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            gate.complete(Unit)
            waitUntil({ "stored ${songs()} held ${vm.editorHeld}" }) {
                !vm.editorHeld && !vm.savingBeforeNavigation && songs().any { it.lyrics == heldEdits }
            }
            assertWindowBKeptTheCopy(checkNotNull(copyId), heldEdits)
            assertEquals(newerWords, storedOpenSong().lyrics)
            val kept = songs().filter { it.lyrics == heldEdits }
            assertEquals("${songs()}", 1, kept.size)
            assertEquals(kept.single().id to heldEdits, vm.currentProjectId to vm.lyrics)
            scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            gate.complete(Unit)
            resetOpenSong()
        }
    }

    /** The hold's result is read while two stored rows share the song's id, and the list refresh then fails. */
    @Test fun aMissOnASongStoredTwiceKeepsBothRowsInTheList() {
        newerOpenSong()
        val vm = openSongInEditor()
        val twin = SongProject(openSong.id, "Twin", "twin words", "", 50L)
        BackupTestHooks.beforeHoldResolve = {
            BackupTestHooks.beforeHoldResolve = null
            repo.saveProjects(repo.projectsFlow.first() + twin)
            while (vm.projects.count { it.id == openSong.id } < 2) kotlinx.coroutines.delay(20)
        }
        BackupTestHooks.beforeHoldListRefresh = {
            BackupTestHooks.beforeHoldListRefresh = null
            throw java.io.IOException("injected refresh failure")
        }
        try {
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            instrumentation.waitForIdleSync()
            val stored = songs().filter { it.id == openSong.id }
            assertEquals(listOf(newerWords, twin.lyrics), stored.map { it.lyrics })
            assertEquals(stored, vm.projects.filter { it.id == openSong.id })
            assertEquals(newerWords, vm.lyrics)
        } finally {
            BackupTestHooks.beforeHoldResolve = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun movedThenReintroducedIdenticalWordsDoNotSatisfyOldReceipt() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        // After the commit and before A reads its result, the copy goes to Trash and a newer incoming copy with the same words comes back.
        BackupTestHooks.beforeHoldResolve = {
            val copy = repo.projectsFlow.first().single { it.id != openSong.id }
            repo.moveProjectToTrash(copy.id, System.currentTimeMillis())
            repo.applySyncResult(
                SyncBlob(projects = repo.projectsFlow.first() + copy.copy(updatedAt = System.currentTimeMillis() + 7_200_000L)),
                repo.snapshotLocalSyncBase()
            )
        }
        try {
            editAndRestore(vm)
            val back = songs().single { it.id != openSong.id }
            assertEquals(heldEdits, back.lyrics)
            assertEquals(openSong.id to newerWords, vm.currentProjectId to vm.lyrics)
            assertEquals(null, vm.persistenceError)
            saveNow(vm)
            assertEquals(back, songs().single { it.id == back.id })
            assertEquals(newerWords, storedOpenSong().lyrics)
        } finally {
            BackupTestHooks.beforeHoldResolve = null
            resetOpenSong()
        }
    }

    @Test fun targetEditedBeforeClaimCannotBeReplayed() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        // Another window edits the copy before A reads its result.
        BackupTestHooks.beforeHoldResolve = {
            val copy = repo.projectsFlow.first().single { it.id != openSong.id }
            repo.saveActiveState(copy.copy(lyrics = "edited elsewhere"), null, copy.title, "edited elsewhere", copy.theme)
        }
        try {
            editAndRestore(vm)
            val edited = songs().single { it.id != openSong.id }
            assertEquals("edited elsewhere", edited.lyrics)
            assertEquals(openSong.id to newerWords, vm.currentProjectId to vm.lyrics)

            // Edited away and back to the kept words before A reads its result.
            val laterWords = "newer words W3"
            newerOpenSong(laterWords, aheadMillis = 7_200_000L)
            BackupTestHooks.beforeHoldResolve = {
                val copy = repo.projectsFlow.first().single { it.lyrics == "second edits" }
                repo.saveActiveState(copy.copy(lyrics = "away"), null, copy.title, "away", copy.theme)
                repo.saveActiveState(copy, null, copy.title, copy.lyrics, copy.theme)
            }
            editAndRestore(vm, "second edits")
            BackupTestHooks.beforeHoldResolve = null
            val roundTrip = songs().single { it.lyrics == "second edits" }
            assertEquals(openSong.id to laterWords, vm.currentProjectId to vm.lyrics)
            saveNow(vm)
            assertEquals(mapOf(openSong.id to laterWords, edited.id to "edited elsewhere", roundTrip.id to "second edits"), songs().associate { it.id to it.lyrics })
        } finally {
            BackupTestHooks.beforeHoldResolve = null
            resetOpenSong()
        }
    }

    @Test fun preservationCommitIsAtomicAndRelaunchUsesStoredSelection() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        val committed = kotlinx.coroutines.CompletableDeferred<Triple<String?, Triple<String, String, String>, List<SongProject>>>()
        // Read right after the commit, before this hold reloads anything; then the window dies there (the reload runs
        // non-cancellable, so the death is thrown into it).
        val death = kotlinx.coroutines.CompletableDeferred<Unit>()
        BackupTestHooks.beforeHoldResolve = {
            committed.complete(Triple(repo.currentProjectIdFlow.first(), repo.editorStateFlow().first(), repo.projectsFlow.first()))
            death.await()
        }
        try {
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(heldEdits)
                vm.restoreFromBackup()
            }
            val (selected, editor, stored) = runBlocking { withTimeout(30_000) { committed.await() } }
            BackupTestHooks.beforeHoldResolve = null
            val copy = stored.single { it.id != openSong.id }
            assertEquals(heldEdits, copy.lyrics)
            assertEquals(copy.id, selected)
            assertEquals(Triple(openSong.title, heldEdits, ""), editor)
            assertEquals(null, runBlocking { repo.preservedTicket(openSong.id) })
            // The window closes while its reload waits (ON_STOP's save waits for the hold); the reload then dies with it.
            scenario?.close()
            death.completeExceptionally(kotlinx.coroutines.CancellationException("window closed"))
            waitUntil({ "held ${vm.editorHeld}" }) { !vm.editorHeld }
            lateinit var fresh: MainViewModel
            scenario = ActivityScenario.launch(MainActivity::class.java).also { s -> s.onActivity { fresh = ViewModelProvider(it)[MainViewModel::class.java] } }
            waitUntil({ "id ${fresh.currentProjectId} lyrics ${fresh.lyrics}" }) { fresh.currentProjectId == copy.id && fresh.lyrics == heldEdits }
            instrumentation.runOnMainSync {
                fresh.showStartMenu = false
                fresh.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("after relaunch")
            }
            saveNow(fresh)
            assertEquals(mapOf(openSong.id to newerWords, copy.id to "after relaunch"), songs().associate { it.id to it.lyrics })
        } finally {
            BackupTestHooks.beforeHoldResolve = null
            death.completeExceptionally(kotlinx.coroutines.CancellationException("test ended"))
            resetOpenSong()
        }
    }

    /** A mark a dead window left cannot be read: the unedited hold has no ticket and shows the song's new words, with no notice. */
    @Test fun aMarkReadFailureBeforeTheHoldReloadsTheSourceWithoutANotice() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true, otherSongs = listOf(songU))
        val marks = androidx.datastore.preferences.core.stringPreferencesKey("preserved_songs_json")
        runBlocking { context.dataStore.edit { it[marks] = "{not json" } }
        try {
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertEquals(openSong.id to newerWords, vm.currentProjectId to vm.lyrics)
            assertEquals(null, vm.persistenceError)
            assertEquals(mapOf(openSong.id to newerWords, songU.id to "u words"), songs().associate { it.id to it.lyrics })
        } finally {
            runBlocking { context.dataStore.edit { it.remove(marks) } }
            resetOpenSong()
        }
    }

    @Test fun aRetriedImportAfterAPreservingCommitMakesNoSecondCopy() {
        val vm = openSongInEditor(activity = true)
        val zip = java.io.File(context.cacheDir, "retried.zip")
        zip.outputStream().use {
            com.rhymeai.app.data.sync.BackupArchive.write(
                it, SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L))),
                emptyList(), 0L, "test"
            )
        }
        fun import() {
            instrumentation.runOnMainSync { vm.importBackup(android.net.Uri.fromFile(zip)) }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice?.startsWith("Imported") == true && !vm.editorHeld }
            instrumentation.waitForIdleSync()
        }
        try {
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(heldEdits) }
            import()
            val copy = songs().single { it.id != openSong.id }
            assertEquals(copy.id to heldEdits, vm.currentProjectId to vm.lyrics)
            assertEquals(keptNotice, vm.persistenceError)
            import()
            assertEquals(mapOf(openSong.id to newerWords, copy.id to heldEdits), songs().associate { it.id to it.lyrics })
            assertEquals(copy.id to heldEdits, vm.currentProjectId to vm.lyrics)
            assertEquals(keptNotice, vm.persistenceError)
        } finally {
            zip.delete()
            resetOpenSong()
        }
    }

    /** An older install saved editor words apart from the song; startup shows them. A restore from the start menu keeps them. */
    @Test fun aRestoreFromTheStartMenuKeepsEditorWordsSavedApartFromTheSongAsANewSong() {
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L))))
        openSongInEditor()
        runBlocking { repo.saveEditorState(openSong.title, "legacy draft words", openSong.theme) }
        val vm = relaunchedViewModel("legacy draft words")
        try {
            assertTrue(vm.showStartMenu)
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertEquals(newerWords, storedOpenSong().lyrics)
            assertEquals("legacy draft words", runBlocking { repo.projectsFlow.first() }.single { it.id != openSong.id }.lyrics)
        } finally {
            resetOpenSong()
        }
    }

    @Test fun aNewSongStartedWhenTheRestoreCommitsFinishesFirst() {
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L))))
        val vm = openSongInEditor()
        val selectionSave = kotlinx.coroutines.CompletableDeferred<Unit>()
        val downloaded = java.util.concurrent.atomic.AtomicBoolean(false)
        drive.beforeDownload = { downloaded.set(true) }
        try {
            NewSongTestHooks.beforeSelectionSave = selectionSave
            instrumentation.runOnMainSync { vm.newProject() }
            waitUntil({ "id ${vm.currentProjectId} lyrics ${vm.lyrics}" }) { vm.currentProjectId == null && vm.lyrics.isEmpty() }
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil { downloaded.get() }
            SystemClock.sleep(700)
            // The restore reached its commit but waits: New Song has not stored its selection yet.
            assertFalse(vm.editorHeld)
            assertEquals(openSong.lyrics, storedOpenSong().lyrics)
            selectionSave.complete(Unit)
            waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertEquals(newerWords, storedOpenSong().lyrics)
            assertEquals(null to "", vm.currentProjectId to vm.lyrics)
            assertEquals(null, runBlocking { repo.currentProjectIdFlow.first() })
        } finally {
            NewSongTestHooks.beforeSelectionSave = null
            selectionSave.complete(Unit)
            drive.beforeDownload = null
            resetOpenSong()
        }
    }

    @Test fun aRestoreRefusedAfterItsRecordingArrivedEndsWithOneTakeAfterTheRetry() {
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, android.Manifest.permission.RECORD_AUDIO)
        val audio = TestRecordings.recordFinalizedM4a(context, java.io.File(context.cacheDir, "drive-take.m4a")).readBytes()
        val take = com.rhymeai.app.data.sync.RecordingManifestEntry(
            openSong.id, "take.m4a", sizeBytes = audio.size.toLong(), modifiedAt = 0L,
            sha256 = BackupManifest.sha256Hex(audio), uploadedAt = 1_000L, id = "5e4d3c2b-1a09-4f8e-9d7c-6b5a4f3e2d1c"
        )
        drive.put(BackupManifest.recordingDriveName(take.id), audio)
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = 200L)), recordings = listOf(take)))
        val vm = openSongInEditor()
        val memoDir = com.rhymeai.app.data.recording.RecordingFiles.memoDirectory(context.filesDir, openSong.id)
        fun takes() = runBlocking { repo.recordingRecords() }.filter { it.projectId == openSong.id && it.trashedAt == null && it.path != null }
        try {
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue("unsaved edit")
                DraftSaveTestHooks.failNext.set(true)
                vm.restoreFromBackup()
            }
            waitUntil({ "notice ${vm.backupNotice}" }) { vm.backupNotice == refusedNotice }
            assertEquals("the take arrived before the refusal", 1, takes().size)
            assertEquals(openSong.lyrics, storedOpenSong().lyrics)
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "notice ${vm.backupNotice} held ${vm.editorHeld}" }) {
                vm.backupNotice != null && vm.backupNotice != refusedNotice && !vm.editorHeld
            }
            instrumentation.waitForIdleSync()
            // The edit saved by the retry is newer than the Drive copy, so it stays.
            assertEquals("unsaved edit", storedOpenSong().lyrics)
            val kept = takes()
            assertEquals("$kept", 1, kept.size)
            val file = com.rhymeai.app.data.recording.RecordingFiles.containedRecordingFile(context.filesDir, kept.single().path!!)
            assertTrue("the take plays the Drive bytes", audio.contentEquals(file?.readBytes()))
            assertEquals(1, memoDir.listFiles().orEmpty().count { it.isFile && it.extension == "m4a" })
        } finally {
            DraftSaveTestHooks.failNext.set(false)
            memoDir.deleteRecursively()
            runCatching { runBlocking { repo.updateRecordingRecords { records -> records.filterNot { it.projectId == openSong.id } } } }
            resetOpenSong()
        }
    }

    @Test fun aRestoreThatTrashesTheOpenSongClearsTheEditor() {
        putDriveSongs(SyncBlob(trashed = listOf(TrashedSongProject(openSong, deletedAt = 200L))))
        val vm = openSongInEditor()
        try {
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "status ${vm.backupStatus}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            instrumentation.waitForIdleSync()
            assertTrue("trashed", runBlocking { repo.trashedProjectsFlow.first() }.any { it.project.id == openSong.id })
            assertTrue("not active", runBlocking { repo.projectsFlow.first() }.none { it.id == openSong.id })
            assertEquals(Triple<String?, String, String>(null, "", ""), Triple(vm.currentProjectId, vm.title, vm.lyrics))
            assertEquals(null, vm.persistenceError)
        } finally {
            resetOpenSong()
        }
    }

    // S0a round 4 (ruling 4 accepted parts): K4(b), K6(a), K7(b), K9, K10, K12, K13. Nothing here asserts the shared editor keys.

    /** The held list refresh runs [during] (another window), then fails: the adoption stays unconfirmed. */
    private fun failingRefresh(during: suspend () -> Unit = {}) {
        BackupTestHooks.beforeHoldListRefresh = {
            BackupTestHooks.beforeHoldListRefresh = null
            during()
            throw java.io.IOException("injected list refresh failure")
        }
    }

    private fun notebook(id: String) = runBlocking { repo.workspacesFlow.first() }[id] ?: com.rhymeai.app.data.model.SongWorkspace()
    private fun hasLine(id: String, text: String) = notebook(id).alternates.any { it.text == text }
    private suspend fun addWindowBLine(id: String) =
        repo.saveWorkspace(id, (repo.workspacesFlow.first()[id] ?: com.rhymeai.app.data.model.SongWorkspace()).keep("window B line", 1L))
    private fun <T> onMain(read: () -> T): T { var value: Any? = null; instrumentation.runOnMainSync { value = read() }; @Suppress("UNCHECKED_CAST") return value as T }

    /** A's edits equal the reused row's words (empty title), and the restore adopts that row. */
    private fun adoptReused(vm: MainViewModel, reused: SongProject) {
        instrumentation.runOnMainSync {
            vm.onTitleChanged("")
            vm.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue(reused.lyrics))
        }
        firstSongIdIs(reused.id) {
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            instrumentation.waitForIdleSync()
        }
        assertEquals(reused.id, vm.currentProjectId)
    }

    private fun driveWithReused(reused: SongProject) =
        putDriveSongs(SyncBlob(projects = listOf(openSong.copy(lyrics = newerWords, updatedAt = System.currentTimeMillis() + 3_600_000L), reused)))

    private val longWords = (1..120).joinToString("\n") { "line $it of the reused song" }

    /** K13(a): the rounded seed of an equal-words adoption is not written; another window's line stays. */
    @Test fun anAdoptedSameWordsSongWritesNoPositionForItsRestoredSeed() = adoptedPositionLeg(storedOffset = 41.3f, clamped = false)

    /** K13(b): a clamped first position of that adoption is stored by itself; another window's line stays. */
    @Test fun anAdoptedSameWordsSongStoresAClampedPositionWithoutItsCachedNotebook() = adoptedPositionLeg(storedOffset = 100_000f, clamped = true)

    private fun adoptedPositionLeg(storedOffset: Float, clamped: Boolean) {
        val reused = SongProject("reuse-x", "Untitled Song", longWords, "", 100L)
        driveWithReused(reused)
        val seed = com.rhymeai.app.data.model.SongWorkspace(selectionStart = 3, selectionEnd = 7, scrollOffset = storedOffset)
        val vm = openSongInEditor(activity = true, otherSongs = listOf(reused), workspaces = mapOf(reused.id to seed))
        val events = java.util.concurrent.ConcurrentLinkedQueue<Pair<Int, String>>()
        // Only what happens once the editor is released (the hook runs on the main thread).
        PositionTestHooks.onEvent = { from, revision, event -> if (from === vm && !from.editorHeld) events += revision to event }
        val density = context.resources.displayMetrics.density
        // Confirmed adoption: the refresh sees the row unchanged; another window keeps a line in its notebook first.
        BackupTestHooks.beforeHoldListRefresh = { BackupTestHooks.beforeHoldListRefresh = null; addWindowBLine(reused.id) }
        try {
            if (!clamped) assertTrue("$storedOffset survives the px round trip", kotlin.math.round(storedOffset * density) / density != storedOffset)
            adoptReused(vm, reused)
            val revision = onMain { vm.openRevision }
            compose.onNodeWithTag("editorScrollContainer").assertExists()
            val range = compose.onNodeWithTag("editorScrollContainer").fetchSemanticsNode()
                .config[androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange]
            val maxDp = range.maxValue() / context.resources.displayMetrics.density
            if (clamped) assertTrue("stored $storedOffset beyond the measured range $maxDp", storedOffset > maxDp + 1f)
            else assertTrue("stored $storedOffset inside the measured range $maxDp", storedOffset < maxDp - 1f)
            fun count(event: String) = events.count { it == revision to event }
            // Checked on the main thread, where each emission reaches, schedules and settles its job.
            // The editor's emission after release, processed on the main thread; then every job it scheduled has ended.
            waitUntil({ "$events" }) { onMain { count("reached") >= 1 } }
            if (clamped) waitUntil({ "$events" }) { onMain { count("wrote") >= 1 && count("settled") == count("scheduled") } }
            else assertEquals("$events", 0, onMain { count("scheduled") })
            instrumentation.waitForIdleSync()
            assertTrue("window B's line was written over: ${notebook(reused.id)}", hasLine(reused.id, "window B line"))
            val stored = notebook(reused.id)
            if (clamped) {
                val rendered = compose.onNodeWithTag("editorScrollContainer").fetchSemanticsNode()
                    .config[androidx.compose.ui.semantics.SemanticsProperties.VerticalScrollAxisRange].value() / density
                assertTrue("clamped $rendered", rendered < storedOffset)
                assertEquals(rendered, stored.scrollOffset, 1f)
                assertEquals("$events", 1, count("wrote"))
            } else {
                assertEquals("$events", 0, count("wrote"))
                assertEquals(androidx.compose.ui.text.TextRange(3, 7) to storedOffset, onMain { vm.lyricsFieldValue.selection to vm.editorScrollOffset })
                assertEquals(storedOffset, stored.scrollOffset)
            }
        } finally {
            PositionTestHooks.onEvent = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K4(b): a version restore on an unconfirmed adoption another window changed writes neither its checkpoint nor its words there. */
    @Test fun aVersionRestoreOnAChangedUnconfirmedAdoptionKeepsTheCheckpointOffThatSong() {
        val reused = SongProject("reuse-x", "Untitled Song", heldEdits, "", 100L)
        driveWithReused(reused)
        val v1 = com.rhymeai.app.data.model.DraftVersion(title = "Untitled Song", lyrics = "version one words", theme = "", createdAt = 50L)
        val vm = openSongInEditor(otherSongs = listOf(reused), workspaces = mapOf(reused.id to com.rhymeai.app.data.model.SongWorkspace(versions = listOf(v1))))
        failingRefresh { editCopyInPlaceInWindowB() }
        try {
            adoptReused(vm, reused)
            assertTrue("v1 is in A's notebook", onMain { vm.songWorkspace.versions.any { it.lyrics == v1.lyrics } })
            instrumentation.runOnMainSync { vm.restoreDraftVersion(v1) }
            waitUntil({ "stored ${songs()}" }) { songs().any { it.lyrics == v1.lyrics } && !onMain { vm.restoringDraft } }
            instrumentation.waitForIdleSync()
            // The words and the notebook are asserted apart: the later word save may itself be refused.
            assertEquals(windowBWords, songs().single { it.id == reused.id }.lyrics)
            val x = notebook(reused.id)
            assertTrue("$x", x.alternates.any { it.text == "window B line" })
            assertTrue("the checkpoint was written to X: $x", x.versions.none { it.lyrics == heldEdits })
            // N is the one row that is neither the source nor X; the source keeps W2.
            val n = songs().single { it.id != openSong.id && it.id != reused.id }
            assertEquals(v1.lyrics, n.lyrics)
            assertEquals(newerWords, storedOpenSong().lyrics)
            assertTrue("${notebook(n.id)}", notebook(n.id).versions.any { it.lyrics == heldEdits })
            // K4(c): X opened again; its next position is stored without the refused notebook A held for it.
            instrumentation.runOnMainSync { vm.loadProject(songs().single { it.id == reused.id }) }
            waitUntil({ "on ${vm.currentProjectId}" }) { onMain { vm.currentProjectId == reused.id && vm.lyrics == windowBWords && !vm.editorHeld } }
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = vm.lyricsFieldValue.copy(selection = androidx.compose.ui.text.TextRange(7, 9))
                vm.rememberEditorPosition()
            }
            waitUntil({ "${notebook(reused.id)}" }) { notebook(reused.id).let { it.selectionStart == 7 && it.selectionEnd == 9 } }
            assertTrue("${notebook(reused.id)}", hasLine(reused.id, "window B line"))
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K6(a): a line sent from the menu to an unconfirmed adoption is its own write; the next save of that song still goes there. */
    @Test fun aLineSentFromTheMenuToAnUnconfirmedAdoptionLetsTheNextSaveWriteThatSong() {
        newerOpenSong()
        val vm = openSongInEditor()
        val line = runBlocking { vm.oneLinersStore.add("a sent line") }
        failingRefresh()
        try {
            editAndRestore(vm)
            val copy = songs().single { it.id != openSong.id }
            instrumentation.runOnMainSync { vm.showStartMenu = true }
            val sent = kotlinx.coroutines.CompletableDeferred<String>()
            instrumentation.runOnMainSync { vm.sendOneLinerToSong(line, copy) { sent.complete(it) } }
            runBlocking { withTimeout(10_000) { sent.await() } }
            // On disk before the editor text is replaced: the line is in the song and marked used there.
            assertTrue(songs().single { it.id == copy.id }.lyrics.contains("a sent line"))
            assertEquals(copy.id, runBlocking { vm.oneLinersStore.all() }.single { it.id == line.id }.usedInProjectId)
            val typed = "typed after the send"
            instrumentation.runOnMainSync {
                vm.showStartMenu = false
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(typed)
            }
            saveNow(vm)
            assertRows(openSong.id to newerWords, copy.id to typed)
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            try {
                runBlocking {
                    vm.oneLinersStore.trash(line.id)
                    assertTrue("the seeded line was deleted", vm.oneLinersStore.permanentlyDelete(line.id))
                }
            } finally {
                resetOpenSong()
            }
        }
    }

    /** K7(b): Record on an adoption whose song went to the Trash keeps the draft as one new song and starts no take. */
    @Test fun recordingOnAnAdoptionMovedToTheTrashKeepsTheDraftAndStartsNoTake() {
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, android.Manifest.permission.RECORD_AUDIO)
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        val gate = java.util.concurrent.atomic.AtomicInteger()
        RecordingTestHooks.onSaveGate = { if (it === vm) gate.incrementAndGet() }
        failingRefresh()
        val w3 = "W3 open when Record was tapped"
        try {
            editAndRestore(vm)
            val copy = songs().single { it.id != openSong.id }
            // Direct assignment arms no autosave; no other writer runs.
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(w3) }
            runBlocking { repo.moveProjectToTrash(copy.id, System.currentTimeMillis()) }
            val recordsBefore = runBlocking { repo.recordingRecords() }.map { it.id }.toSet()
            compose.onNodeWithTag("micButton").performClick()
            waitUntil({ "gate ${gate.get()}" }) { gate.get() == 1 }
            // The refusal has completed: the editor reported that recording did not start.
            waitForText(context.getString(com.rhymeai.app.R.string.voice_memo_record_failed))
            waitUntil({ "stored ${songs()}" }) { songs().any { it.lyrics == w3 } }
            instrumentation.waitForIdleSync()
            assertEquals("${songs()}", 1, songs().count { it.lyrics == w3 })
            assertFalse(onMain { vm.voiceMemoService.isRecording })
            assertEquals(recordsBefore, runBlocking { repo.recordingRecords() }.map { it.id }.toSet())
            assertTrue(songs().none { it.id == copy.id })
        } finally {
            RecordingTestHooks.onSaveGate = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    private val whitespaceDraft = "  \n  "

    /** The open draft is blank but for [lyrics]; direct assignment arms no autosave. */
    private fun blankDraft(vm: MainViewModel, lyrics: String) = instrumentation.runOnMainSync {
        vm.title = ""
        vm.theme = ""
        vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(lyrics)
    }

    /** Starts window A on an unconfirmed adoption of the kept copy, which window B changed in place; returns the copy's id. */
    private fun unconfirmedChangedCopy(vm: MainViewModel, vararg extra: Pair<String, String>): String {
        var copyId = ""
        failingRefresh { copyId = editCopyInPlaceInWindowB() }
        editAndRestore(vm)
        assertEquals(copyId, onMain { vm.currentProjectId })
        assertRows(openSong.id to newerWords, copyId to windowBWords, *extra)
        return copyId
    }

    /** K9(a): a whitespace draft refused at a copy another window changed is still kept as one new song. */
    @Test fun aWhitespaceDraftRefusedAtAChangedCopyIsKeptAsANewSong() {
        newerOpenSong()
        val vm = openSongInEditor()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            blankDraft(vm, whitespaceDraft)
            saveNow(vm)
            waitUntil({ "stored ${songs()}" }) { songs().any { it.lyrics == whitespaceDraft } }
            instrumentation.waitForIdleSync()
            val n = songs().single { it.id != openSong.id && it.id != copyId }
            assertRows(openSong.id to newerWords, copyId to windowBWords, n.id to whitespaceDraft)
            assertEquals("Untitled Song", n.title)
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K9(b): the same whitespace draft refused by a second hold's flush is kept as one new song. */
    @Test fun aWhitespaceDraftRefusedBySecondHoldIsKeptAsANewSong() {
        newerOpenSong()
        val vm = openSongInEditor()
        val entered = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            blankDraft(vm, whitespaceDraft)
            BackupTestHooks.beforeHeldOperation = { entered.complete(Unit) }
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "stored ${songs()} held ${vm.editorHeld}" }) { entered.isCompleted && !onMain { vm.editorHeld } && songs().any { it.lyrics == whitespaceDraft } }
            instrumentation.waitForIdleSync()
            assertTrue("the second hold ran its operation", entered.isCompleted)
            val n = songs().single { it.id != openSong.id && it.id != copyId }
            assertRows(openSong.id to newerWords, copyId to windowBWords, n.id to whitespaceDraft)
            assertEquals("Untitled Song", n.title)
        } finally {
            BackupTestHooks.beforeHeldOperation = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K9(c), a guard: an empty draft refused at a changed copy inserts nothing. */
    @Test fun anEmptyDraftRefusedAtAChangedCopyInsertsNoSong() {
        newerOpenSong()
        val vm = openSongInEditor()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            blankDraft(vm, "")
            saveNow(vm)
            instrumentation.waitForIdleSync()
            assertRows(openSong.id to newerWords, copyId to windowBWords)
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /**
     * K10: the second hold finds the adoption revoked and recovers W3 first; a STOP queued behind that hold and the hold
     * itself wait on that one attempt. It fails, so nothing continues. The explicit retry inserts W3 once, and W4, typed
     * while the retry was writing, is then saved to that same new song.
     */
    @Test fun aFailedRecoveryDropsTheQueuedStopAndTheRetryInsertsTheDraftOnce() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        val continuations = java.util.concurrent.atomic.AtomicInteger()
        val queued = java.util.concurrent.atomic.AtomicInteger()
        RecoveryTestHooks.onQueuedNavigationRun = { if (it === vm) continuations.incrementAndGet() }
        RecoveryTestHooks.onNavigationQueued = { if (it === vm) queued.incrementAndGet() }
        val w3 = "W3 held into the second hold"
        val w4 = "W4 typed while the retry writes"
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        val recoveryParked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val recoveryRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
        val retryGate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val w4Gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val reached = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            // Window B's selection and raw words, which the commit did not write for A: no recovery may replace them.
            val bTuple = storedKeys()
            assertEquals(copyId to Triple("Open Song", windowBWords, ""), bTuple)
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(w3) }
            RecoveryTestHooks.failNextRecovery.set(true)
            RecoveryTestHooks.beforeRecoveryInsert = {
                if (attempts.incrementAndGet() == 1) { recoveryParked.complete(Unit); recoveryRelease.await() }
            }
            BackupTestHooks.beforeHeldOperation = { reached.complete(Unit) }
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "attempts ${attempts.get()}" }) { recoveryParked.isCompleted }
            scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            waitUntil({ "queued ${queued.get()}" }) { queued.get() == 1 }
            recoveryRelease.complete(Unit)
            waitUntil({ "held ${vm.editorHeld}" }) { !onMain { vm.editorHeld } && onMain { vm.saveStatus } == SaveStatus.FAILED }
            instrumentation.waitForIdleSync()
            assertEquals(1, attempts.get())
            assertEquals(SaveStatus.FAILED, onMain { vm.saveStatus })
            assertEquals(w3, onMain { vm.lyrics })
            assertTrue("${songs()}", songs().none { it.lyrics == w3 })
            assertEquals("the dropped STOP ran", 0, continuations.get())
            assertFalse("the failed attempt reached the operation", reached.isCompleted)
            scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
            compose.onNodeWithTag("retrySave").assertExists()
            DraftSaveTestHooks.beforeWrite = retryGate
            instrumentation.runOnMainSync { vm.retrySave() }
            waitUntil({ "retry write" }) { DraftSaveTestHooks.beforeWrite !== retryGate }
            DraftSaveTestHooks.beforeWrite = w4Gate
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(w4) }
            retryGate.complete(Unit)
            waitUntil({ "stored ${songs()}" }) { songs().any { it.lyrics == w3 } }
            val n = songs().single { it.lyrics == w3 }
            assertEquals(bTuple, storedKeys())
            waitUntil({ "W4 write" }) { DraftSaveTestHooks.beforeWrite !== w4Gate }
            w4Gate.complete(Unit)
            waitUntil({ "stored ${songs()}" }) { songs().any { it.id == n.id && it.lyrics == w4 } }
            instrumentation.waitForIdleSync()
            assertRows(openSong.id to newerWords, copyId to windowBWords, n.id to w4)
            assertEquals("the dropped STOP ran", 0, continuations.get())
            assertFalse("the failed attempt reached the operation", reached.isCompleted)
        } finally {
            recoveryRelease.complete(Unit)
            retryGate.complete(Unit)
            w4Gate.complete(Unit)
            RecoveryTestHooks.onQueuedNavigationRun = null
            RecoveryTestHooks.onNavigationQueued = null
            RecoveryTestHooks.beforeRecoveryInsert = null
            RecoveryTestHooks.failNextRecovery.set(false)
            DraftSaveTestHooks.beforeWrite = null
            BackupTestHooks.beforeHoldListRefresh = null
            BackupTestHooks.beforeHeldOperation = null
            resetOpenSong()
        }
    }

    /**
     * K12: a Keep made on X before it was adopted (an independent whole-entry write) is parked at its notebook write.
     * A Keep after the unconfirmed adoption settles only after joining it, and another window's line added after the
     * join survives both. Without the join the settlement commits first and the parked whole-entry write replaces it.
     */
    @Test fun aSettlingKeepJoinsAnEarlierParkedKeepAndKeepsAnotherWindowsLine() {
        val reused = SongProject("reuse-x", "Untitled Song", heldEdits, "", 100L)
        driveWithReused(reused)
        val vm = openSongInEditor(otherSongs = listOf(reused))
        failingRefresh()
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val joining = java.util.concurrent.atomic.AtomicBoolean(false)
        val bAdded = java.util.concurrent.atomic.AtomicBoolean(false)
        try {
            instrumentation.runOnMainSync { vm.loadProject(reused) }
            waitUntil({ "on ${vm.currentProjectId}" }) { onMain { vm.currentProjectId == reused.id && !vm.editorHeld } }
            NotebookTestHooks.beforeLoadedNotebookWrite = { id ->
                if (id == reused.id && !parked.isCompleted) { parked.complete(Unit); release.await() }
            }
            instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
            waitUntil({ "earlier Keep parked" }) { parked.isCompleted }
            instrumentation.runOnMainSync { vm.loadProject(storedOpenSong()) }
            waitUntil({ "on ${vm.currentProjectId}" }) { onMain { vm.currentProjectId == openSong.id && !vm.editorHeld } }
            adoptReused(vm, reused)
            NotebookTestHooks.onJoinWait = { id -> if (id == reused.id) joining.set(true) }
            NotebookTestHooks.afterJoinBeforeSettle = { id -> if (id == reused.id && !bAdded.get()) { addWindowBLine(id); bAdded.set(true) } }
            instrumentation.runOnMainSync { vm.keepAlternate("settling line") }
            // Joined: the settlement waits on the parked Keep. Without a join it settles first.
            waitUntil({ "joining ${joining.get()} ${notebook(reused.id)}" }) { joining.get() || hasLine(reused.id, "settling line") }
            val settledFirst = hasLine(reused.id, "settling line")
            release.complete(Unit)
            waitUntil({ "${notebook(reused.id)}" }) { hasLine(reused.id, "kept line") }
            if (!settledFirst) waitUntil({ "${notebook(reused.id)}" }) { hasLine(reused.id, "settling line") }
            instrumentation.waitForIdleSync()
            fun assertAllLines() = assertTrue("${notebook(reused.id)}",
                hasLine(reused.id, "window B line") && hasLine(reused.id, "kept line") && hasLine(reused.id, "settling line"))
            assertAllLines()
            // Leaving X for the adoption already stored "kept line" (the flush's checkpoint), so only the order shows the join.
            assertFalse("the settling Keep committed before the parked Keep it must join", settledFirst)
            // A later position on X is a stored-position write: it leaves every line where it is.
            instrumentation.runOnMainSync {
                vm.lyricsFieldValue = vm.lyricsFieldValue.copy(selection = androidx.compose.ui.text.TextRange(5, 8))
                vm.rememberEditorPosition(33f)
            }
            waitUntil({ "${notebook(reused.id)}" }) { notebook(reused.id).let { it.selectionStart == 5 && it.selectionEnd == 8 } }
            instrumentation.waitForIdleSync()
            assertEquals(33f, notebook(reused.id).scrollOffset)
            assertAllLines()
        } finally {
            release.complete(Unit)
            NotebookTestHooks.beforeLoadedNotebookWrite = null
            NotebookTestHooks.onJoinWait = null
            NotebookTestHooks.afterJoinBeforeSettle = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    private val songY = SongProject("song-y", "Song Y", "y words", "", 100L)
    private fun storedKeys() = runBlocking { repo.currentProjectIdFlow.first() to repo.editorStateFlow().first() }
    /** The one song holding the held words other than [except], present as soon as the hold released the editor. */
    private fun recovered(vararg except: String): SongProject {
        val kept = songs().filter { it.lyrics == heldEdits && it.id !in except }
        assertEquals("${songs()}", 1, kept.size)
        return kept.single()
    }

    /** K2: the shared selection and raw words at release, after the refresh found A's receipt gone. */
    private fun keysLeg(raw: String? = null, during: suspend (copy: SongProject) -> Unit, expected: (copy: SongProject, n: SongProject) -> Pair<String?, Triple<String, String, String>>) {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        if (raw != null) instrumentation.runOnMainSync { vm.title = raw }
        var copy: SongProject? = null
        BackupTestHooks.beforeHoldListRefresh = {
            BackupTestHooks.beforeHoldListRefresh = null
            copy = repo.projectsFlow.first().single { it.id != openSong.id && it.id != songY.id }
            during(copy!!)
        }
        try {
            editAndRestore(vm)
            val n = recovered(copy!!.id)
            assertEquals(n.id, vm.currentProjectId)
            assertEquals(expected(copy!!, n), storedKeys())
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K2(a): Y selected elsewhere with its raw words. */
    @Test fun aRecoveryLeavesAnotherSongSelectedElsewhereAndItsRawWords() = keysLeg(during = {
        editCopyInPlaceInWindowB(); repo.selectProject(songY.id); repo.saveEditorState("", "y raw", "y theme")
    }) { _, _ -> songY.id to Triple("", "y raw", "y theme") }

    /** K2(b): the selected copy went to the Trash, which cleared the selection. */
    @Test fun aRecoveryLeavesTheSelectionClearedByMovingTheCopyToTheTrash() = keysLeg(during = {
        repo.moveProjectToTrash(it.id, System.currentTimeMillis())
    }) { _, _ -> null to Triple("", "", "") }

    /** K2(c): the copy still selected, with window B's raw words. */
    @Test fun aRecoveryLeavesTheCopySelectedWithAnotherWindowsRawWords() = keysLeg(during = {
        editCopyInPlaceInWindowB()
    }) { copy, _ -> copy.id to Triple(copy.title, windowBWords, copy.theme) }

    /** K2(d): what the commit itself wrote for A is still stored, so the recovery selects the new song with A's raw words. */
    @Test fun aRecoveryAfterTheCommitsOwnSelectionSelectsTheNewSongWithTheRawWords() = keysLeg(raw = "", during = {
        // A whole-list write keeps every row's words but ends every receipt; the shared keys are not touched.
        repo.saveProjects(repo.projectsFlow.first())
    }) { _, n ->
        assertEquals("Untitled Song", n.title)
        n.id to Triple("", heldEdits, "")
    }

    /** K2(e): B selected the reuse target before the commit, so the commit wrote no selection for A and the recovery writes none. */
    @Test fun aRecoveryLeavesAReuseTargetSelectedBeforeTheCommit() {
        val reused = SongProject("reuse-x", "Untitled Song", heldEdits, "", 100L)
        driveWithReused(reused)
        val vm = openSongInEditor(otherSongs = listOf(reused))
        BackupTestHooks.beforeHeldOperation = { repo.selectProject(reused.id) }
        BackupTestHooks.beforeHoldListRefresh = { BackupTestHooks.beforeHoldListRefresh = null; repo.saveProjects(repo.projectsFlow.first()) }
        try {
            instrumentation.runOnMainSync {
                vm.onTitleChanged("")
                vm.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue(heldEdits))
            }
            firstSongIdIs(reused.id) {
                instrumentation.runOnMainSync { vm.restoreFromBackup() }
                waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
                instrumentation.waitForIdleSync()
            }
            assertEquals(heldEdits, songs().single { it.id == reused.id }.lyrics)
            val n = recovered(reused.id)
            assertEquals(n.id, vm.currentProjectId)
            assertEquals(reused.id to Triple(reused.title, reused.lyrics, reused.theme), storedKeys())
        } finally {
            BackupTestHooks.beforeHeldOperation = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K1: the copy changed and changed back during the refresh: its words match, but the receipt is gone. */
    @Test fun aCopyChangedAndChangedBackDuringTheRefreshIsNotAdoptedAgain() {
        newerOpenSong()
        val vm = openSongInEditor()
        var copyId = ""
        BackupTestHooks.beforeHoldListRefresh = {
            BackupTestHooks.beforeHoldListRefresh = null
            val copy = repo.projectsFlow.first().single { it.id != openSong.id }
            copyId = copy.id
            editCopyInPlaceInWindowB()
            repo.saveActiveState(copy, null, copy.title, copy.lyrics, copy.theme)
        }
        try {
            editAndRestore(vm)
            assertEquals(heldEdits, songs().single { it.id == copyId }.lyrics)
            val n = recovered(copyId)
            assertEquals(n.id, vm.currentProjectId)
            val typed = "W3 typed after the hold"
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(typed) }
            saveNow(vm)
            assertEquals(mapOf(openSong.id to newerWords, copyId to heldEdits, n.id to typed), songs().associate { it.id to it.lyrics })
            assertTrue("${notebook(copyId)}", hasLine(copyId, "window B line"))
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K3(a): unconfirmed, B keeps a line; A's first save is valid and its checkpoint is added to X's stored notebook. */
    @Test fun aValidFirstSaveOfAnUnconfirmedAdoptionAddsItsCheckpointToTheStoredNotebook() {
        newerOpenSong()
        val vm = openSongInEditor()
        failingRefresh { addWindowBLine(repo.projectsFlow.first().single { it.id != openSong.id }.id) }
        try {
            editAndRestore(vm)
            val copyId = checkNotNull(vm.currentProjectId)
            val typed = "W3 typed on the unconfirmed copy"
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(typed) }
            saveNow(vm)
            waitUntil({ "${notebook(copyId)}" }) { notebook(copyId).versions.any { it.lyrics == typed } }
            instrumentation.waitForIdleSync()
            assertEquals(mapOf(openSong.id to newerWords, copyId to typed), songs().associate { it.id to it.lyrics })
            assertTrue("${notebook(copyId)}", hasLine(copyId, "window B line"))
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K3(b): unconfirmed, B keeps a line and selects Y; A's first action is Keep: X's notebook gets it, Y's keys stay. */
    @Test fun aKeepOnAnUnconfirmedAdoptionIsItsOwnEditAndLeavesAnotherSelection() {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        failingRefresh {
            addWindowBLine(repo.projectsFlow.first().single { it.id != openSong.id && it.id != songY.id }.id)
            repo.selectProject(songY.id)
            repo.saveEditorState("", "y raw", "y theme")
        }
        try {
            editAndRestore(vm)
            val copyId = checkNotNull(vm.currentProjectId)
            instrumentation.runOnMainSync { vm.keepAlternate("a kept line") }
            waitUntil({ "${notebook(copyId)}" }) { hasLine(copyId, "a kept line") }
            instrumentation.waitForIdleSync()
            assertTrue("${notebook(copyId)}", hasLine(copyId, "window B line"))
            assertEquals(songY.id to Triple("", "y raw", "y theme"), storedKeys())
            assertEquals(setOf(openSong.id, songY.id, copyId), songs().map { it.id }.toSet())
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K4(a): a Keep on an unconfirmed adoption, with no barrier, lands next to another window's line. */
    @Test fun aKeepStraddlingAnUnconfirmedAdoptionsDecisionKeepsAnotherWindowsLine() {
        newerOpenSong()
        val vm = openSongInEditor()
        failingRefresh { addWindowBLine(repo.projectsFlow.first().single { it.id != openSong.id }.id) }
        try {
            editAndRestore(vm)
            val copyId = checkNotNull(vm.currentProjectId)
            instrumentation.runOnMainSync { vm.keepAlternate("a line") }
            waitUntil({ "${notebook(copyId)}" }) { hasLine(copyId, "a line") }
            instrumentation.waitForIdleSync()
            assertTrue("${notebook(copyId)}", hasLine(copyId, "window B line"))
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K5: a second hold on an unconfirmed adoption another window changed: clean, or with words hidden behind Welcome. */
    @Test fun aSecondHoldKeepsTheCleanHeldWordsAsOneNewSong() = secondHoldLeg(hidden = null)

    @Test fun aSecondHoldKeepsWordsHiddenBehindWelcomeAsOneNewSong() = secondHoldLeg(hidden = "W3 typed then hidden behind Welcome")

    private fun secondHoldLeg(hidden: String?) {
        newerOpenSong()
        val vm = openSongInEditor()
        var copyId = ""
        failingRefresh {
            copyId = repo.projectsFlow.first().single { it.id != openSong.id }.id
            editCopyInPlaceInWindowB()
        }
        val entered = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            editAndRestore(vm)
            if (hidden != null) instrumentation.runOnMainSync {
                vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(hidden)
                vm.showStartMenu = true
            }
            BackupTestHooks.beforeHeldOperation = { entered.complete(Unit) }
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            waitUntil({ "held ${vm.editorHeld} status ${vm.backupStatus}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            instrumentation.waitForIdleSync()
            val words = hidden ?: heldEdits
            val kept = songs().filter { it.lyrics == words && it.id != copyId }
            assertEquals("${songs()}", 1, kept.size)
            assertEquals(windowBWords, songs().single { it.id == copyId }.lyrics)
        } finally {
            BackupTestHooks.beforeHeldOperation = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** K8: after the unconfirmed refresh, the copy is moved to the Trash while A's save waits: A's words go to one new song. */
    @Test fun aSaveFindingAnUnconfirmedAdoptionGoneKeepsTheWordsAsANewSong() {
        newerOpenSong()
        val vm = openSongInEditor()
        failingRefresh()
        val w3 = "W3 saved after the copy left"
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            editAndRestore(vm)
            val copyId = checkNotNull(vm.currentProjectId)
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(w3) }
            DraftSaveTestHooks.beforeWrite = gate
            instrumentation.runOnMainSync { vm.flushCurrentDraft() }
            waitUntil({ "gate taken" }) { DraftSaveTestHooks.beforeWrite == null }
            runBlocking { repo.moveProjectToTrash(copyId, System.currentTimeMillis()) }
            gate.complete(Unit)
            waitUntil({ "stored ${songs()}" }) { songs().any { it.lyrics == w3 } }
            instrumentation.waitForIdleSync()
            val n = songs().single { it.lyrics == w3 }
            assertEquals(Triple("Open Song", w3, ""), Triple(n.title, n.lyrics, n.theme))
            assertTrue(songs().none { it.id == copyId })
            // The Trash move cleared the selection the commit wrote for A; that is no tuple of A's, so it stays.
            assertEquals(null to Triple("", "", ""), storedKeys())
        } finally {
            gate.complete(Unit)
            DraftSaveTestHooks.beforeWrite = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    // S0a round 5: the failed-refresh path. One boundary decides an adopted copy; a revoked one is never written again.

    /**
     * R5-1 and the K10 overlap: a Keep refused at a copy window B changed starts the one recovery. A STOP during that
     * recovery's notebook reread finds the copy revoked, writes nothing there and joins the attempt: one insert, one
     * new song holding A's draft and the kept line once, B's words, line and shared keys untouched.
     */
    @Test fun aStopDuringARefusedKeepsRecoveryWritesNothingAtTheCopyAndJoinsIt() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val inserts = java.util.concurrent.atomic.AtomicInteger()
        // Each recovery attempt starts with this read, on the main thread.
        val attempts = java.util.concurrent.atomic.AtomicInteger()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            val bTuple = storedKeys()
            RecoveryTestHooks.onRevokeRead = { if (attempts.incrementAndGet() == 1) { parked.complete(Unit); release.await() } }
            RecoveryTestHooks.beforeRecoveryInsert = { inserts.incrementAndGet() }
            instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
            waitUntil({ "revoke read" }) { parked.isCompleted }
            // The STOP's flush starts on the main thread before this returns.
            scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            instrumentation.waitForIdleSync()
            assertEquals("the STOP joined the attempt in flight", 1, attempts.get())
            release.complete(Unit)
            waitUntil({ "stored ${songs()}" }) { songs().any { it.id != copyId && it.lyrics == heldEdits } }
            val n = songs().single { it.id != copyId && it.lyrics == heldEdits }
            waitUntil({ "${notebook(n.id)}" }) { hasLine(n.id, "kept line") }
            instrumentation.waitForIdleSync()
            assertWindowBKeptTheCopy(copyId, heldEdits)
            assertRows(openSong.id to newerWords, copyId to windowBWords, n.id to heldEdits)
            assertEquals("${notebook(n.id)}", 1, notebook(n.id).alternates.count { it.text == "kept line" })
            assertFalse("${notebook(copyId)}", hasLine(copyId, "kept line"))
            assertEquals("recovery inserts", 1, inserts.get())
            assertEquals("recovery attempts", 1, attempts.get())
            assertEquals(bTuple, storedKeys())
            assertEquals(n.id, onMain { vm.currentProjectId })
        } finally {
            release.complete(Unit)
            RecoveryTestHooks.onRevokeRead = null
            RecoveryTestHooks.beforeRecoveryInsert = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /**
     * R5-1, two overlapping writers: a Keep made while A's first guarded save of a valid unconfirmed copy is writing
     * follows that save's decision. It lands at X; no recovery runs and no new song is made.
     */
    @Test fun aKeepOverlappingTheFirstGuardedSaveFollowsItsDecision() {
        newerOpenSong()
        val vm = openSongInEditor()
        failingRefresh()
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val waiting = java.util.concurrent.atomic.AtomicBoolean(false)
        val w3 = "W3 saved while a Keep waits"
        try {
            editAndRestore(vm)
            val copyId = checkNotNull(vm.currentProjectId)
            instrumentation.runOnMainSync { vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(w3) }
            com.rhymeai.app.data.repository.RepositoryTestHooks.afterUpdateCheck = { parked.complete(Unit); release.await() }
            NotebookTestHooks.onJoinWait = { id -> if (id == copyId) waiting.set(true) }
            NotebookTestHooks.beforeLoadedNotebookWrite = { id -> if (id == copyId) waiting.set(true) }
            instrumentation.runOnMainSync { vm.flushCurrentDraft() }
            waitUntil({ "save parked" }) { parked.isCompleted }
            instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
            waitUntil({ "Keep waiting" }) { waiting.get() }
            release.complete(Unit)
            waitUntil({ "stored ${songs()} ${notebook(copyId)}" }) { !vm.savingBeforeNavigation && (hasLine(copyId, "kept line") || songs().size > 2) }
            instrumentation.waitForIdleSync()
            assertRows(openSong.id to newerWords, copyId to w3)
            assertTrue("${notebook(copyId)}", hasLine(copyId, "kept line"))
            assertEquals(copyId, onMain { vm.currentProjectId })
        } finally {
            release.complete(Unit)
            com.rhymeai.app.data.repository.RepositoryTestHooks.afterUpdateCheck = null
            NotebookTestHooks.onJoinWait = null
            NotebookTestHooks.beforeLoadedNotebookWrite = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /**
     * R5-2: B keeps a line on X during the failed refresh without changing its words. A types W3 and the debounced
     * autosave is X's first guarded save: its checkpoint joins X's stored notebook next to B's line.
     */
    @Test fun aTypedAutosaveConfirmingAnUnconfirmedCopyAddsItsCheckpointToTheStoredNotebook() {
        newerOpenSong()
        val vm = openSongInEditor()
        failingRefresh { addWindowBLine(repo.projectsFlow.first().single { it.id != openSong.id }.id) }
        val typed = "W3 typed and autosaved"
        try {
            editAndRestore(vm)
            val copyId = checkNotNull(vm.currentProjectId)
            instrumentation.runOnMainSync { vm.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue(typed)) }
            waitUntil({ "stored ${songs()} ${notebook(copyId)}" }) {
                songs().any { it.id == copyId && it.lyrics == typed } && notebook(copyId).versions.any { it.lyrics == heldEdits }
            }
            instrumentation.waitForIdleSync()
            assertEquals(mapOf(openSong.id to newerWords, copyId to typed), songs().associate { it.id to it.lyrics })
            assertTrue("B's line: ${notebook(copyId)}", hasLine(copyId, "window B line"))
            assertTrue("A's checkpoint: ${notebook(copyId)}", notebook(copyId).versions.any { it.lyrics == heldEdits })
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /**
     * R5-3: during the failed refresh B moves X to the Trash and selects Y with its own raw words, and A's song list
     * drops X before A saves. The save keeps A's draft as one new song and leaves B's selection and raw words.
     */
    private fun goneCopyLeg(draft: String, save: (MainViewModel) -> Unit) {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        var copyId = ""
        failingRefresh {
            copyId = repo.projectsFlow.first().single { it.id != openSong.id && it.id != songY.id }.id
            repo.moveProjectToTrash(copyId, System.currentTimeMillis())
            repo.selectProject(songY.id)
            repo.saveEditorState("", "y raw", "y theme")
        }
        try {
            editAndRestore(vm)
            waitUntil({ "on ${vm.currentProjectId} list ${vm.projects.map { it.id }}" }) {
                onMain { vm.currentProjectId == copyId && vm.projects.none { it.id == copyId } }
            }
            save(vm)
            waitUntil({ "stored ${songs()}" }) { songs().any { it.lyrics == draft } }
            instrumentation.waitForIdleSync()
            assertEquals("${songs()}", 1, songs().count { it.lyrics == draft })
            assertTrue("${songs()}", songs().none { it.id == copyId })
            assertEquals(songY.id to Triple("", "y raw", "y theme"), storedKeys())
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun aFlushAfterTheGoneCopyLeftTheListLeavesAnotherSelection() = goneCopyLeg(heldEdits) { saveNow(it) }

    @Test fun aWhitespaceFlushAfterTheGoneCopyLeftTheListIsKeptAsANewSong() = goneCopyLeg(whitespaceDraft) { vm ->
        blankDraft(vm, whitespaceDraft)
        saveNow(vm)
    }

    @Test fun aTypedAutosaveAfterTheGoneCopyLeftTheListLeavesAnotherSelection() = goneCopyLeg("W3 typed after the copy left") { vm ->
        instrumentation.runOnMainSync { vm.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue("W3 typed after the copy left")) }
    }

    /** R5-3: the hold's first read of where its words went fails; B selected Y with raw words. The draft's new song leaves them. */
    @Test fun aFailedHoldResolveKeepsTheDraftAsANewSongAndLeavesAnotherSelection() {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        BackupTestHooks.beforeHoldResolve = {
            BackupTestHooks.beforeHoldResolve = null
            repo.selectProject(songY.id)
            repo.saveEditorState("", "y raw", "y theme")
            throw java.io.IOException("injected hold resolve failure")
        }
        try {
            editAndRestore(vm)
            saveNow(vm)
            // The commit's own copy and the draft's new song.
            waitUntil({ "stored ${songs()}" }) { songs().count { it.lyrics == heldEdits } == 2 }
            instrumentation.waitForIdleSync()
            assertEquals("${songs()}", 2, songs().count { it.lyrics == heldEdits })
            assertEquals(songY.id to Triple("", "y raw", "y theme"), storedKeys())
        } finally {
            BackupTestHooks.beforeHoldResolve = null
            resetOpenSong()
        }
    }

    /**
     * Coverage: a recovery whose drawn id is another song's is refused before writing, redraws, and carries the refused
     * Keep's line to the new song. The occupant's words and notebook and B's shared keys stay.
     */
    @Test fun aRecoveryWhoseIdIsTakenRedrawsAndCarriesTheKeptLine() {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        var copyId = ""
        failingRefresh { copyId = editCopyInPlaceInWindowB() }
        try {
            editAndRestore(vm)
            assertEquals(copyId, onMain { vm.currentProjectId })
            val bTuple = storedKeys()
            val yNotebook = notebook(songY.id)
            firstSongIdIs(songY.id) {
                instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
                waitUntil({ "stored ${songs()}" }) { songs().any { it.lyrics == heldEdits } }
                instrumentation.waitForIdleSync()
            }
            val n = songs().single { it.lyrics == heldEdits }
            assertTrue(n.id != songY.id)
            waitUntil({ "${notebook(n.id)}" }) { hasLine(n.id, "kept line") }
            assertEquals(songY.lyrics, songs().single { it.id == songY.id }.lyrics)
            assertEquals(yNotebook, notebook(songY.id))
            assertWindowBKeptTheCopy(copyId, heldEdits)
            assertEquals(bTuple, storedKeys())
            assertEquals(n.id, onMain { vm.currentProjectId })
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** A Keep on an unconfirmed adoption shows as saving until its own write commits, and as not saved when that fails. */
    @Test fun aNotebookActionOnAnUnconfirmedAdoptionShowsSavingUntilItsWriteCommits() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        failingRefresh()
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            editAndRestore(vm)
            val copyId = checkNotNull(vm.currentProjectId)
            NotebookTestHooks.beforeLoadedNotebookWrite = { id -> if (id == copyId && !parked.isCompleted) { parked.complete(Unit); release.await() } }
            instrumentation.runOnMainSync { vm.showSongNotebook = true }
            instrumentation.runOnMainSync { vm.keepAlternate("a pending line") }
            waitUntil({ "parked" }) { parked.isCompleted }
            waitForText("Saving…")
            release.complete(Unit)
            waitUntil({ "${notebook(copyId)}" }) { hasLine(copyId, "a pending line") }
            compose.waitUntil(10_000) { compose.onAllNodesWithText("Saving…").fetchSemanticsNodes().isEmpty() }
        } finally {
            release.complete(Unit)
            NotebookTestHooks.beforeLoadedNotebookWrite = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun aNotebookActionWhoseRecoveryFailsShowsNotSavedAndItsRetryKeepsIt() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        failingRefresh { editCopyInPlaceInWindowB() }
        try {
            editAndRestore(vm)
            val copyId = checkNotNull(vm.currentProjectId)
            instrumentation.runOnMainSync { vm.showSongNotebook = true }
            RecoveryTestHooks.failNextRecovery.set(true)
            instrumentation.runOnMainSync { vm.keepAlternate("a refused line") }
            waitForText("Not saved – Retry")
            assertTrue(songs().none { it.lyrics == heldEdits })
            assertTrue("${notebook(copyId)}", !hasLine(copyId, "a refused line"))
            compose.onNodeWithText("Not saved – Retry").performClick()
            waitUntil({ "stored ${songs()}" }) { songs().any { it.lyrics == heldEdits } }
            val n = songs().single { it.lyrics == heldEdits }
            waitUntil({ "${notebook(n.id)}" }) { hasLine(n.id, "a refused line") }
            assertTrue("${notebook(copyId)}", hasLine(copyId, "window B line") && !hasLine(copyId, "a refused line"))
        } finally {
            RecoveryTestHooks.failNextRecovery.set(false)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    // S0a round 6: the recovery song N's first commit bounds every writer, N stays the editor's song until it is stored,
    // and a notebook action counts as saved only by its own write. X = the copy window B changed, N = the draft's new song.

    /** Waits for the editor's saves, holds and notebook writes to finish; fails if any is still running at the deadline. */
    private fun quiesce(vm: MainViewModel) {
        SystemClock.sleep(1_500)
        waitUntil({ "still busy: navigation ${vm.savingBeforeNavigation} notebook ${vm.notebookSaving} held ${vm.editorHeld} status ${vm.saveStatus}" }) {
            onMain { !vm.savingBeforeNavigation && vm.notebookSaving == 0 && !vm.editorHeld && vm.saveStatus != SaveStatus.SAVING }
        }
        instrumentation.waitForIdleSync()
    }

    /** Stored songs other than the fixture's own and [copyId]. */
    private fun others(copyId: String) = songs().filter { it.id != openSong.id && it.id != copyId && it.id != songY.id }

    /** A Keep at [copyId] holds the copy's lock, parked before its write; complete the result to let it write. */
    private fun parkKeepAt(vm: MainViewModel, copyId: String, text: String = "kept line"): kotlinx.coroutines.CompletableDeferred<Unit> {
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        NotebookTestHooks.afterJoinBeforeSettle = { id -> if (id == copyId && !parked.isCompleted) { parked.complete(Unit); release.await() } }
        instrumentation.runOnMainSync { vm.keepAlternate(text) }
        waitUntil({ "Keep parked at the copy's lock" }) { parked.isCompleted }
        return release
    }

    private fun <T> withOneLiner(vm: MainViewModel, block: (com.rhymeai.app.data.model.OneLiner) -> T): T {
        val line = runBlocking { vm.oneLinersStore.add("a sent line") }
        try {
            return block(line)
        } finally {
            runBlocking { vm.oneLinersStore.trash(line.id); vm.oneLinersStore.permanentlyDelete(line.id) }
        }
    }

    private fun marker(vm: MainViewModel, lineId: String) = runBlocking { vm.oneLinersStore.all() }.single { it.id == lineId }.usedInProjectId

    private fun send(vm: MainViewModel, line: com.rhymeai.app.data.model.OneLiner, to: SongProject): kotlinx.coroutines.CompletableDeferred<String> {
        val sent = kotlinx.coroutines.CompletableDeferred<String>()
        instrumentation.runOnMainSync { vm.sendOneLinerToSong(line, to) { sent.complete(it) } }
        return sent
    }

    private fun <T> result(of: kotlinx.coroutines.Deferred<T>): T = runBlocking { withTimeout(10_000) { of.await() } }
    private fun type(vm: MainViewModel, words: String) =
        instrumentation.runOnMainSync { vm.onLyricsChanged(androidx.compose.ui.text.input.TextFieldValue(words)) }

    /**
     * T7: a Keep made on the copy before A's typed save is refused there folds its line into the draft's recovery. The next
     * writer after the refusal (a typed edit, or STOP) must not take the draft away from that line: one new song holds A's
     * newest words and the line; X keeps B's words and line.
     */
    private fun aKeptLineStaysWithTheDraftThroughTheNextWriter(stop: Boolean) {
        newerOpenSong()
        val vm = openSongInEditor(activity = stop)
        val revokeParked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val revokeRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
        val w3 = "W3 typed while a Keep waits"
        val w4 = "W4 typed after the refusal"
        try {
            val copyId = unconfirmedChangedCopy(vm)
            val release = parkKeepAt(vm, copyId)
            // The typed save passes its ownership check and queues behind the Keep at the copy's lock.
            DraftSaveTestHooks.beforeWrite = kotlinx.coroutines.CompletableDeferred(Unit)
            type(vm, w3)
            waitUntil({ "word save queued" }) { DraftSaveTestHooks.beforeWrite == null }
            // Where a recovery starts with a read, it is held there while the refused save leaves the copy.
            RecoveryTestHooks.onRevokeRead = { if (!revokeParked.isCompleted) { revokeParked.complete(Unit); revokeRelease.await() } }
            release.complete(Unit)
            waitUntil({ "editor on ${vm.currentProjectId}" }) { onMain { vm.currentProjectId } != copyId }
            if (stop) scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED) else type(vm, w4)
            SystemClock.sleep(1_000)
            revokeRelease.complete(Unit)
            quiesce(vm)
            val n = others(copyId)
            assertEquals("${songs()}", listOf(if (stop) w3 else w4), n.map { it.lyrics })
            assertTrue("${notebook(n.single().id)}", hasLine(n.single().id, "kept line"))
            assertWindowBKeptTheCopy(copyId, w3)
            assertFalse("${notebook(copyId)}", hasLine(copyId, "kept line"))
        } finally {
            revokeRelease.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun aKeptLineRefusedAtAChangedCopyStaysWithTheDraftThroughATypedEdit() = aKeptLineStaysWithTheDraftThroughTheNextWriter(stop = false)

    @Test fun aKeptLineRefusedAtAChangedCopyStaysWithTheDraftThroughAStop() = aKeptLineStaysWithTheDraftThroughTheNextWriter(stop = true)

    /** The gone-copy fixture: B trashed X and selected Y with raw words; A's list dropped X while A is still on it. */
    private fun goneCopy(vm: MainViewModel): String {
        var copyId = ""
        failingRefresh {
            copyId = repo.projectsFlow.first().single { it.id != openSong.id && it.id != songY.id }.id
            repo.moveProjectToTrash(copyId, System.currentTimeMillis())
            repo.selectProject(songY.id)
            repo.saveEditorState("", "y raw", "y theme")
        }
        editAndRestore(vm)
        waitUntil({ "on ${vm.currentProjectId} list ${vm.projects.map { it.id }}" }) {
            onMain { vm.currentProjectId == copyId && vm.projects.none { it.id == copyId } }
        }
        return copyId
    }

    /** T8a: Open Y's flush starts the gone copy's recovery; W4 typed while it inserts is stored, not dropped by the open. */
    @Test fun anOpenWhoseFlushRecoversAGoneCopyKeepsWordsTypedDuringTheInsert() {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val w4 = "W4 typed while the recovery inserts"
        try {
            val copyId = goneCopy(vm)
            RecoveryTestHooks.beforeRecoveryInsert = { if (!parked.isCompleted) { parked.complete(Unit); release.await() } }
            instrumentation.runOnMainSync { vm.loadProject(songY) }
            waitUntil({ "recovery parked" }) { parked.isCompleted }
            type(vm, w4)
            SystemClock.sleep(1_000)
            release.complete(Unit)
            quiesce(vm)
            assertEquals("${songs()}", listOf(w4), others(copyId).map { it.lyrics })
        } finally {
            release.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T8b: W3's recovery snapshot is inserting; W4 is typed and Open Y joins it. W4 is stored before Y replaces the editor. */
    @Test fun anOpenJoiningARecoveryInsertOfOlderWordsStoresTheNewerOnesFirst() {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val w3 = "W3 typed after the copy left"
        val w4 = "W4 typed during the insert"
        try {
            val copyId = goneCopy(vm)
            com.rhymeai.app.data.repository.RepositoryTestHooks.afterInsertCheck = { parked.complete(Unit); release.await() }
            type(vm, w3)
            waitUntil({ "insert parked" }) { parked.isCompleted }
            type(vm, w4)
            instrumentation.runOnMainSync { vm.loadProject(songY) }
            SystemClock.sleep(500)
            release.complete(Unit)
            quiesce(vm)
            assertEquals("${songs()}", listOf(w4), others(copyId).map { it.lyrics })
        } finally {
            release.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T8c: behind Welcome, Open Y while the recovery's first write is parked: the draft is stored before Y opens. */
    @Test fun aWelcomeOpenWhileTheRecoveryIsParkedWaitsForItsFirstWrite() {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val w3 = "W3 typed after the copy left"
        try {
            val copyId = goneCopy(vm)
            RecoveryTestHooks.beforeRecoveryInsert = { if (!parked.isCompleted) { parked.complete(Unit); release.await() } }
            type(vm, w3)
            waitUntil({ "recovery parked" }) { parked.isCompleted }
            instrumentation.runOnMainSync {
                vm.showStartMenu = true
                vm.loadProject(songY)
            }
            SystemClock.sleep(500)
            release.complete(Unit)
            quiesce(vm)
            assertEquals("${songs()}", listOf(w3), others(copyId).map { it.lyrics })
        } finally {
            release.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T9(i): once the draft left the refused copy, a new send to that copy is an ordinary append there. */
    @Test fun aFreshSendToTheRefusedCopyAppendsThere() {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        try {
            val copyId = unconfirmedChangedCopy(vm, songY.id to songY.lyrics)
            saveNow(vm)
            quiesce(vm)
            val n = others(copyId).single()
            // Another window selected Y with its own raw draft: an append to X leaves the shared keys alone.
            runBlocking { repo.selectProject(songY.id); repo.saveEditorState("", "y raw", "y theme") }
            withOneLiner(vm) { line ->
                val message = result(send(vm, line, songs().single { it.id == copyId }))
                quiesce(vm)
                assertTrue(message, message.startsWith("Sent to"))
                assertEquals(appended(windowBWords), songs().single { it.id == copyId }.lyrics)
                assertEquals(copyId, marker(vm, line.id))
                assertEquals("${songs()}", listOf(n.id to heldEdits), others(copyId).map { it.id to it.lyrics })
                assertEquals(heldEdits, onMain { vm.lyrics })
                assertEquals(songY.id to Triple("", "y raw", "y theme"), storedKeys())
            }
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T9(ii): behind Welcome a Keep is refused and the draft's new song is parked; a send to the copy appends there. */
    @Test fun aSendToTheRefusedCopyWhileItsRecoveryIsParkedAppendsThere() {
        newerOpenSong()
        val vm = openSongInEditor()
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            RecoveryTestHooks.beforeRecoveryInsert = { if (!parked.isCompleted) { parked.complete(Unit); release.await() } }
            instrumentation.runOnMainSync { vm.showStartMenu = true }
            instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
            waitUntil({ "recovery parked" }) { parked.isCompleted }
            withOneLiner(vm) { line ->
                // The append to X returns while N's first commit is still parked: it does not wait for N.
                val message = result(send(vm, line, songs().single { it.id == copyId }))
                assertFalse(release.isCompleted)
                assertTrue(message, message.startsWith("Sent to"))
                assertEquals(appended(windowBWords), songs().single { it.id == copyId }.lyrics)
                release.complete(Unit)
                quiesce(vm)
                assertEquals(appended(windowBWords), songs().single { it.id == copyId }.lyrics)
                assertEquals(copyId, marker(vm, line.id))
                val n = others(copyId)
                assertEquals("${songs()}", listOf(heldEdits), n.map { it.lyrics })
                assertTrue("${notebook(n.single().id)}", hasLine(n.single().id, "kept line"))
                assertEquals(heldEdits, onMain { vm.lyrics })
            }
        } finally {
            release.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T9(iii): a send that was waiting when the copy was refused is refused once, marker unchanged; sending again appends once. */
    @Test fun aSendCapturedBeforeTheRefusalIsRefusedOnceAndThenAppends() {
        newerOpenSong()
        val vm = openSongInEditor()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            instrumentation.runOnMainSync { vm.showStartMenu = true }
            withOneLiner(vm) { line ->
                val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
                BackupTestHooks.beforeMenuSend = gate
                val waiting = send(vm, line, songs().single { it.id == copyId })
                waitUntil({ "send waiting" }) { BackupTestHooks.beforeMenuSend == null }
                instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
                waitUntil({ "editor on ${vm.currentProjectId}" }) { onMain { vm.currentProjectId } != copyId }
                gate.complete(Unit)
                val first = result(waiting)
                assertTrue(first, first.contains("Try again"))
                assertEquals(windowBWords, songs().single { it.id == copyId }.lyrics)
                assertEquals(null, marker(vm, line.id))
                val again = result(send(vm, line, songs().single { it.id == copyId }))
                quiesce(vm)
                assertTrue(again, again.startsWith("Sent to"))
                assertEquals(appended(windowBWords), songs().single { it.id == copyId }.lyrics)
                assertEquals(copyId, marker(vm, line.id))
                assertEquals("${songs()}", listOf(heldEdits), others(copyId).map { it.lyrics })
            }
        } finally {
            BackupTestHooks.beforeMenuSend = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T10(a), the review bot's case: all three fields cleared, then a Keep refused at the changed copy. The line is kept. */
    @Test fun aKeepOnAnEmptiedDraftRefusedAtAChangedCopyIsKeptInANewSong() {
        newerOpenSong()
        val vm = openSongInEditor()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            val bTuple = storedKeys()
            blankDraft(vm, "")
            instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
            quiesce(vm)
            val n = others(copyId)
            assertEquals("${songs()}", 1, n.size)
            // The emptied draft, not the copy's old words: an untitled row with no words or theme.
            assertEquals(Triple("Untitled Song", "", ""), n.single().let { Triple(it.title, it.lyrics, it.theme) })
            assertTrue("${notebook(n.single().id)}", hasLine(n.single().id, "kept line"))
            assertWindowBKeptTheCopy(copyId, heldEdits)
            assertFalse(hasLine(copyId, "kept line"))
            assertEquals(bTuple, storedKeys())
            assertEquals(0, onMain { vm.notebookSaving })
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T10(b): fields cleared; a second Keep waits at the lock while the first is refused. Both lines are kept in one new song. */
    @Test fun aKeepQueuedBehindARefusedKeepOnAnEmptiedDraftIsKeptToo() {
        newerOpenSong()
        val vm = openSongInEditor()
        val waiting = java.util.concurrent.atomic.AtomicBoolean(false)
        try {
            val copyId = unconfirmedChangedCopy(vm)
            val bTuple = storedKeys()
            blankDraft(vm, "")
            val release = parkKeepAt(vm, copyId, "first kept line")
            NotebookTestHooks.onJoinWait = { id -> if (id == copyId) waiting.set(true) }
            instrumentation.runOnMainSync { vm.keepAlternate("second kept line") }
            waitUntil({ "second Keep waiting" }) { waiting.get() }
            release.complete(Unit)
            quiesce(vm)
            val n = others(copyId)
            assertEquals("${songs()}", 1, n.size)
            assertTrue("${notebook(n.single().id)}", hasLine(n.single().id, "first kept line") && hasLine(n.single().id, "second kept line"))
            assertWindowBKeptTheCopy(copyId, heldEdits)
            assertEquals(bTuple, storedKeys())
            assertEquals(0, onMain { vm.notebookSaving })
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /**
     * T11a: an open-song send whose write queued at the copy behind a refusing Keep, with STOP between its insertion and
     * rollback. The send fails and is undone everywhere: marker, both rows and N's stored versions hold no sent line.
     */
    @Test fun anOpenSongSendQueuedBehindARefusalIsUndoneEverywhere() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        try {
            val copyId = unconfirmedChangedCopy(vm)
            withOneLiner(vm) { line ->
                val release = parkKeepAt(vm, copyId)
                DraftSaveTestHooks.beforeWrite = kotlinx.coroutines.CompletableDeferred(Unit)
                val sent = send(vm, line, songs().single { it.id == copyId })
                waitUntil({ "send queued" }) { DraftSaveTestHooks.beforeWrite == null }
                scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
                instrumentation.waitForIdleSync()
                release.complete(Unit)
                val message = result(sent)
                quiesce(vm)
                assertTrue(message, message.startsWith("Couldn't add the line"))
                assertEquals(null, marker(vm, line.id))
                assertWindowBKeptTheCopy(copyId, heldEdits)
                val n = others(copyId)
                assertEquals("${songs()}", listOf(heldEdits), n.map { it.lyrics })
                assertTrue("${notebook(n.single().id)}", notebook(n.single().id).versions.none { it.lyrics.contains("a sent line") })
                assertTrue("${notebook(n.single().id)}", hasLine(n.single().id, "kept line"))
            }
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /**
     * T11b: an open-song send parked after its marker is saved; a Keep is refused meanwhile and the draft moves to its new
     * song. The send adds the line nowhere: not the editor, the new song or the copy, and the marker is put back.
     */
    @Test fun anOpenSongSendWhoseSongLeftAfterItsMarkerAddsTheLineNowhere() {
        newerOpenSong()
        val vm = openSongInEditor()
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            withOneLiner(vm) { line ->
                BackupTestHooks.afterSendMarked = { parked.complete(Unit); release.await() }
                val sent = send(vm, line, songs().single { it.id == copyId })
                waitUntil({ "send parked" }) { parked.isCompleted }
                instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
                waitUntil({ "editor on ${vm.currentProjectId}" }) { onMain { vm.currentProjectId } != copyId }
                release.complete(Unit)
                val message = result(sent)
                quiesce(vm)
                assertTrue(message, message.startsWith("Couldn't add the line"))
                assertEquals(null, marker(vm, line.id))
                assertEquals(heldEdits, onMain { vm.lyrics })
                val n = others(copyId)
                assertEquals("${songs()}", listOf(heldEdits), n.map { it.lyrics })
                assertTrue("${notebook(n.single().id)}", hasLine(n.single().id, "kept line"))
                assertWindowBKeptTheCopy(copyId, heldEdits)
            }
        } finally {
            release.complete(Unit)
            BackupTestHooks.afterSendMarked = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /**
     * T15: a second hold read the copy as valid; before that read decides, a menu send admitted earlier is refused
     * (window B changed the copy) and the draft moves to its new song. The late valid read confirms nothing: one new
     * song, and the copy keeps window B's words.
     */
    @Test fun aLateValidHoldReadDoesNotOverruleARefusal() {
        newerOpenSong()
        val vm = openSongInEditor()
        val readParked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val readRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            failingRefresh()
            editAndRestore(vm)
            val copyId = onMain { vm.currentProjectId }!!
            withOneLiner(vm) { line ->
                instrumentation.runOnMainSync { vm.showStartMenu = true }
                val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
                BackupTestHooks.beforeMenuSend = gate
                val sent = send(vm, line, songs().single { it.id == copyId })
                waitUntil({ "send admitted" }) { BackupTestHooks.beforeMenuSend == null }
                instrumentation.runOnMainSync { vm.showStartMenu = false }
                BackupTestHooks.afterHoldCopyRead = { readParked.complete(Unit); readRelease.await() }
                instrumentation.runOnMainSync { vm.restoreFromBackup() }
                waitUntil({ "hold read parked" }) { readParked.isCompleted }
                runBlocking { editCopyInPlaceInWindowB() }
                val bTuple = storedKeys()
                gate.complete(Unit)
                val message = result(sent)
                waitUntil({ "editor on ${vm.currentProjectId}" }) { onMain { vm.currentProjectId } != copyId }
                readRelease.complete(Unit)
                waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
                quiesce(vm)
                assertTrue(message, message.contains("Try again"))
                assertEquals(null, marker(vm, line.id))
                val n = others(copyId).filter { it.lyrics == heldEdits }
                assertEquals("${songs()}", 1, n.size)
                assertWindowBKeptTheCopy(copyId, heldEdits)
                assertEquals(windowBWords, songs().single { it.id == copyId }.lyrics)
                assertEquals(bTuple, storedKeys())
                // A's next write goes to N only.
                val w5 = "W5 typed after the late read"
                type(vm, w5)
                quiesce(vm)
                assertEquals(n.single().id, onMain { vm.currentProjectId })
                assertEquals(w5, songs().single { it.id == n.single().id }.lyrics)
                assertEquals(windowBWords, songs().single { it.id == copyId }.lyrics)
            }
        } finally {
            readRelease.complete(Unit)
            BackupTestHooks.afterHoldCopyRead = null
            BackupTestHooks.beforeMenuSend = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T12: recording admission queued at the copy behind a refusing Keep is refused without writing X; the next one gets N. */
    @Test fun aRecordingAdmissionQueuedBehindARefusalWritesNothingAtTheCopy() {
        newerOpenSong()
        val vm = openSongInEditor()
        fun admit(): kotlinx.coroutines.CompletableDeferred<Result<String>> = kotlinx.coroutines.CompletableDeferred<Result<String>>().also { done ->
            instrumentation.runOnMainSync { vm.viewModelScope.launch { done.complete(runCatching { vm.ensureProjectForRecording() }) } }
        }
        try {
            val copyId = unconfirmedChangedCopy(vm)
            val release = parkKeepAt(vm, copyId)
            DraftSaveTestHooks.beforeWrite = kotlinx.coroutines.CompletableDeferred(Unit)
            val admitted = admit()
            waitUntil({ "admission queued" }) { DraftSaveTestHooks.beforeWrite == null }
            release.complete(Unit)
            val first = result(admitted)
            quiesce(vm)
            assertTrue("$first", first.isFailure)
            assertWindowBKeptTheCopy(copyId, heldEdits)
            val id = result(admit()).getOrThrow()
            assertTrue(id != copyId)
            assertEquals(heldEdits, songs().single { it.id == id }.lyrics)
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T13: Restore Version queued behind a refusing Keep: the draft's checkpoint, the line and the restored words go to N. */
    private fun aRestoreQueuedBehindARefusalIsAppliedToTheNewSong(empty: Boolean) {
        newerOpenSong()
        val vm = openSongInEditor()
        val waiting = java.util.concurrent.atomic.AtomicBoolean(false)
        val v1 = com.rhymeai.app.data.model.DraftVersion(title = "Untitled Song", lyrics = "version words", theme = "", createdAt = 50L)
        try {
            val copyId = unconfirmedChangedCopy(vm)
            if (empty) blankDraft(vm, "")
            val release = parkKeepAt(vm, copyId)
            NotebookTestHooks.onJoinWait = { id -> if (id == copyId) waiting.set(true) }
            instrumentation.runOnMainSync { vm.restoreDraftVersion(v1) }
            waitUntil({ "restore waiting" }) { waiting.get() }
            release.complete(Unit)
            quiesce(vm)
            val n = others(copyId)
            assertEquals("${songs()}", listOf("version words"), n.map { it.lyrics })
            assertTrue("${notebook(n.single().id)}", hasLine(n.single().id, "kept line"))
            if (!empty) assertTrue("${notebook(n.single().id)}", notebook(n.single().id).versions.any { it.lyrics == heldEdits })
            assertEquals("version words", onMain { vm.lyrics })
            assertWindowBKeptTheCopy(copyId, heldEdits)
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun aRestoreQueuedBehindARefusalIsAppliedToTheNewSong() = aRestoreQueuedBehindARefusalIsAppliedToTheNewSong(empty = false)

    @Test fun aRestoreOnAnEmptiedDraftQueuedBehindARefusalIsAppliedToTheNewSong() = aRestoreQueuedBehindARefusalIsAppliedToTheNewSong(empty = true)

    /**
     * T14: a menu send admitted before the hold appends to the copy (confirming it) while the hold's own read is parked;
     * that read then finds the copy changed. The confirmation stands: no new song, the line is on the copy.
     */
    @Test fun aMenuSendConfirmingTheCopyDuringTheHoldsReadMakesNoNewSong() {
        newerOpenSong()
        val vm = openSongInEditor()
        val readParked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val readRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
        val copy = SongProject("copy-x", "Open Song", heldEdits, "", 0L)
        try {
            withOneLiner(vm) { line ->
                val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
                BackupTestHooks.beforeMenuSend = gate
                val sent = send(vm, line, copy)
                waitUntil({ "send admitted" }) { BackupTestHooks.beforeMenuSend == null }
                BackupTestHooks.beforeHoldListRefresh = {
                    BackupTestHooks.beforeHoldListRefresh = null
                    readParked.complete(Unit)
                    readRelease.await()
                }
                firstSongIdIs(copy.id) {
                    instrumentation.runOnMainSync {
                        vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(heldEdits)
                        vm.restoreFromBackup()
                    }
                    waitUntil({ "hold read parked" }) { readParked.isCompleted }
                }
                assertEquals(copy.id, onMain { vm.currentProjectId })
                gate.complete(Unit)
                val message = result(sent)
                readRelease.complete(Unit)
                quiesce(vm)
                assertEquals("$message ${songs()}", setOf(openSong.id, copy.id), songs().map { it.id }.toSet())
                assertTrue("${songs()}", songs().single { it.id == copy.id }.lyrics.contains("a sent line"))
                assertEquals(copy.id, marker(vm, line.id))
            }
        } finally {
            readRelease.complete(Unit)
            BackupTestHooks.beforeMenuSend = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    // S0a round 6, reviewer corrections: forced schedules for the races the first tests only reached by timing.

    private fun appended(lyrics: String) = com.rhymeai.app.data.repository.OneLinersStore.appendingLine("a sent line", lyrics)

    /** The next save at an adopted copy parks holding the copy's lock, before its receipt check; complete the result to go on. */
    private fun parkInsideCopyLock(parked: kotlinx.coroutines.CompletableDeferred<Unit>, release: kotlinx.coroutines.CompletableDeferred<Unit>) {
        DraftSaveTestHooks.insideCopyLock = { parked.complete(Unit); release.await() }
    }

    /** N's first commit parks after its snapshot, before its write (the next draft write after the snapshot is its own). */
    private fun parkFirstWriteAfterSnapshot(gate: kotlinx.coroutines.CompletableDeferred<Unit>) {
        RecoveryTestHooks.beforeRecoveryInsert = {
            RecoveryTestHooks.beforeRecoveryInsert = null
            DraftSaveTestHooks.beforeWrite = gate
        }
    }

    private fun admit(vm: MainViewModel): kotlinx.coroutines.CompletableDeferred<Result<String>> =
        kotlinx.coroutines.CompletableDeferred<Result<String>>().also { done ->
            instrumentation.runOnMainSync { vm.viewModelScope.launch { done.complete(runCatching { vm.ensureProjectForRecording() }) } }
        }

    /**
     * T7, word first: A's typed save holds the copy's lock before its receipt check and the Keep waits behind it. The save
     * is refused with N pending; N's first write is parked after its snapshot; a typed edit or STOP comes before N commits.
     */
    private fun aKeepWaitingBehindARefusedWordSaveStaysWithTheDraft(stop: Boolean) {
        newerOpenSong()
        val vm = openSongInEditor(activity = stop)
        val waiting = java.util.concurrent.atomic.AtomicBoolean(false)
        val nGate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val afterFirst = kotlinx.coroutines.CompletableDeferred<Unit>()
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val w3 = "W3 typed before the Keep"
        val w4 = "W4 typed after the refusal"
        try {
            val copyId = unconfirmedChangedCopy(vm)
            val bTuple = storedKeys()
            parkInsideCopyLock(parked, release)
            type(vm, w3)
            waitUntil({ "word save holds the copy's lock" }) { parked.isCompleted }
            NotebookTestHooks.onJoinWait = { id -> if (id == copyId) waiting.set(true) }
            instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
            waitUntil({ "Keep waiting at the lock" }) { waiting.get() }
            parkFirstWriteAfterSnapshot(nGate)
            release.complete(Unit)
            waitUntil({ "N's first write parked" }) { RecoveryTestHooks.beforeRecoveryInsert == null && DraftSaveTestHooks.beforeWrite == null }
            val nId = onMain { vm.currentProjectId }!!
            assertTrue(nId != copyId)
            assertEquals(emptyList<SongProject>(), others(copyId))
            if (stop) scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED) else type(vm, w4)
            instrumentation.waitForIdleSync()
            // The typed edit's save waits for N's first commit; it is held again there so B's keys can be read at that commit.
            if (!stop) DraftSaveTestHooks.beforeWrite = afterFirst
            nGate.complete(Unit)
            waitUntil({ "N stored ${songs()}" }) { others(copyId).isNotEmpty() }
            if (!stop) waitUntil({ "word save after N's first commit" }) { DraftSaveTestHooks.beforeWrite == null }
            assertEquals("${songs()}", listOf(nId to w3), others(copyId).map { it.id to it.lyrics })
            assertEquals(bTuple, storedKeys())
            afterFirst.complete(Unit)
            quiesce(vm)
            assertEquals("${songs()}", listOf(nId to (if (stop) w3 else w4)), others(copyId).map { it.id to it.lyrics })
            assertEquals("${notebook(nId)}", 1, notebook(nId).alternates.count { it.text == "kept line" })
            assertWindowBKeptTheCopy(copyId, w3)
            assertEquals(windowBWords, songs().single { it.id == copyId }.lyrics)
            assertFalse("${notebook(copyId)}", hasLine(copyId, "kept line"))
            if (stop) assertEquals(bTuple, storedKeys())
        } finally {
            release.complete(Unit)
            nGate.complete(Unit)
            afterFirst.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun aKeepWaitingBehindARefusedWordSaveStaysWithTheDraftThroughATypedEdit() = aKeepWaitingBehindARefusedWordSaveStaysWithTheDraft(stop = false)

    @Test fun aKeepWaitingBehindARefusedWordSaveStaysWithTheDraftThroughAStop() = aKeepWaitingBehindARefusedWordSaveStaysWithTheDraft(stop = true)

    /** T7 Retry: the draft is empty and only a refused Keep is owed. N's first commit fails; Retry writes N at its reserved id. */
    @Test fun aRecoveryOwingOnlyAKeptLineIsStoredByItsRetryAtTheReservedId() {
        newerOpenSong()
        val vm = openSongInEditor()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            val bTuple = storedKeys()
            blankDraft(vm, "")
            RecoveryTestHooks.failNextRecovery.set(true)
            instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
            waitUntil({ "status ${vm.saveStatus}" }) { onMain { vm.notebookSaving == 0 && vm.saveStatus != SaveStatus.SAVING } }
            val failed = onMain { vm.saveStatus }
            val nId = onMain { vm.currentProjectId }
            val beforeRetry = others(copyId)
            instrumentation.runOnMainSync { vm.retrySave() }
            quiesce(vm)
            val n = others(copyId)
            assertEquals("${songs()}", listOf(nId), n.map { it.id })
            assertEquals(SaveStatus.FAILED, failed)
            assertTrue(nId != copyId)
            assertEquals(emptyList<SongProject>(), beforeRetry)
            assertEquals(Triple("Untitled Song", "", ""), n.single().let { Triple(it.title, it.lyrics, it.theme) })
            assertEquals("${notebook(n.single().id)}", 1, notebook(n.single().id).alternates.count { it.text == "kept line" })
            assertEquals(bTuple, storedKeys())
            assertWindowBKeptTheCopy(copyId, heldEdits)
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T7 across a redraw: N's drawn id is Y's; a typed edit or STOP comes while the replacement's first commit is parked. */
    private fun aKeptLineCrossesARedrawWithTheNextWriter(stop: Boolean) {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY), activity = stop)
        var copyId = ""
        failingRefresh { copyId = editCopyInPlaceInWindowB() }
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val calls = java.util.concurrent.atomic.AtomicInteger(0)
        val w4 = "W4 typed across the redraw"
        try {
            editAndRestore(vm)
            val bTuple = storedKeys()
            val yNotebook = notebook(songY.id)
            RecoveryTestHooks.beforeRecoveryInsert = { if (calls.incrementAndGet() == 2) { parked.complete(Unit); release.await() } }
            firstSongIdIs(songY.id) {
                instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
                waitUntil({ "replacement parked" }) { parked.isCompleted }
            }
            val nId = onMain { vm.currentProjectId }!!
            assertTrue(nId != songY.id && nId != copyId)
            if (stop) scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED) else type(vm, w4)
            instrumentation.waitForIdleSync()
            release.complete(Unit)
            quiesce(vm)
            assertEquals("${songs()}", listOf(nId to (if (stop) heldEdits else w4)), others(copyId).map { it.id to it.lyrics })
            assertEquals("${notebook(nId)}", 1, notebook(nId).alternates.count { it.text == "kept line" })
            assertEquals(songY.lyrics, songs().single { it.id == songY.id }.lyrics)
            assertEquals(yNotebook, notebook(songY.id))
            assertWindowBKeptTheCopy(copyId, heldEdits)
            assertEquals(bTuple, storedKeys())
        } finally {
            release.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun aKeptLineCrossesARedrawWithATypedEdit() = aKeptLineCrossesARedrawWithTheNextWriter(stop = false)

    @Test fun aKeptLineCrossesARedrawWithAStop() = aKeptLineCrossesARedrawWithTheNextWriter(stop = true)

    /** Move to Trash of the editor's pending N whose drawn id is Y's: across the redraw the move trashes nothing, Y least of all. */
    private fun aMoveOfAPendingRecoveryNeverTrashesTheOccupant(welcome: Boolean) {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        var copyId = ""
        failingRefresh { copyId = editCopyInPlaceInWindowB() }
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val committed = java.util.concurrent.atomic.AtomicReference<Boolean?>(null)
        try {
            editAndRestore(vm)
            RecoveryTestHooks.beforeRecoveryInsert = { if (!parked.isCompleted) { parked.complete(Unit); release.await() } }
            firstSongIdIs(songY.id) {
                instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
                waitUntil({ "N parked" }) { parked.isCompleted }
            }
            assertEquals(songY.id, onMain { vm.currentProjectId })
            instrumentation.runOnMainSync {
                if (welcome) vm.showStartMenu = true
                vm.moveProjectToTrash(songY.id) { committed.set(it) }
            }
            release.complete(Unit)
            quiesce(vm)
            assertEquals(songY.lyrics, songs().single { it.id == songY.id }.lyrics)
            assertTrue(runBlocking { repo.trashedProjectsFlow.first() }.none { it.project.id == songY.id })
            val n = others(copyId)
            assertEquals("${songs()}", listOf(heldEdits), n.map { it.lyrics })
            assertEquals(n.single().id, onMain { vm.currentProjectId })
            assertEquals(null, committed.get())
        } finally {
            release.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun aMoveOfAPendingRecoveryNeverTrashesTheOccupant() = aMoveOfAPendingRecoveryNeverTrashesTheOccupant(welcome = false)

    @Test fun aMoveOfAPendingRecoveryBehindWelcomeNeverTrashesTheOccupant() = aMoveOfAPendingRecoveryNeverTrashesTheOccupant(welcome = true)

    /** T8a parked after the snapshot: Open Y waits on N; W4 typed meanwhile keeps the editor on N with W4 stored. */
    @Test fun anOpenParkedAfterTheRecoverySnapshotNeitherOpensEarlyNorDropsNewerWords() {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val opened = java.util.concurrent.atomic.AtomicBoolean(false)
        val w4 = "W4 typed while the recovery writes"
        try {
            val copyId = goneCopy(vm)
            parkFirstWriteAfterSnapshot(gate)
            instrumentation.runOnMainSync { vm.loadProject(songY) { opened.set(true) } }
            waitUntil({ "N's first write parked" }) { RecoveryTestHooks.beforeRecoveryInsert == null && DraftSaveTestHooks.beforeWrite == null }
            val nId = onMain { vm.currentProjectId }!!
            assertTrue(nId != copyId && nId != songY.id)
            assertTrue(onMain { vm.savingBeforeNavigation })
            assertFalse(opened.get())
            assertEquals(emptyList<SongProject>(), others(copyId))
            type(vm, w4)
            gate.complete(Unit)
            quiesce(vm)
            // The open was for the words it flushed; newer ones keep the editor on N, stored there.
            assertFalse(opened.get())
            assertEquals(nId, onMain { vm.currentProjectId })
            assertEquals("${songs()}", listOf(nId to w4), others(copyId).map { it.id to it.lyrics })
        } finally {
            gate.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T8b at the transition: an open joining N's insert of W3 swaps to Y only with W4 already stored on N. */
    @Test fun anOpenJoiningARecoveryInsertSwapsOnlyWithTheNewerWordsStored() {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val swap = kotlinx.coroutines.CompletableDeferred<Unit>()
        val opened = java.util.concurrent.atomic.AtomicBoolean(false)
        val w3 = "W3 typed after the copy left"
        val w4 = "W4 typed during the insert"
        try {
            val copyId = goneCopy(vm)
            com.rhymeai.app.data.repository.RepositoryTestHooks.afterInsertCheck = { parked.complete(Unit); release.await() }
            type(vm, w3)
            waitUntil({ "insert parked" }) { parked.isCompleted }
            val nId = onMain { vm.currentProjectId }!!
            type(vm, w4)
            SongOpenTestHooks.beforeSwap = swap
            instrumentation.runOnMainSync { vm.loadProject(songY) { opened.set(true) } }
            release.complete(Unit)
            waitUntil({ "open at its swap" }) { onMain { vm.openingSong } }
            assertEquals("${songs()}", listOf(nId to w4), others(copyId).map { it.id to it.lyrics })
            swap.complete(Unit)
            waitUntil({ "Y opened" }) { opened.get() }
            quiesce(vm)
            assertEquals(songY.id, onMain { vm.currentProjectId })
            assertEquals("${songs()}", listOf(nId to w4), others(copyId).map { it.id to it.lyrics })
        } finally {
            SongOpenTestHooks.beforeSwap = null
            swap.complete(Unit)
            release.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /**
     * T8c behind Welcome: Open Y waits while N's first write is parked after its snapshot. [newer]: words newer than the
     * snapshot are in the editor (no autosave armed). [fail]: the first write fails; nothing opens and Retry stays.
     */
    private fun aWelcomeOpenWaitsForTheRecoverysFirstCommit(newer: Boolean, fail: Boolean) {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
        val opened = java.util.concurrent.atomic.AtomicBoolean(false)
        // Behind Welcome the open skips the fade beat (no swap seam): its onReady records the rows at the swap.
        val atOpen = java.util.concurrent.atomic.AtomicReference<List<Pair<String, String>>>()
        val w3 = "W3 typed after the copy left"
        val w4 = "W4 in the editor behind Welcome"
        try {
            val copyId = goneCopy(vm)
            parkFirstWriteAfterSnapshot(gate)
            type(vm, w3)
            waitUntil({ "N's first write parked" }) { RecoveryTestHooks.beforeRecoveryInsert == null && DraftSaveTestHooks.beforeWrite == null }
            val nId = onMain { vm.currentProjectId }!!
            assertTrue(nId != copyId)
            instrumentation.runOnMainSync {
                if (newer) vm.lyricsFieldValue = androidx.compose.ui.text.input.TextFieldValue(w4)
                vm.showStartMenu = true
                vm.loadProject(songY) { atOpen.set(others(copyId).map { it.id to it.lyrics }); opened.set(true) }
            }
            instrumentation.waitForIdleSync()
            assertTrue(onMain { vm.savingBeforeNavigation })
            assertFalse(onMain { vm.openingSong })
            assertEquals(nId, onMain { vm.currentProjectId })
            if (fail) RecoveryTestHooks.failNextRecovery.set(true)
            gate.complete(Unit)
            if (fail) {
                quiesce(vm)
                assertFalse(opened.get())
                assertEquals(nId, onMain { vm.currentProjectId })
                assertEquals(SaveStatus.FAILED, onMain { vm.saveStatus })
                assertEquals(emptyList<SongProject>(), others(copyId))
                return
            }
            waitUntil({ "Y opened" }) { opened.get() }
            assertEquals("${songs()}", listOf(nId to (if (newer) w4 else w3)), atOpen.get())
            quiesce(vm)
            assertEquals(songY.id, onMain { vm.currentProjectId })
            assertEquals("${songs()}", listOf(nId to (if (newer) w4 else w3)), others(copyId).map { it.id to it.lyrics })
        } finally {
            gate.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun aWelcomeOpenSwapsOnlyAfterTheRecoverysFirstCommit() = aWelcomeOpenWaitsForTheRecoverysFirstCommit(newer = false, fail = false)

    @Test fun aWelcomeOpenWritesNewerWordsBeforeItSwaps() = aWelcomeOpenWaitsForTheRecoverysFirstCommit(newer = true, fail = false)

    @Test fun aWelcomeOpenWhoseRecoveryFailsOpensNothing() = aWelcomeOpenWaitsForTheRecoverysFirstCommit(newer = false, fail = true)

    /** A clean draft on N whose first commit failed: a hold (backup restore) runs nothing until Retry stores N. */
    @Test fun aHoldOnARecoveryWhoseFirstCommitFailedRunsNothing() {
        newerOpenSong()
        val vm = openSongInEditor()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            RecoveryTestHooks.failNextRecovery.set(true)
            instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
            waitUntil({ "status ${vm.saveStatus}" }) { onMain { vm.saveStatus == SaveStatus.FAILED && vm.notebookSaving == 0 } }
            val nId = onMain { vm.currentProjectId }!!
            val before = songs()
            instrumentation.runOnMainSync { vm.restoreFromBackup() }
            SystemClock.sleep(500)
            waitUntil({ "status ${vm.backupStatus} busy ${vm.backupBusyLabel} notice ${vm.backupNotice}" }) {
                onMain { vm.backupBusyLabel == null && vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
            }
            assertTrue("${vm.backupNotice}", onMain { vm.backupNotice }!!.startsWith("Your open draft could not be saved"))
            assertEquals(before, songs())
            assertEquals(nId, onMain { vm.currentProjectId })
            assertEquals(heldEdits, onMain { vm.lyrics })
            instrumentation.runOnMainSync { vm.retrySave() }
            quiesce(vm)
            assertEquals("${songs()}", listOf(nId to heldEdits), others(copyId).map { it.id to it.lyrics })
            assertEquals(1, notebook(nId).alternates.count { it.text == "kept line" })
        } finally {
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** Behind Welcome the chooser lists the pending N: a send to it waits for N's first commit and appends where it was stored. */
    private fun aMenuSendToThePendingRecoveryAppendsWhereItWasStored(redraw: Boolean) {
        newerOpenSong()
        val vm = openSongInEditor(otherSongs = listOf(songY))
        var copyId = ""
        failingRefresh { copyId = editCopyInPlaceInWindowB() }
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            editAndRestore(vm)
            val yNotebook = notebook(songY.id)
            RecoveryTestHooks.beforeRecoveryInsert = { if (!parked.isCompleted) { parked.complete(Unit); release.await() } }
            instrumentation.runOnMainSync { vm.showStartMenu = true }
            val drawn = if (redraw) songY.id else null
            fun keep() { instrumentation.runOnMainSync { vm.keepAlternate("kept line") }; waitUntil({ "N parked" }) { parked.isCompleted } }
            if (drawn != null) firstSongIdIs(drawn) { keep() } else keep()
            val pending = onMain { vm.projects.first { it.id == vm.currentProjectId } }
            withOneLiner(vm) { line ->
                val sent = send(vm, line, pending)
                SystemClock.sleep(300)
                val early = if (sent.isCompleted) sent.getCompleted() else null
                release.complete(Unit)
                val message = result(sent)
                quiesce(vm)
                val n = others(copyId)
                assertEquals("$message ${songs()}", listOf(appended(heldEdits)), n.map { it.lyrics })
                assertTrue(message, message.startsWith("Sent to"))
                assertEquals(n.single().id, marker(vm, line.id))
                assertEquals(1, notebook(n.single().id).alternates.count { it.text == "kept line" })
                assertEquals(songY.lyrics, songs().single { it.id == songY.id }.lyrics)
                assertEquals(yNotebook, notebook(songY.id))
                assertWindowBKeptTheCopy(copyId, heldEdits)
                assertEquals(windowBWords, songs().single { it.id == copyId }.lyrics)
                assertEquals("sent before N was stored", null, early)
            }
        } finally {
            release.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun aMenuSendToThePendingRecoveryAppendsWhereItWasStored() = aMenuSendToThePendingRecoveryAppendsWhereItWasStored(redraw = false)

    @Test fun aMenuSendToAPendingRecoveryAcrossARedrawLeavesTheOccupantAlone() = aMenuSendToThePendingRecoveryAppendsWhereItWasStored(redraw = true)

    /**
     * T10(b) restaged: fields empty and the sole explicit action is a Keep queued behind a recording admission that holds the
     * copy's lock and is refused. The Keep is registered before it waits, so N is reserved for it; it completes only with N.
     */
    @Test fun aSoleKeepQueuedBehindARefusedAdmissionOnAnEmptiedDraftIsKept() {
        newerOpenSong()
        val vm = openSongInEditor()
        val waiting = java.util.concurrent.atomic.AtomicBoolean(false)
        val nParked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val nRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            val bTuple = storedKeys()
            blankDraft(vm, "")
            parkInsideCopyLock(parked, release)
            val admitted = admit(vm)
            waitUntil({ "admission holds the copy's lock" }) { parked.isCompleted }
            NotebookTestHooks.onJoinWait = { id -> if (id == copyId) waiting.set(true) }
            instrumentation.runOnMainSync { vm.keepAlternate("kept line") }
            waitUntil({ "Keep waiting at the lock" }) { waiting.get() }
            RecoveryTestHooks.beforeRecoveryInsert = { if (!nParked.isCompleted) { nParked.complete(Unit); nRelease.await() } }
            release.complete(Unit)
            assertTrue("${result(admitted)}", result(admitted).isFailure)
            // Either N's first write parks, or (no reservation) the Keep settles without one: the rows below decide.
            waitUntil({ "N parked or the Keep settled" }) { nParked.isCompleted || onMain { vm.notebookSaving == 0 } }
            // Not acknowledged before its own write: the Keep is still saving while N is unstored.
            val savingWhileParked = onMain { vm.notebookSaving }
            nRelease.complete(Unit)
            quiesce(vm)
            val n = others(copyId)
            assertEquals("${songs()}", listOf(Triple("Untitled Song", "", "")), n.map { Triple(it.title, it.lyrics, it.theme) })
            assertEquals("${notebook(n.single().id)}", 1, notebook(n.single().id).alternates.count { it.text == "kept line" })
            assertWindowBKeptTheCopy(copyId, heldEdits)
            assertFalse(hasLine(copyId, "kept line"))
            assertEquals(bTuple, storedKeys())
            assertTrue("N's first write parked", nParked.isCompleted)
            assertEquals(1, savingWhileParked)
        } finally {
            release.complete(Unit)
            nRelease.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /**
     * T11a, STOP on N: an open-song send holds the copy's lock behind a refusing Keep, so the editor is already on N with the
     * speculative line when STOP flushes. That flush joins N's first commit and keeps no version with the line.
     */
    @Test fun aStopOnTheNewSongBeforeTheSendIsUndoneKeepsNoSpeculativeVersion() {
        newerOpenSong()
        val vm = openSongInEditor(activity = true)
        try {
            val copyId = unconfirmedChangedCopy(vm)
            withOneLiner(vm) { line ->
                val release = parkKeepAt(vm, copyId)
                DraftSaveTestHooks.beforeWrite = kotlinx.coroutines.CompletableDeferred(Unit)
                val sent = send(vm, line, songs().single { it.id == copyId })
                waitUntil({ "send queued" }) { DraftSaveTestHooks.beforeWrite == null }
                val sendParked = kotlinx.coroutines.CompletableDeferred<Unit>()
                val sendRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
                parkInsideCopyLock(sendParked, sendRelease)
                release.complete(Unit)
                waitUntil({ "send holds the copy's lock after the switch" }) { sendParked.isCompleted }
                val nId = onMain { vm.currentProjectId }!!
                assertTrue(nId != copyId)
                assertTrue(onMain { vm.lyrics }.contains("a sent line"))
                // STOP must start its own flush of the speculative words, not queue behind another save (V: flushCurrentDraft).
                val queued = java.util.concurrent.atomic.AtomicBoolean(false)
                RecoveryTestHooks.onNavigationQueued = { queued.set(true) }
                assertFalse("a save was already running before STOP", onMain { vm.savingBeforeNavigation })
                scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
                instrumentation.waitForIdleSync()
                RecoveryTestHooks.onNavigationQueued = null
                assertFalse("STOP queued instead of flushing", queued.get())
                assertTrue("STOP's flush joined N", onMain { vm.savingBeforeNavigation })
                sendRelease.complete(Unit)
                val message = result(sent)
                quiesce(vm)
                assertTrue(message, message.startsWith("Couldn't add the line"))
                assertEquals(null, marker(vm, line.id))
                assertEquals("${songs()}", listOf(nId to heldEdits), others(copyId).map { it.id to it.lyrics })
                assertTrue("${notebook(nId)}", notebook(nId).versions.none { it.lyrics.contains("a sent line") })
                assertEquals(1, notebook(nId).alternates.count { it.text == "kept line" })
                assertWindowBKeptTheCopy(copyId, heldEdits)
                assertEquals(windowBWords, songs().single { it.id == copyId }.lyrics)
            }
        } finally {
            DraftSaveTestHooks.insideCopyLock = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /** T12 restaged: a fresh admission while N's first commit is parked waits, then returns the sole N with X and the Keep intact. */
    @Test fun aRecordingAdmissionWhileTheRecoveryIsParkedReturnsTheSoleNewSong() {
        newerOpenSong()
        val vm = openSongInEditor()
        val nParked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val nRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            val copyId = unconfirmedChangedCopy(vm)
            val release = parkKeepAt(vm, copyId)
            DraftSaveTestHooks.beforeWrite = kotlinx.coroutines.CompletableDeferred(Unit)
            val first = admit(vm)
            waitUntil({ "admission queued" }) { DraftSaveTestHooks.beforeWrite == null }
            RecoveryTestHooks.beforeRecoveryInsert = { if (!nParked.isCompleted) { nParked.complete(Unit); nRelease.await() } }
            release.complete(Unit)
            assertTrue("${result(first)}", result(first).isFailure)
            waitUntil({ "N parked" }) { nParked.isCompleted }
            val nId = onMain { vm.currentProjectId }!!
            val second = admit(vm)
            SystemClock.sleep(500)
            assertFalse("admitted before N was stored", second.isCompleted)
            assertEquals(emptyList<SongProject>(), others(copyId))
            nRelease.complete(Unit)
            assertEquals(nId, result(second).getOrThrow())
            quiesce(vm)
            assertEquals("${songs()}", listOf(nId to heldEdits), others(copyId).map { it.id to it.lyrics })
            assertEquals(1, notebook(nId).alternates.count { it.text == "kept line" })
            assertWindowBKeptTheCopy(copyId, heldEdits)
            assertEquals(windowBWords, songs().single { it.id == copyId }.lyrics)
        } finally {
            nRelease.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    /**
     * T13 restaged: fields empty; Restore Version is the only registered action, queued behind a recording admission that holds
     * the copy's lock and is refused. Nothing is applied while N is unstored; on failure nothing is restored, on success the
     * callback follows N's durable checkpoint and the version's words land on N only.
     */
    private fun aSoleRestoreBehindARefusedAdmissionAppliesOnlyAfterItsWrite(fail: Boolean) {
        newerOpenSong()
        val vm = openSongInEditor()
        val waiting = java.util.concurrent.atomic.AtomicBoolean(false)
        val nParked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val nRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
        val parked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        val v1 = com.rhymeai.app.data.model.DraftVersion(title = "Untitled Song", lyrics = "version words", theme = "", createdAt = 50L)
        val atCallback = java.util.concurrent.atomic.AtomicReference<List<String>?>(null)
        try {
            val copyId = unconfirmedChangedCopy(vm)
            blankDraft(vm, "")
            parkInsideCopyLock(parked, release)
            val admitted = admit(vm)
            waitUntil({ "admission holds the copy's lock" }) { parked.isCompleted }
            NotebookTestHooks.onJoinWait = { id -> if (id == copyId) waiting.set(true) }
            instrumentation.runOnMainSync {
                vm.restoreDraftVersion(v1) {
                    val id = checkNotNull(vm.currentProjectId)
                    // An emptied draft takes no checkpoint (SongWorkspace.checkpoint skips blank fields): N's stored row is the write.
                    atCallback.set(listOf(id, songs().any { it.id == id }.toString()))
                }
            }
            waitUntil({ "restore waiting at the lock" }) { waiting.get() }
            RecoveryTestHooks.beforeRecoveryInsert = { if (!nParked.isCompleted) { nParked.complete(Unit); nRelease.await() } }
            if (fail) RecoveryTestHooks.failNextRecovery.set(true)
            release.complete(Unit)
            assertTrue("${result(admitted)}", result(admitted).isFailure)
            // Reaching the seam is only waited for here; the rows below decide (no reservation never parks).
            runCatching { waitUntil({ "N parked" }) { nParked.isCompleted } }
            val nId = onMain { vm.currentProjectId }
            val callbackWhileParked = atCallback.get()
            val lyricsWhileParked = onMain { vm.lyrics }
            nRelease.complete(Unit)
            quiesce(vm)
            if (fail) {
                assertEquals(null, atCallback.get())
                assertEquals("", onMain { vm.lyrics })
                assertEquals(emptyList<SongProject>(), others(copyId))
                assertEquals(SaveStatus.FAILED, onMain { vm.saveStatus })
            } else {
                // The callback ran on N with N already stored.
                assertEquals(listOf(nId, "true"), atCallback.get())
                assertEquals("version words", onMain { vm.lyrics })
                assertEquals("${songs()}", listOf(nId to "version words"), others(copyId).map { it.id to it.lyrics })
            }
            assertWindowBKeptTheCopy(copyId, "version words")
            assertEquals(windowBWords, songs().single { it.id == copyId }.lyrics)
            assertTrue("N's first write parked", nParked.isCompleted)
            assertEquals(null, callbackWhileParked)
            assertEquals("", lyricsWhileParked)
        } finally {
            release.complete(Unit)
            nRelease.complete(Unit)
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
        }
    }

    @Test fun aSoleRestoreBehindARefusedAdmissionIsAppliedOnlyAfterItsWrite() = aSoleRestoreBehindARefusedAdmissionAppliesOnlyAfterItsWrite(fail = false)

    @Test fun aSoleRestoreBehindARefusedAdmissionWhoseRecoveryFailsRestoresNothing() = aSoleRestoreBehindARefusedAdmissionAppliesOnlyAfterItsWrite(fail = true)

    /**
     * T14 restaged: X is an adopted, undecided copy from a failed refresh. A menu send to X is admitted before a second hold
     * holds the editor; that hold parks before its read. The append confirms X, so the hold's read finds X changed: the
     * confirmation stands, no new song, the line is on X once and the editor stays on X.
     */
    @Test fun aMenuSendConfirmingTheAdoptedCopyBeforeTheHoldsReadMakesNoNewSong() {
        newerOpenSong()
        val vm = openSongInEditor()
        val readParked = kotlinx.coroutines.CompletableDeferred<Unit>()
        val readRelease = kotlinx.coroutines.CompletableDeferred<Unit>()
        try {
            failingRefresh()
            editAndRestore(vm)
            val copyId = onMain { vm.currentProjectId }!!
            val source = songs().single { it.id == openSong.id }.lyrics
            withOneLiner(vm) { line ->
                instrumentation.runOnMainSync { vm.showStartMenu = true }
                val gate = kotlinx.coroutines.CompletableDeferred<Unit>()
                BackupTestHooks.beforeMenuSend = gate
                val sent = send(vm, line, songs().single { it.id == copyId })
                waitUntil({ "send admitted" }) { BackupTestHooks.beforeMenuSend == null }
                instrumentation.runOnMainSync { vm.showStartMenu = false }
                BackupTestHooks.beforeHoldCopyRead = { readParked.complete(Unit); readRelease.await() }
                instrumentation.runOnMainSync { vm.restoreFromBackup() }
                waitUntil({ "hold read parked" }) { readParked.isCompleted }
                assertTrue(onMain { vm.editorHeld })
                gate.complete(Unit)
                val message = result(sent)
                assertTrue(message, message.startsWith("Sent to"))
                assertEquals(appended(heldEdits), songs().single { it.id == copyId }.lyrics)
                readRelease.complete(Unit)
                waitUntil({ "status ${vm.backupStatus} held ${vm.editorHeld}" }) { vm.backupStatus is BackupStatus.Connected && !vm.editorHeld }
                quiesce(vm)
                assertEquals("${songs()}", emptyList<SongProject>(), others(copyId))
                assertEquals(appended(heldEdits), songs().single { it.id == copyId }.lyrics)
                assertEquals(copyId, marker(vm, line.id))
                assertEquals(copyId, onMain { vm.currentProjectId })
                assertEquals(source, songs().single { it.id == openSong.id }.lyrics)
            }
        } finally {
            readRelease.complete(Unit)
            BackupTestHooks.beforeHoldCopyRead = null
            BackupTestHooks.beforeMenuSend = null
            BackupTestHooks.beforeHoldListRefresh = null
            resetOpenSong()
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
        /** Runs before every download (a test pauses a restore here). */
        @Volatile var beforeDownload: (suspend () -> Unit)? = null

        fun put(name: String, bytes: ByteArray) {
            val id = files.entries.firstOrNull { it.value.first == name }?.key ?: "id-${nextId++}"
            files[id] = name to bytes
        }
        fun bytes(name: String) = files.values.firstOrNull { it.first == name }?.second

        override suspend fun findFileByName(accessToken: String, name: String) =
            files.entries.firstOrNull { it.value.first == name }?.let { DriveFileMetadata(it.key, name, version = it.value.second.size.toString()) }
        override suspend fun listFilesByNamePrefix(accessToken: String, namePrefix: String) =
            files.filter { it.value.first.startsWith(namePrefix) }.map { DriveFileMetadata(it.key, it.value.first) }
        override suspend fun downloadFile(accessToken: String, fileId: String, maxBytes: Long): ByteArray {
            beforeDownload?.invoke()
            return files.getValue(fileId).second
        }
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
        override suspend fun listRevisions(accessToken: String, fileId: String) = emptyList<com.rhymeai.app.data.sync.DriveRevision>()
        override suspend fun keepRevisionForever(accessToken: String, fileId: String, revisionId: String) {}
        override suspend fun downloadRevision(accessToken: String, fileId: String, revisionId: String, maxBytes: Long): ByteArray =
            error("no revisions in this fake")
        override suspend fun revokeToken(token: String) {
            revoked += token
        }
    }
}
