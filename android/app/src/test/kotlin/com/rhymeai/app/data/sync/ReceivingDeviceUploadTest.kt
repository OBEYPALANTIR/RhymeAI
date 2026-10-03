package com.rhymeai.app.data.sync

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.SongWorkspace
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.SecureKeyStore
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Production decision, file snapshot, upload planner/executor and DataStore apply with a local Drive boundary. */
class ReceivingDeviceUploadTest {
    private val passphrase = "synthetic sync passphrase".toCharArray()
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun firstAndRepeatedSyncDoNotReuploadRemotelyDeletedSongOrRemoveLocalBytes() = runBlocking {
        val fixture = Fixture()
        try {
            val song = SongProject(id = "remote-deleted", title = "Retained notes")
            fixture.repository.saveProjects(listOf(song))
            val notebook = SongWorkspace().keep("retain this alternate", 100L)
            fixture.repository.saveWorkspace(song.id, notebook)
            val file = fixture.memo(song.id, "take.m4a", "retained audio bytes")
            val before = RecordingFileStore.sha256Hex(file)
            val remote = fixture.seal(SyncBlob(deletions = listOf(SyncDeletion(song.id, deletedAt = 1L))))

            val first = fixture.sync(remote)
            assertEquals(emptyList(), first.projects)
            assertEquals(emptyList(), first.recordings)
            assertEquals(emptyList(), fixture.drive.recordingUploads)
            assertEquals(emptyList(), fixture.uploadedManifest().recordings)
            assertEquals(before, RecordingFileStore.sha256Hex(file))
            fixture.reopen()
            assertEquals(emptyList(), fixture.repository.projectsFlow.first())
            assertEquals(notebook, fixture.repository.workspacesFlow.first()[song.id])
            assertEquals(emptySet(), fixture.repository.pendingRecordingDeletionIds())

            val count = fixture.drive.fileCount()
            val repeated = fixture.sync(fixture.drive.manifestBytes())
            assertEquals(emptyList(), repeated.recordings)
            assertEquals(count, fixture.drive.fileCount())
            assertEquals(emptyList(), fixture.drive.recordingUploads)
            assertEquals(before, RecordingFileStore.sha256Hex(file))
            assertEquals(notebook, fixture.repository.workspacesFlow.first()[song.id])
        } finally {
            fixture.close()
        }
    }

    @Test
    fun refreshedRemoteProjectTombstoneStopsSecondUploadAndFinalAdvertisement() = runBlocking {
        val fixture = Fixture()
        try {
            val song = SongProject(id = "late-remote", title = "Late tombstone")
            fixture.repository.saveProjects(listOf(song))
            val file = fixture.memo(song.id, "take.m4a", "late remote bytes")
            val before = RecordingFileStore.sha256Hex(file)
            val emptyRemote = fixture.seal(SyncBlob())
            val refreshed = fixture.seal(SyncBlob(deletions = listOf(SyncDeletion(song.id, deletedAt = 2L))))

            val result = fixture.sync(emptyRemote, refreshed)
            // The pre-refresh upload is unavoidable; the second plan must not upload again.
            assertEquals(1, fixture.drive.recordingUploads.size)
            assertEquals(emptyList(), result.recordings)
            assertEquals(emptyList(), fixture.uploadedManifest().recordings)
            assertEquals(before, RecordingFileStore.sha256Hex(file))
            fixture.reopen()
            assertEquals(emptyList(), fixture.repository.projectsFlow.first())
            assertEquals(before, RecordingFileStore.sha256Hex(file))
        } finally {
            fixture.close()
        }
    }

