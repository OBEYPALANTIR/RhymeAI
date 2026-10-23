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

    /**
     * A33: throws unless the sync deletions (the tombstones that are also the quarantine
     * intent) can be read and are valid. No adoption, reconciliation or move happens otherwise.
     */
    suspend fun requireDeletionsReadable() {}
}

internal suspend fun RecordingCatalog.putRecord(record: RecordingRecord) =
    updateRecordingRecords { records -> records.filterNot { it.id == record.id } + record }

internal suspend fun RecordingCatalog.removeRecord(id: String) =
    updateRecordingRecords { records -> records.filterNot { it.id == id } }

/**
 * A36: every recording file is named `<id>.<ext>`, live, in Trash, in staging and in
 * quarantine; the name the user sees is the record's display name. So the only moves
 * are staging → live (publish), live ⇄ Trash, live or Trash → quarantine, and the
 * one-time migration of a pre-A36 file to its id name. All of them, and every backup
 * snapshot, run under one [namespace] lock; each writes its record intent (expected
 * id, digest, source) before touching the file, and [reconcile] finishes or undoes an
 * interrupted one from that intent. Lock order: this lock first, then the repository's.
 */
internal object RecordingTransitions {
    val namespace = Mutex()

    /**
     * Called before a recording's bytes move, with the ids concerned, so playback of
     * them stops in the same step. Set by the app to the voice memo service; null in tests.
     */
    @Volatile var beforeBytesMove: (suspend (Set<String>) -> Unit)? = null

    fun relativePath(filesDir: File, file: File): String = file.canonicalFile.relativeTo(filesDir.canonicalFile).path

    /**
     * Moves a complete, verified file from staging to `<id>.<ext>` in the song's memo
     * folder, with its record. Returns null when [skipIfPresent] and this device already
     * holds the recording [id].
     */
    suspend fun publish(
        catalog: RecordingCatalog?,
        filesDir: File,
        source: File,
        projectId: String,
        displayName: String,
        id: String,
        uploadedAt: Long,
        origin: String,
        skipIfPresent: Boolean = false,
        /** A37: [uploadedAt] is a first-seen repair; it stays one through publication. */
        repaired: Boolean = false
    ): File? = namespace.withLock {
        catalog?.let { reconcileLocked(it, filesDir) }
        if (skipIfPresent && catalog?.recordingRecords()?.any { it.id == id && it.path != null } == true) {
            return@withLock null
        }
        SyncIdentity.validateDisplayName(displayName)
        val dir = RecordingFiles.memoDirectory(filesDir, projectId)
        if (!dir.exists() && !dir.mkdirs()) throw IOException("Could not create memo directory for $projectId")
        val target = RecordingFiles.memoFile(filesDir, projectId, id, displayName)
        // Never replace a file: the id's name is taken only by that recording.
        if (target.exists() || isRegularFileStrictly(target)) throw java.nio.file.FileAlreadyExistsException(target.path)
        val record = RecordingRecord(
            id, projectId, displayName, uploadedAt, RecordingFileStore.sha256Hex(source), source.length(), origin,
            precedenceRepaired = repaired,
            path = relativePath(filesDir, target),
            pendingFrom = relativePath(filesDir, source),
            pendingOp = RecordingRecord.OP_PUBLISH
        )
        catalog?.putRecord(record)
        try {
            moveNoReplace(source, target)
        } catch (e: Exception) {
            runCatching { catalog?.removeRecord(id) }
            throw e
        }
        catalog?.putRecord(record.copy(pendingFrom = null, pendingOp = null))
        target
    }

    /** Moves a live recording to Trash at [trashedAt]; the file keeps its id name. Null when it is not a known recording. */
    suspend fun moveToTrash(catalog: RecordingCatalog?, filesDir: File, file: File, projectId: String, trashedAt: Long): File? =
        namespace.withLock { moveLocked(catalog, filesDir, file, projectId, toTrash = true, trashedAt = trashedAt) }

