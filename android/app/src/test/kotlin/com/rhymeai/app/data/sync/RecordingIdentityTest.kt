package com.rhymeai.app.data.sync

import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.recording.RecordingTransitions
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
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
    fun aStampedTimeDoesNotFollowTheFileTimeAndARenameIsMetadataOnly() = runBlocking<Unit> {
        File(RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }, "take.m4a")
            .apply { writeBytes("take".toByteArray()); setLastModified(1_000L) }
        val listed = snapshot().single()
        val stamped = listed.entry
        // A36 migration: the file is named by its id, its old name is the display name.
        assertEquals("${stamped.id}.m4a", listed.file.name)
        assertEquals("take.m4a", stamped.fileName)
        listed.file.setLastModified(99_000L)
        assertEquals(stamped, snapshot().single().entry)

        val renamed = RecordingTransitions.rename(catalog, filesDir, listed.file, "song", "Verse.m4a")!!

        val after = snapshot().single()
        assertEquals(stamped.id, after.entry.id)
        assertEquals(1_000L, after.entry.uploadedAt)
        assertEquals("Verse.m4a", after.entry.fileName)
        assertTrue(renamed.displayNameChanged)
        // Nothing on disk changed.
        assertEquals(listed.file.canonicalFile, after.file.canonicalFile)
        assertEquals(listOf("${stamped.id}.m4a"), RecordingFiles.memoDirectory(filesDir, "song").list()!!.toList())
    }

    @Test
    fun aMetadataWriteFailureFailsEachTransitionAndMovesNothing() = runBlocking<Unit> {
        val liveId = RecordingManifestEntry.newRecordingId()
        val trashId = RecordingManifestEntry.newRecordingId()
        val live = RecordingTransitions.publish(catalog, filesDir, staged("song", "a.m4a", "take".toByteArray()), "song", "take.m4a", liveId, 1L, RecordingRecord.RECORDED)!!
        val toTrash = RecordingTransitions.publish(catalog, filesDir, staged("song", "b.m4a", "old".toByteArray()), "song", "old.m4a", trashId, 1L, RecordingRecord.RECORDED)!!
        val trashed = RecordingTransitions.moveToTrash(catalog, filesDir, toTrash, "song", 1_500L)!!
        val incoming = staged("song", "incoming.m4a", "incoming".toByteArray())
        val before = catalog.records
        catalog.failWrites = true

        // Import / Drive restore.
        assertFailsWith<IOException> {
            RecordingTransitions.publish(catalog, filesDir, incoming, "song", "incoming.m4a", RecordingManifestEntry.newRecordingId(), 1L, RecordingRecord.IMPORTED)
        }
        assertFailsWith<IOException> { RecordingTransitions.rename(catalog, filesDir, live, "song", "Renamed.m4a") }
        assertFailsWith<IOException> { RecordingTransitions.restoreFromTrash(catalog, filesDir, trashed, "song") }
        assertFailsWith<IOException> { RecordingTransitions.moveToTrash(catalog, filesDir, live, "song", 2_000L) }

        assertTrue(incoming.exists())
        assertTrue(live.exists())
        assertTrue(trashed.exists())
        assertEquals(before, catalog.records)
        assertEquals(setOf(live.name), RecordingFiles.memoDirectory(filesDir, "song").list()!!.toSet())
    }

    @Test
    fun anInterruptedMoveIsFinishedOrUndoneAtTheNextLaunch() = runBlocking<Unit> {
        val a = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val b = "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2"
        val moved = RecordingFiles.trashFile(filesDir, "song", a, "a.m4a").apply { parentFile!!.mkdirs(); writeBytes("moved".toByteArray()) }
        val notMoved = RecordingFiles.memoFile(filesDir, "song", b, "b.m4a").apply { parentFile!!.mkdirs(); writeBytes("stayed".toByteArray()) }
        fun rel(f: File) = RecordingTransitions.relativePath(filesDir, f)
        catalog.records = listOf(
            // The move to Trash reached the file system before the process died.
            RecordingRecord(a, "song", "a.m4a", 1_000L, RecordingFileStore.sha256Hex(moved), 5L, RecordingRecord.RECORDED,
                path = rel(moved), trashedAt = 1_500L, pendingFrom = rel(RecordingFiles.memoFile(filesDir, "song", a, "a.m4a")),
                pendingOp = RecordingRecord.OP_MOVE),
            // This one did not: the record goes back to its live path, out of Trash.
            RecordingRecord(b, "song", "b.m4a", 2_000L, RecordingFileStore.sha256Hex(notMoved), 6L, RecordingRecord.RECORDED,
                path = rel(RecordingFiles.trashFile(filesDir, "song", b, "b.m4a")), trashedAt = 2_500L, pendingFrom = rel(notMoved),
                pendingOp = RecordingRecord.OP_MOVE),
            // A publish whose staged file is gone leaves no record.
            RecordingRecord("b2a1c3d4-e5f6-4789-8abc-def012345678", "song", "lost.m4a", 3_000L, "a".repeat(64), 4L,
                RecordingRecord.RESTORED, path = "voice-memos/song/b2a1c3d4-e5f6-4789-8abc-def012345678.m4a",
                pendingFrom = "voice-memos-staging/song/x.m4a", pendingOp = RecordingRecord.OP_PUBLISH)
        )

        RecordingTransitions.reconcile(catalog, filesDir)

        val byId = catalog.records.associateBy { it.id }
        // The publish whose bytes are at neither end is kept, unresolved, with its id and time (T3.5).
        assertEquals(setOf(a, b, "b2a1c3d4-e5f6-4789-8abc-def012345678"), byId.keys)
        assertEquals(RecordingRecord.OP_PUBLISH, byId.getValue("b2a1c3d4-e5f6-4789-8abc-def012345678").pendingOp)
        assertEquals(listOf("song/lost.m4a"), RecordingTransitions.unresolved)
        assertEquals(rel(moved), byId.getValue(a).path)
        assertEquals(1_500L, byId.getValue(a).trashedAt)
        assertNull(byId.getValue(a).pendingOp)
        val undone = byId.getValue(b)
        assertEquals(rel(notMoved), undone.path)
        assertNull(undone.trashedAt)
        assertEquals(2_000L, undone.uploadedAt)
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
    fun aMigrationInterruptedAfterTheFileMovedIsFinishedWithTheSameIdAndName() = runBlocking<Unit> {
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        File(dir, "take.m4a").apply { writeBytes("take".toByteArray()); setLastModified(1_000L) }
        val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", BackupManifest.sha256Hex("take".toByteArray()))
        // Write 1 is the journaled intent; write 2, clearing it, fails after the file moved.
        catalog.failOnWrite = 2
        assertFailsWith<IOException> { RecordingTransitions.migrate(catalog, filesDir) }
        assertEquals(listOf("$id.m4a"), dir.list()!!.toList())
        assertEquals(RecordingRecord.OP_MOVE, catalog.records.single().pendingOp)

        // The next launch reconciles from the journal and finds the same recording.
        assertEquals(emptyList(), RecordingTransitions.migrate(catalog, filesDir))
        val record = catalog.records.single()
        assertEquals(id, record.id)
        assertEquals("take.m4a", record.displayName)
        assertEquals(1_000L, record.uploadedAt)
        assertNull(record.pendingOp)
        // And migrating again changes nothing.
        val settled = catalog.records
        RecordingTransitions.migrate(catalog, filesDir)
        assertEquals(settled, catalog.records)
    }

    @Test
    fun migrationNamesLiveAndTrashFilesByIdAndLeavesATakenIdNameAlone() = runBlocking<Unit> {
        val live = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        val trash = RecordingFiles.trashDirectory(filesDir, "song").apply { mkdirs() }
        File(live, "Chorus idea.m4a").apply { writeBytes("chorus".toByteArray()); setLastModified(1_000L) }
        File(trash, "1500__verse.m4a").apply { writeBytes("verse".toByteArray()); setLastModified(900L) }
        val blocked = File(live, "blocked.m4a").apply { writeBytes("blocked".toByteArray()) }
        val blockedId = RecordingManifestEntry.legacyRecordingId("song", "blocked.m4a", BackupManifest.sha256Hex("blocked".toByteArray()))
        // Something else already sits at the blocked file's id name.
        val squatter = File(live, "$blockedId.m4a").apply { writeBytes("squatter".toByteArray()) }

        val left = RecordingTransitions.migrate(catalog, filesDir)

        assertEquals(listOf(blocked.canonicalFile), left.map { it.canonicalFile })
        assertEquals("blocked", blocked.readText())
        assertEquals("squatter", squatter.readText())
        val byName = catalog.records.associateBy { it.displayName }
        val chorus = byName.getValue("Chorus idea.m4a")
        assertEquals("voice-memos/song/${chorus.id}.m4a", chorus.path)
        val verse = byName.getValue("verse.m4a")
        assertEquals("voice-memos-trash/song/${verse.id}.m4a", verse.path)
        assertEquals(1_500L, verse.trashedAt)
        assertEquals(900L, verse.uploadedAt)
        // Nothing was deleted: every byte is still on disk.
        val all = filesDir.walk().filter { it.isFile }.map { it.readText() }.toSet()
        assertTrue(all.containsAll(setOf("chorus", "verse", "blocked", "squatter")))
    }

    @Test
    fun maximumLengthDisplayNamesStayValidThroughSnapshotAndExport() = runBlocking<Unit> {
        val name = "\u00e9".repeat(118) + ".m4a" // the 240-byte limit
        fun bytesOf(s: String) = s.toByteArray(Charsets.UTF_8).size
        val first = RecordingTransitions.publish(catalog, filesDir, staged("song", "a.m4a", "first".toByteArray()), "song", name,
            RecordingManifestEntry.newRecordingId(), 1_000L, RecordingRecord.RECORDED)!!
        val second = RecordingTransitions.publish(catalog, filesDir, staged("song", "b.m4a", "second".toByteArray()), "song", name,
            RecordingManifestEntry.newRecordingId(), 2_000L, RecordingRecord.RECORDED)!!
        assertNotEquals(first.name, second.name)
        val listed = snapshot()
        assertEquals(listOf(name, name), listed.map { it.entry.fileName })
        listed.forEach { it.entry.validate() }

        // Export tells the two apart with a bounded " 2" and reads back both ids with their display names.
        val exportNames = BackupArchive.exportNames(listed.map { it.entry })
        assertEquals(2, exportNames.values.toSet().size)
        assertTrue(exportNames.values.all { bytesOf(it) <= 240 }, exportNames.toString())
        assertTrue(exportNames.values.any { it.endsWith(" 2.m4a") })
        val archive = File(filesDir, "export.zip")
        archive.outputStream().use { BackupArchive.write(it, SyncBlob(), listed, 3_000L, "device") }
        val read = BackupArchive.read(archive)
        assertEquals(listed.associate { it.entry.id to name }, read.manifest.recordings.associate { it.id to it.fileName })
        assertEquals(setOf("first", "second"), read.recordings.values.map { String(it) }.toSet())
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
                assertContentEquals(bytes, RecordingFiles.quarantineDirectory(dir, "song").walk().single { it.isFile }.readBytes())
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
            val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", BackupManifest.sha256Hex(bytes))
            val expected = Triple("$id.m4a", 1_000L, id)
            assertEquals(expected, Triple(listed.file.name, listed.entry.uploadedAt, listed.entry.id))
            assertEquals(listOf(expected, expected), outcomes)
        } finally {
            together.deleteRecursively()
        }
    }

    @Test
    fun noAdoptionOrReconciliationHappensWhenTheTombstonesCannotBeRead() = runBlocking<Unit> {
        File(RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }, "take.m4a").writeBytes("take".toByteArray())
        catalog.deletionsUnreadable = true
        assertFailsWith<IOException> { snapshot() }
        assertTrue(catalog.records.isEmpty())
    }

    @Test
    fun differentBytesUnderAnIdNameAreAdoptedAsTheirOwnRecording() = runBlocking<Unit> {
        File(RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }, "take.m4a")
            .apply { writeBytes("first take".toByteArray()); setLastModified(1_000L) }
        val firstListed = snapshot().single()
        val first = firstListed.entry
        // Other bytes appear under the first recording's id name: its identity is not applied to them.
        firstListed.file.writeBytes("other bytes".toByteArray())
        firstListed.file.setLastModified(5_000L)
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
            path = "voice-memos-trash/song/0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b.m4a", trashedAt = 1_500L,
            pendingFrom = RecordingTransitions.relativePath(filesDir, source), pendingOp = RecordingRecord.OP_MOVE))

        val listed = snapshot().single()

        // Not moved, not given the old id: the bytes are adopted on their own.
        assertEquals("other bytes", listed.file.readText())
        assertNotEquals("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", listed.entry.id)
        assertEquals(BackupManifest.sha256Hex("other bytes".toByteArray()), listed.entry.sha256)
    }

    @Test
    fun wholeSongCleanupDeletesOnlyRecordingsAWinningTombstoneCovers() = runBlocking<Unit> {
        val covered = RecordingTransitions.publish(catalog, filesDir, staged("song", "a.m4a", "old take".toByteArray()), "song", "old.m4a",
            RecordingManifestEntry.newRecordingId(), 1_000L, RecordingRecord.RECORDED)!!
        // A take that finished after the deletion, and a file dropped in later.
        val later = RecordingTransitions.publish(catalog, filesDir, staged("song", "b.m4a", "new take".toByteArray()), "song", "new.m4a",
            RecordingManifestEntry.newRecordingId(), 9_000L, RecordingRecord.RECORDED)!!
        File(RecordingFiles.memoDirectory(filesDir, "song"), "dropped.m4a").apply { writeBytes("dropped".toByteArray()); setLastModified(9_500L) }

        val done = RecordingTransitions.cleanUpDeletedSong(catalog, filesDir, "song", listOf(SyncDeletion("song", deletedAt = 5_000L)))

        assertFalse(done)
        // A real time older than the deletion: deleted.
        assertFalse(covered.exists())
        // A real time newer than the deletion: kept in place.
        assertEquals("new take", later.readText())
        val left = RecordingFiles.memoDirectory(filesDir, "song").listFiles()!!.map { it.readText() }.toSet()
        assertEquals(setOf("new take"), left)
        // A dropped-in file's time is a repair, which the deletion beats (A41): set aside, never deleted.
        assertEquals(listOf("dropped"), RecordingFiles.quarantineDirectory(filesDir, "song").walk().filter { it.isFile }.map { it.readText() }.toList())
        assertEquals(1, catalog.records.size)
    }

    @Test
    fun aRecordWhoseMigrationTargetIsTakenKeepsItsIdentityUntilTheMoveCanHappen() = runBlocking<Unit> {
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        val r = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val take = File(dir, "take.m4a").apply { writeBytes("the take".toByteArray()) }
        val record = RecordingRecord(r, "song", "take.m4a", 1_000L, BackupManifest.sha256Hex(take.readBytes()), take.length(),
            RecordingRecord.RECORDED, path = "voice-memos/song/take.m4a")
        catalog.records = listOf(record)
        // Other bytes already sit at R's id name.
        File(dir, "$r.m4a").writeBytes("squatter".toByteArray())

        val left = RecordingTransitions.migrate(catalog, filesDir)

        assertEquals(listOf(take.canonicalFile), left.map { it.canonicalFile })
        assertEquals(record, catalog.records.single { it.id == r })
        assertTrue(take.exists())
        // The squatter was adopted on its own and moved off R's name, so the next run moves R.
        assertEquals(emptyList(), RecordingTransitions.migrate(catalog, filesDir))
        val moved = catalog.records.single { it.id == r }
        assertEquals(Triple("take.m4a", 1_000L, "voice-memos/song/$r.m4a"), Triple(moved.displayName, moved.uploadedAt, moved.path))
        assertEquals("the take", File(dir, "$r.m4a").readText())
        assertEquals(setOf("the take", "squatter"), dir.listFiles()!!.map { it.readText() }.toSet())
    }

    @Test
    fun preA36QuarantineCopiesMoveToTheirIdNamesAndNothingIsReplaced() = runBlocking<Unit> {
        val q = RecordingFiles.quarantineDirectory(filesDir, "song").apply { mkdirs() }
        File(q, "1700__take.m4a").writeBytes("kept copy".toByteArray())
        val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", BackupManifest.sha256Hex("kept copy".toByteArray()))

        RecordingTransitions.migrate(catalog, filesDir)
        RecordingTransitions.migrate(catalog, filesDir)

        assertEquals(listOf("1700/$id.m4a"), q.walk().filter { it.isFile }.map { it.relativeTo(q).path }.toList())
        assertEquals("kept copy", File(q, "1700/$id.m4a").readText())
    }

    @Test
    fun nothingMigratesQuarantineIncludedWhenTheTombstonesCannotBeRead() = runBlocking<Unit> {
        val q = RecordingFiles.quarantineDirectory(filesDir, "song").apply { mkdirs() }
        val kept = File(q, "1700__take.m4a").apply { writeBytes("kept copy".toByteArray()) }
        val live = File(RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }, "take.m4a").apply { writeBytes("live".toByteArray()) }
        catalog.deletionsUnreadable = true

        assertFailsWith<IOException> { RecordingTransitions.migrate(catalog, filesDir) }

        assertTrue(kept.exists())
        assertTrue(live.exists())
        assertEquals(listOf("1700__take.m4a"), q.list()!!.toList())
    }

    @Test
    fun aQuarantineMigrationKilledAfterItsClaimIsFinishedFromItsJournal() = runBlocking<Unit> {
        val q = RecordingFiles.quarantineDirectory(filesDir, "song").apply { mkdirs() }
        val bytes = "kept copy".toByteArray()
        val source = File(q, "1700__take.m4a").apply { writeBytes(bytes) }
        val sha = BackupManifest.sha256Hex(bytes)
        val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", sha)
        // The state a kill leaves after the journal and the exclusive claim, before the rename.
        val claim = java.util.UUID.randomUUID().toString()
        val target = File(q, "1700/$id.m4a").apply { parentFile!!.mkdirs(); writeText("rhymeai-claim\n$claim\n") }
        val journals = RecordingFiles.journalRoot(filesDir).apply { mkdirs() }
        File(journals, "$claim.move").writeText(listOf("rhymeai-move 1", "kind=quarantine", "id=$id",
            "source=${RecordingTransitions.relativePath(filesDir, source)}", "target=${RecordingTransitions.relativePath(filesDir, target)}",
            "sha256=$sha", "length=${bytes.size}", "claim=$claim").joinToString("\n", postfix = "\n"))

        assertEquals(emptyList(), RecordingTransitions.migrate(catalog, filesDir))

        assertContentEquals(bytes, target.readBytes())
        assertFalse(source.exists())
        assertEquals(listOf("1700/$id.m4a"), q.walk().filter { it.isFile }.map { it.relativeTo(q).path }.toList())
        assertTrue(journals.list().orEmpty().isEmpty())
    }

    @Test
    fun anEmptyFileWhoseOwnershipCannotBeShownIsNeverRemoved() = runBlocking<Unit> {
        val q = RecordingFiles.quarantineDirectory(filesDir, "song").apply { mkdirs() }
        val bytes = "kept copy".toByteArray()
        val source = File(q, "1700__take.m4a").apply { writeBytes(bytes) }
        val sha = BackupManifest.sha256Hex(bytes)
        val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", sha)
        // An empty file at the destination and an older build's journal that does not name a claim.
        val empty = File(q, "1700/$id.m4a").apply { parentFile!!.mkdirs(); createNewFile() }
        File(q, "1700__take.m4a.migrate").writeText("1700__take.m4a\n1700/$id.m4a\n$id\n$sha\n${bytes.size}\n")

        val left = RecordingTransitions.migrate(catalog, filesDir)

        // Both survive (T1.8): the original stays where it was and is reported.
        assertEquals(listOf(source.canonicalFile), left.map { it.canonicalFile })
        assertTrue(empty.exists() && empty.length() == 0L)
        assertContentEquals(bytes, source.readBytes())
    }

    @Test
    fun aQuarantineDestinationHoldingOtherBytesKeepsBothFiles() = runBlocking<Unit> {
        val q = RecordingFiles.quarantineDirectory(filesDir, "song").apply { mkdirs() }
        val bytes = "kept copy".toByteArray()
        val source = File(q, "1700__take.m4a").apply { writeBytes(bytes) }
        val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", BackupManifest.sha256Hex(bytes))
        val other = File(q, "1700/$id.m4a").apply { parentFile!!.mkdirs(); writeText("other bytes") }

        val left = RecordingTransitions.migrate(catalog, filesDir)

        assertEquals(listOf(source.canonicalFile), left.map { it.canonicalFile })
        assertEquals("other bytes", other.readText())
        assertContentEquals(bytes, source.readBytes())
    }

    @Test
    fun unreadableTombstonesStopReconciliationAndEveryByteMove() = runBlocking<Unit> {
        // A pending move, a legacy file to migrate, a parked file and a quarantine copy to migrate.
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val moved = RecordingFiles.trashFile(filesDir, "song", id, "a.m4a").apply { parentFile!!.mkdirs(); writeText("moved") }
        catalog.records = listOf(RecordingRecord(id, "song", "a.m4a", 1L, BackupManifest.sha256Hex("moved".toByteArray()), 5L,
            RecordingRecord.RECORDED, path = RecordingTransitions.relativePath(filesDir, moved), trashedAt = 2L,
            pendingFrom = "voice-memos/song/$id.m4a", pendingOp = RecordingRecord.OP_MOVE))
        File(dir, "take.m4a").writeText("legacy")
        File(RecordingFiles.parkingRoot(filesDir), "song").apply { mkdirs() }.let { File(it, "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2.m4a").writeText("parked") }
        File(RecordingFiles.quarantineDirectory(filesDir, "song").apply { mkdirs() }, "1700__old.m4a").writeText("old")
        fun state() = filesDir.walk().map { Triple(it.relativeTo(filesDir).path, it.length(), it.lastModified()) }.toSet()
        val before = state()
        val records = catalog.records
        catalog.deletionsUnreadable = true

        assertFailsWith<IOException> { RecordingTransitions.migrate(catalog, filesDir) }
        assertFailsWith<IOException> { RecordingTransitions.reconcile(catalog, filesDir) }
        assertFailsWith<IOException> { RecordingTransitions.migrateStaging(catalog, filesDir, emptySet()) }

        assertEquals(before, state())
        assertEquals(records, catalog.records)
    }

    @Test
    fun parkedRecordingsFromBuildsBeforeA36ReturnToTheirSong() = runBlocking<Unit> {
        val id = "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2"
        val parked = File(RecordingFiles.parkingRoot(filesDir), "song").apply { mkdirs() }.let { File(it, "$id.m4a").apply { writeText("parked take") } }

        assertEquals(emptyList(), RecordingTransitions.migrate(catalog, filesDir))

        assertFalse(parked.exists())
        val listed = snapshot().single()
        assertEquals(id, listed.entry.id)
        assertEquals("parked take", listed.file.readText())
    }
    private suspend fun trashedTake(id: String, trashedAt: Long): File {
        val live = RecordingTransitions.publish(catalog, filesDir, staged("song", "a.m4a", "take".toByteArray()), "song", "take.m4a", id, 1_000L, RecordingRecord.RECORDED)!!
        return RecordingTransitions.moveToTrash(catalog, filesDir, live, "song", trashedAt)!!
    }

    @Test
    fun anExpirySelectionARestoreOvertookDeletesNothingAndWritesNoTombstone() = runBlocking<Unit> {
        // T1.4/T4.1: the expiry pass selected the Trash copy; the user restores it before the deletion runs.
        val id = RecordingManifestEntry.newRecordingId()
        val selected = trashedTake(id, 2_000L)
        val now = 2_000L + TRASH_RETENTION_MILLIS + 1
        val restored = RecordingTransitions.restoreFromTrash(catalog, filesDir, selected, "song")!!
        val tombstones = mutableListOf<String>()

        RecordingTransitions.deleteFromTrash(catalog, filesDir, selected, "song", expiresBy = now) { r, _ -> tombstones += r.id }

        assertTrue(tombstones.isEmpty())
        assertEquals("take", restored.readText())
        assertNull(catalog.records.single().trashedAt)
        // A deletion handed the live file itself is refused: only a recording in Trash is deleted.
        assertFalse(RecordingTransitions.deleteFromTrash(catalog, filesDir, restored, "song", expiresBy = null) { r, _ -> tombstones += r.id })
        assertTrue(tombstones.isEmpty())
        assertEquals("take", restored.readText())

        // Trashed again just now: the stale selection's deadline no longer applies.
        val again = RecordingTransitions.moveToTrash(catalog, filesDir, restored, "song", now)!!
        assertFalse(RecordingTransitions.deleteFromTrash(catalog, filesDir, again, "song", expiresBy = now) { r, _ -> tombstones += r.id })
        assertTrue(tombstones.isEmpty())
        assertEquals("take", again.readText())
    }

    @Test
    fun aRestoreDuringAnExpiryDeletionWaitsUntilTheTombstoneAndUnlinkAreDone() = runBlocking<Unit> {
        val id = RecordingManifestEntry.newRecordingId()
        val selected = trashedTake(id, 2_000L)
        val now = 2_000L + TRASH_RETENTION_MILLIS + 1
        val tombstones = mutableListOf<String>()
        var restore: Deferred<Result<File?>>? = null
        val scope = this
        // Between the tombstone and the unlink, a restore starts: it must wait for the whole operation.
        RecordingTransitions.beforeBytesMove = {
            restore = scope.async(Dispatchers.Default) { runCatching { RecordingTransitions.restoreFromTrash(catalog, filesDir, selected, "song") } }
            delay(200)
            assertFalse(restore!!.isCompleted)
        }
        try {
            assertTrue(RecordingTransitions.deleteFromTrash(catalog, filesDir, selected, "song", expiresBy = now) { r, _ -> tombstones += r.id })
        } finally {
            RecordingTransitions.beforeBytesMove = null
        }

        assertNull(restore!!.await().getOrNull())
        assertEquals(listOf(id), tombstones)
        assertFalse(selected.exists())
        assertTrue(catalog.records.isEmpty())
        assertTrue(RecordingFiles.memoDirectory(filesDir, "song").list().orEmpty().isEmpty())
    }

    @Test
    fun anEstablishedRealTimeIsNeverLoweredByAnOlderCopysFileTime() {
        establishedRealTimeStays(RecordingRecord.RECORDED)
        filesDir.listFiles()!!.forEach { it.deleteRecursively() }
        // The audited case: a stamped ADOPTED row with a real time (written before repairs were flagged).
        establishedRealTimeStays(RecordingRecord.ADOPTED)
    }

    private fun establishedRealTimeStays(origin: String) = runBlocking<Unit> {
        // T2.24: a copy of the same recording appears with an older file time.
        val bytes = "take".toByteArray()
        val sha = BackupManifest.sha256Hex(bytes)
        val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", sha)
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        val file = File(dir, RecordingFiles.idFileName(id, "take.m4a")).apply { writeBytes(bytes) }
        fun record(time: Long, repaired: Boolean) = RecordingRecord(id, "song", "take.m4a", time, sha, bytes.size.toLong(),
            origin, path = RecordingTransitions.relativePath(filesDir, file), precedenceRepaired = repaired)
        catalog.records = listOf(record(9_000L, repaired = false))
        File(RecordingFiles.trashDirectory(filesDir, "song").apply { mkdirs() }, "1500__take.m4a").apply { writeBytes(bytes); setLastModified(1_000L) }

        assertEquals(9_000L, snapshot().single { it.entry.id == id }.entry.uploadedAt)
        assertEquals(9_000L, catalog.records.single().uploadedAt)
        assertFalse(catalog.records.single().precedenceRepaired)

        // A repair, by contrast, settles on the smaller time.
        catalog.records = listOf(record(9_000L, repaired = true))
        File(RecordingFiles.trashDirectory(filesDir, "song"), "1600__take.m4a").apply { writeBytes(bytes); setLastModified(1_000L) }
        assertEquals(1_000L, snapshot().single { it.entry.id == id }.entry.uploadedAt)
    }

    @Test
    fun aHistoricalWaitingMarkerBecomesATakeMarkerAndTheTakeItsIdName() = runBlocking<Unit> {
        // T3.16: the 149676c `.waiting` format, "<id>\n<finish time>\n".
        val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val take = staged("song", "1700000000000.m4a", "finished take".toByteArray())
        val waiting = File(take.parentFile, "1700000000000.m4a.waiting").apply { writeText("$id\n5000\n") }

        assertEquals(emptyList(), RecordingTransitions.migrateStaging(catalog, filesDir, emptySet()))

        val named = File(take.parentFile, "$id.m4a")
        assertFalse(waiting.exists())
        assertFalse(take.exists())
        assertEquals("finished take", named.readText())
        assertEquals("$id\nfinished\n5000\n", File(take.parentFile, "$id.m4a.take").readText())
    }

    @Test
    fun anUnreadableWaitingMarkerLeavesItsTakeInPlaceAndReportsIt() = runBlocking<Unit> {
        val take = staged("song", "1700000000000.m4a", "finished take".toByteArray())
        File(take.parentFile, "1700000000000.m4a.waiting").writeText("not an id\n")

        assertEquals(listOf(take.canonicalFile), RecordingTransitions.migrateStaging(catalog, filesDir, emptySet()).map { it.canonicalFile })
        assertEquals("finished take", take.readText())
    }

    @Test
    fun anImportNoProcessOwnsIsSetAsideAndAnUnmarkedFileIsReported() = runBlocking<Unit> {
        val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val import = staged("song", "$id.m4a", "imported".toByteArray())
        val marker = File(import.parentFile, "$id.m4a.import").apply { writeText("") }
        val stray = staged("song", "stray.m4a", "unknown".toByteArray())
        val owned = staged("song", "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2.m4a", "in progress".toByteArray())
        File(owned.parentFile, owned.name + ".import").writeText("")

        val left = RecordingTransitions.migrateStaging(catalog, filesDir, setOf(owned))

        assertEquals(listOf(stray.canonicalFile), left.map { it.canonicalFile })
        assertFalse(import.exists())
        assertFalse(marker.exists())
        val q = RecordingFiles.quarantineDirectory(filesDir, "song")
        assertEquals(listOf("$id.m4a" to "imported"), q.walk().filter { it.isFile }.map { it.name to it.readText() }.toList())
        assertEquals("unknown", stray.readText())
        assertEquals("in progress", owned.readText())
    }
    /** A folder the encrypted-sync build (c57aa87) left: its binary journal and copies of the originals it replaced. */
    private fun historicalStage(complete: Boolean, vararg entries: Triple<String, String, ByteArray?>): File {
        val stage = File(filesDir, ".recording-restore-1234").apply { mkdirs() }
        java.io.DataOutputStream(File(stage, "restore-journal").outputStream()).use { data ->
            data.writeInt(0x5248594D)
            data.writeInt(1)
            data.writeInt(entries.size)
            entries.forEachIndexed { index, (projectId, name, original) ->
                data.writeInt(index)
                data.writeUTF(projectId)
                data.writeUTF(name)
                data.writeBoolean(original != null)
                original?.let { File(stage, "backup-$index.tmp").writeBytes(it) }
            }
        }
        if (complete) File(stage, "restore-complete").writeBytes(byteArrayOf(1))
        return stage
    }

    private fun historicalRestoreKeepsEveryOriginal(complete: Boolean) = runBlocking<Unit> {
        // T1.35/T3.49/T3.50: the restore replaced "take.m4a" (original "mine"), and "same.m4a" still holds its original.
        val dir = RecordingFiles.memoDirectory(filesDir, "song").apply { mkdirs() }
        File(dir, "take.m4a").writeText("restored")
        File(dir, "take (original).m4a").writeText("an older preserved copy")
        File(dir, "same.m4a").writeText("unchanged")
        val stage = historicalStage(complete,
            Triple("song", "take.m4a", "mine".toByteArray()),
            Triple("song", "same.m4a", "unchanged".toByteArray()),
            Triple("song", "new.m4a", null))

        assertEquals(emptyList(), RecordingFileStore.recoverInterruptedRestores(filesDir, onlyHistorical = true))

        assertFalse(stage.exists())
        assertEquals("restored", File(dir, "take.m4a").readText())
        assertEquals("an older preserved copy", File(dir, "take (original).m4a").readText())
        assertEquals("mine", File(dir, "take (original 2).m4a").readText())
        assertEquals("unchanged", File(dir, "same.m4a").readText())
        assertEquals(setOf("take.m4a", "take (original).m4a", "take (original 2).m4a", "same.m4a"), dir.list()!!.toSet())
        assertTrue(RecordingFiles.journalRoot(filesDir).list().orEmpty().isEmpty())
    }

    @Test
    fun anIncompleteHistoricalRestorePreservesEveryReplacedOriginalBeforeItsFolderGoes() = historicalRestoreKeepsEveryOriginal(complete = false)

    @Test
    fun aCompletedHistoricalRestorePreservesEveryReplacedOriginalBeforeItsFolderGoes() = historicalRestoreKeepsEveryOriginal(complete = true)

    @Test
    fun anUnreadableHistoricalRestoreJournalKeepsItsFolderUntouched() = runBlocking<Unit> {
        val stage = File(filesDir, ".recording-restore-5678").apply { mkdirs() }
        File(stage, "restore-journal").writeText("not a journal")
        File(stage, "backup-0.tmp").writeText("mine")

        assertEquals(listOf(stage.canonicalFile), RecordingFileStore.recoverInterruptedRestores(filesDir, onlyHistorical = true).map { it.canonicalFile })
        assertEquals("mine", File(stage, "backup-0.tmp").readText())
        // A folder of this build (no journal) is left to Restore when only historical ones are recovered.
        val current = File(filesDir, ".recording-restore-9999").apply { mkdirs() }.also { File(it, "recording-0.tmp").writeText("download") }
        RecordingFileStore.recoverInterruptedRestores(filesDir, onlyHistorical = true)
        assertTrue(File(current, "recording-0.tmp").exists())
    }
    private fun tree(root: File) = root.walk().filter { it.isFile }.associate { it.relativeTo(filesDir).path to it.readBytes().toList() }

    @Test
    fun aHistoricalQuarantineJournalWhoseSavedIdDoesNotNameItsTargetHoldsItsFolder() = runBlocking<Unit> {
        // T3.18: line 3 of the old quarantine journal is the id; here it names other bytes.
        val q = RecordingFiles.quarantineDirectory(filesDir, "song").apply { mkdirs() }
        val bytes = "kept copy".toByteArray()
        val sha = BackupManifest.sha256Hex(bytes)
        val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", sha)
        File(q, "1700__take.m4a").writeBytes(bytes)
        File(q, "1800__other.m4a").writeText("another copy")
        File(q, "1700__take.m4a.migrate").writeText("1700__take.m4a\n1700/$id.m4a\n0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b\n$sha\n${bytes.size}\n")
        val before = tree(filesDir)

        val left = RecordingTransitions.migrate(catalog, filesDir)

        // Nothing in the folder moved, the journal stays, and the files are reported.
        assertEquals(before, tree(filesDir))
        assertEquals(setOf("1700__take.m4a", "1800__other.m4a"), left.map { it.name }.toSet())
        assertTrue(RecordingTransitions.unresolved.any { "1700__take.m4a.migrate" in it })
        assertTrue(catalog.records.isEmpty())
    }

    @Test
    fun aMalformedHistoricalStagingJournalSuspendsEveryMoveInItsFolder() = runBlocking<Unit> {
        // T3.17: a staging journal without its length; the take and its marker must stay as they are.
        val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
        val take = staged("song", "1700000000000.m4a", "finished take".toByteArray())
        File(take.parentFile, "1700000000000.m4a.take").writeText("$id\nfinished\n5000\n")
        File(take.parentFile, "$id.m4a.migrate").writeText("1700000000000.m4a\n$id.m4a\n${BackupManifest.sha256Hex(take.readBytes())}\n")
        val before = tree(filesDir)

        val left = RecordingTransitions.migrateStaging(catalog, filesDir, emptySet())

        assertEquals(before, tree(filesDir))
        assertEquals(listOf(take.canonicalFile), left.map { it.canonicalFile })
        assertTrue(catalog.records.isEmpty())
    }
    @Test
    fun wholeSongCleanupDeletesNothingWhoseBytesChangedWhilePlaybackStopped() = runBlocking<Unit> {
        // T1.5: the bytes are verified after the stop hook, immediately before the unlink.
        val id = RecordingManifestEntry.newRecordingId()
        val file = RecordingTransitions.publish(catalog, filesDir, staged("song", "a.m4a", "take".toByteArray()), "song", "take.m4a", id, 1_000L, RecordingRecord.RECORDED)!!
        RecordingTransitions.beforeBytesMove = { file.writeText("rewritten while playback stopped") }
        try {
            assertFalse(RecordingTransitions.cleanUpDeletedSong(catalog, filesDir, "song", listOf(SyncDeletion("song", deletedAt = 5_000L))))
        } finally {
            RecordingTransitions.beforeBytesMove = null
        }
        assertEquals("rewritten while playback stopped", file.readText())
        assertEquals(listOf(id), catalog.records.map { it.id })
    }
    @Test
    fun anUnreadableJournalIsNeverTreatedAsEmptyAndNothingItNamesIsSwept() = runBlocking<Unit> {
        // iOS final review item 5: a journal that cannot be read keeps its claim, source and itself.
        val q = RecordingFiles.quarantineDirectory(filesDir, "song").apply { mkdirs() }
        val bytes = "kept copy".toByteArray()
        val source = File(q, "1700__take.m4a").apply { writeBytes(bytes) }
        val sha = BackupManifest.sha256Hex(bytes)
        val id = RecordingManifestEntry.legacyRecordingId("song", "take.m4a", sha)
        val claim = java.util.UUID.randomUUID().toString()
        val target = File(q, "1700/$id.m4a").apply { parentFile!!.mkdirs(); writeText("rhymeai-claim\n$claim\n") }
        val journal = File(RecordingFiles.journalRoot(filesDir).apply { mkdirs() }, "$claim.move").apply {
            writeText(listOf("rhymeai-move 1", "kind=quarantine", "id=$id",
                "source=${RecordingTransitions.relativePath(filesDir, source)}", "target=${RecordingTransitions.relativePath(filesDir, target)}",
                "sha256=$sha", "length=${bytes.size}", "claim=$claim").joinToString("\n", postfix = "\n"))
        }
        // An older build's staging journal beside a take, unreadable too.
        val take = staged("song", "1700000000000.m4a", "finished take".toByteArray())
        File(take.parentFile, "1700000000000.m4a.take").writeText("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b\nfinished\n5000\n")
        val oldJournal = File(take.parentFile, "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b.m4a.migrate").apply { writeText("x") }
        journal.setReadable(false)
        oldJournal.setReadable(false)
        try {
            org.junit.Assume.assumeFalse("permissions are not enforced here", journal.canRead() || oldJournal.canRead())
            val before = filesDir.walk().filter { it.isFile }.map { it.relativeTo(filesDir).path to it.length() }.toSet()

            RecordingTransitions.migrate(catalog, filesDir)
            RecordingTransitions.migrateStaging(catalog, filesDir, emptySet())

            assertEquals(before, filesDir.walk().filter { it.isFile }.map { it.relativeTo(filesDir).path to it.length() }.toSet())
            assertEquals("rhymeai-claim\n$claim\n", target.readText())
            assertContentEquals(bytes, source.readBytes())
            assertEquals("finished take", take.readText())
        } finally {
            journal.setReadable(true)
            oldJournal.setReadable(true)
        }
    }
}
