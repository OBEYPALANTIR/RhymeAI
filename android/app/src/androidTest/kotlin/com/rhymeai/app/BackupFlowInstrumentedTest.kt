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
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.withTimeout
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
 * into the next test, and empties [viewModels]. Bounded: a join that never returns fails the test instead of hanging the run.
 */
internal fun stopViewModels(viewModels: MutableList<MainViewModel>) {
    try {
        runBlocking { withTimeout(10_000) { viewModels.forEach { it.viewModelScope.coroutineContext[Job]!!.cancelAndJoin() } } }
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
     */
    private fun declineThenEndThePauseWithASongHere(vm: MainViewModel) {
        val before = drive.bytes(BackupManifest.FILE_NAME)
        instrumentation.runOnMainSync {
            check(vm.restoreOffer != null) { "The first background flush must run while the restore offer stops it." }
            vm.triggerBackgroundDriveSync()
        }
        compose.onNodeWithText("Not now").performClick()
        waitUntil { vm.backupStatus == BackupStatus.Paused(2) }
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
        stopViewModels(handBuilt)
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
    private val newerWords = "newer words W2"

    /** Song A with W1 open in the editor of a real view model, Drive connected to [drive]. */
    private fun openSongInEditor(trash: List<TrashedSongProject> = emptyList(), otherSongs: List<SongProject> = emptyList(), draft: String? = null): MainViewModel {
        check(context.packageName == "com.rhymeai.app.motionqa") { "Backup fixtures require the owned isolated QA app." }
        repo = ProjectRepository(context)
        runBlocking {
            savedProjects = repo.projectsFlow.first()
            savedTrash = repo.trashedProjectsFlow.first()
            repo.saveProjects(emptyList())
            repo.saveTrashedProjects(emptyList())
            repo.saveActiveState(openSong, true, openSong.title, openSong.lyrics, openSong.theme)
            // After the save: a same-id Trash entry makes saveActiveState refuse to create the song.
            repo.saveTrashedProjects(trash)
            if (otherSongs.isNotEmpty()) repo.saveProjects(repo.projectsFlow.first() + otherSongs)
            // An interrupted save's draft: the editor's saved words differ from the song's row.
            if (draft != null) repo.saveEditorState(openSong.title, draft, openSong.theme)
        }
        BackupTestHooks.driveClient = drive
        BackupTestHooks.authorizer = object : DriveAuthorizer {
            override suspend fun authorize() = DriveAuthorization.Granted("token")
        }
        prefs().edit().clear().putBoolean("drive_connected", true).commit()
        val vm = MainViewModel(context.applicationContext as android.app.Application).also(handBuilt::add)
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
            stopViewModels(handBuilt)
        } finally {
            runBlocking {
                repo.setCurrentProjectId(null)
                repo.saveEditorState("", "", "")
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
            runBlocking { repo.saveActiveState(openSong.copy(lyrics = newerWords, updatedAt = 200L), false, openSong.title, newerWords, openSong.theme) }
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
            runBlocking { repo.saveActiveState(storedOpenSong().copy(lyrics = newerWords, updatedAt = System.currentTimeMillis()), false, openSong.title, newerWords, openSong.theme) }
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
            runBlocking { repo.saveActiveState(openSong.copy(lyrics = newerWords, updatedAt = 200L), false, openSong.title, newerWords, openSong.theme) }
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
                context.dataStore.edit { workspaces = it[workspacesKey]; it[workspacesKey] = "{not json" }
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
            // Ends the stopped view model (and the relaunched one); its cleanup runs now, after the checks.
            stopViewModels(handBuilt)
            waitUntil({ "dying held ${dying.editorHeld}" }) { !dying.editorHeld }
            runBlocking {
                context.dataStore.edit { if (workspaces == null) it.remove(workspacesKey) else it[workspacesKey] = workspaces!! }
            }
            resetOpenSong()
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
