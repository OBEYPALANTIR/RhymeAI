package com.rhymeai.app.data.repository

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.MutablePreferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.data.model.SavedLocalModel
import com.rhymeai.app.data.model.SongWorkspace
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.data.sync.RecordingManifestEntry
import com.rhymeai.app.data.sync.RecordingRecord
import com.rhymeai.app.data.sync.SyncBlob
import com.rhymeai.app.data.sync.SyncDeletion
import com.rhymeai.app.data.sync.SyncMerger
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "rhymeai_prefs")

internal class CorruptLibraryException(
    val area: String,
    cause: Throwable
) : IllegalStateException("Stored $area data could not be read", cause)

internal class MissingActiveProjectException(id: String) :
    IllegalStateException("Song $id is no longer active")

/** A coherent local membership and deletion view captured before Drive network work. */
internal data class LocalSyncBase(
    val blob: SyncBlob,
    val baseIds: Set<String>,
    val pendingIds: Set<String>
)

internal class FailClosedStoredJson<T>(
    private val area: String,
    private val decodeValue: (String) -> T
) {
    @Volatile private var corrupt = false

    fun decode(raw: String): T = try {
        decodeValue(raw).also { corrupt = false }
    } catch (error: Exception) {
        corrupt = true
        throw CorruptLibraryException(area, error)
    }

    fun requireWritable(raw: String) {
        decode(raw)
        check(!corrupt) { "Cannot overwrite unreadable $area data" }
    }
}

