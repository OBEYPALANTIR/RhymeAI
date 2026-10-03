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
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
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
