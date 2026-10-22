package com.rhymeai.app.data.sync

import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.recording.RecordingTransitions
import kotlinx.coroutines.runBlocking
import java.io.File
import java.io.IOException
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A21-A24: recording ids, staging, metadata-before-publication and reconciliation. */
class RecordingIdentityTest {
    private val filesDir = kotlin.io.path.createTempDirectory("rhymeai-identity").toFile()
    private val catalog = MemoryCatalog()

    @AfterTest
    fun tearDown() {
        filesDir.deleteRecursively()
    }

    private fun staged(projectId: String, name: String, bytes: ByteArray): File =
        File(RecordingFiles.stagingDirectory(filesDir, projectId).apply { mkdirs() }, name).apply { writeBytes(bytes) }

    private fun snapshot() = runBlocking { RecordingTransitions.snapshot(catalog, filesDir, emptySet()) }

    @Test
    fun anUnfinishedRecordingIsInvisibleUntilItIsPublishedWithItsRecord() = runBlocking<Unit> {
        val take = staged("song", "1700000000000.m4a", "half written".toByteArray())

        assertTrue(snapshot().isEmpty())
        assertTrue(catalog.records.isEmpty())

        val published = RecordingTransitions.publish(catalog, filesDir, take, "song", take.name, "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", 7_123L, RecordingRecord.RECORDED)!!

        assertFalse(take.exists())
        val listed = snapshot().single()
        assertEquals("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", listed.entry.id)
        assertEquals(7_123L, listed.entry.uploadedAt)
        assertEquals(published, listed.file.canonicalFile)
    }

    @Test
    fun identicalBytesImportedAgainAfterADeletionAreANewRecording() = runBlocking<Unit> {
        val bytes = "same audio".toByteArray()
        val first = RecordingTransitions.publish(
            catalog, filesDir, staged("song", "a.m4a", bytes), "song", "take.m4a",
            RecordingManifestEntry.newRecordingId(), 1_000L, RecordingRecord.RECORDED
        )!!
        val firstId = catalog.records.single().id
        val tombstone = SyncDeletion("song", "take.m4a", 5_000L, recordingId = firstId)
        first.delete()
        assertTrue(snapshot().isEmpty())

        RecordingTransitions.publish(
            catalog, filesDir, staged("song", "b.m4a", bytes), "song", "take.m4a",
            RecordingManifestEntry.newRecordingId(), 9_000L, RecordingRecord.RECORDED
        )
        val second = snapshot().single().entry

        assertNotEquals(firstId, second.id)
        assertEquals(9_000L, second.uploadedAt)
        // The old id's tombstone still applies to the old id only.
        assertFalse(SyncMerger.Tombstones(listOf(tombstone)).removes(second))
        assertTrue(SyncMerger.Tombstones(listOf(tombstone)).removes(second.copy(id = firstId, uploadedAt = 1_000L)))
    }

    @Test
    fun aLiveAndATrashRecordingWithTheSameNameKeepTheirOwnRecords() = runBlocking<Unit> {
        val trashDir = RecordingFiles.trashDirectory(filesDir, "song").apply { mkdirs() }
        File(trashDir, "1500__take.m4a").apply { writeBytes("old take".toByteArray()); setLastModified(1_000L) }
        File(RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }, "take.m4a")
            .apply { writeBytes("new take".toByteArray()); setLastModified(9_000L) }

        val first = snapshot()
        val again = snapshot()