    /** Moves a recording from Trash back to the song's memo folder. Null when it is not a known recording. */
    suspend fun restoreFromTrash(catalog: RecordingCatalog?, filesDir: File, file: File, projectId: String): File? =
        namespace.withLock { moveLocked(catalog, filesDir, file, projectId, toTrash = false, trashedAt = null) }

    private suspend fun moveLocked(
        catalog: RecordingCatalog?,
        filesDir: File,
        from: File,
        projectId: String,
        toTrash: Boolean,
        trashedAt: Long?
    ): File? {
        catalog?.let { reconcileLocked(it, filesDir) }
        if (catalog == null) {
            // Tests without a catalog: the file already carries its id name.
            val id = RecordingFiles.idOf(from) ?: return null
            val target = if (toTrash) RecordingFiles.trashFile(filesDir, projectId, id, from.name) else RecordingFiles.memoFile(filesDir, projectId, id, from.name)
            target.parentFile?.mkdirs()
            return target.takeIf { runCatching { moveNoReplace(from, it) }.isSuccess }
        }
        // Adoption hashes the song's files: the record is for these exact bytes.
        val record = recordForLocked(catalog, filesDir, from, projectId) ?: return null
        // Adoption may just have given a pre-A36 file its id name: move the file where it is now.
        val current = RecordingFiles.fileAt(filesDir, record.path ?: return null)
        val target = if (toTrash) RecordingFiles.trashFile(filesDir, projectId, record.id, record.displayName)
        else RecordingFiles.memoFile(filesDir, projectId, record.id, record.displayName)
        // Never replace a file.
        if (target.exists() || isRegularFileStrictly(target)) return null
        beforeBytesMove?.invoke(setOf(record.id))
        val intent = record.copy(
            path = relativePath(filesDir, target),
            trashedAt = trashedAt,
            pendingFrom = record.path,
            pendingTrashedAt = record.trashedAt,
            pendingOp = RecordingRecord.OP_MOVE
        )
        catalog.putRecord(intent)
        target.parentFile?.let { if (!it.exists()) it.mkdirs() }
        try {
            moveNoReplace(current, target)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: IOException) {
            catalog.putRecord(record)
            return null
        }
        catalog.putRecord(intent.copy(pendingFrom = null, pendingTrashedAt = null, pendingOp = null))
        return target
    }

    /**
     * A rename is metadata only (A36): the record's display name changes, nothing on
     * disk does. Gated like every other change (A33). Null when the file has no record.
     */
    suspend fun rename(catalog: RecordingCatalog, filesDir: File, file: File, projectId: String, displayName: String): RecordingRecord? =
        namespace.withLock {
            SyncIdentity.validateDisplayName(displayName)
            val record = recordForLocked(catalog, filesDir, file, projectId) ?: return@withLock null
            val renamed = record.copy(displayName = displayName, displayNameChanged = true)
            catalog.putRecord(renamed)
            renamed
        }

    /**
     * A28: runs [start] with the verified id of the recording at [file] while holding the
     * namespace lock, so no transition can move its bytes between the check and the start
     * (a transition stops playback through [beforeBytesMove] under the same lock). Adopts
     * the song's files first, so a file seen for the first time gets its identity. Returns
     * null without running [start] when the file has no verified identity, has a move or
     * save not yet reconciled, a known tombstone removes it, or the state cannot be read.
     */
    suspend fun <T> withPlayableRecording(
        catalog: RecordingCatalog,
        filesDir: File,
        file: File,
        projectId: String,
        deletions: suspend () -> List<SyncDeletion>,
        start: suspend (id: String, file: File) -> T
    ): T? = namespace.withLock {
        val record = try {
            recordForLocked(catalog, filesDir, file, projectId)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        } ?: return@withLock null
        if (record.pendingOp != null) return@withLock null
        val removed = try {
            SyncMerger.Tombstones(deletions()).removes(record.toEntry())
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            true
        }
        if (removed) null else start(record.id, RecordingFiles.fileAt(filesDir, record.path ?: return@withLock null))
    }

