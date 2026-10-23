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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNames
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
        // One entry per recording id: duplicates are refused before anything is applied.
        require(recordings.mapTo(HashSet()) { it.id }.size == recordings.size) { "Duplicate recording id" }
        deletions.forEach(SyncDeletion::validate)
    }
}

@Serializable
data class SyncDeletion(
    val projectId: String,
    @OptIn(ExperimentalSerializationApi::class)
    @EncodeDefault
    val fileName: String? = null,
    val deletedAt: Long,
    /**
     * The deleted recording's stable id (A21). Null on a song tombstone, and on a
     * name-only recording tombstone carried over from a pre-v4 backup, which still
     * applies by project and file name.
     */
    val recordingId: String? = null
) {
    /** Tombstones of one identity collapse to the newest. */
    val identity: String
        get() = recordingId?.let { "id:$it" } ?: "name:$projectId/${fileName.orEmpty()}"

    /** A song tombstone names neither a recording id nor a file; anything else is a recording tombstone. */
    val isSongTombstone: Boolean
        get() = recordingId == null && fileName == null

    fun validate() {
        SyncIdentity.validateProjectId(projectId)
        fileName?.let(SyncIdentity::validateDisplayName)
        recordingId?.let(SyncIdentity::validateRecordingId)
        // A33: a deletion time must be a real time; zero or negative never wins anything.
        require(deletedAt > 0L) { "Invalid deletion time" }
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

/**
 * The v1–v3 encrypted backup as its writers stored it: a collection left out was empty
 * (its default), but a song or Trash entry without its time has an unknown time (0,
 * repaired before any comparison, A32) rather than the moment it is read, and a song
 * without an id is refused (an identity is never invented).
 */
private fun historicalTimes(fields: JsonObject): Map<String, JsonElement> {
    fun song(element: JsonElement): JsonObject {
        val song = element.jsonObject
        if ("id" !in song) throw SerializationException("A song in the backup has no id")
        return if ("updatedAt" in song) song else JsonObject(song + ("updatedAt" to JsonPrimitive(0L)))
    }
    val out = HashMap<String, JsonElement>()
    fields["projects"]?.let { projects -> out["projects"] = JsonArray(projects.jsonArray.map(::song)) }
    fields["trashed"]?.let { trashed ->
        out["trashed"] = JsonArray(trashed.jsonArray.map { element ->
            val entry = element.jsonObject
            val project = entry["project"] ?: throw SerializationException("A Trash entry in the backup has no song")
            val timed = if ("deletedAt" in entry) entry else JsonObject(entry + ("deletedAt" to JsonPrimitive(0L)))
            JsonObject(timed + ("project" to song(project)))
        })
    }
    return out
}

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
        val wire = input.json.decodeFromJsonElement(SyncBlobWire.serializer(), JsonObject(fields + historicalTimes(fields)))
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
    private val recordingIdPattern = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

    fun validateRecordingId(value: String) {
        require(recordingIdPattern.matches(value)) { "Invalid recording id" }
    }

    private const val MAX_PROJECT_ID_BYTES = 128
    const val MAX_RECORDING_FILE_NAME_BYTES = 240
    const val MAX_DISPLAY_NAME_BYTES = 1024

    fun validateProjectId(value: String) {
        require(value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= MAX_PROJECT_ID_BYTES) {
            "Invalid project identifier"
        }
        require(value != "." && value != "..") { "Invalid project identifier" }
        require(value.none { it.isISOControl() || it == '/' || it == '\\' }) { "Invalid project identifier" }
    }

    /**
     * A display name (A36/A39) is metadata, never a path: any non-empty text without NUL, at
     * most [MAX_DISPLAY_NAME_BYTES] UTF-8 bytes. Separators, long names and names without an
     * extension are allowed; files are named by id and archive names are allocated (A39).
     */
    fun validateDisplayName(value: String) {
        require(value.isNotEmpty() && '\u0000' !in value && value.toByteArray(Charsets.UTF_8).size <= MAX_DISPLAY_NAME_BYTES) {
            "Invalid recording name"
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
    /** The recording's precedence time (v4 `uploadedAt`, epoch milliseconds); 0 when unknown. */
    val uploadedAt: Long = 0L,
    /**
     * Stable recording id (A21). A pre-v4 entry has none on the wire and gets one
     * derived from its project, name and hash, so every device derives the same id.
     */
    val id: String = legacyRecordingId(projectId, fileName, sha256),
    /** A37: [uploadedAt] is a first-seen repair of a missing time (A32). */
    val precedenceRepaired: Boolean = false
) {
    /** Merge, tombstones and presence all key on the id. */
    val identityKey: String
        get() = id

    /** The pre-v4 identity, for name-only tombstones. */
    val nameKey: String
        get() = "$projectId/$fileName"

    /** A36: [fileName] is the recording's display name; on disk the file is named by [id]. */
    fun toRecord(origin: String, path: String?) =
        RecordingRecord(id, projectId, fileName, precedenceTime, sha256, sizeBytes, origin, path, precedenceRepaired = precedenceRepaired)

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
        SyncIdentity.validateDisplayName(fileName)
        SyncIdentity.validateRecordingId(id)
        require(driveName == driveNameFor(projectId, fileName)) { "Invalid recording Drive name" }
        // An empty recording is never valid, on any path (recording, import, archive, restore).
        require(sizeBytes > 0L) { "Invalid recording size" }
        require(uploadedAt >= 0L) { "Invalid recording time" }
    }

    companion object {
        /** Per-recording transfer limit for this device; not a manifest validity rule. */
        const val MAX_SYNC_RECORDING_BYTES = 16L * 1024L * 1024L
        const val DRIVE_PREFIX = "rec_"
        const val MIME_TYPE = "application/octet-stream"

        /**
         * Name-based UUID (version 3, MD5) of "rhymeai-legacy-recording:<projectId>/<fileName>/<sha256>",
         * so a pre-v4 recording gets the same id on every device and every run.
         */
        fun legacyRecordingId(projectId: String, fileName: String, sha256: String): String =
            java.util.UUID.nameUUIDFromBytes(
                "rhymeai-legacy-recording:$projectId/$fileName/$sha256".toByteArray(Charsets.UTF_8)
            ).toString()

        fun newRecordingId(): String = java.util.UUID.randomUUID().toString()

        /** RAI1-encrypted pre-v4 name; v4 uses [BackupManifest.recordingDriveName]. */
        fun driveNameFor(projectId: String, fileName: String): String {
            return "$DRIVE_PREFIX${projectId}_${fileName}.enc"
        }
    }
}

/**
 * What this device knows about one recording (A20/A21/A36), kept in DataStore beside
 * the songs and keyed by the recording's stable [id]: its [displayName] (the name the
 * user sees; on disk the file is `<id>.<ext>`), the precedence time tombstones are
 * compared with ([uploadedAt]), its hash and size, how it arrived, where its bytes are
 * now ([path], relative to the app's files folder) and, in Trash, when it was trashed
 * ([trashedAt]). While a file is being moved, [pendingFrom] names the source so an
 * interrupted move can be finished or undone at the next launch (A24).
 * [displayNameChanged] marks a rename made here that a backup has not written yet.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class RecordingRecord(
    val id: String,
    val projectId: String,
    /** Rows written before A36 call it `fileName` (the name the file had); read as the display name. */
    @JsonNames("fileName") val displayName: String,
    val uploadedAt: Long,
    val sha256: String,
    val bytes: Long,
    val origin: String,
    val path: String? = null,
    val trashedAt: Long? = null,
    val pendingFrom: String? = null,
    val pendingOp: String? = null,
    val pendingTrashedAt: Long? = null,
    val displayNameChanged: Boolean = false,
    /** A37: [uploadedAt] is a first-seen repair of a missing time (A32). */
    val precedenceRepaired: Boolean = false,
    /** Pre-A36 rename intents only: the name to return to if that rename is undone. */
    val pendingFromName: String? = null,
    /**
     * The token of the exclusive claim a pending move creates at [path]: only a target
     * holding exactly this claim is this move's, and only it is ever removed on recovery.
     */
    val pendingClaim: String? = null
) {
    fun toEntry() = RecordingManifestEntry(
        projectId = projectId, fileName = displayName, sizeBytes = bytes, modifiedAt = 0L,
        sha256 = sha256, uploadedAt = uploadedAt, id = id, precedenceRepaired = precedenceRepaired
    )

    companion object {
        const val RECORDED = "recorded"
        const val RESTORED = "restored"
        const val IMPORTED = "imported"
        const val MIGRATED = "migrated"

        /** A pre-v4 file first seen here; its time is the earliest file time among its copies (A26). */
        const val ADOPTED = "adopted"

        /** The bytes were being placed from a staging file; undo removes the record. */
        const val OP_PUBLISH = "publish"

        /** The bytes were being moved (rename, Trash, restore from Trash); undo moves the record back. */
        const val OP_MOVE = "move"
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

    fun merge(local: SyncBlob, remote: SyncBlob): SyncBlob = resolve(gather(local, remote))

    /**
     * Collects every input's songs, trash, recordings and tombstones into one working
     * set without resolving anything: per id the newest song or trash entry, per
     * recording identity the last input's entry, per tombstone identity the newest.
     * Resolve once, with [resolve], after every input is in, so no tombstone is
     * dropped or recording filtered before all the evidence is present.
     */
    fun gather(vararg inputs: SyncBlob): SyncBlob {
        inputs.forEach(SyncBlob::validate)
        var projects = emptyList<SongProject>()
        var trashed = emptyList<TrashedSongProject>()
        var recordings = emptyList<RecordingManifestEntry>()
        for (input in inputs) {
            projects = mergeProjects(projects, input.projects)
            trashed = mergeTrash(trashed, input.trashed)
            // A32: every entry's precedence time is fixed here, before any resolution or
            // naming, and never changes afterwards (an entry without one keeps its file time or 0).
            recordings = mergeRecordings(recordings, input.recordings.map { it.copy(uploadedAt = it.precedenceTime) })
        }
        return SyncBlob(
            version = SyncBlob.CURRENT_VERSION,
            projects = projects,
            trashed = trashed,
            recordings = recordings,
            deletions = mergeDeletions(inputs.flatMap { it.deletions }),
            savedAt = System.currentTimeMillis(),
            savedByClientId = inputs.firstOrNull()?.savedByClientId.orEmpty()
        )
    }

    /** Applies active/trash conflicts and tombstone precedence once to a [gather]ed set. */
    fun resolve(gathered: SyncBlob): SyncBlob {
        val (cleanProjects, cleanTrashed) = resolveActiveTrashConflicts(gathered.projects, gathered.trashed)
        val resolved = applyTombstones(cleanProjects, cleanTrashed, gathered.recordings, gathered.deletions)
        return gathered.copy(
            projects = resolved.projects.sortedByDescending { it.updatedAt },
            trashed = resolved.trashed.sortedByDescending { it.deletedAt },
            recordings = resolved.recordings.sortedWith(compareBy<RecordingManifestEntry> { it.projectId }.thenBy { it.fileName }),
            deletions = resolved.deletions
        )
    }

    /** Newest tombstone per identity. */
    fun mergeDeletions(deletions: List<SyncDeletion>): List<SyncDeletion> {
        deletions.forEach(SyncDeletion::validate)
        val byIdentity = HashMap<String, SyncDeletion>(deletions.size)
        for (deletion in deletions) {
            val identity = deletion.identity
            val existing = byIdentity[identity]
            if (existing == null || deletion.deletedAt > existing.deletedAt) {
                byIdentity[identity] = deletion
            }
        }
        return byIdentity.values.sortedWith(
            compareBy<SyncDeletion> { it.projectId }.thenBy { it.fileName ?: "" }.thenBy { it.recordingId ?: "" }
        )
    }

    fun applyTombstones(
        projects: List<SongProject>,
        trashed: List<TrashedSongProject>,
        recordings: List<RecordingManifestEntry>,
        deletions: List<SyncDeletion>
    ): Resolved {
        val tombstones = Tombstones(deletions)
        val keptProjects = projects.filterNot { project ->
            tombstones.songs[project.id]?.let { deletes(it, project.updatedAt, project.precedenceRepaired) } == true
        }
        val keptTrash = trashed.filterNot { entry ->
            // A38: a Trash entry against a tombstone is its trash time only; its song's own time never overrides one.
            tombstones.songs[entry.project.id]?.let { deletes(it, entry.deletedAt, entry.deletedAtRepaired) } == true
        }
        val keptRecordings = recordings.filterNot(tombstones::removes)
        // Each recording a song tombstone removes gets its own tombstone, so reviving
        // the song later (which drops the song tombstone) cannot bring the audio back.
        val covered = recordings.mapNotNull { entry ->
            val songTombstone = tombstones.songs[entry.projectId] ?: return@mapNotNull null
            if (!deletes(songTombstone, entry.precedenceTime, entry.precedenceRepaired)) return@mapNotNull null
            SyncDeletion(entry.projectId, entry.fileName, songTombstone.deletedAt, recordingId = entry.id)
        }
        val allDeletions = if (covered.isEmpty()) deletions else mergeDeletions(deletions + covered)
        val survivingSongs = buildSet {
            keptProjects.forEach { add(it.id) }
            keptTrash.forEach { add(it.project.id) }
        }
        val survivingIds = keptRecordings.mapTo(HashSet()) { it.id }
        val keptDeletions = allDeletions.filterNot { deletion ->
            when {
                deletion.isSongTombstone -> deletion.projectId in survivingSongs
                deletion.recordingId != null -> deletion.recordingId in survivingIds
                else -> keptRecordings.any { Tombstones.namesLegacy(deletion, it) }
            }
        }
        return Resolved(keptProjects, keptTrash, keptRecordings, keptDeletions)
    }

    /**
     * Song, recording-id and pre-v4 name-only tombstones, applied by timestamp. A
     * name-only tombstone can only name a pre-v4 recording: it applies to a recording
     * whose id is the legacy id of that name and the recording's own bytes, never to a
     * v4 recording that reuses the name (A21).
     */
    class Tombstones(deletions: List<SyncDeletion>) {
        // Duplicates of one identity: the newest deletion counts, whatever the order.
        val songs: Map<String, SyncDeletion> = deletions.filter { it.isSongTombstone }
            .groupBy { it.projectId }.mapValues { (_, d) -> d.maxBy { it.deletedAt } }
        private val byId = deletions.filter { it.recordingId != null }
            .groupBy { it.recordingId!! }.mapValues { (_, d) -> d.maxBy { it.deletedAt } }
        private val byProjectNames = deletions.filter { it.fileName != null && it.recordingId == null }
            .groupBy { it.projectId }

        fun removes(entry: RecordingManifestEntry): Boolean {
            val time = entry.precedenceTime
            val repaired = entry.precedenceRepaired
            return songs[entry.projectId]?.let { deletes(it, time, repaired) } == true ||
                byId[entry.id]?.let { deletes(it, time, repaired) } == true ||
                byProjectNames[entry.projectId].orEmpty().any { deletes(it, time, repaired) && namesLegacy(it, entry) }
        }

        companion object {
            fun namesLegacy(deletion: SyncDeletion, entry: RecordingManifestEntry): Boolean =
                deletion.recordingId == null && deletion.fileName != null && deletion.projectId == entry.projectId &&
                    entry.id == RecordingManifestEntry.legacyRecordingId(entry.projectId, deletion.fileName, entry.sha256)
        }
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
            if (existing == null || supersedes(project.updatedAt, project.precedenceRepaired, existing.updatedAt, existing.precedenceRepaired)) {
                byId[project.id] = project
            }
        }
        return byId.values.toList()
    }

    /**
     * A38: whether [tombstone] (always a real time) wins over a held time: a real time beats
     * a repair, so a tombstone removes anything whose time is a repair; otherwise it must be newer.
     */
    internal fun deletes(tombstone: SyncDeletion, time: Long, repaired: Boolean): Boolean =
        supersedes(tombstone.deletedAt, false, time, repaired)

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
            if (existing == null) {
                byId[entry.project.id] = entry
                continue
            }
            // A38: the Trash time and the song inside are settled independently, each by its own flag.
            val trash = if (supersedes(entry.deletedAt, entry.deletedAtRepaired, existing.deletedAt, existing.deletedAtRepaired)) entry else existing
            val song = if (supersedes(entry.project.updatedAt, entry.project.precedenceRepaired, existing.project.updatedAt, existing.project.precedenceRepaired)) entry.project else existing.project
            byId[entry.project.id] = trash.copy(project = song)
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
            val existing = byIdentity[entry.identityKey]
            // A37: of two repaired times the smaller stands; a real time beats a repair.
            val keep = existing != null && (existing.precedenceRepaired || entry.precedenceRepaired) &&
                !supersedes(entry.uploadedAt, entry.precedenceRepaired, existing.uploadedAt, existing.precedenceRepaired)
            if (!keep) byIdentity[entry.identityKey] = entry
        }
        return byIdentity.values.toList()
    }

    /**
     * A37: whether a candidate time replaces the held one for the same identity. A real
     * time (an edit) beats a first-seen repair; of two repairs the smaller wins, so every
     * replica settles on the earliest; of two real times the newer wins.
     */
    internal fun supersedes(time: Long, repaired: Boolean, heldTime: Long, heldRepaired: Boolean): Boolean = when {
        repaired != heldRepaired -> !repaired
        repaired -> time < heldTime
        else -> time > heldTime
    }

    private fun resolveActiveTrashConflicts(
        projects: List<SongProject>,
        trashed: List<TrashedSongProject>
    ): Pair<List<SongProject>, List<TrashedSongProject>> {
        val activeById = projects.associateBy { it.id }
        val restoredIds = trashed
            .filter { trash ->
                val activeProject = activeById[trash.project.id]
                // A37: a real time beats a repair, of two repairs the smaller wins, of two real
                // times the newer; on a tie the Trash entry stays.
                activeProject != null &&
                    supersedes(activeProject.updatedAt, activeProject.precedenceRepaired, trash.deletedAt, trash.deletedAtRepaired)
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
