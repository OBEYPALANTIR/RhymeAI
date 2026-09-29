package com.rhymeai.app.data.sync

import com.rhymeai.app.data.recording.RecordingFiles
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RecordingTombstoneTest {
    private val json = Json { ignoreUnknownKeys = true }

    private fun entry(modifiedAt: Long, name: String = "take.m4a", project: String = "p1") =
        RecordingManifestEntry(projectId = project, fileName = name, sizeBytes = 10L, modifiedAt = modifiedAt, sha256 = "h$modifiedAt")

    private fun tombstone(deletedAt: Long, name: String = "take.m4a", project: String = "p1") =
        RecordingTombstone(project, name, deletedAt)

    private fun tempDir(): File = Files.createTempDirectory("tombstone-test").toFile().also { it.deleteOnExit() }

    private fun driveFiles(vararg entries: RecordingManifestEntry) = entries.associate { it.driveName to "id-${it.driveName}" }

    @Test
    fun trashedLocallyIsNotRestoredFromRemoteManifest() {
        val remoteEntry = entry(modifiedAt = 100L)
        val local = SyncBlob(recordingTombstones = listOf(tombstone(deletedAt = 200L)))
        val remote = SyncBlob(recordings = listOf(remoteEntry))

        val merged = SyncMerger.merge(local, remote)

        assertTrue(merged.recordings.isEmpty())
        val plan = RecordingSyncPlanner.planRestores(
            local = emptyList(),
            remoteManifest = merged.recordings,
            remoteFilesByName = driveFiles(remoteEntry)
        )
        assertTrue(plan.isEmpty())
    }

    @Test
    fun trashedLocallyIsNotUploaded() {
        val filesDir = tempDir()
        val trashDir = RecordingFiles.trashDirectory(filesDir, "p1").also { it.mkdirs() }
        File(trashDir, "500__take.m4a").writeBytes(byteArrayOf(1))
        // The live manifest only lists voice-memos/, so a trashed file is absent from it.
        val liveManifest = emptyList<RecordingManifestEntry>()

        assertEquals(listOf(tombstone(500L)), RecordingTombstoneStore.all(filesDir))
        assertTrue(RecordingSyncPlanner.planUploads(liveManifest, emptyList(), emptySet()).isEmpty())
    }

    @Test
    fun tombstoneSuppressesRemoteEntryEvenWhenRemoteSurvivesInBlob() {
        val remote = SyncBlob(recordings = listOf(entry(modifiedAt = 100L)), recordingTombstones = emptyList())
        val local = SyncBlob(recordingTombstones = listOf(tombstone(deletedAt = 100L)))

        val merged = SyncMerger.merge(local, remote)

        assertTrue(merged.recordings.isEmpty())
        assertEquals(listOf(tombstone(100L)), merged.recordingTombstones)
    }

    @Test
    fun newerRemoteRecordingBeatsTombstone() {
        val remote = SyncBlob(recordings = listOf(entry(modifiedAt = 300L)))
        val local = SyncBlob(recordingTombstones = listOf(tombstone(deletedAt = 200L)))

        val merged = SyncMerger.merge(local, remote)

        assertEquals(listOf(entry(300L)), merged.recordings)
    }

    @Test
    fun remoteTombstoneRemovesLocalManifestEntryFromMergedBlob() {
        val local = SyncBlob(recordings = listOf(entry(modifiedAt = 100L)))
        val remote = SyncBlob(recordingTombstones = listOf(tombstone(deletedAt = 150L)))

        assertTrue(SyncMerger.merge(local, remote).recordings.isEmpty())
    }

    @Test
    fun purgeKeepsTombstoneAndItSurvivesRestart() {
        val filesDir = tempDir()
        val trashDir = RecordingFiles.trashDirectory(filesDir, "p1").also { it.mkdirs() }
        val trashed = File(trashDir, "500__take.m4a").also { it.writeBytes(byteArrayOf(1)) }
        RecordingTombstoneStore.record(filesDir, "p1", "take.m4a", 500L)

        // Purge deletes the trashed file; the persisted store still holds the deletion.
        assertTrue(trashed.delete())
        assertTrue(RecordingTombstoneStore.fromTrash(filesDir).isEmpty())

        // The store is file-backed, so a fresh read (process restart) sees the same state.
        assertEquals(listOf(tombstone(500L)), RecordingTombstoneStore.read(filesDir))
        assertEquals(listOf(tombstone(500L)), RecordingTombstoneStore.all(filesDir))
    }

    @Test
    fun restoreFromTrashClearsTombstone() {
        val filesDir = tempDir()
        val trashDir = RecordingFiles.trashDirectory(filesDir, "p1").also { it.mkdirs() }
        val trashed = File(trashDir, "500__take.m4a").also { it.writeBytes(byteArrayOf(1)) }
        RecordingTombstoneStore.record(filesDir, "p1", "take.m4a", 500L)
        assertEquals(1, RecordingTombstoneStore.all(filesDir).size)

        // Restore moves the file back under its original name and clears the deletion.
        val live = RecordingFiles.memoDirectory(filesDir, "p1").also { it.mkdirs() }
        assertTrue(trashed.renameTo(File(live, "take.m4a")))
        RecordingTombstoneStore.clear(filesDir, "p1", "take.m4a")

        assertTrue(RecordingTombstoneStore.all(filesDir).isEmpty())
    }

    @Test
    fun storeKeepsLatestDeletionPerRecordingAndIgnoresCorruptState() {
        val filesDir = tempDir()
        RecordingTombstoneStore.record(filesDir, "p1", "take.m4a", 500L)
        RecordingTombstoneStore.record(filesDir, "p1", "take.m4a", 400L)
        assertEquals(listOf(tombstone(500L)), RecordingTombstoneStore.read(filesDir))

        RecordingTombstoneStore.file(filesDir).writeText("{not json")
        assertTrue(RecordingTombstoneStore.read(filesDir).isEmpty())
    }

    @Test
    fun oldBlobWithoutTombstoneFieldParsesAndDefaultsEmpty() {
        val oldJson = """{"version":1,"projects":[],"trashed":[],"recordings":[],"savedAt":1,"savedByClientId":"legacy"}"""

        val decoded = json.decodeFromString<SyncBlob>(oldJson)

        assertEquals(emptyList(), decoded.recordingTombstones)
        assertEquals(SyncBlob.CURRENT_VERSION, decoded.version)
    }

    @Test
    fun blobWithTombstonesRoundTripsAndKeepsVersion() {
        val blob = SyncBlob(recordingTombstones = listOf(tombstone(500L)))

        val decoded = json.decodeFromString<SyncBlob>(json.encodeToString(blob))

        assertEquals(listOf(tombstone(500L)), decoded.recordingTombstones)
        assertEquals(1, decoded.version)
    }

    @Test
    fun staleWriterThatDropsTheFieldDoesNotUndoADeletion() {
        // A legacy writer's blob still lists the recording and has no tombstone field at all.
        val legacyRemote = json.decodeFromString<SyncBlob>(
            """{"version":1,"projects":[],"trashed":[],"recordings":[
                {"projectId":"p1","fileName":"take.m4a","sizeBytes":10,"modifiedAt":100,"sha256":"h100"}
               ],"savedAt":1,"savedByClientId":"legacy"}"""
        )
        // This device re-injects its persisted tombstones on every sync, so the deletion is honoured.
        val filesDir = tempDir()
        RecordingTombstoneStore.record(filesDir, "p1", "take.m4a", 200L)
        val local = SyncBlob(recordingTombstones = RecordingTombstoneStore.all(filesDir))

        val merged = SyncMerger.merge(local, legacyRemote)

        assertTrue(legacyRemote.recordings.isNotEmpty())
        assertFalse(merged.recordings.any { it.fileName == "take.m4a" })
        assertEquals(listOf(tombstone(200L)), merged.recordingTombstones)
    }
}
