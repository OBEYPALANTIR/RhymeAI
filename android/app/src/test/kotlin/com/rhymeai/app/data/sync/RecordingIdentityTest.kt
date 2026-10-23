package com.rhymeai.app.data.sync

import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.recording.RecordingTransitions
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
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

    @Test
    fun twoUnseededDevicesAndAnIdLessOlderBackupGiveAPreV4RecordingOneId() = runBlocking<Unit> {
        val bytes = "old take".toByteArray()
        val other = kotlin.io.path.createTempDirectory("rhymeai-identity-other").toFile()
        try {
            for (dir in listOf(filesDir, other)) {
                File(RecordingFiles.memoDirectory(dir, "song").apply { mkdirs() }, "take.m4a").writeBytes(bytes)
            }
            val here = snapshot().single().entry.id
            val there = RecordingTransitions.snapshot(MemoryCatalog(), other, emptySet()).single().entry.id
            val sha = BackupManifest.sha256Hex(bytes)
            val legacy = Json { ignoreUnknownKeys = true }.decodeFromString(
                SyncBlob.serializer(),
                """{"version":3,"deletions":[],"recordings":[{"projectId":"song","fileName":"take.m4a","sizeBytes":8,"modifiedAt":1,"sha256":"$sha"}]}"""
            )

            assertEquals(here, there)
            assertEquals(here, legacy.recordings.single().id)
            assertEquals(RecordingManifestEntry.legacyRecordingId("song", "take.m4a", sha), here)
        } finally {
            other.deleteRecursively()
        }
    }

    @Test
    fun aMoveInterruptedAfterTheFileMovedKeepsTheRecordingsId() = runBlocking<Unit> {
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        val file = File(dir, "take.m4a").apply { writeBytes("take".toByteArray()); setLastModified(1_000L) }
        val stamped = snapshot().single().entry
        // Write 1 was the stamp, write 2 is the intent; write 3, the final record, fails after the file moved.
        catalog.failOnWrite = 3
        assertFailsWith<IOException> {
            RecordingTransitions.move(catalog, filesDir, file, "song", file.name, pick = { File(dir, "Verse.m4a") }, renamesTo = { it.name })
        }
        val moved = File(dir, "Verse.m4a")
        assertTrue(moved.exists())

        // The next consumer reconciles first and finds the same recording.
        val record = RecordingTransitions.recordFor(catalog, filesDir, moved, "song")!!
        assertEquals(stamped.id, record.id)
        assertEquals(1_000L, record.uploadedAt)
        assertEquals(stamped.id, snapshot().single().entry.id)
        assertEquals("Verse.m4a", snapshot().single().entry.fileName)
    }

    @Test
    fun aMaximumLengthNameStaysValidThroughCollisionSnapshotReExportAndRename() = runBlocking<Unit> {
        val base = "\u00e9".repeat(118) // 236 UTF-8 bytes
        val name = "$base.m4a" // the 240-byte limit
        fun bytesOf(s: String) = s.toByteArray(Charsets.UTF_8).size
        val first = RecordingTransitions.publish(catalog, filesDir, staged("song", "a.m4a", "first".toByteArray()), "song", name,
            RecordingManifestEntry.newRecordingId(), 1_000L, RecordingRecord.RECORDED)!!
        val second = RecordingTransitions.publish(catalog, filesDir, staged("song", "b.m4a", "second".toByteArray()), "song", name,
            RecordingManifestEntry.newRecordingId(), 2_000L, RecordingRecord.RECORDED)!!

        assertEquals(name, first.name)
        assertTrue(bytesOf(second.name) <= 240 && second.name.endsWith(" 2.m4a"), second.name)
        val listed = snapshot()
        assertEquals(2, listed.size)
        listed.forEach { it.entry.validate() }

        // Re-export and read back.
        val archive = File(filesDir, "export.zip")
        archive.outputStream().use { BackupArchive.write(it, SyncBlob(), listed, 3_000L, "device") }
        assertEquals(listed.map { it.entry.id }.toSet(), BackupArchive.read(archive).manifest.recordings.map { it.id }.toSet())

        // Renaming the variant back onto the taken name gives another bounded variant and keeps the id.
        val secondId = listed.single { it.file.canonicalFile == second.canonicalFile }.entry.id
        val renamed = RecordingTransitions.move(catalog, filesDir, second, "song", second.name,
            pick = { RecordingFiles.resolveCollision(second.parentFile!!, base, "m4a") }, renamesTo = { it.name })!!
        assertTrue(bytesOf(renamed.name) <= 240, renamed.name)
        val after = snapshot()
        assertEquals(2, after.size)
        assertEquals(renamed.name, after.single { it.entry.id == secondId }.entry.fileName)
    }

    @Test
    fun identicalLiveAndTrashCopiesAreOneRecordingWhicheverIsSeenFirst() = runBlocking<Unit> {
        val bytes = "old take".toByteArray()
        val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", BackupManifest.sha256Hex(bytes))
        fun device(dir: File): Pair<File, File> {
            val live = File(RecordingFiles.memoDirectory(dir, "song").apply { mkdirs() }, "take.m4a").apply { writeBytes(bytes); setLastModified(1_000L) }
            val trashed = File(RecordingFiles.trashDirectory(dir, "song").apply { mkdirs() }, "1500__take.m4a").apply { writeBytes(bytes); setLastModified(1_000L) }
            return live to trashed
        }
        val other = kotlin.io.path.createTempDirectory("rhymeai-identity-other").toFile()
        try {
            // Here a snapshot sees both copies first; there the Trash copy is consumed first.
            device(filesDir)
            val (_, otherTrash) = device(other)
            val otherCatalog = MemoryCatalog()
            assertNull(RecordingTransitions.recordFor(otherCatalog, other, otherTrash, "song"))

            val here = snapshot()
            val there = RecordingTransitions.snapshot(otherCatalog, other, emptySet())
            for ((dir, listed) in listOf(filesDir to here, other to there)) {
                assertEquals(listOf(id), listed.map { it.entry.id })
                assertFalse(listed.single().inTrash)
                // The Trash copy is kept, never deleted, in quarantine.
                assertContentEquals(bytes, RecordingFiles.quarantineDirectory(dir, "song").listFiles().orEmpty().single().readBytes())
                assertTrue(RecordingFiles.trashDirectory(dir, "song").list().orEmpty().isEmpty())
            }
        } finally {
            other.deleteRecursively()
        }
    }

    @Test
    fun aLiveCopyAppearingAfterItsTrashCopyWasStampedTakesOverTheSameIdAndTime() = runBlocking<Unit> {
        val bytes = "old take".toByteArray()
        File(RecordingFiles.trashDirectory(filesDir, "song").apply { mkdirs() }, "1500__take.m4a").apply { writeBytes(bytes); setLastModified(1_000L) }
        val stamped = snapshot().single()
        assertTrue(stamped.inTrash)

        File(RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }, "take.m4a").apply { writeBytes(bytes); setLastModified(9_000L) }
        val after = snapshot().single()

        assertEquals(stamped.entry.id, after.entry.id)
        assertEquals(1_000L, after.entry.uploadedAt)
        assertFalse(after.inTrash)
        assertEquals(1, RecordingFiles.quarantineDirectory(filesDir, "song").list().orEmpty().size)
    }

    @Test
    fun anEmptyStemNameGetsANamedVariantOnCollision() = runBlocking<Unit> {
        val first = RecordingTransitions.publish(catalog, filesDir, staged("song", "a.m4a", "first".toByteArray()), "song", ".m4a",
            RecordingManifestEntry.newRecordingId(), 1_000L, RecordingRecord.RESTORED)!!
        val second = RecordingTransitions.publish(catalog, filesDir, staged("song", "b.m4a", "second".toByteArray()), "song", ".m4a",
            RecordingManifestEntry.newRecordingId(), 2_000L, RecordingRecord.RESTORED)!!

        assertEquals(".m4a", first.name)
        assertEquals("Recording 2.m4a", second.name)
        assertEquals(2, snapshot().size)
    }

    @Test
    fun twoTrashCopiesSettleOnTheSameCanonicalCopyAndTimeInEitherArrivalOrder() = runBlocking<Unit> {
        val bytes = "old take".toByteArray()
        fun put(dir: File, name: String, mtime: Long) =
            File(RecordingFiles.trashDirectory(dir, "song").apply { mkdirs() }, name).apply { writeBytes(bytes); setLastModified(mtime) }
        val outcomes = listOf(
            listOf("1500__take.m4a" to 1_000L, "2500__take.m4a" to 2_000L),
            listOf("2500__take.m4a" to 2_000L, "1500__take.m4a" to 1_000L)
        ).map { order ->
            val dir = kotlin.io.path.createTempDirectory("rhymeai-order").toFile()
            try {
                val catalog = MemoryCatalog()
                for ((name, mtime) in order) {
                    put(dir, name, mtime)
                    RecordingTransitions.snapshot(catalog, dir, emptySet())
                }
                // And a device that sees both at once.
                val listed = RecordingTransitions.snapshot(catalog, dir, emptySet()).single()
                Triple(listed.file.name, listed.entry.uploadedAt, listed.entry.id)
            } finally {
                dir.deleteRecursively()
            }
        }
        val together = kotlin.io.path.createTempDirectory("rhymeai-order").toFile()
        try {
            put(together, "1500__take.m4a", 1_000L)
            put(together, "2500__take.m4a", 2_000L)
            val listed = RecordingTransitions.snapshot(MemoryCatalog(), together, emptySet()).single()
            val expected = Triple("2500__take.m4a", 1_000L, RecordingManifestEntry.legacyRecordingId("song", "take.m4a", BackupManifest.sha256Hex(bytes)))
            assertEquals(expected, Triple(listed.file.name, listed.entry.uploadedAt, listed.entry.id))
            assertEquals(listOf(expected, expected), outcomes)
        } finally {
            together.deleteRecursively()
        }
    }

    @Test
    fun aRenameChecksUnderTheLockThatTheFileIsStillThePlannedRecording() = runBlocking<Unit> {
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        val x = RecordingTransitions.publish(catalog, filesDir, staged("song", "x.m4a", "x take".toByteArray()), "song", "take.m4a",
            "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", 1_000L, RecordingRecord.RECORDED)!!
        val planned = RecordingTransitions.relativePath(filesDir, x)
        // Between planning and the rename, X is renamed away and Y is imported under its old name.
        RecordingTransitions.move(catalog, filesDir, x, "song", x.name, pick = { File(dir, "elsewhere.m4a") }, renamesTo = { it.name })
        RecordingTransitions.publish(catalog, filesDir, staged("song", "y.m4a", "y take".toByteArray()), "song", "take.m4a",
            "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2", 2_000L, RecordingRecord.IMPORTED)

        assertNull(RecordingTransitions.renameIfOwned(catalog, filesDir, "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", planned, File(dir, "take 2.m4a")))
        assertEquals("y take", File(dir, "take.m4a").readText())
        assertEquals(planned, catalog.records.single { it.id == "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2" }.path)
        assertFalse(File(dir, "take 2.m4a").exists())
    }

    @Test
    fun namesThatOnlySwapAreAppliedThroughParkingWithoutReplacingAnything() = runBlocking<Unit> {
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        val x = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val y = "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2"
        RecordingTransitions.publish(catalog, filesDir, staged("song", "x.m4a", "x take".toByteArray()), "song", "a.m4a", x, 1_000L, RecordingRecord.RECORDED)
        RecordingTransitions.publish(catalog, filesDir, staged("song", "y.m4a", "y take".toByteArray()), "song", "b.m4a", y, 2_000L, RecordingRecord.RECORDED)

        RecordingTransitions.applyNames(catalog, filesDir, mapOf(x to "b.m4a", y to "a.m4a"))

        assertEquals("x take", File(dir, "b.m4a").readText())
        assertEquals("y take", File(dir, "a.m4a").readText())
        assertEquals(mapOf(x to "b.m4a", y to "a.m4a"), catalog.records.associate { it.id to it.fileName })
        assertTrue(RecordingFiles.parkingRoot(filesDir).walk().none { it.isFile })
    }

    @Test
    fun noAdoptionOrReconciliationHappensWhenTheTombstonesCannotBeRead() = runBlocking<Unit> {
        File(RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }, "take.m4a").writeBytes("take".toByteArray())
        catalog.deletionsUnreadable = true
        assertFailsWith<IOException> { snapshot() }
        assertTrue(catalog.records.isEmpty())
    }

    @Test
    fun aDifferentDigestAtAKnownPathIsAdoptedAsItsOwnRecording() = runBlocking<Unit> {
        val file = File(RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }, "take.m4a")
            .apply { writeBytes("first take".toByteArray()); setLastModified(1_000L) }
        val first = snapshot().single().entry
        // Other bytes appear at the same path: the stored identity is not applied to them.
        file.writeBytes("other bytes".toByteArray())
        file.setLastModified(5_000L)
        val second = snapshot().single().entry

        assertNotEquals(first.id, second.id)
        assertEquals(RecordingManifestEntry.legacyRecordingId("song", "take.m4a", BackupManifest.sha256Hex("other bytes".toByteArray())), second.id)
        assertEquals(5_000L, second.uploadedAt)
        assertEquals(listOf(second.id), catalog.records.map { it.id })
    }

    @Test
    fun anUndoneMoveOntoDifferentBytesLeavesThemToIndependentAdoption() = runBlocking<Unit> {
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        // An interrupted move: the target never arrived and other bytes now sit at the source.
        val source = File(dir, "before.m4a").apply { writeBytes("other bytes".toByteArray()) }
        catalog.records = listOf(RecordingRecord("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", "song", "after.m4a", 1_000L,
            BackupManifest.sha256Hex("the take".toByteArray()), 8L, RecordingRecord.RECORDED,
            path = "voice-memos/song/after.m4a", pendingFrom = RecordingTransitions.relativePath(filesDir, source),
            pendingFromName = "before.m4a", pendingOp = RecordingRecord.OP_MOVE))

        val listed = snapshot().single()

        // Not moved, not given the old id: the bytes are adopted on their own.
        assertTrue(source.exists())
        assertNotEquals("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", listed.entry.id)
        assertEquals(BackupManifest.sha256Hex("other bytes".toByteArray()), listed.entry.sha256)
    }

    @Test
    fun aSameLengthRewriteWithItsOldTimeIsNotMovedByARemoteRename() = runBlocking<Unit> {
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        val file = File(dir, "take.m4a").apply { writeBytes("first take".toByteArray()); setLastModified(1_000L) }
        val id = snapshot().single().entry.id
        // Rewritten in place: same length, old modification time, record row kept.
        file.writeBytes("other take".toByteArray())
        file.setLastModified(1_000L)

        RecordingTransitions.applyNames(catalog, filesDir, mapOf(id to "renamed.m4a"))

        // Ownership needs the recorded bytes: nothing moved, and the bytes are their own recording.
        assertTrue(file.exists())
        assertFalse(File(dir, "renamed.m4a").exists())
        assertNotEquals(id, snapshot().single().entry.id)
    }
}
