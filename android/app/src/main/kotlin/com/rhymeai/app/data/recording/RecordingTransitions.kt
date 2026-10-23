package com.rhymeai.app.data.recording

import com.rhymeai.app.data.sync.LocalRecordingFile
import com.rhymeai.app.data.sync.RecordingFileStore
import com.rhymeai.app.data.sync.RecordingManifestEntry
import com.rhymeai.app.data.sync.RecordingRecord
import com.rhymeai.app.data.sync.SyncDeletion
import com.rhymeai.app.data.sync.SyncIdentity
import com.rhymeai.app.data.sync.SyncMerger
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
        catalog?.let { reconcileLocked(it, filesDir) }
        if (skipIfPresent && catalog?.recordingRecords()?.any { it.id == id && it.path != null } == true) {
            return@withLock null
        }
        val dir = RecordingFiles.memoDirectory(filesDir, projectId)
        if (!dir.exists() && !dir.mkdirs()) throw IOException("Could not create memo directory for $projectId")
        val target = File(dir, desiredName).takeUnless { it.exists() }
            ?: RecordingFiles.resolveCollision(dir, desiredName.substringBeforeLast('.'), desiredName.substringAfterLast('.', "m4a"))
        RecordingFiles.memoFile(filesDir, projectId, target.name) // validates the final name before any intent
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
        catalog?.let { reconcileLocked(it, filesDir) }
        val record = catalog?.let { recordForLocked(it, filesDir, from, projectId) ?: return@withLock null }
        val target = pick()
        renamesTo(target)?.let { SyncIdentity.validateFileName(it) }
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

    /**
     * The record of the file at [file], adopting its song's files first (used before a
     * permanent delete). Null when the file turned out to be a duplicate copy and was
     * moved to quarantine (A26).
     */
    suspend fun recordFor(catalog: RecordingCatalog, filesDir: File, file: File, projectId: String): RecordingRecord? =
        namespace.withLock { recordForLocked(catalog, filesDir, file, projectId) }

    /**
     * Gives every live and Trash file of [projectIds] a record before a song deletion
     * or expiry builds its recording tombstones from the records. All or nothing: an
     * unreadable file or folder throws, and the caller must not delete anything.
     */
    suspend fun adopt(catalog: RecordingCatalog, filesDir: File, projectIds: Set<String>) {
        if (projectIds.isNotEmpty()) snapshot(catalog, filesDir, emptySet(), projectIds)
    }

    private suspend fun recordForLocked(catalog: RecordingCatalog, filesDir: File, file: File, projectId: String): RecordingRecord? {
        snapshotLocked(catalog, filesDir, emptySet(), setOf(projectId))
        val path = relativePath(filesDir, file)
        return catalog.recordingRecords().firstOrNull { it.path == path }
    }

    private fun stamp(item: Hashed, id: String) = RecordingRecord(
        id = id,
        projectId = item.projectId,
        fileName = item.displayName,
        uploadedAt = item.file.lastModified(),
        sha256 = item.sha,
        bytes = item.file.length(),
        origin = RecordingRecord.RECORDED,
        path = item.path
    )

    /** A28: recordings that [deletions] remove leave the library for quarantine; returns how many. */
    suspend fun quarantineDeleted(
        catalog: RecordingCatalog,
        filesDir: File,
        deletions: List<SyncDeletion>,
        pendingDeletionIds: Set<String>
    ): Int = namespace.withLock {
        val tombstones = SyncMerger.Tombstones(deletions)
        val gone = snapshotLocked(catalog, filesDir, pendingDeletionIds, null).filter { tombstones.removes(it.entry) }
        if (gone.isEmpty()) return@withLock 0
        // Bytes first: a record left behind for a moved file is dropped by the next snapshot.
        gone.forEach { quarantine(filesDir, it.file, it.entry.projectId, it.entry.fileName) }
        val ids = gone.mapTo(HashSet()) { it.entry.id }
        catalog.updateRecordingRecords { records -> records.filterNot { it.id in ids } }
        gone.size
    }

    /** Moves a duplicate or deleted recording's bytes out of the library, keeping them (A26/A28). */
    internal fun quarantine(filesDir: File, file: File, projectId: String, displayName: String): File {
        val dir = RecordingFiles.quarantineDirectory(filesDir, projectId)
        if (!dir.exists() && !dir.mkdirs()) throw IOException("Could not create recording quarantine folder")
        var stamp = System.currentTimeMillis()
        var target = File(dir, "${stamp}__$displayName")
        while (target.exists()) target = File(dir, "${++stamp}__$displayName")
        Files.move(file.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
        return target
    }

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
     * (no record at its path with its hash) is a pre-v4 recording: it gets the derived
     * legacy id and is stamped once with its file time. Copies sharing one legacy
     * identity are one recording (A26): the live copy keeps the id and the others move
     * to quarantine, so the id never depends on which copy was seen first. Apart from
     * finishing or undoing an interrupted transition first ([reconcile]), this is the
     * only local write a backup makes. All or nothing: an unreadable file or folder
     * throws. Staging and quarantine are never read.
     */
    suspend fun snapshot(
        catalog: RecordingCatalog,
        filesDir: File,
        pendingDeletionIds: Set<String>,
        onlyProjects: Set<String>? = null
    ): List<LocalRecordingFile> = namespace.withLock { snapshotLocked(catalog, filesDir, pendingDeletionIds, onlyProjects) }

    private fun listStrictly(dir: File): List<File> {
        if (!dir.exists()) return emptyList()
        return dir.listFiles()?.toList() ?: throw IOException("Could not list ${dir.name}")
    }

    private suspend fun snapshotLocked(
        catalog: RecordingCatalog,
        filesDir: File,
        pendingDeletionIds: Set<String>,
        onlyProjects: Set<String>?
    ): List<LocalRecordingFile> {
        reconcileLocked(catalog, filesDir)
        val hashed = mutableListOf<Hashed>()
        for ((root, inTrash) in listOf(RecordingFiles.memosRoot(filesDir) to false, RecordingFiles.trashRoot(filesDir) to true)) {
            for (dir in listStrictly(root)) {
                if (!dir.isDirectory || dir.name in pendingDeletionIds || (onlyProjects != null && dir.name !in onlyProjects)) continue
                for (file in listStrictly(dir)) {
                    if (!RecordingFiles.isMemoFile(file)) continue
                    val parsed = if (inTrash) VoiceMemoService.parseTrashedName(file.name) ?: continue else null
                    val displayName = parsed?.second ?: file.name
                    RecordingFiles.memoFile(filesDir, dir.name, displayName) // validates the names; throws
                    hashed += Hashed(file, relativePath(filesDir, file), dir.name, displayName,
                        RecordingFileStore.sha256Hex(file), inTrash, parsed?.first ?: 0L)
                }
            }
        }
        val result = mutableListOf<LocalRecordingFile>()
        val quarantined = mutableListOf<Hashed>()
        catalog.updateRecordingRecords { records ->
            result.clear()
            quarantined.clear()
            val byPath = records.filter { it.path != null }.associateBy { it.path }
            val hashedPaths = hashed.mapTo(HashSet()) { it.path }
            fun matches(item: Hashed) = byPath[item.path]?.takeIf { it.sha256 == item.sha && it.bytes == item.file.length() }
            // Records that keep their bytes: matched ones and those of files on disk but not listed here.
            val holders = LinkedHashMap<String, RecordingRecord>()
            records.filter { it.path != null && it.path !in hashedPaths && File(filesDir, it.path).isFile }
                .forEach { holders[it.id] = it }
            val itemFor = HashMap<String, Hashed>()
            hashed.forEach { item -> matches(item)?.let { holders[it.id] = it; itemFor[it.id] = item } }
            // First sight: the live copy first, then the most recently trashed.
            val unmatched = hashed.filter { matches(it) == null }
                .sortedWith(compareBy<Hashed> { it.inTrash }.thenByDescending { it.trashedAt })
            for (item in unmatched) {
                val id = RecordingManifestEntry.legacyRecordingId(item.projectId, item.displayName, item.sha)
                val holder = holders[id]
                val holderItem = itemFor[id]
                when {
                    holder == null -> { holders[id] = stamp(item, id); itemFor[id] = item }
                    // A live copy takes over the id from a Trash copy, keeping its time.
                    !item.inTrash && holderItem != null && holderItem.inTrash -> {
                        quarantined += holderItem
                        holders[id] = holder.copy(path = item.path, fileName = item.displayName)
                        itemFor[id] = item
                    }
                    else -> quarantined += item
                }
            }
            for ((id, record) in holders) itemFor[id]?.let { result += LocalRecordingFile(record.toEntry(), it.file, it.inTrash) }
            // Records whose bytes left this device go.
            holders.values.toList()
        }
        for (item in quarantined) quarantine(filesDir, item.file, item.projectId, item.displayName)
        return result.sortedWith(compareBy<LocalRecordingFile> { it.inTrash }.thenBy { it.entry.projectId }.thenBy { it.entry.fileName })
    }

    private class Hashed(
        val file: File,
        val path: String,
        val projectId: String,
        val displayName: String,
        val sha: String,
        val inTrash: Boolean,
        val trashedAt: Long
    )
}
