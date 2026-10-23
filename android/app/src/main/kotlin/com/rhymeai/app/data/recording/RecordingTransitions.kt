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
import java.nio.file.attribute.BasicFileAttributes
import java.util.Locale

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

    private fun stamp(item: Hashed, id: String, uploadedAt: Long) = RecordingRecord(
        id = id,
        projectId = item.projectId,
        fileName = item.displayName,
        uploadedAt = uploadedAt,
        sha256 = item.sha,
        bytes = item.size,
        origin = RecordingRecord.ADOPTED,
        path = item.path
    )

    /**
     * A28: paths of recordings that a known winning tombstone removes. They stay hidden
     * from the recordings lists until [quarantineDeleted] has moved them.
     */
    fun deletedPaths(records: List<RecordingRecord>, deletions: List<SyncDeletion>): Set<String> {
        val tombstones = SyncMerger.Tombstones(deletions)
        return records.mapNotNullTo(HashSet()) { record -> record.path?.takeIf { tombstones.removes(record.toEntry()) } }
    }

    /**
     * A28: recordings that [deletions] remove leave the library for quarantine; returns
     * how many. The committed tombstones are the durable intent: this runs after Restore
     * and Import and again at every launch, so an interrupted or failed move is retried.
     */
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

    /** A missing folder is empty; any other failure to list it throws. */
    private fun listStrictly(dir: File): List<File> = try {
        Files.newDirectoryStream(dir.toPath()).use { entries -> entries.map { it.toFile() } }
    } catch (_: java.nio.file.NoSuchFileException) {
        emptyList()
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
                if (dir.name in pendingDeletionIds || (onlyProjects != null && dir.name !in onlyProjects)) continue
                // Throwing metadata reads: a file whose attributes cannot be read aborts adoption.
                if (!Files.readAttributes(dir.toPath(), BasicFileAttributes::class.java).isDirectory) continue
                for (file in listStrictly(dir)) {
                    val attributes = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
                    if (!attributes.isRegularFile || file.extension.lowercase(Locale.ROOT) !in RecordingFiles.SUPPORTED_AUDIO_EXTENSIONS) continue
                    val parsed = if (inTrash) VoiceMemoService.parseTrashedName(file.name) ?: continue else null
                    val displayName = parsed?.second ?: file.name
                    RecordingFiles.memoFile(filesDir, dir.name, displayName) // validates the names; throws
                    hashed += Hashed(file, relativePath(filesDir, file), dir.name, displayName,
                        RecordingFileStore.sha256Hex(file), inTrash, parsed?.first ?: 0L,
                        attributes.size(), attributes.lastModifiedTime().toMillis())
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
            fun matches(item: Hashed) = byPath[item.path]?.takeIf { it.sha256 == item.sha && it.bytes == item.size }
            // Records of files on disk but not listed here (songs pending deletion) keep their bytes.
            val kept = records.filter { it.path != null && it.path !in hashedPaths && File(filesDir, it.path).isFile }
                .associateByTo(LinkedHashMap()) { it.id }
            // A26: every copy of one recording, matched or seen for the first time, is a candidate.
            val groups = hashed.groupBy { item ->
                matches(item)?.id ?: RecordingManifestEntry.legacyRecordingId(item.projectId, item.displayName, item.sha)
            }
            for ((id, candidates) in groups) {
                // Order-independent choice: a live copy, else the most recently trashed, then by name.
                val canonical = candidates.sortedWith(
                    compareBy<Hashed> { it.inTrash }.thenByDescending { it.trashedAt }.thenBy { it.path }
                ).first()
                quarantined += candidates.filter { it !== canonical }
                val existing = kept[id] ?: candidates.firstNotNullOfOrNull { matches(it) }
                val earliest = candidates.minOf { it.modifiedAt }
                val record = when {
                    existing == null -> stamp(canonical, id, earliest)
                    // An adopted file's time is the earliest of its copies; other times are kept as stored.
                    existing.origin == RecordingRecord.ADOPTED ->
                        existing.copy(path = canonical.path, fileName = canonical.displayName, uploadedAt = minOf(existing.uploadedAt, earliest))
                    existing.path == canonical.path -> existing
                    else -> existing.copy(path = canonical.path, fileName = canonical.displayName)
                }
                kept[id] = record
                result += LocalRecordingFile(record.toEntry(), canonical.file, canonical.inTrash)
            }
            kept.values.toList()
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
        val trashedAt: Long,
        val size: Long,
        val modifiedAt: Long
    )
}