    /**
     * Permanently deletes recording [id]'s file if, under the lock and after reconciliation,
     * it still holds the recorded bytes; the record goes with it. False otherwise.
     */
    suspend fun deleteVerified(catalog: RecordingCatalog, filesDir: File, id: String): Boolean = namespace.withLock {
        reconcileLocked(catalog, filesDir)
        val record = catalog.recordingRecords().firstOrNull { it.id == id } ?: return@withLock false
        val file = RecordingFiles.fileAt(filesDir, record.path ?: return@withLock false)
        if (!isRegularFileStrictly(file) || RecordingFileStore.sha256Hex(file) != record.sha256) return@withLock false
        beforeBytesMove?.invoke(setOf(id))
        if (!file.delete()) return@withLock false
        catalog.removeRecord(id)
        true
    }

    /**
     * Whole-song cleanup after a song deletion committed: under the lock, the song's live
     * and Trash files are adopted (hashed) and only recordings a winning tombstone in
     * [deletions] removes are deleted, each verified by its digest just now. Any other
     * bytes (a take that finished after the deletion, a file dropped in) are kept.
     * Returns true when nothing of the song is left in its live and Trash folders.
     */
    suspend fun cleanUpDeletedSong(
        catalog: RecordingCatalog,
        filesDir: File,
        projectId: String,
        deletions: List<SyncDeletion>
    ): Boolean = namespace.withLock {
        val tombstones = SyncMerger.Tombstones(deletions)
        val scan = snapshotLocked(catalog, filesDir, emptySet(), setOf(projectId))
        val covered = scan.files.filter { tombstones.removes(it.entry) }
        if (covered.isNotEmpty()) beforeBytesMove?.invoke(covered.mapTo(HashSet()) { it.entry.id })
        for (item in covered) {
            if (!item.file.delete()) return@withLock false
        }
        val ids = covered.mapTo(HashSet()) { it.entry.id }
        if (ids.isNotEmpty()) catalog.updateRecordingRecords { records -> records.filterNot { it.id in ids } }
        val live = RecordingFiles.memoDirectory(filesDir, projectId)
        val trash = RecordingFiles.trashDirectory(filesDir, projectId)
        val left = listStrictly(live) + listStrictly(trash)
        if (left.isNotEmpty() || scan.files.size != covered.size || scan.leftInPlace.isNotEmpty()) return@withLock false
        live.delete()
        trash.delete()
        true
    }

    /**
     * The record of the file at [file], adopting its song's files first (used before a
     * move or a permanent delete). Null when the file turned out to be a duplicate copy
     * and was moved to quarantine (A26), or is a pre-A36 file left in place.
     */
    suspend fun recordFor(catalog: RecordingCatalog, filesDir: File, file: File, projectId: String): RecordingRecord? =
        namespace.withLock { recordForLocked(catalog, filesDir, file, projectId) }

    /**
     * Gives every live and Trash file of [projectIds] a record (and its id name) before a
     * song deletion or expiry builds its recording tombstones from the records. All or
     * nothing: an unreadable file or folder throws, and the caller must not delete anything.
     */
    suspend fun adopt(catalog: RecordingCatalog, filesDir: File, projectIds: Set<String>) {
        if (projectIds.isNotEmpty()) snapshot(catalog, filesDir, emptySet(), projectIds)
    }

    /**
     * A36 migration, run at every launch (idempotent, journaled through the move intents):
     * every pre-A36 file gets its id name with its old name as display name. Returns the
     * files left in place because their id name is taken by different bytes.
     */
    suspend fun migrate(catalog: RecordingCatalog, filesDir: File): List<File> =
        namespace.withLock {
            // A33: nothing moves, quarantine included, unless the deletion state is readable.
            reconcileLocked(catalog, filesDir)
            migrateQuarantineLocked(filesDir) + snapshotLocked(catalog, filesDir, emptySet(), null).leftInPlace
        }

