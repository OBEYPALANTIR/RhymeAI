package com.rhymeai.app.data.sync

import com.rhymeai.app.data.recording.RecordingFiles
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File

/**
 * Records that a recording was deleted at [deletedAt]. Sync uses it so a deleted (trashed or
 * purged) recording is neither uploaded nor restored from a remote manifest that still lists it.
 * A recording with `modifiedAt > deletedAt` is newer than the deletion and wins.
 */
@Serializable
data class RecordingTombstone(
    val projectId: String,
    val fileName: String,
    val deletedAt: Long
) {
    val identityKey: String
        get() = "$projectId/$fileName"

    fun validate() {
        SyncIdentity.validateProjectId(projectId)
        SyncIdentity.validateFileName(fileName)
        require(deletedAt >= 0L) { "Invalid recording tombstone time" }
    }

    /** True when this deletion is at least as recent as [entry], so [entry] must not come back. */
    fun suppresses(entry: RecordingManifestEntry): Boolean =
        identityKey == entry.identityKey && deletedAt >= entry.modifiedAt
}

/**
 * Local persistence for recording tombstones. Trash purges delete the trashed file, so the
 * deletion time is also written here when a recording is trashed and kept after purge.
 * Unreadable or missing state reads as empty; trashed files still contribute via [fromTrash].
 */
object RecordingTombstoneStore {
    private const val FILE_NAME = "recording-tombstones.json"
    private const val TRASH_NAME_SEPARATOR = "__"
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(RecordingTombstone.serializer())

    internal fun file(filesDir: File): File = File(filesDir, FILE_NAME)

    @Synchronized
    fun read(filesDir: File): List<RecordingTombstone> {
        val source = file(filesDir)
        if (!source.isFile) return emptyList()
        return runCatching { json.decodeFromString(serializer, source.readText()) }
            .getOrDefault(emptyList())
            .filter { runCatching { it.validate() }.isSuccess }
    }

    @Synchronized
    fun record(filesDir: File, projectId: String, fileName: String, deletedAt: Long) {
        val tombstone = RecordingTombstone(projectId, fileName, deletedAt)
        runCatching { tombstone.validate() }.onFailure { return }
        write(filesDir, mergeLatest(read(filesDir) + tombstone))
    }

    /** Keep deletions learned from a merged remote so a later blob that lacks them cannot undo them. */
    @Synchronized
    fun recordAll(filesDir: File, tombstones: List<RecordingTombstone>) {
        if (tombstones.isEmpty()) return
        write(filesDir, mergeLatest(read(filesDir) + tombstones))
    }

    /** Forget a deletion, e.g. when the recording is restored from trash under its original name. */
    @Synchronized
    fun clear(filesDir: File, projectId: String, fileName: String) {
        val key = "$projectId/$fileName"
        val current = read(filesDir)
        if (current.none { it.identityKey == key }) return
        write(filesDir, current.filterNot { it.identityKey == key })
    }

    /** Deletions implied by files currently in the trash folder (covers trash made before the store existed). */
    fun fromTrash(filesDir: File): List<RecordingTombstone> {
        val root = RecordingFiles.trashRoot(filesDir)
        val projectDirs = root.listFiles()?.filter { it.isDirectory } ?: return emptyList()
        return projectDirs.flatMap { dir ->
            dir.listFiles()?.mapNotNull { file ->
                val split = file.name.indexOf(TRASH_NAME_SEPARATOR)
                if (split <= 0 || !RecordingFiles.isMemoFile(file)) return@mapNotNull null
                val deletedAt = file.name.substring(0, split).toLongOrNull() ?: return@mapNotNull null
                RecordingTombstone(dir.name, file.name.substring(split + TRASH_NAME_SEPARATOR.length), deletedAt)
                    .takeIf { runCatching { it.validate() }.isSuccess }
            } ?: emptyList()
        }
    }

    /** Stored tombstones plus those implied by the trash folder, latest deletion per recording. */
    fun all(filesDir: File): List<RecordingTombstone> =
        mergeLatest(read(filesDir) + fromTrash(filesDir))

    internal fun mergeLatest(tombstones: List<RecordingTombstone>): List<RecordingTombstone> =
        tombstones.groupBy { it.identityKey }.values.map { group -> group.maxByOrNull { it.deletedAt }!! }

    private fun write(filesDir: File, tombstones: List<RecordingTombstone>) {
        val target = file(filesDir)
        val temp = File(filesDir, "$FILE_NAME.tmp")
        temp.writeText(json.encodeToString(serializer, tombstones))
        if (!temp.renameTo(target)) {
            target.delete()
            temp.renameTo(target)
        }
    }
}
