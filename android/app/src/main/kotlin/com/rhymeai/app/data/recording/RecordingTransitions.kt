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
import java.util.UUID
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS

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

    /**
     * What the last moving reconciliation could not settle: record intents whose bytes are
     * at neither end, and journals that are malformed or match neither file. Kept, never
     * dropped, and reported by the app's launch check (A24/A36).
     */
    @Volatile var unresolved: List<String> = emptyList()
        private set

    fun relativePath(filesDir: File, file: File): String = file.canonicalFile.relativeTo(filesDir.canonicalFile).path

    private fun requireCatalog(catalog: RecordingCatalog?): RecordingCatalog =
        catalog ?: throw IOException("Recordings need their records to move")

    // ---------------------------------------------------------------------------
    // The verified transition (A5/A16/A24/A28/A36): every byte move goes through it
    // ---------------------------------------------------------------------------

    private const val CLAIM_MAGIC = "rhymeai-claim"
    private const val MAX_CLAIM_BYTES = 128L

    private fun claimText(token: String) = "$CLAIM_MAGIC\n$token\n"

    /** Whether [file] is exactly the claim [token] created; only such a file is ever removed by recovery. */
    internal fun isClaimOf(file: File, token: String?): Boolean =
        token != null && isRegularFileStrictly(file) && file.length() <= MAX_CLAIM_BYTES &&
            runCatching { file.readText() }.getOrNull() == claimText(token)

    /** Whether [file] is some move's claim; a claim is never a recording. */
    private fun isAnyClaim(file: File, size: Long): Boolean =
        size in 1..MAX_CLAIM_BYTES && runCatching { file.readText() }.getOrNull()?.startsWith("$CLAIM_MAGIC\n") == true

    /** True when [file] holds exactly [length] bytes with digest [sha]. */
    internal fun holds(file: File, sha: String, length: Long): Boolean =
        isRegularFileStrictly(file) && file.length() == length && RecordingFileStore.sha256Hex(file) == sha

    /** The source no longer holds the bytes its intent names; nothing moved. */
    internal class SourceChangedException(path: String) : IOException("Recording changed before its move: $path")

    /**
     * Moves [source] to [target] without ever replacing a file there. The source is checked
     * against its intent's [sha] and [length] immediately before the move. Then the target
     * is claimed with an exclusive create (O_CREAT|O_EXCL) holding [token]; just before the
     * rename the target must still be that claim (same file key, same content), so the
     * rename only ever replaces this operation's own claim. A file that appears at the
     * target is never replaced: [java.nio.file.FileAlreadyExistsException]. A rename alone
     * (`Files.move` ATOMIC_MOVE, `File.renameTo`, `Os.rename`) would replace it, hard links
     * are refused in app storage, and `renameat2(RENAME_NOREPLACE)` is not reachable from
     * the SDK; no other process writes app-private storage. A failed move removes only its
     * own claim; a claim left by a crash is removed by recovery, which matches its token.
     */
    internal fun moveNoReplace(source: File, target: File, token: String, sha: String, length: Long) {
        target.parentFile?.let { if (!it.exists()) it.mkdirs() }
        if (!target.createNewFile()) throw java.nio.file.FileAlreadyExistsException(target.path)
        val claimKey = try {
            target.writeText(claimText(token))
            Files.readAttributes(target.toPath(), BasicFileAttributes::class.java).fileKey()
        } catch (e: Exception) {
            if (isClaimOf(target, token)) target.delete()
            throw e
        }
        val current = Files.readAttributes(target.toPath(), BasicFileAttributes::class.java).fileKey()
        if (current != claimKey || !isClaimOf(target, token)) throw java.nio.file.FileAlreadyExistsException(target.path)
        try {
            // The source is verified immediately before the rename, after the claim is held.
            if (!holds(source, sha, length)) throw SourceChangedException(source.path)
            Files.move(source.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (e: Exception) {
            if (isClaimOf(target, token)) target.delete()
            throw e
        }
    }

    private fun newToken() = UUID.randomUUID().toString()

    private const val JOURNAL_HEADER = "rhymeai-move 1"
    private const val JOURNAL_SUFFIX = ".move"
    internal const val KIND_QUARANTINE = "quarantine"
    internal const val KIND_STAGING = "staging"
    internal const val KIND_PARKING = "parking"
    internal const val KIND_HISTORICAL = "historical"
    private val SHA256 = Regex("[0-9a-f]{64}")

    /** A move of bytes that have no record of their own (quarantine, staging, historical recovery). */
    private class Journal(val file: File, val kind: String, val source: File, val target: File, val sha: String, val length: Long, val claim: String)

    private fun writeJournal(filesDir: File, kind: String, id: String, source: File, target: File, sha: String, length: Long, claim: String): File {
        val root = RecordingFiles.journalRoot(filesDir)
        if (!root.exists() && !root.mkdirs()) throw IOException("Could not create the recording journal folder")
        val journal = File(root, "$claim$JOURNAL_SUFFIX")
        val temp = File(root, "${journal.name}.tmp")
        temp.writeText(
            listOf(
                JOURNAL_HEADER, "kind=$kind", "id=$id", "source=${relativePath(filesDir, source)}",
                "target=${relativePath(filesDir, target)}", "sha256=$sha", "length=$length", "claim=$claim"
            ).joinToString("\n", postfix = "\n")
        )
        Files.move(temp.toPath(), journal.toPath(), StandardCopyOption.ATOMIC_MOVE)
        return journal
    }

    /** The journal at [file], or null when any field is missing or invalid (it is then kept and reported). */
    private fun readJournal(filesDir: File, file: File): Journal? {
        val lines = runCatching { file.readLines() }.getOrNull() ?: return null
        if (lines.firstOrNull() != JOURNAL_HEADER) return null
        val fields = lines.drop(1).filter { it.isNotEmpty() }.associate { line ->
            val at = line.indexOf('=')
            if (at <= 0) return null
            line.substring(0, at) to line.substring(at + 1)
        }
        val kind = fields["kind"]?.takeIf { it in setOf(KIND_QUARANTINE, KIND_STAGING, KIND_PARKING, KIND_HISTORICAL) } ?: return null
        fields["id"]?.takeIf { runCatching { SyncIdentity.validateRecordingId(it) }.isSuccess } ?: return null
        val source = fields["source"]?.let { RecordingFiles.containedRecordingFile(filesDir, it) } ?: return null
        val target = fields["target"]?.let { RecordingFiles.containedRecordingFile(filesDir, it) } ?: return null
        val sha = fields["sha256"]?.takeIf { SHA256.matches(it) } ?: return null
        val length = fields["length"]?.toLongOrNull()?.takeIf { it > 0L } ?: return null
        val claim = fields["claim"]?.takeIf { runCatching { UUID.fromString(it) }.isSuccess } ?: return null
        return Journal(file, kind, source, target, sha, length, claim)
    }

    /**
     * The verified transition for bytes without a record: journal (id, source, target,
     * digest, length, claim) → stop playback of [id] → re-verify and move without replacing
     * → [afterMove] → clear the journal. A crash at any point is settled by recovery.
     */
    private suspend fun journaledMove(
        filesDir: File, kind: String, id: String, source: File, target: File, sha: String, length: Long,
        afterMove: () -> Unit = {}
    ) {
        val claim = newToken()
        val journal = writeJournal(filesDir, kind, id, source, target, sha, length, claim)
        beforeBytesMove?.invoke(setOf(id))
        try {
            moveNoReplace(source, target, claim, sha, length)
        } catch (e: Exception) {
            journal.delete()
            throw e
        }
        afterMove()
        journal.delete()
    }

    /** A staging take's marker follows it to its new name (a crash between the two is finished here or by recovery). */
    private fun followMarker(source: File, target: File) {
        val old = File(source.parentFile, source.name + TAKE_MARKER_SUFFIX)
        val new = File(target.parentFile, target.name + TAKE_MARKER_SUFFIX)
        if (old.exists() && !new.exists()) {
            val temp = File(new.parentFile, new.name + ".tmp")
            temp.writeBytes(old.readBytes())
            Files.move(temp.toPath(), new.toPath(), StandardCopyOption.ATOMIC_MOVE)
        }
        if (new.exists()) old.delete()
    }

    private const val TAKE_MARKER_SUFFIX = ".take"
    private const val LEGACY_WAITING_SUFFIX = ".waiting"
    private const val LEGACY_JOURNAL_SUFFIX = ".migrate"

    /**
     * Settles every journal (the claim-and-rename crash states included) and returns what it
     * could not settle. Malformed journals are kept. Journals of builds before this one
     * (`.migrate` beside a staging take or a quarantine copy) are settled by their bytes;
     * a target is never removed on their account.
     */
    private fun recoverJournalsLocked(filesDir: File): List<String> {
        val unsettled = mutableListOf<String>()
        val held = HashSet<File>()
        for (file in listStrictly(RecordingFiles.journalRoot(filesDir))) {
            // Never renamed into place: nothing was moved on its account.
            if (file.name.endsWith("$JOURNAL_SUFFIX.tmp")) { file.delete(); continue }
            if (!file.name.endsWith(JOURNAL_SUFFIX)) continue
            val journal = readJournal(filesDir, file) ?: run { unsettled += "journal ${file.name}"; null } ?: continue
            if (isClaimOf(journal.target, journal.claim)) journal.target.delete()
            when {
                holds(journal.target, journal.sha, journal.length) -> {
                    if (journal.kind == KIND_STAGING) followMarker(journal.source, journal.target)
                    file.delete()
                }
                holds(journal.source, journal.sha, journal.length) -> file.delete()
                else -> unsettled += relativePath(filesDir, journal.target)
            }
        }
        // Journals written by builds before this one.
        for ((root, staging) in listOf(RecordingFiles.stagingRoot(filesDir) to true, RecordingFiles.quarantineRoot(filesDir) to false)) {
            if (!isDirectoryStrictly(root)) continue
            for (dir in listStrictly(root).filter { isDirectoryStrictly(it) }) {
                for (file in listStrictly(dir).filter { it.name.endsWith(LEGACY_JOURNAL_SUFFIX) }) {
                    // Staging: source, target, SHA-256, length. Quarantine: source, target, id, SHA-256, length.
                    val lines = runCatching { file.readLines() }.getOrNull()
                    val expected = if (staging) 4 else 5
                    val source = lines?.getOrNull(0)?.let { runCatching { RecordingFiles.containedRecordingFile(filesDir, relativePath(filesDir, File(dir, it))) }.getOrNull() }
                    val target = lines?.getOrNull(1)?.let { runCatching { RecordingFiles.containedRecordingFile(filesDir, relativePath(filesDir, File(dir, it))) }.getOrNull() }
                    // The saved id must be the id the target is named by (T3.18).
                    val idMatches = staging || lines?.getOrNull(2)?.let { id ->
                        runCatching { SyncIdentity.validateRecordingId(id) }.isSuccess && target != null && RecordingFiles.idOf(target) == id
                    } == true
                    val sha = lines?.getOrNull(if (staging) 2 else 3)?.takeIf { SHA256.matches(it) }
                    val length = lines?.getOrNull(if (staging) 3 else 4)?.toLongOrNull()?.takeIf { it > 0L }
                    val complete = lines != null && lines.size == expected
                    if (!complete || source == null || target == null || !idMatches || sha == null || length == null) {
                        // T3.17: a journal that cannot be read in full suspends every move in its folder.
                        unsettled += "journal ${file.name}"
                        held += dir.canonicalFile
                        continue
                    }
                    when {
                        holds(target, sha, length) -> { if (staging) followMarker(source, target); file.delete() }
                        holds(source, sha, length) -> file.delete()
                        else -> { unsettled += relativePath(filesDir, target); held += dir.canonicalFile }
                    }
                }
            }
        }
        heldDirs = held
        return unsettled
    }

    /** Folders whose historical journal could not be settled: nothing in them moves until it can. */
    @Volatile private var heldDirs: Set<File> = emptySet()

    // ---------------------------------------------------------------------------
    // Transitions with records
    // ---------------------------------------------------------------------------

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
        val catalog = requireCatalog(catalog)
        reconcileLocked(catalog, filesDir)
        if (skipIfPresent && catalog.recordingRecords().any { it.id == id && it.path != null }) {
            return@withLock null
        }
        SyncIdentity.validateDisplayName(displayName)
        val dir = RecordingFiles.memoDirectory(filesDir, projectId)
        if (!dir.exists() && !dir.mkdirs()) throw IOException("Could not create memo directory for $projectId")
        val target = RecordingFiles.memoFile(filesDir, projectId, id, displayName)
        // Never replace a file: the id's name is taken only by that recording.
        if (target.exists() || isRegularFileStrictly(target)) throw java.nio.file.FileAlreadyExistsException(target.path)
        val sha = RecordingFileStore.sha256Hex(source)
        val length = source.length()
        if (length <= 0L) throw IOException("An empty recording is never saved")
        // Playback stops before the intent is written: a cancellation here leaves no record
        // behind, while one left after its caller deletes staging would match neither end.
        beforeBytesMove?.invoke(setOf(id))
        val claim = newToken()
        val record = RecordingRecord(
            id, projectId, displayName, uploadedAt, sha, length, origin,
            precedenceRepaired = repaired,
            path = relativePath(filesDir, target),
            pendingFrom = relativePath(filesDir, source),
            pendingOp = RecordingRecord.OP_PUBLISH,
            pendingClaim = claim
        )
        catalog.putRecord(record)
        try {
            moveNoReplace(source, target, claim, sha, length)
        } catch (e: Exception) {
            runCatching { catalog.removeRecord(id) }
            throw e
        }
        catalog.putRecord(record.copy(pendingFrom = null, pendingOp = null, pendingClaim = null))
        target
    }

    /** Moves a live recording to Trash at [trashedAt]; the file keeps its id name. Null when it is not a known recording. */
    suspend fun moveToTrash(catalog: RecordingCatalog?, filesDir: File, file: File, projectId: String, trashedAt: Long): File? =
        namespace.withLock { moveLocked(requireCatalog(catalog), filesDir, file, projectId, toTrash = true, trashedAt = trashedAt) }

    /** Moves a recording from Trash back to the song's memo folder. Null when it is not a known recording. */
    suspend fun restoreFromTrash(catalog: RecordingCatalog?, filesDir: File, file: File, projectId: String): File? =
        namespace.withLock { moveLocked(requireCatalog(catalog), filesDir, file, projectId, toTrash = false, trashedAt = null) }

    private suspend fun moveLocked(
        catalog: RecordingCatalog,
        filesDir: File,
        from: File,
        projectId: String,
        toTrash: Boolean,
        trashedAt: Long?
    ): File? {
        reconcileLocked(catalog, filesDir)
        // Adoption hashes the song's files: the record is for these exact bytes.
        val record = recordForLocked(catalog, filesDir, from, projectId) ?: return null
        if (record.pendingOp != null) return null
        // Adoption may just have given a pre-A36 file its id name: move the file where it is now.
        val current = RecordingFiles.fileAt(filesDir, record.path ?: return null)
        val inTrash = isUnder(current, RecordingFiles.trashRoot(filesDir))
        if (inTrash == toTrash) return null
        val target = if (toTrash) RecordingFiles.trashFile(filesDir, projectId, record.id, record.displayName)
        else RecordingFiles.memoFile(filesDir, projectId, record.id, record.displayName)
        // Never replace a file.
        if (target.exists() || isRegularFileStrictly(target)) return null
        val claim = newToken()
        val intent = record.copy(
            path = relativePath(filesDir, target),
            trashedAt = trashedAt,
            pendingFrom = record.path,
            pendingTrashedAt = record.trashedAt,
            pendingOp = RecordingRecord.OP_MOVE,
            pendingClaim = claim
        )
        catalog.putRecord(intent)
        beforeBytesMove?.invoke(setOf(record.id))
        try {
            moveNoReplace(current, target, claim, record.sha256, record.bytes)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: IOException) {
            catalog.putRecord(record)
            return null
        }
        catalog.putRecord(intent.copy(pendingFrom = null, pendingTrashedAt = null, pendingOp = null, pendingClaim = null))
        return target
    }

    private fun isUnder(file: File, root: File): Boolean =
        file.canonicalFile.toPath().startsWith(root.canonicalFile.toPath())

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
            SyncMerger.Tombstones(deletions()).let { it.removes(record.toEntry()) || it.suspends(record.toEntry()) }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            true
        }
        if (removed) null else start(record.id, RecordingFiles.fileAt(filesDir, record.path ?: return@withLock null))
    }

    /**
     * Permanently deletes the Trash recording at [file] as one operation under the lock
     * (A28/A33): it must still be that recording, in Trash, with no move pending, and, for
     * expiry, past its deadline at [expiresBy]; then [tombstone] is written, playback of it
     * stops, its bytes are verified against the record and unlinked, and the record goes.
     * A recording restored, moved or changed meanwhile is left alone (false). True also
     * when the file is no longer there because it was a duplicate copy set aside (A26).
     */
    suspend fun deleteFromTrash(
        catalog: RecordingCatalog,
        filesDir: File,
        file: File,
        projectId: String,
        expiresBy: Long?,
        tombstone: suspend (RecordingRecord, Long) -> Unit
    ): Boolean = namespace.withLock {
        reconcileLocked(catalog, filesDir)
        val record = recordForLocked(catalog, filesDir, file, projectId)
            ?: return@withLock isConfirmedAbsent(file)
        if (record.pendingOp != null) return@withLock false
        val current = RecordingFiles.fileAt(filesDir, record.path ?: return@withLock false)
        if (!isUnder(current, RecordingFiles.trashRoot(filesDir))) return@withLock false
        val trashedAt = record.trashedAt?.takeIf { it > 0L } ?: return@withLock false
        if (expiresBy != null && trashedAt + TRASH_RETENTION_MILLIS > expiresBy) return@withLock false
        tombstone(record, System.currentTimeMillis())
        beforeBytesMove?.invoke(setOf(record.id))
        if (!holds(current, record.sha256, record.bytes) || !current.delete()) return@withLock false
        catalog.removeRecord(record.id)
        true
    }

    /**
     * Whole-song cleanup after a song deletion committed: under the lock, the song's live
     * and Trash files are adopted (hashed) and only recordings a winning tombstone in
     * [deletions] removes leave: each one's playback stops and its bytes are verified
     * immediately before; one with a real time is deleted, one whose time is a repair is
     * set aside in quarantine (A41). Any other bytes (a take that finished after the
     * deletion, a file dropped in) are kept. True when nothing of the song is left.
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
        val gone = HashSet<String>()
        for (item in covered) {
            val entry = item.entry
            if (entry.precedenceRepaired) {
                quarantineLocked(filesDir, item.file, projectId, entry.id, entry.sha256, entry.sizeBytes)
            } else {
                beforeBytesMove?.invoke(setOf(entry.id))
                if (!holds(item.file, entry.sha256, entry.sizeBytes) || !item.file.delete()) break
            }
            gone += entry.id
        }
        if (gone.isNotEmpty()) catalog.updateRecordingRecords { records -> records.filterNot { it.id in gone } }
        val live = RecordingFiles.memoDirectory(filesDir, projectId)
        val trash = RecordingFiles.trashDirectory(filesDir, projectId)
        val left = listStrictly(live) + listStrictly(trash)
        if (left.isNotEmpty() || scan.files.size != gone.size || scan.leftInPlace.isNotEmpty()) return@withLock false
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
     * A file left under its old name (its id name holds other bytes) must have a record, so
     * its identity is tombstoned with the song; one without a record stops the deletion.
     */
    suspend fun adopt(catalog: RecordingCatalog, filesDir: File, projectIds: Set<String>) {
        if (projectIds.isEmpty()) return
        val left = mutableListOf<File>()
        snapshot(catalog, filesDir, emptySet(), projectIds, notListed = left)
        if (left.isEmpty()) return
        val records = catalog.recordingRecords()
        // Identified: a record of these very bytes, at this path or (a row awaiting migration) by its derived id.
        val unidentified = left.filterNot { file ->
            val projectId = file.parentFile?.name ?: return@filterNot false
            val name = VoiceMemoService.parseTrashedName(file.name)?.second ?: file.name
            val sha = RecordingFileStore.sha256Hex(file)
            val path = relativePath(filesDir, file)
            val legacyId = RecordingManifestEntry.legacyRecordingId(projectId, name, sha)
            records.any { it.sha256 == sha && (it.path == path || it.id == legacyId) }
        }
        if (unidentified.isNotEmpty()) throw IOException("${unidentified.size} recording file(s) could not be identified yet")
    }

    /**
     * A36 migration, run at every launch (idempotent, journaled): historical parked
     * recordings return to their song, pre-A36 quarantine copies, live and Trash files take
     * their id names (old name kept as display name). Returns the files left in place
     * because their id name is taken by other bytes. Staging is migrated by the voice memo
     * service, which owns its markers ([migrateStaging]).
     */
    suspend fun migrate(catalog: RecordingCatalog, filesDir: File): List<File> =
        namespace.withLock {
            // A33: nothing moves, quarantine included, unless the deletion state is readable.
            reconcileLocked(catalog, filesDir)
            recoverParkingLocked(filesDir) + migrateQuarantineLocked(filesDir) +
                snapshotLocked(catalog, filesDir, emptySet(), null).leftInPlace
        }

    /**
     * Preserves an original that an interrupted restore of the encrypted-sync build had
     * replaced: it moves, verified and journaled, into the song's live folder as
     * "<name> (original)<ext>" (or "(original 2)", …; never replacing a file), where the
     * launch migration adopts it as its own recording. Returns where it went.
     */
    suspend fun preserveOriginal(filesDir: File, original: File, projectId: String, name: String): File = namespace.withLock {
        val sha = RecordingFileStore.sha256Hex(original)
        val dot = name.lastIndexOf('.')
        val extension = if (dot > 0) name.substring(dot + 1).lowercase(Locale.ROOT).takeIf { it in RecordingFiles.SUPPORTED_AUDIO_EXTENSIONS } else null
        val stem = if (dot > 0) name.substring(0, dot) else name
        var n = 1
        while (true) {
            val candidate = "$stem (original${if (n == 1) "" else " $n"}).${extension ?: "m4a"}"
            val target = RecordingFiles.legacyMemoFile(filesDir, projectId, candidate)
            if (!target.exists() && !isRegularFileStrictly(target)) {
                try {
                    journaledMove(filesDir, KIND_HISTORICAL, RecordingManifestEntry.legacyRecordingId(projectId, candidate, sha),
                        original, target, sha, original.length())
                    return@withLock target
                } catch (_: java.nio.file.FileAlreadyExistsException) {
                    // Taken meanwhile: try the next name.
                }
            }
            n++
        }
        @Suppress("UNREACHABLE_CODE") original
    }

    /**
     * Builds before A36 parked a recording at `voice-memos-parking/<projectId>/<id>.<ext>`
     * while names swapped. Each such file returns to its song's live folder under the same
     * id name, through the journaled no-replace move; a taken name leaves it in place.
     */
    private suspend fun recoverParkingLocked(filesDir: File): List<File> {
        val left = mutableListOf<File>()
        for (dir in listStrictly(RecordingFiles.parkingRoot(filesDir)).filter { isDirectoryStrictly(it) }) {
            SyncIdentity.validateProjectId(dir.name)
            for (file in listStrictly(dir)) {
                if (!isRegularFileStrictly(file) || file.length() == 0L) continue
                val id = RecordingFiles.idOf(file) ?: run { left += file; null } ?: continue
                val target = File(RecordingFiles.memoDirectory(filesDir, dir.name), file.name)
                try {
                    journaledMove(filesDir, KIND_PARKING, id, file, target, RecordingFileStore.sha256Hex(file), file.length())
                } catch (_: java.nio.file.FileAlreadyExistsException) {
                    left += file
                }
            }
            if (listStrictly(dir).isEmpty()) dir.delete()
        }
        return left
    }

    /**
     * A36 for quarantine: a pre-A36 kept copy `<movedAt>__<name>` moves to
     * `<movedAt>/<id>.<ext>` in its song's quarantine folder (the derived A21 id of its name
     * and bytes), through the journaled no-replace move; one whose target exists stays.
     */
    private suspend fun migrateQuarantineLocked(filesDir: File): List<File> {
        val left = mutableListOf<File>()
        for (dir in listStrictly(RecordingFiles.quarantineRoot(filesDir))) {
            if (!isDirectoryStrictly(dir)) continue
            if (dir.canonicalFile in heldDirs) { left += listStrictly(dir).filter { isRegularFileStrictly(it) && !it.name.endsWith(LEGACY_JOURNAL_SUFFIX) }; continue }
            for (file in listStrictly(dir)) {
                if (!isRegularFileStrictly(file) || file.name.endsWith(LEGACY_JOURNAL_SUFFIX) ||
                    file.name.endsWith("$LEGACY_JOURNAL_SUFFIX.tmp") || file.length() == 0L) continue
                val (movedAt, name) = VoiceMemoService.parseTrashedName(file.name) ?: (file.lastModified() to file.name)
                val sha = RecordingFileStore.sha256Hex(file)
                val id = RecordingManifestEntry.legacyRecordingId(dir.name, name, sha)
                val target = File(File(dir, movedAt.toString()), RecordingFiles.idFileName(id, name))
                if (target.exists() || isRegularFileStrictly(target)) {
                    left += file
                    continue
                }
                try {
                    journaledMove(filesDir, KIND_QUARANTINE, id, file, target, sha, file.length())
                } catch (_: java.nio.file.FileAlreadyExistsException) {
                    left += file
                }
            }
        }
        return left
    }

    /**
     * A36 for staging, under the recording lock and only with readable tombstones (A33):
     * a take from a build before this one (`.waiting` marker: id and finish time) gets the
     * current marker; a take still under a pre-A36 name moves to `<id>.<ext>` (the id from
     * its marker) through the journaled no-replace move, its marker following; an import
     * interrupted before it was saved (its `.import` ownership marker still there) is set
     * aside in quarantine, kept. A take whose marker cannot be read, whose id name is taken,
     * or a file with no marker at all, stays and is returned. [skip] (the take being
     * recorded, imports in progress) is never touched.
     */
    suspend fun migrateStaging(catalog: RecordingCatalog?, filesDir: File, skip: Set<File>): List<File> = namespace.withLock {
        catalog?.let { reconcileLocked(it, filesDir) } ?: throw IOException("Recordings need their records to move")
        val left = mutableListOf<File>()
        for (dir in listStrictly(RecordingFiles.stagingRoot(filesDir)).filter { isDirectoryStrictly(it) }) {
            if (dir.canonicalFile in heldDirs) {
                left += listStrictly(dir).filter { isRegularFileStrictly(it) && it.extension.lowercase(Locale.ROOT) in RecordingFiles.SUPPORTED_AUDIO_EXTENSIONS }
                continue
            }
            // Historical `.waiting` markers: "<id>\n<finish time>\n" for a finished take.
            for (waiting in listStrictly(dir).filter { it.name.endsWith(LEGACY_WAITING_SUFFIX) }) {
                val take = File(dir, waiting.name.removeSuffix(LEGACY_WAITING_SUFFIX))
                val marker = File(dir, take.name + TAKE_MARKER_SUFFIX)
                val lines = runCatching { waiting.readLines() }.getOrNull()
                val id = lines?.getOrNull(0)?.takeIf { runCatching { SyncIdentity.validateRecordingId(it) }.isSuccess }
                val finishedAt = lines?.getOrNull(1)?.toLongOrNull()?.takeIf { it > 0L }
                // Unreadable: the marker stays and the take is reported once, below, as unattributed.
                if (id == null || finishedAt == null) continue
                if (!marker.exists()) {
                    val temp = File(dir, marker.name + ".tmp")
                    temp.writeText("$id\nfinished\n$finishedAt\n")
                    Files.move(temp.toPath(), marker.toPath(), StandardCopyOption.ATOMIC_MOVE)
                }
                waiting.delete()
            }
            for (file in listStrictly(dir)) {
                if (file in skip || !isRegularFileStrictly(file) ||
                    file.extension.lowercase(Locale.ROOT) !in RecordingFiles.SUPPORTED_AUDIO_EXTENSIONS) continue
                val importMarker = File(dir, file.name + IMPORT_MARKER_SUFFIX)
                val takeMarker = File(dir, file.name + TAKE_MARKER_SUFFIX)
                when {
                    importMarker.exists() -> {
                        // An import this process no longer owns: kept aside, never deleted.
                        val id = RecordingFiles.idOf(file)
                        if (id == null || file.length() == 0L) { left += file; continue }
                        quarantineLocked(filesDir, file, dir.name, id, RecordingFileStore.sha256Hex(file), file.length())
                        importMarker.delete()
                    }
                    takeMarker.exists() -> {
                        if (RecordingFiles.idOf(file) != null || file.length() == 0L) continue
                        val id = runCatching { takeMarker.readLines().firstOrNull() }.getOrNull()
                            ?.takeIf { runCatching { SyncIdentity.validateRecordingId(it) }.isSuccess }
                            ?: run { left += file; null } ?: continue
                        val target = File(dir, RecordingFiles.idFileName(id, file.name))
                        if (target.exists() || isRegularFileStrictly(target)) { left += file; continue }
                        try {
                            journaledMove(filesDir, KIND_STAGING, id, file, target, RecordingFileStore.sha256Hex(file), file.length()) {
                                followMarker(file, target)
                            }
                        } catch (_: java.nio.file.FileAlreadyExistsException) {
                            left += file
                        }
                    }
                    // No marker of any kind: a remnant this build cannot attribute; reported, kept.
                    else -> left += file
                }
            }
            // An ownership marker whose import is gone needs nothing more.
            listStrictly(dir).filter { it.name.endsWith(IMPORT_MARKER_SUFFIX) }
                .filter { isConfirmedAbsent(File(dir, it.name.removeSuffix(IMPORT_MARKER_SUFFIX))) && File(dir, it.name.removeSuffix(IMPORT_MARKER_SUFFIX)) !in skip }
                .forEach { it.delete() }
        }
        left
    }

    /** A take in staging set aside in quarantine with its marker (the recorder never finished it). */
    suspend fun setAsideStaged(catalog: RecordingCatalog?, filesDir: File, take: File, projectId: String, id: String): Boolean = namespace.withLock {
        val catalog = requireCatalog(catalog)
        reconcileLocked(catalog, filesDir)
        if (!isRegularFileStrictly(take) || take.length() == 0L) return@withLock false
        quarantineLocked(filesDir, take, projectId, id, RecordingFileStore.sha256Hex(take), take.length())
        File(take.parentFile, take.name + TAKE_MARKER_SUFFIX).delete()
        true
    }

    private const val IMPORT_MARKER_SUFFIX = ".import"

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
        return records.mapNotNullTo(HashSet()) { record -> record.path?.takeIf { tombstones.removes(record.toEntry()) || tombstones.suspends(record.toEntry()) } }
    }

    /**
     * A28: recordings that [deletions] remove leave the library for quarantine; returns
     * how many. The committed tombstones are the durable intent and each move is
     * journaled: this runs after Restore and Import and again at every launch, so an
     * interrupted or failed move is settled and retried.
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
        for (item in gone) quarantineLocked(filesDir, item.file, item.entry.projectId, item.entry.id, item.entry.sha256, item.entry.sizeBytes)
        val ids = gone.mapTo(HashSet()) { it.entry.id }
        catalog.updateRecordingRecords { records -> records.filterNot { it.id in ids } }
        gone.size
    }

    /**
     * Moves a duplicate or deleted recording's bytes out of the library, keeping them
     * (A26/A28), as `<id>.<ext>` in a folder of its own, so two kept copies never collide;
     * through the journaled, verified, no-replace move.
     */
    private suspend fun quarantineLocked(filesDir: File, file: File, projectId: String, id: String, sha: String, length: Long): File {
        val root = RecordingFiles.quarantineDirectory(filesDir, projectId)
        var stamp = System.currentTimeMillis()
        var dir = File(root, stamp.toString())
        while (dir.exists()) dir = File(root, (++stamp).toString())
        if (!dir.mkdirs()) throw IOException("Could not create recording quarantine folder")
        val target = File(dir, RecordingFiles.idFileName(id, file.name))
        journaledMove(filesDir, KIND_QUARANTINE, id, file, target, sha, length)
        return target
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

    /**
     * Settles interrupted moves. With [mutateFiles] (launch, transitions, Restore, Import)
     * journals are settled and this move's own claims removed; a read-only pass (Back up,
     * export) changes no file and leaves an intent whose target is still its claim pending.
     * A record whose bytes are at its target is committed; a move whose bytes are back at
     * its source is undone; a publish whose bytes are still in staging is dropped (its take
     * or import retries). An intent whose bytes are at neither end is kept, with its id and
     * time, and reported, never dropped.
     */
    private suspend fun reconcileLocked(catalog: RecordingCatalog, filesDir: File, mutateFiles: Boolean = true) {
        // A33: every adoption, reconciliation and move starts here; none runs on unreadable tombstones.
        catalog.requireDeletionsReadable()
        val unsettledJournals = if (mutateFiles) recoverJournalsLocked(filesDir) else null
        val pending = catalog.recordingRecords().filter { it.pendingOp != null }
        val blocked = HashSet<String>()
        for (record in pending) {
            val target = record.path?.let { RecordingFiles.fileAt(filesDir, it) } ?: continue
            if (!isClaimOf(target, record.pendingClaim)) continue
            if (mutateFiles) target.delete() else blocked += record.id
        }
        if (pending.isNotEmpty()) {
            catalog.updateRecordingRecords { records ->
                records.mapNotNull { record ->
                    if (record.pendingOp == null || record.id in blocked) return@mapNotNull record
                    val target = record.path?.let { RecordingFiles.fileAt(filesDir, it) }
                    val source = record.pendingFrom?.let { RecordingFiles.fileAt(filesDir, it) }
                    when {
                        // The expected id's bytes at the target: the move happened. Strict checks: a file
                        // that cannot be examined throws here and nothing is committed.
                        target != null && holds(target, record.sha256, record.bytes) ->
                            record.copy(pendingFrom = null, pendingTrashedAt = null, pendingOp = null, pendingFromName = null, pendingClaim = null)
                        // Undo only onto the same bytes; anything else at the source is adopted on its own.
                        record.pendingOp == RecordingRecord.OP_MOVE && source != null && holds(source, record.sha256, record.bytes) -> record.copy(
                            path = record.pendingFrom,
                            trashedAt = record.pendingTrashedAt,
                            displayName = record.pendingFromName ?: record.displayName,
                            pendingFrom = null, pendingTrashedAt = null, pendingOp = null, pendingFromName = null, pendingClaim = null
                        )
                        // Not published: the take or import is still in staging and is retried by its owner.
                        record.pendingOp == RecordingRecord.OP_PUBLISH && source != null && holds(source, record.sha256, record.bytes) -> null
                        // At neither end: kept with its identity and time, reported.
                        else -> record
                    }
                }
            }
        }
        if (mutateFiles) {
            unresolved = unsettledJournals.orEmpty() +
                catalog.recordingRecords().filter { it.pendingOp != null }.map { "${it.projectId}/${it.displayName}" }
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
     * new copies, recorded as a repair (A37: of two repairs the smaller stands; an
     * established real time never moves); an unknown file or Trash time is the time first
     * seen. All or nothing: an unreadable file or folder throws. Staging and quarantine are
     * never read. Empty files and move claims are never recordings.
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

    /** Trash files whose names this build cannot read (neither an id nor `<time>__<name>`): reported, never adopted. */
    @Volatile var unrecognizedTrashFiles: List<File> = emptyList()
        private set

    private suspend fun snapshotLocked(
        catalog: RecordingCatalog,
        filesDir: File,
        pendingDeletionIds: Set<String>,
        onlyProjects: Set<String>?,
        moveFiles: Boolean = true
    ): Scan {
        reconcileLocked(catalog, filesDir, mutateFiles = moveFiles)
        val now = System.currentTimeMillis()
        val items = mutableListOf<Item>()
        val unrecognized = mutableListOf<File>()
        for ((root, inTrash) in listOf(RecordingFiles.memosRoot(filesDir) to false, RecordingFiles.trashRoot(filesDir) to true)) {
            for (dir in listStrictly(root)) {
                if (dir.name in pendingDeletionIds || (onlyProjects != null && dir.name !in onlyProjects)) continue
                // Throwing metadata reads: a file whose attributes cannot be read aborts adoption.
                if (!Files.readAttributes(dir.toPath(), BasicFileAttributes::class.java).isDirectory) continue
                SyncIdentity.validateProjectId(dir.name)
                for (file in listStrictly(dir)) {
                    val attributes = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
                    if (!attributes.isRegularFile || file.extension.lowercase(Locale.ROOT) !in RecordingFiles.SUPPORTED_AUDIO_EXTENSIONS) continue
                    // An empty file is never a recording (empty audio is refused everywhere), and a move's
                    // claim is never one: neither is adopted, listed or removed here.
                    if (attributes.size() == 0L || isAnyClaim(file, attributes.size())) continue
                    val idName = RecordingFiles.idOf(file)
                    // A pre-A36 Trash file carries its trash time and original name in its name.
                    val legacyTrash = if (inTrash && idName == null) {
                        VoiceMemoService.parseTrashedName(file.name) ?: run { unrecognized += file; null } ?: continue
                    } else null
                    val name = legacyTrash?.second ?: file.name
                    if (idName == null) SyncIdentity.validateDisplayName(name)
                    items += Item(file, relativePath(filesDir, file), dir.name, idName, name, RecordingFileStore.sha256Hex(file),
                        inTrash, legacyTrash?.first, attributes.size(), attributes.lastModifiedTime().toMillis())
                }
            }
        }
        if (onlyProjects == null) unrecognizedTrashFiles = unrecognized
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
            // outside this scan (or pending deletion) keeps its records unexamined, and so does a
            // record with an intent not yet settled.
            val kept = records.filter { record ->
                // A song outside this scan keeps its records unexamined; a row without a path (from
                // the first record store) waits, by identity, for the scan that adopts its file.
                if (record.projectId in pendingDeletionIds || (onlyProjects != null && record.projectId !in onlyProjects)) return@filter true
                if (record.pendingOp != null) return@filter true
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
            // An id-named Trash file's trash time is in its record; a pre-A36 one's in its name. An
            // unknown one (0) is the time first seen, so it never reads as long expired.
            fun trashTime(item: Item): Long = (item.trashedAt ?: byPath[item.path]?.takeIf { intact(it, item) }?.trashedAt)
                ?.takeIf { it > 0L } ?: now
            val groups = items.groupBy { idOf(it).first }
            for ((id, all) in groups) {
                // Pending intents are settled first; their recording is not adopted again meanwhile.
                if (byId[id]?.pendingOp != null) { all.forEach { leftInPlace += it.file }; continue }
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
                // A20: a stamped time never moves with a file time; only copies seen for the first time
                // count, a file time is a repair (it may be newer than the recording), and an unknown
                // one (0) is the time first seen.
                val newCopies = candidates.filter { idOf(it).second == null }
                val earliest = newCopies.minOfOrNull { it.modifiedAt.takeIf { time -> time > 0L } ?: now }
                val displayName = existing?.displayName ?: if (canonical.idName == null) canonical.name else canonical.file.name
                val trashedAt = if (canonical.inTrash) trashTime(canonical) else null
                var record = when {
                    existing == null -> RecordingRecord(
                        id, canonical.projectId, displayName, earliest!!, canonical.sha, canonical.size,
                        RecordingRecord.ADOPTED, path = canonical.path, trashedAt = trashedAt, precedenceRepaired = true
                    )
                    // A37: of two repairs the smaller stands; an established real time never moves.
                    existing.precedenceRepaired && earliest != null && earliest < existing.uploadedAt ->
                        existing.copy(path = canonical.path, trashedAt = trashedAt, uploadedAt = earliest)
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
                    record = record.copy(path = targetPath, pendingFrom = canonical.path, pendingTrashedAt = trashedAt,
                        pendingOp = RecordingRecord.OP_MOVE, pendingClaim = newToken())
                    planned += Planned(record, canonical, target)
                }
                kept[id] = record
                listed += ScannedFile(record.toEntry(), target, canonical.inTrash, canonical.path)
            }
            kept.values.toList()
        }
        // Duplicates leave first (each journaled), so a canonical copy can take a name a duplicate held.
        for ((item, id) in quarantined) quarantineLocked(filesDir, item.file, item.projectId, id, item.sha, item.size)
        if (planned.isNotEmpty()) {
            beforeBytesMove?.invoke(planned.mapTo(HashSet()) { it.record.id })
            val failed = HashSet<String>()
            for (move in planned) {
                try {
                    moveNoReplace(move.item.file, move.target, move.record.pendingClaim!!, move.record.sha256, move.record.bytes)
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (_: IOException) {
                    failed += move.record.id
                }
            }
            // Commits the moved ones, undoes the others (their bytes are back at, or never left, their source).
            reconcileLocked(catalog, filesDir)
            if (failed.isNotEmpty()) {
                listed.removeAll { it.entry.id in failed }
                planned.filter { it.record.id in failed }.forEach { leftInPlace += it.item.file }
            }
        }
        return Scan(
            listed.sortedWith(compareBy<ScannedFile> { it.inTrash }.thenBy { it.entry.projectId }.thenBy { it.entry.fileName }),
            leftInPlace.toList()
        )
    }
}