    /**
     * A36 for quarantine: a pre-A36 kept copy `<movedAt>__<name>` moves to
     * `<movedAt>/<id>.<ext>` in its song's quarantine folder (the derived A21 id of its name
     * and bytes). One atomic rename that never replaces a file; one whose target exists stays.
     */
    private fun migrateQuarantineLocked(filesDir: File): List<File> {
        val left = mutableListOf<File>()
        for (dir in listStrictly(RecordingFiles.quarantineRoot(filesDir))) {
            if (!isDirectoryStrictly(dir)) continue
            // Each move is journaled first (source, target, id, SHA-256, length): a run after a
            // crash removes an empty claim, then finishes or redoes the move from the journal.
            for (journal in listStrictly(dir).filter { it.name.endsWith(QUARANTINE_JOURNAL_SUFFIX) }) {
                val lines = journal.readLines()
                val source = File(dir, lines.getOrNull(0) ?: continue)
                val target = File(dir, lines.getOrNull(1) ?: continue)
                val sha = lines.getOrNull(3) ?: continue
                val length = lines.getOrNull(4)?.toLongOrNull() ?: continue
                fun holds(file: File) = isRegularFileStrictly(file) && file.length() == length && RecordingFileStore.sha256Hex(file) == sha
                if (length > 0L && isRegularFileStrictly(target) && target.length() == 0L) target.delete()
                when {
                    holds(target) || holds(source) -> journal.delete()
                    else -> left += source
                }
            }
            for (file in listStrictly(dir)) {
                if (!isRegularFileStrictly(file) || file.name.endsWith(QUARANTINE_JOURNAL_SUFFIX) ||
                    file.name.endsWith("$QUARANTINE_JOURNAL_SUFFIX.tmp")) continue
                val (movedAt, name) = VoiceMemoService.parseTrashedName(file.name) ?: (file.lastModified() to file.name)
                val sha = RecordingFileStore.sha256Hex(file)
                val length = file.length()
                val id = RecordingManifestEntry.legacyRecordingId(dir.name, name, sha)
                val target = File(File(dir, movedAt.toString()), RecordingFiles.idFileName(id, name))
                val journal = File(dir, file.name + QUARANTINE_JOURNAL_SUFFIX)
                if (target.exists() || isRegularFileStrictly(target) || journal.exists()) {
                    left += file
                    continue
                }
                val temp = File(dir, journal.name + ".tmp")
                temp.writeText("${file.name}\n${target.relativeTo(dir).path}\n$id\n$sha\n$length\n")
                Files.move(temp.toPath(), journal.toPath(), StandardCopyOption.ATOMIC_MOVE)
                target.parentFile?.mkdirs()
                try {
                    moveNoReplace(file, target)
                } catch (_: java.nio.file.FileAlreadyExistsException) {
                    left += file
                }
                journal.delete()
            }
        }
        return left
    }

    private const val QUARANTINE_JOURNAL_SUFFIX = ".migrate"

