package com.rhymeai.app.data.repository

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.data.model.OneLiner
import com.rhymeai.app.data.model.OneLinersSnapshot
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedOneLiner
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * A save that failed after its take was adopted. [takeNowAt] is where the take really is
 * now (back in pending, or still in place when the move back failed), so a retry adopts it
 * from there and the take is never lost.
 */
class OneLinerSaveFailure(cause: Throwable, val takeNowAt: File?) : java.io.IOException("One liner not saved", cause)

/** An audio-only line has no words to put into a song. */
class OneLinerHasNoWordsException : IllegalStateException("Transcribe or type the words first.")

/**
 * Reads and writes the One Liners pool, beside the songs in the same DataStore and in the
 * same JSON style. Audio lives in [audioRoot] (one file per line, named in the row); takes
 * being recorded stay in [pendingRoot] until a save adopts them. Audio in [audioRoot] is never
 * removed automatically: only Delete Forever and the Trash purge remove a take.
 */
// TODO: back up one liners (and their audio) with DriveSyncService once the backup manifest carries them.
class OneLinersStore internal constructor(
    private val dataStore: DataStore<Preferences>,
    val audioRoot: File,
    /** Where the widget snapshot is written after every change; null writes none. */
    private val snapshotFile: File? = null,
    /** Called after a snapshot is written (the app refreshes its widgets here). */
    private val onSnapshot: suspend () -> Unit = {}
) {
    constructor(context: Context, onSnapshot: suspend () -> Unit = {}) : this(
        context.dataStore,
        File(context.filesDir, AUDIO_FOLDER),
        snapshotFile(context),
        onSnapshot
    )

    companion object {
        const val AUDIO_FOLDER = "one-liners"
        const val PENDING_FOLDER = "pending"
        const val DELETING_FOLDER = "deleting"
        /** A take older than this in pending was left by an app that closed mid-capture. */
        const val ABANDONED_TAKE_AGE_MILLIS = 24L * 60L * 60L * 1000L
        /** A set-aside file no row names is removed once it is this old. */
        const val ORPHAN_AUDIO_AGE_MILLIS = 7L * 24L * 60L * 60L * 1000L
        private val LINES_KEY = stringPreferencesKey("one_liners_json")
        private val TRASH_KEY = stringPreferencesKey("trashed_one_liners_json")

        fun snapshotFile(context: Context) = File(context.filesDir, "one-liners-widget.json")

        /** Case-insensitive substring match; a blank query keeps everything. */
        fun filter(lines: List<OneLiner>, query: String): List<OneLiner> {
            val q = query.trim()
            return if (q.isEmpty()) lines else lines.filter { it.text.contains(q, ignoreCase = true) }
        }

        fun appendingLine(line: String, lyrics: String): String = when {
            lyrics.isEmpty() -> line
            lyrics.endsWith("\n") -> lyrics + line
            else -> lyrics + "\n" + line
        }
    }

    /** Tests make a commit fail here, inside the write, so nothing is stored. */
    internal var beforeCommit: () -> Unit = {}
    /** Tests make a file move fail. */
    internal var moveFile: (File, File) -> Unit = { from, to ->
        Files.move(from.toPath(), to.toPath(), StandardCopyOption.ATOMIC_MOVE)
    }

    // Defaults are written too: a time default equal to "now" at encode would otherwise be dropped and re-read as a later now.
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val linesStore = FailClosedStoredJson("one liners") { json.decodeFromString<List<OneLiner>>(it) }
    private val trashStore = FailClosedStoredJson("one liners trash") { json.decodeFromString<List<TrashedOneLiner>>(it) }

    val pendingRoot: File get() = File(audioRoot, PENDING_FOLDER)
    /** Audio set aside by a delete until the row's removal is stored. */
    private val deletingRoot: File get() = File(audioRoot, DELETING_FOLDER)

    fun audioFile(fileName: String) = File(audioRoot, fileName)

    /** Newest first. */
    val linesFlow: Flow<List<OneLiner>> = dataStore.data
        .map { it[LINES_KEY] ?: "[]" }
        .distinctUntilChanged()
        .map { raw -> linesStore.decode(raw).sortedByDescending { it.createdAt } }
        .flowOn(Dispatchers.Default)

    /** Most recently trashed first. */
    val trashFlow: Flow<List<TrashedOneLiner>> = dataStore.data
        .map { it[TRASH_KEY] ?: "[]" }
        .distinctUntilChanged()
        .map { raw -> trashStore.decode(raw).sortedByDescending { it.deletedAt } }
        .flowOn(Dispatchers.Default)

    suspend fun all(): List<OneLiner> = linesFlow.first()
    suspend fun trashed(): List<TrashedOneLiner> = trashFlow.first()

    private data class Pool(val lines: List<OneLiner>, val trash: List<TrashedOneLiner>)

    private fun read(prefs: Preferences) =
        Pool(linesStore.decode(prefs[LINES_KEY] ?: "[]"), trashStore.decode(prefs[TRASH_KEY] ?: "[]"))

    /** One read-modify-write; [block] returns null to store nothing. */
    private suspend fun <T : Any> change(block: (Pool) -> Pair<Pool, T>?): T? {
        var result: T? = null
        var committed: Pool? = null
        var appearance: String? = null
        dataStore.edit { prefs ->
            val (next, value) = block(read(prefs)) ?: return@edit
            beforeCommit()
            prefs[LINES_KEY] = json.encodeToString(next.lines)
            prefs[TRASH_KEY] = json.encodeToString(next.trash)
            appearance = prefs[ProjectRepository.APP_APPEARANCE_KEY]
            committed = next
            result = value
        }
        committed?.let { publishSnapshot(it.lines, appearance) }
        return result
    }

    /**
     * Saves a new line. A take is moved from its pending place into [audioRoot] first; if the
     * save fails it is moved back and the failure says where the take is, so the caller still
     * holds it.
     */
    suspend fun add(text: String, take: File? = null, audioDurationMs: Long = 0L, now: Long = System.currentTimeMillis()): OneLiner {
        val adopted = take?.let { audioFile(it.name) }
        if (take != null && adopted != null) withContext(Dispatchers.IO) {
            audioRoot.mkdirs()
            // A retry after a failed move back finds the take already in place.
            if (take.canonicalPath != adopted.canonicalPath) moveFile(take, adopted)
        }
        val line = OneLiner(createdAt = now, audioFileName = adopted?.name, audioDurationMs = audioDurationMs).withText(text)
        try {
            change { pool -> pool.copy(lines = pool.lines + line) to line }
        } catch (error: Exception) {
            if (take == null || adopted == null) throw error
            if (take.canonicalPath == adopted.canonicalPath) throw OneLinerSaveFailure(error, adopted)
            val takeNowAt = withContext(Dispatchers.IO) {
                runCatching { moveFile(adopted, take); take }.getOrDefault(adopted)
            }
            throw OneLinerSaveFailure(error, takeNowAt)
        }
        return line
    }

    /** New words for a line; the prosody follows. */
    suspend fun updateText(id: String, text: String): OneLiner? = change { pool ->
        val line = pool.lines.firstOrNull { it.id == id } ?: return@change null
        val updated = line.withText(text)
        pool.copy(lines = pool.lines.map { if (it.id == id) updated else it }) to updated
    }

    suspend fun trash(id: String, now: Long = System.currentTimeMillis()): TrashedOneLiner? = change { pool ->
        val line = pool.lines.firstOrNull { it.id == id } ?: return@change null
        val trashed = TrashedOneLiner(line, now)
        // One Trash copy per line.
        Pool(pool.lines.filterNot { it.id == id }, listOf(trashed) + pool.trash.filterNot { it.line.id == id }) to trashed
    }

    /** Restores the line and drops every Trash copy of it. */
    suspend fun restore(id: String): OneLiner? = change { pool ->
        val line = pool.trash.firstOrNull { it.line.id == id }?.line ?: return@change null
        Pool(pool.lines.filterNot { it.id == id } + line, pool.trash.filterNot { it.line.id == id }) to line
    }

    /**
     * The audio is set aside first (unless another row still uses it), the row is removed,
     * and only once that is stored does the set-aside file go. A failed save puts the file
     * back beside the row it still belongs to.
     */
    suspend fun permanentlyDelete(id: String): Boolean {
        val pool = read(dataStore.data.first())
        val trashed = pool.trash.firstOrNull { it.line.id == id } ?: return false
        val fileName = trashed.line.audioFileName
        val referencedElsewhere = fileName != null && (
            pool.lines.any { it.audioFileName == fileName } ||
                pool.trash.any { it.line.id != id && it.line.audioFileName == fileName }
            )
        val original = fileName?.let(::audioFile)
        val aside = fileName?.let { File(deletingRoot, it) }
        val staged = withContext(Dispatchers.IO) {
            if (original == null || aside == null || referencedElsewhere || !original.exists()) return@withContext false
            deletingRoot.mkdirs()
            aside.delete()
            moveFile(original, aside)
            true
        }
        try {
            change { current -> current.copy(trash = current.trash.filterNot { it.line.id == id }) to Unit }
        } catch (error: Exception) {
            if (staged) withContext(Dispatchers.IO) { runCatching { moveFile(aside!!, original!!) } }
            throw error
        }
        // A leftover here is removed by the next reconcile.
        if (staged) withContext(Dispatchers.IO) { aside!!.delete() }
        return true
    }

    suspend fun purgeExpired(now: Long = System.currentTimeMillis()): List<String> {
        val expired = trashed().filter { it.deleteAfter <= now }.map { it.line.id }.distinct()
        expired.forEach { permanentlyDelete(it) }
        return expired
    }

    /** The next time a Trash copy expires, for the Trash scheduler. */
    suspend fun nextExpiry(now: Long = System.currentTimeMillis()): Long? =
        trashed().map { it.deleteAfter }.filter { it > now }.minOrNull()

    /**
     * Run at launch. Never deletes from the main folder. A set-aside file a row still names
     * (a delete that stopped before its save) goes back; other set-aside files go after a
     * week, and pending takes an app left behind after a day.
     */
    suspend fun reconcileAudioFiles(now: Long = System.currentTimeMillis()) {
        val pool = read(dataStore.data.first())
        val referenced = (pool.lines.mapNotNull { it.audioFileName } + pool.trash.mapNotNull { it.line.audioFileName }).toSet()
        withContext(Dispatchers.IO) {
            deletingRoot.listFiles().orEmpty().forEach { file ->
                val home = audioFile(file.name)
                if (file.name in referenced) {
                    if (!home.exists()) runCatching { moveFile(file, home) }
                } else if (now - file.lastModified() > ORPHAN_AUDIO_AGE_MILLIS) {
                    file.delete()
                }
            }
            pendingRoot.listFiles().orEmpty().forEach { take ->
                if (now - take.lastModified() > ABANDONED_TAKE_AGE_MILLIS) take.delete()
            }
        }
    }

    /** Marks the line used inside another store write (the song's), so both land or neither does. */
    internal fun markUsedIn(prefs: MutablePreferences, id: String, projectId: String) {
        val pool = read(prefs)
        require(pool.lines.any { it.id == id }) { "One liner $id is gone" }
        prefs[LINES_KEY] = json.encodeToString(pool.lines.map { if (it.id == id) it.copy(usedInProjectId = projectId) else it })
    }

    suspend fun markUsed(id: String, projectId: String?): OneLiner? = change { pool ->
        val line = pool.lines.firstOrNull { it.id == id } ?: return@change null
        val updated = line.copy(usedInProjectId = projectId)
        pool.copy(lines = pool.lines.map { if (it.id == id) updated else it }) to updated
    }

    /**
     * Appends the line to a song that is not open in the editor, as its new last line. The
     * song and the used marker are stored in one write: both land, or neither does. Returns
     * the stored songs; null when the song is no longer active.
     */
    suspend fun sendToSong(id: String, projectId: String, songs: ProjectRepository, now: Long = System.currentTimeMillis()): List<SongProject>? {
        val line = all().firstOrNull { it.id == id } ?: return null
        if (line.text.isBlank()) throw OneLinerHasNoWordsException()
        return songs.appendLineToProject(projectId, line.text.trim(), now) { prefs -> markUsedIn(prefs, id, projectId) }
    }

    /** Refreshes the widget snapshot (also after an appearance change). */
    suspend fun publishSnapshot() {
        val prefs = runCatching { dataStore.data.first() }.getOrNull() ?: return
        val lines = runCatching { read(prefs).lines }.getOrNull() ?: return
        publishSnapshot(lines, prefs[ProjectRepository.APP_APPEARANCE_KEY])
    }

    /** A failure here never fails the change that called it. */
    private suspend fun publishSnapshot(lines: List<OneLiner>, appearance: String?) {
        val file = snapshotFile ?: return
        val newest = lines.sortedByDescending { it.createdAt }.take(OneLinersSnapshot.LINE_LIMIT)
        val snapshot = OneLinersSnapshot(
            count = lines.size,
            lines = newest.map { OneLinersSnapshot.Line(it.id, it.text, it.createdAt, it.audioFileName != null) },
            appearance = AppAppearance.fromStorage(appearance).storageValue
        )
        runCatching {
            withContext(Dispatchers.IO) {
                file.parentFile?.mkdirs()
                val temp = File(file.parentFile, file.name + ".tmp")
                temp.writeText(json.encodeToString(snapshot))
                Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
            onSnapshot()
        }
    }
}
