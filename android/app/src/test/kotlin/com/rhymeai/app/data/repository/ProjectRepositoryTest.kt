package com.rhymeai.app.data.repository

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
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
                assertEquals("recoverable recording", File(retained, "keep.m4a").readText())
                assertEquals("unsaved draft recording", File(untracked, "unsaved.m4a").readText())
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
            assertEquals("restore me", recording.readText())
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
            val restoredAudio = RecordingFiles.memoFile(restored, song.id, "take.m4a")
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
            assertEquals("Earlier", RecordingFiles.memoFile(filesDir, earlier.id, "take.m4a").readText())
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
            repository.saveProjects(listOf(SongProject(id = id, title = "Delete")))
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
            repository.saveProjects(listOf(SongProject(id = id, title = "Delete")))
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
        val songs = listOf(SongProject(id = "expired-a"), SongProject(id = "expired-b"))
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
            repository.saveActiveState(created, true, created.title, created.lyrics, created.theme)
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
                val stale = SyncBlob(
                    projects = listOf(song.copy(updatedAt = Long.MAX_VALUE)),
                    trashed = listOf(TrashedSongProject(song, 20L)),
                    recordings = listOf(syncedRecording(song.id))
                )
                val merged = SyncMerger.merge(base.blob, stale)
                assertEquals(emptyList(), merged.projects)
                assertEquals(emptyList(), merged.trashed)
                assertEquals(emptyList(), merged.recordings)
                assertEquals(base.blob.deletions, merged.deletions)
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
                    projects = expired.map { it.copy(updatedAt = Long.MAX_VALUE) },
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
                val stalePeer = SyncBlob(version = 1, projects = listOf(song.copy(updatedAt = Long.MAX_VALUE)))
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
                repository.recordRecordingDeletion("song-1", "../escape.m4a", 50L)
            }
            repository.recordRecordingDeletion("song-1", recording.fileName, 50L)

            val base = repository.snapshotLocalSyncBase()
            assertEquals(listOf(SyncDeletion("song-1", recording.fileName, 50L)), base.blob.deletions)

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
            val other = recording.copy(fileName = "other.m4a", driveName = RecordingManifestEntry.driveNameFor("song-1", "other.m4a"))
            assertEquals(listOf(other), SyncMerger.merge(base.blob, SyncBlob(recordings = listOf(other))).recordings)
        } finally {
            scope.cancel()
            directory.deleteRecursively()
        }
    }

    @Test
    fun remoteProjectTombstoneRemovesPostSnapshotLocalSongAndRestorePlan() = runBlocking {
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
            repository.saveActiveState(song, true, song.title, song.lyrics, song.theme)
            assertEquals(listOf(song.id), repository.projectsFlow.first().map { it.id })
            val merged = SyncMerger.merge(
                base.blob,
                SyncBlob(
                    recordings = listOf(recording),
                    deletions = listOf(SyncDeletion(song.id, deletedAt = 1L))
                )
            )
            assertEquals(emptyList(), merged.recordings)
            assertEquals(emptyList(), RecordingSyncPlanner.planRestores(
                local = emptyList(),
                remoteManifest = merged.recordings,
                remoteFilesByName = mapOf(recording.driveName to "uploaded-byte-id")
            ))
            repository.applySyncResult(merged, base)
            assertEquals(emptyList(), repository.projectsFlow.first())
            firstScope.coroutineContext[Job]!!.cancelAndJoin()

            val reopenedScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            try {
                val reopened = ProjectRepository(
                    PreferenceDataStoreFactory.create(scope = reopenedScope) { file }, testKeyStore()
                )
                assertEquals(emptyList(), reopened.projectsFlow.first())
                assertEquals(listOf(SyncDeletion(song.id, deletedAt = 1L)),
                    reopened.snapshotLocalSyncBase().blob.deletions)
            } finally {
                reopenedScope.cancel()
            }
        } finally {
            firstScope.cancel()
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
        projectId = id, fileName = "take.m4a", sizeBytes = 3L, modifiedAt = 500L, sha256 = "synthetic"
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

    private fun testKeyStore(): SecureKeyStore = object : SecureKeyStore {
        override fun getKey(provider: String) = ""
        override fun setKey(provider: String, key: String) = Unit
        override fun allKeys(): Map<String, String> = emptyMap()
        override fun clear() = Unit
    }
}
