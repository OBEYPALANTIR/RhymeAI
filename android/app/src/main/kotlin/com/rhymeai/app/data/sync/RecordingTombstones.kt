package com.rhymeai.app.data.sync

import com.rhymeai.app.data.recording.RecordingFiles
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.security.MessageDigest

/**
 * A deletion record for one recording. Identity is (projectId, fileName, sha256 of the deleted
 * bytes): a newer `modifiedAt` never decides anything, and different bytes under the same name are
 * a different recording. [sha256] is null only while the bytes could not be hashed (pending), in
 * which case the record conservatively covers any bytes with that name.
 *
 * [restoredAt] is set only by an explicit restore or Undo. The record is deleted while
 * `deletedAt >= restoredAt` (a tie resolves to deleted) or when there is no restore.
 */
@Serializable
data class RecordingTombstone(
    val projectId: String,
    val fileName: String,
    val deletedAt: Long,
    val sha256: String? = null,
    val restoredAt: Long? = null
) {
    val identityKey: String
        get() = "$projectId/$fileName"

    val mergeKey: String
        get() = "$identityKey@${sha256 ?: "-"}"

    val isDeleted: Boolean
        get() = restoredAt == null || deletedAt >= restoredAt

    fun validate() {
        SyncIdentity.validateProjectId(projectId)
        SyncIdentity.validateFileName(fileName)
        require(deletedAt >= 0L) { "Invalid recording tombstone time" }
        require(restoredAt == null || restoredAt >= 0L) { "Invalid recording tombstone restore time" }
        require(sha256 == null || (sha256.isNotEmpty() && sha256.length <= 128)) { "Invalid recording tombstone digest" }
    }

    /** True when this record is a live deletion of exactly [entry]'s bytes (or of the name while unhashed). */
    fun suppresses(entry: RecordingManifestEntry): Boolean =
        isDeleted &&
            identityKey == entry.identityKey &&
            (sha256 == null || sha256.equals(entry.sha256, ignoreCase = true))

    companion object {
        /** Union by (identity, digest): latest `deletedAt` and latest `restoredAt` per key. */
        fun merge(tombstones: List<RecordingTombstone>): List<RecordingTombstone> =
            tombstones.groupBy { it.mergeKey }.values.map { group ->
                group.first().copy(
                    deletedAt = group.maxOf { it.deletedAt },
                    restoredAt = group.mapNotNull { it.restoredAt }.maxOrNull()
                )
            }
    }
}

/**
 * This install's own deletion records, persisted so they survive purge, restart and sync. Records
 * are never removed by upload, purge or time; a restore only marks them restored. Unreadable or
 * missing state reads as empty; files still in the trash folder contribute via [fromTrash].
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

    /** Record a deletion. [sha256] is the digest of the bytes moved to the trash, or null if hashing failed. */
    @Synchronized
    fun record(filesDir: File, projectId: String, fileName: String, sha256: String?, deletedAt: Long) {
        val tombstone = RecordingTombstone(projectId, fileName, deletedAt, sha256)
        runCatching { tombstone.validate() }.onFailure { return }
        write(filesDir, mergeLatest(read(filesDir) + tombstone))
    }

    /** Explicit restore or Undo: every record of this recording becomes restored (restoredAt is after its deletedAt). */
    @Synchronized
    fun markRestored(filesDir: File, projectId: String, fileName: String, restoredAt: Long) {
        val key = "$projectId/$fileName"
        val current = read(filesDir)
        if (current.none { it.identityKey == key }) return
        write(filesDir, current.map {
            if (it.identityKey == key) it.copy(restoredAt = maxOf(restoredAt, it.deletedAt + 1L, it.restoredAt ?: 0L)) else it
        })
    }

    /** Retry hashing for records whose bytes could not be hashed when they were trashed. */
    @Synchronized
    fun resolvePending(filesDir: File) {
        val current = read(filesDir)
        val pending = current.filter { it.sha256 == null && it.isDeleted }
        if (pending.isEmpty()) return
        val updated = current.toMutableList()
        var changed = false
        for (record in pending) {
            val trashed = File(
                RecordingFiles.trashDirectory(filesDir, record.projectId),
                "${record.deletedAt}$TRASH_NAME_SEPARATOR${record.fileName}"
            )
            if (!trashed.isFile) continue
            val digest = runCatching { sha256Of(trashed) }.getOrNull() ?: continue
            updated.remove(record)
            updated.add(record.copy(sha256 = digest))
            changed = true
        }
        if (changed) write(filesDir, mergeLatest(updated))
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

    /** Stored records plus those implied by the trash folder. */
    fun all(filesDir: File): List<RecordingTombstone> =
        mergeLatest(read(filesDir) + fromTrash(filesDir))

    internal fun mergeLatest(tombstones: List<RecordingTombstone>): List<RecordingTombstone> =
        RecordingTombstone.merge(tombstones)

    fun sha256Of(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

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
