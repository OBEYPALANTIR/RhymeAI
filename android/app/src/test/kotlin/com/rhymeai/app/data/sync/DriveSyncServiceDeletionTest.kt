package com.rhymeai.app.data.sync

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.SecureKeyStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Runs the real [DriveSyncService.restore] and [DriveSyncService.sync] callers against a fake Drive
 * client and a real temp DataStore, to prove the ordering of deletion-record writes versus every
 * recording upload and library blob write, and that a verified deletion is never dropped.
 */
class DriveSyncServiceDeletionTest {
    private val passphraseText = "correct horse"
    private val passphrase = passphraseText.toCharArray()
    private val json = Json { ignoreUnknownKeys = true }

    private class RecordingDrive : DriveClient {
        val objects = linkedMapOf<String, Pair<String, ByteArray>>()
        val ops = mutableListOf<String>()
        var failUploadPrefix: String? = null
        private var nextId = 0

        fun put(name: String, bytes: ByteArray): String {
            val id = "seed${nextId++}"
            objects[id] = name to bytes
            return id
        }

        override suspend fun findFileByName(accessToken: String, name: String): DriveFileMetadata? =
            objects.entries.firstOrNull { it.value.first == name }?.let { DriveFileMetadata(it.key, name) }

        override suspend fun listFilesByNamePrefix(accessToken: String, namePrefix: String): List<DriveFileMetadata> =
            objects.filter { it.value.first.startsWith(namePrefix) }.map { DriveFileMetadata(it.key, it.value.first) }

        override suspend fun downloadFile(accessToken: String, fileId: String, maxBytes: Long): ByteArray {
            val bytes = objects.getValue(fileId).second
            if (bytes.size > maxBytes) throw DriveNetworkException("too large")
            return bytes
        }

        override suspend fun uploadNewFile(accessToken: String, name: String, mimeType: String, content: ByteArray): String {
            if (failUploadPrefix?.let { name.startsWith(it) } == true) throw DriveNetworkException("upload failed")
            ops += "upload:$name"
            val id = "up${nextId++}"
            objects[id] = name to content
            return id
        }

        override suspend fun updateFile(accessToken: String, fileId: String, mimeType: String, content: ByteArray) {
            val name = objects.getValue(fileId).first
            ops += "update:$name"
            objects[fileId] = name to content
        }
    }

    private class FixedKeyStore(private val passphrase: String) : SecureKeyStore {
        override fun getKey(provider: String): String = if (provider == DriveSyncService.PASSPHRASE_KEY) passphrase else ""
        override fun setKey(provider: String, key: String) {}
        override fun allKeys(): Map<String, String> = emptyMap()
        override fun clear() {}
    }

    private class Env(passphrase: String) {
        val filesDir: File = Files.createTempDirectory("svc-files").toFile()
        val noBackupDir: File = Files.createTempDirectory("svc-nobackup").toFile()
        val drive = RecordingDrive()
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private val dataStoreFile = File(Files.createTempDirectory("svc-ds").toFile(), "repo.preferences_pb")
        val repository = ProjectRepository(
            PreferenceDataStoreFactory.create(scope = scope) { dataStoreFile },
            FixedKeyStore(passphrase)
        )
        private val host = object : DriveSyncHost {
            override val filesDir: File get() = this@Env.filesDir
            override val noBackupFilesDir: File get() = this@Env.noBackupDir
            override fun clientId(): String = "client-under-test"
            override suspend fun authorize(): DriveAuthorization? = DriveAuthorization(false, null, "token")
        }
        val service = DriveSyncService(host, FixedKeyStore(passphrase), drive)

        fun close() {
            scope.cancel()
        }
    }

    private fun seedMainBlob(env: Env) {
        val blob = SyncBlob(savedByClientId = "other-device")
        val sealed = SyncBlobCrypto.seal(json.encodeToString(blob).toByteArray(Charsets.UTF_8), passphrase)
        env.drive.put(SyncBlob.DRIVE_FILE_NAME, sealed)
    }

    private fun writeLiveRecording(env: Env, name: String) {
        val dir = RecordingFiles.memoDirectory(env.filesDir, "p1")
        dir.mkdirs()
        File(dir, name).writeBytes(ByteArray(64) { it.toByte() })
    }

    private fun manifest(name: String, sha: String) =
        RecordingManifestEntry(projectId = "p1", fileName = name, sizeBytes = 1L, modifiedAt = 100L, sha256 = sha)

    private suspend fun readSidecar(env: Env): SidecarRead.Ok =
        DeletionSidecar(env.drive, FileSidecarWriterIdentity(env.noBackupDir)).readAll("token", passphrase) as SidecarRead.Ok

