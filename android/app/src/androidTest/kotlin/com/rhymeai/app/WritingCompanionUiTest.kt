package com.rhymeai.app

import android.app.Application
import android.os.SystemClock
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.service.AIProvider
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.*
import org.junit.Assert.*

class WritingCompanionUiTest {
    @get:Rule val composeRule = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val repo = ProjectRepository(app)
    private lateinit var vm: MainViewModel

    @Before fun start() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
        // The launch finishes loading (and shows the start menu) before the test acts, so the
        // start menu cannot reappear over the song the test opens.
        waitUntil { vm.appearanceLoaded && vm.aiSettingsLoaded }
        composeRule.onNodeWithText("New Song", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.waitForIdle()
    }

    @After fun stop() { scenario?.close() }

    @Test fun keepSelectionDoesNotEditAndVersionRestorePreservesCurrentDraft() {
        onMain {
            vm.onTitleChanged("Notebook QA")
            vm.onLyricsChanged(TextFieldValue("first lyric\nsecond lyric", TextRange(0, 11)))
        }
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithText("Keep selection").performClick()
        composeRule.onNodeWithText("first lyric", substring = false).assertExists()
        onMain { assertEquals("first lyric\nsecond lyric", vm.lyrics); assertEquals(1, vm.songWorkspace.alternates.size) }
        composeRule.onNodeWithText("Draft History").performClick()
        composeRule.onNodeWithText("Save version").performClick()
        composeRule.onNodeWithText("Close").performClick()
        onMain { vm.onLyricsChanged(TextFieldValue("a different draft")) }
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithText("Song Notebook").performClick()
        composeRule.onNodeWithText("Draft History").performClick()
        composeRule.onAllNodesWithText("Preview version").onFirst().performClick()
        composeRule.onNodeWithText("Restore version").performClick()
        waitUntil { vm.lyrics == "first lyric\nsecond lyric" }
        onMain {
            assertEquals("first lyric\nsecond lyric", vm.lyrics)
            assertTrue(vm.songWorkspace.versions.any { it.lyrics == "a different draft" })
        }
    }

    @Test fun localUnavailableDisablesSuggestionsAndLinksToSetup() {
        onMain {
            vm.onLyricsChanged(TextFieldValue("A quiet line"))
            vm.saveProvider(AIProvider.LOCAL)
            vm.unloadLocalModel()
            vm.localModelError = null
            vm.localModelLoading = false
        }
        composeRule.onNodeWithTag("unBlockAction").performClick()
        composeRule.onNodeWithText("Local AI · Choose a model").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("assistantPrimaryAction")
            .assertTextEquals("Set up model")
            .assertIsEnabled()
            .performClick()
        composeRule.onNodeWithContentDescription("Close").assertIsDisplayed()
    }

    @Test fun immediateSwitchPersistsLatestTextPositionAndMetadataThroughTrashRestore() {
        val lyrics = "🎵 first\n" + (1..80).joinToString("\n") { "lyric line $it" }
        onMain {
            vm.onTitleChanged("Position QA")
            vm.onLyricsChanged(TextFieldValue(lyrics, TextRange(2, 8)))
            vm.keepAlternate("an alternate")
            vm.rememberEditorPosition(140f)
            vm.newProject()
        }
        waitUntil { runBlocking { repo.projectsFlow.first().any { it.title == "Position QA" && it.lyrics == lyrics } } }
        val saved = runBlocking { repo.projectsFlow.first().first { it.title == "Position QA" } }
        waitUntil { !vm.savingBeforeNavigation }
        onMain { vm.loadProject(saved) }
        waitUntil { vm.currentProjectId == saved.id && !vm.savingBeforeNavigation }
        onMain {
            assertEquals(lyrics, vm.lyrics)
            assertEquals(TextRange(2, 8), vm.lyricsFieldValue.selection)
            assertEquals(140f, vm.editorScrollOffset)
            assertEquals("an alternate", vm.songWorkspace.alternates.single().text)
            vm.moveProjectToTrash(saved.id)
        }
        waitUntil { runBlocking { repo.trashedProjectsFlow.first().any { it.project.id == saved.id } } }
        onMain { vm.restoreTrashedProject(saved.id) }
        waitUntil { runBlocking { repo.projectsFlow.first().any { it.id == saved.id } } }
        waitUntil { !vm.savingBeforeNavigation }
        onMain { vm.loadProject(vm.projects.first { it.id == saved.id }) }
        waitUntil { vm.currentProjectId == saved.id && !vm.savingBeforeNavigation }
        assertEquals("an alternate", vm.songWorkspace.alternates.single().text)
        waitUntil { runBlocking { repo.workspacesFlow.first()[saved.id]?.alternates?.size == 1 } }
        val persisted = runBlocking { ProjectRepository(app).workspacesFlow.first().getValue(saved.id) }
        assertEquals(2, persisted.selectionStart)
        assertEquals(8, persisted.selectionEnd)
        onMain { vm.moveProjectToTrash(saved.id) }
        waitUntil { vm.trashedProjects.any { it.project.id == saved.id } && !vm.savingBeforeNavigation }
        onMain { vm.permanentlyDeleteTrashedProject(saved.id) }
        waitUntil { runBlocking { saved.id !in repo.workspacesFlow.first() } }
    }

    private fun onMain(block: () -> Unit) { instrumentation.runOnMainSync(block); instrumentation.waitForIdleSync() }
    private fun waitUntil(condition: () -> Boolean) {
        val until = SystemClock.uptimeMillis() + 8_000
        while (SystemClock.uptimeMillis() < until) {
            if (condition()) return
            SystemClock.sleep(50)
        }
        fail("Writing companion state did not settle; error: ${vm.persistenceError}")
    }
}
