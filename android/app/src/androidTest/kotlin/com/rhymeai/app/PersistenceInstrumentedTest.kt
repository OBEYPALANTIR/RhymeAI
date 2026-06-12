package com.rhymeai.app

import android.app.Application
import android.os.SystemClock
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.repository.ProjectRepository
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

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

    private fun resetRepository() {
        runBlocking {
            repo.saveProjects(emptyList())
            repo.saveTrashedProjects(emptyList())
            repo.setCurrentProjectId(null)
            repo.saveEditorState("", "", "")
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
