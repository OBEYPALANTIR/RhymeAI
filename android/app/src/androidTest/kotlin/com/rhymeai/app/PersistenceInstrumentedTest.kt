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
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.service.AIModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
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

    @Before
    fun setUp() {
        resetRepository()
    }

    @After
    fun tearDown() {
        resetRepository()
    }

    @Test
    fun importProjectPersistsProjectsCurrentIdAndEditorState() {
        seedEditorStateForInit()
        val viewModel = MainViewModel(app)
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

        val restoredViewModel = MainViewModel(app)
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
        val viewModel = MainViewModel(app)
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

        val restoredViewModel = MainViewModel(app)
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
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
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
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
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
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        onMain {
            viewModel.showStartMenu = false
            viewModel.lyricsFieldValue = TextFieldValue("edited during the race")
            // Trashed elsewhere before the view model hears of it: the save finds its row gone.
            runBlocking { repo.moveProjectToTrash(original.id, System.currentTimeMillis()) }
            viewModel.flushCurrentDraft()
        }
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
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        onMain {
            viewModel.showStartMenu = false
            runBlocking { repo.moveProjectToTrash(original.id, System.currentTimeMillis()) }
            viewModel.flushCurrentDraft()
        }
        waitUntil { viewModel.currentProjectId == null && !viewModel.savingBeforeNavigation }
        SystemClock.sleep(300)
        assertEquals(SaveStatus.IDLE, viewModel.saveStatus)
        assertTrue(runBlocking { repo.projectsFlow.first() }.isEmpty())
    }

    @Test
    fun retryOfAFailedEraseStoresTheEmptySong() {
        val original = SongProject("erase-retry", "Original", "old lyric", "old theme", 100L)
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
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
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
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
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
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
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
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
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
        waitUntil { viewModel.currentProjectId == original.id && viewModel.title == original.title }

        val reread = CompletableDeferred<Unit>()
        try {
            onMain {
                viewModel.showStartMenu = false
                // Trashed elsewhere before the view model hears of it; the flush of the unedited song finds its row gone.
                runBlocking { repo.moveProjectToTrash(original.id, System.currentTimeMillis()) }
                DraftSaveTestHooks.beforeReread = reread
                viewModel.flushCurrentDraft()
            }
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
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
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
        runBlocking { repo.saveActiveState(original, true, original.title, original.lyrics, original.theme) }
        val viewModel = MainViewModel(app)
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
            repo.saveActiveState(original, true, original.title, original.lyrics, original.theme)
            // The process ends after this commit, before any editor reloads.
            repo.applySyncResult(
                com.rhymeai.app.data.sync.SyncBlob(projects = listOf(original.copy(lyrics = "restored lyric", updatedAt = 200L))),
                repo.snapshotLocalSyncBase()
            )
        }
        val viewModel = MainViewModel(app)
        waitUntil { viewModel.initialized }
        assertEquals(original.id to "restored lyric", viewModel.currentProjectId to viewModel.lyrics)
    }

    @Test
    fun aRelaunchRightAfterARestoreTrashedTheSongShowsAnEmptyEditor() {
        val original = SongProject("trashed-under-editor", "Original", "old lyric", "old theme", 100L)
        runBlocking {
            repo.saveActiveState(original, true, original.title, original.lyrics, original.theme)
            repo.applySyncResult(
                com.rhymeai.app.data.sync.SyncBlob(trashed = listOf(com.rhymeai.app.data.model.TrashedSongProject(original, 200L))),
                repo.snapshotLocalSyncBase()
            )
        }
        val viewModel = MainViewModel(app)
        waitUntil { viewModel.initialized }
        assertEquals(Triple<String?, String, String>(null, "", ""), Triple(viewModel.currentProjectId, viewModel.title, viewModel.lyrics))
    }

    @Test
    fun startupStillShowsEditorWordsSavedApartFromTheSong() {
        val original = SongProject("legacy-editor-words", "Original", "stored lyric", "", 100L)
        runBlocking {
            repo.saveActiveState(original, true, original.title, original.lyrics, original.theme)
            repo.saveEditorState(original.title, "draft words saved apart", original.theme)
        }
        val viewModel = MainViewModel(app)
        waitUntil { viewModel.initialized }
        assertEquals(original.id to "draft words saved apart", viewModel.currentProjectId to viewModel.lyrics)
    }

    @Test
    fun startupKeepsTheBlankTitleOfAnUnchangedSong() {
        val untitled = SongProject("blank-title", "Untitled Song", "some words", "", 100L)
        runBlocking { repo.saveActiveState(untitled, true, "", untitled.lyrics, "") }
        val viewModel = MainViewModel(app)
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

        val restoredViewModel = MainViewModel(app)

        waitUntil { restoredViewModel.localModelPath == modelFile.absolutePath }
        modelFile.delete()
    }

    @Test
    fun moveToTrashOfASongWhoseIdAnotherSongSharesIsRefused() {
        val first = SongProject("shared-move", "Shared", "words A", "", 100L)
        runBlocking { repo.saveProjects(listOf(first, first.copy(lyrics = "words B"))) }
        val viewModel = MainViewModel(app)
        try {
            waitUntil { viewModel.projects.count { it.id == first.id } == 2 }
            val committed = CompletableDeferred<Boolean>()
            onMain { viewModel.moveProjectToTrash(first.id) { committed.complete(it) } }

            assertEquals(false, runBlocking { withTimeout(5_000) { committed.await() } })
            assertEquals("More than one song shares this identity, so nothing was moved to Trash.", viewModel.persistenceError)
            assertEquals(listOf("words A", "words B"), runBlocking { repo.projectsFlow.first() }.map { it.lyrics })
            assertTrue(runBlocking { repo.trashedProjectsFlow.first() }.isEmpty())
        } finally {
            runBlocking { withTimeout(10_000) { viewModel.viewModelScope.coroutineContext[Job]!!.cancelAndJoin() } }
        }
    }

    @Test
    fun sendToASongWhoseIdAnotherSongSharesIsRefusedAndTheLineStaysUnused() {
        val first = SongProject("shared-send", "Shared", "words A", "", 100L)
        runBlocking { repo.saveProjects(listOf(first, first.copy(lyrics = "words B"))) }
        val viewModel = MainViewModel(app)
        val line = runBlocking { viewModel.oneLinersStore.add("a shared line") }
        try {
            waitUntil { viewModel.projects.count { it.id == first.id } == 2 }
            val sent = CompletableDeferred<String>()
            onMain { viewModel.sendOneLinerToSong(line, first) { sent.complete(it) } }

            assertEquals("Two songs share this song's identity; the line was not sent.", runBlocking { withTimeout(5_000) { sent.await() } })
            assertEquals(listOf("words A", "words B"), runBlocking { repo.projectsFlow.first() }.map { it.lyrics })
            assertEquals(null, runBlocking { viewModel.oneLinersStore.all() }.single { it.id == line.id }.usedInProjectId)
        } finally {
            try {
                runBlocking { withTimeout(10_000) { viewModel.viewModelScope.coroutineContext[Job]!!.cancelAndJoin() } }
            } finally {
                runBlocking { viewModel.oneLinersStore.permanentlyDelete(line.id) }
            }
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
