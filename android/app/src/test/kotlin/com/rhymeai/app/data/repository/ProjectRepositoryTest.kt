package com.rhymeai.app.data.repository

import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ProjectRepositoryTest {
    @Test
    fun corruptStoredJsonBlocksWritesUntilAValidValueIsObserved() {
        val stored = FailClosedStoredJson("song library") { raw ->
            if (raw == "invalid") error("malformed JSON") else raw
        }

        val corruption = assertFailsWith<CorruptLibraryException> {
            stored.decode("invalid")
        }
        assertEquals("song library", corruption.area)
        assertFailsWith<CorruptLibraryException> { stored.requireWritable("invalid") }

        assertEquals("valid", stored.decode("valid"))
        stored.requireWritable("valid")
    }

    @Test
    fun saveProjectsCannotOverwriteCorruptCurrentValueBeforeFirstRead() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-project-repository").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val file = File(directory, "repository.preferences_pb")
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) { file }
        val projectsKey = stringPreferencesKey("projects_json")
        val corruptJson = "{not valid json"
        val secureStore = object : SecureKeyStore {
            private val values = mutableMapOf<String, String>()
            override fun getKey(provider: String) = values[provider].orEmpty()
            override fun setKey(provider: String, key: String) { values[provider] = key }
            override fun allKeys(): Map<String, String> = values.toMap()
            override fun clear() = values.clear()
        }

        try {
            dataStore.edit { it[projectsKey] = corruptJson }
            val repository = ProjectRepository(dataStore, secureStore)

            assertFailsWith<CorruptLibraryException> {
                repository.saveProjects(emptyList())
            }
            assertEquals(corruptJson, dataStore.data.first()[projectsKey])
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }
}
