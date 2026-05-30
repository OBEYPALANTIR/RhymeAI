package com.rhymeai.app.data.sync

import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import kotlinx.serialization.Serializable

/**
 * The complete, sync-able snapshot of a user's library. Serialized as a single
 * `rhymeai-projects.json` blob in Drive's hidden `appDataFolder`. One blob per
 * user; every device pushes and pulls the whole thing.
 *
 * Schema version is bumped only if the on-disk shape needs to evolve; readers
 * older than `version` should fall back to local-only operation rather than
 * try to interpret unknown fields.
 */
@Serializable
data class SyncBlob(
    val version: Int = CURRENT_VERSION,
    val projects: List<SongProject> = emptyList(),
    val trashed: List<TrashedSongProject> = emptyList(),
    val savedAt: Long = System.currentTimeMillis(),
    val savedByClientId: String = ""
) {
    companion object {
        const val CURRENT_VERSION = 1
        const val DRIVE_FILE_NAME = "rhymeai-projects.json"
        const val DRIVE_MIME_TYPE = "application/json"
    }
}

/**
 * Pure merge logic: takes the local snapshot and the remote snapshot and
 * produces the canonical post-merge snapshot using last-writer-wins keyed on
 * `updatedAt`. Trash entries follow the same rule on `deletedAt`. Application
 * order is local-first so that a missing remote degrades gracefully to local
 * data.
 *
 * Pure function, no IO, no side effects. Tested without Android.
 */
object SyncMerger {
    fun merge(local: SyncBlob, remote: SyncBlob): SyncBlob {
        val mergedProjects = mergeProjects(local.projects, remote.projects)
        val mergedTrashed = mergeTrash(local.trashed, remote.trashed)

        // Anything in trash should not also live in projects.
        val trashIds = mergedTrashed.map { it.project.id }.toSet()
        val cleanProjects = mergedProjects.filterNot { it.id in trashIds }

        return SyncBlob(
            version = maxOf(local.version, remote.version),
            projects = cleanProjects.sortedByDescending { it.updatedAt },
            trashed = mergedTrashed.sortedByDescending { it.deletedAt },
            savedAt = System.currentTimeMillis(),
            savedByClientId = local.savedByClientId
        )
    }

    private fun mergeProjects(
        local: List<SongProject>,
        remote: List<SongProject>
    ): List<SongProject> {
        val byId = HashMap<String, SongProject>(local.size + remote.size)
        for (project in local) {
            byId[project.id] = project
        }
        for (project in remote) {
            val existing = byId[project.id]
            if (existing == null || project.updatedAt > existing.updatedAt) {
                byId[project.id] = project
            }
        }
        return byId.values.toList()
    }

    private fun mergeTrash(
        local: List<TrashedSongProject>,
        remote: List<TrashedSongProject>
    ): List<TrashedSongProject> {
        val byId = HashMap<String, TrashedSongProject>(local.size + remote.size)
        for (entry in local) {
            byId[entry.project.id] = entry
        }
        for (entry in remote) {
            val existing = byId[entry.project.id]
            if (existing == null || entry.deletedAt > existing.deletedAt) {
                byId[entry.project.id] = entry
            }
        }
        return byId.values.toList()
    }
}
