package com.rhymeai.app.data.repository

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.rhymeai.app.data.model.SongProject
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "rhymeai_prefs")

class ProjectRepository(private val context: Context) {

    companion object {
        private val PROJECTS_KEY = stringPreferencesKey("projects_json")
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

    suspend fun saveProjects(projects: List<SongProject>) {
        context.dataStore.edit { prefs ->
            prefs[PROJECTS_KEY] = json.encodeToString(projects)
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

    suspend fun loadEditorState(): Triple<String, String, String> {
        var title = ""
        var lyrics = ""
        var theme = ""
        context.dataStore.data.collect { prefs ->
            title = prefs[CURRENT_TITLE_KEY] ?: ""
            lyrics = prefs[CURRENT_LYRICS_KEY] ?: ""
            theme = prefs[CURRENT_THEME_KEY] ?: ""
        }
        return Triple(title, lyrics, theme)
    }

    fun editorStateFlow(): Flow<Triple<String, String, String>> = context.dataStore.data.map { prefs ->
        Triple(
            prefs[CURRENT_TITLE_KEY] ?: "",
            prefs[CURRENT_LYRICS_KEY] ?: "",
            prefs[CURRENT_THEME_KEY] ?: ""
        )
    }

    fun apiKeyFlow(provider: String): Flow<String> = context.dataStore.data.map { prefs ->
        when (provider) {
            "GEMINI" -> prefs[GEMINI_API_KEY] ?: ""
            "OPENAI" -> prefs[OPENAI_API_KEY] ?: ""
            "CLAUDE" -> prefs[CLAUDE_API_KEY] ?: ""
            else -> ""
        }
    }

    suspend fun saveApiKey(provider: String, key: String) {
        context.dataStore.edit { prefs ->
            when (provider) {
                "GEMINI" -> prefs[GEMINI_API_KEY] = key
                "OPENAI" -> prefs[OPENAI_API_KEY] = key
                "CLAUDE" -> prefs[CLAUDE_API_KEY] = key
            }
        }
    }

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

    fun allApiKeysFlow(): Flow<Map<String, String>> = context.dataStore.data.map { prefs ->
        mapOf(
            "GEMINI" to (prefs[GEMINI_API_KEY] ?: ""),
            "OPENAI" to (prefs[OPENAI_API_KEY] ?: ""),
            "CLAUDE" to (prefs[CLAUDE_API_KEY] ?: "")
        )
    }
}
