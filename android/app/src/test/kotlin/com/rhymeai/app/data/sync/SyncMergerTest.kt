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
}
