package com.rhymeai.app.data.sync

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import java.security.MessageDigest
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

class RecordingSyncTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun oldSyncBlobJsonDefaultsRecordingsToEmptyManifest() {
        val oldJson = """
            {
              "version": 1,
              "projects": [],
              "trashed": [],
              "savedAt": 123,
              "savedByClientId": "legacy-device"
            }
        """.trimIndent()

        val decoded = json.decodeFromString<SyncBlob>(oldJson)

        assertEquals(emptyList(), decoded.recordings)
    }

    @Test
    fun recordingRemoteNamesUseInteropFormatFromProjectAndFileStem() {
        val driveName = RecordingManifestEntry.driveNameFor(
            projectId = "project-123",
            fileName = "take 1_final.m4a"
        )

        assertEquals("rec_project-123_take 1_final.m4a.enc", driveName)
    }

    @Test
    fun importedFormatsPreserveExtensionAndCannotCollideWithM4aBackupNames() {
        val wav = RecordingManifestEntry.driveNameFor("song", "take.wav")
        val m4a = RecordingManifestEntry.driveNameFor("song", "take.wav.m4a")
        assertEquals("rec_song_take.wav.enc", wav)
        assertEquals("rec_song_take.wav.m4a.enc", m4a)
        assertFalse(wav == m4a)
    }

    @Test
    fun syncMergerUnionsRecordingsAndKeepsNewestPerIdentity() {
        val localOnly = recording("p1", "local.m4a", modifiedAt = 100L, sha256 = "local")
        val staleLocal = recording("p1", "shared.m4a", modifiedAt = 100L, sha256 = "old")
        val freshRemote = recording("p1", "shared.m4a", modifiedAt = 300L, sha256 = "new")
        val remoteOnly = recording("p2", "remote.m4a", modifiedAt = 200L, sha256 = "remote")

        val merged = SyncMerger.merge(
            local = SyncBlob(recordings = listOf(localOnly, staleLocal)),
            remote = SyncBlob(recordings = listOf(freshRemote, remoteOnly))
        )

        assertEquals(setOf("p1/local.m4a", "p1/shared.m4a", "p2/remote.m4a"), merged.recordings.map { it.identityKey }.toSet())
        assertEquals("new", merged.recordings.first { it.projectId == "p1" && it.fileName == "shared.m4a" }.sha256)
    }

    @Test
    fun uploadPlanIncludesOnlyLocalRecordingsMissingOrOlderInRemoteManifest() {
        val alreadyRemote = recording("p1", "same.m4a", modifiedAt = 100L, sha256 = "same")
        val newerLocal = recording("p1", "newer.m4a", modifiedAt = 300L, sha256 = "local-new")
        val olderRemote = newerLocal.copy(modifiedAt = 200L, sha256 = "remote-old")
        val localOlder = recording("p3", "remote-newer.m4a", modifiedAt = 100L, sha256 = "local-old")
        val remoteNewer = localOlder.copy(modifiedAt = 400L, sha256 = "remote-new")
        val localOnly = recording("p2", "local-only.m4a", modifiedAt = 100L, sha256 = "only")

        val plan = RecordingSyncPlanner.planUploads(
            local = listOf(alreadyRemote, newerLocal, localOlder, localOnly),
            remoteManifest = listOf(alreadyRemote, olderRemote, remoteNewer),
            remoteDriveNames = setOf(alreadyRemote.driveName, olderRemote.driveName)
        )

        assertEquals(listOf(newerLocal.driveName, localOnly.driveName), plan.map { it.driveName })
    }

    @Test
    fun restorePlanIsNonDestructiveAndOnlyDownloadsMissingOrNewerRemoteRecordings() {
        val localOnly = recording("p1", "local-only.m4a", modifiedAt = 500L, sha256 = "keep")
        val localNewer = recording("p1", "local-newer.m4a", modifiedAt = 500L, sha256 = "new-local")
        val remoteOlder = localNewer.copy(modifiedAt = 100L, sha256 = "old-remote")
        val localStale = recording("p1", "stale.m4a", modifiedAt = 100L, sha256 = "old-local")
        val remoteNewer = localStale.copy(modifiedAt = 300L, sha256 = "new-remote")
        val remoteOnly = recording("p2", "remote-only.m4a", modifiedAt = 200L, sha256 = "remote")

        val plan = RecordingSyncPlanner.planRestores(
            local = listOf(localOnly, localNewer, localStale),
            remoteManifest = listOf(remoteOlder, remoteNewer, remoteOnly),
            remoteFilesByName = mapOf(
                remoteOlder.driveName to "drive-old",
                remoteNewer.driveName to "drive-new",
                remoteOnly.driveName to "drive-only"
            )
        )

        assertEquals(listOf("drive-new", "drive-only"), plan.map { it.remoteFileId })
        assertFalse(plan.any { it.entry.identityKey == localOnly.identityKey }, "remote absence must never delete or overwrite local-only recordings")
        assertFalse(plan.any { it.entry.identityKey == localNewer.identityKey }, "older remote must not overwrite newer local recording")
    }

    @Test
    fun recordingFileStoreUsesTempWriteAndKeepsExistingFileOnIntegrityFailure() {
        val root = Files.createTempDirectory("rhymeai-recording-store").toFile()
        try {
            val existing = RecordingFileStore.targetFile(root, "p1", "clip.m4a")
            existing.parentFile?.mkdirs()
            existing.writeText("local stays")

            val remoteBytes = "remote wins".toByteArray()
            val validEntry = recording(
                projectId = "p1",
                fileName = "clip.m4a",
                modifiedAt = 700L,
                sha256 = sha256Hex(remoteBytes),
                sizeBytes = remoteBytes.size.toLong()
            )

            assertFailsWith<DriveNetworkException> {
                RecordingFileStore.writeAtomically(root, validEntry.copy(sizeBytes = remoteBytes.size + 1L), remoteBytes)
            }
            assertEquals("local stays", existing.readText())

            RecordingFileStore.writeAtomically(root, validEntry, remoteBytes)

            assertEquals("remote wins", existing.readText())
            assertEquals(700L, existing.lastModified())
            assertFalse(existing.parentFile?.listFiles()?.any { it.name.endsWith(".tmp") } ?: false)
        } finally {
            root.deleteRecursively()
        }
    }

    private fun recording(
        projectId: String,
        fileName: String,
        modifiedAt: Long,
        sha256: String,
        sizeBytes: Long = 12L
    ): RecordingManifestEntry = RecordingManifestEntry(
        projectId = projectId,
        fileName = fileName,
        driveName = RecordingManifestEntry.driveNameFor(projectId, fileName),
        sizeBytes = sizeBytes,
        modifiedAt = modifiedAt,
        sha256 = sha256
    )

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }
}
