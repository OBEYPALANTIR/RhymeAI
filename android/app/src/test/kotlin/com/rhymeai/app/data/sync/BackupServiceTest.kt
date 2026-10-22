package com.rhymeai.app.data.sync

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.SecureKeyStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.ByteArrayInputStream
import java.io.File
import java.util.Base64
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The whole backup, restore and migration flow against an in-memory Drive and a real repository. */
class BackupServiceTest {
    private val root = kotlin.io.path.createTempDirectory("rhymeai-backup").toFile()
    private val filesDir = File(root, "files").also { it.mkdirs() }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val keys = MemoryKeyStore()
    private val repository = ProjectRepository(
        PreferenceDataStoreFactory.create(scope = scope) { File(root, "prefs.preferences_pb") },
        keys
    )
    private val drive = FakeDrive()
    private val auth = FakeAuthorizer()
    private val clock = 1_792_702_991_000L
    private val service = DriveSyncService(filesDir, keys, drive, auth, clientId = { "test-device" }, now = { clock })
    private val passphrase = "correct horse battery staple"
    private val legacyJson = Json { encodeDefaults = true }

    @AfterTest
    fun tearDown() {
        scope.cancel()
        root.deleteRecursively()
    }

    private fun song(id: String, updatedAt: Long = 100L, lyrics: String = "lyrics of $id") =
        SongProject(id = id, title = id, lyrics = lyrics, theme = "", updatedAt = updatedAt)

    private fun writeMemo(projectId: String, fileName: String, bytes: ByteArray, modifiedAt: Long = 1_000L): RecordingManifestEntry {
        val file = RecordingFileStore.targetFile(filesDir, projectId, fileName)
        file.parentFile!!.mkdirs()
        file.writeBytes(bytes)
        file.setLastModified(modifiedAt)
        return RecordingManifestEntry(projectId, fileName, sizeBytes = bytes.size.toLong(), modifiedAt = modifiedAt, sha256 = BackupManifest.sha256Hex(bytes))
    }

    private fun entry(projectId: String, fileName: String, bytes: ByteArray, uploadedAt: Long = 5_000L) =
        RecordingManifestEntry(projectId, fileName, sizeBytes = bytes.size.toLong(), modifiedAt = 5L, sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = uploadedAt)

    private fun putRaw(entry: RecordingManifestEntry, bytes: ByteArray) =
        drive.put(BackupManifest.recordingDriveName(entry.projectId, entry.fileName), bytes, recordingAppProperties(entry))

    private fun putRemote(blob: SyncBlob) {
        drive.put(BackupManifest.FILE_NAME, BackupManifest.encode(blob, 1_000L, "other-device"))
    }

    private fun remote(): SyncBlob = BackupManifest.decode(drive.bytes(BackupManifest.FILE_NAME)!!)

    private fun putLegacy(blob: SyncBlob, recordings: Map<RecordingManifestEntry, ByteArray> = emptyMap()) {
        val json = legacyJson.encodeToString(blob).toByteArray()
        drive.put(SyncBlob.DRIVE_FILE_NAME, LegacyEnvelopes.sealManifest(json, passphrase.toCharArray()))
        recordings.forEach { (entry, bytes) -> drive.put(entry.driveName, LegacyEnvelopes.seal(bytes, passphrase.toCharArray())) }
    }

    @Test
    fun boundedDriveReadAcceptsExactLimitAndRejectsOverflow() {
        val exact = ByteArray(8) { it.toByte() }
        assertContentEquals(exact, ByteArrayInputStream(exact).readBytesBounded(8L))
        assertFailsWith<DriveNetworkException> { ByteArrayInputStream(exact).readBytesBounded(7L) }
    }

