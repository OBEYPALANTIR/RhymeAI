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
import com.rhymeai.app.data.model.RewriteAction
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
    // Restored in stop() even when an assertion fails part way.
    private val originalProvider = runBlocking { repo.selectedProviderFlow.first() }
    private val originalModelId = runBlocking { repo.modelIdFlow.first() }
    /** Songs, active or in Trash, stored before the test; null if that could not be read, and then nothing is deleted. */
    private var songIdsBefore: Set<String>? = null
    /** Songs this test is known to have created; teardown permanently deletes only these (when not in the baseline). */
    private val createdSongIds = mutableSetOf<String>()

    private fun storedSongIds(): Set<String> = runBlocking {
        repo.projectsFlow.first().map { it.id }.toSet() + repo.trashedProjectsFlow.first().map { it.project.id }
    }

    private fun isNewSong(id: String) = songIdsBefore?.contains(id) == false
    /** A title no other song can have, so a fixture lookup can only match the song this run saved. */
    private fun runTitle(base: String) = "$base ${java.util.UUID.randomUUID()}"
    /** Waits for the song this test saved and records it as owned; the wait and the lookup use one predicate. */
    private fun awaitSavedFixture(title: String, lyrics: String): SongProject {
        fun find() = runBlocking { repo.projectsFlow.first().firstOrNull { isNewSong(it.id) && it.title == title && it.lyrics == lyrics } }
        waitUntil { find() != null }
        return find()!!.also { createdSongIds += it.id }
    }

    @Before fun start() {
        songIdsBefore = storedSongIds()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
        waitUntil { vm.appearanceLoaded }
        composeRule.onNodeWithText("New Song", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.waitForIdle()
    }

    @After fun stop() {
        // A failure here is reported after the provider and model are restored; JUnit keeps the test's own failure too.
        val problems = mutableListOf<String>()
        try {
            if (::vm.isInitialized) {
                onMain { vm.showSongNotebook = false; vm.dismissSettings() }
                // Leaving the editor saves the open draft now, so closing the activity creates no song later.
                // The save's own callback is the proof it landed, and the draft has its id by then.
                val flushed = java.util.concurrent.atomic.AtomicBoolean(false)
                onMain { vm.goToStartMenu { vm.currentProjectId?.let { createdSongIds += it }; flushed.set(true) } }
                if (!settle { flushed.get() }) problems += "the open draft was not saved before teardown"
            }
            scenario?.close()
            val before = songIdsBefore
            if (before == null) {
                problems += "the songs stored before the test were never read, so no song was deleted"
            } else {
                val owned = createdSongIds - before
                runBlocking {
                    owned.forEach { id ->
                        val now = System.currentTimeMillis()
                        repo.moveProjectToTrash(id, now)
                        repo.permanentlyDeleteTrashedProject(id, now)
                    }
                }
                val stored = storedSongIds()
                (stored intersect owned).takeIf { it.isNotEmpty() }?.let { problems += "songs this test created are still stored: $it" }
                (stored - before - owned).takeIf { it.isNotEmpty() }?.let { problems += "unexpected new songs were left in place: $it" }
            }
        } finally {
            runCatching { runBlocking { repo.saveSelectedProvider(originalProvider) } }
                .onFailure { problems += "the provider was not restored: $it" }
            runCatching { runBlocking { repo.saveModelId(originalModelId) } }
                .onFailure { problems += "the model choice was not restored: $it" }
        }
        if (problems.isNotEmpty()) fail("Teardown: ${problems.joinToString("; ")}")
    }

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

    @OptIn(ExperimentalTestApi::class)
    @Test fun openingTheNotebookKeepsTheSelectionForKeepSelectedLyrics() {
        onMain { vm.onLyricsChanged(TextFieldValue("first lyric\nsecond lyric")) }
        // Select in the focused field, as a touch does, so opening the notebook takes focus away from it.
        val editor = composeRule.onNodeWithTag("lyricsEditor")
        editor.performClick()
        editor.performTextInputSelection(TextRange(0, 11))
        waitUntil { vm.pendingRewriteRange == TextRange(0, 11) }
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithText("Song Notebook").performClick()
        composeRule.onNodeWithText("Keep selected lyrics").assertIsEnabled().performClick()
        onMain { assertEquals(listOf("first lyric"), vm.songWorkspace.alternates.map { it.text }) }
        onMain {
            vm.onLyricsChanged(TextFieldValue("first lyric\nsecond lyric", TextRange(0, 11)))
            vm.onLyricsChanged(TextFieldValue("first lyric\nsecond lyric", TextRange(15)))
            assertNull("A cursor away from the selection's ends clears it", vm.pendingRewriteRange)
        }
    }

    @OptIn(ExperimentalTestApi::class)
    @Test fun movingTheCursorOntoTheSelectionEndInTheFocusedFieldClearsIt() {
        onMain { vm.onLyricsChanged(TextFieldValue("first lyric\nsecond lyric")) }
        val editor = composeRule.onNodeWithTag("lyricsEditor")
        editor.performClick()
        editor.performTextInputSelection(TextRange(0, 11))
        waitUntil { vm.pendingRewriteRange == TextRange(0, 11) }
        editor.performTextInputSelection(TextRange(11))
        waitUntil { vm.lyricsFieldValue.selection == TextRange(11) }
        onMain { assertNull(vm.pendingRewriteRange) }
    }

    @Test fun blankSelectionGetsNoRangeWhenTheNotebookTakesFocus() {
        val lyrics = "first lyric\n  \nsecond lyric"
        onMain {
            vm.onLyricsChanged(TextFieldValue(lyrics))
            vm.onLyricsChanged(TextFieldValue(lyrics, TextRange(12, 14)))
            vm.showSongNotebook = true
            vm.onLyricsChanged(TextFieldValue(lyrics, TextRange(14)))
            assertNull(vm.pendingRewriteRange)
            vm.showSongNotebook = false
        }
    }

    @Test fun reopenedSongKeepsItsRestoredSelectionWhenFocusLeaves() {
        val lyrics = "first lyric\nsecond lyric"
        val title = runTitle("Restored Selection QA")
        onMain {
            vm.onTitleChanged(title)
            vm.onLyricsChanged(TextFieldValue(lyrics, TextRange(0, 11)))
            vm.rememberEditorPosition()
            vm.newProject()
        }
        val saved = awaitSavedFixture(title, lyrics)
        waitUntil { !vm.savingBeforeNavigation }
        onMain { vm.loadProject(saved) }
        waitUntil { vm.currentProjectId == saved.id && !vm.openingSong && !vm.savingBeforeNavigation }
        onMain {
            assertEquals(TextRange(0, 11), vm.lyricsFieldValue.selection)
            assertNull(vm.pendingRewriteRange)
            // Opening the notebook takes focus, which collapses the cursor onto the selection's end.
            vm.showSongNotebook = true
            vm.onLyricsChanged(TextFieldValue(lyrics, TextRange(11)))
            assertEquals(TextRange(0, 11), vm.pendingRewriteRange)
            vm.keepSelectedLyrics()
            assertEquals(listOf("first lyric"), vm.songWorkspace.alternates.map { it.text })
            vm.moveProjectToTrash(saved.id)
        }
        waitUntil { vm.trashedProjects.any { it.project.id == saved.id } && !vm.savingBeforeNavigation }
        onMain { vm.permanentlyDeleteTrashedProject(saved.id) }
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

    @Test fun rewriteWithoutLocalModelOffersSetupInsteadOfRetry() {
        onMain {
            vm.onLyricsChanged(TextFieldValue("A quiet line", TextRange(0, 7)))
            vm.saveProvider(AIProvider.LOCAL)
            vm.unloadLocalModel()
            vm.localModelError = null
            vm.localModelLoading = false
        }
        // The unload finishes off the main thread; the rewrite must see no model ready.
        waitUntil { vm.selectedProvider == AIProvider.LOCAL && !vm.localReady && !vm.localModelLoading }
        onMain { vm.requestRewrite(RewriteAction.REPHRASE) }
        val bar = hasAnyAncestor(hasTestTag("inlineRewriteReviewBar"))
        composeRule.onNode(hasText(REWRITE_NEEDS_MODEL) and bar).assertIsDisplayed()
        composeRule.onNode(hasText("Cancel") and bar).assertIsDisplayed()
        composeRule.onAllNodes(hasText("Retry") and bar).assertCountEquals(0)
        composeRule.onNode(hasText("Set up model") and bar).assertIsDisplayed().performClick()
        composeRule.onNodeWithContentDescription("Close").assertIsDisplayed()
        onMain { assertTrue(vm.showSettingsDialog && vm.settingsOpensAiSetup) }
    }

    @OptIn(ExperimentalTestApi::class)
    @Test fun setUpModelClosesTheRewriteBarAndKeepsSelectionAndLyrics() {
        onMain {
            vm.onLyricsChanged(TextFieldValue("A quiet line"))
            vm.saveProvider(AIProvider.LOCAL)
            vm.unloadLocalModel()
            vm.localModelError = null
            vm.localModelLoading = false
        }
        waitUntil { vm.selectedProvider == AIProvider.LOCAL && !vm.localReady && !vm.localModelLoading }
        // Select in the focused field, as a touch does, so opening AI setup takes focus away from it.
        val editor = composeRule.onNodeWithTag("lyricsEditor")
        editor.performClick()
        editor.performTextInputSelection(TextRange(0, 7))
        waitUntil { vm.pendingRewriteRange == TextRange(0, 7) }
        onMain { vm.requestRewrite(RewriteAction.REPHRASE) }
        val bar = hasAnyAncestor(hasTestTag("inlineRewriteReviewBar"))
        composeRule.onNode(hasText("Set up model") and bar).performClick()
        composeRule.onNodeWithContentDescription("Close").assertIsDisplayed()
        onMain { assertFalse(vm.hasActiveRewrite); assertTrue(vm.settingsOpensAiSetup) }
        // Back out of AI setup without choosing a model.
        androidx.test.espresso.Espresso.pressBack()
        waitUntil { !vm.showSettingsDialog }
        composeRule.onAllNodesWithTag("inlineRewriteReviewBar").assertCountEquals(0)
        composeRule.onNodeWithTag("rewriteChipBar").assertIsDisplayed()
        onMain {
            assertEquals("A quiet line", vm.lyrics)
            assertEquals(TextRange(0, 7), vm.pendingRewriteRange)
        }
    }

    @OptIn(ExperimentalTestApi::class)
    @Test fun applyingAISettingsFromSetUpModelKeepsSelectionAndLyrics() {
        onMain {
            vm.onLyricsChanged(TextFieldValue("A quiet line"))
            vm.saveProvider(AIProvider.LOCAL)
            vm.unloadLocalModel()
            vm.localModelError = null
            vm.localModelLoading = false
        }
        waitUntil { vm.selectedProvider == AIProvider.LOCAL && !vm.localReady && !vm.localModelLoading }
        val editor = composeRule.onNodeWithTag("lyricsEditor")
        editor.performClick()
        editor.performTextInputSelection(TextRange(0, 7))
        waitUntil { vm.pendingRewriteRange == TextRange(0, 7) }
        onMain { vm.requestRewrite(RewriteAction.REPHRASE) }
        composeRule.onNode(hasText("Set up model") and hasAnyAncestor(hasTestTag("inlineRewriteReviewBar"))).performClick()
        composeRule.onNodeWithContentDescription("Close").assertIsDisplayed()
        // Apply stops in-flight AI work; it must not drop the selection the writer came to rewrite.
        val choicesBefore = vm.modelChoiceRevision
        composeRule.onNodeWithTag("applyAISettings").performScrollTo().performClick()
        waitUntil { vm.modelChoiceRevision > choicesBefore }
        composeRule.waitUntil(8_000) {
            composeRule.onAllNodes(hasTestTag("applyAISettings") and isEnabled()).fetchSemanticsNodes().isNotEmpty()
        }
        androidx.test.espresso.Espresso.pressBack()
        waitUntil { !vm.showSettingsDialog }
        composeRule.onNodeWithTag("rewriteChipBar").assertIsDisplayed()
        onMain {
            assertEquals("A quiet line", vm.lyrics)
            assertEquals(TextRange(0, 7), vm.pendingRewriteRange)
        }
    }

    @OptIn(ExperimentalTestApi::class)
    @Test fun modelChangeAfterLeavingSetUpModelKeepsSelectionAndLyrics() {
        onMain {
            vm.onLyricsChanged(TextFieldValue("A quiet line"))
            vm.saveProvider(AIProvider.LOCAL)
            vm.unloadLocalModel()
            vm.localModelError = null
            vm.localModelLoading = false
        }
        waitUntil { vm.selectedProvider == AIProvider.LOCAL && !vm.localReady && !vm.localModelLoading }
        val editor = composeRule.onNodeWithTag("lyricsEditor")
        editor.performClick()
        editor.performTextInputSelection(TextRange(0, 7))
        waitUntil { vm.pendingRewriteRange == TextRange(0, 7) }
        onMain { vm.requestRewrite(RewriteAction.REPHRASE) }
        composeRule.onNode(hasText("Set up model") and hasAnyAncestor(hasTestTag("inlineRewriteReviewBar"))).performClick()
        composeRule.onNodeWithContentDescription("Close").assertIsDisplayed()
        androidx.test.espresso.Espresso.pressBack()
        waitUntil { !vm.showSettingsDialog }
        // A model change landing after AI setup closed (as a finished download does) goes through the same step.
        onMain { vm.unloadLocalModel() }
        waitUntil { !vm.localModelLoading }
        composeRule.onNodeWithTag("rewriteChipBar").assertIsDisplayed()
        onMain {
            assertEquals("A quiet line", vm.lyrics)
            assertEquals(TextRange(0, 7), vm.pendingRewriteRange)
        }
    }

    @OptIn(ExperimentalTestApi::class)
    @Test fun goingToTheBackgroundKeepsSelectionAndLyrics() {
        onMain { vm.onLyricsChanged(TextFieldValue("A quiet line")) }
        val editor = composeRule.onNodeWithTag("lyricsEditor")
        editor.performClick()
        editor.performTextInputSelection(TextRange(0, 7))
        waitUntil { vm.pendingRewriteRange == TextRange(0, 7) }
        // Stopping the activity (a file picker on top, or Home) cancels AI work through onBackground.
        scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
        onMain {
            assertEquals("A quiet line", vm.lyrics)
            assertEquals(TextRange(0, 7), vm.pendingRewriteRange)
        }
        scenario!!.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
        composeRule.onNodeWithTag("rewriteChipBar").assertIsDisplayed()
        onMain {
            assertEquals("A quiet line", vm.lyrics)
            assertEquals(TextRange(0, 7), vm.pendingRewriteRange)
        }
    }

    @Test fun immediateSwitchPersistsLatestTextPositionAndMetadataThroughTrashRestore() {
        val lyrics = "🎵 first\n" + (1..80).joinToString("\n") { "lyric line $it" }
        val title = runTitle("Position QA")
        onMain {
            vm.onTitleChanged(title)
            vm.onLyricsChanged(TextFieldValue(lyrics, TextRange(2, 8)))
            vm.keepAlternate("an alternate")
            vm.rememberEditorPosition(140f)
            vm.newProject()
        }
        val saved = awaitSavedFixture(title, lyrics)
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
        if (!settle(condition)) fail("Writing companion state did not settle; error: ${vm.persistenceError}")
    }
    /** Cleanup's wait: never fails, so it cannot hide the test's own failure. */
    private fun settle(condition: () -> Boolean): Boolean {
        val until = SystemClock.uptimeMillis() + 8_000
        while (SystemClock.uptimeMillis() < until) {
            if (condition()) return true
            SystemClock.sleep(50)
        }
        return false
    }
}
