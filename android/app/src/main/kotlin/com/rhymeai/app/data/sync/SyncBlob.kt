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
 * The complete backup snapshot of a user's library, held in memory. Drive and
 * export files carry it as [BackupManifest] v4; this serializer only reads the
 * legacy v1-v3 JSON found inside an older encrypted `rhymeai-projects.json`.
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
        /** Encrypted pre-v4 manifest; read only to migrate it. */
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
    val sha256: String,
    /** When this copy reached Drive (v4 `uploadedAt`); 0 for a local file not yet listed. */
    val uploadedAt: Long = 0L
) {
    val identityKey: String
        get() = "$projectId/$fileName"

    /** The time a tombstone must beat to remove this recording. */
    val precedenceTime: Long
        get() = if (uploadedAt > 0L) uploadedAt else modifiedAt

    /**
     * Whether this device can move the recording. Recordings are held whole in
     * memory, so a larger entry stays valid in the manifest (another device may
     * hold it) but is never uploaded or downloaded here.
     */
    val isTransferable: Boolean
        get() = sizeBytes <= MAX_SYNC_RECORDING_BYTES

    fun validate() {
        SyncIdentity.validateProjectId(projectId)
        SyncIdentity.validateFileName(fileName)
        require(driveName == driveNameFor(projectId, fileName)) { "Invalid recording Drive name" }
        require(sizeBytes >= 0L) { "Invalid recording size" }
    }

    companion object {
        /** Per-recording transfer limit for this device; not a manifest validity rule. */
        const val MAX_SYNC_RECORDING_BYTES = 16L * 1024L * 1024L
        const val DRIVE_PREFIX = "rec_"
        const val MIME_TYPE = "application/octet-stream"

        /** RAI1-encrypted pre-v4 name; v4 uses [BackupManifest.recordingDriveName]. */
        fun driveNameFor(projectId: String, fileName: String): String {
            return "$DRIVE_PREFIX${projectId}_${fileName}.enc"
        }
    }
}

/**
 * Merge content by update timestamps, then apply permanent-deletion tombstones
 * by timestamp precedence: a project tombstone removes a song only when its
 * `deletedAt` is newer than the song (and the trash time); a recording tombstone,
 * or the tombstone of its song, removes a recording only when newer than the
 * recording's [RecordingManifestEntry.precedenceTime]. A tombstone beaten by a
 * surviving song or recording is dropped. Application order is local-first so a
 * missing remote degrades gracefully to local data.
 *
 * Pure function, no IO, no side effects. Tested without Android.
 */
object SyncMerger {
    data class Resolved(
        val projects: List<SongProject>,
        val trashed: List<TrashedSongProject>,
        val recordings: List<RecordingManifestEntry>,
        val deletions: List<SyncDeletion>
    )

    fun merge(local: SyncBlob, remote: SyncBlob): SyncBlob {
        local.validate()
        remote.validate()
        val (cleanProjects, cleanTrashed) = resolveActiveTrashConflicts(
            mergeProjects(local.projects, remote.projects),
            mergeTrash(local.trashed, remote.trashed)
        )
        val resolved = applyTombstones(
            cleanProjects,
            cleanTrashed,
            mergeRecordings(local.recordings, remote.recordings),
            mergeDeletions(local.deletions + remote.deletions)
        )
        return SyncBlob(
            version = SyncBlob.CURRENT_VERSION,
            projects = resolved.projects.sortedByDescending { it.updatedAt },
            trashed = resolved.trashed.sortedByDescending { it.deletedAt },
            recordings = resolved.recordings.sortedWith(compareBy<RecordingManifestEntry> { it.projectId }.thenBy { it.fileName }),
            deletions = resolved.deletions,
            savedAt = System.currentTimeMillis(),
            savedByClientId = local.savedByClientId
        )
    }

    /** Newest tombstone per identity. */
    fun mergeDeletions(deletions: List<SyncDeletion>): List<SyncDeletion> {
        deletions.forEach(SyncDeletion::validate)
        val byIdentity = HashMap<Pair<String, String?>, SyncDeletion>(deletions.size)
        for (deletion in deletions) {
            val identity = deletion.projectId to deletion.fileName
            val existing = byIdentity[identity]
            if (existing == null || deletion.deletedAt > existing.deletedAt) {
                byIdentity[identity] = deletion
            }
        }
        return byIdentity.values.sortedWith(compareBy<SyncDeletion> { it.projectId }.thenBy { it.fileName ?: "" })
    }

    fun applyTombstones(
        projects: List<SongProject>,
        trashed: List<TrashedSongProject>,
        recordings: List<RecordingManifestEntry>,
        deletions: List<SyncDeletion>
    ): Resolved {
        val projectTombstones = deletions.filter { it.fileName == null }.associateBy { it.projectId }
        val fileTombstones = deletions.filter { it.fileName != null }.associateBy { it.projectId to it.fileName }
        val keptProjects = projects.filterNot { project ->
            projectTombstones[project.id]?.let { it.deletedAt > project.updatedAt } == true
        }
        val keptTrash = trashed.filterNot { entry ->
            projectTombstones[entry.project.id]?.let { it.deletedAt > maxOf(entry.project.updatedAt, entry.deletedAt) } == true
        }
        val keptRecordings = recordings.filterNot { removesRecording(it, projectTombstones, fileTombstones) }
        // Each recording a song tombstone removes gets its own tombstone, so reviving
        // the song later (which drops the song tombstone) cannot bring the audio back.
        val covered = recordings.mapNotNull { entry ->
            val songTombstone = projectTombstones[entry.projectId] ?: return@mapNotNull null
            if (songTombstone.deletedAt <= entry.precedenceTime) return@mapNotNull null
            SyncDeletion(entry.projectId, entry.fileName, songTombstone.deletedAt)
        }
        val allDeletions = if (covered.isEmpty()) deletions else mergeDeletions(deletions + covered)
        val survivingSongs = buildSet {
            keptProjects.forEach { add(it.id) }
            keptTrash.forEach { add(it.project.id) }
        }
        val survivingRecordings = keptRecordings.mapTo(HashSet()) { it.projectId to it.fileName }
        val keptDeletions = allDeletions.filterNot { deletion ->
            if (deletion.fileName == null) deletion.projectId in survivingSongs
            else (deletion.projectId to deletion.fileName) in survivingRecordings
        }
        return Resolved(keptProjects, keptTrash, keptRecordings, keptDeletions)
    }

    internal fun removesRecording(
        entry: RecordingManifestEntry,
        projectTombstones: Map<String, SyncDeletion>,
        fileTombstones: Map<Pair<String, String?>, SyncDeletion>
    ): Boolean {
        val time = entry.precedenceTime
        return projectTombstones[entry.projectId]?.let { it.deletedAt > time } == true ||
            fileTombstones[entry.projectId to entry.fileName]?.let { it.deletedAt > time } == true
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
        // Recordings are immutable once written (a rename is a new identity), so
        // the copy already backed up wins.
        val byIdentity = HashMap<String, RecordingManifestEntry>(local.size + remote.size)
        for (entry in local) {
            byIdentity[entry.identityKey] = entry
        }
        for (entry in remote) {
            byIdentity[entry.identityKey] = entry
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
