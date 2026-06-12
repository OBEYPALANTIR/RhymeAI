package com.rhymeai.app.data.repository

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
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
    }

    private val json = Json { ignoreUnknownKeys = true }

    val projectsFlow: Flow<List<SongProject>> = context.dataStore.data.map { prefs ->
        val raw = prefs[PROJECTS_KEY] ?: "[]"
        try { json.decodeFromString<List<SongProject>>(raw) } catch (_: Exception) { emptyList() }
    }

    val currentProjectIdFlow: Flow<String?> = context.dataStore.data.map { prefs ->
        prefs[CURRENT_PROJECT_ID_KEY]
    }

    val trashedProjectsFlow: Flow<List<TrashedSongProject>> = context.dataStore.data.map { prefs ->
        val raw = prefs[TRASHED_PROJECTS_KEY] ?: "[]"
        try { json.decodeFromString<List<TrashedSongProject>>(raw) } catch (_: Exception) { emptyList() }
    }

    suspend fun saveProjects(projects: List<SongProject>) {
        context.dataStore.edit { prefs ->
            prefs[PROJECTS_KEY] = json.encodeToString(projects)
        }
    }

    suspend fun saveTrashedProjects(projects: List<TrashedSongProject>) {
        context.dataStore.edit { prefs ->
            prefs[TRASHED_PROJECTS_KEY] = json.encodeToString(projects)
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
