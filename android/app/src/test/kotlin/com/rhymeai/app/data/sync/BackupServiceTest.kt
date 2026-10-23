package com.rhymeai.app.data.sync

import com.rhymeai.app.data.recording.RecordingFiles

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
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
import kotlinx.serialization.json.JsonObject
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
import kotlin.test.assertFails
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
    private val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(root, "prefs.preferences_pb") }
    private val repository = ProjectRepository(dataStore, keys)
    private val drive = FakeDrive()
    private val auth = FakeAuthorizer()
    private var clock = 1_792_702_991_000L
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

    /**
     * A live memo with its record, as left by a recording or restore on this device:
     * its id is the deterministic one of its entry, so tests can name it.
     */
    private suspend fun writeMemo(
        projectId: String,
        fileName: String,
        bytes: ByteArray,
        modifiedAt: Long = 1_000L,
        repo: ProjectRepository = repository,
        dir: File = filesDir
    ): RecordingManifestEntry {
        val entry = RecordingManifestEntry(projectId, fileName, sizeBytes = bytes.size.toLong(), modifiedAt = modifiedAt, sha256 = BackupManifest.sha256Hex(bytes))
        val file = RecordingFileStore.targetFile(dir, projectId, entry.id, fileName)
        file.parentFile!!.mkdirs()
        file.writeBytes(bytes)
        file.setLastModified(modifiedAt)
        seedRecord(repo, dir, file, entry)
        return entry
    }

    private suspend fun seedRecord(repo: ProjectRepository, dir: File, file: File, entry: RecordingManifestEntry) {
        val path = com.rhymeai.app.data.recording.RecordingTransitions.relativePath(dir, file)
        repo.updateRecordingRecords { records -> records + entry.toRecord(RecordingRecord.RECORDED, path) }
    }

    /** The live file of the one recording shown as [displayName] in [projectId]; a missing path when there is none. */
    private suspend fun liveFile(projectId: String, displayName: String, dir: File = filesDir, repo: ProjectRepository = repository): File =
        repo.recordingRecords().singleOrNull { it.projectId == projectId && it.displayName == displayName && it.trashedAt == null }
            ?.path?.let { File(dir, it) } ?: File(dir, "no-such-recording/$projectId/$displayName")

    private fun entry(projectId: String, fileName: String, bytes: ByteArray, uploadedAt: Long = 5_000L) =
        RecordingManifestEntry(projectId, fileName, sizeBytes = bytes.size.toLong(), modifiedAt = 5L, sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = uploadedAt)

    private fun putRaw(entry: RecordingManifestEntry, bytes: ByteArray) =
        drive.put(BackupManifest.recordingDriveName(entry.id), bytes, recordingAppProperties(entry))

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
        assertEquals(memo.id, listed.id)
        // A memo from before records existed is stamped once with its file time (A20).
        assertEquals(1_000L, listed.uploadedAt)
        assertEquals(1_000L, repository.recordingRecords().single().uploadedAt)
        val uploaded = drive.file(BackupManifest.recordingDriveName(listed.id))!!
        assertContentEquals("raw audio".toByteArray(), uploaded.bytes)
        assertEquals(
            mapOf("id" to memo.id, "projectId" to "here", "fileName" to "take.m4a", "sha256" to memo.sha256, "bytes" to "9"),
            uploaded.appProperties
        )
        assertEquals(listOf("here"), repository.projectsFlow.first().map { it.id })
        assertFalse(result.legacyBackupPresent)

        // A second backup finds the raw file on Drive and does not upload it again.
        val uploadsBefore = drive.uploads
        service.backUp(repository)
        assertEquals(uploadsBefore, drive.uploads)
        liveFile("here", "take.m4a").setLastModified(99_000L)
        service.backUp(repository)
        assertEquals(1_000L, remote().recordings.single().uploadedAt)
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
        assertContentEquals(good, liveFile("elsewhere", "good.m4a").readBytes())
        assertFalse(liveFile("elsewhere", "bad.m4a").exists())
        assertEquals(listOf(goodEntry.id), repository.recordingRecords().map { it.id })
        assertEquals(1, result.damagedRecordings)
    }

    @Test
    fun restoreNeverReplacesALocalRecording() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val mine = writeMemo("p", "take.m4a", "mine".toByteArray())
        val theirs = "theirs".toByteArray()
        val listed = entry("p", "take.m4a", theirs)
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(listed)))
        putRaw(listed, theirs)

        assertIs<SyncResult.Success>(service.restore(repository))

        // A36: both are kept side by side under their ids, both shown as take.m4a.
        assertContentEquals("mine".toByteArray(), RecordingFileStore.targetFile(filesDir, "p", mine.id, "take.m4a").readBytes())
        assertContentEquals(theirs, RecordingFileStore.targetFile(filesDir, "p", listed.id, "take.m4a").readBytes())
        assertEquals(listOf("take.m4a", "take.m4a"), repository.recordingRecords().map { it.displayName })
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

        assertEquals(listOf("p/new.m4a"), remote().recordings.map { it.nameKey })
        assertNull(drive.file(BackupManifest.recordingDriveName(old.id)))
        assertEquals(listOf(SyncDeletion("p", "old.m4a", 5_000L)), remote().deletions)
    }

    @Test
    fun pendingLocalDeletionIsNeverUploaded() = runBlocking<Unit> {
        repository.saveTrashedProjects(listOf(TrashedSongProject(song("binned"), deletedAt = 500L)))
        val binned = writeMemo("binned", "take.m4a", "audio".toByteArray())
        assertNotNull(repository.permanentlyDeleteTrashedProject("binned"))
        assertTrue("binned" in repository.pendingRecordingDeletionIds())

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertTrue(remote().recordings.isEmpty())
        assertNull(drive.file(BackupManifest.recordingDriveName(binned.id)))
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
        val newTake = writeMemo("x", "new.m4a", "new take".toByteArray(), modifiedAt = 9_500L)
        // While the new take uploads, a stale device writes a song tombstone (5000) with no recording tombstone.
        drive.onRecordingUpload = { putRemote(SyncBlob(deletions = listOf(SyncDeletion("x", deletedAt = 5_000L)))) }

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(listOf("x"), remote().projects.map { it.id })
        assertEquals(listOf("x/new.m4a"), remote().recordings.map { it.nameKey })
        assertEquals(listOf(SyncDeletion("x", "take.m4a", 5_000L, recordingId = listed.id)), remote().deletions)
        assertEquals(1, drive.count(BackupManifest.recordingDriveName(newTake.id)))
    }

    @Test
    fun aRemoteTombstoneThatArrivesDuringUploadsIsMergedBeforeTheFinalWrite() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("doomed", updatedAt = 1_000L), song("kept")))
        val doomed = writeMemo("doomed", "take.m4a", "audio".toByteArray(), modifiedAt = 1_000L)
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
        assertEquals(1, drive.count(BackupManifest.recordingDriveName(doomed.id)))
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
            assertEquals(listOf(SyncDeletion("x", "take.m4a", 5_000L, recordingId = listed.id)), remote().deletions, "backup ${it + 1}")
        }

        // An offline device that kept the old song and audio backs up later.
        val offlineRoot = kotlin.io.path.createTempDirectory("rhymeai-offline").toFile()
        try {
            val offlineFiles = File(offlineRoot, "files").also { it.mkdirs() }
            val offlineRepo = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(offlineRoot, "prefs.preferences_pb") }, MemoryKeyStore()
            )
            offlineRepo.saveProjects(listOf(song("x", updatedAt = 100L)))
            // It restored the same take earlier, so it holds the same recording id.
            writeMemo("x", "take.m4a", audio, modifiedAt = 1_000L, repo = offlineRepo, dir = offlineFiles)
            val offline = DriveSyncService(offlineFiles, MemoryKeyStore(), drive, auth, clientId = { "offline" }, now = { clock })

            assertIs<SyncResult.Success>(offline.backUp(offlineRepo))

            assertTrue(remote().recordings.isEmpty())
            assertEquals(9_000L, remote().projects.single().updatedAt)
        } finally {
            offlineRoot.deleteRecursively()
        }
    }

    @Test
    fun aRawObjectWithTheSameDigestButWrongSizeIsReplacedWithTheVerifiedBytes() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val memo = writeMemo("p", "take.m4a", "healthy".toByteArray())
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(memo.copy(uploadedAt = 2_000L))))
        val name = BackupManifest.recordingDriveName(memo.id)
        // Same recording (same digest), but a torn copy whose size does not match.
        drive.put(name, "heal".toByteArray(), recordingAppProperties(memo) + ("bytes" to "4"))

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(0, result.conflictingRecordings)
        assertContentEquals("healthy".toByteArray(), drive.bytes(name))
        assertEquals(memo.sha256, drive.file(name)!!.appProperties["sha256"])
        assertEquals(1, drive.count(name))
    }

    @Test
    fun aRawObjectWithAnotherDigestOrNoneIsNeverOverwrittenAndIsReported() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val memo = writeMemo("p", "take.m4a", "healthy".toByteArray())
        val other = writeMemo("p", "verse.m4a", "verse".toByteArray())
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(memo.copy(uploadedAt = 2_000L), other.copy(uploadedAt = 2_000L))))
        val name = BackupManifest.recordingDriveName(memo.id)
        val otherName = BackupManifest.recordingDriveName(other.id)
        // A40: one id, one digest. Different audio under this id, and an object without metadata.
        drive.put(name, "different".toByteArray(), recordingAppProperties(memo) + ("sha256" to BackupManifest.sha256Hex("different".toByteArray())))
        drive.put(otherName, "unknown".toByteArray())

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(2, result.conflictingRecordings)
        assertContentEquals("different".toByteArray(), drive.bytes(name))
        assertContentEquals("unknown".toByteArray(), drive.bytes(otherName))
        assertEquals(1, drive.count(name))
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
        assertContentEquals(audio, drive.bytes(BackupManifest.recordingDriveName(old.id)))
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
        RecordingFileStore.stageRestore(stage, entry("p", "staged.m4a", bytes), bytes)
        val mine = writeMemo("p", "mine.m4a", "mine".toByteArray())

        assertIs<SyncResult.Success>(service.backUp(repository))
        assertTrue(stage.exists())

        assertIs<SyncResult.Success>(service.restore(repository))
        assertFalse(stage.exists())
        assertContentEquals("mine".toByteArray(), RecordingFileStore.targetFile(filesDir, mine.projectId, mine.id, mine.fileName).readBytes())
    }

    @Test
    fun migrationGathersOlderRecordingsWithTheirOwnTimesBeforeResolving() = runBlocking<Unit> {
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        val audio = "legacy take".toByteArray()
        val old = entry("x", "take.m4a", audio, uploadedAt = 0L).copy(modifiedAt = 1_000L)
        putLegacy(SyncBlob(projects = listOf(song("x", updatedAt = 100L)), recordings = listOf(old)), mapOf(old to audio))
        putRemote(SyncBlob(deletions = listOf(SyncDeletion("x", deletedAt = 5_000L))))
        repository.saveProjects(listOf(song("x", updatedAt = 9_000L)))

        repeat(2) { round ->
            assertIs<SyncResult.Success>(service.backUp(repository), "backup ${round + 1}")
            assertEquals(listOf("x"), remote().projects.map { it.id }, "backup ${round + 1}")
            assertTrue(remote().recordings.isEmpty(), "backup ${round + 1}")
            assertEquals(listOf(SyncDeletion("x", "take.m4a", 5_000L, recordingId = old.id)), remote().deletions, "backup ${round + 1}")
        }
        // Its bytes are kept raw, and the older backup could be retired.
        assertContentEquals(audio, drive.bytes(BackupManifest.recordingDriveName(old.id)))
        assertNull(drive.bytes(SyncBlob.DRIVE_FILE_NAME))
    }

    @Test
    fun aSongTombstoneAppliedOnRestoreAlsoCoversATakeKnownOnlyInTrash() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("x", updatedAt = 100L)))
        val audio = "trashed take".toByteArray()
        val trashDir = com.rhymeai.app.data.recording.RecordingFiles.trashDirectory(filesDir, "x").also { it.mkdirs() }
        val trashed = File(trashDir, "1500__take.m4a").apply { writeBytes(audio); setLastModified(1_000L) }
        val take = RecordingManifestEntry("x", "take.m4a", sizeBytes = audio.size.toLong(), modifiedAt = 1_000L, sha256 = BackupManifest.sha256Hex(audio))
        seedRecord(repository, filesDir, trashed, take)
        putRemote(SyncBlob(projects = listOf(song("keep")), deletions = listOf(SyncDeletion("x", deletedAt = 5_000L))))

        assertIs<SyncResult.Success>(service.restore(repository))
        assertTrue(SyncDeletion("x", "take.m4a", 5_000L, recordingId = take.id) in repository.snapshotLocalSyncBase().blob.deletions)
        assertIs<SyncResult.Success>(service.backUp(repository))

        // A bare manifest revives the song with a newer edit.
        val bare = File(root, "revive.json").apply {
            writeBytes(BackupManifest.encode(SyncBlob(projects = listOf(song("x", updatedAt = 9_000L))), 0L, "elsewhere"))
        }
        BackupArchive.import(BackupArchive.read(bare), repository, filesDir)
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertEquals(setOf("keep", "x"), remote().projects.map { it.id }.toSet())

        // An offline device that kept the take live backs up later.
        val offlineRoot = kotlin.io.path.createTempDirectory("rhymeai-offline-trash").toFile()
        try {
            val offlineFiles = File(offlineRoot, "files").also { it.mkdirs() }
            val offlineRepo = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(offlineRoot, "prefs.preferences_pb") }, MemoryKeyStore()
            )
            offlineRepo.saveProjects(listOf(song("x", updatedAt = 100L)))
            // The same take, live there (same recording id).
            writeMemo("x", "take.m4a", audio, modifiedAt = 1_000L, repo = offlineRepo, dir = offlineFiles)
            val offline = DriveSyncService(offlineFiles, MemoryKeyStore(), drive, auth, clientId = { "offline" }, now = { clock })

            assertIs<SyncResult.Success>(offline.backUp(offlineRepo))

            assertTrue(remote().recordings.none { it.id == take.id })
            assertTrue(SyncDeletion("x", "take.m4a", 5_000L, recordingId = take.id) in remote().deletions)
        } finally {
            offlineRoot.deleteRecursively()
        }
    }

    @Test
    fun aRevivalAndADeletionInTheSameMergeStillCoverATrashOnlyTake() = runBlocking<Unit> {
        // This device: song x edited at 9000, an old take (1000) only in its Trash.
        repository.saveProjects(listOf(song("x", updatedAt = 9_000L)))
        val audio = "trashed take".toByteArray()
        val trashed = File(com.rhymeai.app.data.recording.RecordingFiles.trashDirectory(filesDir, "x").apply { mkdirs() }, "1500__take.m4a")
            .apply { writeBytes(audio); setLastModified(1_000L) }
        val take = RecordingManifestEntry("x", "take.m4a", sizeBytes = audio.size.toLong(), modifiedAt = 1_000L, sha256 = BackupManifest.sha256Hex(audio))
        seedRecord(repository, filesDir, trashed, take)
        // Drive: a song tombstone at 5000 from another device.
        putRemote(SyncBlob(deletions = listOf(SyncDeletion("x", deletedAt = 5_000L))))
        // Launch gives the pre-A36 file its id name; Back up itself moves nothing (A17).
        com.rhymeai.app.data.recording.RecordingTransitions.migrate(repository, filesDir)

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(listOf("x"), remote().projects.map { it.id })
        assertTrue(remote().recordings.isEmpty())
        assertEquals(listOf(SyncDeletion("x", "take.m4a", 5_000L, recordingId = take.id)), remote().deletions)

        // An offline device holding the same take live backs up later; it stays deleted.
        val offlineRoot = kotlin.io.path.createTempDirectory("rhymeai-offline-same-merge").toFile()
        try {
            val offlineFiles = File(offlineRoot, "files").also { it.mkdirs() }
            val offlineRepo = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(offlineRoot, "prefs.preferences_pb") }, MemoryKeyStore()
            )
            writeMemo("x", "take.m4a", audio, modifiedAt = 1_000L, repo = offlineRepo, dir = offlineFiles)
            val offline = DriveSyncService(offlineFiles, MemoryKeyStore(), drive, auth, clientId = { "offline" }, now = { clock })

            assertIs<SyncResult.Success>(offline.backUp(offlineRepo))

            assertTrue(remote().recordings.isEmpty())
        } finally {
            offlineRoot.deleteRecursively()
        }
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
        assertFalse(RecordingFiles.memoDirectory(filesDir, "legacy").exists())
        // Drive holds everything, with the newer legacy lyrics.
        assertEquals(setOf("here", "legacy", "shared"), remote().projects.map { it.id }.toSet())
        assertEquals("newer in legacy", remote().projects.single { it.id == "shared" }.lyrics)
        assertContentEquals(audio, drive.bytes(BackupManifest.recordingDriveName(old.id)))
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
        assertContentEquals(audio, drive.bytes(BackupManifest.recordingDriveName(movable.id)))
        assertEquals(setOf("legacy"), remote().projects.map { it.id }.toSet())
    }

    @Test
    fun anUnavailableOlderRecordingNeverStandsInForADeletedLocalOne() = runBlocking<Unit> {
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        repository.saveProjects(listOf(song("p")))
        // Local take B at 1000, deleted elsewhere at 5000 (its recording tombstone is in Drive).
        val local = writeMemo("p", "take.m4a", "local take".toByteArray(), modifiedAt = 1_000L)
        putRemote(SyncBlob(projects = listOf(song("p")), deletions = listOf(SyncDeletion("p", "take.m4a", 5_000L, recordingId = local.id))))
        // The older backup lists a different take A under the same name at 9000, payload missing.
        val olderA = entry("p", "take.m4a", "older take".toByteArray(), uploadedAt = 0L).copy(modifiedAt = 9_000L)
        putLegacy(SyncBlob(projects = listOf(song("p")), recordings = listOf(olderA)))

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(1, result.unmovedLegacyRecordings)
        assertTrue(remote().recordings.isEmpty())
        assertNull(drive.file(BackupManifest.recordingDriveName(local.id)))
        assertTrue(SyncDeletion("p", "take.m4a", 5_000L, recordingId = local.id) in remote().deletions)
        assertNotNull(drive.bytes(SyncBlob.DRIVE_FILE_NAME))
    }

    @Test
    fun anOlderNameTombstoneDeletesOnlyTheOlderRecordingItNamed() = runBlocking<Unit> {
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        repository.saveProjects(listOf(song("p")))
        // Older backup: recording A under take.m4a at 1000, deleted by name at 5000.
        val audioA = "older take".toByteArray()
        val olderA = entry("p", "take.m4a", audioA, uploadedAt = 0L).copy(modifiedAt = 1_000L)
        putLegacy(
            SyncBlob(projects = listOf(song("p")), recordings = listOf(olderA), deletions = listOf(SyncDeletion("p", "take.m4a", 5_000L))),
            mapOf(olderA to audioA)
        )
        // A different v4 recording B now has that name here, recorded at 1000.
        val bytesB = "new take".toByteArray()
        val b = RecordingManifestEntry("p", "take.m4a", sizeBytes = bytesB.size.toLong(), modifiedAt = 1_000L,
            sha256 = BackupManifest.sha256Hex(bytesB), uploadedAt = 1_000L, id = RecordingManifestEntry.newRecordingId())
        val fileB = RecordingFileStore.targetFile(filesDir, "p", b.id, "take.m4a").apply { parentFile!!.mkdirs(); writeBytes(bytesB) }
        seedRecord(repository, filesDir, fileB, b)

        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(listOf(b.id), remote().recordings.map { it.id })
        assertContentEquals(bytesB, drive.bytes(BackupManifest.recordingDriveName(b.id)))
        assertTrue(SyncDeletion("p", "take.m4a", 5_000L, recordingId = olderA.id) in remote().deletions)
        assertTrue(remote().deletions.none { it.fileName != null && it.recordingId == null })
    }

    @Test
    fun anOversizedLocalRecordingIsNeitherListedNorUploadedAndIsCountedAsSkipped() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val big = writeMemo("p", "big.m4a", ByteArray((RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES + 1).toInt()))

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(1, result.skippedLargeRecordings)
        assertTrue(remote().recordings.isEmpty())
        assertNull(drive.file(BackupManifest.recordingDriveName(big.id)))
    }

    @Test
    fun aSongDeletedBeforeItsRecordingsWereStampedStillTombstonesEachOfThem() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("gone")))
        repository.moveProjectToTrash("gone", 10L)
        val live = "live take".toByteArray()
        val trashed = "trashed take".toByteArray()
        File(RecordingFiles.memoDirectory(filesDir, "gone").apply { mkdirs() }, "take.m4a").apply { writeBytes(live); setLastModified(1_000L) }
        File(RecordingFiles.trashDirectory(filesDir, "gone").apply { mkdirs() }, "1500__old.m4a").apply { writeBytes(trashed); setLastModified(1_000L) }
        assertTrue(repository.recordingRecords().isEmpty())

        // What the app does before Delete Forever or expiry.
        com.rhymeai.app.data.recording.RecordingTransitions.adopt(repository, filesDir, setOf("gone"))
        repository.permanentlyDeleteTrashedProject("gone", now = 5_000L)

        val expected = setOf(
            RecordingManifestEntry.legacyRecordingId("gone", "take.m4a", BackupManifest.sha256Hex(live)),
            RecordingManifestEntry.legacyRecordingId("gone", "old.m4a", BackupManifest.sha256Hex(trashed))
        )
        val deletions = repository.snapshotLocalSyncBase().blob.deletions
        assertEquals(expected, deletions.mapNotNull { it.recordingId }.toSet())
        // An offline device that never stamped its copy derives the same id, so the tombstone holds there too.
        val offline = kotlin.io.path.createTempDirectory("rhymeai-offline").toFile()
        try {
            File(RecordingFiles.memoDirectory(offline, "gone").apply { mkdirs() }, "take.m4a").apply { writeBytes(live); setLastModified(1_000L) }
            val copy = snapshotLocalRecordingFiles(offline, emptySet()).single().entry
            assertTrue(SyncMerger.Tombstones(deletions.filter { it.fileName != null }).removes(copy))
        } finally {
            offline.deleteRecursively()
        }
    }

    @Test
    fun anOversizedRecordingCountsAsBackedUpOnlyWhenItsRawObjectMatches() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val bytes = ByteArray((RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES + 1).toInt()) { 7 }
        val big = writeMemo("p", "big.m4a", bytes).copy(uploadedAt = 1_000L)
        // Another version listed it, but its raw object is missing.
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(big)))
        assertEquals(1, assertIs<SyncResult.Success>(service.backUp(repository)).skippedLargeRecordings)

        // A raw object with another size does not count either.
        drive.put(BackupManifest.recordingDriveName(big.id), byteArrayOf(1), recordingAppProperties(big.copy(sizeBytes = 1L)))
        assertEquals(1, assertIs<SyncResult.Success>(service.backUp(repository)).skippedLargeRecordings)

        // With the matching raw object it is backed up.
        drive.put(BackupManifest.recordingDriveName(big.id), bytes, recordingAppProperties(big))
        assertEquals(0, assertIs<SyncResult.Success>(service.backUp(repository)).skippedLargeRecordings)
    }

    @Test
    fun aDeletionThatWinsOnRestoreTakesTheRecordingOutOfTheLibraryIntoQuarantine() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val take = writeMemo("p", "take.m4a", "old take".toByteArray(), modifiedAt = 1_000L)
        // Elsewhere the take was deleted at 5000 and the song was edited later, at 9000.
        putRemote(SyncBlob(
            projects = listOf(song("p", updatedAt = 9_000L)),
            deletions = listOf(SyncDeletion("p", "take.m4a", 5_000L, recordingId = take.id))
        ))

        assertIs<SyncResult.Success>(service.restore(repository))

        assertEquals(listOf("p"), repository.projectsFlow.first().map { it.id })
        // The recordings listing reads the song's memo folder: the take is no longer there.
        assertTrue(RecordingFiles.memoDirectory(filesDir, "p").list().orEmpty().isEmpty())
        val kept = RecordingFiles.quarantineDirectory(filesDir, "p").walk().single { it.isFile }
        assertContentEquals("old take".toByteArray(), kept.readBytes())
        assertTrue(repository.recordingRecords().isEmpty())
        assertTrue(snapshotLocalRecordingFiles(filesDir, emptySet()).isEmpty())
    }

    @Test
    fun anUnreadableRecordingStopsDeleteForeverAndExpiryAndChangesNothing() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("gone")))
        repository.moveProjectToTrash("gone", 10L)
        val dir = RecordingFiles.memoDirectory(filesDir, "gone").apply { mkdirs() }
        val unreadable = File(dir, "take.m4a").apply { writeBytes("take".toByteArray()) }
        unreadable.setReadable(false)
        org.junit.Assume.assumeFalse("permissions are not enforced for this user", unreadable.canRead())
        val adopt: suspend (Set<String>) -> Unit = { com.rhymeai.app.data.recording.RecordingTransitions.adopt(repository, filesDir, it) }
        try {
            assertFailsWith<java.io.IOException> { repository.permanentlyDeleteTrashedProject("gone", now = 5_000L, adopt = adopt) }
            assertFailsWith<java.io.IOException> {
                repository.purgeExpiredTrashedProjects(10L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS, adopt = adopt)
            }

            assertEquals(listOf("gone"), repository.trashedProjectsFlow.first().map { it.project.id })
            assertTrue(repository.snapshotLocalSyncBase().blob.deletions.isEmpty())
            assertTrue(unreadable.exists())
        } finally {
            unreadable.setReadable(true)
        }
    }

    @Test
    fun aFolderThatCannotBeListedStopsDeleteForeverAndExpiryAndChangesNothing() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("gone")))
        repository.moveProjectToTrash("gone", 10L)
        val trash = RecordingFiles.trashDirectory(filesDir, "gone").apply { mkdirs() }
        val trashed = File(trash, "1500__old.m4a").apply { writeBytes("old".toByteArray()) }
        trash.setReadable(false)
        org.junit.Assume.assumeTrue("permissions are not enforced for this user", trash.listFiles() == null)
        val adopt: suspend (Set<String>) -> Unit = { com.rhymeai.app.data.recording.RecordingTransitions.adopt(repository, filesDir, it) }
        try {
            assertFailsWith<java.io.IOException> { repository.permanentlyDeleteTrashedProject("gone", now = 5_000L, adopt = adopt) }
            assertFailsWith<java.io.IOException> {
                repository.purgeExpiredTrashedProjects(10L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS, adopt = adopt)
            }

            assertEquals(listOf("gone"), repository.trashedProjectsFlow.first().map { it.project.id })
            assertTrue(repository.snapshotLocalSyncBase().blob.deletions.isEmpty())
        } finally {
            trash.setReadable(true)
        }
        assertTrue(trashed.exists())
    }

    @Test
    fun aDirectoryWhoseEntriesCannotBeExaminedStopsDeleteForeverAndExpiry() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("gone")))
        repository.moveProjectToTrash("gone", 10L)
        val trash = RecordingFiles.trashDirectory(filesDir, "gone").apply { mkdirs() }
        val trashed = File(trash, "1500__old.m4a").apply { writeBytes("old".toByteArray()) }
        // Readable but not searchable: names list, but no entry's metadata can be read.
        trash.setExecutable(false)
        val blocked = runCatching { java.nio.file.Files.readAttributes(trashed.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java) }.isFailure
        org.junit.Assume.assumeTrue("permissions are not enforced for this user", blocked && trash.list() != null)
        val adopt: suspend (Set<String>) -> Unit = { com.rhymeai.app.data.recording.RecordingTransitions.adopt(repository, filesDir, it) }
        try {
            assertFailsWith<java.io.IOException> { repository.permanentlyDeleteTrashedProject("gone", now = 5_000L, adopt = adopt) }
            assertFailsWith<java.io.IOException> {
                repository.purgeExpiredTrashedProjects(10L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS, adopt = adopt)
            }
            assertEquals(listOf("gone"), repository.trashedProjectsFlow.first().map { it.project.id })
            assertTrue(repository.snapshotLocalSyncBase().blob.deletions.isEmpty())
        } finally {
            trash.setExecutable(true)
        }
        assertTrue(trashed.exists())
    }

    @Test
    fun aQuarantineThatFailsAfterTheCommitKeepsTheRecordingHiddenAndIsRetried() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val take = writeMemo("p", "take.m4a", "old take".toByteArray(), modifiedAt = 1_000L)
        putRemote(SyncBlob(
            projects = listOf(song("p", updatedAt = 9_000L)),
            deletions = listOf(SyncDeletion("p", "take.m4a", 5_000L, recordingId = take.id))
        ))
        // A file where the quarantine folder belongs makes the move fail after the commit.
        val blocker = RecordingFiles.quarantineRoot(filesDir).apply { writeText("in the way") }

        assertFalse(service.restore(repository) is SyncResult.Success)

        val memo = liveFile("p", "take.m4a")
        assertTrue(memo.exists())
        assertEquals(9_000L, repository.projectsFlow.first().single().updatedAt)
        // Until the move happens, the lists hide it: its path is a deleted one.
        val deleted = com.rhymeai.app.data.recording.RecordingTransitions.deletedPaths(repository.recordingRecords(), repository.syncDeletions())
        assertEquals(setOf(com.rhymeai.app.data.recording.RecordingTransitions.relativePath(filesDir, memo)), deleted)

        // The next launch retries it.
        blocker.delete()
        quarantineDeletedRecordings(repository, filesDir)
        assertFalse(memo.exists())
        assertEquals(1, RecordingFiles.quarantineDirectory(filesDir, "p").list().orEmpty().size)
        assertTrue(com.rhymeai.app.data.recording.RecordingTransitions.deletedPaths(repository.recordingRecords(), repository.syncDeletions()).isEmpty())
    }

    @Test
    fun oversizedRecordingsAreCountedOncePerRecordingAcrossLiveTrashRemoteAndDeleted() = runBlocking<Unit> {
        val size = (RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES + 1).toInt()
        repository.saveProjects(listOf(song("p")))
        // Live, backed up: raw object matches.
        val backedBytes = ByteArray(size) { 1 }
        val backed = writeMemo("p", "backed.m4a", backedBytes).copy(uploadedAt = 1_000L)
        drive.put(BackupManifest.recordingDriveName(backed.id), backedBytes, recordingAppProperties(backed))
        // Live, never uploaded anywhere: skipped.
        writeMemo("p", "local.m4a", ByteArray(size) { 2 })
        // In Trash here, backed up: held, so not a remote recording this device lacks.
        val trashedBytes = ByteArray(size) { 3 }
        File(RecordingFiles.trashDirectory(filesDir, "p").apply { mkdirs() }, "1500__trashed.m4a").apply { writeBytes(trashedBytes); setLastModified(1_000L) }
        val trashed = RecordingManifestEntry("p", "trashed.m4a", sizeBytes = size.toLong(), modifiedAt = 0L,
            sha256 = BackupManifest.sha256Hex(trashedBytes), uploadedAt = 1_000L)
        drive.put(BackupManifest.recordingDriveName(trashed.id), trashedBytes, recordingAppProperties(trashed))
        // Only in Drive: this device cannot download it, so skipped.
        val remoteOnly = entry("p", "remote.m4a", byteArrayOf(4), uploadedAt = 1_000L).copy(sizeBytes = size.toLong())
        // Deleted: a newer song tombstone removes it, so it is a deletion, not a skip.
        val deleted = entry("gone", "deleted.m4a", byteArrayOf(5), uploadedAt = 1_000L).copy(sizeBytes = size.toLong())
        writeMemo("p", "small.m4a", "small".toByteArray())
        putRemote(SyncBlob(
            projects = listOf(song("p")),
            recordings = listOf(backed, trashed, remoteOnly, deleted),
            deletions = listOf(SyncDeletion("gone", deletedAt = 5_000L))
        ))

        com.rhymeai.app.data.recording.RecordingTransitions.migrate(repository, filesDir) // as at launch
        assertEquals(2, assertIs<SyncResult.Success>(service.backUp(repository)).skippedLargeRecordings)
        assertEquals(2, assertIs<SyncResult.Success>(service.restore(repository)).skippedLargeRecordings)

        // The Trash-held recording's raw object goes missing, then comes back with another size:
        // it is unpreserved, counted once, and not as a remote recording this device lacks.
        drive.remove(BackupManifest.recordingDriveName(trashed.id))
        assertEquals(3, assertIs<SyncResult.Success>(service.backUp(repository)).skippedLargeRecordings)
        drive.put(BackupManifest.recordingDriveName(trashed.id), byteArrayOf(1), recordingAppProperties(trashed.copy(sizeBytes = 1L)))
        assertEquals(3, assertIs<SyncResult.Success>(service.backUp(repository)).skippedLargeRecordings)
    }

    @Test
    fun aStampedTimeHoldsWhenTheFileTimeLaterDropsBelowATombstone() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val file = File(RecordingFiles.memoDirectory(filesDir, "p").apply { mkdirs() }, "take.m4a")
            .apply { writeBytes("take".toByteArray()); setLastModified(5_000L) }
        val stamped = snapshotLocalRecordingFiles(filesDir, emptySet(), repository).single().entry
        assertEquals(5_000L, stamped.uploadedAt)

        file.setLastModified(1_000L)
        val again = snapshotLocalRecordingFiles(filesDir, emptySet(), repository).single().entry

        assertEquals(5_000L, again.uploadedAt)
        assertFalse(SyncMerger.Tombstones(listOf(SyncDeletion("p", "take.m4a", 3_000L, recordingId = stamped.id))).removes(again))
    }

    @Test
    fun anInterruptedPublishWhoseDestinationCannotBeExaminedKeepsItsIdentityUntilAccessReturns() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val dir = RecordingFiles.memoDirectory(filesDir, "p").apply { mkdirs() }
        val bytes = "restored take".toByteArray()
        val placed = File(dir, "take.m4a").apply { writeBytes(bytes); setLastModified(9_000L) }
        val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val path = com.rhymeai.app.data.recording.RecordingTransitions.relativePath(filesDir, placed)
        // The file reached its place; the process died before the record was finished.
        val intent = RecordingRecord(id, "p", "take.m4a", 1_000L, BackupManifest.sha256Hex(bytes), bytes.size.toLong(),
            RecordingRecord.RESTORED, path = path, pendingFrom = ".recording-restore-x/take.m4a", pendingOp = RecordingRecord.OP_PUBLISH)
        repository.updateRecordingRecords { listOf(intent) }

        dir.setExecutable(false)
        val blocked = runCatching { java.nio.file.Files.readAttributes(placed.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java) }.isFailure
        org.junit.Assume.assumeTrue("permissions are not enforced for this user", blocked)
        try {
            assertFailsWith<java.io.IOException> { snapshotLocalRecordingFiles(filesDir, emptySet(), repository) }
            assertEquals(listOf(intent), repository.recordingRecords())
        } finally {
            dir.setExecutable(true)
        }

        val listed = snapshotLocalRecordingFiles(filesDir, emptySet(), repository).single().entry
        assertEquals(id, listed.id)
        assertEquals(1_000L, listed.uploadedAt)
        assertEquals(RecordingRecord.RESTORED, repository.recordingRecords().single().origin)
        assertTrue(SyncMerger.Tombstones(listOf(SyncDeletion("p", "take.m4a", 5_000L, recordingId = id))).removes(listed))
    }

    @Test
    fun twoDevicesWithDifferentRecordingsUnderOneNameConvergeWithoutRenamingLoops() = runBlocking<Unit> {
        val otherFiles = File(root, "other-files").also { it.mkdirs() }
        val otherRepository = ProjectRepository(
            PreferenceDataStoreFactory.create(scope = scope) { File(root, "other.preferences_pb") }, MemoryKeyStore()
        )
        val other = DriveSyncService(otherFiles, MemoryKeyStore(), drive, auth, clientId = { "other-device" }, now = { clock })
        repository.saveProjects(listOf(song("p")))
        otherRepository.saveProjects(listOf(song("p")))
        // Here, X under take.m4a at 2000; on the other device, Y under take.m4a at 1000.
        val x = writeMemo("p", "take.m4a", "x take".toByteArray(), modifiedAt = 2_000L)
        val y = writeMemo("p", "take.m4a", "y take".toByteArray(), modifiedAt = 1_000L, repo = otherRepository, dir = otherFiles)

        assertIs<SyncResult.Success>(service.backUp(repository))
        assertIs<SyncResult.Success>(other.restore(otherRepository))
        assertIs<SyncResult.Success>(service.restore(repository))

        // A36: both devices hold both, under their ids, both shown as take.m4a; nothing is renamed.
        for (dir in listOf(filesDir, otherFiles)) {
            assertContentEquals("y take".toByteArray(), RecordingFileStore.targetFile(dir, "p", y.id, "take.m4a").readBytes())
            assertContentEquals("x take".toByteArray(), RecordingFileStore.targetFile(dir, "p", x.id, "take.m4a").readBytes())
        }
        val names = remote().recordings.associate { it.id to it.fileName }
        assertEquals(mapOf(y.id to "take.m4a", x.id to "take.m4a"), names)

        // Further rounds from either device change nothing: no renaming loop.
        repeat(2) {
            assertIs<SyncResult.Success>(service.backUp(repository))
            assertIs<SyncResult.Success>(other.backUp(otherRepository))
            assertIs<SyncResult.Success>(other.restore(otherRepository))
            assertIs<SyncResult.Success>(service.restore(repository))
            assertEquals(names, remote().recordings.associate { it.id to it.fileName })
        }
        assertEquals(setOf("${x.id}.m4a", "${y.id}.m4a"), RecordingFiles.memoDirectory(otherFiles, "p").list()!!.toSet())
        assertEquals(listOf("take.m4a", "take.m4a"), otherRepository.recordingRecords().map { it.displayName })
    }

    @Test
    fun theManifestCarriesTheDisplayNameAsFileNameAndNoClaim() {
        val entry = RecordingManifestEntry("p", "take.m4a", sizeBytes = 1L, modifiedAt = 0L, sha256 = "a".repeat(64),
            uploadedAt = 20L, id = "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2")
        val json = String(BackupManifest.encode(SyncBlob(recordings = listOf(entry)), 1_000L, "device"))
        assertFalse(json.contains("claimedName"))
        assertEquals("take.m4a", BackupManifest.decode(json.toByteArray()).recordings.single().fileName)
    }

    @Test
    fun aMissingPrecedenceTimeBecomesTheFirstSeenTimeOnceAndNamesStayPut() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        // Here, A under take.m4a at 2000. Drive lists B under the same name and C under
        // verse.m4a, both without a time.
        val a = writeMemo("p", "take.m4a", "a take".toByteArray(), modifiedAt = 2_000L)
        val verse = writeMemo("p", "verse.m4a", "local verse".toByteArray(), modifiedAt = 3_000L)
        val bBytes = "b take".toByteArray()
        val b = RecordingManifestEntry("p", "take.m4a", sizeBytes = bBytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bBytes), uploadedAt = 0L)
        val cBytes = "c verse".toByteArray()
        val c = RecordingManifestEntry("p", "verse.m4a", sizeBytes = cBytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(cBytes), uploadedAt = 0L)
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(b, c)))
        putRaw(b, bBytes)
        putRaw(c, cBytes)
        val firstSeen = clock

        assertIs<SyncResult.Success>(service.backUp(repository))
        val first = remote().recordings.associate { it.id to (it.fileName to it.uploadedAt) }
        // A32: B and C were first seen now; A36: every display name stays as it was.
        assertEquals(mapOf(
            a.id to ("take.m4a" to 2_000L), b.id to ("take.m4a" to firstSeen),
            verse.id to ("verse.m4a" to 3_000L), c.id to ("verse.m4a" to firstSeen)
        ), first)
        repeat(3) {
            clock += 60_000L
            assertIs<SyncResult.Success>(service.backUp(repository))
            assertEquals(first, remote().recordings.associate { it.id to (it.fileName to it.uploadedAt) })
        }
    }

    @Test
    fun aRecordingOrSongWithoutATimeLosesToARealTombstone() = runBlocking<Unit> {
        val bytes = "timeless take".toByteArray()
        val timeless = RecordingManifestEntry("p", "take.m4a", sizeBytes = bytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = 0L)
        putRemote(SyncBlob(
            projects = listOf(song("p", updatedAt = 0L)),
            recordings = listOf(timeless),
            deletions = listOf(
                SyncDeletion("p", "take.m4a", clock - 1_000L, recordingId = timeless.id),
                SyncDeletion("p", deletedAt = clock - 1_000L)
            )
        ))
        putRaw(timeless, bytes)

        assertIs<SyncResult.Success>(service.restore(repository))

        // A38: an unknown time is repaired (first seen now), and a real tombstone beats a repair,
        // even one written before that: neither comes back.
        assertTrue(remote().projects.none { it.id == "p" })
        assertTrue(remote().recordings.none { it.id == timeless.id })
        assertFalse(liveFile("p", "take.m4a").exists())
        assertTrue(remote().deletions.any { it.isSongTombstone && it.projectId == "p" })
    }

    @Test
    fun unreadableTombstonesStopAdoptionDeletionAndMovesBeforeAnythingChanges() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("gone"), song("kept")))
        repository.moveProjectToTrash("gone", 10L)
        val bytes = "old take".toByteArray()
        val live = File(RecordingFiles.memoDirectory(filesDir, "gone").apply { mkdirs() }, "take.m4a").apply { writeBytes(bytes) }
        val trashed = File(RecordingFiles.trashDirectory(filesDir, "gone").apply { mkdirs() }, "1500__take.m4a").apply { writeBytes(bytes) }
        val other = File(RecordingFiles.memoDirectory(filesDir, "kept").apply { mkdirs() }, "verse.m4a").apply { writeBytes("verse".toByteArray()) }
        dataStore.edit { it[androidx.datastore.preferences.core.stringPreferencesKey("sync_deletions_json")] = "{not json" }
        val adopt: suspend (Set<String>) -> Unit = { com.rhymeai.app.data.recording.RecordingTransitions.adopt(repository, filesDir, it) }

        assertFails { repository.permanentlyDeleteTrashedProject("gone", now = 5_000L, adopt = adopt) }
        assertFails {
            com.rhymeai.app.data.recording.RecordingTransitions.rename(repository, filesDir, other, "kept", "renamed.m4a")
        }

        // Nothing was stamped, quarantined, deleted or moved.
        assertTrue(repository.recordingRecords().isEmpty())
        assertTrue(live.exists())
        assertTrue(trashed.exists())
        assertTrue(other.exists())
        assertFalse(RecordingFiles.quarantineRoot(filesDir).exists())
        assertEquals(listOf("gone"), repository.trashedProjectsFlow.first().map { it.project.id })
    }

    @Test
    fun aParseableButInvalidTombstoneFailsClosedLikeAnUnreadableOne() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("kept")))
        val other = File(RecordingFiles.memoDirectory(filesDir, "kept").apply { mkdirs() }, "verse.m4a").apply { writeBytes("verse".toByteArray()) }
        dataStore.edit {
            it[androidx.datastore.preferences.core.stringPreferencesKey("sync_deletions_json")] =
                """[{"projectId":"kept","fileName":"verse.m4a","deletedAt":5,"recordingId":"broken"}]"""
        }

        assertFails { repository.syncDeletions() }
        assertFails { repository.requireDeletionsReadable() }
        assertFails {
            com.rhymeai.app.data.recording.RecordingTransitions.rename(repository, filesDir, other, "kept", "renamed.m4a")
        }
        assertTrue(other.exists())
        assertTrue(repository.recordingRecords().isEmpty())
    }

    @Test
    fun aPendingSongFolderDeletionWaitsForReadableTombstones() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("gone")))
        repository.moveProjectToTrash("gone", 10L)
        File(RecordingFiles.memoDirectory(filesDir, "gone").apply { mkdirs() }, "take.m4a").apply { writeBytes("take".toByteArray()) }
        val adopt: suspend (Set<String>) -> Unit = { com.rhymeai.app.data.recording.RecordingTransitions.adopt(repository, filesDir, it) }
        repository.permanentlyDeleteTrashedProject("gone", now = 5_000L, adopt = adopt)
        // The folder deletion is pending; then the tombstones become unreadable.
        dataStore.edit { it[androidx.datastore.preferences.core.stringPreferencesKey("sync_deletions_json")] = "{not json" }
        var deleteCalls = 0

        val done = runCatching { repository.retryPendingRecordingDeletions { deleteCalls++; true } }

        assertTrue(done.isFailure || done.getOrNull() == false)
        assertEquals(0, deleteCalls)
        // Adoption gave it its id name; the bytes are still there.
        assertEquals(listOf("take"), RecordingFiles.memoDirectory(filesDir, "gone").listFiles()!!.map { it.readText() })
    }

    private fun secondDevice(name: String): Pair<ProjectRepository, Pair<File, DriveSyncService>> {
        val files = File(root, "$name-files").also { it.mkdirs() }
        val repo = ProjectRepository(PreferenceDataStoreFactory.create(scope = scope) { File(root, "$name.preferences_pb") }, MemoryKeyStore())
        return repo to (files to DriveSyncService(files, MemoryKeyStore(), drive, auth, clientId = { name }, now = { clock }))
    }

    private suspend fun holdRecording(
        repo: ProjectRepository, dir: File, id: String, name: String, bytes: ByteArray, time: Long,
        renamedHere: Boolean = false
    ): RecordingRecord {
        val file = RecordingFileStore.targetFile(dir, "p", id, name).apply { parentFile!!.mkdirs(); writeBytes(bytes) }
        val record = RecordingRecord(id, "p", name, time, BackupManifest.sha256Hex(bytes), bytes.size.toLong(),
            RecordingRecord.RECORDED, path = com.rhymeai.app.data.recording.RecordingTransitions.relativePath(dir, file),
            displayNameChanged = renamedHere)
        repo.updateRecordingRecords { it + record }
        return record
    }

    @Test
    fun aRenameOnOneDeviceWinsOnBothWithoutFlipFloppingAndMovesNoFile() = runBlocking<Unit> {
        val (otherRepo, otherSide) = secondDevice("other")
        val (otherFiles, other) = otherSide
        repository.saveProjects(listOf(song("p")))
        otherRepo.saveProjects(listOf(song("p")))
        val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val bytes = "the take".toByteArray()
        // Both devices synced it as old.m4a; then B's user renamed it to new.m4a.
        holdRecording(repository, filesDir, id, "old.m4a", bytes, 10L)
        holdRecording(otherRepo, otherFiles, id, "new.m4a", bytes, 10L, renamedHere = true)
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(
            RecordingManifestEntry("p", "old.m4a", sizeBytes = bytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = 10L, id = id)
        )))

        val names = mutableListOf<String>()
        repeat(2) {
            assertIs<SyncResult.Success>(service.backUp(repository))
            names += remote().recordings.single().fileName
            assertIs<SyncResult.Success>(other.backUp(otherRepo))
            names += remote().recordings.single().fileName
        }
        assertEquals(listOf("old.m4a", "new.m4a", "new.m4a", "new.m4a"), names)
        // A follows Drive's name in its record; B's rename is written, so its flag is cleared.
        assertEquals("new.m4a", repository.recordingRecords().single().displayName)
        assertFalse(otherRepo.recordingRecords().single().displayNameChanged)
        assertIs<SyncResult.Success>(service.restore(repository))
        assertEquals("new.m4a", remote().recordings.single().fileName)
        // Nothing on disk was renamed on either device.
        assertEquals(listOf("$id.m4a"), RecordingFiles.memoDirectory(filesDir, "p").list()!!.toList())
        assertEquals(listOf("$id.m4a"), RecordingFiles.memoDirectory(otherFiles, "p").list()!!.toList())
    }

    @Test
    fun anImportedRecordingWithoutATimeKeepsItsFirstSeenTimeThroughExportAndAFreshImport() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val bytes = "timeless".toByteArray()
        val entry = RecordingManifestEntry("p", "take.m4a", sizeBytes = bytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = 0L)
        BackupArchive.import(BackupArchive.Contents(SyncBlob(projects = listOf(song("p")), recordings = listOf(entry)), mapOf(entry.id to bytes)), repository, filesDir)

        // The imported record has its first-seen time, marked as a repair (A37), which any real
        // tombstone beats (A38).
        val record = repository.recordingRecords().single()
        val firstSeen = record.uploadedAt
        assertTrue(firstSeen > 0L && record.precedenceRepaired)
        assertTrue(SyncMerger.Tombstones(listOf(SyncDeletion("p", "take.m4a", firstSeen - 1, recordingId = entry.id))).removes(record.toEntry()))

        // Exported and imported into a fresh device: the same time.
        val archive = File(root, "export.zip")
        archive.outputStream().use { BackupArchive.write(it, SyncBlob(projects = listOf(song("p"))), snapshotLocalRecordingFiles(filesDir, emptySet(), repository), 2_000L, "device") }
        val (fresh, freshSide) = secondDevice("fresh")
        clock += 3_600_000L
        BackupArchive.import(BackupArchive.read(archive), fresh, freshSide.first)
        assertEquals(firstSeen, fresh.recordingRecords().single().uploadedAt)
    }

    @Test
    fun duplicateManifestsAProbeAndTheApplyAllFixMissingTimesBeforeComparing() = runBlocking<Unit> {
        // Two manifests: the same song at 500 and at no time; a song tombstone at 750.
        drive.put(BackupManifest.FILE_NAME, BackupManifest.encode(SyncBlob(projects = listOf(song("p", updatedAt = 500L))), 1_000L, "a"))
        drive.add(BackupManifest.FILE_NAME, BackupManifest.encode(SyncBlob(
            projects = listOf(song("p", updatedAt = 0L)), deletions = listOf(SyncDeletion("p", deletedAt = 750L))
        ), 1_000L, "b"))

        // A37: the real time 500 beats the first-seen repair of the time-less copy, so the
        // tombstone at 750 wins in the probe and the backup alike.
        val probe = assertIs<ProbeResult.Ready>(service.probe(repository)).probe
        assertEquals(0, probe.projectCount)
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertEquals(emptyList(), remote().projects.map { it.id })
        assertTrue(remote().deletions.any { it.projectId == "p" && it.isSongTombstone })

        // The transactional apply does the same for a song stored here without a time.
        repository.saveProjects(listOf(song("q", updatedAt = 0L)))
        repository.applySyncResult(SyncBlob(deletions = listOf(SyncDeletion("q", deletedAt = 750L))), repository.snapshotLocalSyncBase())
        // A38: its repaired time loses to the real tombstone, whatever the numbers.
        assertTrue(repository.projectsFlow.first().none { it.id == "q" })
    }

    @Test
    fun aManifestWithoutUploadedAtIsReadAsUnknownAndAMalformedOneIsRefused() = runBlocking<Unit> {
        val bytes = "absent".toByteArray()
        val entry = RecordingManifestEntry("p", "take.m4a", sizeBytes = bytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = 5L)
        fun rehash(edit: (JsonObject) -> JsonObject): ByteArray {
            val root = Json.parseToJsonElement(String(BackupManifest.encode(SyncBlob(projects = listOf(song("p")), recordings = listOf(entry)), 1_000L, "x"))).jsonObject
            val body = edit(JsonObject(root - BackupManifest.HASH_KEY))
            val hash = BackupManifest.sha256Hex(BackupManifest.canonical(body).toByteArray())
            return BackupManifest.canonical(JsonObject(body + (BackupManifest.HASH_KEY to kotlinx.serialization.json.JsonPrimitive(hash)))).toByteArray()
        }
        fun recordingsEdited(change: (JsonObject) -> JsonObject) = rehash { body ->
            JsonObject(body + ("recordings" to kotlinx.serialization.json.JsonArray(body.getValue("recordings").jsonArray.map { change(it.jsonObject) })))
        }
        val absent = recordingsEdited { JsonObject(it - "uploadedAt") }
        assertEquals(0L, BackupManifest.decode(absent).recordings.single().uploadedAt)
        assertFailsWith<DamagedBackupException> {
            BackupManifest.decode(recordingsEdited { JsonObject(it + ("uploadedAt" to kotlinx.serialization.json.JsonPrimitive("soon"))) })
        }

        // A backup gives the absent time its first-seen time.
        repository.saveProjects(listOf(song("p")))
        drive.put(BackupManifest.FILE_NAME, absent)
        putRaw(entry, bytes)
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertEquals(clock, remote().recordings.single().uploadedAt)
    }

    @Test
    fun deletionTimesMustBePositiveAndDuplicatesCountTheNewest() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val take = writeMemo("p", "take.m4a", "take".toByteArray(), modifiedAt = 5_000L)
        val key = androidx.datastore.preferences.core.stringPreferencesKey("sync_deletions_json")
        // Stored newest first, then an older duplicate of the same identity.
        dataStore.edit {
            it[key] = """[{"projectId":"p","fileName":"take.m4a","deletedAt":9000,"recordingId":"${take.id}"},""" +
                """{"projectId":"p","fileName":"take.m4a","deletedAt":1000,"recordingId":"${take.id}"}]"""
        }
        assertEquals(listOf(9_000L), repository.syncDeletions().map { it.deletedAt })
        // The listing hides it (the newest deletion, 9000, is newer than the take's 5000).
        val path = com.rhymeai.app.data.recording.RecordingTransitions.relativePath(filesDir, RecordingFileStore.targetFile(filesDir, "p", take.id, "take.m4a"))
        assertEquals(setOf(path), com.rhymeai.app.data.recording.RecordingTransitions.deletedPaths(repository.recordingRecords(), repository.syncDeletions()))
        assertTrue(SyncMerger.Tombstones(listOf(SyncDeletion("p", "take.m4a", 9_000L, take.id), SyncDeletion("p", "take.m4a", 1_000L, take.id))).removes(take))

        // A zero time is refused where it is written and where it is read.
        assertFails { repository.recordRecordingDeletion("p", "take.m4a", take.id, 0L) }
        dataStore.edit { it[key] = """[{"projectId":"p","fileName":null,"deletedAt":0}]""" }
        assertFails { repository.syncDeletions() }
    }

    @Test
    fun importPlacesArchiveBytesByIdWithTheirDisplayNameInEitherTimeOrder() = runBlocking<Unit> {
        for ((label, yTime) in listOf("earlier" to 1_000L, "later" to 3_000L)) {
            val (repo, side) = secondDevice("import-$label")
            val dir = side.first
            repo.saveProjects(listOf(song("p")))
            val x = holdRecording(repo, dir, "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", "take.m4a", "x take".toByteArray(), 2_000L)
            val yBytes = "y take".toByteArray()
            val y = RecordingManifestEntry("p", "take.m4a", sizeBytes = yBytes.size.toLong(), modifiedAt = 0L,
                sha256 = BackupManifest.sha256Hex(yBytes), uploadedAt = yTime, id = "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2")

            BackupArchive.import(BackupArchive.Contents(SyncBlob(projects = listOf(song("p")), recordings = listOf(y)), mapOf(y.id to yBytes)), repo, dir)

            assertContentEquals(yBytes, RecordingFileStore.targetFile(dir, "p", y.id, "take.m4a").readBytes(), label)
            assertContentEquals("x take".toByteArray(), RecordingFileStore.targetFile(dir, "p", x.id, "take.m4a").readBytes(), label)
            assertEquals(listOf("take.m4a", "take.m4a"), repo.recordingRecords().map { it.displayName }, label)
        }
    }

    @Test
    fun anIdTombstoneWithoutAFileNameIsNeverASongTombstone() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p", updatedAt = 100L)))
        val take = writeMemo("p", "take.m4a", "take".toByteArray(), modifiedAt = 1_000L)
        val idOnly = SyncDeletion("p", fileName = null, deletedAt = 5_000L, recordingId = take.id)
        assertFalse(idOnly.isSongTombstone)

        BackupArchive.import(BackupArchive.Contents(SyncBlob(deletions = listOf(idOnly)), emptyMap()), repository, filesDir)
        quarantineDeletedRecordings(repository, filesDir) // as at launch

        // The song stays; only that recording leaves the library.
        assertEquals(listOf("p"), repository.projectsFlow.first().map { it.id })
        assertFalse(RecordingFileStore.targetFile(filesDir, "p", take.id, "take.m4a").exists())
        assertEquals(listOf("${take.id}.m4a"), RecordingFiles.quarantineDirectory(filesDir, "p").walk().filter { it.isFile }.map { it.name }.toList())
    }

    @Test
    fun aManifestOrArchiveWithADuplicateRecordingIdIsRefusedBeforeAnythingIsApplied() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val bytes = "take".toByteArray()
        val entry = RecordingManifestEntry("p", "take.m4a", sizeBytes = bytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = 5L)
        val twice = SyncBlob(projects = listOf(song("p"), song("new")), recordings = listOf(entry, entry.copy(fileName = "other.m4a", driveName = RecordingManifestEntry.driveNameFor("p", "other.m4a"))))
        assertFails { twice.validate() }
        assertFails { BackupArchive.import(BackupArchive.Contents(twice, mapOf(entry.id to bytes)), repository, filesDir) }
        assertEquals(listOf("p"), repository.projectsFlow.first().map { it.id })
        assertTrue(repository.recordingRecords().isEmpty())
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
        fun remove(name: String) {
            files.values.removeIf { it.name == name }
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

    @Test
    fun twoReplicasRepairingOneTimelessSongSettleOnTheEarlierRepairAndTheTombstoneBetweenWins() = runBlocking<Unit> {
        val (otherRepo, otherSide) = secondDevice("other")
        val other = otherSide.second
        val tA = 1_000L
        val tD = 2_000L
        val tB = 3_000L
        // Both replicas hold the song without a time (an old backup) and repair it when first seen.
        repository.saveProjects(listOf(song("p", updatedAt = 0L)))
        otherRepo.saveProjects(listOf(song("p", updatedAt = 0L)))
        repository.establishPrecedence(emptyList(), tA)
        otherRepo.establishPrecedence(emptyList(), tB)
        assertEquals(tA to true, repository.projectsFlow.first().single().let { it.updatedAt to it.precedenceRepaired })
        assertEquals(tB to true, otherRepo.projectsFlow.first().single().let { it.updatedAt to it.precedenceRepaired })

        // A backs up its repair; a third device's deletion at tD lands in the manifest.
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertTrue(String(drive.bytes(BackupManifest.FILE_NAME)!!).contains("\"precedenceRepaired\":true"))
        putRemote(remote().let { it.copy(deletions = it.deletions + SyncDeletion("p", deletedAt = tD)) })

        // B meets A's earlier repair: the smaller wins, so the tombstone between them wins too.
        assertIs<SyncResult.Success>(other.restore(otherRepo))
        assertIs<SyncResult.Success>(service.restore(repository))
        assertTrue(otherRepo.projectsFlow.first().isEmpty())
        assertTrue(repository.projectsFlow.first().isEmpty())
        assertTrue(remote().projects.isEmpty())
        // A later zero-time copy on B gets tA, not tB, so it cannot outlive the tombstone either.
        assertEquals(tA, otherRepo.establishPrecedence(listOf(SyncBlob(projects = listOf(song("p", updatedAt = 0L)))), 9_000L)
            .single().projects.single().updatedAt)
    }

    @Test
    fun aRealEditBeatsARepairAndClearsItsFlag() = runBlocking<Unit> {
        val repaired = song("p", updatedAt = 9_000L).copy(precedenceRepaired = true)
        val real = song("p", updatedAt = 500L, lyrics = "real")
        // Whatever the order and however old the real time is.
        assertEquals("real", SyncMerger.merge(SyncBlob(projects = listOf(repaired)), SyncBlob(projects = listOf(real))).projects.single().lyrics)
        assertEquals("real", SyncMerger.merge(SyncBlob(projects = listOf(real)), SyncBlob(projects = listOf(repaired))).projects.single().lyrics)
        // Two repairs: the smaller.
        val earlier = repaired.copy(updatedAt = 4_000L, lyrics = "earlier")
        assertEquals("earlier", SyncMerger.merge(SyncBlob(projects = listOf(repaired)), SyncBlob(projects = listOf(earlier))).projects.single().lyrics)

        // An edit here clears the flag; a Trash time repair recomputes the deadline.
        repository.saveProjects(listOf(song("p", updatedAt = 0L)))
        repository.saveTrashedProjects(listOf(TrashedSongProject(song("t", updatedAt = 50L), deletedAt = 0L, deleteAfter = 0L)))
        repository.establishPrecedence(emptyList(), 1_000L)
        assertTrue(repository.projectsFlow.first().single().precedenceRepaired)
        val trashed = repository.trashedProjectsFlow.first().single()
        assertEquals(Triple(1_000L, 1_000L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS, true), Triple(trashed.deletedAt, trashed.deleteAfter, trashed.deletedAtRepaired))
        val stored = repository.projectsFlow.first().single()
        repository.saveActiveState(stored.copy(lyrics = "edited", updatedAt = 2_000L), false, stored.title, "edited", stored.theme)
        assertEquals(2_000L to false, repository.projectsFlow.first().single().let { it.updatedAt to it.precedenceRepaired })
    }

    @Test
    fun aManifestTakeLandsOnDiskUnderItsIdWithItsDisplayName() = runBlocking<Unit> {
        val bytes = "the take".toByteArray()
        val listed = entry("p", "take.m4a", bytes)
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(listed)))
        putRaw(listed, bytes)

        assertIs<SyncResult.Success>(service.restore(repository))

        assertEquals(listOf("${listed.id}.m4a"), RecordingFiles.memoDirectory(filesDir, "p").list()!!.toList())
        val record = repository.recordingRecords().single()
        assertEquals("take.m4a", record.displayName)
        assertEquals("voice-memos/p/${listed.id}.m4a", record.path)
        assertEquals("take.m4a", remote().recordings.single().fileName)
    }

    @Test
    fun aDuplicatedRawRecordingIsRestoredFromTheIntactCopyInEitherListingOrder() = runBlocking<Unit> {
        val good = "good take".toByteArray()
        val torn = "torn take".toByteArray() // same size, other digest, same appProperties
        val listed = entry("p", "take.m4a", good)
        val name = BackupManifest.recordingDriveName(listed.id)
        for (tornFirst in listOf(true, false)) {
            val (repo, side) = secondDevice("dup-$tornFirst")
            drive.clear()
            putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(listed)))
            val order = if (tornFirst) listOf(torn, good) else listOf(good, torn)
            order.forEach { drive.add(name, it, recordingAppProperties(listed)) }

            val result = assertIs<SyncResult.Success>(side.second.restore(repo), "torn first: $tornFirst")

            assertEquals(0, result.damagedRecordings, "torn first: $tornFirst")
            assertContentEquals(good, liveFile("p", "take.m4a", side.first, repo).readBytes(), "torn first: $tornFirst")
        }
    }

    @Test
    fun aDisconnectedLaunchFixesMissingTimesBeforeAnyTombstoneIsCompared() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        repository.saveTrashedProjects(listOf(TrashedSongProject(song("t", updatedAt = 0L), deletedAt = 0L, deleteAfter = 0L)))
        val take = writeMemo("p", "take.m4a", "take".toByteArray(), modifiedAt = 1_000L)
        // A record stored without a time (an older build), and an older tombstone for it.
        repository.updateRecordingRecords { records -> records.map { it.copy(uploadedAt = 0L) } }
        repository.recordRecordingDeletion("p", "take.m4a", take.id, 500L)

        // Lists compare the repaired record: A38, a real tombstone beats a repaired time.
        repository.establishPrecedence(emptyList(), clock)
        val repaired = repository.recordingRecords().single()
        assertTrue(repaired.uploadedAt > 500L && repaired.precedenceRepaired)
        assertEquals(setOf(repaired.path), com.rhymeai.app.data.recording.RecordingTransitions.deletedPaths(repository.recordingRecords(), repository.syncDeletions()))

        // Launch upkeep without Drive: repair first, then the deletion check moves it aside.
        quarantineDeletedRecordings(repository, filesDir)

        assertTrue(repository.recordingRecords().isEmpty())
        assertFalse(RecordingFileStore.targetFile(filesDir, "p", take.id, "take.m4a").exists())
        assertEquals(listOf("${take.id}.m4a"), RecordingFiles.quarantineDirectory(filesDir, "p").walk().filter { it.isFile }.map { it.name }.toList())
        // The trashed song's own time and its Trash time are repaired as well.
        val trashed = repository.trashedProjectsFlow.first().single()
        assertTrue(trashed.project.updatedAt > 0L && trashed.project.precedenceRepaired)
        assertEquals(trashed.deletedAt + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS, trashed.deleteAfter)
    }

    @Test
    fun recordingRowsWrittenBeforeA36AreReadAndMigratedWithTheirIdentityTimeAndIntent() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val dir = RecordingFiles.memoDirectory(filesDir, "p").apply { mkdirs() }
        val take = File(dir, "take.m4a").apply { writeBytes("take".toByteArray()) }
        val before = File(dir, "before.m4a").apply { writeBytes("renamed".toByteArray()) }
        val r = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val q = "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2"
        // Rows exactly as the previous head serialized them (fileName, claims, a rename intent).
        val stored = """[{"id":"$r","projectId":"p","fileName":"take.m4a","uploadedAt":1000,"sha256":"${BackupManifest.sha256Hex(take.readBytes())}","bytes":4,"origin":"recorded","path":"voice-memos/p/take.m4a","claimedName":"take.m4a","syncedName":"take.m4a"},""" +
            """{"id":"$q","projectId":"p","fileName":"after.m4a","uploadedAt":2000,"sha256":"${BackupManifest.sha256Hex(before.readBytes())}","bytes":7,"origin":"imported","path":"voice-memos/p/after.m4a","pendingFrom":"voice-memos/p/before.m4a","pendingFromName":"before.m4a","pendingOp":"move","claimedName":"after.m4a"}]"""
        dataStore.edit { it[androidx.datastore.preferences.core.stringPreferencesKey("recording_records_json")] = stored }

        assertEquals(listOf("take.m4a", "after.m4a"), repository.recordingRecords().map { it.displayName })
        assertEquals(emptyList(), com.rhymeai.app.data.recording.RecordingTransitions.migrate(repository, filesDir))

        val byId = repository.recordingRecords().associateBy { it.id }
        assertEquals(setOf(r, q), byId.keys)
        assertEquals(Triple("take.m4a", 1_000L, "voice-memos/p/$r.m4a"), byId.getValue(r).let { Triple(it.displayName, it.uploadedAt, it.path) })
        // The interrupted rename never reached the file: undone, back to its old name, same id and time.
        assertEquals(Triple("before.m4a", 2_000L, "voice-memos/p/$q.m4a"), byId.getValue(q).let { Triple(it.displayName, it.uploadedAt, it.path) })
        assertTrue(byId.values.all { it.pendingOp == null && it.pendingFromName == null })
        assertEquals(setOf("$r.m4a", "$q.m4a"), dir.list()!!.toSet())
    }

    @Test
    fun aTimelessTrashEntryIsRepairedBeforeExpiryChoosesAnything() = runBlocking<Unit> {
        repository.saveTrashedProjects(listOf(TrashedSongProject(song("t", updatedAt = 0L), deletedAt = 0L, deleteAfter = 0L)))

        val purge = repository.purgeExpiredTrashedProjects(clock)

        assertEquals(emptyList(), purge.purgedIds)
        val kept = repository.trashedProjectsFlow.first().single()
        assertEquals(Triple(clock, clock + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS, true), Triple(kept.deletedAt, kept.deleteAfter, kept.deletedAtRepaired))
    }

    @Test
    fun aRepairedRecordingTimeStaysARepairThroughDriveAndArchiveRoundTrips() = runBlocking<Unit> {
        val bytes = "repaired".toByteArray()
        val listed = entry("p", "take.m4a", bytes, uploadedAt = 1_000L).copy(precedenceRepaired = true)
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(listed)))
        putRaw(listed, bytes)

        assertIs<SyncResult.Success>(service.restore(repository))
        assertEquals(1_000L to true, repository.recordingRecords().single().let { it.uploadedAt to it.precedenceRepaired })
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertTrue(remote().recordings.single().precedenceRepaired)

        // Archive: exported and imported into a fresh device, still a repair at the same time.
        val archive = File(root, "repaired.zip")
        archive.outputStream().use { BackupArchive.write(it, SyncBlob(projects = listOf(song("p"))), snapshotLocalRecordingFiles(filesDir, emptySet(), repository), 2_000L, "device") }
        assertTrue(BackupArchive.read(archive).manifest.recordings.single().precedenceRepaired)
        val (fresh, freshSide) = secondDevice("fresh-repaired")
        BackupArchive.import(BackupArchive.read(archive), fresh, freshSide.first)
        assertEquals(1_000L to true, fresh.recordingRecords().single().let { it.uploadedAt to it.precedenceRepaired })
    }

    @Test
    fun aRealRemoteTimeReplacesALocalRepairSoTheTombstoneBetweenThemWins() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val take = writeMemo("p", "take.m4a", "take".toByteArray())
        repository.updateRecordingRecords { records -> records.map { it.copy(uploadedAt = 2_000L, precedenceRepaired = true) } }
        val real = take.copy(uploadedAt = 1_000L, modifiedAt = 0L)
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(real),
            deletions = listOf(SyncDeletion("p", "take.m4a", 1_500L, recordingId = take.id))))

        assertIs<SyncResult.Success>(service.backUp(repository))
        // Back up already compares (and stores) the real time.
        assertEquals(1_000L to false, repository.recordingRecords().single().let { it.uploadedAt to it.precedenceRepaired })
        assertTrue(remote().recordings.isEmpty())

        assertIs<SyncResult.Success>(service.restore(repository))
        assertTrue(repository.recordingRecords().isEmpty())
        assertFalse(RecordingFileStore.targetFile(filesDir, "p", take.id, "take.m4a").exists())
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertTrue(remote().recordings.isEmpty())
    }

    @Test
    fun repairedRecordingsWithTiedTimesSettleOnDrivesNameInAlternatingBackups() = runBlocking<Unit> {
        val (otherRepo, otherSide) = secondDevice("tie")
        val (otherFiles, other) = otherSide
        repository.saveProjects(listOf(song("p")))
        otherRepo.saveProjects(listOf(song("p")))
        val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val bytes = "tie".toByteArray()
        holdRecording(repository, filesDir, id, "a.m4a", bytes, 10L)
        holdRecording(otherRepo, otherFiles, id, "b.m4a", bytes, 10L)
        repository.updateRecordingRecords { rs -> rs.map { it.copy(precedenceRepaired = true) } }
        otherRepo.updateRecordingRecords { rs -> rs.map { it.copy(precedenceRepaired = true) } }
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(
            RecordingManifestEntry("p", "a.m4a", sizeBytes = bytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = 10L, id = id, precedenceRepaired = true)
        )))

        val names = mutableListOf<String>()
        repeat(3) {
            assertIs<SyncResult.Success>(other.backUp(otherRepo))
            names += remote().recordings.single().fileName
            assertIs<SyncResult.Success>(service.backUp(repository))
            names += remote().recordings.single().fileName
        }
        assertEquals(List(6) { "a.m4a" }, names)
        assertEquals("a.m4a", otherRepo.recordingRecords().single().displayName)
    }

    @Test
    fun aRenameThenTrashBeforeBackUpStillWritesTheNewName() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val bytes = "take".toByteArray()
        val held = holdRecording(repository, filesDir, id, "old.m4a", bytes, 10L)
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertEquals("old.m4a", remote().recordings.single().fileName)

        val file = File(filesDir, held.path!!)
        com.rhymeai.app.data.recording.RecordingTransitions.rename(repository, filesDir, file, "p", "new.m4a")
        com.rhymeai.app.data.recording.RecordingTransitions.moveToTrash(repository, filesDir, file, "p", 20L)
        assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals("new.m4a", remote().recordings.single().fileName)
        assertEquals("new.m4a" to false, repository.recordingRecords().single().let { it.displayName to it.displayNameChanged })
    }

    @Test
    fun backUpMovesNoFileAndReportsOneStillAwaitingItsNewName() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val legacy = File(RecordingFiles.memoDirectory(filesDir, "p").apply { mkdirs() }, "take.m4a").apply { writeBytes("take".toByteArray()) }

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(1, result.unmigratedRecordings)
        assertTrue(legacy.exists())
        assertEquals(listOf("take.m4a"), RecordingFiles.memoDirectory(filesDir, "p").list()!!.toList())
        assertTrue(remote().recordings.isEmpty())
        assertTrue(repository.recordingRecords().none { it.pendingOp != null })
    }

    @Test
    fun idLessRowsFromTheFirstRecordStoreGetTheirDerivedIdAndKeepTheirTime() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val dir = RecordingFiles.memoDirectory(filesDir, "p").apply { mkdirs() }
        val take = File(dir, "take.m4a").apply { writeBytes("take".toByteArray()); setLastModified(9_000L) }
        val sha = BackupManifest.sha256Hex(take.readBytes())
        // Exactly the shape commit 059a5f1 stored: no id, no path.
        val stored = """[{"projectId":"p","fileName":"take.m4a","uploadedAt":1000,"sha256":"$sha","bytes":4,"origin":"recorded"}]"""
        dataStore.edit { it[androidx.datastore.preferences.core.stringPreferencesKey("recording_records_json")] = stored }
        val id = RecordingManifestEntry.legacyRecordingId("p", "take.m4a", sha)

        assertEquals(listOf(id), repository.recordingRecords().map { it.id })
        assertEquals(emptyList(), com.rhymeai.app.data.recording.RecordingTransitions.migrate(repository, filesDir))

        val record = repository.recordingRecords().single()
        assertEquals(id, record.id)
        // Its stored time, not the file time, and its origin.
        assertEquals(Triple(1_000L, RecordingRecord.RECORDED, "voice-memos/p/$id.m4a"), Triple(record.uploadedAt, record.origin, record.path))
        assertEquals("take.m4a", record.displayName)
    }

    @Test
    fun anIdLessRowSurvivesABackupAnExportAndAnUnrelatedAdoptionBeforeItsMigration() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p"), song("other")))
        val dir = RecordingFiles.memoDirectory(filesDir, "p").apply { mkdirs() }
        val take = File(dir, "take.m4a").apply { writeBytes("take".toByteArray()); setLastModified(9_000L) }
        val sha = BackupManifest.sha256Hex(take.readBytes())
        dataStore.edit {
            it[androidx.datastore.preferences.core.stringPreferencesKey("recording_records_json")] =
                """[{"projectId":"p","fileName":"take.m4a","uploadedAt":1000,"sha256":"$sha","bytes":4,"origin":"recorded"}]"""
        }
        val id = RecordingManifestEntry.legacyRecordingId("p", "take.m4a", sha)

        // Back up and an export read without moving anything; another song is adopted on its own.
        assertIs<SyncResult.Success>(service.backUp(repository))
        snapshotLocalRecordings(repository, filesDir, emptySet(), moveFiles = false)
        writeMemo("other", "verse.m4a", "verse".toByteArray())
        com.rhymeai.app.data.recording.RecordingTransitions.adopt(repository, filesDir, setOf("other"))
        assertEquals(1_000L, repository.recordingRecords().single { it.id == id }.uploadedAt)

        com.rhymeai.app.data.recording.RecordingTransitions.migrate(repository, filesDir)
        val record = repository.recordingRecords().single { it.id == id }
        assertEquals(Triple(1_000L, RecordingRecord.RECORDED, "voice-memos/p/$id.m4a"), Triple(record.uploadedAt, record.origin, record.path))
    }

    @Test
    fun aBackupSnapshotWritesNothingToTheFileSystem() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val dir = RecordingFiles.memoDirectory(filesDir, "p").apply { mkdirs() }
        // A legacy file, a duplicate copy in Trash, and an interrupted publish's empty claim.
        File(dir, "take.m4a").writeBytes("take".toByteArray())
        File(RecordingFiles.trashDirectory(filesDir, "p").apply { mkdirs() }, "1500__take.m4a").writeBytes("take".toByteArray())
        val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val staged = File(RecordingFiles.stagingDirectory(filesDir, "p").apply { mkdirs() }, "$id.m4a").apply { writeBytes("staged".toByteArray()) }
        val claim = File(dir, "$id.m4a").apply { createNewFile() }
        repository.updateRecordingRecords {
            listOf(RecordingRecord(id, "p", "staged.m4a", 1L, BackupManifest.sha256Hex(staged.readBytes()), 6L, RecordingRecord.RECORDED,
                path = com.rhymeai.app.data.recording.RecordingTransitions.relativePath(filesDir, claim),
                pendingFrom = com.rhymeai.app.data.recording.RecordingTransitions.relativePath(filesDir, staged),
                pendingOp = RecordingRecord.OP_PUBLISH))
        }
        fun state() = filesDir.walk().filter { !it.path.contains("datastore") }
            .map { Triple(it.relativeTo(filesDir).path, it.length(), it.lastModified()) }.toSet()
        val before = state()

        assertIs<SyncResult.Success>(service.backUp(repository))
        snapshotLocalRecordings(repository, filesDir, emptySet(), moveFiles = false)

        assertEquals(before, state())
        assertEquals(RecordingRecord.OP_PUBLISH, repository.recordingRecords().single { it.id == id }.pendingOp)
    }

    @Test
    fun aRecordingWhoseMigrationIsBlockedIsStillTombstonedWithItsDeletedSong() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        repository.moveProjectToTrash("p", 10L)
        val dir = RecordingFiles.memoDirectory(filesDir, "p").apply { mkdirs() }
        val audio = "old take".toByteArray()
        val take = File(dir, "take.m4a").apply { writeBytes(audio) }
        val sha = BackupManifest.sha256Hex(audio)
        val r = RecordingManifestEntry.legacyRecordingId("p", "take.m4a", sha)
        // A row from the first record store, and other bytes already at its id name.
        dataStore.edit {
            it[androidx.datastore.preferences.core.stringPreferencesKey("recording_records_json")] =
                """[{"projectId":"p","fileName":"take.m4a","uploadedAt":1000,"sha256":"$sha","bytes":${audio.size},"origin":"recorded"}]"""
        }
        File(dir, "$r.m4a").writeBytes("squatter".toByteArray())
        val adopt: suspend (Set<String>) -> Unit = { com.rhymeai.app.data.recording.RecordingTransitions.adopt(repository, filesDir, it) }

        repository.permanentlyDeleteTrashedProject("p", now = 5_000L, adopt = adopt)

        assertTrue(take.exists())
        assertTrue(repository.syncDeletions().any { it.recordingId == r && it.deletedAt == 5_000L })
        // The song comes back newer from another device, beside an older backup still listing the take.
        val old = RecordingManifestEntry("p", "take.m4a", sizeBytes = audio.size.toLong(), modifiedAt = 0L, sha256 = sha, uploadedAt = 1_000L)
        putRemote(SyncBlob(projects = listOf(song("p", updatedAt = 9_000L)), recordings = listOf(old)))
        putRaw(old, audio)

        assertIs<SyncResult.Success>(service.restore(repository))

        assertEquals(listOf("p"), repository.projectsFlow.first().map { it.id })
        assertTrue(remote().recordings.none { it.id == r })
        assertTrue(repository.recordingRecords().none { it.id == r })
    }

    @Test
    fun aSongDeletionStopsWhileAFileOfItCannotBeIdentified() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        repository.moveProjectToTrash("p", 10L)
        val dir = RecordingFiles.memoDirectory(filesDir, "p").apply { mkdirs() }
        val take = File(dir, "take.m4a").apply { writeBytes("old take".toByteArray()) }
        // No record, and its derived id name already holds other bytes: it cannot be tombstoned.
        val r = RecordingManifestEntry.legacyRecordingId("p", "take.m4a", BackupManifest.sha256Hex(take.readBytes()))
        File(dir, "$r.m4a").writeBytes("squatter".toByteArray())
        val adopt: suspend (Set<String>) -> Unit = { com.rhymeai.app.data.recording.RecordingTransitions.adopt(repository, filesDir, it) }

        assertFails { repository.permanentlyDeleteTrashedProject("p", now = 5_000L, adopt = adopt) }

        assertEquals(listOf("p"), repository.trashedProjectsFlow.first().map { it.project.id })
        assertTrue(take.exists())
    }

    @Test
    fun aRecordingWhoseBytesDifferFromDrivesEntryForItsIdIsReportedAndBothAreKept() = runBlocking<Unit> {
        repository.saveProjects(listOf(song("p")))
        val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val mine = "my take".toByteArray()
        val theirs = "their take".toByteArray()
        val held = holdRecording(repository, filesDir, id, "take.m4a", mine, 10L)
        val listed = RecordingManifestEntry("p", "take.m4a", sizeBytes = theirs.size.toLong(), modifiedAt = 0L,
            sha256 = BackupManifest.sha256Hex(theirs), uploadedAt = 10L, id = id)
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(listed)))
        putRaw(listed, theirs)
        val name = BackupManifest.recordingDriveName(id)

        assertEquals(1, assertIs<SyncResult.Success>(service.backUp(repository)).conflictingRecordings)
        assertEquals(1, assertIs<SyncResult.Success>(service.restore(repository)).conflictingRecordings)

        // Nothing is written over on either side.
        assertContentEquals(theirs, drive.bytes(name))
        assertEquals(listed.sha256, remote().recordings.single().sha256)
        assertContentEquals(mine, File(filesDir, held.path!!).readBytes())
    }

    @Test
    fun anEmptyRecordingIsRefusedEverywhere() {
        val empty = RecordingManifestEntry("p", "take.m4a", sizeBytes = 0L, modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(ByteArray(0)), uploadedAt = 1L)
        assertFails { empty.validate() }
        assertFails { BackupManifest.encode(SyncBlob(recordings = listOf(empty)), 1L, "x") }
    }
}
