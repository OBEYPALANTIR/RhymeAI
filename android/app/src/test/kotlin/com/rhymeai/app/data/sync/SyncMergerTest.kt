package com.rhymeai.app.data.sync

import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SyncMergerTest {

    private fun project(id: String, lyrics: String, updatedAt: Long): SongProject =
        SongProject(id = id, title = id, lyrics = lyrics, theme = "", updatedAt = updatedAt)

    private fun trashed(id: String, deletedAt: Long, lyrics: String = ""): TrashedSongProject =
        TrashedSongProject(
            project = project(id, lyrics, updatedAt = deletedAt - 1L),
            deletedAt = deletedAt
        )

    @Test
    fun lastWriterWinsKeepsHigherUpdatedAtVersion() {
        val local = SyncBlob(projects = listOf(project("a", "old lyrics", updatedAt = 100L)))
        val remote = SyncBlob(projects = listOf(project("a", "new lyrics", updatedAt = 200L)))

        val merged = SyncMerger.merge(local, remote)

        val a = merged.projects.first { it.id == "a" }
        assertEquals("new lyrics", a.lyrics)
        assertEquals(200L, a.updatedAt)
    }

    @Test
    fun localWinsWhenItHasNewerTimestamp() {
        val local = SyncBlob(projects = listOf(project("a", "newer local", updatedAt = 300L)))
        val remote = SyncBlob(projects = listOf(project("a", "stale remote", updatedAt = 100L)))

        val merged = SyncMerger.merge(local, remote)

        assertEquals("newer local", merged.projects.first { it.id == "a" }.lyrics)
    }

    @Test
    fun mergeUnionsDistinctProjects() {
        val local = SyncBlob(projects = listOf(project("a", "A", 100L), project("b", "B", 150L)))
        val remote = SyncBlob(projects = listOf(project("c", "C", 200L)))

        val merged = SyncMerger.merge(local, remote)

        assertEquals(
            setOf("a", "b", "c"),
            merged.projects.map { it.id }.toSet()
        )
    }

    @Test
    fun trashedProjectsAreRemovedFromActiveList() {
        val local = SyncBlob(
            projects = listOf(project("a", "A", 100L), project("b", "B", 100L)),
            trashed = emptyList()
        )
        val remote = SyncBlob(
            projects = emptyList(),
            trashed = listOf(trashed("a", deletedAt = 200L))
        )

        val merged = SyncMerger.merge(local, remote)

        assertFalse(merged.projects.any { it.id == "a" }, "trashed remote entry must remove a from active")
        assertTrue(merged.projects.any { it.id == "b" }, "b is untouched")
        assertTrue(merged.trashed.any { it.project.id == "a" })
    }

    @Test
    fun restoredProjectNewerThanTrashRemainsActive() {
        val local = SyncBlob(
            projects = listOf(project("a", "restored lyrics", updatedAt = 300L)),
            trashed = emptyList()
        )
        val remote = SyncBlob(
            projects = emptyList(),
            trashed = listOf(trashed("a", deletedAt = 200L, lyrics = "deleted lyrics"))
        )

        val merged = SyncMerger.merge(local, remote)

        assertEquals(listOf("a"), merged.projects.map { it.id })
        assertEquals("restored lyrics", merged.projects.first().lyrics)
        assertFalse(merged.trashed.any { it.project.id == "a" }, "stale trash must not delete a newer restore")
    }

    @Test
    fun newerTrashStillRemovesStaleActiveProject() {
        val local = SyncBlob(
            projects = listOf(project("a", "stale active", updatedAt = 100L)),
            trashed = emptyList()
        )
        val remote = SyncBlob(
            projects = emptyList(),
            trashed = listOf(trashed("a", deletedAt = 300L, lyrics = "deleted lyrics"))
        )

        val merged = SyncMerger.merge(local, remote)

        assertFalse(merged.projects.any { it.id == "a" }, "newer trash must remove stale active copy")
        assertEquals("deleted lyrics", merged.trashed.first { it.project.id == "a" }.project.lyrics)
    }

    @Test
    fun trashLastWriterWinsByDeletedAt() {
        val local = SyncBlob(trashed = listOf(trashed("a", deletedAt = 100L, lyrics = "old")))
        val remote = SyncBlob(trashed = listOf(trashed("a", deletedAt = 200L, lyrics = "new")))

        val merged = SyncMerger.merge(local, remote)

        val entry = merged.trashed.first { it.project.id == "a" }
        assertEquals(200L, entry.deletedAt)
        assertEquals("new", entry.project.lyrics)
    }

    @Test
    fun mergeOfEmptyRemoteReturnsLocalContents() {
        val local = SyncBlob(projects = listOf(project("a", "A", 100L)))
        val remote = SyncBlob()

        val merged = SyncMerger.merge(local, remote)

        assertEquals(listOf("a"), merged.projects.map { it.id })
    }

    @Test
    fun tombstonesConvergeByTimestampPrecedence() {
        val later = 2_000_000_000_000L
        fun recording(id: String, file: String) = RecordingManifestEntry(
            projectId = id, fileName = file, sizeBytes = 3, modifiedAt = later, sha256 = "synthetic"
        )
        val content = SyncBlob(
            projects = listOf(project("gone", "edited after its tombstones", later), project("keep", "current", later), project("old", "stale", 10L)),
            trashed = listOf(TrashedSongProject(project("binned", "stale", 10L), 20L)),
            recordings = listOf(
                recording("gone", "take.m4a"),
                recording("keep", "removed.m4a"),
                recording("keep", "new.m4a")
            )
        )
        val tombstones = SyncBlob(deletions = listOf(
            SyncDeletion("gone", deletedAt = 1L),
            SyncDeletion("gone", deletedAt = 2L),
            SyncDeletion("old", deletedAt = 2_000L),
            SyncDeletion("binned", deletedAt = 30L),
            SyncDeletion("gone", fileName = "take.m4a", deletedAt = Long.MAX_VALUE),
            SyncDeletion("keep", fileName = "removed.m4a", deletedAt = later + 1),
            SyncDeletion("keep", fileName = "new.m4a", deletedAt = 3L)
        ))
        val merged = SyncMerger.merge(content, tombstones)

        // A song edited after its tombstone survives and the tombstone is dropped.
        assertEquals(setOf("gone", "keep"), merged.projects.map { it.id }.toSet())
        assertEquals(emptySet(), merged.trashed.map { it.project.id }.toSet())
        assertEquals(setOf("keep/new.m4a"), merged.recordings.map { it.nameKey }.toSet())
        assertEquals(
            listOf(
                SyncDeletion("binned", deletedAt = 30L),
                SyncDeletion("gone", fileName = "take.m4a", deletedAt = Long.MAX_VALUE),
                SyncDeletion("keep", fileName = "removed.m4a", deletedAt = later + 1),
                SyncDeletion("old", deletedAt = 2_000L)
            ),
            merged.deletions
        )
        for (next in listOf(
            SyncMerger.merge(tombstones, content),
            SyncMerger.merge(merged, content)
        )) {
            assertEquals(merged.projects.map { it.id }.toSet(), next.projects.map { it.id }.toSet())
            assertEquals(merged.trashed.map { it.project.id }.toSet(), next.trashed.map { it.project.id }.toSet())
            assertEquals(merged.recordings.map { it.nameKey }.toSet(), next.recordings.map { it.nameKey }.toSet())
            assertEquals(merged.deletions, next.deletions)
        }
    }

    @Test
    fun aNameOnlyTombstoneNamesOnlyPreV4RecordingsOfThatName() {
        val sha = BackupManifest.sha256Hex("a".toByteArray())
        val olderA = RecordingManifestEntry("p", "take.m4a", sizeBytes = 1L, modifiedAt = 1_000L, sha256 = sha)
        val renamedA = olderA.copy(fileName = "Verse.m4a", driveName = RecordingManifestEntry.driveNameFor("p", "Verse.m4a"))
        val newB = olderA.copy(id = RecordingManifestEntry.newRecordingId(), uploadedAt = 1_000L)
        val byName = SyncDeletion("p", "take.m4a", 5_000L)
        val tombstones = SyncMerger.Tombstones(listOf(byName))

        assertTrue(tombstones.removes(olderA))
        assertTrue(tombstones.removes(renamedA))
        assertFalse(tombstones.removes(newB))
        val resolved = SyncMerger.merge(SyncBlob(recordings = listOf(newB)), SyncBlob(deletions = listOf(byName)))
        assertEquals(listOf(newB), resolved.recordings)
        assertTrue(byName in resolved.deletions)
    }

    @Test
    fun recordingsSharingADisplayNameAllSurviveMergeWithTheirNamesUnchanged() {
        fun take(id: String, time: Long) = RecordingManifestEntry("p", "take.m4a", sizeBytes = 1L, modifiedAt = 0L,
            sha256 = "a".repeat(64), uploadedAt = time, id = id)
        val a = take("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", 10L)
        val b = take("7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2", 20L)
        val c = take("b2a1c3d4-e5f6-4789-8abc-def012345678", 30L)
        val expected = mapOf(a.id to "take.m4a", b.id to "take.m4a", c.id to "take.m4a")
        // A36: display names are metadata; duplicates are kept as-is and never renamed by merge.
        for ((local, remote) in listOf(listOf(a, b) to listOf(c), listOf(c) to listOf(b, a), listOf(b, c) to listOf(a, b))) {
            val merged = SyncMerger.merge(SyncBlob(recordings = local), SyncBlob(recordings = remote))
            assertEquals(expected, merged.recordings.associate { it.id to it.fileName })
        }
    }

    @Test
    fun activeVersusTrashUsesTheRepairAwareOrderInEitherInputOrder() {
        fun active(time: Long) = SongProject(id = "s", title = "active", updatedAt = time, precedenceRepaired = true)
        fun trashed(time: Long) = TrashedSongProject(SongProject(id = "s", title = "trashed", updatedAt = 1L), deletedAt = time, deletedAtRepaired = true)
        for ((a, t, trashWins) in listOf(Triple(2_000L, 1_000L, true), Triple(1_000L, 2_000L, false))) {
            for (swap in listOf(false, true)) {
                val one = SyncBlob(projects = listOf(active(a)))
                val two = SyncBlob(trashed = listOf(trashed(t)))
                val merged = if (swap) SyncMerger.merge(two, one) else SyncMerger.merge(one, two)
                assertEquals(trashWins, merged.trashed.isNotEmpty(), "active $a trash $t swap $swap")
                assertEquals(!trashWins, merged.projects.isNotEmpty(), "active $a trash $t swap $swap")
            }
        }
    }

    @Test
    fun aTombstoneMeetsATrashEntryByItsTrashTimeOnly() {
        // Trash time 100 (real), its song's time 300 (a repair), tombstone 200: the tombstone wins.
        val trashed = TrashedSongProject(SongProject(id = "s", updatedAt = 300L, precedenceRepaired = true), deletedAt = 100L)
        val merged = SyncMerger.merge(SyncBlob(trashed = listOf(trashed)), SyncBlob(deletions = listOf(SyncDeletion("s", deletedAt = 200L))))
        assertTrue(merged.trashed.isEmpty())
        // Trash time after the tombstone: the Trash entry stays.
        val later = SyncMerger.merge(SyncBlob(trashed = listOf(trashed.copy(deletedAt = 250L))), SyncBlob(deletions = listOf(SyncDeletion("s", deletedAt = 200L))))
        assertEquals(listOf("s"), later.trashed.map { it.project.id })
    }

    @Test
    fun aRealTombstoneBeatsARepairedTimeWhateverTheNumbers() {
        // A38: Trash time 300 is a repair, the tombstone at 200 is real: the tombstone wins.
        val trashed = TrashedSongProject(SongProject(id = "s", updatedAt = 100L), deletedAt = 300L, deletedAtRepaired = true)
        val merged = SyncMerger.merge(SyncBlob(trashed = listOf(trashed)), SyncBlob(deletions = listOf(SyncDeletion("s", deletedAt = 200L))))
        assertTrue(merged.trashed.isEmpty())
        assertEquals(listOf("s"), merged.deletions.map { it.projectId })
        // The same for an active song and a recording whose times are repairs.
        val active = SongProject(id = "a", updatedAt = 900L, precedenceRepaired = true)
        val take = RecordingManifestEntry("a", "take.m4a", sizeBytes = 1L, modifiedAt = 0L, sha256 = "a".repeat(64), uploadedAt = 900L, precedenceRepaired = true)
        val both = SyncMerger.merge(SyncBlob(projects = listOf(active), recordings = listOf(take)),
            SyncBlob(deletions = listOf(SyncDeletion("a", deletedAt = 200L))))
        assertTrue(both.projects.isEmpty() && both.recordings.isEmpty())
        // A real time newer than the tombstone still survives it.
        val real = SyncMerger.merge(SyncBlob(projects = listOf(active.copy(precedenceRepaired = false))), SyncBlob(deletions = listOf(SyncDeletion("a", deletedAt = 200L))))
        assertEquals(listOf("a"), real.projects.map { it.id })
    }

    @Test
    fun twoTrashCopiesSettleTheirTrashTimeAndTheirSongIndependently() {
        // One copy was trashed later; the other holds the newer edit of the song.
        val laterTrash = TrashedSongProject(SongProject(id = "s", lyrics = "old", updatedAt = 100L), deletedAt = 500L)
        val newerSong = TrashedSongProject(SongProject(id = "s", lyrics = "new", updatedAt = 400L), deletedAt = 300L)
        for ((one, two) in listOf(laterTrash to newerSong, newerSong to laterTrash)) {
            val merged = SyncMerger.merge(SyncBlob(trashed = listOf(one)), SyncBlob(trashed = listOf(two))).trashed.single()
            assertEquals(500L to "new", merged.deletedAt to merged.project.lyrics)
        }
        // Repairs on each side follow their own flag: a real song time beats a repaired one.
        val repairedSong = newerSong.copy(project = newerSong.project.copy(updatedAt = 900L, precedenceRepaired = true, lyrics = "repaired"))
        val merged = SyncMerger.merge(SyncBlob(trashed = listOf(repairedSong)), SyncBlob(trashed = listOf(laterTrash))).trashed.single()
        assertEquals(500L to "old", merged.deletedAt to merged.project.lyrics)
    }
}
