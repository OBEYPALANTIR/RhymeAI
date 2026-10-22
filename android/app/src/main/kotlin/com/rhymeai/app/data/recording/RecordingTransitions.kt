package com.rhymeai.app.data.recording

import com.rhymeai.app.data.sync.LocalRecordingFile
import com.rhymeai.app.data.sync.RecordingFileStore
import com.rhymeai.app.data.sync.RecordingManifestEntry
import com.rhymeai.app.data.sync.RecordingRecord
import com.rhymeai.app.service.VoiceMemoService
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/** Where recording records (A20/A21) are persisted; the app's is [com.rhymeai.app.data.repository.ProjectRepository]. */
interface RecordingCatalog {
    suspend fun recordingRecords(): List<RecordingRecord>

    /** Replaces the records in one write; throws when the write fails. */
    suspend fun updateRecordingRecords(transform: (List<RecordingRecord>) -> List<RecordingRecord>)
}

internal suspend fun RecordingCatalog.putRecord(record: RecordingRecord) =
    updateRecordingRecords { records -> records.filterNot { it.id == record.id } + record }

internal suspend fun RecordingCatalog.removeRecord(id: String) =
    updateRecordingRecords { records -> records.filterNot { it.id == id } }

/**
 * Every change to the published recording folders (record, import, Drive restore,
 * archive import, rename, Trash, restore from Trash) and every backup snapshot runs
 * under one [namespace] lock, so a name is checked and taken in one step and a
 * snapshot never sees half a transition. Each transition writes its record intent
 * before touching the file (A24); [reconcile] finishes or undoes an interrupted one.
 */
internal object RecordingTransitions {
    val namespace = Mutex()

    fun relativePath(filesDir: File, file: File): String = file.canonicalFile.relativeTo(filesDir.canonicalFile).path

