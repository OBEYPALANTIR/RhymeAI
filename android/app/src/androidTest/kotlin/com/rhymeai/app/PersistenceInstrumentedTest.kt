package com.rhymeai.app

import android.app.Application
import android.os.SystemClock
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.SavedLocalModel
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.SongCreation
import com.rhymeai.app.data.repository.dataStore
import androidx.datastore.preferences.core.edit
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.service.AIModel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class PersistenceInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val repo = ProjectRepository(app)
    /** View models built here without an Activity; [stopViewModels] ends them before the stored state is reset. */
    private val handBuilt = mutableListOf<MainViewModel>()
    private val workspacesKey = androidx.datastore.preferences.core.stringPreferencesKey("local_song_workspaces_json")
    /** The raw notebook preference as found (null when absent): each test starts without it and teardown puts it back. */
    private var foundWorkspaces: String? = null

    @Before
    fun setUp() {
        runBlocking {
            foundWorkspaces = app.dataStore.data.first()[workspacesKey]
            app.dataStore.edit { it.remove(workspacesKey) }
        }
        resetRepository()
    }

    @After
    fun tearDown() {
        // A hold a failed test never reached would stall the next test's first draft write.
        DraftSaveTestHooks.beforeWrite = null
        DraftSaveTestHooks.beforePositionSave = null
        try {
            stopViewModels(handBuilt)
        } finally {
            resetRepository()
            // After every writer stopped, also when the test failed.
            runBlocking { app.dataStore.edit { prefs -> foundWorkspaces?.let { prefs[workspacesKey] = it } ?: prefs.remove(workspacesKey) } }
        }
    }

    @Test
    fun importProjectPersistsProjectsCurrentIdAndEditorState() {
        seedEditorStateForInit()
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.title == INIT_SENTINEL_TITLE }

        val imported = SongProject(
            id = "source-project-id",
            title = "",
            lyrics = "  imported first line\nimported second line",
            theme = "clear signal",
            updatedAt = 100L
        )

        onMain {
            viewModel.importProject(imported)
        }

        waitUntil {
            runBlocking {
                // Editor state is the last of the three autosave writes; waiting on
                // it too keeps this from racing the project/current-id emissions.
                repo.projectsFlow.first().any { it.lyrics == imported.lyrics } &&
                    repo.currentProjectIdFlow.first() != null &&
                    repo.editorStateFlow().first().second == imported.lyrics
            }
        }

        val savedProject = runBlocking { repo.projectsFlow.first().single() }
        val savedCurrentId = runBlocking { repo.currentProjectIdFlow.first() }
        val savedEditorState = runBlocking { repo.editorStateFlow().first() }

        assertNotEquals(imported.id, savedProject.id)
        assertEquals("Imported Song", savedProject.title)
        assertEquals(imported.lyrics, savedProject.lyrics)
        assertEquals(imported.theme, savedProject.theme)
        assertEquals(savedProject.id, savedCurrentId)
        assertEquals(Triple(savedProject.title, savedProject.lyrics, savedProject.theme), savedEditorState)

        val restoredViewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil {
            restoredViewModel.currentProjectId == savedProject.id &&
                restoredViewModel.title == savedProject.title &&
                restoredViewModel.lyrics == savedProject.lyrics &&
                restoredViewModel.theme == savedProject.theme
        }
    }

    @Test
    fun autoSaveCreatesProjectAndRestoresEditorState() {
        seedEditorStateForInit()
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.title == INIT_SENTINEL_TITLE }

        onMain {
            viewModel.onTitleChanged("Autosaved Draft")
            viewModel.onLyricsChanged(TextFieldValue("first line\nsecond line", TextRange(22)))
            viewModel.onThemeChanged("late-night resolve")
        }

        waitUntil {
            runBlocking {
                // Editor state is the last of the three autosave writes; waiting on
                // it too keeps this from racing the project/current-id emissions.
                repo.projectsFlow.first().any { it.title == "Autosaved Draft" } &&
                    repo.currentProjectIdFlow.first() != null &&
                    repo.editorStateFlow().first().first == "Autosaved Draft"
            }
        }

        val savedProject = runBlocking { repo.projectsFlow.first().single() }
        val savedCurrentId = runBlocking { repo.currentProjectIdFlow.first() }
        val savedEditorState = runBlocking { repo.editorStateFlow().first() }

        assertEquals(savedProject.id, savedCurrentId)
        assertEquals("Autosaved Draft", savedProject.title)
        assertEquals("first line\nsecond line", savedProject.lyrics)
        assertEquals("late-night resolve", savedProject.theme)
        assertEquals(Triple(savedProject.title, savedProject.lyrics, savedProject.theme), savedEditorState)

        val restoredViewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil {
            restoredViewModel.currentProjectId == savedProject.id &&
                restoredViewModel.title == savedProject.title &&
                restoredViewModel.lyrics == savedProject.lyrics &&
                restoredViewModel.theme == savedProject.theme
        }
    }

    @Test
    fun remoteTrashWhileOpenSavesDraftUnderNewIdentityBeforeNavigation() {
        val original = SongProject("remote-trashed", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        onMain {
            viewModel.showStartMenu = false
            viewModel.lyricsFieldValue = TextFieldValue("local unsaved lyric")
        }
        runBlocking { repo.moveProjectToTrash(original.id, System.currentTimeMillis()) }
        waitUntil { viewModel.projects.none { it.id == original.id } }
        val navigated = java.util.concurrent.atomic.AtomicBoolean()
        onMain { viewModel.newProject { navigated.set(true) } }
        waitUntil { navigated.get() }

        val replacement = runBlocking { repo.projectsFlow.first().single() }
        assertNotEquals(original.id, replacement.id)
        assertEquals("local unsaved lyric", replacement.lyrics)
        assertEquals(original.id, runBlocking { repo.trashedProjectsFlow.first().single().project.id })
        assertEquals("", viewModel.lyrics)
        assertTrue(viewModel.persistenceError.orEmpty().contains("saved as a new song"))
    }

    @Test
    fun remoteTrashWhileOpenAutosavesNextEditUnderNewIdentity() {
        val original = SongProject("remote-autosave", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        onMain {
            viewModel.showStartMenu = false
            viewModel.lyricsFieldValue = TextFieldValue("edited after remote trash")
        }
        runBlocking { repo.moveProjectToTrash(original.id, System.currentTimeMillis()) }
        waitUntil { viewModel.projects.none { it.id == original.id } }
        onMain { viewModel.triggerAutoSave() }
        waitUntil {
            runBlocking {
                repo.projectsFlow.first().any { it.id != original.id && it.lyrics == "edited after remote trash" }
            }
        }

        val replacement = runBlocking { repo.projectsFlow.first().single() }
        assertNotEquals(original.id, replacement.id)
        assertEquals(replacement.id, viewModel.currentProjectId)
        assertEquals(replacement.id, runBlocking { repo.currentProjectIdFlow.first() })
        assertEquals("edited after remote trash", runBlocking { repo.editorStateFlow().first().second })
        assertEquals(original.id, runBlocking { repo.trashedProjectsFlow.first().single().project.id })
        assertTrue(viewModel.persistenceError.orEmpty().contains("saved as a new song"))
    }

    @Test
    fun remoteTrashDuringSaveKeepsFailureAndRetrySavesDraftUnderNewIdentity() {
        val original = SongProject("remote-race", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        val trashed = CompletableDeferred<Unit>()
        onMain {
            viewModel.showStartMenu = false
            viewModel.lyricsFieldValue = TextFieldValue("edited during the race")
            DraftSaveTestHooks.beforeWrite = trashed
            viewModel.flushCurrentDraft()
        }
        // Trashed elsewhere while the save is held before its write: the view model still had the row, the write finds it gone.
        waitUntil { DraftSaveTestHooks.beforeWrite == null }
        runBlocking { repo.moveProjectToTrash(original.id, System.currentTimeMillis()) }
        trashed.complete(Unit)
        waitUntil { viewModel.saveStatus == SaveStatus.FAILED && !viewModel.savingBeforeNavigation }
        assertEquals(null, viewModel.currentProjectId)
        assertTrue(viewModel.persistenceError.orEmpty().contains("no deleted song was restored"))

        onMain {
            viewModel.persistenceError = null
            viewModel.retrySave()
            assertEquals(SaveStatus.SAVING, viewModel.saveStatus)
        }
        waitUntil { viewModel.saveStatus == SaveStatus.SAVED }

        val replacement = runBlocking { repo.projectsFlow.first().single() }
        assertNotEquals(original.id, replacement.id)
        assertEquals("edited during the race", replacement.lyrics)
        assertEquals(replacement.id, viewModel.currentProjectId)
        assertEquals(original.id, runBlocking { repo.trashedProjectsFlow.first().single().project.id })
    }

    @Test
    fun remoteTrashDuringSaveOfUneditedSongLeavesNoFailure() {
        val original = SongProject("remote-race-unedited", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        val trashed = CompletableDeferred<Unit>()
        onMain {
            viewModel.showStartMenu = false
            DraftSaveTestHooks.beforeWrite = trashed
            viewModel.flushCurrentDraft()
        }
        // Trashed elsewhere while the save is held before its write: the view model still had the row, the write finds it gone.
        waitUntil { DraftSaveTestHooks.beforeWrite == null }
        runBlocking { repo.moveProjectToTrash(original.id, System.currentTimeMillis()) }
        trashed.complete(Unit)
        waitUntil { viewModel.currentProjectId == null && !viewModel.savingBeforeNavigation }
        SystemClock.sleep(300)
        assertEquals(SaveStatus.IDLE, viewModel.saveStatus)
        assertTrue(runBlocking { repo.projectsFlow.first() }.isEmpty())
    }

    @Test
    fun retryOfAFailedEraseStoresTheEmptySong() {
        val original = SongProject("erase-retry", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        try {
            onMain {
                viewModel.showStartMenu = false
                viewModel.title = ""
                viewModel.lyricsFieldValue = TextFieldValue("")
                viewModel.theme = ""
                DraftSaveTestHooks.failNext.set(true)
                viewModel.flushCurrentDraft()
            }
            waitUntil { viewModel.saveStatus == SaveStatus.FAILED && !viewModel.savingBeforeNavigation }

            // An ordinary autosave never stores the erase, and the failure stays.
            onMain { viewModel.triggerAutoSave() }
            SystemClock.sleep(1_000)
            instrumentation.waitForIdleSync()
            assertEquals(original.lyrics, runBlocking { repo.projectsFlow.first().single() }.lyrics)
            assertEquals(SaveStatus.FAILED, viewModel.saveStatus)

            onMain { viewModel.retrySave() }
            waitUntil { viewModel.saveStatus == SaveStatus.SAVED }
            val stored = runBlocking { repo.projectsFlow.first().single() }
            assertEquals(original.id, stored.id)
            assertEquals(Triple("Untitled Song", "", ""), Triple(stored.title, stored.lyrics, stored.theme))
        } finally {
            DraftSaveTestHooks.failNext.set(false)
        }
    }

    @Test
    fun aFailureDuringTheSavedBeatKeepsTheRetry() {
        val original = SongProject("saved-beat", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        val beat = CompletableDeferred<Unit>()
        try {
            onMain {
                viewModel.showStartMenu = false
                viewModel.lyricsFieldValue = TextFieldValue("autosaved words")
                DraftSaveTestHooks.afterAutosaveCommit = beat
                viewModel.triggerAutoSave()
            }
            // The autosave has committed and is held before its beat ends in SAVED.
            waitUntil { DraftSaveTestHooks.afterAutosaveCommit == null }
            assertEquals(SaveStatus.SAVING, viewModel.saveStatus)
            DraftSaveTestHooks.failNext.set(true)
            val recording = runCatching { runBlocking(Dispatchers.Main) { viewModel.ensureProjectForRecording() } }
            assertTrue(recording.isFailure)
            assertEquals(SaveStatus.FAILED, viewModel.saveStatus)

            beat.complete(Unit)
            SystemClock.sleep(1_000)
            instrumentation.waitForIdleSync()
            assertEquals(SaveStatus.FAILED, viewModel.saveStatus)
        } finally {
            DraftSaveTestHooks.afterAutosaveCommit = null
            DraftSaveTestHooks.failNext.set(false)
        }
    }

    @Test
    fun anOlderWriteFailingAfterANewerCommitLeavesNoFailure() {
        val original = SongProject("older-write", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        val olderWrite = CompletableDeferred<Unit>()
        try {
            onMain {
                viewModel.showStartMenu = false
                viewModel.lyricsFieldValue = TextFieldValue("words kept")
                DraftSaveTestHooks.beforeWrite = olderWrite
                viewModel.flushCurrentDraft()
            }
            waitUntil { DraftSaveTestHooks.beforeWrite == null }
            onMain { viewModel.triggerAutoSave() }
            waitUntil { viewModel.saveStatus == SaveStatus.SAVED }

            DraftSaveTestHooks.failNext.set(true)
            olderWrite.complete(Unit)
            waitUntil { !viewModel.savingBeforeNavigation }
            SystemClock.sleep(300)
            instrumentation.waitForIdleSync()
            assertEquals(SaveStatus.SAVED, viewModel.saveStatus)
            assertEquals(null, viewModel.persistenceError)
            assertEquals("words kept", runBlocking { repo.projectsFlow.first().single() }.lyrics)
        } finally {
            DraftSaveTestHooks.beforeWrite = null
            DraftSaveTestHooks.failNext.set(false)
        }
    }

    @Test
    fun aNewerCommitDuringAFailedWritesRereadLeavesNoFailure() {
        val original = SongProject("held-reread", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        val reread = CompletableDeferred<Unit>()
        try {
            onMain {
                viewModel.showStartMenu = false
                viewModel.lyricsFieldValue = TextFieldValue("words kept")
                DraftSaveTestHooks.failNext.set(true)
                DraftSaveTestHooks.beforeReread = reread
                viewModel.flushCurrentDraft()
            }
            waitUntil { DraftSaveTestHooks.beforeReread == null }
            onMain { viewModel.triggerAutoSave() }
            waitUntil { viewModel.saveStatus == SaveStatus.SAVED }

            reread.complete(Unit)
            waitUntil { !viewModel.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            assertEquals(SaveStatus.SAVED, viewModel.saveStatus)
            assertEquals(null, viewModel.persistenceError)
            assertEquals("words kept", runBlocking { repo.projectsFlow.first().single() }.lyrics)
        } finally {
            DraftSaveTestHooks.beforeReread = null
            DraftSaveTestHooks.failNext.set(false)
        }
    }

    @Test
    fun wordsTypedWhileAMissingSongsRereadIsHeldAreSavedAsANewSong() {
        val original = SongProject("held-missing", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        val trashed = CompletableDeferred<Unit>()
        val reread = CompletableDeferred<Unit>()
        try {
            onMain {
                viewModel.showStartMenu = false
                DraftSaveTestHooks.beforeWrite = trashed
                DraftSaveTestHooks.beforeReread = reread
                viewModel.flushCurrentDraft()
            }
            // Trashed elsewhere while the save is held before its write: the view model still had the row, the write finds it gone.
            waitUntil { DraftSaveTestHooks.beforeWrite == null }
            runBlocking { repo.moveProjectToTrash(original.id, System.currentTimeMillis()) }
            trashed.complete(Unit)
            waitUntil { DraftSaveTestHooks.beforeReread == null }
            onMain {
                viewModel.lyricsFieldValue = TextFieldValue("typed during the reread")
                viewModel.triggerAutoSave()
            }
            reread.complete(Unit)

            waitUntil {
                runBlocking { repo.projectsFlow.first() }.any { it.id != original.id && it.lyrics == "typed during the reread" }
            }
            assertEquals(original.id, runBlocking { repo.trashedProjectsFlow.first().single().project.id })
            assertNotEquals(original.id, viewModel.currentProjectId)
        } finally {
            DraftSaveTestHooks.beforeReread = null
        }
    }

    @Test
    fun anOlderWriteFindingTheRowGoneAfterANewerCommitKeepsTheDraftAttached() {
        val original = SongProject("older-missing", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        val olderWrite = CompletableDeferred<Unit>()
        try {
            onMain {
                viewModel.showStartMenu = false
                viewModel.lyricsFieldValue = TextFieldValue("words kept")
                DraftSaveTestHooks.beforeWrite = olderWrite
                viewModel.flushCurrentDraft()
            }
            waitUntil { DraftSaveTestHooks.beforeWrite == null }
            onMain { viewModel.triggerAutoSave() }
            waitUntil { viewModel.saveStatus == SaveStatus.SAVED }

            // The row goes after the newer commit, so the held older write finds it missing.
            runBlocking { repo.moveProjectToTrash(original.id, System.currentTimeMillis()) }
            olderWrite.complete(Unit)
            waitUntil { !viewModel.savingBeforeNavigation }
            instrumentation.waitForIdleSync()
            assertEquals(original.id, viewModel.currentProjectId)
            assertEquals(null, viewModel.persistenceError)
            assertEquals(SaveStatus.SAVED, viewModel.saveStatus)
            assertEquals("words kept", runBlocking { repo.trashedProjectsFlow.first().single().project.lyrics })
        } finally {
            DraftSaveTestHooks.beforeWrite = null
        }
    }

    @Test
    fun aRereadFailureAfterAFailedSaveStillMarksTheDraft() {
        val original = SongProject("reread-fails", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        try {
            onMain {
                viewModel.showStartMenu = false
                viewModel.lyricsFieldValue = TextFieldValue("unsaved words")
                DraftSaveTestHooks.failNext.set(true)
                DraftSaveTestHooks.failNextReread.set(true)
                viewModel.flushCurrentDraft()
            }
            waitUntil { !viewModel.savingBeforeNavigation }
            assertTrue("the reread ran and failed", !DraftSaveTestHooks.failNextReread.get())
            assertEquals(SaveStatus.FAILED, viewModel.saveStatus)
            assertTrue(viewModel.persistenceError.orEmpty().contains("could not be saved"))
        } finally {
            DraftSaveTestHooks.failNext.set(false)
            DraftSaveTestHooks.failNextReread.set(false)
        }
    }


    @Test
    fun aRelaunchRightAfterARestoreCommitShowsTheCommittedWords() {
        val original = SongProject("changed-under-editor", "Original", "old lyric", "old theme", 100L)
        runBlocking {
            repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme)
            // The process ends after this commit, before any editor reloads.
            repo.applySyncResult(
                com.rhymeai.app.data.sync.SyncBlob(projects = listOf(original.copy(lyrics = "restored lyric", updatedAt = 200L))),
                repo.snapshotLocalSyncBase()
            )
        }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized }
        assertEquals(original.id to "restored lyric", viewModel.currentProjectId to viewModel.lyrics)
    }

    @Test
    fun aRelaunchRightAfterARestoreTrashedTheSongShowsAnEmptyEditor() {
        val original = SongProject("trashed-under-editor", "Original", "old lyric", "old theme", 100L)
        runBlocking {
            repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme)
            repo.applySyncResult(
                com.rhymeai.app.data.sync.SyncBlob(trashed = listOf(com.rhymeai.app.data.model.TrashedSongProject(original, 200L))),
                repo.snapshotLocalSyncBase()
            )
        }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized }
        assertEquals(Triple<String?, String, String>(null, "", ""), Triple(viewModel.currentProjectId, viewModel.title, viewModel.lyrics))
    }

    @Test
    fun startupStillShowsEditorWordsSavedApartFromTheSong() {
        val original = SongProject("legacy-editor-words", "Original", "stored lyric", "", 100L)
        runBlocking {
            repo.saveActiveState(original, SongCreation(), original.title, original.lyrics, original.theme)
            repo.saveEditorState(original.title, "draft words saved apart", original.theme)
        }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized }
        assertEquals(original.id to "draft words saved apart", viewModel.currentProjectId to viewModel.lyrics)
    }

    @Test
    fun startupKeepsTheBlankTitleOfAnUnchangedSong() {
        val untitled = SongProject("blank-title", "Untitled Song", "some words", "", 100L)
        runBlocking { repo.saveActiveState(untitled, SongCreation(), "", untitled.lyrics, "") }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized }
        assertEquals(Triple<String?, String, String>(untitled.id, "", "some words"), Triple(viewModel.currentProjectId, viewModel.title, viewModel.lyrics))
    }

    @Test
    fun customLocalModelRegistrationAndSelectionSurviveRepositoryRecreation() = runBlocking {
        val model = SavedLocalModel(
            id = "custom-night-drive",
            displayName = "Night Drive",
            fileName = "custom-night-drive.gguf",
            isCustom = true
        )

        repo.saveLocalModels(listOf(model))
        repo.saveSelectedLocalModelId(model.id)

        val restoredRepository = ProjectRepository(app)
        assertEquals(listOf(model), restoredRepository.localModelsFlow.first())
        assertEquals(model.id, restoredRepository.selectedLocalModelIdFlow.first())
    }

    @Test
    fun selectedLocalModelIsRestoredWhenLocalProviderStarts() {
        val modelFile = app.filesDir.resolve("startup-custom.gguf")
        modelFile.writeBytes(
            ByteBuffer.allocate(24)
                .order(ByteOrder.LITTLE_ENDIAN)
                .put("GGUF".toByteArray())
                .putInt(3)
                .putLong(1)
                .putLong(1)
                .array()
        )
        val model = SavedLocalModel(
            id = "startup-custom",
            displayName = "Startup Custom",
            fileName = modelFile.name,
            isCustom = true
        )
        runBlocking {
            repo.saveSelectedProvider(AIProvider.LOCAL.name)
            repo.saveModelId(AIModel.LOCAL_MODEL.id)
            repo.saveLocalModels(listOf(model))
            repo.saveSelectedLocalModelId(model.id)
        }

        val restoredViewModel = MainViewModel(app).also(handBuilt::add)

        waitUntil { restoredViewModel.localModelPath == modelFile.absolutePath }
        modelFile.delete()
    }

    @Test
    fun moveToTrashOfASongWhoseIdAnotherSongSharesIsRefused() {
        val first = SongProject("shared-move", "Shared", "words A", "", 100L)
        runBlocking { repo.saveProjects(listOf(first, first.copy(lyrics = "words B"))) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        try {
            waitUntil { viewModel.projects.count { it.id == first.id } == 2 }
            val committed = CompletableDeferred<Boolean>()
            onMain { viewModel.moveProjectToTrash(first.id) { committed.complete(it) } }

            assertEquals(false, runBlocking { withTimeout(5_000) { committed.await() } })
            assertEquals("More than one song shares this identity, so nothing was moved to Trash.", viewModel.persistenceError)
            assertEquals(listOf("words A", "words B"), runBlocking { repo.projectsFlow.first() }.map { it.lyrics })
            assertTrue(runBlocking { repo.trashedProjectsFlow.first() }.isEmpty())
        } finally {
            stopViewModels(handBuilt)
        }
    }

    @Test
    fun sendToASongWhoseIdAnotherSongSharesIsRefusedAndTheLineStaysUnused() {
        val first = SongProject("shared-send", "Shared", "words A", "", 100L)
        runBlocking { repo.saveProjects(listOf(first, first.copy(lyrics = "words B"))) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        var seeded: com.rhymeai.app.data.model.OneLiner? = null
        var deleted = false
        try {
            val line = runBlocking { viewModel.oneLinersStore.add("a shared line") }
            seeded = line
            waitUntil { viewModel.projects.count { it.id == first.id } == 2 }
            val sent = CompletableDeferred<String>()
            onMain { viewModel.sendOneLinerToSong(line, first) { sent.complete(it) } }

            assertEquals("Two songs share this song's identity; the line was not sent.", runBlocking { withTimeout(5_000) { sent.await() } })
            assertEquals(listOf("words A", "words B"), runBlocking { repo.projectsFlow.first() }.map { it.lyrics })
            assertEquals(null, runBlocking { viewModel.oneLinersStore.all() }.single { it.id == line.id }.usedInProjectId)
        } finally {
            try {
                stopViewModels(handBuilt)
            } finally {
                // Recorded, not asserted, here: a failed cleanup must not hide the test's own failure.
                seeded?.let { line ->
                    deleted = runCatching {
                        runBlocking { viewModel.oneLinersStore.trash(line.id); viewModel.oneLinersStore.permanentlyDelete(line.id) }
                    }.getOrDefault(false)
                }
            }
        }
        assertTrue("the seeded One Liner was not deleted", deleted)
    }

    @Test
    fun legacyRestartSecondWindowImportAndTemplateUseTheRightSaveMode() {
        // A song stored before creations carried tokens, open in the editor at relaunch.
        val legacy = SongProject("legacy-song", "Legacy", "legacy words", "", 100L)
        runBlocking {
            repo.saveProjects(listOf(legacy))
            repo.saveActiveState(legacy, null, legacy.title, legacy.lyrics, legacy.theme)
        }
        fun stored() = runBlocking { repo.projectsFlow.first() }
        fun editorSaved() = runBlocking { repo.editorStateFlow().first() }
        val first = MainViewModel(app).also(handBuilt::add)
        waitUntil { first.currentProjectId == legacy.id && first.title == legacy.title }
        onMain { first.showStartMenu = false; first.onLyricsChanged(TextFieldValue("first window words")) }
        waitUntil { stored().singleOrNull()?.lyrics == "first window words" }

        // A second window opens the same song and saves it the ordinary way.
        val second = MainViewModel(app).also(handBuilt::add)
        waitUntil { second.currentProjectId == legacy.id && second.lyrics == "first window words" }
        onMain { second.showStartMenu = false; second.onLyricsChanged(TextFieldValue("second window words")) }
        waitUntil { stored().singleOrNull()?.lyrics == "second window words" }
        assertEquals(legacy.id, stored().single().id)

        // An import is a new song beside it, and its next save updates that one row.
        onMain { second.importProject(SongProject(legacy.id, "Imported", "imported words", "", 1L)) }
        waitUntil { stored().size == 2 && editorSaved().second == "imported words" }
        val imported = stored().first { it.lyrics == "imported words" }
        assertNotEquals(legacy.id, imported.id)
        assertEquals(imported.id, runBlocking { repo.currentProjectIdFlow.first() })
        onMain { second.onLyricsChanged(TextFieldValue("imported edited")) }
        waitUntil { stored().any { it.id == imported.id && it.lyrics == "imported edited" } }
        assertEquals(2, stored().size)

        // A template is another new song, saved by its first autosave, then updated in place.
        onMain { second.applyTemplate("Blues", "blue theme", "template words") }
        waitUntil { stored().size == 3 && editorSaved().second == "template words" }
        val template = stored().first { it.lyrics == "template words" }
        assertEquals(template.id, runBlocking { repo.currentProjectIdFlow.first() })
        assertEquals(Triple("Untitled Blues", "template words", "blue theme"), editorSaved())
        onMain { second.onLyricsChanged(TextFieldValue("template edited")) }
        waitUntil { stored().any { it.id == template.id && it.lyrics == "template edited" } }
        assertEquals(setOf(legacy.id, imported.id, template.id), stored().map { it.id }.toSet())
        assertEquals("second window words", stored().single { it.id == legacy.id }.lyrics)
        assertEquals(Triple("Untitled Blues", "template edited", "blue theme"), editorSaved())
    }

    @Test
    fun creationRefusalKeepsDraftAndCannotDetachLaterAttempt() {
        // Another window's new song already holds the id every new draft here draws.
        val occupant = SongProject("occupied", "Occupant", "occupant words", "", 100L)
        runBlocking {
            repo.saveActiveState(occupant, SongCreation(), occupant.title, occupant.lyrics, occupant.theme)
            repo.setCurrentProjectId(null)
            repo.saveEditorState("", "", "")
        }
        fun stored() = runBlocking { repo.projectsFlow.first() }
        fun occupantKept() = assertEquals(occupant.lyrics, stored().single { it.id == occupant.id }.lyrics)
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized && viewModel.projects.any { it.id == occupant.id } }
        val draws = SongIdAllocator.next
        val holds = List(4) { CompletableDeferred<Unit>() }
        // A recording's save of the new draft, held before it writes.
        fun heldRecording(hold: CompletableDeferred<Unit>): kotlinx.coroutines.Deferred<Result<String>> {
            DraftSaveTestHooks.beforeWrite = hold
            val recording = kotlinx.coroutines.CoroutineScope(Dispatchers.Main).async { runCatching { viewModel.ensureProjectForRecording() } }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId == occupant.id }
            return recording
        }
        fun refused(recording: kotlinx.coroutines.Deferred<Result<String>>) =
            assertTrue(runBlocking { withTimeout(5_000) { recording.await() } }.exceptionOrNull() is com.rhymeai.app.data.repository.CreationIdTakenException)
        // The refused flush does not navigate; it detaches the draft from the id.
        fun refusedFlush() {
            val navigated = java.util.concurrent.atomic.AtomicBoolean()
            onMain { viewModel.newProject { navigated.set(true) } }
            waitUntil { viewModel.currentProjectId == null && !viewModel.savingBeforeNavigation }
            assertTrue(!navigated.get())
            assertEquals("draft words", viewModel.lyrics)
        }
        try {
            SongIdAllocator.next = { occupant.id }
            onMain { viewModel.showStartMenu = false; viewModel.lyricsFieldValue = TextFieldValue("draft words") }

            // A version restore waits on the held save; its refusal ends the restore with no words changed and the notebook usable.
            val firstRecording = heldRecording(holds[0])
            onMain { viewModel.restoreDraftVersion(com.rhymeai.app.data.model.DraftVersion(title = "V", lyrics = "version words", theme = "", createdAt = 1L)) }
            assertTrue(viewModel.restoringDraft)
            holds[0].complete(Unit)
            refused(firstRecording)
            waitUntil { !viewModel.restoringDraft && viewModel.currentProjectId == null }
            assertEquals("draft words", viewModel.lyrics)
            assertEquals(null, viewModel.notebookError)

            // A later attempt draws the same id; the older recording's refusal arrives after it and must not detach it.
            val secondRecording = heldRecording(holds[1])
            refusedFlush()
            DraftSaveTestHooks.beforeWrite = holds[2]
            onMain { viewModel.triggerAutoSave(retry = true) }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId == occupant.id }
            holds[1].complete(Unit)
            refused(secondRecording)
            SystemClock.sleep(300)
            instrumentation.waitForIdleSync()
            assertEquals(occupant.id, viewModel.currentProjectId)
            holds[2].complete(Unit)
            waitUntil { viewModel.currentProjectId == null }

            // A fresh writing save keeps the words under a new id.
            SongIdAllocator.next = draws
            onMain { viewModel.triggerAutoSave(retry = true) }
            waitUntil { stored().any { it.id != occupant.id && it.lyrics == "draft words" } }
            occupantKept()

            // Nor may an old attempt's late refusal detach the occupant the user opened with nothing newer committed.
            onMain { viewModel.newProject() }
            waitUntil { viewModel.currentProjectId == null && viewModel.lyrics.isEmpty() }
            SongIdAllocator.next = { occupant.id }
            onMain { viewModel.lyricsFieldValue = TextFieldValue("draft words") }
            val thirdRecording = heldRecording(holds[3])
            refusedFlush()
            onMain { viewModel.lyricsFieldValue = TextFieldValue("") }
            onMain { viewModel.loadProject(occupant) }
            waitUntil { viewModel.currentProjectId == occupant.id && viewModel.lyrics == occupant.lyrics }
            holds[3].complete(Unit)
            refused(thirdRecording)
            SystemClock.sleep(300)
            instrumentation.waitForIdleSync()
            assertEquals(occupant.id, viewModel.currentProjectId)
            occupantKept()
            assertEquals(null, viewModel.notebookError)

            // A refused import does not run its ready callback and keeps its words for the next save.
            SongIdAllocator.next = { occupant.id }
            val ready = java.util.concurrent.atomic.AtomicBoolean()
            onMain { viewModel.importProject(SongProject("source", "Imported", "import words", "", 1L)) { ready.set(true) } }
            waitUntil { viewModel.lyrics == "import words" && viewModel.currentProjectId == null }
            SystemClock.sleep(300)
            instrumentation.waitForIdleSync()
            assertTrue(!ready.get())
            SongIdAllocator.next = draws
            onMain { viewModel.triggerAutoSave(retry = true) }
            waitUntil { stored().any { it.id != occupant.id && it.lyrics == "import words" } }
            occupantKept()

            // A version restore on a stored song another window moved to Trash restores nothing and leaves the notebook usable.
            val importedId = stored().single { it.lyrics == "import words" }.id
            waitUntil { viewModel.currentProjectId == importedId }
            runBlocking { repo.moveProjectToTrash(importedId, System.currentTimeMillis()) }
            onMain { viewModel.restoreDraftVersion(com.rhymeai.app.data.model.DraftVersion(title = "V", lyrics = "version words", theme = "", createdAt = 1L)) }
            waitUntil { !viewModel.restoringDraft }
            assertEquals("import words", viewModel.lyrics)
            assertEquals(null, viewModel.notebookError)
        } finally {
            SongIdAllocator.next = draws
            holds.forEach { it.complete(Unit) }
            DraftSaveTestHooks.beforeWrite = null
        }
    }

    @Test
    fun delayedPositionAfterAnotherWindowEditsWritesOnlyWorkspace() {
        val other = SongProject("other-song", "Other", "other words", "", 100L)
        runBlocking { repo.saveProjects(listOf(other)) }
        fun stored() = runBlocking { repo.projectsFlow.first() }
        fun storedWorkspace(id: String) = runBlocking { repo.workspacesFlow.first()[id] }
        val a = MainViewModel(app).also(handBuilt::add)
        waitUntil { a.initialized }
        val firstWrite = CompletableDeferred<Unit>()
        val position = CompletableDeferred<Unit>()
        try {
            // Window A's new song X: a cursor move is queued while X is still new, then X is stored.
            DraftSaveTestHooks.beforeWrite = firstWrite
            onMain { a.showStartMenu = false; a.onLyricsChanged(TextFieldValue("words one", TextRange(2, 5))) }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && a.currentProjectId != null }
            val x = a.currentProjectId!!
            // Held on the main thread right after the move replaces the autosave's own position save, so only this one waits.
            onMain { a.rememberEditorPosition(42f); DraftSaveTestHooks.beforePositionSave = position }
            firstWrite.complete(Unit)
            waitUntil { stored().any { it.id == x && it.lyrics == "words one" } && DraftSaveTestHooks.beforePositionSave == null }

            // Window B opens X, saves new words, then selects its other song.
            val b = MainViewModel(app).also(handBuilt::add)
            waitUntil { b.currentProjectId == x && b.lyrics == "words one" }
            onMain { b.showStartMenu = false; b.onLyricsChanged(TextFieldValue("words two")) }
            waitUntil { stored().single { it.id == x }.lyrics == "words two" }
            // B also keeps a line and a version in X's notebook; A's later position must leave them.
            onMain { b.keepAlternate("b line"); b.saveDraftVersion() }
            waitUntil { storedWorkspace(x)?.let { it.alternates.any { line -> line.text == "b line" } && it.versions.any { v -> v.lyrics == "words two" } } == true }
            onMain { b.loadProject(other) }
            waitUntil { b.currentProjectId == other.id && runBlocking { repo.currentProjectIdFlow.first() } == other.id }
            // B's own delayed position save for X (an ordinary whole-notebook write) lands first.
            SystemClock.sleep(400)
            instrumentation.waitForIdleSync()
            val notebookOfB = storedWorkspace(x)!!
            val savedByB = stored().single { it.id == x }
            val editorOfB = runBlocking { repo.editorStateFlow().first() }
            assertEquals(Triple(other.title, other.lyrics, other.theme), editorOfB)

            // A's position lands in X's notebook and nothing else.
            position.complete(Unit)
            waitUntil { storedWorkspace(x)?.scrollOffset == 42f }
            assertEquals(2 to 5, storedWorkspace(x)!!.let { it.selectionStart to it.selectionEnd })
            assertEquals(notebookOfB.alternates, storedWorkspace(x)!!.alternates)
            assertEquals(notebookOfB.versions, storedWorkspace(x)!!.versions)
            assertEquals(savedByB, stored().single { it.id == x })
            assertEquals(other.id, runBlocking { repo.currentProjectIdFlow.first() })
            assertEquals(editorOfB, runBlocking { repo.editorStateFlow().first() })
        } finally {
            firstWrite.complete(Unit)
            position.complete(Unit)
            DraftSaveTestHooks.beforeWrite = null
            DraftSaveTestHooks.beforePositionSave = null
        }
    }

    @Test
    fun notebookFirstCreationCompletesAndRefusedWorkspaceCannotReachOccupant() {
        // Another window's new song U already holds the id this window draws, with its own notebook.
        val occupant = SongProject("occupied", "Occupant", "occupant words", "", 100L)
        val seeded = com.rhymeai.app.data.model.SongWorkspace().keep("occupant alternate", 1L)
        runBlocking {
            repo.saveActiveState(occupant, SongCreation(), occupant.title, occupant.lyrics, occupant.theme)
            repo.saveWorkspace(occupant.id, seeded)
            repo.setCurrentProjectId(null)
            repo.saveEditorState("", "", "")
        }
        fun stored() = runBlocking { repo.projectsFlow.first() }
        fun storedWorkspace(id: String) = runBlocking { repo.workspacesFlow.first()[id] }
        val version = com.rhymeai.app.data.model.DraftVersion(title = "V", lyrics = "version words", theme = "", createdAt = 1L)
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized && viewModel.projects.any { it.id == occupant.id } }
        val draws = SongIdAllocator.next
        val holds = List(3) { CompletableDeferred<Unit>() }
        try {
            // Refused: the notebook-first save is held; an alternate and a version restore wait on it and end with it.
            SongIdAllocator.next = { occupant.id }
            onMain { viewModel.showStartMenu = false; viewModel.lyricsFieldValue = TextFieldValue("refused words") }
            DraftSaveTestHooks.beforeWrite = holds[0]
            onMain { viewModel.keepAlternate("refused alternate") }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId == occupant.id }
            onMain { viewModel.restoreDraftVersion(version) }
            assertTrue(viewModel.restoringDraft)
            holds[0].complete(Unit)
            waitUntil { !viewModel.restoringDraft && viewModel.currentProjectId == null }
            assertEquals("refused words", viewModel.lyrics)
            assertEquals(null, viewModel.notebookError)
            assertEquals(seeded, storedWorkspace(occupant.id))

            // Reopening U and saving its notebook again still leaves the refused alternate out.
            SongIdAllocator.next = draws
            onMain { viewModel.loadProject(occupant) }
            waitUntil { viewModel.currentProjectId == occupant.id && viewModel.lyrics == occupant.lyrics }
            onMain { viewModel.keepAlternate("occupant second") }
            waitUntil { storedWorkspace(occupant.id)!!.alternates.any { it.text == "occupant second" } }
            assertEquals(listOf("occupant second", "occupant alternate"), storedWorkspace(occupant.id)!!.alternates.map { it.text })
            assertEquals(occupant.lyrics, stored().single { it.id == occupant.id }.lyrics)

            // Stored: with a free id the held save commits one row, then the alternate and the version join its notebook.
            onMain { viewModel.newProject() }
            waitUntil { viewModel.currentProjectId == null && viewModel.lyrics.isEmpty() }
            onMain { viewModel.lyricsFieldValue = TextFieldValue("new words") }
            DraftSaveTestHooks.beforeWrite = holds[1]
            onMain { viewModel.keepAlternate("new alternate") }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            val x = viewModel.currentProjectId!!
            onMain { viewModel.saveDraftVersion() }
            assertTrue(stored().none { it.id == x } && storedWorkspace(x) == null)
            holds[1].complete(Unit)
            waitUntil { storedWorkspace(x)?.let { it.alternates.size == 1 && it.versions.size == 1 } == true }
            assertEquals("new alternate", storedWorkspace(x)!!.alternates.single().text)
            assertEquals("new words", storedWorkspace(x)!!.versions.single().lyrics)
            assertEquals(1, stored().count { it.id == x })

            // Cancelled: a held save that ends by cancellation finishes its waiting restore without writing.
            onMain { viewModel.newProject() }
            waitUntil { viewModel.currentProjectId == null && viewModel.lyrics.isEmpty() }
            onMain { viewModel.lyricsFieldValue = TextFieldValue("cancelled words") }
            DraftSaveTestHooks.beforeWrite = holds[2]
            onMain { viewModel.keepAlternate("cancelled alternate") }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            val y = viewModel.currentProjectId!!
            onMain { viewModel.restoreDraftVersion(version) }
            assertTrue(viewModel.restoringDraft)
            holds[2].completeExceptionally(kotlinx.coroutines.CancellationException("save cancelled"))
            waitUntil { !viewModel.restoringDraft }
            assertEquals("cancelled words", viewModel.lyrics)
            assertEquals(null, viewModel.notebookError)
            assertEquals(null, storedWorkspace(y))

            // The next save stores the song; the alternate that waited on the cancelled save is neither shown nor stored.
            assertEquals(emptyList<String>(), viewModel.songWorkspace.alternates.map { it.text })
            onMain { viewModel.triggerAutoSave(retry = true) }
            waitUntil { stored().any { it.id == y && it.lyrics == "cancelled words" } }
            SystemClock.sleep(300)
            assertEquals(emptyList<String>(), storedWorkspace(y)?.alternates.orEmpty().map { it.text })
            val reopened = MainViewModel(app).also(handBuilt::add)
            waitUntil { reopened.initialized && reopened.currentProjectId == y }
            assertEquals(viewModel.songWorkspace.alternates to viewModel.songWorkspace.versions, reopened.songWorkspace.alternates to reopened.songWorkspace.versions)
        } finally {
            SongIdAllocator.next = draws
            holds.forEach { it.complete(Unit) }
            DraftSaveTestHooks.beforeWrite = null
        }
    }

    @Test
    fun aNewSongsNotebookStoresTheRecordsItShowedAndTheWordsItsFlushSaved() {
        fun storedWorkspace(id: String) = runBlocking { repo.workspacesFlow.first()[id] }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized }
        val holds = List(2) { CompletableDeferred<Unit>() }
        try {
            // Kept and removed before the insert: the removal names the line the notebook showed, and the stored one.
            onMain { viewModel.showStartMenu = false; viewModel.lyricsFieldValue = TextFieldValue("kept words") }
            DraftSaveTestHooks.beforeWrite = holds[0]
            onMain { viewModel.keepAlternate("kept line") }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            val x = viewModel.currentProjectId!!
            onMain { viewModel.saveDraftVersion() }
            val shownVersion = viewModel.songWorkspace.versions.single().id
            onMain { viewModel.removeAlternate(viewModel.songWorkspace.alternates.single().id) }
            holds[0].complete(Unit)
            waitUntil { storedWorkspace(x)?.versions?.size == 1 }
            SystemClock.sleep(300)
            assertEquals(emptyList<String>(), storedWorkspace(x)!!.alternates.map { it.text })
            assertEquals(shownVersion, storedWorkspace(x)!!.versions.single().id)

            // A flush of W1 followed by W2 before its checkpoint is stored: the version holds W1, the words that flush saved.
            onMain { viewModel.newProject() }
            waitUntil { viewModel.currentProjectId == null && viewModel.lyrics.isEmpty() }
            onMain { viewModel.lyricsFieldValue = TextFieldValue("W1 words") }
            DraftSaveTestHooks.beforeWrite = holds[1]
            onMain { viewModel.flushCurrentDraft() }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            val y = viewModel.currentProjectId!!
            onMain { viewModel.lyricsFieldValue = TextFieldValue("W2 words") }
            holds[1].complete(Unit)
            waitUntil { storedWorkspace(y)?.versions?.isNotEmpty() == true }
            SystemClock.sleep(300)
            assertEquals(listOf("W1 words"), storedWorkspace(y)!!.versions.map { it.lyrics })
            assertEquals(viewModel.songWorkspace.versions.map { it.id }, storedWorkspace(y)!!.versions.map { it.id })
        } finally {
            holds.forEach { it.complete(Unit) }
            DraftSaveTestHooks.beforeWrite = null
        }
    }

    @Test
    fun anOldSongsLateSaveCannotTakeOrReviveAnotherCreationAtItsId() {
        val x = SongProject("song-x", "X", "x words", "", 100L)
        val other = SongProject("song-other", "Other", "other words", "", 100L)
        runBlocking {
            for (song in listOf(x, other)) repo.saveActiveState(song, SongCreation(), song.title, song.lyrics, song.theme)
            repo.setCurrentProjectId(null)
            repo.saveEditorState("", "", "")
        }
        fun stored() = runBlocking { repo.projectsFlow.first() }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized && viewModel.projects.size == 2 }
        val draws = SongIdAllocator.next
        val holds = List(3) { CompletableDeferred<Unit>() }
        fun heldRecording(hold: CompletableDeferred<Unit>): kotlinx.coroutines.Deferred<Result<String>> {
            DraftSaveTestHooks.beforeWrite = hold
            val recording = kotlinx.coroutines.CoroutineScope(Dispatchers.Main).async { runCatching { viewModel.ensureProjectForRecording() } }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            return recording
        }
        // An old song's recording save is held; the editor leaves it, and a new draft's creation draws the same id.
        fun heldSaveThenNewDraftAt(song: SongProject, oldHold: CompletableDeferred<Unit>, newHold: CompletableDeferred<Unit>, words: String): kotlinx.coroutines.Deferred<Result<String>> {
            SongIdAllocator.next = draws
            onMain { viewModel.loadProject(song) }
            waitUntil { viewModel.currentProjectId == song.id && viewModel.lyrics == song.lyrics }
            val recording = heldRecording(oldHold)
            onMain { viewModel.newProject() }
            waitUntil { viewModel.currentProjectId == null && viewModel.lyrics.isEmpty() && !viewModel.savingBeforeNavigation }
            SongIdAllocator.next = { song.id }
            onMain { viewModel.lyricsFieldValue = TextFieldValue(words) }
            DraftSaveTestHooks.beforeWrite = newHold
            onMain { viewModel.triggerAutoSave(retry = true) }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId == song.id }
            return recording
        }
        fun settle(recording: kotlinx.coroutines.Deferred<Result<String>>) {
            runBlocking { withTimeout(5_000) { recording.await() } }
            SystemClock.sleep(300)
            instrumentation.waitForIdleSync()
        }
        try {
            // Success: X's late save leaves the new draft's creation in place, so its next save is refused, not written over X.
            settle(heldSaveThenNewDraftAt(x, holds[0], holds[1], "new words").also { holds[0].complete(Unit) })
            onMain { viewModel.flushCurrentDraft() }
            waitUntil { !viewModel.savingBeforeNavigation }
            SystemClock.sleep(300)
            assertEquals("x words", stored().single { it.id == x.id }.lyrics)
            assertEquals(null, viewModel.currentProjectId)
            assertEquals("new words", viewModel.lyrics)
            // A pending creation across another song's Trash: pendingCreationAcrossAnUnrelatedTrash. A withdrawn
            // creation's insert: ProjectRepositoryTest.aWithdrawnCreationCannotInsert.
        } finally {
            SongIdAllocator.next = draws
            holds.forEach { it.complete(Unit) }
            DraftSaveTestHooks.beforeWrite = null
        }
    }

    /** A new song's save is parked before its write; another save of it is refused, which retires the creation. */
    @Test
    fun aRetiredCreationsParkedInsertNeverLandsOnceItsIdIsFree() {
        val id = "song-retired"
        runBlocking { repo.saveTrashedProjects(listOf(com.rhymeai.app.data.model.TrashedSongProject(SongProject(id, "Gone", "gone words", "", 100L), System.currentTimeMillis()))) }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized }
        val draws = SongIdAllocator.next
        val parked = CompletableDeferred<Unit>()
        try {
            SongIdAllocator.next = { id }
            onMain {
                viewModel.showStartMenu = false
                viewModel.lyricsFieldValue = TextFieldValue("draft words")
            }
            DraftSaveTestHooks.beforeWrite = parked
            onMain { viewModel.flushCurrentDraft() }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId == id }
            // The second save meets the trashed song at the id: refused, the creation is retired and the editor detached.
            onMain { viewModel.triggerAutoSave(retry = true) }
            waitUntil { viewModel.currentProjectId == null }
            // The id is free again before the parked save writes.
            runBlocking { repo.saveTrashedProjects(emptyList()) }
            parked.complete(Unit)
            waitUntil { !viewModel.savingBeforeNavigation }
            SystemClock.sleep(300)
            instrumentation.waitForIdleSync()
            assertEquals(emptyList<SongProject>(), runBlocking { repo.projectsFlow.first() }.filter { it.id == id })
            assertEquals(null to "draft words", viewModel.currentProjectId to viewModel.lyrics)
        } finally {
            SongIdAllocator.next = draws
            parked.complete(Unit)
            DraftSaveTestHooks.beforeWrite = null
        }
    }

    @Test
    fun aPendingSongFlushedWhileItsInsertWaitsAcrossAnUnrelatedTrashIsStoredOnce() = pendingCreationAcrossAnUnrelatedTrash(insertCommitsFirst = false)

    @Test
    fun aPendingSongWhoseInsertIsBeingWrittenAcrossAnUnrelatedTrashIsStoredOnce() = pendingCreationAcrossAnUnrelatedTrash(insertCommitsFirst = true)

    @Test
    fun aPendingSongFlushedAcrossAnUnrelatedRestoreFromTrashIsStoredOnce() = pendingCreationAcrossAnUnrelatedTrash(insertCommitsFirst = false, restore = true)

    /**
     * Another song goes to Trash while the new song X is being inserted, with a line kept on X waiting for it; the editor
     * then flushes. [insertCommitsFirst]: X's insert has passed its checks and is being written when the flush runs.
     * [restore]: another song comes back from Trash instead.
     */
    private fun pendingCreationAcrossAnUnrelatedTrash(insertCommitsFirst: Boolean, restore: Boolean = false) {
        val other = SongProject("song-other", "Other", "other words", "", 100L)
        runBlocking {
            repo.saveActiveState(other, SongCreation(), other.title, other.lyrics, other.theme)
            if (restore) {
                repo.saveProjects(emptyList())
                repo.saveTrashedProjects(listOf(com.rhymeai.app.data.model.TrashedSongProject(other, System.currentTimeMillis())))
            }
            repo.setCurrentProjectId(null)
            repo.saveEditorState("", "", "")
        }
        fun stored() = runBlocking { repo.projectsFlow.first() }
        fun storedWorkspace(id: String) = runBlocking { repo.workspacesFlow.first()[id] }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized && (if (restore) viewModel.trashedProjects.any { it.project.id == other.id } else viewModel.projects.any { it.id == other.id }) }
        val insert = CompletableDeferred<Unit>()
        val learned = CompletableDeferred<Unit>()
        try {
            onMain { viewModel.showStartMenu = false; viewModel.lyricsFieldValue = TextFieldValue("pending words") }
            DraftSaveTestHooks.beforeWrite = insert
            val recording = kotlinx.coroutines.CoroutineScope(Dispatchers.Main).async { runCatching { viewModel.ensureProjectForRecording() } }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            val x = viewModel.currentProjectId!!
            onMain { viewModel.keepAlternate("queued line") }
            if (restore) {
                onMain { viewModel.restoreTrashedProject(other.id) }
                waitUntil { stored().any { it.id == other.id } && viewModel.projects.any { it.id == other.id } }
            } else {
                onMain { viewModel.moveProjectToTrash(other.id) }
                waitUntil { stored().none { it.id == other.id } && viewModel.projects.none { it.id == other.id } }
            }
            if (insertCommitsFirst) {
                // X's insert passes its checks, then waits inside its write while the flush below runs.
                val reached = CompletableDeferred<Unit>()
                com.rhymeai.app.data.repository.RepositoryTestHooks.afterInsertCheck = { reached.complete(Unit); learned.await() }
                insert.complete(Unit)
                runBlocking { withTimeout(5_000) { reached.await() } }
            }
            onMain { viewModel.flushCurrentDraft() }
            // The flush's own write waits for X's to finish.
            learned.complete(Unit)
            waitUntil { !viewModel.savingBeforeNavigation }
            insert.complete(Unit)
            runBlocking { withTimeout(5_000) { recording.await() } }
            SystemClock.sleep(500)
            instrumentation.waitForIdleSync()
            // One song holds the draft, at the id its creation drew, with the line that waited on it.
            assertEquals(listOf(x), stored().filter { it.lyrics == "pending words" }.map { it.id })
            assertEquals(listOf("queued line"), storedWorkspace(x)?.alternates.orEmpty().map { it.text })
            assertEquals(x, viewModel.currentProjectId)
        } finally {
            insert.complete(Unit)
            learned.complete(Unit)
            DraftSaveTestHooks.beforeWrite = null
            com.rhymeai.app.data.repository.RepositoryTestHooks.afterInsertCheck = null
        }
    }

    @Test
    fun aRefusedNotebookTokenDetachesTheEditorSoItsNextSaveCannotReachTheReplacement() {
        fun stored() = runBlocking { repo.projectsFlow.first() }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized }
        val holds = List(2) { CompletableDeferred<Unit>() }
        try {
            // A position is queued while the new song X is pending; its creation then commits.
            onMain { viewModel.showStartMenu = false; viewModel.lyricsFieldValue = TextFieldValue("a words") }
            DraftSaveTestHooks.beforeWrite = holds[0]
            onMain { viewModel.triggerAutoSave(retry = true) }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            val x = viewModel.currentProjectId!!
            DraftSaveTestHooks.beforePositionSave = holds[1]
            onMain { viewModel.rememberEditorPosition() }
            holds[0].complete(Unit)
            waitUntil { stored().any { it.id == x } && DraftSaveTestHooks.beforePositionSave == null }

            // Another window replaces the library: X is now a different song.
            runBlocking { repo.saveProjects(listOf(SongProject(x, "Incoming", "incoming words", "", 200L))) }
            holds[1].complete(Unit)
            SystemClock.sleep(500)
            instrumentation.waitForIdleSync()

            // The editor's next save keeps its words as a new song; the replacement keeps its own.
            onMain { viewModel.lyricsFieldValue = TextFieldValue("a words edited") }
            onMain { viewModel.flushCurrentDraft() }
            waitUntil { !viewModel.savingBeforeNavigation }
            SystemClock.sleep(300)
            assertEquals("incoming words", stored().single { it.id == x }.lyrics)
            waitUntil { stored().any { it.id != x && it.lyrics == "a words edited" } }
            assertEquals("a words edited", viewModel.lyrics)
        } finally {
            holds.forEach { it.complete(Unit) }
            DraftSaveTestHooks.beforeWrite = null
            DraftSaveTestHooks.beforePositionSave = null
        }
    }

    @Test
    fun aPendingVersionRestoreKeepsAnotherWindowsNotebookEntries() {
        fun storedWorkspace(id: String) = runBlocking { repo.workspacesFlow.first()[id] }
        val version = com.rhymeai.app.data.model.DraftVersion(title = "V", lyrics = "version words", theme = "", createdAt = 1L)
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized }
        val insert = CompletableDeferred<Unit>()
        val position = CompletableDeferred<Unit>()
        try {
            // A restore is asked for while the new song X is still being inserted.
            onMain { viewModel.showStartMenu = false; viewModel.lyricsFieldValue = TextFieldValue("a words") }
            DraftSaveTestHooks.beforeWrite = insert
            onMain { viewModel.keepAlternate("a line") }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            val x = viewModel.currentProjectId!!
            onMain { viewModel.restoreDraftVersion(version) }
            assertTrue(viewModel.restoringDraft)
            // Once X is stored, another window keeps a line and a version in its notebook before A's changes are written.
            val bWritten = CompletableDeferred<Unit>()
            val first = java.util.concurrent.atomic.AtomicBoolean(true)
            DraftSaveTestHooks.beforeCreationNotebookWrite = {
                if (first.compareAndSet(true, false)) {
                    val current = repo.workspacesFlow.first()[x] ?: com.rhymeai.app.data.model.SongWorkspace()
                    repo.saveWorkspace(x, current.keep("b line", 2L).checkpoint("B", "b version words", "", 2L, force = true))
                    bWritten.complete(Unit)
                } else {
                    // The restore's checkpoint follows A's earlier keep, as the queue orders them without this hook.
                    bWritten.await()
                    while (repo.workspacesFlow.first()[x]?.alternates?.any { it.text == "a line" } != true) kotlinx.coroutines.delay(20)
                }
            }
            DraftSaveTestHooks.beforePositionSave = position
            insert.complete(Unit)
            waitUntil { !viewModel.restoringDraft && viewModel.lyrics == "version words" }
            assertTrue(viewModel.songWorkspace.alternates.any { it.text == "b line" })
            assertTrue(viewModel.songWorkspace.versions.any { it.lyrics == "b version words" })

            // The restore's own position write, and the autosave of the restored words, keep B's entries.
            waitUntil { DraftSaveTestHooks.beforePositionSave == null }
            position.complete(Unit)
            SystemClock.sleep(1_000)
            instrumentation.waitForIdleSync()
            val notebook = storedWorkspace(x)!!
            assertEquals(listOf("a line", "b line"), notebook.alternates.map { it.text }.sorted())
            assertTrue(notebook.versions.map { it.lyrics }.toString(), notebook.versions.any { it.lyrics == "b version words" })
            assertTrue(notebook.versions.map { it.lyrics }.toString(), notebook.versions.any { it.lyrics == "a words" })
        } finally {
            insert.complete(Unit)
            position.complete(Unit)
            DraftSaveTestHooks.beforeWrite = null
            DraftSaveTestHooks.beforePositionSave = null
            DraftSaveTestHooks.beforeCreationNotebookWrite = null
        }
    }

    @Test
    fun aRefusedTokenKeepsAnEditAlreadyWaitingToAutosave() {
        fun stored() = runBlocking { repo.projectsFlow.first() }
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized }
        val holds = List(2) { CompletableDeferred<Unit>() }
        try {
            onMain { viewModel.showStartMenu = false; viewModel.lyricsFieldValue = TextFieldValue("a words") }
            DraftSaveTestHooks.beforeWrite = holds[0]
            onMain { viewModel.triggerAutoSave(retry = true) }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            val x = viewModel.currentProjectId!!
            DraftSaveTestHooks.beforePositionSave = holds[1]
            onMain { viewModel.rememberEditorPosition() }
            holds[0].complete(Unit)
            waitUntil { stored().any { it.id == x } && DraftSaveTestHooks.beforePositionSave == null }
            runBlocking { repo.saveProjects(listOf(SongProject(x, "Incoming", "incoming words", "", 200L))) }

            // The writer types while the obsolete position is still held: that edit's autosave is armed for X.
            onMain { viewModel.onLyricsChanged(TextFieldValue("a words typed")) }
            holds[1].complete(Unit)
            // No further edit and no flush: the typed words reach storage as a new song, and X keeps its own words.
            waitUntil { stored().any { it.id != x && it.lyrics == "a words typed" } }
            assertEquals("incoming words", stored().single { it.id == x }.lyrics)
            assertEquals("a words typed", viewModel.lyrics)
        } finally {
            holds.forEach { it.complete(Unit) }
            DraftSaveTestHooks.beforeWrite = null
            DraftSaveTestHooks.beforePositionSave = null
        }
    }

    @Test
    fun aNotebookChangeWhoseSongWasNotSavedIsNotShownAsKept() {
        fun storedWorkspace(id: String) = runBlocking { repo.workspacesFlow.first()[id] }
        val notSaved = "A Song Notebook change was not saved"
        val viewModel = MainViewModel(app).also(handBuilt::add)
        waitUntil { viewModel.initialized }
        val holds = List(3) { CompletableDeferred<Unit>() }
        try {
            // The new song's save fails: lines kept while it was writing leave the notebook, and the writer is told.
            onMain { viewModel.showStartMenu = false; viewModel.lyricsFieldValue = TextFieldValue("fail words") }
            DraftSaveTestHooks.beforeWrite = holds[0]
            onMain { viewModel.keepAlternate("first line") }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            val x = viewModel.currentProjectId!!
            onMain { viewModel.keepAlternate("second line") }
            DraftSaveTestHooks.failNext.set(true)
            holds[0].complete(Unit)
            waitUntil { viewModel.persistenceError?.contains(notSaved) == true }
            assertEquals(emptyList<String>(), viewModel.songWorkspace.alternates.map { it.text })
            // A line kept after the failure and before Retry waits on the failed save too.
            onMain { viewModel.keepAlternate("between line") }
            SystemClock.sleep(300)
            instrumentation.waitForIdleSync()
            assertEquals(emptyList<String>(), viewModel.songWorkspace.alternates.map { it.text })

            // Retry stores the song; a line kept while it writes is shown and stored, and the dropped ones stay out.
            DraftSaveTestHooks.beforeWrite = holds[1]
            onMain { viewModel.retrySave() }
            waitUntil { DraftSaveTestHooks.beforeWrite == null }
            onMain { viewModel.keepAlternate("third line") }
            holds[1].complete(Unit)
            waitUntil { storedWorkspace(x)?.alternates?.isNotEmpty() == true }
            SystemClock.sleep(300)
            assertEquals(listOf("third line"), storedWorkspace(x)!!.alternates.map { it.text })
            assertEquals(listOf("third line"), viewModel.songWorkspace.alternates.map { it.text })
            val reopened = MainViewModel(app).also(handBuilt::add)
            waitUntil { reopened.initialized && reopened.currentProjectId == x }
            assertEquals(listOf("third line"), reopened.songWorkspace.alternates.map { it.text })

            // An autosave cancelled by a flush of the same new song does not fail the flush's checkpoint.
            onMain { viewModel.newProject() }
            waitUntil { viewModel.currentProjectId == null && viewModel.lyrics.isEmpty() && !viewModel.savingBeforeNavigation }
            onMain { viewModel.lyricsFieldValue = TextFieldValue("flush words") }
            DraftSaveTestHooks.beforeWrite = holds[2]
            onMain { viewModel.triggerAutoSave(retry = true) }
            waitUntil { DraftSaveTestHooks.beforeWrite == null && viewModel.currentProjectId != null }
            val y = viewModel.currentProjectId!!
            onMain { viewModel.flushCurrentDraft() }
            waitUntil { !viewModel.savingBeforeNavigation }
            SystemClock.sleep(300)
            assertEquals(listOf("flush words"), storedWorkspace(y)?.versions?.map { it.lyrics })
            assertEquals(storedWorkspace(y)!!.versions.map { it.id }, viewModel.songWorkspace.versions.map { it.id })
        } finally {
            holds.forEach { it.complete(Unit) }
            DraftSaveTestHooks.beforeWrite = null
            DraftSaveTestHooks.failNext.set(false)
        }
    }

    private fun resetRepository() {
        runBlocking {
            repo.saveProjects(emptyList())
            repo.saveTrashedProjects(emptyList())
            repo.setCurrentProjectId(null)
            repo.saveEditorState("", "", "")
            repo.saveSelectedProvider(AIProvider.LOCAL.name)
            repo.saveModelId(AIModel.DEFAULT.id)
            repo.saveLocalModels(emptyList())
            repo.saveSelectedLocalModelId(null)
        }
    }

    private fun seedEditorStateForInit() {
        runBlocking {
            repo.saveEditorState(INIT_SENTINEL_TITLE, "", "")
        }
    }

    private fun onMain(block: () -> Unit) {
        instrumentation.runOnMainSync(block)
        instrumentation.waitForIdleSync()
    }

    private fun waitUntil(timeoutMillis: Long = 5_000, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + timeoutMillis
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.waitForIdleSync()
            if (condition()) return
            SystemClock.sleep(50)
        }
        fail("Condition was not met within ${timeoutMillis}ms")
    }

    private companion object {
        const val INIT_SENTINEL_TITLE = "Init Sentinel"
    }
}
