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
    private val service = DriveSyncService(filesDir, keys, drive, auth, clientId = { "test-device" }, now = { 1_792_702_991_000L })
    private val passphrase = "correct horse battery staple"
    private val legacyJson = Json { encodeDefaults = true }

    @AfterTest
    fun tearDown() {
        scope.cancel()
        root.deleteRecursively()
    }

    private fun song(id: String, updatedAt: Long = 100L, lyrics: String = "lyrics of $id") =
        SongProject(id = id, title = id, lyrics = lyrics, theme = "", updatedAt = updatedAt)

    private fun writeMemo(projectId: String, fileName: String, bytes: ByteArray): RecordingManifestEntry {
        val file = RecordingFileStore.targetFile(filesDir, projectId, fileName)
        file.parentFile!!.mkdirs()
        file.writeBytes(bytes)
        return RecordingManifestEntry(projectId, fileName, sizeBytes = bytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes))
    }

    private fun entry(projectId: String, fileName: String, bytes: ByteArray) =
        RecordingManifestEntry(projectId, fileName, sizeBytes = bytes.size.toLong(), modifiedAt = 5L, sha256 = BackupManifest.sha256Hex(bytes))

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
    fun backupMergesIntoDriveWritesRawRecordingsAndLeavesThisDeviceAlone() = runBlocking {
        repository.saveProjects(listOf(song("here")))
        val memo = writeMemo("here", "take.m4a", "raw audio".toByteArray())
        putRemote(SyncBlob(projects = listOf(song("elsewhere"))))

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertEquals(setOf("here", "elsewhere"), remote().projects.map { it.id }.toSet())
        assertEquals(listOf(memo.identityKey), remote().recordings.map { it.identityKey })
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
        assertEquals(uploadsBefore + 0, drive.uploads)
    }

    @Test
    fun restoreMergesBothWaysAndDownloadsOnlyVerifiedMissingRecordings() = runBlocking {
        repository.saveProjects(listOf(song("here")))
        val good = "good take".toByteArray()
        val goodEntry = entry("elsewhere", "good.m4a", good)
        val badEntry = entry("elsewhere", "bad.m4a", "expected".toByteArray())
        putRemote(SyncBlob(projects = listOf(song("elsewhere")), recordings = listOf(goodEntry, badEntry)))
        drive.put("rec_elsewhere_good.m4a", good)
        drive.put("rec_elsewhere_bad.m4a", "tampered".toByteArray())

        val result = assertIs<SyncResult.Success>(service.restore(repository))

        assertEquals(setOf("here", "elsewhere"), repository.projectsFlow.first().map { it.id }.toSet())
        assertEquals(setOf("here", "elsewhere"), remote().projects.map { it.id }.toSet())
        assertContentEquals(good, RecordingFileStore.targetFile(filesDir, "elsewhere", "good.m4a").readBytes())
        assertFalse(RecordingFileStore.targetFile(filesDir, "elsewhere", "bad.m4a").exists())
        assertEquals(1, result.damagedRecordings)
    }

    @Test
    fun restoreNeverReplacesALocalRecording() = runBlocking {
        repository.saveProjects(listOf(song("p")))
        writeMemo("p", "take.m4a", "mine".toByteArray())
        val theirs = "theirs".toByteArray()
        putRemote(SyncBlob(projects = listOf(song("p")), recordings = listOf(entry("p", "take.m4a", theirs))))
        drive.put("rec_p_take.m4a", theirs)

        assertIs<SyncResult.Success>(service.restore(repository))

        assertContentEquals("mine".toByteArray(), RecordingFileStore.targetFile(filesDir, "p", "take.m4a").readBytes())
    }

    @Test
    fun restoreWithoutABackupSaysSoAndWritesNothing() = runBlocking {
        repository.saveProjects(listOf(song("here")))
        assertEquals(SyncResult.NoBackup, service.restore(repository))
        assertNull(drive.bytes(BackupManifest.FILE_NAME))
    }

    @Test
    fun hashMismatchedManifestIsRefusedAndNeverOverwrittenOrMerged() = runBlocking {
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
    fun tombstonesWinOverOlderAndNewerCopies() = runBlocking {
        repository.saveProjects(listOf(song("gone", updatedAt = 9_999L), song("kept")))
        putRemote(SyncBlob(deletions = listOf(SyncDeletion("gone", deletedAt = 1L))))

        assertIs<SyncResult.Success>(service.restore(repository))

        assertEquals(listOf("kept"), repository.projectsFlow.first().map { it.id })
        assertEquals(listOf("kept"), remote().projects.map { it.id })
        assertEquals(listOf(SyncDeletion("gone", deletedAt = 1L)), remote().deletions)
    }

    @Test
    fun probeCountsSongsAndRecordingsAndSeesTheOlderBackup() = runBlocking {
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
    fun storedPassphraseMigratesTheOlderBackupVerifiesThenDeletesIt() = runBlocking {
        repository.saveProjects(listOf(song("here")))
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        val audio = "old take".toByteArray()
        val old = entry("legacy", "take.m4a", audio)
        val tooBig = entry("legacy", "huge.wav", byteArrayOf(1)).copy(sizeBytes = RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES + 1)
        putLegacy(
            SyncBlob(projects = listOf(song("legacy")), recordings = listOf(old, tooBig)),
            mapOf(old to audio, tooBig to byteArrayOf(1))
        )

        val result = assertIs<SyncResult.Success>(service.backUp(repository))

        assertTrue(result.migratedLegacyBackup)
        assertFalse(result.legacyBackupPresent)
        assertEquals(setOf("here", "legacy"), repository.projectsFlow.first().map { it.id }.toSet())
        assertEquals(setOf("here", "legacy"), remote().projects.map { it.id }.toSet())
        assertContentEquals(audio, RecordingFileStore.targetFile(filesDir, "legacy", "take.m4a").readBytes())
        assertContentEquals(audio, drive.bytes("rec_legacy_take.m4a"))
        assertNull(drive.bytes(SyncBlob.DRIVE_FILE_NAME))
        assertNull(drive.bytes(old.driveName))
        // A recording that could not move here is left in Drive, never destroyed.
        assertTrue(drive.bytes(tooBig.driveName) != null)
        assertEquals("", keys.getKey(DriveSyncService.LEGACY_PASSPHRASE_KEY))
    }

    @Test
    fun withoutAPassphraseTheOlderBackupIsLeftAloneAndOffered() = runBlocking {
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
    fun typedPassphraseMigratesOnceAndAWrongOneChangesNothing() = runBlocking {
        putLegacy(SyncBlob(projects = listOf(song("legacy"))))

        assertEquals(SyncResult.WrongPassphrase, service.migrateLegacyBackup(repository, "not the passphrase"))
        assertTrue(drive.bytes(SyncBlob.DRIVE_FILE_NAME) != null)
        assertNull(drive.bytes(BackupManifest.FILE_NAME))

        val result = assertIs<SyncResult.Success>(service.migrateLegacyBackup(repository, "  $passphrase\n"))
        assertTrue(result.migratedLegacyBackup)
        assertNull(drive.bytes(SyncBlob.DRIVE_FILE_NAME))
        assertEquals(listOf("legacy"), repository.projectsFlow.first().map { it.id })
        assertEquals("", keys.getKey(DriveSyncService.LEGACY_PASSPHRASE_KEY))
    }

    @Test
    fun storedPassphraseWithNoOlderBackupIsForgotten() = runBlocking {
        keys.setKey(DriveSyncService.LEGACY_PASSPHRASE_KEY, passphrase)
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertEquals("", keys.getKey(DriveSyncService.LEGACY_PASSPHRASE_KEY))
    }

    @Test
    fun independentIosShapedVectorsMigrateFromEveryEnvelopeVersion() = runBlocking {
        val stream = requireNotNull(javaClass.classLoader!!.getResourceAsStream("sync-envelope-vectors.json"))
        val fixture = Json.parseToJsonElement(stream.bufferedReader().use { it.readText() }).jsonObject
        val vectorPassphrase = fixture.getValue("passphrase").jsonPrimitive.content
        for (vector in fixture.getValue("vectors").jsonArray.map { it.jsonObject }) {
            drive.clear()
            drive.put(SyncBlob.DRIVE_FILE_NAME, Base64.getDecoder().decode(vector.getValue("envelope_base64").jsonPrimitive.content))
            repository.saveProjects(listOf(song("gone", updatedAt = Long.MAX_VALUE), song("keep")))

            val result = assertIs<SyncResult.Success>(service.migrateLegacyBackup(repository, vectorPassphrase))

            assertTrue(result.migratedLegacyBackup, vector.getValue("magic").jsonPrimitive.content)
            if (vector.getValue("magic").jsonPrimitive.content != "RAI1") {
                assertEquals(listOf("keep"), repository.projectsFlow.first().map { it.id })
                assertTrue(remote().deletions.any { it.projectId == "gone" && it.fileName == null })
            }
        }
    }

    @Test
    fun damagedOlderBackupIsReportedAndKept() = runBlocking {
        drive.put(SyncBlob.DRIVE_FILE_NAME, LegacyEnvelopes.sealManifest("""{"version":3}""".toByteArray(), passphrase.toCharArray()))
        assertEquals(SyncResult.CorruptRemote, service.migrateLegacyBackup(repository, passphrase))
        assertTrue(drive.bytes(SyncBlob.DRIVE_FILE_NAME) != null)
    }

    @Test
    fun disconnectRevokesTheCurrentTokenAndReportsWhenGoogleIsUnreachable() = runBlocking {
        assertTrue(service.disconnect())
        assertEquals(listOf("token"), drive.revoked)
        assertEquals(listOf("token"), auth.forgotten)

        drive.failRevoke = true
        assertFalse(service.disconnect())
    }

    @Test
    fun consentIsRequestedBeforeAnyDriveCall() = runBlocking {
        auth.next = DriveAuthorization.Unavailable
        assertEquals(SyncResult.NotConfigured, service.backUp(repository))
        assertEquals(0, drive.calls)
    }

    @Test
    fun trashedSongsTravelInTheManifest() = runBlocking {
        repository.saveTrashedProjects(listOf(TrashedSongProject(song("binned"), deletedAt = 500L)))
        assertIs<SyncResult.Success>(service.backUp(repository))
        assertEquals(listOf("binned" to 500L), remote().trashed.map { it.project.id to it.deletedAt })
    }

    class StoredFile(val name: String, var bytes: ByteArray, val appProperties: Map<String, String>, var version: Int = 1)

    class FakeDrive : DriveClient {
        private val files = LinkedHashMap<String, StoredFile>()
        private var nextId = 0
        var uploads = 0
        var calls = 0
        var failRevoke = false
        val revoked = mutableListOf<String>()

        fun put(name: String, bytes: ByteArray) {
            val existing = files.entries.firstOrNull { it.value.name == name }
            if (existing != null) existing.value.bytes = bytes else files["id-${nextId++}"] = StoredFile(name, bytes, emptyMap())
        }
        fun file(name: String) = files.values.firstOrNull { it.name == name }
        fun bytes(name: String) = file(name)?.bytes
        fun clear() = files.clear()

        private fun meta(id: String, file: StoredFile) = DriveFileMetadata(id, file.name, version = file.version.toString())

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
            return bytes
        }
        override suspend fun uploadNewFile(
            accessToken: String, name: String, mimeType: String, content: ByteArray, appProperties: Map<String, String>
        ): String {
            calls++
            uploads++
            val id = "id-${nextId++}"
            files[id] = StoredFile(name, content, appProperties)
            return id
        }
        override suspend fun updateFile(accessToken: String, fileId: String, mimeType: String, content: ByteArray) {
            calls++
            files.getValue(fileId).apply { bytes = content; version++ }
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