    @Test
    fun uploadOnlyWithWriteAheadDeleteAdvertisesNoRecordingAndRetainsPendingBytes() = runBlocking {
        val fixture = Fixture()
        try {
            val song = SongProject(id = "local-deleted")
            fixture.repository.saveProjects(listOf(song))
            val file = fixture.memo(song.id, "take.m4a", "pending local audio")
            val before = RecordingFileStore.sha256Hex(file)
            fixture.repository.moveProjectToTrash(song.id, 10L)
            fixture.repository.permanentlyDeleteTrashedProject(song.id)
            val result = fixture.sync(null)

            assertEquals(setOf(song.id), result.deletions.map { it.projectId }.toSet())
            assertEquals(emptyList(), fixture.drive.recordingUploads)
            assertEquals(emptyList(), fixture.uploadedManifest().recordings)
            assertEquals(before, RecordingFileStore.sha256Hex(file))
            // A caller supplying a stale local manifest must still not advertise the pending file.
            val staleEntry = RecordingManifestEntry(
                projectId = song.id, fileName = file.name,
                sizeBytes = file.length(), modifiedAt = file.lastModified(), sha256 = before
            )
            val uploadOnly = decideSyncAction(SyncDecisionInput(
                result.copy(recordings = listOf(staleEntry)), null, passphrase, "device"
            )) as SyncDecision.UploadOnly
            assertEquals(emptyList(), uploadOnly.local.recordings)
            assertEquals(emptyList(), json.decodeFromString<SyncBlob>(
                SyncBlobCrypto.openManifest(uploadOnly.sealedBytes, passphrase)
                    .plaintext.toString(Charsets.UTF_8)
            ).recordings)
            fixture.reopen()
            assertEquals(setOf(song.id), fixture.repository.pendingRecordingDeletionIds())
            assertEquals(before, RecordingFileStore.sha256Hex(file))
            val refreshedUploadOnly = fixture.sync(fixture.seal(SyncBlob()), refreshed = null)
            assertEquals(emptyList(), refreshedUploadOnly.recordings)
            assertEquals(emptyList(), fixture.uploadedManifest().recordings)
            assertEquals(emptyList(), fixture.drive.recordingUploads)
            assertEquals(before, RecordingFileStore.sha256Hex(file))
        } finally {
            fixture.close()
        }
    }

    @Test
    fun remoteFileTombstoneExcludesOnlyNamedRecordingFromActualUpload() = runBlocking {
        val fixture = Fixture()
        try {
            val song = SongProject(id = "live-song")
            fixture.repository.saveProjects(listOf(song))
            val removed = fixture.memo(song.id, "removed.m4a", "keep removed bytes locally")
            val allowed = fixture.memo(song.id, "allowed.m4a", "upload this sibling")
            val removedHash = RecordingFileStore.sha256Hex(removed)
            val allowedHash = RecordingFileStore.sha256Hex(allowed)
            val remote = fixture.seal(SyncBlob(
                deletions = listOf(SyncDeletion(song.id, "removed.m4a", 5L))
            ))

            val merged = fixture.sync(remote)
            assertEquals(listOf("allowed.m4a"), merged.recordings.map { it.fileName })
            assertEquals(listOf(RecordingManifestEntry.driveNameFor(song.id, "allowed.m4a")),
                fixture.drive.recordingUploads.distinct())
            assertFalse(fixture.drive.recordingUploads.contains(
                RecordingManifestEntry.driveNameFor(song.id, "removed.m4a")))
            assertEquals(listOf("allowed.m4a"), fixture.uploadedManifest().recordings.map { it.fileName })
            assertEquals(removedHash, RecordingFileStore.sha256Hex(removed))
            assertEquals(allowedHash, RecordingFileStore.sha256Hex(allowed))
            fixture.reopen()
            assertTrue(fixture.repository.projectsFlow.first().any { it.id == song.id })
        } finally {
            fixture.close()
        }
    }

