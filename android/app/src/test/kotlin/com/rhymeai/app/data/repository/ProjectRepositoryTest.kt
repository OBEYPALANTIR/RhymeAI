package com.rhymeai.app.data.repository

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.SongWorkspace
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

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
            assertFailsWith<CorruptLibraryException> {
                repository.saveActiveState(null, false, "", "", "")
            }
            assertEquals(corruptJson, dataStore.data.first()[projectsKey])
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun movingToTrashCannotCommitActiveRemovalWhenStoredTrashIsUnreadable() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-trash-red").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) {
            File(directory, "repository.preferences_pb")
        }
        val activeKey = stringPreferencesKey("projects_json")
        val trashKey = stringPreferencesKey("trashed_projects_json")
        val song = SongProject(id = "song-1", title = "Kept", lyrics = "original")
        val secureStore = object : SecureKeyStore {
            override fun getKey(provider: String) = ""
            override fun setKey(provider: String, key: String) = Unit
            override fun allKeys(): Map<String, String> = emptyMap()
            override fun clear() = Unit
        }

        try {
            val repository = ProjectRepository(dataStore, secureStore)
            repository.saveProjects(listOf(song))
            val originalActive = dataStore.data.first()[activeKey]
            val unreadableTrash = "{not valid json"
            dataStore.edit { it[trashKey] = unreadableTrash }

            assertFailsWith<CorruptLibraryException> {
                repository.moveProjectToTrash(song.id, 100L)
            }
            assertEquals(originalActive, dataStore.data.first()[activeKey])
            assertEquals(unreadableTrash, dataStore.data.first()[trashKey])
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun restoreCannotOverwriteUnreadableActiveLibrary() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-restore-corrupt").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }
        val activeKey = stringPreferencesKey("projects_json")
        val trashKey = stringPreferencesKey("trashed_projects_json")
        val song = SongProject(id = "restore-1", title = "Restore", lyrics = "lyric")
        try {
            val repository = ProjectRepository(dataStore, testKeyStore())
            repository.saveProjects(listOf(song))
            repository.moveProjectToTrash(song.id, 10L)
            val originalTrash = dataStore.data.first()[trashKey]
            dataStore.edit { it[activeKey] = "{broken active" }
            assertFailsWith<CorruptLibraryException> { repository.restoreTrashedProject(song.id, 20L) }
            assertEquals("{broken active", dataStore.data.first()[activeKey])
            assertEquals(originalTrash, dataStore.data.first()[trashKey])
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun deletionAndPurgeCannotRemoveTrashWhenNotebookIsUnreadable() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-delete-corrupt").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }
        val trashKey = stringPreferencesKey("trashed_projects_json")
        val notebookKey = stringPreferencesKey("local_song_workspaces_json")
        val song = SongProject(id = "delete-1", title = "Delete")
        try {
            val repository = ProjectRepository(dataStore, testKeyStore())
            repository.saveProjects(listOf(song))
            repository.moveProjectToTrash(song.id, 10L)
            val originalTrash = dataStore.data.first()[trashKey]
            dataStore.edit { it[notebookKey] = "{broken notebook" }
            assertFailsWith<CorruptLibraryException> { repository.permanentlyDeleteTrashedProject(song.id) }
            assertFailsWith<CorruptLibraryException> {
                repository.purgeExpiredTrashedProjects(10L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS + 1L)
            }
            assertEquals(originalTrash, dataStore.data.first()[trashKey])
            assertEquals("{broken notebook", dataStore.data.first()[notebookKey])
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun failedDataStoreCommitPreservesBothLibrariesAndEditorState() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-commit-failure").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }
        val activeKey = stringPreferencesKey("projects_json")
        val trashKey = stringPreferencesKey("trashed_projects_json")
        val idKey = stringPreferencesKey("current_project_id")
        val song = SongProject(id = "fail-1", title = "Keep", lyrics = "line")
        try {
            val repository = ProjectRepository(dataStore, testKeyStore())
            repository.saveActiveState(song, true, song.title, song.lyrics, song.theme)
            val before = dataStore.data.first().asMap()
            val failingStore = object : DataStore<Preferences> by dataStore {
                override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences =
                    dataStore.updateData { current ->
                        transform(current)
                        throw IOException("injected write failure before commit")
                    }
            }
            assertFailsWith<IOException> {
                ProjectRepository(failingStore, testKeyStore()).moveProjectToTrash(song.id, 100L)
            }
            val after = dataStore.data.first()
            assertEquals(before, after.asMap())
            assertEquals(song.id, after[idKey])
            assertEquals(before[activeKey], after[activeKey])
            assertEquals(before[trashKey], after[trashKey])
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun committedTransitionsAndNotebookDeletionSurviveRepositoryReopen() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-trash-reopen").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val song = SongProject(id = "reopen-1", title = "Persist", lyrics = "one")
        try {
            val firstStore = PreferenceDataStoreFactory.create(scope = firstScope) { file }
            val first = ProjectRepository(firstStore, testKeyStore())
            first.saveActiveState(song, true, song.title, song.lyrics, song.theme)
            first.saveWorkspace(song.id, SongWorkspace(checkpointAt = 123L))
            val moved = first.moveProjectToTrash(song.id, 10L)!!
            assertEquals(emptyList(), moved.projects)
            assertEquals(song.id, moved.trashedProjects.single().project.id)
            assertEquals(null, first.currentProjectIdFlow.first())
            val restored = first.restoreTrashedProject(song.id, 20L)!!
            assertEquals(song.id, restored.projects.single().id)
            assertEquals(emptyList(), restored.trashedProjects)
            first.moveProjectToTrash(song.id, 30L)
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopenedStore = PreferenceDataStoreFactory.create(scope = reopenedScope) { file }
                val reopened = ProjectRepository(reopenedStore, testKeyStore())
                assertEquals(emptyList(), reopened.projectsFlow.first())
                assertEquals(song.id, reopened.trashedProjectsFlow.first().single().project.id)
                assertEquals(123L, reopened.workspacesFlow.first()[song.id]?.checkpointAt)
                val afterDelete = reopened.permanentlyDeleteTrashedProject(song.id)
                assertEquals(emptyList(), afterDelete)
                assertNull(reopened.workspacesFlow.first()[song.id])
                assertEquals(emptyList(), reopened.trashedProjectsFlow.first())
                assertFailsWith<MissingActiveProjectException> {
                    reopened.saveWorkspace(song.id, SongWorkspace(checkpointAt = 999L))
                }
                assertNull(reopened.workspacesFlow.first()[song.id])
                val expired = SongProject(id = "expired-2", title = "Expired")
                val retained = SongProject(id = "active-3", title = "Retained")
                reopened.saveProjects(listOf(expired, retained))
                reopened.saveWorkspace(expired.id, SongWorkspace(checkpointAt = 456L))
                reopened.saveWorkspace(retained.id, SongWorkspace(checkpointAt = 789L))
                reopened.moveProjectToTrash(expired.id, 40L)
                val purged = reopened.purgeExpiredTrashedProjects(
                    40L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
                )
                assertEquals(listOf(expired.id), purged.purgedIds)
                assertEquals(emptyList(), reopened.trashedProjectsFlow.first())
                assertNull(reopened.workspacesFlow.first()[expired.id])
                assertFailsWith<MissingActiveProjectException> {
                    reopened.saveWorkspace(expired.id, SongWorkspace(checkpointAt = 999L))
                }
                assertNull(reopened.workspacesFlow.first()[expired.id])
                assertEquals(789L, reopened.workspacesFlow.first()[retained.id]?.checkpointAt)
                assertEquals(retained.id, reopened.projectsFlow.first().single().id)
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun staleSaveQueuedBehindTrashMoveCannotResurrectSongOrDiscardOtherSongs() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-move-race").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val store = PreferenceDataStoreFactory.create(scope = scope) { file }
            val first = SongProject(id = "moved", title = "Move", lyrics = "keep")
            val second = SongProject(id = "edit", title = "Other", lyrics = "old")
            val repository = ProjectRepository(store, testKeyStore())
            repository.saveProjects(listOf(first, second))
            val entered = CompletableDeferred<Unit>()
            val resume = CompletableDeferred<Unit>()
            val gated = gateFirstWrite(store, entered, resume)
            val concurrent = ProjectRepository(gated, testKeyStore())
            val moving = async(Dispatchers.Default) { concurrent.moveProjectToTrash(first.id, 100L) }
            entered.await()
            val staleSave = async(Dispatchers.Default) {
                concurrent.saveActiveState(second.copy(lyrics = "new"), false, second.title, "new", "")
            }
            resume.complete(Unit)
            moving.await()
            staleSave.await()
            assertEquals(listOf(second.id), repository.projectsFlow.first().map { it.id })
            assertEquals("new", repository.projectsFlow.first().single().lyrics)
            assertEquals(listOf(first.id), repository.trashedProjectsFlow.first().map { it.project.id })
            assertFailsWith<MissingActiveProjectException> {
                concurrent.saveActiveState(first, false, first.title, first.lyrics, first.theme)
            }
            assertFailsWith<MissingActiveProjectException> {
                concurrent.saveWorkspace(first.id, SongWorkspace(checkpointAt = 999L))
            }
            scope.coroutineContext[Job]!!.cancelAndJoin()
            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore())
                assertEquals(listOf(second.id), reopened.projectsFlow.first().map { it.id })
                assertEquals(listOf(first.id), reopened.trashedProjectsFlow.first().map { it.project.id })
                assertEquals(second.id, reopened.currentProjectIdFlow.first())
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun staleSaveQueuedBehindRestoreKeepsRestoredSongAndItsMetadata() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-restore-race").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val store = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }
            val restoredSong = SongProject(id = "restored", title = "Return", lyrics = "original", theme = "blue")
            val other = SongProject(id = "other", title = "Editing", lyrics = "old")
            val repository = ProjectRepository(store, testKeyStore())
            repository.saveProjects(listOf(restoredSong, other))
            repository.moveProjectToTrash(restoredSong.id, 10L)
            val entered = CompletableDeferred<Unit>()
            val resume = CompletableDeferred<Unit>()
            val concurrent = ProjectRepository(gateFirstWrite(store, entered, resume), testKeyStore())
            val restoring = async(Dispatchers.Default) { concurrent.restoreTrashedProject(restoredSong.id, 20L) }
            entered.await()
            val staleSave = async(Dispatchers.Default) {
                concurrent.saveActiveState(other.copy(lyrics = "new"), false, other.title, "new", "")
            }
            resume.complete(Unit)
            restoring.await()
            staleSave.await()
            val active = repository.projectsFlow.first()
            assertEquals(setOf(restoredSong.id, other.id), active.map { it.id }.toSet())
            assertEquals("original", active.single { it.id == restoredSong.id }.lyrics)
            assertEquals("blue", active.single { it.id == restoredSong.id }.theme)
            assertEquals("new", active.single { it.id == other.id }.lyrics)
            assertEquals(emptyList(), repository.trashedProjectsFlow.first())
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun failedRestoreDeleteAndPurgeLeaveCommittedBytesUnchanged() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-transition-writes").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val store = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }
            val repository = ProjectRepository(store, testKeyStore())
            val song = SongProject(id = "retained", title = "Retained")
            repository.saveProjects(listOf(song))
            repository.saveWorkspace(song.id, SongWorkspace(checkpointAt = 91L))
            repository.moveProjectToTrash(song.id, 10L)
            val before = store.data.first().asMap()
            val failedStore = object : DataStore<Preferences> by store {
                override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences =
                    store.updateData { current ->
                        transform(current)
                        throw IOException("injected write failure before commit")
                    }
            }
            val failing = ProjectRepository(failedStore, testKeyStore())
            assertFailsWith<IOException> { failing.restoreTrashedProject(song.id, 20L) }
            assertEquals(before, store.data.first().asMap())
            assertFailsWith<IOException> { failing.permanentlyDeleteTrashedProject(song.id) }
            assertEquals(before, store.data.first().asMap())
            assertFailsWith<IOException> {
                failing.purgeExpiredTrashedProjects(10L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS)
            }
            assertEquals(before, store.data.first().asMap())
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    private fun gateFirstWrite(
        store: DataStore<Preferences>,
        entered: CompletableDeferred<Unit>,
        resume: CompletableDeferred<Unit>
    ): DataStore<Preferences> {
        val first = AtomicBoolean(true)
        return object : DataStore<Preferences> by store {
            override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences =
                if (first.compareAndSet(true, false)) {
                    store.updateData { current ->
                        entered.complete(Unit)
                        resume.await()
                        transform(current)
                    }
                } else store.updateData(transform)
        }
    }

    private fun testKeyStore(): SecureKeyStore = object : SecureKeyStore {
        override fun getKey(provider: String) = ""
        override fun setKey(provider: String, key: String) = Unit
        override fun allKeys(): Map<String, String> = emptyMap()
        override fun clear() = Unit
    }
}