class ProjectRepository internal constructor(
    private val dataStore: DataStore<Preferences>,
    private val secureKeyStore: SecureKeyStore
) : com.rhymeai.app.data.recording.RecordingCatalog {
    constructor(
        context: Context,
        secureKeyStore: SecureKeyStore = EncryptedPrefsKeyStore(context)
    ) : this(context.dataStore, secureKeyStore)

    companion object {
        private val WORKSPACES_KEY = stringPreferencesKey("local_song_workspaces_json")
        private val PROJECTS_KEY = stringPreferencesKey("projects_json")
        private val TRASHED_PROJECTS_KEY = stringPreferencesKey("trashed_projects_json")
        private val PENDING_RECORDING_DELETIONS_KEY = stringSetPreferencesKey("pending_recording_deletions")
        private val SYNC_DELETIONS_KEY = stringPreferencesKey("sync_deletions_json")
        private val RECORDING_RECORDS_KEY = stringPreferencesKey("recording_records_json")
        private val FIRST_SEEN_KEY = stringPreferencesKey("first_seen_precedence_json")
        private val CURRENT_PROJECT_ID_KEY = stringPreferencesKey("current_project_id")
        private val CURRENT_TITLE_KEY = stringPreferencesKey("current_title")
        private val CURRENT_LYRICS_KEY = stringPreferencesKey("current_lyrics")
        private val CURRENT_THEME_KEY = stringPreferencesKey("current_theme")
        private val APP_APPEARANCE_KEY = stringPreferencesKey("app_appearance")
        private val GEMINI_API_KEY = stringPreferencesKey("gemini_api_key")
        private val OPENAI_API_KEY = stringPreferencesKey("openai_api_key")
        private val CLAUDE_API_KEY = stringPreferencesKey("claude_api_key")
        private val SELECTED_PROVIDER_KEY = stringPreferencesKey("selected_provider")
        private val GEMINI_MODEL_KEY = stringPreferencesKey("gemini_model_id")
        private val LOCAL_MODELS_KEY = stringPreferencesKey("local_models_json")
        private val SELECTED_LOCAL_MODEL_ID_KEY = stringPreferencesKey("selected_local_model_id")

        // Editor toggle keys — persisted separately from project data so they
        // survive project switches and app restart without loading an entire project.
        private val EDITOR_WHOLE_SONG_CONTEXT = booleanPreferencesKey("editor_use_whole_song_context")
        private val EDITOR_STRESS_IPA = booleanPreferencesKey("editor_stress_ipa")
        private val EDITOR_HIGHLIGHT_RHYMES = booleanPreferencesKey("editor_highlight_rhymes")
        private val EDITOR_SYLLABLE_COLORING = booleanPreferencesKey("editor_syllable_coloring")
        private val EDITOR_RHYME_HIGHLIGHT = booleanPreferencesKey("editor_rhyme_highlight")
        private val EDITOR_BEAT_GRID = booleanPreferencesKey("editor_beat_grid")

        /** Whole Song Context is on until the user saves a value (iOS parity). */
        const val DEFAULT_USE_WHOLE_SONG_CONTEXT = true
    }

    // Snapshot of all 6 editor-toggle preferences, with sensible on-first-install defaults.
    data class EditorToggles(
        val useWholeSongContext: Boolean = DEFAULT_USE_WHOLE_SONG_CONTEXT,
        val isStressIpaEnabled: Boolean = false,
        val isHighlightEnabled: Boolean = true,
        val isSyllableColoringEnabled: Boolean = true,
        val isRhymeHighlightEnabled: Boolean = false,
        val isBeatGridEnabled: Boolean = false
    )

    private val projectSaveMutex = Mutex()
    private val json = Json { ignoreUnknownKeys = true }
    private val projectsStore = FailClosedStoredJson("song library") {
        json.decodeFromString<List<SongProject>>(it)
    }
    private val trashedProjectsStore = FailClosedStoredJson("trash") {
        json.decodeFromString<List<TrashedSongProject>>(it)
    }
    // A33: every tombstone is validated where it is read; a malformed one makes the whole
    // deletion state unreadable, so mutations and lists that depend on it fail closed.
    private val deletionsStore = FailClosedStoredJson("sync deletions") {
        // Validated, and duplicates of one identity collapse to the newest deletion.
        SyncMerger.mergeDeletions(json.decodeFromString<List<SyncDeletion>>(it))
    }
    private val firstSeenStore = FailClosedStoredJson("first-seen times") {
        json.decodeFromString<Map<String, Long>>(it)
    }
    private val recordsStore = FailClosedStoredJson("recording records") {
        json.decodeFromString<List<RecordingRecord>>(it)
    }
    private val workspacesStore = FailClosedStoredJson("song notebook") {
        json.decodeFromString<Map<String, SongWorkspace>>(it)
    }
    private val localModelsStore = FailClosedStoredJson("saved local models") {
        json.decodeFromString<List<SavedLocalModel>>(it)
    }

    // Every preference write (editor position, toggles, notebook) re-emits dataStore.data.
    // Only decode the library when its stored JSON actually changed.
    val projectsFlow: Flow<List<SongProject>> = dataStore.data
        .map { prefs -> prefs[PROJECTS_KEY] ?: "[]" }
        .distinctUntilChanged()
        .map(projectsStore::decode)
        .flowOn(Dispatchers.Default)

    val currentProjectIdFlow: Flow<String?> = dataStore.data.map { prefs ->
        prefs[CURRENT_PROJECT_ID_KEY]
    }

    val trashedProjectsFlow: Flow<List<TrashedSongProject>> = dataStore.data
        .map { prefs -> prefs[TRASHED_PROJECTS_KEY] ?: "[]" }
        .distinctUntilChanged()
        .map(trashedProjectsStore::decode)
        .flowOn(Dispatchers.Default)

    /** Raw tombstone JSON; emits when a song or recording is permanently deleted (drives backup). */
    val syncDeletionsFlow: Flow<String> = dataStore.data
        .map { prefs -> prefs[SYNC_DELETIONS_KEY] ?: "[]" }
        .distinctUntilChanged()

    val workspacesFlow: Flow<Map<String, SongWorkspace>> = dataStore.data.map { prefs ->
        workspacesStore.decode(prefs[WORKSPACES_KEY] ?: "{}")
    }

    suspend fun saveWorkspace(id: String, workspace: SongWorkspace?) {
        dataStore.edit { prefs ->
            val active = projectsStore.decode(prefs[PROJECTS_KEY] ?: "[]")
            if (active.none { it.id == id }) throw MissingActiveProjectException(id)
            val current = workspacesStore.decode(prefs[WORKSPACES_KEY] ?: "{}")
            prefs[WORKSPACES_KEY] = json.encodeToString(
                if (workspace == null) current - id else current + (id to workspace)
            )
        }
    }

    /**
     * Persist only the intended editor entry against the latest library snapshot.
     * A caller's in-memory list may predate a Trash transition; it must never
     * replace membership committed by that transition.
     */
    suspend fun saveActiveState(
        project: SongProject?,
        createIfMissing: Boolean,
        title: String,
        lyrics: String,
        theme: String
    ): List<SongProject> = projectSaveMutex.withLock {
        var committed: List<SongProject>? = null
        dataStore.edit { prefs ->
            val active = projectsStore.decode(prefs[PROJECTS_KEY] ?: "[]")
            val next = if (project == null) {
                active
            } else {
                val stored = active.firstOrNull { it.id == project.id }
                if (stored == null) {
                    if (!createIfMissing ||
                        trashedProjectsStore.decode(prefs[TRASHED_PROJECTS_KEY] ?: "[]")
                            .any { it.project.id == project.id }
                    ) throw MissingActiveProjectException(project.id)
                    listOf(project) + active
                } else {
                    active.map { current ->
                        if (current.id != project.id) current else current.copy(
                            title = project.title,
                            lyrics = project.lyrics,
                            theme = project.theme,
                            updatedAt = if (current.title == project.title &&
                                current.lyrics == project.lyrics && current.theme == project.theme
                            ) current.updatedAt else maxOf(current.updatedAt, project.updatedAt),
                            // A37: an edit is a real time and clears a repair.
                            precedenceRepaired = current.precedenceRepaired && current.title == project.title &&
                                current.lyrics == project.lyrics && current.theme == project.theme
                        )
                    }
                }
            }
            if (project != null) prefs[PROJECTS_KEY] = json.encodeToString(next)
            if (project != null && createIfMissing) {
                prefs[PENDING_RECORDING_DELETIONS_KEY] =
                    (prefs[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()) - project.id
            }
            if (project == null) prefs.remove(CURRENT_PROJECT_ID_KEY)
            else prefs[CURRENT_PROJECT_ID_KEY] = project.id
            prefs[CURRENT_TITLE_KEY] = title
            prefs[CURRENT_LYRICS_KEY] = lyrics
            prefs[CURRENT_THEME_KEY] = theme
            committed = next
        }
        checkNotNull(committed)
    }

    suspend fun selectProject(id: String): SongProject = projectSaveMutex.withLock {
        lateinit var selected: SongProject
        dataStore.edit { prefs ->
            selected = projectsStore.decode(prefs[PROJECTS_KEY] ?: "[]")
                .firstOrNull { it.id == id } ?: throw MissingActiveProjectException(id)
            prefs[CURRENT_PROJECT_ID_KEY] = id
            prefs[CURRENT_TITLE_KEY] = selected.title
            prefs[CURRENT_LYRICS_KEY] = selected.lyrics
            prefs[CURRENT_THEME_KEY] = selected.theme
        }
        selected
    }

    suspend fun saveProjects(projects: List<SongProject>) = projectSaveMutex.withLock {
        val encoded = withContext(Dispatchers.Default) { json.encodeToString(projects) }
        dataStore.edit { prefs ->
            projectsStore.requireWritable(prefs[PROJECTS_KEY] ?: "[]")
            prefs[PROJECTS_KEY] = encoded
            prefs[PENDING_RECORDING_DELETIONS_KEY] =
                (prefs[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()) - projects.map { it.id }.toSet()
        }
    }

    suspend fun saveTrashedProjects(projects: List<TrashedSongProject>) = projectSaveMutex.withLock {
        val encoded = withContext(Dispatchers.Default) { json.encodeToString(projects) }
        dataStore.edit { prefs ->
            trashedProjectsStore.requireWritable(prefs[TRASHED_PROJECTS_KEY] ?: "[]")
            prefs[PENDING_RECORDING_DELETIONS_KEY] =
                (prefs[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()) - projects.map { it.project.id }.toSet()
            prefs[TRASHED_PROJECTS_KEY] = encoded
        }
    }

    data class TrashTransition(
        val projects: List<SongProject>,
        val trashedProjects: List<TrashedSongProject>,
        val wasCurrent: Boolean = false
    )

    data class TrashPurge(val trashedProjects: List<TrashedSongProject>, val purgedIds: List<String>)

    suspend fun moveProjectToTrash(id: String, now: Long): TrashTransition? = projectSaveMutex.withLock {
        var committed: TrashTransition? = null
        dataStore.edit { prefs ->
            val active = projectsStore.decode(prefs[PROJECTS_KEY] ?: "[]")
            val trash = trashedProjectsStore.decode(prefs[TRASHED_PROJECTS_KEY] ?: "[]")
            val project = active.firstOrNull { it.id == id } ?: return@edit
            val nextActive = active.filterNot { it.id == id }
            val nextTrash = listOf(TrashedSongProject(project, now, now + TRASH_RETENTION_MILLIS)) +
                trash.filterNot { it.project.id == id }
            val wasCurrent = prefs[CURRENT_PROJECT_ID_KEY] == id
            prefs[PROJECTS_KEY] = json.encodeToString(nextActive)
            prefs[TRASHED_PROJECTS_KEY] = json.encodeToString(nextTrash)
            prefs[PENDING_RECORDING_DELETIONS_KEY] =
                (prefs[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()) - id
            if (wasCurrent) {
                prefs.remove(CURRENT_PROJECT_ID_KEY)
                prefs[CURRENT_TITLE_KEY] = ""
                prefs[CURRENT_LYRICS_KEY] = ""
                prefs[CURRENT_THEME_KEY] = ""
            }
            committed = TrashTransition(nextActive, nextTrash, wasCurrent)
        }
        committed
    }

    suspend fun restoreTrashedProject(id: String, now: Long): TrashTransition? = projectSaveMutex.withLock {
        var committed: TrashTransition? = null
        dataStore.edit { prefs ->
            val active = projectsStore.decode(prefs[PROJECTS_KEY] ?: "[]")
            val trash = trashedProjectsStore.decode(prefs[TRASHED_PROJECTS_KEY] ?: "[]")
            val entry = trash.firstOrNull { it.project.id == id } ?: return@edit
            val nextActive = listOf(entry.project.copy(updatedAt = now, precedenceRepaired = false)) + active.filterNot { it.id == id }
            val nextTrash = trash.filterNot { it.project.id == id }
            prefs[PROJECTS_KEY] = json.encodeToString(nextActive)
            prefs[PENDING_RECORDING_DELETIONS_KEY] =
                (prefs[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()) - id
            prefs[TRASHED_PROJECTS_KEY] = json.encodeToString(nextTrash)
            committed = TrashTransition(nextActive, nextTrash)
        }
        committed
    }

    override suspend fun recordingRecords(): List<RecordingRecord> =
        recordsStore.decode(dataStore.data.first()[RECORDING_RECORDS_KEY] ?: "[]")

    override suspend fun updateRecordingRecords(transform: (List<RecordingRecord>) -> List<RecordingRecord>) {
        projectSaveMutex.withLock {
            dataStore.edit { prefs ->
                val current = recordsStore.decode(prefs[RECORDING_RECORDS_KEY] ?: "[]")
                val next = transform(current)
                if (next != current) prefs[RECORDING_RECORDS_KEY] = json.encodeToString(next)
            }
        }
    }

    /** Tombstones for a deleted song and every recording this device holds for it, in one write. */
    private fun songTombstones(prefs: Preferences, ids: Collection<String>, deletedAt: Long): List<SyncDeletion> {
        val records = recordsStore.decode(prefs[RECORDING_RECORDS_KEY] ?: "[]")
        return ids.flatMap { id ->
            listOf(SyncDeletion(projectId = id, deletedAt = deletedAt)) +
                records.filter { it.projectId == id && it.path != null }
                    .map { SyncDeletion(id, it.displayName, deletedAt, recordingId = it.id) }
        }
    }

    /**
     * [adopt] gives every recording file of the songs a record first (A26), so the
     * deletion tombstones each of them; if it throws, nothing is deleted.
     */
    suspend fun permanentlyDeleteTrashedProject(
        id: String,
        now: Long = System.currentTimeMillis(),
        adopt: suspend (Set<String>) -> Unit = {}
    ): List<TrashedSongProject>? {
        adopt(setOf(id))
        return permanentlyDeleteAdopted(id, now)
    }

    private suspend fun permanentlyDeleteAdopted(id: String, now: Long): List<TrashedSongProject>? = projectSaveMutex.withLock {
        var committed: List<TrashedSongProject>? = null
        dataStore.edit { prefs ->
            val trash = trashedProjectsStore.decode(prefs[TRASHED_PROJECTS_KEY] ?: "[]")
            val workspaces = workspacesStore.decode(prefs[WORKSPACES_KEY] ?: "{}")
            if (trash.none { it.project.id == id }) return@edit
            val nextTrash = trash.filterNot { it.project.id == id }
            val deletions = deletionsStore.decode(prefs[SYNC_DELETIONS_KEY] ?: "[]")
            prefs[TRASHED_PROJECTS_KEY] = json.encodeToString(nextTrash)
            prefs[WORKSPACES_KEY] = json.encodeToString(workspaces - id)
            prefs[PENDING_RECORDING_DELETIONS_KEY] =
                (prefs[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()) + id
            prefs[SYNC_DELETIONS_KEY] = json.encodeToString(
                SyncMerger.mergeDeletions(deletions + songTombstones(prefs, listOf(id), now))
            )
            committed = nextTrash
        }
        committed
    }

    suspend fun purgeExpiredTrashedProjects(now: Long, adopt: suspend (Set<String>) -> Unit = {}): TrashPurge {
        // A32/A37: a Trash entry without a time gets its first-seen time (and a deadline from it)
        // before anything is chosen for expiry, so a zero deadline never expires it at once.
        establishPrecedence(emptyList(), now)
        val expiring = trashedProjectsStore.decode(dataStore.data.first()[TRASHED_PROJECTS_KEY] ?: "[]")
            .filter { it.deleteAfter <= now }.mapTo(HashSet()) { it.project.id }
        adopt(expiring)
        return purgeAdopted(now, expiring)
    }

    /** Only songs whose recordings were adopted expire in this pass. */
    private suspend fun purgeAdopted(now: Long, adopted: Set<String>): TrashPurge = projectSaveMutex.withLock {
        lateinit var committed: TrashPurge
        dataStore.edit { prefs ->
            // The same repair inside the deciding transaction: whatever was stored meanwhile is fixed first.
            normalizePrecedence(prefs, emptyList(), now)
            val trash = trashedProjectsStore.decode(prefs[TRASHED_PROJECTS_KEY] ?: "[]")
            val expired = trash.filter { it.deleteAfter <= now && it.project.id in adopted }.map { it.project.id }
            val retained = trash.filterNot { it.project.id in expired }
            if (expired.isNotEmpty()) {
                val workspaces = workspacesStore.decode(prefs[WORKSPACES_KEY] ?: "{}")
                val deletions = deletionsStore.decode(prefs[SYNC_DELETIONS_KEY] ?: "[]")
                prefs[TRASHED_PROJECTS_KEY] = json.encodeToString(retained)
                prefs[WORKSPACES_KEY] = json.encodeToString(workspaces - expired.toSet())
                prefs[PENDING_RECORDING_DELETIONS_KEY] =
                    (prefs[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()) + expired
                prefs[SYNC_DELETIONS_KEY] = json.encodeToString(
                    SyncMerger.mergeDeletions(deletions + songTombstones(prefs, expired, now))
                )
            }
            committed = TrashPurge(retained, expired)
        }
        committed
    }

    /**
     * A32: every song, trashed song and recording among [inputs] whose precedence time is
     * missing (zero) gets the time this device first saw it, by identity, persisted here
     * before any comparison or naming and reused on every later merge; it then travels
     * in the manifest. Returns the inputs with those times filled in.
     */
    suspend fun establishPrecedence(inputs: List<SyncBlob>, now: Long): List<SyncBlob> {
        var established = inputs
        projectSaveMutex.withLock {
            dataStore.edit { prefs -> established = normalizePrecedence(prefs, inputs, now) }
        }
        return established
    }

    /**
     * A32 within one edit: missing times among [inputs] and among this device's own songs,
     * Trash and recording records get their first-seen times (kept by identity), and the
     * local state stores them, so lists, playback, exports and later merges all use them.
     */
    private fun normalizePrecedence(prefs: MutablePreferences, inputs: List<SyncBlob>, now: Long): List<SyncBlob> {
        val projects = projectsStore.decode(prefs[PROJECTS_KEY] ?: "[]")
        val trash = trashedProjectsStore.decode(prefs[TRASHED_PROJECTS_KEY] ?: "[]")
        val records = recordsStore.decode(prefs[RECORDING_RECORDS_KEY] ?: "[]")
        // A37: every repaired time known for an identity, here or in any input; the smallest stands.
        val known = firstSeenStore.decode(prefs[FIRST_SEEN_KEY] ?: "{}")
        val repairs = HashMap(known)
        val needed = HashSet<String>()
        fun see(key: String, time: Long, repaired: Boolean) {
            if (time <= 0L) needed += key else if (repaired) repairs.merge(key, time, ::minOf)
        }
        fun seeSong(p: SongProject) = see("song:${p.id}", p.updatedAt, p.precedenceRepaired)
        fun seeTrash(t: TrashedSongProject) {
            seeSong(t.project)
            see("trash:${t.project.id}", t.deletedAt, t.deletedAtRepaired)
        }
        // A37: a real time for a recording this device only holds a repair for replaces it here,
        // so lists, playback and quarantine compare what the merge compares.
        val realRecordingTimes = HashMap<String, Long>()
        for (blob in inputs) {
            blob.projects.forEach(::seeSong)
            blob.trashed.forEach(::seeTrash)
            blob.recordings.forEach { see("rec:${it.id}", it.precedenceTime, it.precedenceRepaired) }
            blob.recordings.filter { it.precedenceTime > 0L && !it.precedenceRepaired }
                .forEach { realRecordingTimes.putIfAbsent(it.id, it.precedenceTime) }
        }
        projects.forEach(::seeSong)
        trash.forEach(::seeTrash)
        records.forEach { see("rec:${it.id}", it.uploadedAt, it.precedenceRepaired) }
        for (key in needed) repairs.putIfAbsent(key, now)
        if (repairs != known) prefs[FIRST_SEEN_KEY] = json.encodeToString(repairs.toMap())
        fun song(p: SongProject) =
            if (p.updatedAt > 0L && !p.precedenceRepaired) p else p.copy(updatedAt = repairs.getValue("song:${p.id}"), precedenceRepaired = true)
        fun trashed(t: TrashedSongProject): TrashedSongProject {
            val withSong = t.copy(project = song(t.project))
            if (t.deletedAt > 0L && !t.deletedAtRepaired) return withSong
            // The Trash deadline always follows the repaired time.
            val at = repairs.getValue("trash:${t.project.id}")
            return withSong.copy(deletedAt = at, deleteAfter = at + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS, deletedAtRepaired = true)
        }
        fun record(r: RecordingRecord) = when {
            r.uploadedAt > 0L && !r.precedenceRepaired -> r
            r.id in realRecordingTimes -> r.copy(uploadedAt = realRecordingTimes.getValue(r.id), precedenceRepaired = false)
            else -> r.copy(uploadedAt = repairs.getValue("rec:${r.id}"), precedenceRepaired = true)
        }
        projects.map(::song).let { if (it != projects) prefs[PROJECTS_KEY] = json.encodeToString(it) }
        trash.map(::trashed).let { if (it != trash) prefs[TRASHED_PROJECTS_KEY] = json.encodeToString(it) }
        records.map(::record).let { if (it != records) prefs[RECORDING_RECORDS_KEY] = json.encodeToString(it) }
        return inputs.map { blob ->
            blob.copy(
                projects = blob.projects.map(::song),
                trashed = blob.trashed.map(::trashed),
                recordings = blob.recordings.map { r ->
                    if (r.precedenceTime > 0L && !r.precedenceRepaired) r
                    else r.copy(uploadedAt = repairs.getValue("rec:${r.id}"), precedenceRepaired = true)
                }
            )
        }
    }

    suspend fun syncDeletions(): List<SyncDeletion> =
        deletionsStore.decode(dataStore.data.first()[SYNC_DELETIONS_KEY] ?: "[]")

    override suspend fun requireDeletionsReadable() {
        syncDeletions()
    }

    /**
     * Tombstone one recording so no device restores it through Drive sync. Callers
     * write this before deleting the file; a failed write keeps the file in Trash.
     */
    suspend fun recordRecordingDeletion(projectId: String, fileName: String, recordingId: String, deletedAt: Long) =
        projectSaveMutex.withLock {
            dataStore.edit { prefs ->
                val deletions = deletionsStore.decode(prefs[SYNC_DELETIONS_KEY] ?: "[]")
                prefs[SYNC_DELETIONS_KEY] = json.encodeToString(
                    SyncMerger.mergeDeletions(deletions + SyncDeletion(projectId, fileName, deletedAt, recordingId = recordingId))
                )
            }
        }

    /** A deletion becomes retryable in the same commit that removes its song and notebook. */
    suspend fun pendingRecordingDeletionIds(): Set<String> =
        dataStore.data.first()[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()

    /** Read all sync-relevant repository fields from one DataStore generation. */
    internal suspend fun snapshotLocalSyncBase(): LocalSyncBase {
        val prefs = dataStore.data.first()
        val projects = projectsStore.decode(prefs[PROJECTS_KEY] ?: "[]")
        val trash = trashedProjectsStore.decode(prefs[TRASHED_PROJECTS_KEY] ?: "[]")
        val deletions = SyncMerger.mergeDeletions(deletionsStore.decode(prefs[SYNC_DELETIONS_KEY] ?: "[]"))
        val ids = buildSet {
            projects.forEach { add(it.id) }
            trash.forEach { add(it.project.id) }
        }
        return LocalSyncBase(
            blob = SyncBlob(
                projects = projects,
                trashed = trash,
                deletions = deletions,
                savedAt = System.currentTimeMillis()
            ),
            baseIds = ids,
            pendingIds = prefs[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()
        )
    }

    /**
     * Apply a merged backup in one edit against the data as it is now: the current
     * songs, trash and tombstones are merged with [merged] again (newest `updatedAt`
     * per id, tombstones by timestamp), so an edit saved after [base] was read is
     * kept. IDs removed after the base read stay removed; new local IDs stay.
     */
    internal suspend fun applySyncResult(merged: SyncBlob, base: LocalSyncBase): SyncBlob =
        projectSaveMutex.withLock {
            lateinit var committed: SyncBlob
            dataStore.edit { prefs ->
                // Live and Trash recordings known here join the inputs, so a song tombstone
                // being applied also tombstones takes this device holds only in Trash.
                // A32: this device's current state and the incoming inputs get their first-seen
                // times before anything is compared.
                normalizePrecedence(prefs, emptyList(), System.currentTimeMillis())
                val current = SyncBlob(
                    projects = projectsStore.decode(prefs[PROJECTS_KEY] ?: "[]"),
                    trashed = trashedProjectsStore.decode(prefs[TRASHED_PROJECTS_KEY] ?: "[]"),
                    recordings = recordsStore.decode(prefs[RECORDING_RECORDS_KEY] ?: "[]").filter { it.path != null }.map { it.toEntry() },
                    deletions = SyncMerger.mergeDeletions(deletionsStore.decode(prefs[SYNC_DELETIONS_KEY] ?: "[]"))
                )
                val incoming = normalizePrecedence(prefs, listOf(merged), System.currentTimeMillis()).single()
                // A25: a song deleted here after the snapshot stays deleted only if its
                // tombstone is newer than the incoming version; timestamps decide, not membership.
                val resolved = SyncMerger.merge(current, incoming)
                val nextProjects = resolved.projects
                val nextTrash = resolved.trashed
                val writtenIds = buildSet {
                    nextProjects.forEach { add(it.id) }
                    nextTrash.forEach { add(it.project.id) }
                }
                prefs[PROJECTS_KEY] = json.encodeToString(nextProjects)
                prefs[TRASHED_PROJECTS_KEY] = json.encodeToString(nextTrash)
                prefs[SYNC_DELETIONS_KEY] = json.encodeToString(resolved.deletions)
                prefs[PENDING_RECORDING_DELETIONS_KEY] =
                    (prefs[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()) - writtenIds
                committed = resolved
            }
            committed
        }

    /**
     * Serialize cleanup with project transitions: never remove recordings for an ID
     * that has become active or trashed again (for example after a Drive restore).
     * A failed or interrupted directory removal leaves its durable pending marker.
     */
    suspend fun retryPendingRecordingDeletions(
        onlyId: String? = null,
        deleteDirectory: suspend (String) -> Boolean
    ): Boolean {
        // Decided under this lock, cleaned outside it: the cleanup takes the recording lock,
        // which is always taken before this one (lock order). The cleanup itself deletes only
        // recordings a winning tombstone removes, so a song revived meanwhile loses nothing.
        val (blocked, ready) = projectSaveMutex.withLock {
            val prefs = dataStore.data.first()
            val active = projectsStore.decode(prefs[PROJECTS_KEY] ?: "[]")
            val trash = trashedProjectsStore.decode(prefs[TRASHED_PROJECTS_KEY] ?: "[]")
            // A33: no recording bytes are deleted unless the deletion state is readable and valid.
            deletionsStore.decode(prefs[SYNC_DELETIONS_KEY] ?: "[]")
            pendingRecordingDeletionIds().filter { onlyId == null || it == onlyId }
                .partition { id -> active.any { it.id == id } || trash.any { it.project.id == id } }
        }
        var complete = blocked.isEmpty()
        for (id in ready) {
            val removed = try {
                deleteDirectory(id)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                false
            }
            if (!removed) {
                complete = false
                continue
            }
            projectSaveMutex.withLock {
                dataStore.edit { current ->
                    val active = projectsStore.decode(current[PROJECTS_KEY] ?: "[]")
                    val trash = trashedProjectsStore.decode(current[TRASHED_PROJECTS_KEY] ?: "[]")
                    if (active.none { it.id == id } && trash.none { it.project.id == id }) {
                        current[PENDING_RECORDING_DELETIONS_KEY] = (current[PENDING_RECORDING_DELETIONS_KEY] ?: emptySet()) - id
                    }
                }
            }
        }
        return complete
    }

    suspend fun setCurrentProjectId(id: String?) {
        dataStore.edit { prefs ->
            if (id != null) prefs[CURRENT_PROJECT_ID_KEY] = id
            else prefs.remove(CURRENT_PROJECT_ID_KEY)
        }
    }

    suspend fun saveEditorState(title: String, lyrics: String, theme: String) {
        dataStore.edit { prefs ->
            prefs[CURRENT_TITLE_KEY] = title
            prefs[CURRENT_LYRICS_KEY] = lyrics
            prefs[CURRENT_THEME_KEY] = theme
        }
    }

    fun editorStateFlow(): Flow<Triple<String, String, String>> = dataStore.data.map { prefs ->
        Triple(
            prefs[CURRENT_TITLE_KEY] ?: "",
            prefs[CURRENT_LYRICS_KEY] ?: "",
            prefs[CURRENT_THEME_KEY] ?: ""
        )
    }

    val appearanceFlow: Flow<AppAppearance> = dataStore.data.map { prefs ->
        AppAppearance.fromStorage(prefs[APP_APPEARANCE_KEY])
    }

    suspend fun saveAppearance(appearance: AppAppearance) {
        dataStore.edit { prefs ->
            prefs[APP_APPEARANCE_KEY] = appearance.storageValue
        }
    }

    suspend fun saveApiKey(provider: String, key: String) {
        withContext(Dispatchers.IO) {
            secureKeyStore.setKey(provider, key)
        }
    }

    /**
     * Synchronous read of a single provider's key. Backed by the encrypted store,
     * which is an in-memory `SharedPreferences` instance after the first access,
     * so this is cheap to call from the request hot path.
     */
    fun getApiKey(provider: String): String = secureKeyStore.getKey(provider)

    /**
     * One-shot snapshot for UI flows that need to display the existing key
     * (e.g. seeding the Settings dialog's editing fields). The returned map is
     * not retained; callers should not stash it in long-lived state.
     */
    fun apiKeySnapshot(): Map<String, String> = secureKeyStore.allKeys()

    val selectedProviderFlow: Flow<String> = dataStore.data.map { prefs ->
        prefs[SELECTED_PROVIDER_KEY] ?: "LOCAL"
    }

    suspend fun saveSelectedProvider(provider: String) {
        dataStore.edit { prefs ->
            prefs[SELECTED_PROVIDER_KEY] = provider
        }
    }

    val cloudAIConsentsFlow: Flow<Set<String>> = dataStore.data.map { prefs ->
        prefs[androidx.datastore.preferences.core.stringSetPreferencesKey("cloud_ai_consent_v1")] ?: emptySet()
    }

    suspend fun saveCloudAIConsent(key: String, allowed: Boolean) {
        dataStore.edit { prefs ->
            val consentKey = androidx.datastore.preferences.core.stringSetPreferencesKey("cloud_ai_consent_v1")
            val current = prefs[consentKey] ?: emptySet()
            prefs[consentKey] = if (allowed) current + key else current - key
        }
    }

    val modelIdFlow: Flow<String> = dataStore.data.map { prefs ->
        prefs[GEMINI_MODEL_KEY] ?: ""
    }

    suspend fun saveModelId(id: String) {
        dataStore.edit { prefs ->
            prefs[GEMINI_MODEL_KEY] = id
        }
    }

    val localModelsFlow: Flow<List<SavedLocalModel>> = dataStore.data.map { prefs ->
        localModelsStore.decode(prefs[LOCAL_MODELS_KEY] ?: "[]")
    }.flowOn(Dispatchers.Default)

    suspend fun saveLocalModels(models: List<SavedLocalModel>) {
        val encoded = withContext(Dispatchers.Default) { json.encodeToString(models) }
        dataStore.edit { prefs ->
            localModelsStore.requireWritable(prefs[LOCAL_MODELS_KEY] ?: "[]")
            prefs[LOCAL_MODELS_KEY] = encoded
        }
    }

    val selectedLocalModelIdFlow: Flow<String?> = dataStore.data.map { prefs ->
        prefs[SELECTED_LOCAL_MODEL_ID_KEY]
    }

    suspend fun saveSelectedLocalModelId(id: String?) {
        dataStore.edit { prefs ->
            if (id == null) {
                prefs.remove(SELECTED_LOCAL_MODEL_ID_KEY)
            } else {
                prefs[SELECTED_LOCAL_MODEL_ID_KEY] = id
            }
        }
    }

    /** Flow of editor toggle preferences; emits immediately with current values. */
    val editorTogglesFlow: Flow<EditorToggles> = dataStore.data.map { prefs ->
        EditorToggles(
            useWholeSongContext = prefs[EDITOR_WHOLE_SONG_CONTEXT] ?: DEFAULT_USE_WHOLE_SONG_CONTEXT,
            isStressIpaEnabled = prefs[EDITOR_STRESS_IPA] ?: false,
            isHighlightEnabled = prefs[EDITOR_HIGHLIGHT_RHYMES] ?: true,
            isSyllableColoringEnabled = prefs[EDITOR_SYLLABLE_COLORING] ?: true,
            isRhymeHighlightEnabled = prefs[EDITOR_RHYME_HIGHLIGHT] ?: false,
            isBeatGridEnabled = prefs[EDITOR_BEAT_GRID] ?: false
        )
    }

    /** Persist all 6 editor toggles atomically. */
    suspend fun saveEditorToggles(toggles: EditorToggles) {
        dataStore.edit { prefs ->
            prefs[EDITOR_WHOLE_SONG_CONTEXT] = toggles.useWholeSongContext
            prefs[EDITOR_STRESS_IPA] = toggles.isStressIpaEnabled
            prefs[EDITOR_HIGHLIGHT_RHYMES] = toggles.isHighlightEnabled
            prefs[EDITOR_SYLLABLE_COLORING] = toggles.isSyllableColoringEnabled
            prefs[EDITOR_RHYME_HIGHLIGHT] = toggles.isRhymeHighlightEnabled
            prefs[EDITOR_BEAT_GRID] = toggles.isBeatGridEnabled
        }
    }

    /**
     * Move any plaintext API keys still living in DataStore (from app versions
     * before 0.3) into the encrypted store, then wipe the originals. Idempotent:
     * subsequent calls find no legacy entries and do nothing.
     */
    suspend fun ensureApiKeysMigrated() {
        val prefs = dataStore.data.first()
        val legacy = mapOf(
            "GEMINI" to (prefs[GEMINI_API_KEY] ?: ""),
            "OPENAI" to (prefs[OPENAI_API_KEY] ?: ""),
            "CLAUDE" to (prefs[CLAUDE_API_KEY] ?: "")
        )
        val wipeLegacy = withContext(Dispatchers.IO) {
            ApiKeyMigration.apply(legacy, secureKeyStore)
        }
        if (wipeLegacy) {
            dataStore.edit {
                it.remove(GEMINI_API_KEY)
                it.remove(OPENAI_API_KEY)
                it.remove(CLAUDE_API_KEY)
            }
        }
    }
}
