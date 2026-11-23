package com.rhymeai.app.data.repository

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.SongWorkspace
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.sync.snapshotLocalRecordingFiles
import com.rhymeai.app.data.sync.recordingsAllowedForUpload
import com.rhymeai.app.data.sync.SyncBlob
import com.rhymeai.app.data.sync.RecordingManifestEntry
import com.rhymeai.app.data.sync.RecordingSyncPlanner
import com.rhymeai.app.data.sync.SyncDeletion
import com.rhymeai.app.data.sync.SyncMerger
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
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

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
                repository.saveActiveState(null, null, "", "", "")
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
            // Delete forever reads the song library too, so it refuses rather than deleting blind.
            assertFailsWith<CorruptLibraryException> { repository.permanentlyDeleteTrashedProject(song.id) }
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
            // Still in Trash (its times may have been repaired, A32), never removed.
            assertTrue(originalTrash!!.contains("delete-1") && dataStore.data.first()[trashKey]!!.contains("delete-1"))
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
            repository.saveActiveState(song, SongCreation(), song.title, song.lyrics, song.theme)
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
            first.saveActiveState(song, SongCreation(), song.title, song.lyrics, song.theme)
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
                assertEquals(emptyList(), afterDelete?.trashedProjects)
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
    fun partialRecordingDeletionRemainsPendingAcrossReopenAndOnlyRetriesDeletedSong() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-pending-memos").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val filesDir = File(directory, "files")
        val deletedId = "deleted-song"
        val retainedId = "active-song"
        val live = RecordingFiles.memoDirectory(filesDir, deletedId).apply { mkdirs() }
        val trash = RecordingFiles.trashDirectory(filesDir, deletedId).apply { mkdirs() }
        val retained = RecordingFiles.memoDirectory(filesDir, retainedId).apply { mkdirs() }
        File(live, "live.m4a").writeText("live recording")
        File(trash, "old.m4a").writeText("trashed recording")
        File(retained, "keep.m4a").writeText("recoverable recording")
        val untracked = RecordingFiles.memoDirectory(filesDir, "untracked").apply { mkdirs() }
        File(untracked, "unsaved.m4a").writeText("unsaved draft recording")
        val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = firstScope) { file }, testKeyStore()
            )
            repository.saveProjects(listOf(SongProject(id = deletedId, title = "Delete"),
                SongProject(id = retainedId, title = "Keep")))
            repository.moveProjectToTrash(deletedId, 10L)
            repository.permanentlyDeleteTrashedProject(deletedId)
            assertEquals(setOf(deletedId), repository.pendingRecordingDeletionIds())
            assertEquals(false, repository.retryPendingRecordingDeletions { id ->
                assertEquals(deletedId, id)
                trash.deleteRecursively()
                false // Deletion failed with the live directory still present.
            })
            assertEquals(setOf(deletedId), repository.pendingRecordingDeletionIds())
            assertTrue(File(live, "live.m4a").exists())
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore()
                )
                assertEquals(setOf(deletedId), reopened.pendingRecordingDeletionIds())
                val upload = snapshotLocalRecordingFiles(filesDir, reopened.pendingRecordingDeletionIds())
                assertEquals(listOf(retainedId, "untracked"), upload.map { it.entry.projectId })
                assertTrue(reopened.retryPendingRecordingDeletions { id ->
                    RecordingFiles.memoDirectory(filesDir, id).deleteRecursively() &&
                        RecordingFiles.trashDirectory(filesDir, id).deleteRecursively()
                })
                assertEquals(emptySet(), reopened.pendingRecordingDeletionIds())
                assertEquals(false, live.exists())
                assertEquals(emptyList(), reopened.trashedProjectsFlow.first())
                assertEquals(listOf(retainedId), reopened.projectsFlow.first().map { it.id })
                assertEquals(listOf("recoverable recording"), retained.listFiles()!!.map { it.readText() })
                assertEquals(listOf("unsaved draft recording"), untracked.listFiles()!!.map { it.readText() })
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun reactivatedSongCancelsPendingDeletionAndKeepsItsRecordingInDriveCollection() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-reactivated-memos").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val filesDir = File(directory, "files")
        val song = SongProject(id = "reactivated", title = "Recovered")
        val recording = File(RecordingFiles.memoDirectory(filesDir, song.id).apply { mkdirs() }, "take.m4a")
        recording.writeText("restore me")
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") },
                testKeyStore()
            )
            repository.saveProjects(listOf(song))
            repository.moveProjectToTrash(song.id, 10L)
            repository.permanentlyDeleteTrashedProject(song.id)
            assertEquals(emptyList(), snapshotLocalRecordingFiles(filesDir, repository.pendingRecordingDeletionIds()))

            repository.saveProjects(listOf(song))
            assertEquals(emptySet(), repository.pendingRecordingDeletionIds())
            assertEquals(listOf(song.id), snapshotLocalRecordingFiles(
                filesDir, repository.pendingRecordingDeletionIds()
            ).map { it.entry.projectId })
            assertTrue(repository.retryPendingRecordingDeletions { id ->
                RecordingFiles.memoDirectory(filesDir, id).deleteRecursively()
            })
            // The snapshot gave it its id name (A36); the bytes are kept.
            assertEquals(listOf("restore me"), RecordingFiles.memoDirectory(filesDir, song.id).listFiles()!!.map { it.readText() })
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun backedUpPendingDeletionCompletesAfterFilesAndDataStoreRestore() = runBlocking {
        val source = kotlin.io.path.createTempDirectory("rhymeai-backup-source").toFile()
        val restored = kotlin.io.path.createTempDirectory("rhymeai-backup-restored").toFile()
        val filesDir = File(source, "files")
        val preferences = File(filesDir, "datastore/rhymeai_prefs.preferences_pb")
        preferences.parentFile!!.mkdirs()
        val song = SongProject(id = "backup-pending", title = "Removed")
        val audio = File(RecordingFiles.memoDirectory(filesDir, song.id).apply { mkdirs() }, "take.m4a")
        audio.writeText("pending private recording")
        val sourceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = sourceScope) { preferences }, testKeyStore()
            )
            repository.saveProjects(listOf(song))
            repository.moveProjectToTrash(song.id, 10L)
            repository.permanentlyDeleteTrashedProject(song.id)
            assertEquals(false, repository.retryPendingRecordingDeletions { false })
            assertEquals(setOf(song.id), repository.pendingRecordingDeletionIds())
            sourceScope.coroutineContext[Job]!!.cancelAndJoin()

            // Simulate an Auto Backup restore of app files, including DataStore and memo bytes.
            filesDir.copyRecursively(restored, overwrite = true)
            val restoredAudio = File(RecordingFiles.memoDirectory(restored, song.id), "take.m4a")
            assertEquals("pending private recording", restoredAudio.readText())
            val restoredScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val restoredRepo = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = restoredScope) {
                        File(restored, "datastore/rhymeai_prefs.preferences_pb")
                    },
                    testKeyStore()
                )
                assertEquals(setOf(song.id), restoredRepo.pendingRecordingDeletionIds())
                assertTrue(restoredRepo.retryPendingRecordingDeletions { id ->
                    val live = RecordingFiles.memoDirectory(restored, id)
                    val trash = RecordingFiles.trashDirectory(restored, id)
                    (!live.exists() || live.deleteRecursively()) &&
                        (!trash.exists() || trash.deleteRecursively())
                })
                assertEquals(emptySet(), restoredRepo.pendingRecordingDeletionIds())
                assertEquals(false, restoredAudio.exists())
                assertEquals("pending private recording", audio.readText())
            } finally {
                restoredScope.cancel()
            }
        } finally {
            sourceScope.cancel()
            source.deleteRecursively()
            restored.deleteRecursively()
        }
    }

    @Test
    fun expiryPurgeRetriesEarlierFailuresAndRemovesRecordingResidue() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-expiry-memos").toFile()
        val filesDir = File(directory, "files")
        val leftover = RecordingFiles.memoDirectory(filesDir, "expired").apply { mkdirs() }
        File(leftover, "take.m4a").writeText("expired audio")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") },
                testKeyStore()
            )
            val expired = SongProject(id = "expired", title = "Expired")
            repository.saveProjects(listOf(expired))
            repository.moveProjectToTrash(expired.id, 10L)
            val now = 10L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
            repository.purgeExpiredTrashedProjects(now)
            assertEquals(setOf(expired.id), repository.pendingRecordingDeletionIds())
            assertEquals(false, repository.retryPendingRecordingDeletions {
                throw IOException("injected recording deletion failure")
            })
            assertEquals(setOf(expired.id), repository.pendingRecordingDeletionIds())
            assertTrue(File(leftover, "take.m4a").exists())
            assertEquals(emptyList(), repository.purgeExpiredTrashedProjects(now).purgedIds)
            assertTrue(repository.retryPendingRecordingDeletions { id ->
                RecordingFiles.memoDirectory(filesDir, id).deleteRecursively()
            })
            assertEquals(emptySet(), repository.pendingRecordingDeletionIds())
            assertEquals(false, leftover.exists())
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun manualDeletionOnlyRetriesItsOwnDirectoryWhenAnotherDeletionIsPending() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-manual-pending").toFile()
        val filesDir = File(directory, "files")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") },
                testKeyStore()
            )
            val earlier = SongProject(id = "earlier", title = "Earlier")
            val current = SongProject(id = "current", title = "Current")
            repository.saveProjects(listOf(earlier, current))
            for (song in listOf(earlier, current)) {
                repository.moveProjectToTrash(song.id, 10L)
                repository.permanentlyDeleteTrashedProject(song.id)
                File(RecordingFiles.memoDirectory(filesDir, song.id).apply { mkdirs() }, "take.m4a")
                    .writeText(song.title)
            }
            assertTrue(repository.retryPendingRecordingDeletions(onlyId = current.id) { id ->
                RecordingFiles.memoDirectory(filesDir, id).deleteRecursively()
            })
            assertEquals(setOf(earlier.id), repository.pendingRecordingDeletionIds())
            assertEquals(false, RecordingFiles.memoDirectory(filesDir, current.id).exists())
            assertEquals("Earlier", File(RecordingFiles.memoDirectory(filesDir, earlier.id), "take.m4a").readText())
        } finally {
            scope.cancel()
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
                concurrent.saveActiveState(second.copy(lyrics = "new"), null, second.title, "new", "")
            }
            resume.complete(Unit)
            moving.await()
            staleSave.await()
            assertEquals(listOf(second.id), repository.projectsFlow.first().map { it.id })
            assertEquals("new", repository.projectsFlow.first().single().lyrics)
            assertEquals(listOf(first.id), repository.trashedProjectsFlow.first().map { it.project.id })
            assertFailsWith<MissingActiveProjectException> {
                concurrent.saveActiveState(first, null, first.title, first.lyrics, first.theme)
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
                concurrent.saveActiveState(other.copy(lyrics = "new"), null, other.title, "new", "")
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

    @Test
    fun staleSyncCannotRestoreDeletedTrashOrClearMarkerAfterPartialMemoRemoval() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-sync-partial-delete").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val filesDir = File(directory, "files")
        val id = "partial-delete"
        val memos = RecordingFiles.memoDirectory(filesDir, id).apply { mkdirs() }
        val removed = File(memos, "first.m4a").apply { writeText("remove this") }
        val residue = File(memos, "second.m4a").apply { writeText("retain these bytes") }
        val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = firstScope) { file }, testKeyStore()
            )
            repository.saveProjects(listOf(SongProject(id = id, title = "Delete", updatedAt = 1L)))
            repository.moveProjectToTrash(id, 10L)
            val base = repository.snapshotLocalSyncBase()
            repository.permanentlyDeleteTrashedProject(id)
            assertEquals(false, repository.retryPendingRecordingDeletions(onlyId = id) {
                assertTrue(removed.delete())
                memos.delete() // Fails on the remaining file, after the first file was removed.
            })
            // A real filesystem deletion failed: the second file is still present.
            assertEquals("retain these bytes", residue.readText())
            repository.applySyncResult(base.blob, base)
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore()
                )
                assertEquals(emptyList(), reopened.trashedProjectsFlow.first())
                assertEquals(setOf(id), reopened.pendingRecordingDeletionIds())
                assertEquals("retain these bytes", residue.readText())
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun staleSyncCannotRestoreDeletedTrashAfterSuccessfulMemoRemoval() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-sync-complete-delete").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val filesDir = File(directory, "files")
        val id = "complete-delete"
        val memos = RecordingFiles.memoDirectory(filesDir, id).apply { mkdirs() }
        File(memos, "take.m4a").writeText("recording")
        val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = firstScope) { file }, testKeyStore()
            )
            repository.saveProjects(listOf(SongProject(id = id, title = "Delete", updatedAt = 1L)))
            repository.moveProjectToTrash(id, 10L)
            val base = repository.snapshotLocalSyncBase()
            repository.permanentlyDeleteTrashedProject(id)
            assertTrue(repository.retryPendingRecordingDeletions(onlyId = id) {
                RecordingFiles.memoDirectory(filesDir, it).deleteRecursively() &&
                    RecordingFiles.trashDirectory(filesDir, it).deleteRecursively()
            })
            assertEquals(false, memos.exists())
            repository.applySyncResult(base.blob, base)
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore()
                )
                assertEquals(emptyList(), reopened.trashedProjectsFlow.first())
                assertEquals(emptySet(), reopened.pendingRecordingDeletionIds())
                assertEquals(false, memos.exists())
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun staleSyncCannotRestoreEitherSongAfterExpiryPurge() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-sync-purge").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val songs = listOf(SongProject(id = "expired-a", updatedAt = 1L), SongProject(id = "expired-b", updatedAt = 1L))
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = firstScope) { file }, testKeyStore()
            )
            repository.saveProjects(songs)
            songs.forEach { repository.moveProjectToTrash(it.id, 10L) }
            val base = repository.snapshotLocalSyncBase()
            val purged = repository.purgeExpiredTrashedProjects(
                10L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
            )
            assertEquals(songs.map { it.id }.toSet(), purged.purgedIds.toSet())
            repository.applySyncResult(base.blob, base)
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore()
                )
                assertEquals(emptyList(), reopened.trashedProjectsFlow.first())
                assertEquals(songs.map { it.id }.toSet(), reopened.pendingRecordingDeletionIds())
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun syncApplyRetainsRemoteAdditionInItsMergedPlacement() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-sync-remote-add").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") },
                testKeyStore()
            )
            val base = repository.snapshotLocalSyncBase()
            val remote = SongProject(id = "remote-add", title = "From Drive", updatedAt = 50L)
            val remoteTrash = com.rhymeai.app.data.model.TrashedSongProject(remote, 100L)
            val committed = repository.applySyncResult(SyncBlob(trashed = listOf(remoteTrash)), base)
            assertEquals(listOf(remoteTrash), committed.trashed)
            assertEquals(emptyList(), repository.projectsFlow.first())
            assertEquals(listOf(remoteTrash), repository.trashedProjectsFlow.first())
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun syncApplyKeepsSongCreatedAfterSnapshotAcrossRepositoryReopen() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-sync-local-add").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = firstScope) { file }, testKeyStore()
            )
            val original = SongProject(id = "base-song", title = "Already saved")
            repository.saveProjects(listOf(original))
            val base = repository.snapshotLocalSyncBase()
            val created = SongProject(id = "new-song", title = "During sync", lyrics = "new words")
            repository.saveActiveState(created, SongCreation(), created.title, created.lyrics, created.theme)
            val committed = repository.applySyncResult(base.blob, base)
            assertEquals(setOf(original.id, created.id), committed.projects.map { it.id }.toSet())
            assertEquals(created.lyrics, repository.projectsFlow.first().single { it.id == created.id }.lyrics)
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore()
                )
                assertEquals(setOf(original.id, created.id), reopened.projectsFlow.first().map { it.id }.toSet())
                assertEquals(created.lyrics, reopened.projectsFlow.first().single { it.id == created.id }.lyrics)
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun permanentDeleteWritesTombstoneBeforeSyncAndSurvivesRepositoryReopen() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-sync-forever-v2").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val song = SongProject(id = "forever-v2", title = "Delete", updatedAt = 100L)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = firstScope) { file }, testKeyStore()
            )
            repository.saveProjects(listOf(song))
            repository.moveProjectToTrash(song.id, 10L)
            repository.permanentlyDeleteTrashedProject(song.id)
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore()
                )
                val base = reopened.snapshotLocalSyncBase()
                assertEquals(listOf(song.id), base.blob.deletions.map { it.projectId })
                assertEquals(null, base.blob.deletions.single().fileName)
                // Copies older than the tombstone are removed everywhere.
                val stale = SyncBlob(
                    projects = listOf(song),
                    trashed = listOf(TrashedSongProject(song, 20L)),
                    recordings = listOf(syncedRecording(song.id))
                )
                val merged = SyncMerger.merge(base.blob, stale)
                assertEquals(emptyList(), merged.projects)
                assertEquals(emptyList(), merged.trashed)
                assertEquals(emptyList(), merged.recordings)
                // The removed recording gets its own tombstone at the song's deletion time.
                val songTombstone = base.blob.deletions.single()
                assertEquals(
                    listOf(songTombstone, SyncDeletion(song.id, "take.m4a", songTombstone.deletedAt, recordingId = syncedRecording(song.id).id)),
                    merged.deletions
                )
                // A copy edited after the tombstone survives and drops the song tombstone,
                // but the recording tombstone keeps the old take deleted.
                val edited = SyncMerger.merge(merged, SyncBlob(projects = listOf(song.copy(updatedAt = Long.MAX_VALUE)), recordings = listOf(syncedRecording(song.id))))
                assertEquals(listOf(song.id), edited.projects.map { it.id })
                assertEquals(emptyList(), edited.recordings)
                assertEquals(listOf(SyncDeletion(song.id, "take.m4a", songTombstone.deletedAt, recordingId = syncedRecording(song.id).id)), edited.deletions)
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun expiryPurgeWritesTombstonesForBothSongsBeforeRemoteMerge() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-sync-expiry-v2").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val expired = listOf(SongProject(id = "expired-v2-a", updatedAt = 100L),
            SongProject(id = "expired-v2-b", updatedAt = 100L))
        val retained = SongProject(id = "retained-v2", updatedAt = 100L)
        val now = 10L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = firstScope) { file }, testKeyStore()
            )
            repository.saveProjects(expired + retained)
            expired.forEach { repository.moveProjectToTrash(it.id, 10L) }
            assertEquals(expired.map { it.id }.toSet(),
                repository.purgeExpiredTrashedProjects(now).purgedIds.toSet())
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore()
                )
                val base = reopened.snapshotLocalSyncBase()
                assertEquals(expired.map { it.id }.toSet(), base.blob.deletions.map { it.projectId }.toSet())
                assertEquals(setOf(now), base.blob.deletions.map { it.deletedAt }.toSet())
                val stale = SyncBlob(
                    projects = expired,
                    trashed = expired.map { TrashedSongProject(it, 20L) },
                    recordings = expired.map { syncedRecording(it.id) }
                )
                val merged = SyncMerger.merge(base.blob, stale)
                assertEquals(listOf(retained.id), merged.projects.map { it.id })
                assertEquals(emptyList(), merged.trashed)
                assertEquals(emptyList(), merged.recordings)
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun deletionCommittedAfterBaseReadSurvivesSyncApplyAndLaterUpload() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-sync-delete-window-v2").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val song = SongProject(id = "during-sync-v2", title = "Delete during sync", updatedAt = 100L)
        val remoteTombstone = SyncDeletion("another-device", deletedAt = 200L)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = firstScope) { file }, testKeyStore()
            )
            repository.saveProjects(listOf(song))
            repository.moveProjectToTrash(song.id, 10L)
            val base = repository.snapshotLocalSyncBase()
            repository.permanentlyDeleteTrashedProject(song.id)
            // This result was computed before the local deletion and still contains the song.
            val staleResult = SyncBlob(
                trashed = listOf(TrashedSongProject(song, 10L)),
                deletions = listOf(remoteTombstone)
            )
            repository.applySyncResult(staleResult, base)
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore()
                )
                assertEquals(emptyList(), reopened.projectsFlow.first())
                assertEquals(emptyList(), reopened.trashedProjectsFlow.first())
                assertEquals(setOf(song.id), reopened.pendingRecordingDeletionIds())
                val laterUpload = reopened.snapshotLocalSyncBase().blob
                assertEquals(setOf(song.id, remoteTombstone.projectId),
                    laterUpload.deletions.map { it.projectId }.toSet())
                val stalePeer = SyncBlob(version = 1, projects = listOf(song))
                assertEquals(emptyList(), SyncMerger.merge(laterUpload, stalePeer).projects)
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun permanentRecordingDeleteWritesFileTombstoneThatBlocksRestoreAndUpload() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-recording-tombstone").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val recording = syncedRecording("song-1")
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { file }, testKeyStore()
            )
            // Invalid names fail before anything is written, so the file stays in Trash.
            assertFailsWith<IllegalArgumentException> {
                repository.recordRecordingDeletion("song-1", "bad\u0000name.m4a", recording.id, 50L)
            }
            repository.recordRecordingDeletion("song-1", recording.fileName, recording.id, 5_000L)

            val base = repository.snapshotLocalSyncBase()
            assertEquals(listOf(SyncDeletion("song-1", recording.fileName, 5_000L, recordingId = recording.id)), base.blob.deletions)

            // The remote manifest still lists the recording; the merge drops it and no
            // restore is planned, so the deleted take never comes back from Drive.
            val merged = SyncMerger.merge(base.blob, SyncBlob(recordings = listOf(recording)))
            assertEquals(emptyList(), merged.recordings)
            assertEquals(emptyList(), RecordingSyncPlanner.planRestores(
                local = emptyList(),
                remoteManifest = merged.recordings,
                remoteFilesByName = mapOf(recording.driveName to "drive-id")
            ))
            // A lingering local copy is never uploaded either.
            assertEquals(emptyList(), recordingsAllowedForUpload(listOf(recording), base.blob.deletions, emptyList()))
            // Another recording of the same song is untouched.
            val other = recording.copy(
                fileName = "other.m4a",
                driveName = RecordingManifestEntry.driveNameFor("song-1", "other.m4a"),
                id = RecordingManifestEntry.newRecordingId()
            )
            assertEquals(listOf(other), SyncMerger.merge(base.blob, SyncBlob(recordings = listOf(other))).recordings)
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun olderRemoteTombstoneKeepsASongEditedAfterTheSnapshot() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-sync-remote-delete-v2").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val firstScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val song = SongProject(id = "remote-deleted-v2", title = "Late local edit", updatedAt = Long.MAX_VALUE)
        val recording = syncedRecording(song.id)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = firstScope) { file }, testKeyStore()
            )
            val base = repository.snapshotLocalSyncBase()
            repository.saveActiveState(song, SongCreation(), song.title, song.lyrics, song.theme)
            assertEquals(listOf(song.id), repository.projectsFlow.first().map { it.id })
            val merged = SyncMerger.merge(
                base.blob,
                SyncBlob(
                    recordings = listOf(recording),
                    deletions = listOf(SyncDeletion(song.id, deletedAt = 1L))
                )
            )
            // The recording was uploaded after the tombstone, so it stays listed.
            assertEquals(listOf(recording), merged.recordings)
            repository.applySyncResult(merged, base)
            assertEquals(listOf(song.id), repository.projectsFlow.first().map { it.id })
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore()
                )
                assertEquals(listOf(song.id), reopened.projectsFlow.first().map { it.id })
                assertEquals(emptyList(), reopened.snapshotLocalSyncBase().blob.deletions)
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun songDeletionTombstonesItsKnownRecordingsInTheSameWrite() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-song-recording-tombstones").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }, testKeyStore()
            )
            val takes = listOf("forever", "expired").associateWith { RecordingManifestEntry.newRecordingId() }
            repository.updateRecordingRecords {
                takes.map { (song, id) ->
                    com.rhymeai.app.data.sync.RecordingRecord(id, song, "$song-take.m4a", 1L, "a".repeat(64), 1L, "recorded", path = "voice-memos/$song/$song-take.m4a")
                }
            }
            repository.saveProjects(listOf(SongProject(id = "forever", updatedAt = 1L), SongProject(id = "expired", updatedAt = 1L)))
            repository.moveProjectToTrash("forever", 10L)
            repository.moveProjectToTrash("expired", 10L)
            val expiredTrashRow = repository.trashedProjectsFlow.first().single { it.project.id == "expired" }

            assertEquals(
                ProjectRepository.TrashPurge(listOf(expiredTrashRow), listOf("forever")),
                repository.permanentlyDeleteTrashedProject("forever", now = 5_000L)
            )
            assertTrue("forever" in repository.pendingRecordingDeletionIds())
            repository.purgeExpiredTrashedProjects(10L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS)

            val deletions = repository.snapshotLocalSyncBase().blob.deletions
            val purgedAt = 10L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
            assertEquals(
                setOf(
                    SyncDeletion("expired", deletedAt = purgedAt),
                    SyncDeletion("expired", "expired-take.m4a", purgedAt, recordingId = takes.getValue("expired")),
                    SyncDeletion("forever", deletedAt = 5_000L),
                    SyncDeletion("forever", "forever-take.m4a", 5_000L, recordingId = takes.getValue("forever"))
                ),
                deletions.toSet()
            )
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    private fun withSameIdStore(test: suspend (DataStore<Preferences>, ProjectRepository) -> Unit) = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-same-id-delete").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }
            test(dataStore, ProjectRepository(dataStore, testKeyStore()))
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun deleteForeverOfATrashCopyOfAnActiveSongRemovesOnlyThatRow() = withSameIdStore { dataStore, repository ->
        val notebookKey = stringPreferencesKey("local_song_workspaces_json")
        val deletionsKey = stringPreferencesKey("sync_deletions_json")
        val pendingKey = androidx.datastore.preferences.core.stringSetPreferencesKey("pending_recording_deletions")
        repository.saveProjects(listOf(SongProject(id = "same", title = "Active", updatedAt = 1L)))
        repository.saveWorkspace("same", SongWorkspace(checkpointAt = 123L))
        val take = RecordingManifestEntry.newRecordingId()
        repository.updateRecordingRecords {
            listOf(com.rhymeai.app.data.sync.RecordingRecord(take, "same", "same-take.m4a", 1L, "a".repeat(64), 1L, "recorded", path = "voice-memos/same/same-take.m4a"))
        }
        repository.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "same", title = "Trashed"), deletedAt = 10L)))
        val before = dataStore.data.first()
        val activeBefore = repository.projectsFlow.first()

        val result = repository.permanentlyDeleteTrashedProject("same", now = 5_000L)

        assertEquals(ProjectRepository.TrashPurge(emptyList(), emptyList()), result)
        assertEquals(emptyList(), repository.trashedProjectsFlow.first(), "Trash read back from the store")
        assertEquals(activeBefore, repository.projectsFlow.first(), "active list read back from the store")
        val after = dataStore.data.first()
        assertEquals(before[notebookKey], after[notebookKey])
        assertEquals(before[pendingKey], after[pendingKey])
        assertEquals(before[deletionsKey], after[deletionsKey])
        // A known edit time cannot lose to a Trash copy by being unknown: nothing is set aside.
        assertEquals(emptyList(), repository.recoveredSongs())
    }

    private fun assertUnknownTimeActiveSongIsKeptAside(active: SongProject) = withSameIdStore { dataStore, repository ->
        val keys = listOf("projects_json", "local_song_workspaces_json", "recording_records_json", "sync_deletions_json").map(::stringPreferencesKey)
        repository.saveProjects(listOf(active))
        repository.saveWorkspace("same", SongWorkspace(checkpointAt = 123L))
        val take = RecordingManifestEntry.newRecordingId()
        repository.updateRecordingRecords {
            listOf(com.rhymeai.app.data.sync.RecordingRecord(take, "same", "same-take.m4a", 1L, "a".repeat(64), 1L, "recorded", path = "voice-memos/same/same-take.m4a"))
        }
        repository.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "same", title = "Trashed", lyrics = "LT", updatedAt = 400L), deletedAt = 500L)))
        val stored = repository.projectsFlow.first().single()
        val before = dataStore.data.first()

        assertEquals(ProjectRepository.TrashPurge(emptyList(), emptyList()), repository.permanentlyDeleteTrashedProject("same", now = 5_000L))

        val kept = RecoveredSong(stored, wasInTrash = false, deletedAt = 5_000L, keptAt = 5_000L, recordingIds = listOf(take), trashedAt = null, trashedAtRepaired = false)
        assertEquals(listOf(kept), repository.recoveredSongs())
        assertEquals(emptyList(), repository.trashedProjectsFlow.first())
        val after = dataStore.data.first()
        keys.forEach { assertEquals(before[it], after[it], it.name) }

        // Another same-id Trash copy deleted later keeps no second copy of the same words.
        repository.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "same", title = "Trashed again", updatedAt = 600L), deletedAt = 700L)))
        repository.permanentlyDeleteTrashedProject("same", now = 6_000L)
        assertEquals(listOf(kept), repository.recoveredSongs())
    }

    @Test
    fun deleteForeverOfATrashCopyKeepsARepairedTimeActiveSongAside() =
        assertUnknownTimeActiveSongIsKeptAside(SongProject(id = "same", title = "Active", lyrics = "LA", updatedAt = 300L, precedenceRepaired = true))

    @Test
    fun deleteForeverOfATrashCopyKeepsAZeroTimeActiveSongAside() =
        assertUnknownTimeActiveSongIsKeptAside(SongProject(id = "same", title = "Active", lyrics = "LA", updatedAt = 0L))

    @Test
    fun deleteForeverKeepsEachDistinctUnknownTimeActiveRowOnce() = withSameIdStore { _, repository ->
        val known = SongProject(id = "same", title = "Known", lyrics = "K", updatedAt = 50L)
        val repaired = SongProject(id = "same", title = "Repaired", lyrics = "U1", updatedAt = 300L, precedenceRepaired = true)
        val zero = SongProject(id = "same", title = "Zero", lyrics = "U2", updatedAt = 0L)
        repository.saveProjects(listOf(known, repaired, zero, repaired))
        repository.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "same", title = "Trashed", updatedAt = 400L), deletedAt = 500L)))

        repository.permanentlyDeleteTrashedProject("same", now = 5_000L)

        assertEquals(listOf(repaired, zero), repository.recoveredSongs().map { it.project })
    }

    @Test
    fun deleteForeverRefusesWhenTheRecoveryStoreIsUnreadable() = withSameIdStore { dataStore, repository ->
        repository.saveProjects(listOf(SongProject(id = "same", title = "Active", lyrics = "LA", updatedAt = 300L, precedenceRepaired = true)))
        repository.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "same", title = "Trashed", updatedAt = 400L), deletedAt = 500L)))
        dataStore.edit { it[stringPreferencesKey("recovered_songs_json")] = "{broken recovery" }
        val before = dataStore.data.first().asMap()

        assertFailsWith<CorruptLibraryException> { repository.permanentlyDeleteTrashedProject("same", now = 5_000L) }

        assertEquals(before, dataStore.data.first().asMap())
    }

    @Test
    fun deleteForeverRefusesTwoTrashCopiesSharingAnId() = withSameIdStore { dataStore, repository ->
        repository.saveProjects(listOf(SongProject(id = "same", title = "Active", updatedAt = 1L)))
        repository.saveWorkspace("same", SongWorkspace(checkpointAt = 123L))
        repository.saveTrashedProjects(
            listOf(
                TrashedSongProject(SongProject(id = "same", lyrics = "one"), deletedAt = 10L),
                TrashedSongProject(SongProject(id = "same", lyrics = "two"), deletedAt = 20L)
            )
        )
        val before = dataStore.data.first().asMap()

        assertFailsWith<SameIdTrashCopiesException> { repository.permanentlyDeleteTrashedProject("same", now = 5_000L) }

        assertEquals(before, dataStore.data.first().asMap())
    }

    @Test
    fun moveToTrashRefusesTwoActiveSongsSharingAnId() = withSameIdStore { dataStore, repository ->
        repository.saveProjects(listOf(SongProject(id = "same", lyrics = "A", updatedAt = 1L), SongProject(id = "same", lyrics = "B", updatedAt = 2L)))
        repository.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "other", lyrics = "T"), deletedAt = 10L)))
        repository.setCurrentProjectId("same")
        val before = dataStore.data.first().asMap()

        assertFailsWith<SameIdActiveCopiesException> { repository.moveProjectToTrash("same", now = 5_000L) }

        assertEquals(before, dataStore.data.first().asMap())
        assertEquals(listOf("A", "B"), repository.projectsFlow.first().map { it.lyrics })
    }

    @Test
    fun deleteForeverWithTheIdOnlyActiveWritesNothing() = withSameIdStore { dataStore, repository ->
        repository.saveProjects(listOf(SongProject(id = "same", title = "Active", updatedAt = 1L)))
        repository.saveWorkspace("same", SongWorkspace(checkpointAt = 123L))
        val before = dataStore.data.first().asMap()
        assertNull(repository.permanentlyDeleteTrashedProject("same", now = 5_000L))
        assertEquals(before, dataStore.data.first().asMap())

        // No Trash row: nothing is decoded past the Trash, so a broken song library is no refusal.
        dataStore.edit { it[stringPreferencesKey("projects_json")] = "{broken active" }
        val broken = dataStore.data.first().asMap()
        assertNull(repository.permanentlyDeleteTrashedProject("same", now = 5_000L))
        assertEquals(broken, dataStore.data.first().asMap())
    }

    @Test
    fun aDeletionDuringApplyLosesToANewerIncomingVersion() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-apply-delete").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }, testKeyStore()
            )
            repository.saveProjects(listOf(SongProject(id = "x", updatedAt = 100L), SongProject(id = "y", updatedAt = 100L)))
            val base = repository.snapshotLocalSyncBase()
            // Both songs are deleted forever at 500 while the restore runs.
            for (id in listOf("x", "y")) {
                repository.moveProjectToTrash(id, 200L)
                repository.permanentlyDeleteTrashedProject(id, now = 500L)
            }
            // The incoming backup holds x edited at 900 and y unchanged at 100.
            val incoming = SyncBlob(projects = listOf(SongProject(id = "x", lyrics = "edited", updatedAt = 900L), SongProject(id = "y", updatedAt = 100L)))

            repository.applySyncResult(incoming, base)

            assertEquals(listOf("x"), repository.projectsFlow.first().map { it.id })
            assertEquals(listOf(SyncDeletion("y", deletedAt = 500L)), repository.snapshotLocalSyncBase().blob.deletions)
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun applyKeepsAnEditSavedBetweenSnapshotAndCommit() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-apply-race").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val repository = ProjectRepository(
                PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }, testKeyStore()
            )
            val song = SongProject(id = "racing", title = "Song", lyrics = "first draft", updatedAt = 100L)
            repository.saveProjects(listOf(song))
            val base = repository.snapshotLocalSyncBase()
            val merged = SyncMerger.merge(base.blob, SyncBlob(projects = listOf(song.copy(lyrics = "from backup", updatedAt = 200L))))
            // The writer keeps typing while the restore runs.
            repository.saveProjects(listOf(song.copy(lyrics = "newer lyrics", updatedAt = 300L)))

            repository.applySyncResult(merged, base)

            assertEquals("newer lyrics", repository.projectsFlow.first().single().lyrics)
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun libraryFlowsSkipWritesThatLeaveTheLibraryUnchanged() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-library-flow").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }
        val song = SongProject(id = "flow-1", title = "Before", lyrics = "line")
        val projectEmissions = java.util.concurrent.CopyOnWriteArrayList<List<SongProject>>()
        val trashEmissions = java.util.concurrent.CopyOnWriteArrayList<List<TrashedSongProject>>()

        try {
            val repository = ProjectRepository(dataStore, testKeyStore())
            repository.saveProjects(listOf(song))
            val collectors = listOf(
                scope.launch { repository.projectsFlow.collect { projectEmissions += it } },
                scope.launch { repository.trashedProjectsFlow.collect { trashEmissions += it } }
            )
            withTimeout(5_000) { while (projectEmissions.isEmpty() || trashEmissions.isEmpty()) delay(10) }

            // Editor position, draft and notebook writes rewrite other keys in the same store.
            repeat(3) { index ->
                repository.saveEditorState("Draft $index", "lyric $index", "")
                repository.saveWorkspace(song.id, SongWorkspace(scrollOffset = index.toFloat()))
                delay(50)
            }
            repository.saveProjects(listOf(song.copy(title = "After")))
            withTimeout(5_000) { while (projectEmissions.size < 2) delay(10) }
            delay(100)

            assertEquals(listOf("Before", "After"), projectEmissions.map { it.single().title })
            assertEquals(1, trashEmissions.size)
            collectors.forEach { it.cancelAndJoin() }
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    private fun syncedRecording(id: String) = RecordingManifestEntry(
        projectId = id, fileName = "take.m4a", sizeBytes = 3L, modifiedAt = 500L, sha256 = "synthetic", uploadedAt = 500L
    )

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

    @Test
    fun dominantHandDefaultsToRightAndRoundTripsThroughAFreshRepository() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-dominant-hand").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }
        try {
            val repository = ProjectRepository(dataStore, testKeyStore())
            assertEquals(com.rhymeai.app.data.model.DominantHand.RIGHT, repository.dominantHandFlow.first())

            repository.saveDominantHand(com.rhymeai.app.data.model.DominantHand.LEFT)
            assertEquals(
                com.rhymeai.app.data.model.DominantHand.LEFT,
                ProjectRepository(dataStore, testKeyStore()).dominantHandFlow.first()
            )

            repository.saveDominantHand(com.rhymeai.app.data.model.DominantHand.RIGHT)
            assertEquals(com.rhymeai.app.data.model.DominantHand.RIGHT, repository.dominantHandFlow.first())

            // A value this version doesn't know (a newer build, a corrupt write) reads as Right.
            dataStore.edit { it[stringPreferencesKey("dominant_hand")] = "ambidextrous" }
            assertEquals(com.rhymeai.app.data.model.DominantHand.RIGHT, repository.dominantHandFlow.first())
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun storedInkMarksStyleFromAnOlderVersionLeavesColorAnalysisSettingsIntact() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-legacy-ink-marks").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }
        val legacyStyleKey = stringPreferencesKey("analysis_presentation")
        try {
            // Ink Marks was removed; Color is the only analysis style, so the old value has no reader.
            dataStore.edit { it[legacyStyleKey] = "ink_marks" }
            val repository = ProjectRepository(dataStore, testKeyStore())

            assertEquals(ProjectRepository.EditorToggles(), repository.editorTogglesFlow.first())
            assertEquals(com.rhymeai.app.data.model.AppAppearance.INK, repository.appearanceFlow.first())

            val chosen = ProjectRepository.EditorToggles(
                isSyllableColoringEnabled = false,
                isRhymeHighlightEnabled = true
            )
            repository.saveEditorToggles(chosen)
            assertEquals(chosen, repository.editorTogglesFlow.first())
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun aTrashRestoreOfAnActiveIdKeepsTheActiveSongAndReturnsOtherWordsAsANewSong() = withRepository { _, repository ->
        val active = SongProject(id = "same", title = "Active", lyrics = "active words", updatedAt = 100L)
        val trashed = TrashedSongProject(active.copy(title = "Trashed", lyrics = "trash words", updatedAt = 50L), deletedAt = 500L)
        val other = SongProject(id = "other", title = "Other", updatedAt = 10L)
        repository.saveProjects(listOf(active, other))
        repository.saveTrashedProjects(listOf(trashed))

        val restored = repository.restoreTrashedProject("same", 900L)!!

        assertTrue(restored.activeKept && restored.copied)
        val kept = restored.projects.single { it.id == "same" }
        assertEquals(Triple("Active", "active words", ""), Triple(kept.title, kept.lyrics, kept.theme))
        assertEquals(501L, kept.updatedAt)
        assertEquals(false, kept.precedenceRepaired)
        val copy = restored.projects.single { it.id != "same" && it.id != "other" }
        assertEquals(Triple("Trashed", "trash words", 900L), Triple(copy.title, copy.lyrics, copy.updatedAt))
        assertEquals(emptyList(), repository.trashedProjectsFlow.first())
        assertEquals(restored.projects, repository.projectsFlow.first())
        // The next merge with a device still holding that Trash copy keeps the active song.
        val next = SyncMerger.resolve(SyncMerger.gather(SyncBlob(projects = restored.projects), SyncBlob(trashed = listOf(trashed))))
        assertEquals("active words", next.projects.single { it.id == "same" }.lyrics)
        assertTrue(next.trashed.none { it.project.id == "same" })
    }

    @Test
    fun aTrashRestoreOfAnActiveIdWithTheSameWordsOnlyRemovesTheTrashCopy() = withRepository { _, repository ->
        val active = SongProject(id = "same", title = "Song", lyrics = "words", updatedAt = 700L)
        repository.saveProjects(listOf(active))
        repository.saveTrashedProjects(listOf(TrashedSongProject(active.copy(updatedAt = 1L), deletedAt = 500L)))

        val restored = repository.restoreTrashedProject("same", 900L)!!

        assertTrue(restored.activeKept && !restored.copied)
        assertEquals(listOf(active), restored.projects)
        assertEquals(emptyList(), repository.trashedProjectsFlow.first())
    }

    @Test
    fun aTrashRestoreOfARepeatedIdWritesNothing() = withRepository { _, repository ->
        val song = SongProject(id = "same", title = "Song", lyrics = "words", updatedAt = 100L)
        repository.saveProjects(listOf(SongProject(id = "kept", title = "Kept", updatedAt = 1L)))
        val twoInTrash = listOf(TrashedSongProject(song, 200L), TrashedSongProject(song.copy(lyrics = "other"), 300L))
        repository.saveTrashedProjects(twoInTrash)
        assertFailsWith<SameIdTrashCopiesException> { repository.restoreTrashedProject("same", 900L) }
        assertEquals("kept", repository.projectsFlow.first().single().id)
        assertEquals(twoInTrash, repository.trashedProjectsFlow.first())

        val twoActive = listOf(song, song.copy(lyrics = "other"))
        repository.saveProjects(twoActive)
        repository.saveTrashedProjects(listOf(TrashedSongProject(song, 200L)))
        assertFailsWith<SameIdActiveCopiesException> { repository.restoreTrashedProject("same", 900L) }
        assertEquals(twoActive, repository.projectsFlow.first())
        assertEquals(listOf(TrashedSongProject(song, 200L)), repository.trashedProjectsFlow.first())
    }

    @Test
    fun aSyncCommitMovesTheSavedEditorStateWithTheSelectedSongInTheSameEdit() = withRepository { _, repository ->
        val open = SongProject(id = "open", title = "Open", lyrics = "older words", updatedAt = 100L)
        repository.saveActiveState(open, SongCreation(), open.title, open.lyrics, open.theme)
        // A newer stored version: the saved editor state follows it, and no copy is made.
        repository.applySyncResult(SyncBlob(projects = listOf(open.copy(lyrics = "newer words", updatedAt = 200L))), repository.snapshotLocalSyncBase())
        assertEquals("open", repository.currentProjectIdFlow.first())
        assertEquals(Triple("Open", "newer words", ""), repository.editorStateFlow().first())
        assertEquals(listOf("open"), repository.projectsFlow.first().map { it.id })
        // A commit that leaves the song unchanged keeps editor words saved apart from it (an older install's draft).
        repository.saveEditorState("Open", "legacy draft words", "")
        repository.applySyncResult(SyncBlob(projects = listOf(SongProject(id = "else", title = "Else", updatedAt = 5L))), repository.snapshotLocalSyncBase())
        assertEquals(Triple("Open", "legacy draft words", ""), repository.editorStateFlow().first())
        // Moved to Trash by the commit, with editor words equal to the song: the selection and editor state clear.
        repository.saveEditorState("Open", "newer words", "")
        repository.applySyncResult(SyncBlob(trashed = listOf(TrashedSongProject(open, deletedAt = 300L))), repository.snapshotLocalSyncBase())
        assertNull(repository.currentProjectIdFlow.first())
        assertEquals(Triple("", "", ""), repository.editorStateFlow().first())
        assertEquals(listOf("else"), repository.projectsFlow.first().map { it.id })
    }

    @Test
    fun aSyncCommitThatReplacesWordsAHeldFlushMarkedKeepsThemAsANewSongEvenAfterARelaunch() = withRepository { store, repository ->
        val open = SongProject(id = "open", title = "Open", lyrics = "older words", updatedAt = 100L)
        repository.saveActiveState(open, SongCreation(), open.title, open.lyrics, open.theme)
        // The held flush writes the edited words and marks them in that same write.
        repository.saveActiveState(open.copy(lyrics = "edited words"), null, "Open", "edited words", "", preserveAs = ticket("kept-open"))
        // The app dies here: a new repository over the same store has no memory of the editor.
        val relaunched = ProjectRepository(store, testKeyStore())
        relaunched.applySyncResult(SyncBlob(projects = listOf(open.copy(lyrics = "newer words", updatedAt = 200L))), relaunched.snapshotLocalSyncBase())
        val songs = relaunched.projectsFlow.first()
        assertEquals("newer words", songs.single { it.id == "open" }.lyrics)
        val copy = songs.single { it.id != "open" }
        // Under the id the held operation chose, so its reload finds it without reading the shared selection.
        assertEquals("kept-open", copy.id)
        assertEquals(Triple("Open", "edited words", false), Triple(copy.title, copy.lyrics, copy.precedenceRepaired))
        assertNull(relaunched.preservedTicket("open")?.copyId)
        // Selected in that same edit, so a relaunch shows it.
        assertEquals(copy.id, relaunched.currentProjectIdFlow.first())
        assertEquals(Triple("Open", "edited words", ""), relaunched.editorStateFlow().first())
        // The mark was consumed: a later replacement makes no further copy.
        relaunched.selectProject("open")
        relaunched.applySyncResult(SyncBlob(projects = listOf(open.copy(lyrics = "newest words", updatedAt = 300L))), relaunched.snapshotLocalSyncBase())
        assertEquals(2, relaunched.projectsFlow.first().size)
    }

    @Test
    fun aSyncCommitWithAMarkThatLeavesTheSongOrWasClearedMakesNoCopy() = withRepository { _, repository ->
        val open = SongProject(id = "open", title = "Open", lyrics = "edited words", updatedAt = 100L)
        repository.saveActiveState(open, SongCreation(), open.title, open.lyrics, open.theme, preserveAs = ticket("kept-1"))
        // Unchanged by the commit: no copy, and the mark stays for its own operation to clear.
        repository.applySyncResult(SyncBlob(projects = listOf(SongProject(id = "else", title = "Else", updatedAt = 5L))), repository.snapshotLocalSyncBase())
        assertEquals(setOf("open", "else"), repository.projectsFlow.first().map { it.id }.toSet())
        assertEquals("kept-1", repository.preservedTicket("open")?.copyId)
        // Cleared when its operation ended without replacing the song: a later replacement makes no copy.
        repository.clearPreservedSong("open", ticket("kept-1"))
        repository.applySyncResult(SyncBlob(projects = listOf(open.copy(lyrics = "newer words", updatedAt = 200L))), repository.snapshotLocalSyncBase())
        assertEquals(setOf("open", "else"), repository.projectsFlow.first().map { it.id }.toSet())
    }

    @Test
    fun anOperationEndingOnTheSameSongClearsOnlyItsOwnMarkSoAnotherWindowsEditsAreKept() = withRepository { _, repository ->
        val a = SongProject(id = "a", title = "A", lyrics = "w1", updatedAt = 100L)
        repository.saveActiveState(a, SongCreation(), a.title, a.lyrics, a.theme)
        // Window 1 starts a clean restore of A: it writes no mark. Window 2 flushes W2 and marks A with its own copy id.
        repository.saveActiveState(a.copy(lyrics = "w2"), null, "A", "w2", "", preserveAs = ticket("kept-2"))
        // Window 1's merge leaves W2 in place; its cleanup cannot clear window 2's mark (another copy id, or none).
        repository.applySyncResult(SyncBlob(projects = listOf(SongProject(id = "else", title = "Else", updatedAt = 5L))), repository.snapshotLocalSyncBase())
        repository.clearPreservedSong("a", ticket("kept-1"))
        assertEquals("kept-2", repository.preservedTicket("a")?.copyId)
        // Window 2's commit brings a newer W3: W2 is kept as its own song.
        repository.applySyncResult(SyncBlob(projects = listOf(a.copy(lyrics = "w3", updatedAt = System.currentTimeMillis() + 60_000L))), repository.snapshotLocalSyncBase())
        val songs = repository.projectsFlow.first()
        assertEquals("w3", songs.single { it.id == "a" }.lyrics)
        assertEquals("w2", songs.single { it.id == "kept-2" }.lyrics)
    }

    @Test
    fun marksOnTwoSongsAreKeptAndClearedEachForItsOwnSong() = withRepository { _, repository ->
        val a = SongProject(id = "a", title = "A", lyrics = "a words", updatedAt = 100L)
        val b = SongProject(id = "b", title = "B", lyrics = "b words", updatedAt = 100L)
        repository.saveActiveState(a, SongCreation(), a.title, a.lyrics, a.theme)
        repository.saveActiveState(b, SongCreation(), b.title, b.lyrics, b.theme)
        // Two held flushes (two windows), one per song.
        repository.saveActiveState(a.copy(lyrics = "a edits"), null, "A", "a edits", "", preserveAs = ticket("kept-a"))
        repository.saveActiveState(b.copy(lyrics = "b edits"), null, "B", "b edits", "", preserveAs = ticket("kept-b"))
        // B's commit replaces only B: it keeps B's edits and leaves A's mark alone.
        repository.applySyncResult(SyncBlob(projects = listOf(b.copy(lyrics = "b newer", updatedAt = 200L))), repository.snapshotLocalSyncBase())
        assertEquals("b edits", repository.projectsFlow.first().single { it.id == "kept-b" }.lyrics)
        assertNull(repository.preservedTicket("b")?.copyId)
        assertEquals("kept-a", repository.preservedTicket("a")?.copyId)
        // Another hold on B that ends without a commit clears only B's mark.
        repository.saveActiveState(b.copy(lyrics = "b newer edits"), null, "B", "b newer edits", "", preserveAs = ticket("kept-b2"))
        repository.clearPreservedSong("b", ticket("kept-b2"))
        assertEquals("kept-a", repository.preservedTicket("a")?.copyId)
        // A's commit then keeps A's edits under A's own id.
        repository.applySyncResult(SyncBlob(projects = listOf(a.copy(lyrics = "a newer", updatedAt = System.currentTimeMillis() + 60_000L))), repository.snapshotLocalSyncBase())
        val songs = repository.projectsFlow.first()
        assertEquals("a newer", songs.single { it.id == "a" }.lyrics)
        assertEquals("a edits", songs.single { it.id == "kept-a" }.lyrics)
        assertEquals(setOf("a", "b", "kept-a", "kept-b"), songs.map { it.id }.toSet())
        assertNull(repository.preservedTicket("a")?.copyId)
    }

    @Test
    fun aSyncCommitThatReplacesTheSelectedSongKeepsDifferentSavedEditorWordsAsANewSong() = withRepository { _, repository ->
        val open = SongProject(id = "open", title = "Untitled Song", lyrics = "stored words", updatedAt = 100L)
        repository.saveActiveState(open, SongCreation(), "", open.lyrics, open.theme)
        // A blank editor title is the stored "Untitled Song": the same words, so no copy.
        repository.applySyncResult(SyncBlob(projects = listOf(open.copy(lyrics = "newer words", updatedAt = 200L))), repository.snapshotLocalSyncBase())
        assertEquals(listOf("open"), repository.projectsFlow.first().map { it.id })
        // Editor words saved apart from the song (an older install's draft, shown at startup) are kept when it is replaced.
        repository.saveEditorState("", "legacy draft words", "")
        repository.applySyncResult(SyncBlob(projects = listOf(open.copy(lyrics = "newest words", updatedAt = 300L))), repository.snapshotLocalSyncBase())
        val songs = repository.projectsFlow.first()
        assertEquals("newest words", songs.single { it.id == "open" }.lyrics)
        val copy = songs.single { it.id != "open" }
        assertEquals("Untitled Song" to "legacy draft words", copy.title to copy.lyrics)
        assertEquals(copy.id, repository.currentProjectIdFlow.first())
        // All-blank editor fields hold no words: nothing is copied.
        repository.saveActiveState(songs.single { it.id == "open" }, null, "", "", "")
        repository.applySyncResult(SyncBlob(projects = listOf(open.copy(lyrics = "latest words", updatedAt = 400L))), repository.snapshotLocalSyncBase())
        assertEquals(2, repository.projectsFlow.first().size)
    }

    @Test
    fun aTrashRestoreOfAnActiveIdIsRefusedWhenTheTrashTimeCannotBeBeaten() = withRepository { _, repository ->
        val active = SongProject(id = "same", title = "Active", lyrics = "active words", updatedAt = 100L)
        val trashed = TrashedSongProject(active.copy(lyrics = "trash words"), deletedAt = Long.MAX_VALUE)
        repository.saveProjects(listOf(active))
        repository.saveTrashedProjects(listOf(trashed))
        assertFailsWith<TrashCopyOutranksActiveException> { repository.restoreTrashedProject("same", 900L) }
        assertEquals(listOf(active), repository.projectsFlow.first())
        assertEquals(listOf(trashed), repository.trashedProjectsFlow.first())
    }

    @Test
    fun aTrashRestoreOfAnActiveIdOverARepairedEndOfTimeTrashTimeIsAcceptedAndTheActiveSongWinsTheNextMerge() = withRepository { _, repository ->
        val active = SongProject(id = "same", title = "Active", lyrics = "active words", updatedAt = 100L)
        val trashed = TrashedSongProject(active.copy(lyrics = "trash words"), deletedAt = Long.MAX_VALUE, deletedAtRepaired = true)
        repository.saveProjects(listOf(active))
        repository.saveTrashedProjects(listOf(trashed))
        repository.restoreTrashedProject("same", 900L)
        val kept = repository.projectsFlow.first().single { it.id == "same" }
        assertEquals("active words", kept.lyrics)
        // A device that still holds the Trash entry merges it with the kept row: a real time outranks a repair.
        val merged = SyncMerger.resolve(SyncMerger.gather(SyncBlob(projects = listOf(kept)), SyncBlob(trashed = listOf(trashed))))
        assertEquals(listOf(kept), merged.projects)
        assertTrue(merged.trashed.none { it.project.id == "same" })
    }

    @Test
    fun aTrashRestoreOfAnActiveIdClearsOnlyItsOwnPendingCleanupAndKeepsItsRecordingsAndNotebook() = withRepository { store, repository ->
        val active = SongProject(id = "same", title = "Active", lyrics = "active words", updatedAt = 100L)
        repository.saveProjects(listOf(active))
        repository.saveTrashedProjects(listOf(TrashedSongProject(active.copy(lyrics = "trash words"), deletedAt = 500L)))
        val notebook = com.rhymeai.app.data.model.SongWorkspace(checkpointAt = 123L)
        repository.saveWorkspace("same", notebook)
        repository.recordRecordingDeletion("same", "old.m4a", "1b2c3d4e-5f60-4718-9a2b-3c4d5e6f7a8b", 50L)
        store.edit {
            it[recordsKey] = """[{"id":"$recordingId","projectId":"same","displayName":"take.m4a","uploadedAt":500,"sha256":"$digest",""" +
                """"bytes":4,"origin":"recorded","path":"voice-memos/same/$recordingId.m4a"}]"""
            it[stringSetPreferencesKey("pending_recording_deletions")] = setOf("same", "gone")
        }
        val records = repository.recordingRecords()
        val tombstones = repository.syncDeletions()

        repository.restoreTrashedProject("same", 900L)!!

        assertEquals(setOf("gone"), repository.pendingRecordingDeletionIds())
        assertEquals(records, repository.recordingRecords())
        assertEquals(tombstones, repository.syncDeletions())
        assertEquals(notebook, repository.workspacesFlow.first()["same"])
        // The directory cleanup removes only the song no longer here, never the restored song's recordings.
        val removed = mutableListOf<String>()
        repository.retryPendingRecordingDeletions { removed += it; true }
        assertEquals(listOf("gone"), removed)
    }

    @Test
    fun trashAndPreservedCopyAllocationsSkipReservedIdsOrAbort() = withRepository { store, repository ->
        val active = SongProject(id = "same", title = "Active", lyrics = "active words", updatedAt = 100L)
        val other = SongProject(id = "u", title = "Other", lyrics = "other words", updatedAt = 100L)
        val otherTrash = TrashedSongProject(SongProject(id = "t", title = "T", lyrics = "t words", updatedAt = 50L), deletedAt = 60L)
        repository.saveProjects(listOf(active, other))
        repository.saveTrashedProjects(listOf(TrashedSongProject(active.copy(lyrics = "trash words"), deletedAt = 200L), otherTrash))
        store.edit { it[stringPreferencesKey("sync_deletions_json")] = """[{"projectId":"dead","deletedAt":70}]""" }
        // Every draw is taken (the keeper, another active song, a Trash song, a song tombstone): nothing is written.
        val before = store.data.first()
        withAllocator("same", "u", "t", "dead", "same", "u", "t", "dead") {
            assertFailsWith<SongIdUnavailableException> { repository.restoreTrashedProject("same", 900L) }
        }
        assertEquals(before, store.data.first())
        // The same clashes, then a free draw: the Trash words come back under it beside the unchanged keeper.
        withAllocator("same", "u", "t", "dead", "fresh") { repository.restoreTrashedProject("same", 900L) }
        val songs = repository.projectsFlow.first()
        assertEquals(listOf("fresh", "same", "u"), songs.map { it.id })
        assertEquals(Triple("Active", "trash words", 900L), Triple(songs[0].title, songs[0].lyrics, songs[0].updatedAt))
        assertEquals(active.copy(updatedAt = 201L), songs[1])
        assertEquals(other, songs[2])
        assertEquals(listOf(otherTrash), repository.trashedProjectsFlow.first())

        // A held flush marked "same" with the id of the unrelated "u", and the editor holds other words: the commit that
        // replaces "same" gives the editor copy and then the marked copy ids no row, Trash, tombstone or earlier copy holds.
        repository.saveActiveState(songs[1].copy(lyrics = "held words"), null, "Active", "held words", "", preserveAs = ticket("u"))
        repository.saveEditorState("Active", "editor words", "")
        val incoming = SyncBlob(projects = listOf(active.copy(lyrics = "incoming words", updatedAt = System.currentTimeMillis() + 60_000L)))
        val beforeCommit = store.data.first()
        withAllocator("ed", "same", "u", "t", "dead", "fresh", "ed", "u", "t") {
            assertFailsWith<SongIdUnavailableException> { repository.applySyncResult(incoming, repository.snapshotLocalSyncBase()) }
        }
        assertEquals(beforeCommit, store.data.first())
        withAllocator("ed", "same", "u", "t", "dead", "fresh", "ed", "kept") { repository.applySyncResult(incoming, repository.snapshotLocalSyncBase()) }
        val committed = repository.projectsFlow.first()
        assertEquals(
            mapOf("ed" to "editor words", "kept" to "held words", "same" to "incoming words", "u" to "other words", "fresh" to "trash words"),
            committed.associate { it.id to it.lyrics }
        )
        assertEquals(5, committed.size)
        assertEquals(listOf(otherTrash), repository.trashedProjectsFlow.first())
        assertEquals("ed", repository.currentProjectIdFlow.first())
        assertNull(repository.preservedTicket("same")?.copyId)
        // The hold that asked for "u" gets the copy the commit actually made.
        assertEquals(HoldResult.Adopted(committed.single { it.id == "kept" }, appended = true), repository.resolveHold("same", ticket("u")))
    }

    private val later get() = System.currentTimeMillis() + 60_000L

    @Test
    fun twoMarksOnOneCopyIdKeepBothReplacedSongsUnderFourDistinctIds() = withRepository { _, repository ->
        val a = SongProject(id = "a", title = "A", lyrics = "a old", updatedAt = 100L)
        val b = SongProject(id = "b", title = "B", lyrics = "b old", updatedAt = 100L)
        repository.saveActiveState(a, SongCreation(), a.title, a.lyrics, a.theme)
        repository.saveActiveState(b, SongCreation(), b.title, b.lyrics, b.theme)
        // Two held flushes, one per song, asked for the same copy id.
        repository.saveActiveState(a, null, "A", "a old", "", preserveAs = ticket("x"))
        repository.saveActiveState(b, null, "B", "b old", "", preserveAs = ticket("x"))
        repository.applySyncResult(SyncBlob(projects = listOf(a.copy(lyrics = "a new", updatedAt = later), b.copy(lyrics = "b new", updatedAt = later))), repository.snapshotLocalSyncBase())
        val songs = repository.projectsFlow.first()
        assertEquals(4, songs.map { it.id }.toSet().size)
        assertEquals(listOf("a new", "a old", "b new", "b old"), songs.map { it.lyrics }.sorted())
        assertNull(repository.preservedTicket("a")?.copyId)
        assertNull(repository.preservedTicket("b")?.copyId)
    }

    @Test
    fun anUnrelatedSongAtTheMarkedIdIsLeftAndTheWordsGetAFreshId() = withRepository { _, repository ->
        val a = SongProject(id = "a", title = "A", lyrics = "a old", updatedAt = 100L)
        val other = SongProject(id = "x", title = "Other", lyrics = "other", updatedAt = 100L)
        repository.saveActiveState(other, SongCreation(), other.title, other.lyrics, other.theme)
        repository.saveActiveState(a, SongCreation(), a.title, a.lyrics, a.theme)
        repository.saveActiveState(a, null, "A", "a old", "", preserveAs = ticket("x"))
        repository.applySyncResult(SyncBlob(projects = listOf(a.copy(lyrics = "a new", updatedAt = later))), repository.snapshotLocalSyncBase())
        val songs = repository.projectsFlow.first()
        assertEquals(other, songs.single { it.id == "x" })
        assertEquals("a new", songs.single { it.id == "a" }.lyrics)
        val copy = songs.single { it.lyrics == "a old" }
        assertTrue(copy.id !in setOf("a", "x"))
        assertEquals(3, songs.size)
        assertNull(repository.preservedTicket("a")?.copyId)
        assertEquals(copy.id, repository.currentProjectIdFlow.first())
    }

    @Test
    fun aRowAlreadyHoldingTheMarkedWordsIsReusedNotAppended() = withRepository { _, repository ->
        val a = SongProject(id = "a", title = "A", lyrics = "a old", updatedAt = 100L)
        val held = ticket("x")
        repository.saveActiveState(a, SongCreation(), a.title, a.lyrics, a.theme)
        repository.saveActiveState(a, null, "A", "a old", "", preserveAs = held)
        // Another device already kept the words under the requested id.
        repository.applySyncResult(
            SyncBlob(projects = listOf(a.copy(lyrics = "a new", updatedAt = later), SongProject(id = "x", title = "A", lyrics = "a old", updatedAt = 150L))),
            repository.snapshotLocalSyncBase()
        )
        val songs = repository.projectsFlow.first()
        assertEquals(mapOf("a" to "a new", "x" to "a old"), songs.associate { it.id to it.lyrics })
        assertEquals(2, songs.size)
        assertEquals("x", repository.currentProjectIdFlow.first())
        assertEquals(Triple("A", "a old", ""), repository.editorStateFlow().first())
        assertNull(repository.preservedTicket("a")?.copyId)
        assertEquals(HoldResult.Adopted(songs.single { it.id == "x" }, appended = false), repository.resolveHold("a", held))
    }

    @Test
    fun aTrashedSongAtTheMarkedIdGetsAFreshActiveId() = withRepository { _, repository ->
        val a = SongProject(id = "a", title = "A", lyrics = "a old", updatedAt = 100L)
        val trashed = TrashedSongProject(SongProject(id = "x", title = "T", lyrics = "trash words", updatedAt = 50L), deletedAt = 60L)
        repository.saveActiveState(a, SongCreation(), a.title, a.lyrics, a.theme)
        repository.saveTrashedProjects(listOf(trashed))
        repository.saveActiveState(a, null, "A", "a old", "", preserveAs = ticket("x"))
        repository.applySyncResult(SyncBlob(projects = listOf(a.copy(lyrics = "a new", updatedAt = later))), repository.snapshotLocalSyncBase())
        assertEquals(listOf(trashed), repository.trashedProjectsFlow.first())
        val songs = repository.projectsFlow.first()
        assertEquals(2, songs.size)
        assertTrue(songs.single { it.lyrics == "a old" }.id !in setOf("a", "x"))
    }

    @Test
    fun theEditorCopyKeepsPriorityAndNeverSharesAnIdWithAMarkedCopy() = withRepository { _, repository ->
        val a = SongProject(id = "a", title = "A", lyrics = "a old", updatedAt = 100L)
        repository.saveActiveState(a, SongCreation(), a.title, a.lyrics, a.theme)
        repository.saveActiveState(a, null, "A", "a old", "", preserveAs = ticket("x"))
        repository.saveEditorState("A", "editor words", "")
        // The allocator offers the marked id to the editor copy first.
        withAllocator("x", "fresh") {
            repository.applySyncResult(SyncBlob(projects = listOf(a.copy(lyrics = "a new", updatedAt = later))), repository.snapshotLocalSyncBase())
        }
        val songs = repository.projectsFlow.first()
        assertEquals(3, songs.map { it.id }.toSet().size)
        assertEquals(mapOf("x" to "editor words", "fresh" to "a old", "a" to "a new"), songs.associate { it.id to it.lyrics })
        assertEquals("x", repository.currentProjectIdFlow.first())
        assertEquals(Triple("A", "editor words", ""), repository.editorStateFlow().first())
    }

    @Test
    fun divergentSavedEditorWordsStillBecomeTheirOwnSongBesideTheMarkedCopy() = withRepository { _, repository ->
        val open = SongProject(id = "open", title = "Untitled Song", lyrics = "stored words", updatedAt = 100L)
        repository.saveActiveState(open, SongCreation(), "", open.lyrics, open.theme)
        repository.saveActiveState(open, null, "", open.lyrics, open.theme, preserveAs = ticket("kept"))
        repository.saveEditorState("", "legacy draft words", "")
        repository.applySyncResult(SyncBlob(projects = listOf(open.copy(lyrics = "newest words", updatedAt = later))), repository.snapshotLocalSyncBase())
        val songs = repository.projectsFlow.first()
        assertEquals(listOf("legacy draft words", "newest words", "stored words"), songs.map { it.lyrics }.sorted())
        assertEquals(3, songs.map { it.id }.toSet().size)
        assertEquals(songs.single { it.lyrics == "legacy draft words" }.id, repository.currentProjectIdFlow.first())
    }

    @Test
    fun anUnaffectedMarkSurvivesACommitThatActsOnAnother() = withRepository { _, repository ->
        val a = SongProject(id = "a", title = "A", lyrics = "a words", updatedAt = 100L)
        val b = SongProject(id = "b", title = "B", lyrics = "b words", updatedAt = 100L)
        repository.saveActiveState(a, SongCreation(), a.title, a.lyrics, a.theme)
        repository.saveActiveState(b, SongCreation(), b.title, b.lyrics, b.theme)
        repository.saveActiveState(a.copy(lyrics = "a edits"), null, "A", "a edits", "", preserveAs = ticket("kept-a"))
        repository.saveActiveState(b.copy(lyrics = "b edits"), null, "B", "b edits", "", preserveAs = ticket("kept-b"))
        repository.applySyncResult(SyncBlob(projects = listOf(a.copy(lyrics = "a newer", updatedAt = later))), repository.snapshotLocalSyncBase())
        assertNull(repository.preservedTicket("a")?.copyId)
        assertEquals("kept-b", repository.preservedTicket("b")?.copyId)
        assertEquals(setOf("a", "b", "kept-a"), repository.projectsFlow.first().map { it.id }.toSet())
    }

    @Test
    fun twoSourcesWithIdenticalWordsNeverShareAReusedTarget() = withRepository { _, repository ->
        val a = SongProject(id = "a", title = "Same", lyrics = "same old", updatedAt = 100L)
        val b = SongProject(id = "b", title = "Same", lyrics = "same old", updatedAt = 100L)
        val ticketA = PreservationTicket("x")
        val ticketB = PreservationTicket("x")
        repository.saveActiveState(a, SongCreation(), a.title, a.lyrics, a.theme)
        repository.saveActiveState(b, SongCreation(), b.title, b.lyrics, b.theme)
        repository.saveActiveState(a, null, "Same", "same old", "", preserveAs = ticketA)
        repository.saveActiveState(b, null, "Same", "same old", "", preserveAs = ticketB)
        repository.applySyncResult(
            SyncBlob(projects = listOf(
                a.copy(lyrics = "a new", updatedAt = later), b.copy(lyrics = "b new", updatedAt = later),
                SongProject(id = "x", title = "Same", lyrics = "same old", updatedAt = 150L)
            )),
            repository.snapshotLocalSyncBase()
        )
        val songs = repository.projectsFlow.first()
        val kept = songs.filter { it.lyrics == "same old" }
        // One source reuses "x"; the other gets its own row.
        assertEquals(2, kept.map { it.id }.toSet().size)
        assertTrue("x" in kept.map { it.id })
        assertEquals(4, songs.size)
        assertNull(repository.preservedTicket("a")?.copyId)
        assertNull(repository.preservedTicket("b")?.copyId)

        val resultA = assertIs<HoldResult.Adopted>(repository.resolveHold("a", ticketA))
        val resultB = assertIs<HoldResult.Adopted>(repository.resolveHold("b", ticketB))
        assertNotEquals(resultA.row.id, resultB.row.id, "Each ticket must have its own target")
        val reused = kept.single { it.id == "x" }
        val appended = kept.single { it.id != "x" }
        assertEquals(
            setOf(HoldResult.Adopted(reused, appended = false), HoldResult.Adopted(appended, appended = true)),
            setOf(resultA, resultB)
        )

        val edited = resultA.row.copy(lyrics = "edited a copy", updatedAt = later)
        repository.saveActiveState(edited, null, edited.title, edited.lyrics, edited.theme)
        val miss = assertIs<HoldResult.Miss>(repository.resolveHold("a", ticketA))
        assertEquals("a", miss.source?.id)
        assertEquals(resultB, repository.resolveHold("b", ticketB))
    }

    @Test
    fun newCreationCannotOverwriteEarlierCreationInSameRepository() = withRepository { store, repository ->
        val first = SongProject(id = "x", title = "First", lyrics = "w1", updatedAt = 10L)
        repository.saveActiveState(first, SongCreation(), first.title, first.lyrics, "")
        val before = store.data.first().asMap()
        // A second new draft drew the same id: its creation is not the one that made the row.
        val second = SongProject(id = "x", title = "Second", lyrics = "w2", updatedAt = 20L)
        assertFailsWith<CreationIdTakenException> {
            repository.saveActiveState(second, SongCreation(), second.title, second.lyrics, "")
        }
        assertEquals(before, store.data.first().asMap())
    }

    @Test
    fun creationClaimCommitsWithRowAndGenuineRetryKeepsItsId() = withRepository { store, repository ->
        val failing = object : DataStore<Preferences> by store {
            override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences =
                store.updateData { current -> transform(current); throw IOException("injected write failure") }
        }
        val draft = SongProject(id = "x", title = "Mine", lyrics = "mine", updatedAt = 10L)
        // A failed insert claims nothing: retried with its own creation it still inserts, at the same id.
        val retried = SongCreation()
        assertFailsWith<IOException> { ProjectRepository(failing, testKeyStore()).saveActiveState(draft, retried, "Mine", "mine", "") }
        repository.saveActiveState(draft, retried, "Mine", "mine", "")
        assertEquals(listOf("mine"), repository.projectsFlow.first().map { it.lyrics })

        // A failed insert, then another window's creation takes the id: the retry is refused and the occupant kept.
        store.edit { it.clear() }
        val lost = SongCreation()
        assertFailsWith<IOException> { ProjectRepository(failing, testKeyStore()).saveActiveState(draft, lost, "Mine", "mine", "") }
        val occupant = SongProject(id = "x", title = "Other", lyrics = "other", updatedAt = 20L)
        ProjectRepository(store, testKeyStore()).saveActiveState(occupant, SongCreation(), "Other", "other", "")
        val before = store.data.first().asMap()
        assertFailsWith<CreationIdTakenException> { repository.saveActiveState(draft, lost, "Mine", "mine", "") }
        assertEquals(before, store.data.first().asMap())

        // A committed creation's own later saves update its one row.
        store.edit { it.clear() }
        val mine = SongCreation()
        repository.saveActiveState(draft, mine, "Mine", "mine", "")
        repository.saveActiveState(draft.copy(lyrics = "mine edited", updatedAt = 30L), mine, "Mine", "mine edited", "")
        assertEquals(listOf("x" to "mine edited"), repository.projectsFlow.first().map { it.id to it.lyrics })

        // Leave the id free of both Trash and tombstones so the committed creation is what prevents reinsertion.
        val survivor = SongProject(id = "other", title = "Survivor", lyrics = "keep these words", updatedAt = 40L)
        repository.saveActiveState(survivor, SongCreation(), survivor.title, survivor.lyrics, survivor.theme)
        repository.saveProjects(listOf(survivor))
        val afterRemoval = store.data.first()

        val retry = runCatching { repository.saveActiveState(draft, mine, draft.title, draft.lyrics, draft.theme) }

        assertEquals(listOf(survivor), repository.projectsFlow.first(), "A committed creation must never recreate a removed row")
        assertEquals(afterRemoval, store.data.first())
        assertTrue(retry.isFailure)
    }

    @Test
    fun aNewSongIdNamedByASongTombstoneIsRefused() = withRepository { store, repository ->
        store.edit { it[stringPreferencesKey("sync_deletions_json")] = """[{"projectId":"x","deletedAt":70}]""" }
        val before = store.data.first().asMap()
        val draft = SongProject(id = "x", title = "New", lyrics = "new", updatedAt = 10L)
        assertFailsWith<CreationIdTakenException> { repository.saveActiveState(draft, SongCreation(), "New", "new", "") }
        assertEquals(before, store.data.first().asMap())
    }

    @Test
    fun aNewSongWhoseGeneratedIdIsAnUnrelatedSongIsRefusedWithoutWriting() = withRepository { store, repository ->
        // A song stored before creations carried tokens; it is still edited by ordinary saves.
        val stored = SongProject(id = "x", title = "Stored", lyrics = "stored", updatedAt = 10L)
        repository.saveProjects(listOf(stored))
        val before = store.data.first().asMap()
        val draft = SongProject(id = "x", title = "New", lyrics = "new", updatedAt = 20L)
        assertFailsWith<CreationIdTakenException> { repository.saveActiveState(draft, SongCreation(), "New", "new", "") }
        assertEquals(before, store.data.first().asMap())
        repository.saveActiveState(stored.copy(lyrics = "edited", updatedAt = 30L), null, "Stored", "edited", "")
        assertEquals(listOf("edited"), repository.projectsFlow.first().map { it.lyrics })
    }

    /** A new song [id] made by its creation and selected, then marked by a held flush with [held]. */
    private suspend fun ProjectRepository.heldSong(id: String, held: PreservationTicket): SongProject {
        val song = SongProject(id = id, title = id.uppercase(), lyrics = "$id old", updatedAt = 100L)
        saveActiveState(song, SongCreation(), song.title, song.lyrics, song.theme)
        saveActiveState(song, null, song.title, song.lyrics, song.theme, preserveAs = held)
        return song
    }

    private suspend fun ProjectRepository.replace(vararg songs: SongProject) =
        applySyncResult(SyncBlob(projects = songs.map { it.copy(lyrics = "${it.id} new", updatedAt = later) }), snapshotLocalSyncBase())

    @Test
    fun differentTicketsForOneSourceDoNotShareAResult() = withRepository { _, repository ->
        // Two requests for "a" asked for the same copy id; the later one's mark is the stored one.
        val older = PreservationTicket("x")
        val winner = PreservationTicket("x")
        val a = repository.heldSong("a", older)
        repository.saveActiveState(a, null, a.title, a.lyrics, a.theme, preserveAs = winner)
        repository.clearPreservedSong("a", older)
        assertEquals(winner, repository.preservedTicket("a"))
        repository.replace(a)
        val kept = repository.projectsFlow.first().single { it.lyrics == "a old" }
        assertEquals(HoldResult.Adopted(kept, appended = true), repository.resolveHold("a", winner))
        // The older request and one the commit never saw get the source, not the winner's copy.
        for (other in listOf(older, PreservationTicket("x"))) {
            val miss = repository.resolveHold("a", other)
            assertTrue(miss is HoldResult.Miss && miss.source?.lyrics == "a new", "$other: $miss")
        }
        assertEquals(HoldResult.Adopted(kept, appended = true), repository.resolveHold("a", winner))
    }

    @Test
    fun aMarkStoredBeforeTicketsIsOneTicketItsReadersShare() = withRepository { store, repository ->
        val a = repository.heldSong("a", PreservationTicket("unused"))
        store.edit { it[stringPreferencesKey("preserved_songs_json")] = """{"a":"kept"}""" }
        val legacy = repository.preservedTicket("a")!!
        assertEquals(PreservationTicket("kept", token = ""), legacy)
        repository.replace(a)
        val kept = repository.projectsFlow.first().single { it.id == "kept" }
        assertEquals("a old", kept.lyrics)
        assertEquals(HoldResult.Adopted(kept, appended = true), repository.resolveHold("a", repository.preservedTicket("a") ?: legacy))
    }

    @Test
    fun movedThenReintroducedIdenticalWordsDoNotSatisfyOldReceipt() = withRepository { _, repository ->
        val held = PreservationTicket("x")
        val a = repository.heldSong("a", held)
        repository.replace(a)
        val x = repository.projectsFlow.first().single { it.id == "x" }
        assertEquals(HoldResult.Adopted(x, appended = true), repository.resolveHold("a", held))
        // X leaves for Trash, then a newer incoming X with the same words is active again before anyone claims.
        repository.moveProjectToTrash("x", 300L)
        val current = repository.projectsFlow.first()
        repository.applySyncResult(SyncBlob(projects = current + x.copy(updatedAt = later + 1_000L)), repository.snapshotLocalSyncBase())
        val back = repository.projectsFlow.first().single { it.id == "x" }
        assertEquals(Triple(x.title, x.lyrics, x.theme), Triple(back.title, back.lyrics, back.theme))
        val miss = repository.resolveHold("a", held)
        assertTrue(miss is HoldResult.Miss && miss.source?.id == "a", "$miss")
        // The holder's next save goes to its source and leaves X as it is.
        val source = (miss as HoldResult.Miss).source!!
        repository.saveActiveState(source.copy(lyrics = "holder words"), null, source.title, "holder words", source.theme)
        assertEquals(back, repository.projectsFlow.first().single { it.id == "x" })
    }

    @Test
    fun targetEditedBeforeClaimCannotBeReplayed() = withRepository { _, repository ->
        val ta = PreservationTicket("xa")
        val tb = PreservationTicket("xb")
        val a = repository.heldSong("a", ta)
        val b = repository.heldSong("b", tb)
        repository.replace(a, b)
        val songs = repository.projectsFlow.first()
        val xa = songs.single { it.id == "xa" }
        val xb = songs.single { it.id == "xb" }
        // B's copy now has other words.
        repository.saveActiveState(xb.copy(lyrics = "b edited"), null, xb.title, "b edited", xb.theme)
        val missB = repository.resolveHold("b", tb)
        assertTrue(missB is HoldResult.Miss && missB.source?.id == "b", "$missB")
        // A's copy is edited away and back: the first change ended its result.
        repository.saveActiveState(xa.copy(lyrics = "changed"), null, xa.title, "changed", xa.theme)
        repository.saveActiveState(xa, null, xa.title, xa.lyrics, xa.theme)
        val missA = repository.resolveHold("a", ta)
        assertTrue(missA is HoldResult.Miss && missA.source?.id == "a", "$missA")
    }

    @Test
    fun preservationCommitIsAtomicAndRelaunchUsesStoredSelection() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-preserve").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val store = PreferenceDataStoreFactory.create(scope = scope) { file }
            val repository = ProjectRepository(store, testKeyStore())
            val held = PreservationTicket("x")
            val a = repository.heldSong("a", held)
            // The commit's edit fails once its result is built: none of it is stored.
            val failing = object : DataStore<Preferences> by store {
                override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences =
                    store.updateData { current ->
                        transform(current).also { next ->
                            if (next.asMap().keys.any { it.name == "preserved_receipts_json" }) throw IOException("injected write failure")
                        }
                    }
            }
            val before = store.data.first()
            assertFailsWith<IOException> { ProjectRepository(failing, testKeyStore()).replace(a) }
            assertEquals(before, store.data.first())
            assertTrue(repository.resolveHold("a", held) is HoldResult.Miss)
            repository.replace(a)
            scope.coroutineContext[Job]!!.cancelAndJoin()
            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopenedStore = PreferenceDataStoreFactory.create(scope = reopenedScope) { file }
                val reopened = ProjectRepository(reopenedStore, testKeyStore())
                val x = reopened.projectsFlow.first().single { it.id == "x" }
                assertEquals("a old", x.lyrics)
                // The commit selected the held words' copy and the editor shows them, as a relaunch reads them.
                val prefs = reopenedStore.data.first()
                assertEquals("x", prefs[stringPreferencesKey("current_project_id")])
                assertEquals("a old", prefs[stringPreferencesKey("current_lyrics")])
                assertNull(reopened.preservedTicket("a"))
                assertEquals(HoldResult.Adopted(x, appended = true), reopened.resolveHold("a", held))
                reopened.saveActiveState(x.copy(lyrics = "next"), null, x.title, "next", x.theme)
                assertEquals(mapOf("a" to "a new", "x" to "next"), reopened.projectsFlow.first().associate { it.id to it.lyrics })
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    private fun ticket(copyId: String) = PreservationTicket(copyId, token = "token-$copyId")

    private suspend fun <T> withAllocator(vararg ids: String, block: suspend () -> T): T {
        val draws = ArrayDeque(ids.toList())
        val saved = com.rhymeai.app.SongIdAllocator.next
        com.rhymeai.app.SongIdAllocator.next = { draws.removeFirst() }
        try {
            return block()
        } finally {
            com.rhymeai.app.SongIdAllocator.next = saved
        }
    }

    private fun testKeyStore(): SecureKeyStore = object : SecureKeyStore {
        override fun getKey(provider: String) = ""
        override fun setKey(provider: String, key: String) = Unit
        override fun allKeys(): Map<String, String> = emptyMap()
        override fun clear() = Unit
    }
    private fun withRepository(block: suspend (DataStore<Preferences>, ProjectRepository) -> Unit) = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-precedence").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val dataStore = PreferenceDataStoreFactory.create(scope = scope) { File(directory, "prefs.preferences_pb") }
        try {
            block(dataStore, ProjectRepository(dataStore, testKeyStore()))
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    private val recordsKey = stringPreferencesKey("recording_records_json")
    private val firstSeenKey = stringPreferencesKey("first_seen_precedence_json")
    private val recordingId = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"
    private val digest = "a".repeat(64)

    @Test
    fun aRecordingInTrashWithoutATrashTimeGetsItsFirstSeenTimeBeforeAnyDeadline() = withRepository { store, repository ->
        // T2.35: trashedAt=0 must never read as an epoch deadline (expired at once).
        store.edit {
            it[recordsKey] = """[{"id":"$recordingId","projectId":"p","displayName":"take.m4a","uploadedAt":500,"sha256":"$digest",""" +
                """"bytes":4,"origin":"recorded","path":"voice-memos-trash/p/$recordingId.m4a","trashedAt":0}]"""
        }
        val before = System.currentTimeMillis()

        val first = repository.recordingRecords().single()
        val again = repository.recordingRecords().single()

        assertTrue(first.trashedAt!! >= before && first.trashedAt!! <= System.currentTimeMillis())
        assertEquals(first.trashedAt, again.trashedAt)
        assertEquals(500L, first.uploadedAt)
        assertTrue(store.data.first()[firstSeenKey]!!.contains("\"rtrash:$recordingId\":${first.trashedAt}"))
    }

    @Test
    fun historicalRowsWithoutTimesOrIdsAreRepairedAndInvalidOnesFailClosed() = withRepository { store, repository ->
        // T3.11/T3.12: songs and Trash written before precedence fields existed.
        store.edit {
            it[stringPreferencesKey("projects_json")] = """[{"id":"s1","title":"Old","lyrics":"x"}]"""
            it[stringPreferencesKey("trashed_projects_json")] = """[{"project":{"id":"t1","title":"T","updatedAt":500}}]"""
            // T3.4/T3.28: a row from before A21 has no id and calls the display name fileName.
            it[recordsKey] = """[{"projectId":"p","fileName":"take.m4a","uploadedAt":700,"sha256":"$digest","bytes":4,"origin":"recorded"}]"""
        }

        repository.establishPrecedence(emptyList(), 7_000L)

        val song = repository.projectsFlow.first().single()
        assertEquals(7_000L, song.updatedAt)
        assertTrue(song.precedenceRepaired)
        val trash = repository.trashedProjectsFlow.first().single()
        assertEquals(500L, trash.project.updatedAt)
        assertEquals(7_000L, trash.deletedAt)
        assertTrue(trash.deletedAtRepaired)
        assertEquals(7_000L + com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS, trash.deleteAfter)
        val record = repository.recordingRecords().single()
        assertEquals(RecordingManifestEntry.legacyRecordingId("p", "take.m4a", digest), record.id)
        assertEquals(700L, record.uploadedAt)

        // A song without an id, a zero-length recording row and a malformed ledger each fail closed.
        store.edit { it[stringPreferencesKey("projects_json")] = """[{"title":"No id"}]""" }
        assertFailsWith<CorruptLibraryException> { repository.establishPrecedence(emptyList(), 8_000L) }
        store.edit { it[stringPreferencesKey("projects_json")] = "[]" }
        store.edit {
            it[recordsKey] = """[{"id":"$recordingId","projectId":"p","displayName":"take.m4a","uploadedAt":5,"sha256":"$digest","bytes":0,"origin":"recorded"}]"""
        }
        assertFailsWith<CorruptLibraryException> { repository.recordingRecords() }
        store.edit { it[recordsKey] = "[]" }
        // T3.9: a ledger entry must name a known identity with a real time.
        store.edit { it[firstSeenKey] = """{"song:s1":0}""" }
        assertFailsWith<CorruptLibraryException> { repository.establishPrecedence(emptyList(), 8_000L) }
        store.edit { it[firstSeenKey] = """{"elsewhere:s1":5}""" }
        assertFailsWith<CorruptLibraryException> { repository.establishPrecedence(emptyList(), 8_000L) }
    }

    @Test
    fun aSongWhoseRepairedTimeLosesToATombstoneIsKeptAsideAndARealOneIsDeleted() = withRepository { store, repository ->
        // A41: "repaired" has no updatedAt (first seen at 9_000); "real" was edited at 100.
        store.edit {
            it[stringPreferencesKey("projects_json")] = """[{"id":"repaired","title":"Kept","lyrics":"words"},{"id":"real","title":"Gone","lyrics":"x","updatedAt":100}]"""
        }
        repository.establishPrecedence(emptyList(), 9_000L)
        val tombstones = listOf(SyncDeletion("repaired", deletedAt = 200L), SyncDeletion("real", deletedAt = 200L))

        repository.applySyncResult(SyncBlob(deletions = tombstones), repository.snapshotLocalSyncBase())

        assertTrue(repository.projectsFlow.first().isEmpty())
        val kept = repository.recoveredSongs().single()
        assertEquals("repaired", kept.project.id)
        assertEquals("words", kept.project.lyrics)
        assertEquals(200L, kept.deletedAt)
        assertEquals(false, kept.wasInTrash)
    }

    @Test
    fun aRemoteSongDeletionTombstonesItsPathlessHistoricalRecordings() = withRepository { store, repository ->
        // Review 18 finding 2: a row from the first record store (no path) is still covered.
        repository.saveProjects(listOf(SongProject(id = "p", title = "Song", updatedAt = 100L)))
        store.edit {
            it[recordsKey] = """[{"id":"$recordingId","projectId":"p","displayName":"take.m4a","uploadedAt":150,"sha256":"$digest","bytes":4,"origin":"recorded"}]"""
        }

        repository.applySyncResult(SyncBlob(deletions = listOf(SyncDeletion("p", deletedAt = 500L))), repository.snapshotLocalSyncBase())

        assertTrue(repository.syncDeletions().any { it.recordingId == recordingId && it.deletedAt == 500L })
    }
    @Test
    fun expiryResolvesEveryVersionOfASongBeforeItWritesATombstone() = withRepository { _, repository ->
        // iOS final review item 1: a newer, unexpired Trash copy, or an active copy, of the same id
        // must not lose to the tombstone an older expired copy would write.
        val now = 100L * com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
        val expired = TrashedSongProject(SongProject(id = "s", title = "Old", updatedAt = 1L), deletedAt = 1L)
        val newer = TrashedSongProject(SongProject(id = "s", title = "Newer", updatedAt = now - 5L), deletedAt = now - 5L)
        repository.saveTrashedProjects(listOf(expired, newer))

        assertTrue(repository.purgeExpiredTrashedProjects(now).purgedIds.isEmpty())
        assertTrue(repository.syncDeletions().isEmpty())
        assertEquals(2, repository.trashedProjectsFlow.first().size)

        repository.saveTrashedProjects(listOf(expired))
        repository.saveProjects(listOf(SongProject(id = "s", title = "Live", updatedAt = now - 5L)))
        assertTrue(repository.purgeExpiredTrashedProjects(now).purgedIds.isEmpty())
        assertTrue(repository.syncDeletions().isEmpty())
        assertEquals("Live", repository.projectsFlow.first().single().title)

        // With no other version, the expired copy does expire.
        repository.saveProjects(emptyList())
        assertEquals(listOf("s"), repository.purgeExpiredTrashedProjects(now).purgedIds)
        assertTrue(repository.syncDeletions().any { it.projectId == "s" && it.isSongTombstone })
    }
    @Test
    fun expiryWeighsEveryActiveCopyOfAnIdNotTheFirstRow() = withRepository { _, repository ->
        // iOS second pass item 1: two active rows of one id (a merge or import gone wrong); the first
        // is older than the expired Trash copy, the second newer. Neither may be purged by it.
        val now = 100L * com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
        repository.saveProjects(listOf(SongProject(id = "s", title = "Older", updatedAt = 1L), SongProject(id = "s", title = "Newer", updatedAt = now - 5L)))
        repository.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "s", title = "Bin", updatedAt = 2L), deletedAt = 3L)))

        assertTrue(repository.purgeExpiredTrashedProjects(now).purgedIds.isEmpty())

        assertTrue(repository.syncDeletions().isEmpty())
        assertEquals(listOf("Older", "Newer"), repository.projectsFlow.first().map { it.title })
    }
    @Test
    fun anExpiredDatedTrashCopyNeverDeletesRepairedActiveCopiesOfItsId() = withRepository { _, repository ->
        // iOS third pass item 1: a dated (real-time) Trash copy would win over repaired active
        // copies by precedence. Android never expires an id that has any active row, so no
        // tombstone is written, nothing is set aside and nothing of those copies is deleted.
        val now = 100L * com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
        repository.saveProjects(listOf(
            SongProject(id = "s", title = "First", lyrics = "repaired lyrics one", updatedAt = 2L, precedenceRepaired = true),
            SongProject(id = "s", title = "Second", lyrics = "repaired lyrics two", updatedAt = 3L, precedenceRepaired = true)
        ))
        repository.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "s", title = "Bin", lyrics = "dated", updatedAt = 4L), deletedAt = 5L)))

        val purge = repository.purgeExpiredTrashedProjects(now)

        assertTrue(purge.purgedIds.isEmpty())
        assertTrue(repository.syncDeletions().isEmpty())
        assertTrue(repository.recoveredSongs().isEmpty())
        assertEquals(listOf("repaired lyrics one", "repaired lyrics two"), repository.projectsFlow.first().map { it.lyrics })
        assertTrue(repository.pendingRecordingDeletionIds().isEmpty())
    }

    @Test
    fun consumingALegacyMarkPreservesTheFullTicketFromTheSameStoredMap() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-mixed-marks").toFile()
        val file = File(directory, "prefs.preferences_pb")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val store = PreferenceDataStoreFactory.create(scope = scope) { file }
            val repository = ProjectRepository(store, testKeyStore())
            val legacy = PreservationTicket("legacy-copy", token = "")
            val full = PreservationTicket("full-copy", token = "full-token")
            val a = repository.heldSong("a", legacy)
            repository.heldSong("b", full)
            store.edit {
                it[stringPreferencesKey("preserved_songs_json")] =
                    """{"a":"legacy-copy","b":{"copyId":"full-copy","token":"full-token"}}"""
            }
            assertEquals(legacy, repository.preservedTicket("a"))
            assertEquals(full, repository.preservedTicket("b"))

            repository.replace(a)
            val kept = repository.projectsFlow.first().single { it.id == "legacy-copy" }
            assertEquals("a old", kept.lyrics)
            assertEquals(HoldResult.Adopted(kept, appended = true), repository.resolveHold("a", legacy))
            assertNull(repository.preservedTicket("a"))

            scope.coroutineContext[Job]!!.cancelAndJoin()
            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopenedStore = PreferenceDataStoreFactory.create(scope = reopenedScope) { file }
                val reopened = ProjectRepository(reopenedStore, testKeyStore())
                assertNull(reopened.preservedTicket("a"))
                assertEquals(full, reopened.preservedTicket("b"), "The unconsumed full ticket must survive the rewrite")
            } finally {
                reopenedScope.coroutineContext[Job]!!.cancelAndJoin()
            }
        } finally {
            scope.coroutineContext[Job]!!.cancelAndJoin()
            directory.deleteRecursively()
        }
    }
}
