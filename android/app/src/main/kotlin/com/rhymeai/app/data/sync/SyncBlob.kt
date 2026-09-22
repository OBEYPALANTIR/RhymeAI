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
    val recordings: List<RecordingManifestEntry> = emptyList(),
    val savedAt: Long = System.currentTimeMillis(),
    val savedByClientId: String = ""
) {
    companion object {
        const val CURRENT_VERSION = 1
        const val DRIVE_FILE_NAME = "rhymeai-projects.json"
        const val DRIVE_MIME_TYPE = "application/json"
    }

    fun validate() {
        projects.forEach { SyncIdentity.validateProjectId(it.id) }
        trashed.forEach { SyncIdentity.validateProjectId(it.project.id) }
        recordings.forEach(RecordingManifestEntry::validate)
    }
}

internal object SyncIdentity {
    private const val MAX_PROJECT_ID_BYTES = 128
    private const val MAX_RECORDING_FILE_NAME_BYTES = 240
    private val illegalRecordingCharacters = setOf('/', '\\', ':', '*', '?', '"', '<', '>', '|')

    fun validateProjectId(value: String) {
        require(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= MAX_PROJECT_ID_BYTES) {
            "Invalid project identifier"
        }
        require(value != "." && value != "..") { "Invalid project identifier" }
        require(value.none { it.isISOControl() || it == '/' || it == '\\' }) { "Invalid project identifier" }
    }

    fun validateFileName(value: String) {
        require(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= MAX_RECORDING_FILE_NAME_BYTES) {
            "Invalid recording filename"
        }
        require(value == value.trim() && value.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT) in com.rhymeai.app.data.recording.RecordingFiles.SUPPORTED_AUDIO_EXTENSIONS) { "Invalid recording filename" }
        require(value.none { it.isISOControl() || it in illegalRecordingCharacters }) {
            "Invalid recording filename"
        }
    }
}

@Serializable
data class RecordingManifestEntry(
    val projectId: String,
    val fileName: String,
    val driveName: String = driveNameFor(projectId, fileName),
    val sizeBytes: Long,
    val modifiedAt: Long,
    val sha256: String
) {
    val identityKey: String
        get() = "$projectId/$fileName"

    fun validate() {
        SyncIdentity.validateProjectId(projectId)
        SyncIdentity.validateFileName(fileName)
        require(driveName == driveNameFor(projectId, fileName)) { "Invalid recording Drive name" }
        require(sizeBytes in 0..MAX_SYNC_RECORDING_BYTES) { "Invalid recording size" }
    }

    companion object {
        const val MAX_SYNC_RECORDING_BYTES = 16L * 1024L * 1024L
        const val DRIVE_PREFIX = "rec_"
        const val MIME_TYPE = "application/octet-stream"

        fun driveNameFor(projectId: String, fileName: String): String {
            return "$DRIVE_PREFIX${projectId}_${fileName}.enc"
        }
    }
}

/**
 * Pure merge logic: takes the local snapshot and the remote snapshot and
 * produces the canonical post-merge snapshot using last-writer-wins keyed on
 * `updatedAt`. Trash entries follow the same rule on `deletedAt`; active-vs-trash
 * conflicts compare those two timestamps so a later restore can beat stale
 * trash. Application order is local-first so that a missing remote degrades
 * gracefully to local data.
 *
 * Pure function, no IO, no side effects. Tested without Android.
 */
object SyncMerger {
    fun merge(local: SyncBlob, remote: SyncBlob): SyncBlob {
        local.validate()
        remote.validate()
        val mergedProjects = mergeProjects(local.projects, remote.projects)
        val mergedTrashed = mergeTrash(local.trashed, remote.trashed)
        val mergedRecordings = mergeRecordings(local.recordings, remote.recordings)

        val (cleanProjects, cleanTrashed) = resolveActiveTrashConflicts(mergedProjects, mergedTrashed)

        return SyncBlob(
            version = maxOf(local.version, remote.version),
            projects = cleanProjects.sortedByDescending { it.updatedAt },
            trashed = cleanTrashed.sortedByDescending { it.deletedAt },
            recordings = mergedRecordings.sortedWith(compareBy<RecordingManifestEntry> { it.projectId }.thenBy { it.fileName }),
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

    private fun mergeRecordings(
        local: List<RecordingManifestEntry>,
        remote: List<RecordingManifestEntry>
    ): List<RecordingManifestEntry> {
        val byIdentity = HashMap<String, RecordingManifestEntry>(local.size + remote.size)
        for (entry in local) {
            byIdentity[entry.identityKey] = entry
        }
        for (entry in remote) {
            val existing = byIdentity[entry.identityKey]
            if (existing == null || entry.modifiedAt > existing.modifiedAt) {
                byIdentity[entry.identityKey] = entry
            }
        }
        return byIdentity.values.toList()
    }

    private fun resolveActiveTrashConflicts(
        projects: List<SongProject>,
        trashed: List<TrashedSongProject>
    ): Pair<List<SongProject>, List<TrashedSongProject>> {
        val activeById = projects.associateBy { it.id }
        val restoredIds = trashed
            .filter { trash ->
                val activeProject = activeById[trash.project.id]
                activeProject != null && activeProject.updatedAt > trash.deletedAt
            }
            .mapTo(mutableSetOf()) { it.project.id }

        val trashIds = trashed
            .filterNot { it.project.id in restoredIds }
            .mapTo(mutableSetOf()) { it.project.id }

        val cleanProjects = projects.filter { it.id !in trashIds }
        val cleanTrashed = trashed.filter { it.project.id !in restoredIds }

        return cleanProjects to cleanTrashed
    }
}