    @Test
    fun outgoingRai2WireIncludesIosRequiredDefaultFieldsOnBothDecisionPaths() = runBlocking {
        val missing = mutableListOf<String>()
        for (merge in listOf(false, true)) {
            val fixture = Fixture()
            try {
                val active = SongProject(id = "wire-active", title = "", lyrics = "", theme = "", updatedAt = 10L)
                val trashed = SongProject(id = "wire-trashed", title = "", lyrics = "", theme = "", updatedAt = 20L)
                fixture.repository.saveProjects(listOf(active, trashed))
                fixture.repository.moveProjectToTrash(trashed.id, 100L)
                val recording = fixture.memo(active.id, "take.m4a", "on-disk recording bytes")
                val remote = if (merge) fixture.seal(SyncBlob()) else null

                fixture.sync(remote)
                val sealed = fixture.drive.manifestBytes()
                assertEquals("RAI2", sealed.copyOfRange(0, 4).toString(Charsets.US_ASCII))
                val opened = SyncBlobCrypto.openManifest(sealed, passphrase)
                assertEquals(2, opened.version)
                val wire = json.parseToJsonElement(opened.plaintext.toString(Charsets.UTF_8)).jsonObject
                assertEquals("2", wire.getValue("version").jsonPrimitive.content)
                assertTrue("deletions" in wire)
                val project = wire.getValue("projects").jsonArray.single().jsonObject
                val trash = wire.getValue("trashed").jsonArray.single().jsonObject
                val trashProject = trash.getValue("project").jsonObject
                val audio = wire.getValue("recordings").jsonArray.single().jsonObject
                val path = if (merge) "MergeAndUpload" else "UploadOnly"
                for (field in listOf("title", "lyrics", "theme")) {
                    if (field !in project) missing += "$path.projects.$field"
                    else assertEquals("", project.getValue(field).jsonPrimitive.content)
                    if (field !in trashProject) missing += "$path.trashed.project.$field"
                    else assertEquals("", trashProject.getValue(field).jsonPrimitive.content)
                }
                if ("deleteAfter" !in trash) missing += "$path.trashed.deleteAfter"
                else assertEquals(
                    (100L + TRASH_RETENTION_MILLIS).toString(),
                    trash.getValue("deleteAfter").jsonPrimitive.content
                )
                if ("driveName" !in audio) missing += "$path.recordings.driveName"
                else assertEquals(
                    RecordingManifestEntry.driveNameFor(active.id, recording.name),
                    audio.getValue("driveName").jsonPrimitive.content
                )
                assertEquals(recording.length().toString(), audio.getValue("sizeBytes").jsonPrimitive.content)
                assertEquals(RecordingFileStore.sha256Hex(recording), audio.getValue("sha256").jsonPrimitive.content)
            } finally {
                fixture.close()
            }
        }
        assertEquals(emptyList(), missing, "Missing iOS-required JSON keys from sealed production decisions")
    }

