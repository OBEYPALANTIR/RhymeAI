package com.rhymeai.app.data.repository

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import com.rhymeai.app.data.repository.ProjectRepository.EditorToggles
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Unit tests for the EditorToggles data class used as a persistence snapshot,
 * plus the whole-song default through a file-backed JVM DataStore.
 */
class EditorTogglePersistenceTest {

    @Test
    fun defaultValuesMatchExpectedOnFirstInstall() {
        val defaults = EditorToggles()
        assertTrue(defaults.useWholeSongContext, "Whole song context should default on")
        assertFalse(defaults.isStressIpaEnabled, "Stress IPA should default off")
        assertTrue(defaults.isHighlightEnabled, "Highlight rhymes should default on")
        assertTrue(defaults.isSyllableColoringEnabled, "Syllable coloring should default on")
        assertFalse(defaults.isRhymeHighlightEnabled, "Rhyme highlight should default off")
        assertFalse(defaults.isBeatGridEnabled, "Beat grid should default off")
    }

    @Test
    fun copyPreservesUnchangedFields() {
        val original = EditorToggles()
        val modified = original.copy(useWholeSongContext = false)
        assertFalse(modified.useWholeSongContext)
        // All other fields preserved from defaults.
        assertFalse(modified.isStressIpaEnabled)
        assertTrue(modified.isHighlightEnabled)
        assertTrue(modified.isSyllableColoringEnabled)
        assertFalse(modified.isRhymeHighlightEnabled)
        assertFalse(modified.isBeatGridEnabled)
    }

    @Test
    fun allTogglesOnRoundTrip() {
        // Simulate saving all toggles enabled and reading them back.
        val saved = EditorToggles(
            useWholeSongContext = true,
            isStressIpaEnabled = true,
            isHighlightEnabled = true,
            isSyllableColoringEnabled = true,
            isRhymeHighlightEnabled = true,
            isBeatGridEnabled = true
        )
        // In a real DataStore path each field is stored and reloaded individually;
        // here we verify the data class correctly holds and exposes all values.
        assertTrue(saved.useWholeSongContext)
        assertTrue(saved.isStressIpaEnabled)
        assertTrue(saved.isHighlightEnabled)
        assertTrue(saved.isSyllableColoringEnabled)
        assertTrue(saved.isRhymeHighlightEnabled)
        assertTrue(saved.isBeatGridEnabled)
    }

    @Test
    fun allTogglesOffRoundTrip() {
        val saved = EditorToggles(
            useWholeSongContext = false,
            isStressIpaEnabled = false,
            isHighlightEnabled = false,
            isSyllableColoringEnabled = false,
            isRhymeHighlightEnabled = false,
            isBeatGridEnabled = false
        )
        assertFalse(saved.useWholeSongContext)
        assertFalse(saved.isStressIpaEnabled)
        assertFalse(saved.isHighlightEnabled)
        assertFalse(saved.isSyllableColoringEnabled)
        assertFalse(saved.isRhymeHighlightEnabled)
        assertFalse(saved.isBeatGridEnabled)
    }

    @Test
    fun equalityIsStructural() {
        val a = EditorToggles(useWholeSongContext = true)
        val b = EditorToggles(useWholeSongContext = true)
        assertEquals(a, b)
    }

    @Test
    fun inequalityDetectsChangedField() {
        val a = EditorToggles(isBeatGridEnabled = false)
        val b = EditorToggles(isBeatGridEnabled = true)
        assertTrue(a != b)
    }

    @Test
    fun wholeSongContextIsOnWhenUnsetAndRespectsSavedValue() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-editor-toggles").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) {
            File(directory, "toggles.preferences_pb")
        }
        val secureStore = object : SecureKeyStore {
            override fun getKey(provider: String) = ""
            override fun setKey(provider: String, key: String) = Unit
            override fun allKeys(): Map<String, String> = emptyMap()
            override fun clear() = Unit
        }
        try {
            val repository = ProjectRepository(dataStore, secureStore)
            assertTrue(repository.editorTogglesFlow.first().useWholeSongContext, "unset key reads as on")

            dataStore.edit { it[booleanPreferencesKey("editor_use_whole_song_context")] = false }
            assertFalse(repository.editorTogglesFlow.first().useWholeSongContext, "saved false is respected")

            repository.saveEditorToggles(EditorToggles(useWholeSongContext = true))
            assertTrue(repository.editorTogglesFlow.first().useWholeSongContext)
            repository.saveEditorToggles(EditorToggles(useWholeSongContext = false))
            assertFalse(repository.editorTogglesFlow.first().useWholeSongContext)
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }
}
