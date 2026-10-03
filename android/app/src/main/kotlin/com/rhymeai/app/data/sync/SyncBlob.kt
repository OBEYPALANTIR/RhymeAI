package com.rhymeai.app.data.sync

import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The complete, sync-able snapshot of a user's library. Serialized as a single
 * `rhymeai-projects.json` blob in Drive's hidden `appDataFolder`. One blob per
 * user; every device pushes and pulls the whole thing.
 *
 * Schema version is bumped only if the on-disk shape needs to evolve; readers
 * older than `version` should fall back to local-only operation rather than
 * try to interpret unknown fields.
 */
@Serializable(with = SyncBlobSerializer::class)
data class SyncBlob(
    val version: Int = CURRENT_VERSION,
    val projects: List<SongProject> = emptyList(),
    val trashed: List<TrashedSongProject> = emptyList(),
    val recordings: List<RecordingManifestEntry> = emptyList(),
    val deletions: List<SyncDeletion> = emptyList(),
    val savedAt: Long = System.currentTimeMillis(),
    val savedByClientId: String = ""
) {
    companion object {
        const val CURRENT_VERSION = 3
        const val DRIVE_FILE_NAME = "rhymeai-projects.json"
        const val DRIVE_MIME_TYPE = "application/json"
    }

    fun validate() {
        require(version in 1..CURRENT_VERSION) { "Unsupported sync version" }
        require(version >= 2 || deletions.isEmpty()) { "Invalid sync version shape" }
        projects.forEach { SyncIdentity.validateProjectId(it.id) }
        trashed.forEach { SyncIdentity.validateProjectId(it.project.id) }
        recordings.forEach(RecordingManifestEntry::validate)
        deletions.forEach(SyncDeletion::validate)
    }
}

@Serializable
data class SyncDeletion(
    val projectId: String,
    @OptIn(ExperimentalSerializationApi::class)
    @EncodeDefault
    val fileName: String? = null,
    val deletedAt: Long
) {
    fun validate() {
        SyncIdentity.validateProjectId(projectId)
        fileName?.let(SyncIdentity::validateFileName)
    }
}

/** The wire shape is explicit: v1 has no deletions key; v2 must have one. */
@Serializable
private data class SyncBlobWire(
    val version: Int,
    val projects: List<SongProject> = emptyList(),
    val trashed: List<TrashedSongProject> = emptyList(),
    val recordings: List<RecordingManifestEntry> = emptyList(),
    @OptIn(ExperimentalSerializationApi::class)
    @EncodeDefault
    val deletions: List<SyncDeletion> = emptyList(),
    val savedAt: Long = System.currentTimeMillis(),
    val savedByClientId: String = ""
)

object SyncBlobSerializer : KSerializer<SyncBlob> {
    override val descriptor: SerialDescriptor = SyncBlobWire.serializer().descriptor

    override fun deserialize(decoder: Decoder): SyncBlob {
        val input = decoder as? JsonDecoder ?: throw SerializationException("Sync blob requires JSON")
        val fields = input.decodeJsonElement().jsonObject
        val version = fields["version"]?.jsonPrimitive?.int
            ?: throw SerializationException("Missing sync version")
        if (version !in 1..SyncBlob.CURRENT_VERSION ||
            (version == 1 && "deletions" in fields) ||
            (version >= 2 && (fields["deletions"] == null || fields["deletions"] is JsonNull))
        ) {
            throw SerializationException("Invalid sync version shape")
        }
        val wire = input.json.decodeFromJsonElement(SyncBlobWire.serializer(), fields)
        return SyncBlob(
            version = wire.version,
            projects = wire.projects,
            trashed = wire.trashed,
            recordings = wire.recordings,
            deletions = wire.deletions,
            savedAt = wire.savedAt,
            savedByClientId = wire.savedByClientId
        ).also(SyncBlob::validate)
    }

    override fun serialize(encoder: Encoder, value: SyncBlob) {
        val output = encoder as? JsonEncoder ?: throw SerializationException("Sync blob requires JSON")
        value.validate()
        val wire = SyncBlobWire(
            version = value.version,
            projects = value.projects,
            trashed = value.trashed,
            recordings = value.recordings,
            deletions = value.deletions,
            savedAt = value.savedAt,
            savedByClientId = value.savedByClientId
        )
        val fields = output.json.encodeToJsonElement(SyncBlobWire.serializer(), wire).jsonObject
        output.encodeJsonElement(if (value.version == 1) JsonObject(fields - "deletions") else fields)
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
 * Merge content by update timestamps, then unconditionally suppress projects
 * and recordings named by the union of permanent-deletion tombstones. Active/
 * trash conflicts still compare timestamps, but a newer stale edit never
 * overrides a permanent deletion. Application order is local-first so that
 * a missing remote degrades gracefully to local data.
 *
 * Pure function, no IO, no side effects. Tested without Android.
 */
object SyncMerger {
    fun merge(local: SyncBlob, remote: SyncBlob): SyncBlob {
        local.validate()
        remote.validate()
        val deletions = mergeDeletions(local.deletions + remote.deletions)
        val deletedProjects = deletions.filter { it.fileName == null }.mapTo(HashSet()) { it.projectId }
        val deletedFiles = deletions.filter { it.fileName != null }
            .mapTo(HashSet()) { it.projectId to it.fileName }
        val mergedProjects = mergeProjects(local.projects, remote.projects)
        val mergedTrashed = mergeTrash(local.trashed, remote.trashed)
        val mergedRecordings = mergeRecordings(local.recordings, remote.recordings)

        val (cleanProjects, cleanTrashed) = resolveActiveTrashConflicts(mergedProjects, mergedTrashed)

        return SyncBlob(
            version = SyncBlob.CURRENT_VERSION,
            projects = cleanProjects.filterNot { it.id in deletedProjects }.sortedByDescending { it.updatedAt },
            trashed = cleanTrashed.filterNot { it.project.id in deletedProjects }.sortedByDescending { it.deletedAt },
            recordings = mergedRecordings.filterNot {
                it.projectId in deletedProjects || (it.projectId to it.fileName) in deletedFiles
            }.sortedWith(compareBy<RecordingManifestEntry> { it.projectId }.thenBy { it.fileName }),
            deletions = deletions,
            savedAt = System.currentTimeMillis(),
            savedByClientId = local.savedByClientId
        )
    }

    fun mergeDeletions(deletions: List<SyncDeletion>): List<SyncDeletion> {
        deletions.forEach(SyncDeletion::validate)
        val deletedProjects = deletions.filter { it.fileName == null }.mapTo(HashSet()) { it.projectId }
        val byIdentity = HashMap<Pair<String, String?>, SyncDeletion>(deletions.size)
        for (deletion in deletions) {
            if (deletion.fileName != null && deletion.projectId in deletedProjects) continue
            val identity = deletion.projectId to deletion.fileName
            val existing = byIdentity[identity]
            if (existing == null || deletion.deletedAt > existing.deletedAt) {
                byIdentity[identity] = deletion
            }
        }
        return byIdentity.values.sortedWith(compareBy<SyncDeletion> { it.projectId }.thenBy { it.fileName ?: "" })
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