    @Test
    fun restorePublishesOwnDeletionRecordsBeforeAnyRecordingUploadOrBlobWrite() {
        val env = Env(passphraseText)
        try {
            runBlocking {
                seedMainBlob(env)
                RecordingTombstoneStore.record(env.filesDir, "p1", "take.m4a", "h100", 200L)
                writeLiveRecording(env, "live.m4a")

                val result = env.service.restore(env.repository)

                assertTrue(result is SyncResult.Success, result.toString())
                val ops = env.drive.ops
                val sidecarAt = ops.indexOfFirst { it.startsWith("upload:${DeletionSidecar.NAME_PREFIX}") }
                val recordingAt = ops.indexOfFirst { it.startsWith("upload:rec_") }
                val blobAt = ops.indexOf("update:${SyncBlob.DRIVE_FILE_NAME}")
                assertTrue(sidecarAt >= 0, "sidecar object was not written: $ops")
                assertTrue(recordingAt > sidecarAt, "recording upload must follow the sidecar write: $ops")
                assertTrue(blobAt > recordingAt, "blob write must follow recording upload: $ops")
                assertTrue(readSidecar(env).entries.any { it.suppresses(manifest("take.m4a", "h100")) })
            }
        } finally {
            env.close()
        }
    }

    @Test
    fun restoreWritesNothingWhenTheDeletionRecordsCannotBeSaved() {
        val env = Env(passphraseText)
        try {
            runBlocking {
                seedMainBlob(env)
                RecordingTombstoneStore.record(env.filesDir, "p1", "take.m4a", "h100", 200L)
                writeLiveRecording(env, "live.m4a")
                env.drive.failUploadPrefix = DeletionSidecar.NAME_PREFIX

                val result = env.service.restore(env.repository)

                assertTrue(result is SyncResult.NetworkError, result.toString())
                assertTrue(env.drive.ops.isEmpty(), "no recording or blob write may happen: ${env.drive.ops}")
                assertEquals(1, env.drive.objects.size)
            }
        } finally {
            env.close()
        }
    }

    @Test
    fun syncStillPublishesBeforeWriting() {
        val env = Env(passphraseText)
        try {
            runBlocking {
                seedMainBlob(env)
                RecordingTombstoneStore.record(env.filesDir, "p1", "take.m4a", "h100", 200L)
                writeLiveRecording(env, "live.m4a")

                val result = env.service.sync(env.repository)

                assertTrue(result is SyncResult.Success, result.toString())
                val ops = env.drive.ops
                val sidecarAt = ops.indexOfFirst { it.startsWith("upload:${DeletionSidecar.NAME_PREFIX}") }
                val blobAt = ops.indexOf("update:${SyncBlob.DRIVE_FILE_NAME}")
                assertTrue(sidecarAt in 0 until blobAt, "sidecar must precede the blob write: $ops")
            }
        } finally {
            env.close()
        }
    }

    @Test
    fun oldVerifiedDeletionSurvivesDamagedLocalStateAndLaterSyncs() {
        val env = Env(passphraseText)
        try {
            runBlocking {
                seedMainBlob(env)
                RecordingTombstoneStore.record(env.filesDir, "p1", "take.m4a", "h100", 200L)
                assertTrue(env.service.sync(env.repository) is SyncResult.Success)
                assertTrue(readSidecar(env).entries.any { it.suppresses(manifest("take.m4a", "h100")) })

                // Local state is damaged, then a new deletion is recorded.
                RecordingTombstoneStore.file(env.filesDir).writeText("{not json")
                RecordingTombstoneStore.record(env.filesDir, "p1", "new.m4a", "h2", 300L)
                assertTrue(env.service.sync(env.repository) is SyncResult.Success)

                repeat(2) {
                    val read = readSidecar(env)
                    assertTrue(read.entries.any { it.suppresses(manifest("take.m4a", "h100")) }, "old deletion lost")
                    assertTrue(read.entries.any { it.suppresses(manifest("new.m4a", "h2")) }, "new deletion missing")
                    assertTrue(env.service.sync(env.repository) is SyncResult.Success)
                }
            }
        } finally {
            env.close()
        }
    }

    @Test
    fun unreadableOwnObjectIsNotOverwrittenAndNothingIsWritten() {
        val env = Env(passphraseText)
        try {
            runBlocking {
                seedMainBlob(env)
                val ownName = DeletionSidecar.objectName(FileSidecarWriterIdentity(env.noBackupDir).writerId())
                val foreign = SyncBlobCrypto.seal("x".toByteArray(), "another passphrase".toCharArray())
                val ownId = env.drive.put(ownName, foreign)
                RecordingTombstoneStore.record(env.filesDir, "p1", "take.m4a", "h100", 200L)

                val result = env.service.sync(env.repository)

                assertTrue(result is SyncResult.NetworkError, result.toString())
                assertContentEquals(foreign, env.drive.objects.getValue(ownId).second)
                assertFalse(env.drive.ops.contains("update:${SyncBlob.DRIVE_FILE_NAME}"), "blob must not be written: ${env.drive.ops}")
            }
        } finally {
            env.close()
        }
    }
}