    @Test
    fun backupMergesIntoDriveWritesRawRecordingsAndLeavesThisDeviceAlone() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("here")))
        val memo = writeMemo("here", "take.m4a", "raw audio".toByteArray())
        putRemote(SyncBlob(projects = listOf(song("elsewhere"))))

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(setOf("here", "elsewhere"), remote().projects.map { it.id }.toSet())
        val listed = remote().recordings.single()
        assertEquals(memo.identityKey, listed.identityKey)
        assertEquals(clock, listed.uploadedAt)
        val uploaded = drive.file("rec_here_take.m4a")!!
        assertContentEquals("raw audio".toByteArray(), uploaded.bytes)
        assertEquals(
            mapOf("projectId" to "here", "fileName" to "take.m4a", "sha256" to memo.sha256, "bytes" to "9"),
            uploaded.appProperties
        )
        assertEquals(listOf("here"), repository.projectsFlow.first().map { it.id })
        assertFalse(result.legacyBackupPresent)

        // A second backup finds the raw file on Drive and does not upload it again.
        val uploadsBefore = drive.uploads
        service.backUp(repository)
        assertEquals(uploadsBefore, drive.uploads)
        assertEquals(clock, remote().recordings.single().uploadedAt)
    }

    @Test
    fun restoreMergesBothWaysAndDownloadsOnlyVerifiedMissingRecordings() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("here")))
        val good = "good take".toByteArray()
        val goodEntry = entry("elsewhere", "good.m4a", good)
        val badEntry = entry("elsewhere", "bad.m4a", "expected".toByteArray())
        putRemote(SyncBlob(projects = listOf(song("elsewhere")), recordings = listOf(goodEntry, badEntry)))
        putRaw(goodEntry, good)
        putRaw(badEntry, "tampered".toByteArray())

        val result = assertIs<SyncResult.Success>(service.restore(repository))

        assertEquals(setOf("here", "elsewhere"), repository.projectsFlow.first().map { it.id }.toSet())
        assertEquals(setOf("here", "elsewhere"), remote().projects.map { it.id }.toSet())
        assertContentEquals(good, RecordingFileStore.targetFile(filesDir, "elsewhere", "good.m4a").readBytes())
        assertFalse(RecordingFileStore.targetFile(filesDir, "elsewhere", "bad.m4a").exists())
        assertEquals(1, result.damagedRecordings)
    }

    @Test
    fun restoreNeverReplacesALocalRecording() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        writeMemo("p", "take.m4a", "mine".toByteArray())
        val theirs = "theirs".toByteArray()
        val listed = entry("p", "take.m4a", theirs)
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(listed)))
        putRaw(listed, theirs)

        assertIs<SyncResult.Success>(service.restore(repository))

        assertContentEquals("mine".toByteArray(), RecordingFileStore.targetFile(filesDir, "p", "take.m4a").readBytes())
    }

    @Test
    fun restoreWithoutABackupSaysSoAndWritesNothing() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("here")))
        assertEquals(SyncResult.NoBackup, service.restore(repository))
        assertNull(drive.bytes(BackupManifest.FILE_NAME))
    }

    @Test
    fun hashMismatchedManifestIsRefusedAndNeverOverwrittenOrMerged() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("here")))
        putRemote(SyncBlob(projects = listOf(song("elsewhere", lyrics = "original"))))
        val tampered = drive.bytes(BackupManifest.FILE_NAME)!!.toString(Charsets.UTF_8)
            .replace("original", "rewritten").toByteArray()
        drive.put(BackupManifest.FILE_NAME, tampered)

        assertEquals(SyncResult.CorruptRemote, service.backUp(repository))
        assertEquals(SyncResult.CorruptRemote, service.restore(repository))
        assertIs<ProbeResult.Failed>(service.probe())

        assertContentEquals(tampered, drive.bytes(BackupManifest.FILE_NAME))
        assertEquals(listOf("here"), repository.projectsFlow.first().map { it.id })
    }

    @Test
    fun tombstonesApplyByTimestampPrecedence() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("edited-later", updatedAt = 9_999L), song("stale", updatedAt = 10L), song("kept")))
        putRemote(
            SyncBlob(
                deletions = listOf(SyncDeletion("edited-later", deletedAt = 1_000L), SyncDeletion("stale", deletedAt = 1_000L))
            )
        )

        assertIs<SyncResult.Success>(service.restore(repository))

        // The newer edit survives and its older tombstone is dropped; the stale song goes.
        assertEquals(setOf("edited-later", "kept"), repository.projectsFlow.first().map { it.id }.toSet())
        assertEquals(setOf("edited-later", "kept"), remote().projects.map { it.id }.toSet())
        assertEquals(listOf(SyncDeletion("stale", deletedAt = 1_000L)), remote().deletions)
    }

    @Test
    fun recordingTombstonesApplyByUploadTime() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val old = writeMemo("p", "old.m4a", "old".toByteArray(), modifiedAt = 1_000L)
        writeMemo("p", "new.m4a", "new".toByteArray(), modifiedAt = 9_000L)
        putRemote(
            SyncBlob(
                projects = listOf(song("p")),
                deletions = listOf(SyncDeletion("p", "old.m4a", 5_000L), SyncDeletion("p", "new.m4a", 5_000L))
            )
        )

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(listOf("p/new.m4a"), remote().recordings.map { it.identityKey })
        assertNull(drive.file(BackupManifest.recordingDriveName(old.projectId, old.fileName)))
        assertEquals(listOf(SyncDeletion("p", "old.m4a", 5_000L)), remote().deletions)
    }

    @Test
    fun pendingLocalDeletionIsNeverUploaded() = runBlocking<Unit> {
        repository.saveTrashedProjects(listOf(TrashedSongProject(song("binned"), deletedAt = 500L)))
        writeMemo("binned", "take.m4a", "audio".toByteArray())
        assertNotNull(repository.permanentlyDeleteTrashedProject("binned"))
        assertTrue("binned" in repository.pendingRecordingDeletionIds())

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertTrue(remote().recordings.isEmpty())
        assertNull(drive.file("rec_binned_take.m4a"))
        assertTrue(remote().deletions.any { it.projectId == "binned" && it.fileName == null })
    }

    @Test
    fun writerThatLandsBetweenOurWriteAndReadBackIsMergedNotLost() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("mine")))
        putRemote(SyncBlob(projects = listOf(song("seed"))))
        drive.afterManifestWrite = {
            putRemote(SyncBlob(projects = listOf(song("seed"), song("theirs"))))
        }

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(setOf("seed", "theirs", "mine"), remote().projects.map { it.id }.toSet())
        assertEquals(2, drive.manifestWrites)
    }

    @Test
    fun contentSeenInAnEarlierAttemptSurvivesAStaleWriterInBetween() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("L")))
        putRemote(SyncBlob(projects = listOf(song("R"))))
        // A stale device overwrites the manifest with only T right after our write.
        drive.afterManifestWrite = { putRemote(SyncBlob(projects = listOf(song("T")))) }

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(setOf("R", "L", "T"), remote().projects.map { it.id }.toSet())
    }

    @Test
    fun aConflictingReadBackIsKeptEvenWhenAnotherWriterReplacesItBeforeTheRetry() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("L")))
        putRemote(SyncBlob(projects = listOf(song("R"))))
        drive.afterManifestWrite = {
            putRemote(SyncBlob(projects = listOf(song("T"))))
            // Our read-back sees T; then a stale writer replaces it with U before the retry reads.
            drive.afterNextDownload = { putRemote(SyncBlob(projects = listOf(song("U")))) }
        }

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(setOf("R", "L", "T", "U"), remote().projects.map { it.id }.toSet())
    }

    @Test
    fun aStaleSongTombstoneSeenOnRetryStillDeletesTheOldTakeButNotTheNewerSong() = runBlocking<Unit> {
        val old = "old take".toByteArray()
        val listed = entry("x", "take.m4a", old, uploadedAt = 1_000L)
        putRemote(SyncBlob(projects = listOf(song("x", updatedAt = 100L)), recordings = listOf(listed)))
        putRaw(listed, old)
        repository.saveProjects(listOf(song("x", updatedAt = 9_000L)))
        writeMemo("x", "new.m4a", "new take".toByteArray(), modifiedAt = 9_500L)
        // While the new take uploads, a stale device writes a song tombstone (5000) with no recording tombstone.
        drive.onRecordingUpload = { putRemote(SyncBlob(deletions = listOf(SyncDeletion("x", deletedAt = 5_000L)))) }

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(listOf("x"), remote().projects.map { it.id })
        assertEquals(listOf("x/new.m4a"), remote().recordings.map { it.identityKey })
        assertEquals(listOf(SyncDeletion("x", "take.m4a", 5_000L)), remote().deletions)
        assertEquals(1, drive.count("rec_x_new.m4a"))
    }

    @Test
    fun aRemoteTombstoneThatArrivesDuringUploadsIsMergedBeforeTheFinalWrite() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("doomed", updatedAt = 1_000L), song("kept")))
        writeMemo("doomed", "take.m4a", "audio".toByteArray(), modifiedAt = 1_000L)
        putRemote(SyncBlob(projects = listOf(song("kept"))))
        // Another device deletes the song forever while our recording uploads (a minute later).
        drive.onRecordingUpload = {
            putRemote(SyncBlob(projects = listOf(song("kept")), deletions = listOf(SyncDeletion("doomed", deletedAt = clock + 60_000L))))
        }

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(listOf("kept"), remote().projects.map { it.id })
        assertTrue(remote().recordings.isEmpty())
        assertTrue(remote().deletions.any { it.projectId == "doomed" && it.fileName == null })
        // The retry does not upload the recording a second time.
        assertEquals(1, drive.count("rec_doomed_take.m4a"))
        assertEquals(1, drive.uploads) // the one recording upload; the manifest was updated in place
        // This device still has its song: Back up never changes local data.
        assertEquals(setOf("doomed", "kept"), repository.projectsFlow.first().map { it.id }.toSet())
    }

    @Test
    fun revivingASongDoesNotBringBackItsDeletedRecordings() = runBlocking<Unit> {
        val audio = "old take".toByteArray()
        val listed = entry("x", "take.m4a", audio, uploadedAt = 1_000L)
        // Another device deleted song x forever at 5000; Drive still listed its old take.
        putRemote(SyncBlob(recordings = listOf(listed), deletions = listOf(SyncDeletion("x", deletedAt = 5_000L))))
        putRaw(listed, audio)
        // This device edited x afterwards and still holds the old audio.
        repository.saveProjects(listOf(song("x", updatedAt = 9_000L)))
        writeMemo("x", "take.m4a", audio, modifiedAt = 1_000L)

        repeat(2) {
            assertIs<SyncResult.Success>(service.backUp(repository))
            assertEquals(listOf("x"), remote().projects.map { it.id }, "backup ${it + 1}")
            assertTrue(remote().recordings.isEmpty(), "backup ${it + 1}")
            assertEquals(listOf(SyncDeletion("x", "take.m4a", 5_000L)), remote().deletions, "backup ${it + 1}")
        }

        // An offline device that kept the old song and audio backs up later.
        val offlineRoot = kotlin.io.path.createTempDirectory("rhymeai-offline").toFile()
        try {
            val offlineFiles = File(offlineRoot, "files").also { it.mkdirs() }
            val offlineRepo = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(offlineRoot, "prefs.preferences_pb") }, MemoryKeyStore()
            )
            offlineRepo.saveProjects(listOf(song("x", updatedAt = 100L)))
            RecordingFileStore.targetFile(offlineFiles, "x", "take.m4a").apply { parentFile!!.mkdirs(); writeBytes(audio); setLastModified(1_000L) }
            val offline = DriveSyncService(offlineFiles, MemoryKeyStore(), drive, auth, clientId = { "offline" }, now = { clock })

            assertIs<SyncResult.Success>(offline.backUp(offlineRepo))

            assertTrue(remote().recordings.isEmpty())
            assertEquals(9_000L, remote().projects.single().updatedAt)
        } finally {
            offlineRoot.deleteRecursively()
        }
    }

    @Test
    fun aRawFileWithoutMatchingMetadataIsUploadedAgain() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val memo = writeMemo("p", "take.m4a", "healthy".toByteArray())
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(memo.copy(uploadedAt = 2_000L))))
        drive.put("rec_p_take.m4a", "damaged".toByteArray()) // no appProperties

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertContentEquals("healthy".toByteArray(), drive.bytes("rec_p_take.m4a"))
        assertEquals(memo.sha256, drive.file("rec_p_take.m4a")!!.appProperties["sha256"])
        assertEquals(1, drive.count("rec_p_take.m4a"))
    }

    @Test
    fun aDeletedOlderRecordingIsPreservedRawBeforeTheOlderBackupIsRemoved() = runBlocking<Unit> {
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        val audio = "deleted take".toByteArray()
        val old = entry("legacy", "deleted.m4a", audio, uploadedAt = 0L)
        putLegacy(
            SyncBlob(projects = listOf(song("legacy")), recordings = listOf(old), deletions = listOf(SyncDeletion("legacy", "deleted.m4a", 9_000L))),
            mapOf(old to audio)
        )

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertTrue(result.migratedLegacyBackup)
        // Not listed (it was deleted), but its bytes are kept raw rather than destroyed.
        assertTrue(remote().recordings.isEmpty())
        assertContentEquals(audio, drive.bytes("rec_legacy_deleted.m4a"))
        assertNull(drive.bytes(old.driveName))
    }

    @Test
    fun aDeletedOlderRecordingThatCannotMoveKeepsTheOlderBackup() = runBlocking<Unit> {
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        val old = entry("legacy", "deleted.m4a", "never uploaded".toByteArray(), uploadedAt = 0L)
        putLegacy(SyncBlob(projects = listOf(song("legacy")), recordings = listOf(old), deletions = listOf(SyncDeletion("legacy", "deleted.m4a", 9_000L))))

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertFalse(result.migratedLegacyBackup)
        assertEquals(1, result.unmovedLegacyRecordings)
        assertNotNull(drive.bytes(SyncBlob.DRIVE_FILE_NAME))
    }

    @Test
    fun backUpLeavesAnInterruptedRestoreAloneAndRestoreFinishesIt() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val stage = java.nio.file.Files.createTempDirectory(filesDir.toPath(), RecordingFileStore.RESTORE_STAGE_PREFIX).toFile()
        val bytes = "half restored".toByteArray()
        RecordingFileStore.stageRestore(stage, 0, entry("p", "staged.m4a", bytes), bytes)
        val mine = writeMemo("p", "mine.m4a", "mine".toByteArray())

        assertIs<SyncResult.Success>(service.backUp(repository))
        assertTrue(stage.exists())

        assertIs<SyncResult.Success>(service.restore(repository))
        assertFalse(stage.exists())
        assertContentEquals("mine".toByteArray(), RecordingFileStore.targetFile(filesDir, mine.projectId, mine.fileName).readBytes())
    }

    @Test
    fun aWriterThatNeverStopsIsReportedAsAConflict() = runBlocking<Unit> {
        putRemote(SyncBlob(projects = listOf(song("seed"))))
        var round = 0
        drive.keepInterfering = { putRemote(SyncBlob(projects = listOf(song("other-${round++}")))) }

        val result = assertIs<SyncResult.NetworkError>(service.backUp(repository))
        assertEquals("Backup conflict, will retry", result.message)
    }

    @Test
    fun duplicateManifestsAreMergedAndTheOlderOnesRemovedAfterVerification() = runBlocking<Unit> {
        drive.add(BackupManifest.FILE_NAME, BackupManifest.encode(SyncBlob(projects = listOf(song("older"))), 0L, "a"))
        drive.add(BackupManifest.FILE_NAME, BackupManifest.encode(SyncBlob(projects = listOf(song("newer"))), 0L, "b"))

        assertEquals(2, assertIs<ProbeResult.Ready>(service.probe()).probe.projectCount)
        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(1, drive.count(BackupManifest.FILE_NAME))
        assertEquals(setOf("older", "newer"), remote().projects.map { it.id }.toSet())
    }

    @Test
    fun probeCountsSongsAndRecordingsAndSeesTheOlderBackup() = runBlocking<Unit> {
        putRemote(SyncBlob(projects = listOf(song("a"), song("b")), recordings = listOf(entry("a", "x.m4a", byteArrayOf(1)))))
        putLegacy(SyncBlob())
        assertEquals(BackupProbe(2, 1, legacyBackupPresent = true), assertIs<ProbeResult.Ready>(service.probe()).probe)
    }

    @Test
    fun migrationDecisionTable() {
        assertEquals(LegacyBackupAction.MIGRATE, decideLegacyBackupAction(legacyBackupExists = true, passphraseAvailable = true))
        assertEquals(LegacyBackupAction.OFFER_MIGRATION, decideLegacyBackupAction(legacyBackupExists = true, passphraseAvailable = false))
        assertEquals(LegacyBackupAction.FORGET_PASSPHRASE, decideLegacyBackupAction(legacyBackupExists = false, passphraseAvailable = true))
        assertEquals(LegacyBackupAction.NONE, decideLegacyBackupAction(legacyBackupExists = false, passphraseAvailable = false))
    }

    @Test
    fun storedPassphraseMigratesIntoDriveOnlyVerifiesThenDeletesTheOlderBackup() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("here"), song("shared", updatedAt = 50L, lyrics = "older here")))
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        val audio = "old take".toByteArray()
        val old = entry("legacy", "take.m4a", audio, uploadedAt = 0L)
        putLegacy(
            SyncBlob(projects = listOf(song("legacy"), song("shared", updatedAt = 80L, lyrics = "newer in legacy")), recordings = listOf(old)),
            mapOf(old to audio)
        )

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertTrue(result.migratedLegacyBackup)
        assertFalse(result.legacyBackupPresent)
        // Back up never changes this device, migration included.
        assertEquals(setOf("here", "shared"), repository.projectsFlow.first().map { it.id }.toSet())
        assertEquals("older here", repository.projectsFlow.first().single { it.id == "shared" }.lyrics)
        assertFalse(RecordingFileStore.targetFile(filesDir, "legacy", "take.m4a").exists())
        // Drive holds everything, with the newer legacy lyrics.
        assertEquals(setOf("here", "legacy", "shared"), remote().projects.map { it.id }.toSet())
        assertEquals("newer in legacy", remote().projects.single { it.id == "shared" }.lyrics)
        assertContentEquals(audio, drive.bytes("rec_legacy_take.m4a"))
        assertNull(drive.bytes(SyncBlob.DRIVE_FILE_NAME))
        assertNull(drive.bytes(old.driveName))
        assertEquals("", keys.getKey(DriveSyncService.LEGACY_PASSPHRASE_KEY))
    }

    @Test
    fun anUnmovableOlderRecordingKeepsTheOlderBackupAndThePassphrase() = runBlocking<Unit> {
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        val audio = "old take".toByteArray()
        val movable = entry("legacy", "take.m4a", audio, uploadedAt = 0L)
        val tooBig = entry("legacy", "huge.wav", byteArrayOf(1), uploadedAt = 0L)
            .copy(sizeBytes = RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES + 1)
        val missing = entry("legacy", "gone.m4a", "never uploaded".toByteArray(), uploadedAt = 0L)
        putLegacy(
            SyncBlob(projects = listOf(song("legacy")), recordings = listOf(movable, tooBig, missing)),
            mapOf(movable to audio, tooBig to byteArrayOf(1))
        )
        val legacyBytes = drive.bytes(SyncBlob.DRIVE_FILE_NAME)

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertFalse(result.migratedLegacyBackup)
        assertTrue(result.legacyBackupPresent)
        assertEquals(2, result.unmovedLegacyRecordings)
        assertContentEquals(legacyBytes, drive.bytes(SyncBlob.DRIVE_FILE_NAME))
        assertNotNull(drive.bytes(movable.driveName))
        assertNotNull(drive.bytes(tooBig.driveName))
        assertEquals(passphrase, keys.getKey(DriveSyncService.LEGACY_PASSPHRASE_KEY))
        // What could move is already safe in the new backup.
        assertContentEquals(audio, drive.bytes("rec_legacy_take.m4a"))
        assertEquals(setOf("legacy"), remote().projects.map { it.id }.toSet())
    }

    @Test
    fun aDifferentRecordingUnderTheSameNameIsNotCountedAsMoved() = runBlocking<Unit> {
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        val audio = "old take".toByteArray()
        val old = entry("legacy", "take.m4a", audio, uploadedAt = 0L)
        putLegacy(SyncBlob(projects = listOf(song("legacy")), recordings = listOf(old)), mapOf(old to audio))
        val other = entry("legacy", "take.m4a", "other bytes".toByteArray())
        putRemote(SyncBlob(projects = listOf(song("legacy")), recordings = listOf(other)))
        putRaw(other, "other bytes".toByteArray())

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(1, result.unmovedLegacyRecordings)
        assertNotNull(drive.bytes(SyncBlob.DRIVE_FILE_NAME))
        assertNotNull(drive.bytes(old.driveName))
    }

    @Test
    fun withoutAPassphraseTheOlderBackupIsLeftAloneAndOffered() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("here")))
        putLegacy(SyncBlob(projects = listOf(song("legacy"))))
        val legacyBytes = drive.bytes(SyncBlob.DRIVE_FILE_NAME)

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertTrue(result.legacyBackupPresent)
        assertFalse(result.migratedLegacyBackup)
        assertContentEquals(legacyBytes, drive.bytes(SyncBlob.DRIVE_FILE_NAME))
        assertEquals(listOf("here"), remote().projects.map { it.id })
        assertEquals(listOf("here"), repository.projectsFlow.first().map { it.id })
    }

    @Test
    fun typedPassphraseMigratesOnceAndAWrongOneChangesNothing() = runBlocking<Unit> {
        putLegacy(SyncBlob(projects = listOf(song("legacy"))))

        assertEquals(SyncResult.WrongPassphrase, service.migrateLegacyBackup(repository, "not the passphrase"))
        assertNotNull(drive.bytes(SyncBlob.DRIVE_FILE_NAME))
        assertNull(drive.bytes(BackupManifest.FILE_NAME))

        val result = assertIs<SyncResult.Success>(service.migrateLegacyBackup(repository, "  $passphrase\n"))
        assertTrue(result.migratedLegacyBackup)
        assertNull(drive.bytes(SyncBlob.DRIVE_FILE_NAME))
        assertEquals(listOf("legacy"), remote().projects.map { it.id })
        assertTrue(repository.projectsFlow.first().isEmpty())
        assertEquals("", keys.getKey(DriveSyncService.LEGACY_PASSPHRASE_KEY))
    }

    @Test
    fun storedPassphraseWithNoOlderBackupIsForgotten() = runBlocking<Unit> {
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertEquals("", keys.getKey(DriveSyncService.LEGACY_PASSPHRASE_KEY))
    }

    @Test
    fun independentIosShapedVectorsMigrateFromEveryEnvelopeVersion() = runBlocking<Unit> {
        val stream = requireNotNull(javaClass.classLoader!!.getResourceAsStream("sync-envelope-vectors.json"))
        val fixture = Json.parseToJsonElement(stream.bufferedReader().use { it.readText() }).jsonObject
        val vectorPassphrase = fixture.getValue("passphrase").jsonPrimitive.content
        repository.saveProjects(listOf(song("gone", updatedAt = 1_500L), song("keep")))
        for (vector in fixture.getValue("vectors").jsonArray.map { it.jsonObject }) {
            val magic = vector.getValue("magic").jsonPrimitive.content
            drive.clear()
            drive.put(SyncBlob.DRIVE_FILE_NAME, Base64.getDecoder().decode(vector.getValue("envelope_base64").jsonPrimitive.content))

            val result = assertIs<SyncResult.Success>(service.migrateLegacyBackup(repository, vectorPassphrase))

            assertTrue(result.migratedLegacyBackup, magic)
            assertEquals(setOf("gone", "keep"), repository.projectsFlow.first().map { it.id }.toSet(), magic)
            if (magic != "RAI1") {
                // The song was edited after its tombstones (1, 2), so it survives; the file tombstone stays.
                assertEquals(setOf("gone", "keep"), remote().projects.map { it.id }.toSet(), magic)
                assertTrue(remote().deletions.any { it.projectId == "keep" && it.fileName == "removed.m4a" }, magic)
                assertFalse(remote().deletions.any { it.projectId == "gone" && it.fileName == null }, magic)
            }
        }
    }

    @Test
    fun damagedOlderBackupIsReportedAndKept() = runBlocking<Unit> {
        drive.put(SyncBlob.DRIVE_FILE_NAME, LegacyEnvelopes.sealManifest("""{"version":3}""".toByteArray(), passphrase.toCharArray()))
        assertEquals(SyncResult.CorruptRemote, service.migrateLegacyBackup(repository, passphrase))
        assertNotNull(drive.bytes(SyncBlob.DRIVE_FILE_NAME))
    }

    @Test
    fun disconnectCountsOnlyAConfirmedRevoke() = runBlocking<Unit> {
        assertTrue(service.disconnect())
        assertEquals(listOf("token"), drive.revoked)
        assertEquals(listOf("token"), auth.forgotten)

        drive.failRevoke = true
        assertFalse(service.disconnect())

        drive.failRevoke = false
        auth.next = DriveAuthorization.Unavailable
        assertFalse(service.disconnect())
        assertEquals(listOf("token"), drive.revoked)
    }

    @Test
    fun consentIsRequestedBeforeAnyDriveCall() = runBlocking<Unit> {
        auth.next = DriveAuthorization.Unavailable
        assertEquals(SyncResult.NotConfigured, service.backUp(repository))
        assertEquals(0, drive.calls)
    }

    @Test
    fun trashedSongsTravelInTheManifest() = runBlocking<Unit> {
        repository.saveTrashedProjects(listOf(TrashedSongProject(song("binned"), deletedAt = 500L)))
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertEquals(listOf("binned" to 500L), remote().trashed.map { it.project.id to it.deletedAt })
    }

    class StoredFile(val name: String, var bytes: ByteArray, var appProperties: Map<String, String>, var version: Int, val created: Int)

    class FakeDrive : DriveClient {
        private val files = LinkedHashMap<String, StoredFile>()
        private var nextId = 0
        var uploads = 0
        var calls = 0
        var manifestWrites = 0
        var failRevoke = false
        var afterManifestWrite: (() -> Unit)? = null
        var keepInterfering: (() -> Unit)? = null
        var onRecordingUpload: (() -> Unit)? = null
        var afterNextDownload: (() -> Unit)? = null
        val revoked = mutableListOf<String>()

        fun put(name: String, bytes: ByteArray, appProperties: Map<String, String> = emptyMap()) {
            val existing = files.values.firstOrNull { it.name == name }
            if (existing != null) {
                existing.bytes = bytes
                existing.appProperties = appProperties
                existing.version++
            } else {
                add(name, bytes, appProperties)
            }
        }
        fun add(name: String, bytes: ByteArray, appProperties: Map<String, String> = emptyMap()): String {
            val id = "id-${nextId++}"
            files[id] = StoredFile(name, bytes, appProperties, 1, nextId)
            return id
        }
        fun file(name: String) = files.values.firstOrNull { it.name == name }
        fun bytes(name: String) = file(name)?.bytes
        fun count(name: String) = files.values.count { it.name == name }
        fun clear() = files.clear()

        private fun meta(id: String, file: StoredFile) = DriveFileMetadata(
            id, file.name, modifiedTime = "%08d".format(file.created), version = file.version.toString(), appProperties = file.appProperties
        )

        private fun manifestWritten() {
            manifestWrites++
            afterManifestWrite?.let { afterManifestWrite = null; it() }
            keepInterfering?.invoke()
        }

        override suspend fun findFileByName(accessToken: String, name: String): DriveFileMetadata? {
            calls++
            return files.entries.firstOrNull { it.value.name == name }?.let { meta(it.key, it.value) }
        }
        override suspend fun listFilesByNamePrefix(accessToken: String, namePrefix: String): List<DriveFileMetadata> {
            calls++
            return files.filter { it.value.name.startsWith(namePrefix) }.map { meta(it.key, it.value) }
        }
        override suspend fun downloadFile(accessToken: String, fileId: String, maxBytes: Long): ByteArray {
            calls++
            val bytes = files.getValue(fileId).bytes
            if (bytes.size > maxBytes) throw DriveNetworkException("Drive download exceeds the allowed size")
            afterNextDownload?.let { afterNextDownload = null; it() }
            return bytes
        }
        override suspend fun uploadNewFile(
            accessToken: String, name: String, mimeType: String, content: ByteArray, appProperties: Map<String, String>
        ): String {
            calls++
            uploads++
            val id = add(name, content, appProperties)
            if (name == BackupManifest.FILE_NAME) manifestWritten()
            if (name.startsWith(BackupManifest.RECORDING_PREFIX)) onRecordingUpload?.let { onRecordingUpload = null; it() }
            return id
        }
        override suspend fun updateFile(
            accessToken: String, fileId: String, mimeType: String, content: ByteArray, appProperties: Map<String, String>
        ) {
            calls++
            files.getValue(fileId).apply {
                bytes = content
                version++
                if (appProperties.isNotEmpty()) this.appProperties = appProperties
            }
            if (files.getValue(fileId).name == BackupManifest.FILE_NAME) manifestWritten()
        }
        override suspend fun deleteFile(accessToken: String, fileId: String) {
            calls++
            files.remove(fileId)
        }
        override suspend fun revokeToken(token: String) {
            if (failRevoke) throw DriveNetworkException("Google revoke failed — check your connection.")
            revoked += token
        }
    }

    class FakeAuthorizer : DriveAuthorizer {
        var next: DriveAuthorization = DriveAuthorization.Granted("token")
        val forgotten = mutableListOf<String>()
        override suspend fun authorize() = next
        override suspend fun forget(accessToken: String) {
            forgotten += accessToken
        }
    }

    class MemoryKeyStore : SecureKeyStore {
        private val values = mutableMapOf<String, String>()
        override fun getKey(provider: String) = values[provider].orEmpty()
        override fun setKey(provider: String, key: String) { values[provider] = key }
        override fun allKeys(): Map<String, String> = values.toMap()
        override fun clear() = values.clear()
    }
}
