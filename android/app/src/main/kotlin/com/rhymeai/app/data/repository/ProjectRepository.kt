package com.rhymeai.app.data.repository

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "rhymeai_prefs")

class ProjectRepository(
    private val context: Context,
    private val secureKeyStore: SecureKeyStore = EncryptedPrefsKeyStore(context)
) {

    companion object {
        private val PROJECTS_KEY = stringPreferencesKey("projects_json")
        private val TRASHED_PROJECTS_KEY = stringPreferencesKey("trashed_projects_json")
        private val CURRENT_PROJECT_ID_KEY = stringPreferencesKey("current_project_id")
        private val CURRENT_TITLE_KEY = stringPreferencesKey("current_title")
        private val CURRENT_LYRICS_KEY = stringPreferencesKey("current_lyrics")
        private val CURRENT_THEME_KEY = stringPreferencesKey("current_theme")
        private val GEMINI_API_KEY = stringPreferencesKey("gemini_api_key")
        private val OPENAI_API_KEY = stringPreferencesKey("openai_api_key")
        private val CLAUDE_API_KEY = stringPreferencesKey("claude_api_key")
        private val SELECTED_PROVIDER_KEY = stringPreferencesKey("selected_provider")
        private val GEMINI_MODEL_KEY = stringPreferencesKey("gemini_model_id")

        // Editor toggle keys — persisted separately from project data so they
        // survive project switches and app restart without loading an entire project.
        private val EDITOR_WHOLE_SONG_CONTEXT = booleanPreferencesKey("editor_use_whole_song_context")
        private val EDITOR_STRESS_IPA = booleanPreferencesKey("editor_stress_ipa")
        private val EDITOR_HIGHLIGHT_RHYMES = booleanPreferencesKey("editor_highlight_rhymes")
        private val EDITOR_SYLLABLE_COLORING = booleanPreferencesKey("editor_syllable_coloring")
        private val EDITOR_RHYME_HIGHLIGHT = booleanPreferencesKey("editor_rhyme_highlight")
        private val EDITOR_BEAT_GRID = booleanPreferencesKey("editor_beat_grid")
    }

    // Snapshot of all 6 editor-toggle preferences, with sensible on-first-install defaults.
    data class EditorToggles(
        val useWholeSongContext: Boolean = false,
        val isStressIpaEnabled: Boolean = false,
        val isHighlightEnabled: Boolean = true,
        val isSyllableColoringEnabled: Boolean = true,
        val isRhymeHighlightEnabled: Boolean = false,
        val isBeatGridEnabled: Boolean = false
    )

    private val json = Json { ignoreUnknownKeys = true }

    val projectsFlow: Flow<List<SongProject>> = context.dataStore.data.map { prefs ->
        val raw = prefs[PROJECTS_KEY] ?: "[]"
        try { json.decodeFromString<List<SongProject>>(raw) } catch (_: Exception) { emptyList() }
    }.flowOn(Dispatchers.Default)

    val currentProjectIdFlow: Flow<String?> = context.dataStore.data.map { prefs ->
        prefs[CURRENT_PROJECT_ID_KEY]
    }

    val trashedProjectsFlow: Flow<List<TrashedSongProject>> = context.dataStore.data.map { prefs ->
        val raw = prefs[TRASHED_PROJECTS_KEY] ?: "[]"
        try { json.decodeFromString<List<TrashedSongProject>>(raw) } catch (_: Exception) { emptyList() }
    }.flowOn(Dispatchers.Default)

    suspend fun saveProjects(projects: List<SongProject>) {
        val encoded = withContext(Dispatchers.Default) { json.encodeToString(projects) }
        context.dataStore.edit { prefs ->
            prefs[PROJECTS_KEY] = encoded
        }
    }

    suspend fun saveTrashedProjects(projects: List<TrashedSongProject>) {
        val encoded = withContext(Dispatchers.Default) { json.encodeToString(projects) }
        context.dataStore.edit { prefs ->
            prefs[TRASHED_PROJECTS_KEY] = encoded
        }
    }

    suspend fun setCurrentProjectId(id: String?) {
        context.dataStore.edit { prefs ->
            if (id != null) prefs[CURRENT_PROJECT_ID_KEY] = id
            else prefs.remove(CURRENT_PROJECT_ID_KEY)
        }
    }

    suspend fun saveEditorState(title: String, lyrics: String, theme: String) {
        context.dataStore.edit { prefs ->
            prefs[CURRENT_TITLE_KEY] = title
            prefs[CURRENT_LYRICS_KEY] = lyrics
            prefs[CURRENT_THEME_KEY] = theme
        }
    }

    fun editorStateFlow(): Flow<Triple<String, String, String>> = context.dataStore.data.map { prefs ->
        Triple(
            prefs[CURRENT_TITLE_KEY] ?: "",
            prefs[CURRENT_LYRICS_KEY] ?: "",
            prefs[CURRENT_THEME_KEY] ?: ""
        )
    }

    suspend fun saveApiKey(provider: String, key: String) {
        secureKeyStore.setKey(provider, key)
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

    val selectedProviderFlow: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[SELECTED_PROVIDER_KEY] ?: "GEMINI"
    }

    suspend fun saveSelectedProvider(provider: String) {
        context.dataStore.edit { prefs ->
            prefs[SELECTED_PROVIDER_KEY] = provider
        }
    }

    val modelIdFlow: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[GEMINI_MODEL_KEY] ?: ""
    }

    suspend fun saveModelId(id: String) {
        context.dataStore.edit { prefs ->
            prefs[GEMINI_MODEL_KEY] = id
        }
    }

    /** Flow of editor toggle preferences; emits immediately with current values. */
    val editorTogglesFlow: Flow<EditorToggles> = context.dataStore.data.map { prefs ->
        EditorToggles(
            useWholeSongContext = prefs[EDITOR_WHOLE_SONG_CONTEXT] ?: false,
            isStressIpaEnabled = prefs[EDITOR_STRESS_IPA] ?: false,
            isHighlightEnabled = prefs[EDITOR_HIGHLIGHT_RHYMES] ?: true,
            isSyllableColoringEnabled = prefs[EDITOR_SYLLABLE_COLORING] ?: true,
            isRhymeHighlightEnabled = prefs[EDITOR_RHYME_HIGHLIGHT] ?: false,
            isBeatGridEnabled = prefs[EDITOR_BEAT_GRID] ?: false
        )
    }

    /** Persist all 6 editor toggles atomically. */
    suspend fun saveEditorToggles(toggles: EditorToggles) {
        context.dataStore.edit { prefs ->
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
        val prefs = context.dataStore.data.first()
        val legacy = mapOf(
            "GEMINI" to (prefs[GEMINI_API_KEY] ?: ""),
            "OPENAI" to (prefs[OPENAI_API_KEY] ?: ""),
            "CLAUDE" to (prefs[CLAUDE_API_KEY] ?: "")
        )
        val wipeLegacy = ApiKeyMigration.apply(legacy, secureKeyStore)
        if (wipeLegacy) {
            context.dataStore.edit {
                it.remove(GEMINI_API_KEY)
                it.remove(OPENAI_API_KEY)
                it.remove(CLAUDE_API_KEY)
            }
        }
    }
}