    /**
     * Moves a complete, verified file from staging into the project's memo folder,
     * under [desiredName] or a free variant, with its record. Returns null when
     * [skipIfPresent] and this device already holds the recording [id].
     */
    suspend fun publish(
        catalog: RecordingCatalog?,
        filesDir: File,
        source: File,
        projectId: String,
        desiredName: String,
        id: String,
        uploadedAt: Long,
        origin: String,
        skipIfPresent: Boolean = false
    ): File? = namespace.withLock {
        if (skipIfPresent && catalog?.recordingRecords()?.any { it.id == id && it.path != null } == true) {
            return@withLock null
        }
        val dir = RecordingFiles.memoDirectory(filesDir, projectId)
        if (!dir.exists() && !dir.mkdirs()) throw IOException("Could not create memo directory for $projectId")
        val target = File(dir, desiredName).takeUnless { it.exists() }
            ?: RecordingFiles.resolveCollision(dir, desiredName.substringBeforeLast('.'), desiredName.substringAfterLast('.', "m4a"))
        val record = RecordingRecord(
            id, projectId, target.name, uploadedAt, RecordingFileStore.sha256Hex(source), source.length(), origin,
            path = relativePath(filesDir, target),
            pendingFrom = relativePath(filesDir, source),
            pendingOp = RecordingRecord.OP_PUBLISH
        )
        catalog?.putRecord(record)
        try {
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (e: Exception) {
            runCatching { catalog?.removeRecord(id) }
            throw e
        }
        catalog?.putRecord(record.copy(pendingFrom = null, pendingOp = null))
        target
    }

    /**
     * Rename, move to Trash or restore from Trash: [pick] chooses the free target
     * under the lock; the record keeps its id and time and changes only its path and,
     * when [renamesTo] gives one, its file name. A file with no record is stamped first.
     */
    suspend fun move(
        catalog: RecordingCatalog?,
        filesDir: File,
        from: File,
        projectId: String,
        displayName: String,
        pick: () -> File,
        renamesTo: (File) -> String?
    ): File? = namespace.withLock {
        val record = catalog?.let { recordForLocked(it, filesDir, from, projectId, displayName) }
        val target = pick()
        val intent = record?.copy(
            fileName = renamesTo(target) ?: record.fileName,
            path = relativePath(filesDir, target),
            pendingFrom = record.path,
            pendingFromName = record.fileName,
            pendingOp = RecordingRecord.OP_MOVE
        )
        if (intent != null) catalog.putRecord(intent)
        if (!from.renameTo(target)) {
            if (record != null) catalog.putRecord(record)
            return@withLock null
        }
        if (intent != null) catalog.putRecord(intent.copy(pendingFrom = null, pendingFromName = null, pendingOp = null))
        target
    }

    /** The record of the file at [file], stamping it once if it has none (used before a permanent delete). */
    suspend fun recordFor(catalog: RecordingCatalog, filesDir: File, file: File, projectId: String, displayName: String): RecordingRecord =
        namespace.withLock { recordForLocked(catalog, filesDir, file, projectId, displayName) }

    private suspend fun recordForLocked(
        catalog: RecordingCatalog,
        filesDir: File,
        file: File,
        projectId: String,
        displayName: String
    ): RecordingRecord {
        val path = relativePath(filesDir, file)
        val sha = RecordingFileStore.sha256Hex(file)
        catalog.recordingRecords().firstOrNull { it.path == path && it.pendingOp == null && it.sha256 == sha }?.let { return it }
        return stamp(file, path, sha, projectId, displayName).also { catalog.putRecord(it) }
    }

    private fun stamp(file: File, path: String, sha: String, projectId: String, displayName: String) = RecordingRecord(
        id = RecordingManifestEntry.newRecordingId(),
        projectId = projectId,
        fileName = displayName,
        uploadedAt = file.lastModified(),
        sha256 = sha,
        bytes = file.length(),
        origin = RecordingRecord.RECORDED,
        path = path
    )

    /** A24: finishes a move whose file reached its target, undoes one that did not. */
    suspend fun reconcile(catalog: RecordingCatalog, filesDir: File) = namespace.withLock { reconcileLocked(catalog, filesDir) }

    private suspend fun reconcileLocked(catalog: RecordingCatalog, filesDir: File) {
        if (catalog.recordingRecords().none { it.pendingOp != null }) return
        catalog.updateRecordingRecords { records ->
            records.mapNotNull { record ->
                if (record.pendingOp == null) return@mapNotNull record
                val target = record.path?.let { File(filesDir, it) }
                val source = record.pendingFrom?.let { File(filesDir, it) }
                when {
                    target != null && target.isFile && RecordingFileStore.sha256Hex(target) == record.sha256 ->
                        record.copy(pendingFrom = null, pendingFromName = null, pendingOp = null)
                    record.pendingOp == RecordingRecord.OP_MOVE && source != null && source.isFile -> record.copy(
                        path = record.pendingFrom,
                        fileName = record.pendingFromName ?: record.fileName,
                        pendingFrom = null, pendingFromName = null, pendingOp = null
                    )
                    else -> null
                }
            }
        }
    }

    /**
     * Live and Trash recordings with their records. A file seen for the first time
     * (no record at its path with its hash) is stamped once with its file time; this
     * stamping is the only local write a backup makes. Staging folders are never read.
     */
    suspend fun snapshot(
        catalog: RecordingCatalog,
        filesDir: File,
        pendingDeletionIds: Set<String>
    ): List<LocalRecordingFile> = namespace.withLock {
        reconcileLocked(catalog, filesDir)
        val found = mutableListOf<Triple<File, Pair<String, String>, Boolean>>()
        RecordingFiles.memosRoot(filesDir).listFiles().orEmpty()
            .filter { it.isDirectory && it.name !in pendingDeletionIds }
            .forEach { dir ->
                dir.listFiles().orEmpty().filter { RecordingFiles.isMemoFile(it) }
                    .forEach { found += Triple(it, dir.name to it.name, false) }
            }
        RecordingFiles.trashRoot(filesDir).listFiles().orEmpty()
            .filter { it.isDirectory && it.name !in pendingDeletionIds }
            .forEach { dir ->
                dir.listFiles().orEmpty().filter { RecordingFiles.isMemoFile(it) }.forEach { file ->
                    val original = VoiceMemoService.parseTrashedName(file.name)?.second ?: return@forEach
                    found += Triple(file, dir.name to original, true)
                }
            }
        val hashed = found.mapNotNull { (file, identity, inTrash) ->
            runCatching {
                RecordingFiles.memoFile(filesDir, identity.first, identity.second) // validates the names
                Hashed(file, relativePath(filesDir, file), identity.first, identity.second, RecordingFileStore.sha256Hex(file), inTrash)
            }.getOrNull()
        }
        val result = mutableListOf<LocalRecordingFile>()
        catalog.updateRecordingRecords { records ->
            result.clear()
            val byPath = records.filter { it.path != null }.associateBy { it.path }
            val kept = ArrayList<RecordingRecord>()
            for (item in hashed) {
                val existing = byPath[item.path]
                val record = if (existing != null && existing.sha256 == item.sha && existing.bytes == item.file.length()) {
                    existing
                } else {
                    stamp(item.file, item.path, item.sha, item.projectId, item.displayName)
                }
                kept += record
                result += LocalRecordingFile(record.toEntry(), item.file, item.inTrash)
            }
            val seen = hashed.mapTo(HashSet()) { it.path }
            // Records of files still on disk but not listed (songs pending deletion) stay;
            // records whose bytes left this device go.
            kept + records.filter { it.path != null && it.path !in seen && File(filesDir, it.path).isFile }
        }
        result.sortedWith(compareBy<LocalRecordingFile> { it.inTrash }.thenBy { it.entry.projectId }.thenBy { it.entry.fileName })
    }

    private class Hashed(
        val file: File,
        val path: String,
        val projectId: String,
        val displayName: String,
        val sha: String,
        val inTrash: Boolean
    )
}
