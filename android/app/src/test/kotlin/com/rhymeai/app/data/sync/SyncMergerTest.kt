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
    fun versionResultIsMaxOfBothBlobs() {
        val local = SyncBlob(version = 1)
        val remote = SyncBlob(version = 3)

        val merged = SyncMerger.merge(local, remote)

        assertEquals(3, merged.version)
    }
}