    private inner class Fixture {
        private val root = kotlin.io.path.createTempDirectory("rhymeai-receiving-upload").toFile()
        private val preferencesFile = File(root, "prefs.preferences_pb")
        private val filesDir = File(root, "app-files").also { it.mkdirs() }
        private var scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        var repository = newRepository()
            private set
        val drive = MemoryDriveClient()

        private fun newRepository() = ProjectRepository(
            PreferenceDataStoreFactory.create(scope = scope) { preferencesFile },
            object : SecureKeyStore {
                override fun getKey(provider: String) = ""
                override fun setKey(provider: String, key: String) = Unit
                override fun allKeys(): Map<String, String> = emptyMap()
                override fun clear() = Unit
            }
        )

        fun memo(projectId: String, fileName: String, content: String): File =
            RecordingFiles.memoFile(filesDir, projectId, fileName).apply {
                parentFile!!.mkdirs()
                writeText(content)
            }

        fun seal(blob: SyncBlob): ByteArray = SyncBlobCrypto.sealManifest(
            json.encodeToString(blob).toByteArray(Charsets.UTF_8), passphrase
        )

        suspend fun sync(remote: ByteArray?, refreshed: ByteArray? = remote): SyncBlob {
            val base = repository.snapshotLocalSyncBase()
            val files = snapshotLocalRecordingFiles(filesDir, base.pendingIds)
            val local = base.blob.copy(recordings = files.map { it.entry })
            val initial = decideSyncAction(SyncDecisionInput(local, remote, passphrase, "device"))
            upload(initial, local, files)
            val final = decideSyncAction(SyncDecisionInput(local, refreshed, passphrase, "device"))
            upload(final, local, files)
            val sealed = when (final) {
                is SyncDecision.MergeAndUpload -> final.sealedBytes
                is SyncDecision.UploadOnly -> final.sealedBytes
                else -> error("Unexpected remote decision: $final")
            }
            drive.uploadNewFile("synthetic", sealed)
            return when (final) {
                is SyncDecision.MergeAndUpload -> repository.applySyncResult(final.merged, base)
                is SyncDecision.UploadOnly -> final.local
                else -> error("Unexpected remote decision: $final")
            }
        }

        private suspend fun upload(
            decision: SyncDecision,
            local: SyncBlob,
            files: List<LocalRecordingFile>
        ) {
            val uploads = when (decision) {
                is SyncDecision.UploadOnly -> decision.local.recordings
                is SyncDecision.MergeAndUpload -> RecordingSyncPlanner.planUploads(
                    local = recordingsAllowedForUpload(
                        local.recordings, local.deletions, decision.remote.deletions
                    ),
                    remoteManifest = decision.remote.recordings,
                    remoteDriveNames = drive.recordingNames()
                )
                else -> error("Unexpected remote decision: $decision")
            }
            uploadRecordingFilesToDrive(
                driveClient = drive,
                accessToken = "synthetic",
                passphrase = passphrase,
                uploads = uploads,
                localFiles = files,
                remoteFilesByName = drive.recordingIds()
            )
        }

        fun uploadedManifest(): SyncBlob = json.decodeFromString(
            SyncBlobCrypto.openManifest(drive.manifestBytes(), passphrase).plaintext.toString(Charsets.UTF_8)
        )

        suspend fun reopen() {
            scope.coroutineContext[Job]!!.cancelAndJoin()
            scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            repository = newRepository()
        }

        fun close() {
            scope.cancel()
            root.deleteRecursively()
        }
    }

    private class MemoryDriveClient : DriveClient {
        private val files = LinkedHashMap<String, ByteArray>()
        val recordingUploads = mutableListOf<String>()
        fun recordingNames(): Set<String> = files.keys.filterTo(mutableSetOf()) { it.startsWith("rec_") }
        fun recordingIds(): Map<String, String> = recordingNames().associateWith { it }
        fun fileCount() = files.size
        fun manifestBytes(): ByteArray = requireNotNull(files[SyncBlob.DRIVE_FILE_NAME])

        override suspend fun findFileByName(accessToken: String, name: String): DriveFileMetadata? =
            files[name]?.let { DriveFileMetadata(id = name, name = name) }
        override suspend fun listFilesByNamePrefix(accessToken: String, namePrefix: String): List<DriveFileMetadata> =
            files.keys.filter { it.startsWith(namePrefix) }.map { DriveFileMetadata(id = it, name = it) }
        override suspend fun downloadFile(accessToken: String, fileId: String, maxBytes: Long): ByteArray =
            requireNotNull(files[fileId]).also { require(it.size.toLong() <= maxBytes) }
        override suspend fun uploadNewFile(
            accessToken: String, name: String, mimeType: String, content: ByteArray
        ): String {
            files[name] = content
            if (name.startsWith("rec_")) recordingUploads += name
            return name
        }
        override suspend fun updateFile(
            accessToken: String, fileId: String, mimeType: String, content: ByteArray
        ) {
            files[fileId] = content
            if (fileId.startsWith("rec_")) recordingUploads += fileId
        }
    }
}