        assertEquals(2, first.size)
        assertEquals(first.map { it.entry.id }, again.map { it.entry.id })
        val live = first.single { !it.inTrash }.entry
        val trash = first.single { it.inTrash }.entry
        assertEquals("take.m4a", live.fileName)
        assertEquals("take.m4a", trash.fileName)
        assertNotEquals(live.id, trash.id)
        assertEquals(9_000L, live.uploadedAt)
        assertEquals(1_000L, trash.uploadedAt)
        // A tombstone for the old take at 5000 leaves the new one alone.
        val tombstones = SyncMerger.Tombstones(listOf(SyncDeletion("song", "take.m4a", 5_000L, recordingId = trash.id)))
        assertTrue(tombstones.removes(trash))
        assertFalse(tombstones.removes(live))
    }

    @Test
    fun aStampedTimeDoesNotFollowTheFileTimeAndARenameKeepsIt() = runBlocking<Unit> {
        val file = File(RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }, "take.m4a")
            .apply { writeBytes("take".toByteArray()); setLastModified(1_000L) }
        val stamped = snapshot().single().entry
        file.setLastModified(99_000L)
        assertEquals(stamped, snapshot().single().entry)

        val renamed = RecordingTransitions.move(
            catalog, filesDir, file, "song", file.name,
            pick = { File(file.parentFile, "Verse.m4a") }, renamesTo = { it.name }
        )!!

        val after = snapshot().single().entry
        assertEquals(stamped.id, after.id)
        assertEquals(1_000L, after.uploadedAt)
        assertEquals("Verse.m4a", after.fileName)
        assertEquals("Verse.m4a", renamed.name)
    }

    @Test
    fun aMetadataWriteFailureFailsEachTransitionAndMovesNothing() = runBlocking<Unit> {
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        val live = File(dir, "take.m4a").apply { writeBytes("take".toByteArray()) }
        val trashed = File(RecordingFiles.trashDirectory(filesDir, "song").apply { mkdirs() }, "1500__old.m4a")
            .apply { writeBytes("old".toByteArray()) }
        val incoming = staged("song", "incoming.m4a", "incoming".toByteArray())
        catalog.failWrites = true

        // Import / Drive restore.
        assertFailsWith<IOException> {
            RecordingTransitions.publish(catalog, filesDir, incoming, "song", "incoming.m4a", RecordingManifestEntry.newRecordingId(), 1L, RecordingRecord.IMPORTED)
        }
        // Rename.
        assertFailsWith<IOException> {
            RecordingTransitions.move(catalog, filesDir, live, "song", live.name, pick = { File(dir, "Renamed.m4a") }, renamesTo = { it.name })
        }
        // Restore from Trash.
        assertFailsWith<IOException> {
            RecordingTransitions.move(catalog, filesDir, trashed, "song", "old.m4a", pick = { File(dir, "old.m4a") }, renamesTo = { it.name })
        }

        assertTrue(incoming.exists())
        assertFalse(File(dir, "incoming.m4a").exists())
        assertTrue(live.exists())
        assertFalse(File(dir, "Renamed.m4a").exists())
        assertTrue(trashed.exists())
        assertFalse(File(dir, "old.m4a").exists())
    }

    @Test
    fun anInterruptedMoveIsFinishedOrUndoneAtTheNextLaunch() = runBlocking<Unit> {
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        val moved = File(dir, "Moved.m4a").apply { writeBytes("moved".toByteArray()) }
        val notMoved = File(dir, "stayed.m4a").apply { writeBytes("stayed".toByteArray()) }
        fun rel(f: File) = RecordingTransitions.relativePath(filesDir, f)
        catalog.records = listOf(
            // The rename reached the file system before the process died.
            RecordingRecord("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", "song", "Moved.m4a", 1_000L, RecordingFileStore.sha256Hex(moved), 5L,
                RecordingRecord.RECORDED, path = rel(moved), pendingFrom = "voice-memos/song/before.m4a", pendingFromName = "before.m4a",
                pendingOp = RecordingRecord.OP_MOVE),
            // This one did not: the record goes back to the old name and path.
            RecordingRecord("7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2", "song", "Target.m4a", 2_000L, RecordingFileStore.sha256Hex(notMoved), 6L,
                RecordingRecord.RECORDED, path = "voice-memos/song/Target.m4a", pendingFrom = rel(notMoved), pendingFromName = "stayed.m4a",
                pendingOp = RecordingRecord.OP_MOVE),
            // A publish whose staged file is gone leaves no record.
            RecordingRecord("b2a1c3d4-e5f6-4789-8abc-def012345678", "song", "lost.m4a", 3_000L, "a".repeat(64), 4L,
                RecordingRecord.RESTORED, path = "voice-memos/song/lost.m4a", pendingFrom = "voice-memos-staging/song/x.m4a",
                pendingOp = RecordingRecord.OP_PUBLISH)
        )

        RecordingTransitions.reconcile(catalog, filesDir)

        val byId = catalog.records.associateBy { it.id }
        assertEquals(2, byId.size)
        assertEquals(rel(moved), byId.getValue("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b").path)
        assertNull(byId.getValue("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b").pendingOp)
        val undone = byId.getValue("7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2")
        assertEquals(rel(notMoved), undone.path)
        assertEquals("stayed.m4a", undone.fileName)
        assertEquals(2_000L, undone.uploadedAt)
        // Snapshots then see both with their original times.
        assertEquals(setOf(1_000L, 2_000L), snapshot().mapTo(HashSet()) { it.entry.uploadedAt })
    }

    @Test
    fun aRestoredRecordingKeepsTheEntrysTimeNotItsFileTime() = runBlocking<Unit> {
        val bytes = "restored".toByteArray()
        val entry = RecordingManifestEntry("song", "take.m4a", sizeBytes = bytes.size.toLong(), modifiedAt = 0L,
            sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = 5_900L, id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b")
        assertTrue(RecordingFileStore.importVerified(catalog, filesDir, entry, bytes, RecordingRecord.RESTORED))
        val listed = snapshot().single()
        assertEquals(5_900L, listed.entry.uploadedAt)
        assertEquals(entry.id, listed.entry.id)
        assertContentEquals(bytes, listed.file.readBytes())
    }
}