    private suspend fun recordForLocked(catalog: RecordingCatalog, filesDir: File, file: File, projectId: String): RecordingRecord? {
        val scan = snapshotLocked(catalog, filesDir, emptySet(), setOf(projectId))
        // The file may just have been given its id name.
        val path = relativePath(filesDir, file)
        return scan.files.firstOrNull { relativePath(filesDir, it.file) == path || it.originalPath == path }
            ?.let { found -> catalog.recordingRecords().firstOrNull { it.id == found.entry.id } }
    }

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
        val gone = snapshotLocked(catalog, filesDir, pendingDeletionIds, null).files.filter { tombstones.removes(it.entry) }
        if (gone.isEmpty()) return@withLock 0
        beforeBytesMove?.invoke(gone.mapTo(HashSet()) { it.entry.id })
        // Bytes first: a record left behind for a moved file is dropped by the next snapshot.
        gone.forEach { quarantine(filesDir, it.file, it.entry.projectId, it.entry.id) }
        val ids = gone.mapTo(HashSet()) { it.entry.id }
        catalog.updateRecordingRecords { records -> records.filterNot { it.id in ids } }
        gone.size
    }

    /**
     * Moves a duplicate or deleted recording's bytes out of the library, keeping them
     * (A26/A28), as `<id>.<ext>` in a folder of its own, so two kept copies never collide.
     */
    internal fun quarantine(filesDir: File, file: File, projectId: String, id: String): File {
        val root = RecordingFiles.quarantineDirectory(filesDir, projectId)
        var stamp = System.currentTimeMillis()
        var dir = File(root, stamp.toString())
        while (dir.exists()) dir = File(root, (++stamp).toString())
        if (!dir.mkdirs()) throw IOException("Could not create recording quarantine folder")
        val target = File(dir, RecordingFiles.idFileName(id, file.name))
        moveNoReplace(file, target)
        return target
    }

    /**
     * Moves [source] to [target] without ever replacing a file there (A5/A16). A rename
     * (`Files.move` with ATOMIC_MOVE, `File.renameTo`, `Os.rename`) replaces an existing
     * target, and hard links are refused in app storage, so the target is first claimed
     * with an exclusive create (O_CREAT|O_EXCL): if anything is there, nothing moves and
     * [java.nio.file.FileAlreadyExistsException] is thrown. The rename then replaces only
     * that empty claim. A claim a crash leaves behind is removed by reconciliation.
     */
    internal fun moveNoReplace(source: File, target: File) {
        if (!target.createNewFile()) throw java.nio.file.FileAlreadyExistsException(target.path)
        try {
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (e: Exception) {
            if (target.length() == 0L) target.delete()
            throw e
        }
    }

    /** Whether [file] is a regular file; only confirmed absence is false, and a file that cannot be examined throws. */
    internal fun isRegularFileStrictly(file: File): Boolean = try {
        Files.readAttributes(file.toPath(), BasicFileAttributes::class.java).isRegularFile
    } catch (_: java.nio.file.NoSuchFileException) {
        false
    }

    /** Whether [file] is a directory; only confirmed absence is false, a failed read throws. */
    internal fun isDirectoryStrictly(file: File): Boolean = try {
        Files.readAttributes(file.toPath(), BasicFileAttributes::class.java).isDirectory
    } catch (_: java.nio.file.NoSuchFileException) {
        false
    }

    /** True only when [file] is confirmed not to exist; a file that cannot be examined is not absent. */
    internal fun isConfirmedAbsent(file: File): Boolean = try {
        Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
        false
    } catch (_: java.nio.file.NoSuchFileException) {
        true
    } catch (_: IOException) {
        false
    }

    /** A24: finishes a move whose file reached its target, undoes one that did not. */
    suspend fun reconcile(catalog: RecordingCatalog, filesDir: File) = namespace.withLock { reconcileLocked(catalog, filesDir) }

    private suspend fun reconcileLocked(catalog: RecordingCatalog, filesDir: File, mutateFiles: Boolean = true) {
        // A33: every adoption, reconciliation and move starts here; none runs on unreadable tombstones.
        catalog.requireDeletionsReadable()
        val pending = catalog.recordingRecords().filter { it.pendingOp != null }
        if (pending.isEmpty()) return
        // An empty file at a journaled target is the exclusive claim of a move a crash interrupted.
        // Removing it is a file change, so a read-only pass (Back up, export) leaves that intent pending.
        fun claimed(record: RecordingRecord): Boolean {
            val target = record.path?.let { RecordingFiles.fileAt(filesDir, it) } ?: return false
            return record.bytes > 0L && isRegularFileStrictly(target) && target.length() == 0L
        }
        val unresolved = HashSet<String>()
        for (record in pending) {
            if (!claimed(record)) continue
            if (mutateFiles) RecordingFiles.fileAt(filesDir, record.path!!).delete() else unresolved += record.id
        }
        catalog.updateRecordingRecords { records ->
            records.mapNotNull { record ->
                if (record.pendingOp == null || record.id in unresolved) return@mapNotNull record
                val target = record.path?.let { RecordingFiles.fileAt(filesDir, it) }
                val source = record.pendingFrom?.let { RecordingFiles.fileAt(filesDir, it) }
                when {
                    // The expected id's bytes at the target: the move happened. Strict checks: a file
                    // that cannot be examined throws here and nothing is committed.
                    target != null && isRegularFileStrictly(target) && RecordingFileStore.sha256Hex(target) == record.sha256 ->
                        record.copy(pendingFrom = null, pendingTrashedAt = null, pendingOp = null, pendingFromName = null)
                    // Undo only onto the same bytes; anything else at the source is adopted on its own.
                    record.pendingOp == RecordingRecord.OP_MOVE && source != null && isRegularFileStrictly(source) &&
                        RecordingFileStore.sha256Hex(source) == record.sha256 -> record.copy(
                        path = record.pendingFrom,
                        trashedAt = record.pendingTrashedAt,
                        displayName = record.pendingFromName ?: record.displayName,
                        pendingFrom = null, pendingTrashedAt = null, pendingOp = null, pendingFromName = null
                    )
                    else -> null
                }
            }
        }
    }

    /**
     * Live and Trash recordings with their records. A file named by an id whose record
     * matches its bytes is that recording. Any other file is adopted: a pre-A36 file keeps
     * the id its record had at that path, else gets the derived legacy id (A21), and is
     * renamed to `<id>.<ext>` with its old name as display name (A36 migration); a file
     * whose bytes differ from its id's record is adopted on its own. Copies sharing one id
     * are one recording (A26): the live copy, else the most recently trashed, stays and the
     * others move to quarantine. An adopted file's time is the earliest file time among its
     * new copies; a stamped time never changes (A20). All or nothing: an unreadable file or
     * folder throws. Staging and quarantine are never read.
     *
     * With [moveFiles] false (Back up, export: A17, the file system is read only) nothing is
     * migrated or quarantined: a file that would need a move is left out, its record kept as
     * it is, and added to [notListed]; only records are stamped.
     */
    suspend fun snapshot(
        catalog: RecordingCatalog,
        filesDir: File,
        pendingDeletionIds: Set<String>,
        onlyProjects: Set<String>? = null,
        moveFiles: Boolean = true,
        notListed: MutableList<File>? = null
    ): List<LocalRecordingFile> = namespace.withLock {
        val scan = snapshotLocked(catalog, filesDir, pendingDeletionIds, onlyProjects, moveFiles)
        notListed?.addAll(scan.leftInPlace)
        scan.files.map { it.toLocal() }
    }

    /** A missing folder is empty; any other failure to list it throws. */
    internal fun listStrictly(dir: File): List<File> = try {
        Files.newDirectoryStream(dir.toPath()).use { entries -> entries.map { it.toFile() } }
    } catch (_: java.nio.file.NoSuchFileException) {
        emptyList()
    }

    private class Scan(val files: List<ScannedFile>, val leftInPlace: List<File>)

    /** A listed recording; [originalPath] is where it was before a migration rename in this scan. */
    private class ScannedFile(val entry: RecordingManifestEntry, val file: File, val inTrash: Boolean, val originalPath: String) {
        fun toLocal() = LocalRecordingFile(entry, file, inTrash)
    }

    private class Item(
        val file: File,
        val path: String,
        val projectId: String,
        val idName: String?,
        val name: String,
        val sha: String,
        val inTrash: Boolean,
        val trashedAt: Long?,
        val size: Long,
        val modifiedAt: Long
    )

    private class Planned(val record: RecordingRecord, val item: Item, val target: File)

    private suspend fun snapshotLocked(
        catalog: RecordingCatalog,
        filesDir: File,
        pendingDeletionIds: Set<String>,
        onlyProjects: Set<String>?,
        moveFiles: Boolean = true
    ): Scan {
        reconcileLocked(catalog, filesDir, mutateFiles = moveFiles)
        val items = mutableListOf<Item>()
        for ((root, inTrash) in listOf(RecordingFiles.memosRoot(filesDir) to false, RecordingFiles.trashRoot(filesDir) to true)) {
            for (dir in listStrictly(root)) {
                if (dir.name in pendingDeletionIds || (onlyProjects != null && dir.name !in onlyProjects)) continue
                // Throwing metadata reads: a file whose attributes cannot be read aborts adoption.
                if (!Files.readAttributes(dir.toPath(), BasicFileAttributes::class.java).isDirectory) continue
                SyncIdentity.validateProjectId(dir.name)
                for (file in listStrictly(dir)) {
                    val attributes = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
                    if (!attributes.isRegularFile || file.extension.lowercase(Locale.ROOT) !in RecordingFiles.SUPPORTED_AUDIO_EXTENSIONS) continue
                    // An empty file is never a recording: it is the claim of an interrupted move.
                    if (attributes.size() == 0L) continue
                    val idName = RecordingFiles.idOf(file)
                    // A pre-A36 Trash file carries its trash time and original name in its name.
                    val legacyTrash = if (inTrash && idName == null) VoiceMemoService.parseTrashedName(file.name) ?: continue else null
                    val name = legacyTrash?.second ?: file.name
                    if (idName == null) SyncIdentity.validateDisplayName(name)
                    items += Item(file, relativePath(filesDir, file), dir.name, idName, name, RecordingFileStore.sha256Hex(file),
                        inTrash, legacyTrash?.first, attributes.size(), attributes.lastModifiedTime().toMillis())
                }
            }
        }
        val listed = mutableListOf<ScannedFile>()
        val planned = mutableListOf<Planned>()
        val quarantined = mutableListOf<Pair<Item, String>>()
        val leftInPlace = mutableListOf<File>()
        catalog.updateRecordingRecords { records ->
            listed.clear(); planned.clear(); quarantined.clear(); leftInPlace.clear()
            val byId = records.associateBy { it.id }
            val byPath = records.filter { it.path != null }.associateBy { it.path }
            val itemPaths = items.mapTo(HashSet()) { it.path }
            fun intact(record: RecordingRecord?, item: Item) = record != null && record.sha256 == item.sha && record.bytes == item.size
            // A record not matched by this scan goes only when its file is confirmed absent; a song
            // outside this scan (or pending deletion) keeps its records unexamined.
            val kept = records.filter { record ->
                // A song outside this scan keeps its records unexamined; a row without a path (from
                // the first record store) waits, by identity, for the scan that adopts its file.
                if (record.projectId in pendingDeletionIds || (onlyProjects != null && record.projectId !in onlyProjects)) return@filter true
                val path = record.path ?: return@filter true
                when {
                    path in itemPaths -> false
                    else -> isRegularFileStrictly(RecordingFiles.fileAt(filesDir, path))
                }
            }.associateByTo(LinkedHashMap()) { it.id }
            // Each file's recording id, and whether its record already matches it at this path.
            fun idOf(item: Item): Pair<String, RecordingRecord?> {
                val atPath = byPath[item.path]?.takeIf { intact(it, item) }
                if (atPath != null) return atPath.id to atPath
                val named = item.idName?.let { byId[it] }
                return when {
                    item.idName != null && (named == null || intact(named, item)) -> item.idName to named
                    // Other bytes under an id's name: adopted on their own.
                    item.idName != null -> RecordingManifestEntry.legacyRecordingId(item.projectId, named!!.displayName, item.sha) to null
                    else -> RecordingManifestEntry.legacyRecordingId(item.projectId, item.name, item.sha) to null
                }
            }
            // An id-named Trash file's trash time is in its record; a pre-A36 one's in its name.
            fun trashTime(item: Item) = item.trashedAt ?: byPath[item.path]?.takeIf { intact(it, item) }?.trashedAt ?: 0L
            val groups = items.groupBy { idOf(it).first }
            for ((id, all) in groups) {
                // Copies of one id are the same bytes: those of its record, else of the file named by
                // the id. A pre-A36 file whose derived id names other bytes is left in place, reported.
                val sha = byId[id]?.sha256?.takeIf { known -> all.any { it.sha == known } }
                    ?: all.firstOrNull { it.idName == id }?.sha ?: all.first().sha
                val candidates = all.filter { it.sha == sha }
                all.filter { it.sha != sha }.forEach { leftInPlace += it.file }
                val canonical = candidates.sortedWith(
                    compareBy<Item> { it.inTrash }.thenByDescending { trashTime(it) }.thenBy { it.path }
                ).first()
                if (moveFiles) candidates.filter { it !== canonical }.forEach { quarantined += it to id }
                val existing = kept[id] ?: byId[id]?.takeIf { intact(it, canonical) } ?: candidates.firstNotNullOfOrNull { idOf(it).second }
                // A20: a stamped time never moves with a file time; only copies seen for the first time count.
                val newCopies = candidates.filter { idOf(it).second == null }
                val earliest = newCopies.minOfOrNull { it.modifiedAt }
                val displayName = existing?.displayName ?: if (canonical.idName == null) canonical.name else canonical.file.name
                val trashedAt = if (canonical.inTrash) trashTime(canonical).takeIf { it > 0L } ?: existing?.trashedAt ?: canonical.modifiedAt else null
                var record = when {
                    existing == null -> RecordingRecord(
                        id, canonical.projectId, displayName, earliest!!, canonical.sha, canonical.size,
                        RecordingRecord.ADOPTED, path = canonical.path, trashedAt = trashedAt
                    )
                    existing.origin == RecordingRecord.ADOPTED -> existing.copy(
                        path = canonical.path, trashedAt = trashedAt,
                        uploadedAt = earliest?.let { minOf(existing.uploadedAt, it) } ?: existing.uploadedAt
                    )
                    else -> existing.copy(path = canonical.path, trashedAt = trashedAt)
                }
                // A36 migration: the file takes its id name, journaled as a move intent.
                val target = if (canonical.inTrash) RecordingFiles.trashFile(filesDir, canonical.projectId, id, displayName)
                else RecordingFiles.memoFile(filesDir, canonical.projectId, id, displayName)
                val targetPath = relativePath(filesDir, target)
                if (targetPath != canonical.path) {
                    // A duplicate copy of this same recording at the target is quarantined first.
                    val heldByCopy = moveFiles && candidates.any { it !== canonical && it.path == targetPath }
                    if (!moveFiles || (!heldByCopy && (target.exists() || isRegularFileStrictly(target)))) {
                        // Not moved now (the id's name is taken by other bytes, or nothing may move):
                        // left where it is, reported, never deleted, and its record kept unchanged
                        // so its identity, time and tombstone protection survive the next scan.
                        (byPath[canonical.path]?.takeIf { intact(it, canonical) } ?: existing)?.let { kept[it.id] = it }
                        leftInPlace += canonical.file
                        continue
                    }
                    record = record.copy(path = targetPath, pendingFrom = canonical.path, pendingTrashedAt = trashedAt, pendingOp = RecordingRecord.OP_MOVE)
                    planned += Planned(record, canonical, target)
                }
                kept[id] = record
                listed += ScannedFile(record.toEntry(), target, canonical.inTrash, canonical.path)
            }
            kept.values.toList()
        }
        if (planned.isNotEmpty() || quarantined.isNotEmpty()) {
            beforeBytesMove?.invoke((planned.map { it.record.id } + quarantined.map { it.second }).toSet())
        }
        // Duplicates leave first, so a canonical copy can take a name a duplicate held.
        for ((item, id) in quarantined) quarantine(filesDir, item.file, item.projectId, id)
        if (planned.isNotEmpty()) {
            for (move in planned) {
                move.target.parentFile?.let { if (!it.exists()) it.mkdirs() }
                moveNoReplace(move.item.file, move.target)
            }
            val done = planned.mapTo(HashSet()) { it.record.id }
            catalog.updateRecordingRecords { records ->
                records.map { if (it.id in done) it.copy(pendingFrom = null, pendingTrashedAt = null, pendingOp = null) else it }
            }
        }
        return Scan(
            listed.sortedWith(compareBy<ScannedFile> { it.inTrash }.thenBy { it.entry.projectId }.thenBy { it.entry.fileName }),
            leftInPlace.toList()
        )
    }
}
