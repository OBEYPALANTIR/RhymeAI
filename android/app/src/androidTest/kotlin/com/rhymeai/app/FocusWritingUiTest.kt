package com.rhymeai.app

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.util.PronunciationDictionary
import java.io.File
import org.junit.*
import org.junit.Assert.*

@OptIn(ExperimentalTestApi::class)
class FocusWritingUiTest {
    @get:Rule val composeRule = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var vm: MainViewModel
    private val draft = "A quiet line\nBeneath the light"
    private val suggestion = "The words arrive with morning light"

    @Before fun start() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
        waitUntil { vm.appearanceLoaded }
        composeRule.onNodeWithText("New Song", useUnmergedTree = true).performScrollTo().performClick()
        waitUntil { !vm.savingBeforeNavigation && !vm.showStartMenu && vm.lyrics.isEmpty() }
        onMain {
            vm.onTitleChanged("Focus writing QA")
            vm.onLyricsChanged(TextFieldValue(draft, TextRange(draft.length)))
        }
    }

    @After fun stop() { scenario?.close() }

    @Test fun songRecordingsLivesInSongActionsAndClosesBackToWriting() {
        composeRule.onNodeWithText("Recordings", substring = false).assertDoesNotExist()
        val micButton = composeRule.onNodeWithTag("micButton").fetchSemanticsNode().boundsInRoot
        val micGlyph = composeRule.onNodeWithTag("micGlyph", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        assertEquals(micButton.center.x, micGlyph.center.x, 0.5f)
        assertEquals(micButton.center.y, micGlyph.center.y, 0.5f)
        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithTag("songRecordings").assertIsDisplayed().performClick()
        waitUntil { composeRule.onAllNodesWithTag("recordingsDone").fetchSemanticsNodes().isNotEmpty() }
        composeRule.onNodeWithText("Search recordings").assertIsDisplayed()
        composeRule.onNodeWithTag("importRecording").assertIsDisplayed()
        composeRule.onNodeWithText("Record", substring = false).assertDoesNotExist()
        composeRule.onNodeWithTag("recordingsDone").assertIsDisplayed().performClick()
        waitUntil { composeRule.onAllNodesWithTag("recordingsDone").fetchSemanticsNodes().isEmpty() }
        // Native dialog semantics disappear before the editor is interactive again.
        waitUntil { composeRule.onAllNodesWithTag("micButton").fetchSemanticsNodes().isNotEmpty() }
        composeRule.onNodeWithTag("lyricsEditor").assertIsDisplayed()
        onMain { assertEquals(draft, vm.lyrics) }
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithTag("songRecordings").assertIsEnabled().assertIsDisplayed().performClick()
        waitUntil { composeRule.onAllNodesWithTag("recordingsDone").fetchSemanticsNodes().isNotEmpty() }
        composeRule.onNodeWithTag("recordingsDone").performClick()
    }

    @Test fun suggestionActionsAreExplicitAndInsertionCanBeUndone() {
        seedSuggestions()
        composeRule.onNodeWithTag("unBlockAction").performClick()
        composeRule.onNodeWithText(suggestion).performScrollTo().performTouchInput { click() }
        onMain { assertEquals(draft, vm.lyrics) }
        capture("suggestion-actions")
        composeRule.onNodeWithText("Keep for later").performScrollTo().performClick()
        composeRule.onNodeWithText("Kept").assertIsNotEnabled()
        onMain {
            assertEquals(draft, vm.lyrics)
            assertEquals(suggestion, vm.songWorkspace.alternates.single().text)
        }
        capture("suggestion-kept")
        composeRule.onNodeWithText("Use line").performScrollTo().performClick()
        composeRule.onNodeWithText("Line added").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Close assistant").assertDoesNotExist()
        onMain { assertEquals("$draft\n$suggestion\n", vm.lyrics) }
        capture("line-added")
        composeRule.onNodeWithText("Undo", substring = false).performClick()
        onMain {
            assertEquals(draft, vm.lyrics)
            assertNull(vm.suggestionInsertion)
            assertEquals(TextRange(draft.length), vm.lyricsFieldValue.selection)
        }
        capture("line-undone")
        if (InstrumentationRegistry.getArguments().getString("prepareFocusReview") == "true") {
            seedSuggestions()
            composeRule.onNodeWithTag("unBlockAction").performClick()
            composeRule.onNodeWithText("Use line").performScrollTo()
            scenario = null
        }
    }

    @Test fun focusHidesSecondaryUIAndRestoresAnalysisWithoutChangingPreferences() {
        onMain { vm.isRhymeHighlightEnabled = true; vm.isSyllableColoringEnabled = true }
        composeRule.mainClock.advanceTimeBy(250)
        waitUntil { composeRule.onAllNodesWithTag("lyricAnalysisOverlay").fetchSemanticsNodes().isNotEmpty() }
        composeRule.onNodeWithText("Focus", substring = false).performClick()
        composeRule.onNodeWithText("Exit Focus").assertIsDisplayed()
        composeRule.onNodeWithTag("unBlockAction").assertDoesNotExist()
        composeRule.onNodeWithTag("songActionsMenuButton").assertDoesNotExist()
        composeRule.onNodeWithText("Song Notebook").assertDoesNotExist()
        composeRule.onNodeWithTag("lyricAnalysisOverlay").assertDoesNotExist()
        onMain { assertTrue(vm.isRhymeHighlightEnabled); assertTrue(vm.isSyllableColoringEnabled) }
        capture("focus")
        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInputSelection(TextRange(draft.length))
        composeRule.onNodeWithTag("lyricsEditor").performTextInput(" still writing")
        onMain { assertTrue(vm.lyrics.endsWith(" still writing")) }
        composeRule.onNodeWithText("Exit Focus").performClick()
        composeRule.onNodeWithTag("songActionsMenuButton").assertIsDisplayed().performClick()
        composeRule.onNodeWithTag("sectionMenuButton").assertIsDisplayed()
        composeRule.onNodeWithText("Song Notebook").assertIsDisplayed()
        composeRule.onNodeWithTag("unBlockAction").assertExists()
        composeRule.mainClock.advanceTimeBy(250)
        waitUntil { composeRule.onAllNodesWithTag("lyricAnalysisOverlay").fetchSemanticsNodes().isNotEmpty() }
        onMain { assertTrue(vm.isRhymeHighlightEnabled); assertTrue(vm.isSyllableColoringEnabled) }
        capture("focus-restored")
    }

    @Test fun insertionUndoPreservesUnicodeSelectionAndRejectsStaleFeedback() {
        val original = "🎵 first lyric\nA second line"
        val selected = TextRange(3, 8)
        onMain {
            vm.onLyricsChanged(TextFieldValue(original, selected))
            vm.insertSuggestion(suggestion)
            val insertion = requireNotNull(vm.suggestionInsertion)
            assertEquals(suggestion, vm.lyrics.substring(insertion.range.min, insertion.range.max))
            vm.undoSuggestionInsertion(insertion.id)
            assertEquals(original, vm.lyrics)
            assertEquals(selected, vm.lyricsFieldValue.selection)
            vm.insertSuggestion(suggestion)
            val second = requireNotNull(vm.suggestionInsertion)
            val typed = vm.lyrics + "manual edit"
            vm.onLyricsChanged(TextFieldValue(typed, TextRange(typed.length)))
            assertNull(vm.suggestionInsertion)
            vm.undoSuggestionInsertion(second.id)
            assertEquals(typed, vm.lyrics)
            vm.undoLyrics()
            vm.redoLyrics()
            vm.undoSuggestionInsertion(second.id)
            assertEquals(typed, vm.lyrics)
        }
    }

    @Test fun wordInspectorPublishesAfterOpeningModalClearsSelection() {
        composeRule.waitUntil(timeoutMillis = 20_000) {
            PronunciationDictionary.shared.wordCount > 0
        }
        val inspectorLyrics = "The streetlights blur like stars against the rain"
        val start = inspectorLyrics.lastIndexOf("rain")
        val selectedWord = TextRange(start, start + "rain".length)
        onMain {
            vm.onLyricsChanged(TextFieldValue(inspectorLyrics, TextRange(inspectorLyrics.length)))
            vm.onLyricsChanged(TextFieldValue(inspectorLyrics, selectedWord))
            assertEquals("rain" to selectedWord, vm.singleWordSelection)
        }

        composeRule.onNodeWithContentDescription("Look up word").assertIsDisplayed()
        onMain {
            vm.openInspectorForSelection()
            // This is the same transition EditorScreen runs when its modal opens.
            // Keep it in one main-thread turn so IO cannot win the old race.
            vm.clearPendingRewriteSelection()
        }
        composeRule.waitUntil(timeoutMillis = 8_000) {
            vm.showInspector && vm.lyricsFieldValue.selection.collapsed
        }
        composeRule.waitUntil(timeoutMillis = 20_000) {
            vm.inspectorProsody?.word == "rain" && vm.inspectorMatches?.perfect?.isNotEmpty() == true
        }
        onMain {
            assertNull(vm.pendingRewriteRange)
            assertEquals(inspectorLyrics, vm.lyrics)
            assertEquals("rain", vm.inspectorWord)
        }
    }

    @Test fun switchingSongsInvalidatesInsertionFeedback() {
        var insertionId = 0L
        onMain {
            vm.insertSuggestion(suggestion)
            insertionId = requireNotNull(vm.suggestionInsertion).id
            vm.newProject()
        }
        waitUntil { !vm.savingBeforeNavigation && vm.lyrics.isEmpty() }
        onMain {
            assertNull(vm.suggestionInsertion)
            vm.undoSuggestionInsertion(insertionId)
            assertEquals("", vm.lyrics)
        }
    }

    private fun seedSuggestions() { onMain { vm.suggestions = listOf(SuggestedLine(suggestion, rhymeTier = 2)) } }
    private fun capture(name: String) {
        val directory = File(instrumentation.targetContext.filesDir, "focus-writing-qa").apply { mkdirs() }
        instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
            File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }
    private fun onMain(block: () -> Unit) { instrumentation.runOnMainSync(block); instrumentation.waitForIdleSync() }
    private fun waitUntil(condition: () -> Boolean) {
        val until = SystemClock.uptimeMillis() + 8_000
        while (SystemClock.uptimeMillis() < until) {
            if (condition()) return
            SystemClock.sleep(50)
        }
        capture("state-timeout")
        val evidence = File(instrumentation.targetContext.filesDir, "focus-writing-qa/state-timeout.txt")
        evidence.writeText("rhyme=${vm.isRhymeHighlightEnabled}; syllables=${vm.isSyllableColoringEnabled}; selection=${vm.lyricsFieldValue.selection}; activeRewrite=${vm.hasActiveRewrite}\n" + composeRule.onRoot(useUnmergedTree = true).printToString())
        fail("Focus writing state did not settle")
    }
}
