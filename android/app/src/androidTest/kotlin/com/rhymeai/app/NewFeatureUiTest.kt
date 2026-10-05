package com.rhymeai.app

import android.content.ContentValues
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextInputSelection
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.TextRange
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.ViewModelProvider
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.util.PronunciationDictionary
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.After
import org.junit.Before
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NewFeatureUiTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null
    private var previousFontScale: String? = null
    private var previousAnimatorDurationScale: String? = null

    @Before
    fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        if (PronunciationDictionary.shared.wordCount == 0) {
            context.assets.open("cmudict-rhymeai.tsv").use(PronunciationDictionary::initialize)
        }
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    @After
    fun tearDown() {
        try {
            scenario?.close()
        } finally {
            scenario = null
            restoreFontScale()
            restoreAnimatorDurationScale()
        }
    }

    @Test
    fun songLibraryEntersFromAndReturnsToLeftEdge() {
        openNewSong()
        composeRule.mainClock.autoAdvance = false
        try {
            composeRule.onNodeWithContentDescription("Open songs drawer").performClick()
            composeRule.mainClock.advanceTimeBy(64)
            val enteringBounds = composeRule.onNodeWithContentDescription("Close drawer")
                .getUnclippedBoundsInRoot()
            captureRootScreenshot("library-motion-entry.png")
            composeRule.mainClock.advanceTimeBy(240)
            val settledBounds = composeRule.onNodeWithContentDescription("Close drawer")
                .getUnclippedBoundsInRoot()
            captureRootScreenshot("library-motion-settled.png")
            assertTrue(
                "The song library must enter from its left-edge origin",
                enteringBounds.left.value < settledBounds.left.value
            )

            composeRule.onNodeWithContentDescription("Close drawer").performClick()
            composeRule.mainClock.advanceTimeBy(96)
            val exitingBounds = composeRule.onNodeWithContentDescription("Close drawer")
                .assertExists()
                .getUnclippedBoundsInRoot()
            captureRootScreenshot("library-motion-exit.png")
            assertTrue(
                "The song library must return toward the left edge",
                exitingBounds.left.value < settledBounds.left.value
            )
            composeRule.mainClock.advanceTimeBy(240)
            composeRule.onNodeWithContentDescription("Close drawer").assertDoesNotExist()
            composeRule.onNodeWithTag("lyricsEditor").assertIsDisplayed()
        } finally {
            composeRule.mainClock.autoAdvance = true
        }
    }

    @Test
    fun songLibraryChangesImmediatelyWhenAnimationsAreDisabled() {
        setAnimatorDurationScale(0f)
        relaunchActivity()
        openNewSong()
        composeRule.mainClock.autoAdvance = false
        try {
            composeRule.onNodeWithContentDescription("Open songs drawer").performClick()
            composeRule.mainClock.advanceTimeByFrame()
            composeRule.onNodeWithContentDescription("Close drawer").assertIsDisplayed()

            composeRule.onNodeWithContentDescription("Close drawer").performClick()
            composeRule.mainClock.advanceTimeByFrame()
            composeRule.mainClock.advanceTimeByFrame()
            composeRule.onNodeWithContentDescription("Close drawer").assertDoesNotExist()
        } finally {
            composeRule.mainClock.autoAdvance = true
        }
    }

    @Test
    fun trashNavigationObservesRemoveAnimationsWithoutRelaunch() {
        createSavedSong(title = "Reduced Motion Trash")
        composeRule.onNodeWithContentDescription("Open songs drawer").performClick()
        composeRule.onNodeWithContentDescription("Delete Reduced Motion Trash").performClick()
        composeRule.onNodeWithContentDescription("Open Trash Bin").performClick()
        composeRule.onNodeWithText("Trash").assertIsDisplayed()

        setAnimatorDurationScale(0f)
        composeRule.waitForIdle()
        composeRule.mainClock.autoAdvance = false
        try {
            composeRule.onNodeWithContentDescription("Back to songs drawer").performClick()
            composeRule.mainClock.advanceTimeByFrame()
            composeRule.mainClock.advanceTimeByFrame()
            composeRule.onNodeWithText("Trash").assertDoesNotExist()
        } finally {
            composeRule.mainClock.autoAdvance = true
        }
    }

    @Test
    fun songNotebookTabsKeepOneInsetAwareHeight() {
        openNewSong()
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithText("Song Notebook").performClick()
        composeRule.waitForIdle()

        val alternatesBounds = composeRule.onNodeWithTag("songNotebookSheetContent")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        assertTrue(
            "Notebook content must remain below the status-bar edge",
            alternatesBounds.top.value > 0f
        )

        composeRule.onNodeWithText("Draft History").performClick()
        composeRule.waitForIdle()
        val historyBounds = composeRule.onNodeWithTag("songNotebookSheetContent")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        assertEquals(alternatesBounds.top.value, historyBounds.top.value, 1f)
        assertEquals(alternatesBounds.bottom.value, historyBounds.bottom.value, 1f)
    }

    @Test
    fun selectingSongReplacesEditorWithoutWaitingForDismissal() {
        createSavedSong(title = "Library Selection Test")
        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java].newProject()
        }
        composeRule.onNodeWithContentDescription("Open songs drawer").performClick()
        composeRule.waitForIdle()
        composeRule.mainClock.autoAdvance = false
        try {
            composeRule.onNodeWithText("Library Selection Test").performClick()
            composeRule.mainClock.advanceTimeByFrame()
            composeRule.onNodeWithContentDescription("Close drawer").assertDoesNotExist()
            composeRule.onNodeWithTag("songTitleEditor").assertTextEquals("Library Selection Test")
        } finally {
            composeRule.mainClock.autoAdvance = true
        }
    }

    @Test
    fun editorTopBarProvidesSectionMenu() {
        composeRule.onNodeWithText("New Song").performClick()

        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithTag("sectionMenuButton")
            .assertIsDisplayed()
            .assertHasClickAction()
            .performClick()
        composeRule.onNodeWithTag("sectionMenuVerse").assertIsDisplayed().performClick()
        assertEquals(
            "[Verse]\n",
            composeRule.onNodeWithTag("lyricsEditor")
                .fetchSemanticsNode()
                .config[SemanticsProperties.EditableText]
                .text
        )
    }

    @Test
    fun longEditorTitleKeepsTopBarActionsReachable() {
        // Given
        val title = "A Very Long Song Title That Still Needs Useful Context"
        val nonEmptyLyrics = "A line that keeps Share enabled"

        // When
        composeRule.onNodeWithText("New Song").performClick()
        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java]
                .seedEditorForTesting(title, nonEmptyLyrics)
        }
        composeRule.waitForIdle()
        composeRule.mainClock.advanceTimeBy(1_500)
        composeRule.waitForIdle()

        // Then
        val rootBounds = composeRule.onRoot().getUnclippedBoundsInRoot()
        val sectionBounds = composeRule.onNodeWithTag("songActionsMenuButton")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        assertTrue(
            "Section menu needs positive geometry",
            sectionBounds.right.value > sectionBounds.left.value &&
                sectionBounds.bottom.value > sectionBounds.top.value
        )
        val savedBounds = composeRule.onNodeWithContentDescription("Saved")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        assertTrue(
            "Saved status must have positive geometry",
            savedBounds.right.value > savedBounds.left.value &&
                savedBounds.bottom.value > savedBounds.top.value
        )
        assertTrue(
            "Saved status must remain inside the root",
            savedBounds.left.value >= rootBounds.left.value &&
                savedBounds.top.value >= rootBounds.top.value &&
                savedBounds.right.value <= rootBounds.right.value &&
                savedBounds.bottom.value <= rootBounds.bottom.value
        )
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithText("Export")
            .assertIsDisplayed()
            .assertHasClickAction()
        composeRule.onNodeWithText("Settings")
            .assertIsDisplayed()
            .assertHasClickAction()
            .performClick()
        composeRule.onNodeWithText("Editor").performClick()
        composeRule.onNodeWithText("Syllable Guide").assertIsOn()
        composeRule.onNodeWithText("Rhyme Families").assertIsOn()
        composeRule.onNodeWithContentDescription("Rhyme Families help").performClick()
        composeRule.onNodeWithText(
            "Colors matching rhyme sounds throughout the current lyric. " +
                "Each color represents one rhyme family; this does not change generated suggestions."
        ).assertIsDisplayed()
    }

    @Test
    fun sectionMenuRemainsReachableAfterEditorScroll() {
        composeRule.onNodeWithText("New Song").performClick()
        val longLyrics = (1..60).joinToString("\n") { line -> "Lyric line $line" }
        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java]
                .seedEditorForTesting("Long Song", longLyrics)
        }
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("editorScrollContainer").performTouchInput { swipeUp() }

        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithTag("sectionMenuButton")
            .assertIsDisplayed()
            .assertHasClickAction()
            .performClick()
        composeRule.onNodeWithTag("sectionMenuBridge").assertIsDisplayed()
    }

    @Test
    fun welcomeCardsRemainHittableAtLargeFontScale() {
        // Given
        setFontScale(2.0f)

        // When
        relaunchActivity()

        // Then
        listOf("New Song", "Load Song", "Song Templates").forEach { title ->
            composeRule.onNodeWithText(title)
                .assertIsDisplayed()
                .assertHasClickAction()
        }
        listOf(
            "Start with a blank canvas",
            "Continue where you left off",
            "Start with a structured layout"
        ).forEach { subtitle ->
            composeRule.onNodeWithText(subtitle).assertIsDisplayed()
        }

        val rootBounds = composeRule.onRoot().getUnclippedBoundsInRoot()
        val textContainers = composeRule.onAllNodesWithTag(
            "welcomeCardText",
            useUnmergedTree = true
        )
        val expectedCardCount = if (
            composeRule.onAllNodesWithText("Return to your writing").fetchSemanticsNodes().isEmpty()
        ) 3 else 4
        textContainers.assertCountEquals(expectedCardCount)
        val textContainerBounds = List(expectedCardCount) { index ->
            textContainers[index].getUnclippedBoundsInRoot()
        }
        textContainerBounds.forEachIndexed { index, bounds ->
            assertTrue(
                "Welcome card text container $index must have positive geometry",
                bounds.right.value > bounds.left.value && bounds.bottom.value > bounds.top.value
            )
            assertTrue(
                "Welcome card text container $index must stay inside the root",
                bounds.left.value >= rootBounds.left.value &&
                    bounds.top.value >= rootBounds.top.value &&
                    bounds.right.value <= rootBounds.right.value &&
                    bounds.bottom.value <= rootBounds.bottom.value
            )
        }
        val trailingEdge = textContainerBounds.first().right.value
        textContainerBounds.drop(1).forEachIndexed { index, bounds ->
            assertTrue(
                "Welcome card text container ${index + 1} must fill the available card width",
                kotlin.math.abs(bounds.right.value - trailingEdge) <= 1f
            )
        }
    }

    @Test
    fun undoRedoButtonsRestoreLyrics() {
        // Given
        composeRule.onNodeWithText("New Song").performClick()
        val editor = composeRule.onNodeWithTag("lyricsEditor")
        val undoButton = composeRule.onNodeWithTag("undoLyricsButton")
        val redoButton = composeRule.onNodeWithTag("redoLyricsButton")
        undoButton.assertIsNotEnabled()
        redoButton.assertIsNotEnabled()

        // When
        editor.performClick().performTextInput("first line")
        undoButton.assertIsEnabled().performClick()

        // Then
        assertEquals(
            "",
            editor.fetchSemanticsNode().config[SemanticsProperties.EditableText].text
        )
        redoButton.assertIsEnabled()

        // When
        redoButton.performClick()

        // Then
        editor.assertTextEquals("first line")
        captureRootScreenshot("undo-redo-phone.png")
    }

    @Test
    fun editorActionsStayGroupedAtTheRightEdge() {
        composeRule.onNodeWithText("New Song").performClick()

        val rootBounds = composeRule.onRoot().getUnclippedBoundsInRoot()
        val unBlockBounds = composeRule.onNodeWithTag("unBlockAction")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        val micBounds = composeRule.onNodeWithContentDescription("Voice memos")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        val rightInset = rootBounds.right.value - micBounds.right.value
        val unBlockCenter = (unBlockBounds.left.value + unBlockBounds.right.value) / 2f
        val rootCenter = (rootBounds.left.value + rootBounds.right.value) / 2f

        assertTrue(
            "The mic should keep the editor's 21dp right-edge inset",
            kotlin.math.abs(rightInset - DesignTokens.Rhythm.standard.value) <= 1f
        )
        assertTrue("UnBlock should sit on the right half of the editor", unBlockCenter > rootCenter)
    }

    @Test
    fun lyricViewportStopsAboveWritingActions() {
        openNewSong()

        val viewportBounds = composeRule.onNodeWithTag("editorScrollContainer")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        val unBlockBounds = composeRule.onNodeWithTag("unBlockAction")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()

        assertTrue(
            "The readable lyric viewport must end above UnBlock",
            viewportBounds.bottom.value <= unBlockBounds.top.value
        )
    }

    @Test
    fun focusModeKeepsLyricViewportAboveKeyboard() {
        openNewSong()
        composeRule.onNodeWithTag("lyricsEditor")
            .performClick()
            .performTextInput("first line\nsecond line\nthird line")
        composeRule.waitUntil(timeoutMillis = 3_000) { imeBottomPx() > 0 }

        composeRule.onNodeWithTag("focusWritingToggle").performClick()
        composeRule.onNodeWithTag("unBlockAction").assertDoesNotExist()
        composeRule.onNodeWithTag("focusWritingToggle").performClick()
        composeRule.onNodeWithTag("unBlockAction").assertIsDisplayed()
        composeRule.onNodeWithTag("focusWritingToggle").performClick()
        composeRule.onNodeWithTag("unBlockAction").assertDoesNotExist()
        assertTrue("The keyboard must stay open across the Focus toggle sequence", imeBottomPx() > 0)

        val viewportBounds = composeRule.onNodeWithTag("editorScrollContainer")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        val keyboardTop = decorHeightPx() - imeBottomPx()
        assertTrue(
            "Focus mode must keep the lyric viewport above the keyboard",
            viewportBounds.bottom.value <= keyboardTop
        )
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun longLyricsStayAboveUnBlockAndKeyboard() {
        openNewSong()
        val lyrics = (1..24).joinToString("\n") { line ->
            "Synthetic lyric context line $line"
        }
        val editor = composeRule.onNodeWithTag("lyricsEditor")
        editor.performClick().performTextInput(lyrics)
        editor.performTextInputSelection(TextRange(lyrics.length))
        composeRule.waitUntil(timeoutMillis = 3_000) { imeBottomPx() > 0 }

        val viewportBounds = composeRule.onNodeWithTag("editorScrollContainer")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        val unBlockBounds = composeRule.onNodeWithTag("unBlockAction")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        val keyboardTop = decorHeightPx() - imeBottomPx()
        assertTrue(
            "Long lyrics must stop above UnBlock",
            viewportBounds.bottom.value <= unBlockBounds.top.value
        )
        assertTrue(
            "UnBlock must remain above the keyboard",
            unBlockBounds.bottom.value <= keyboardTop
        )
        captureRootScreenshot("editor-long-keyboard.png")
    }

    @Test
    fun lyricStatsSitBelowTheEditableTitle() {
        composeRule.onNodeWithText("New Song").performClick()

        val topBarSection = composeRule.onNodeWithTag("songActionsMenuButton")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        val title = composeRule.onNodeWithTag("songTitleEditor")
            .assertIsDisplayed()
            .getUnclippedBoundsInRoot()
        val stats = composeRule.onNodeWithTag("editorStats")
            .assertTextEquals("0w · 0s")
            .getUnclippedBoundsInRoot()

        assertTrue(
            "Stats must leave the top-bar action cluster",
            stats.top.value > topBarSection.bottom.value
        )
        assertTrue(
            "Stats must follow the editable title",
            stats.top.value >= title.bottom.value
        )
    }

    @Test
    fun movingSongToTrashShowsFullPageTrashBinAndRestoreActions() {
        createSavedSong(title = "UI Trash Song")

        composeRule.onNodeWithContentDescription("Open songs drawer").performClick()
        composeRule.onNodeWithContentDescription("Delete UI Trash Song").performClick()
        composeRule.onNodeWithText("\"UI Trash Song\" moved to Trash").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Open Trash Bin").performClick()

        composeRule.onNodeWithText("Trash").assertIsDisplayed()
        composeRule.onNodeWithText("UI Trash Song").assertIsDisplayed()
        // The header states the retention rule; each row carries its own countdown.
        composeRule.onNodeWithText("Deleted songs stay here for 30 days.").assertIsDisplayed()
        composeRule.onNode(hasText("30 days left", substring = true)).assertDoesNotExist()
        composeRule.onNode(hasText("Deletes in 30 days", substring = true)).assertIsDisplayed()

        val trashSelection = composeRule.onNodeWithText("UI Trash Song")
        val semantics = trashSelection.fetchSemanticsNode().config
        assertEquals(Role.Checkbox, semantics[SemanticsProperties.Role])
        assertEquals(ToggleableState.Off, semantics[SemanticsProperties.ToggleableState])
        trashSelection.assertIsOff().performClick().assertIsOn()
        composeRule.onNodeWithText("Restore").assertIsEnabled()
        composeRule.onNodeWithText("Delete").assertIsEnabled()
    }

    @Test
    fun editorSettingsSwitchesExposeAccessibleNames() {
        composeRule.onNodeWithText("New Song").performClick()
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithText("Settings").performClick()
        composeRule.onNodeWithText("Editor").performClick()

        listOf(
            "Syllable Guide",
            "Rhyme Families",
            "Whole Song Context",
            "Stress + IPA",
            "Highlight Suggestion Rhymes",
            "Beat Grid"
        ).forEach { label ->
            composeRule.onNodeWithText(label).assertExists()
        }
        composeRule.onNodeWithContentDescription("Rhyme Families help").performClick()
        composeRule.onNodeWithText(
            "Colors matching rhyme sounds throughout the current lyric. " +
                "Each color represents one rhyme family; this does not change generated suggestions."
        ).assertIsDisplayed()
    }

    @Test
    fun trashSelectorsExposeCheckboxSemanticsAndSingleEntryNode() {
        val title = "UI Semantics ${System.currentTimeMillis()}"
        createSavedSong(title)

        composeRule.onNodeWithContentDescription("Open songs drawer").performClick()
        assertEquals(
            1,
            composeRule.onAllNodesWithContentDescription(
                "Open Trash Bin",
                useUnmergedTree = true
            ).fetchSemanticsNodes().size
        )
        composeRule.onNodeWithContentDescription("Delete $title").performClick()
        composeRule.onNodeWithText("\"$title\" moved to Trash").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Open Trash Bin").performClick()
        composeRule.waitUntil(timeoutMillis = 3_000) {
            composeRule.onAllNodesWithText(title).fetchSemanticsNodes().isNotEmpty()
        }

        val selector = composeRule.onNodeWithText(title)
        val before = selector.fetchSemanticsNode().config
        assertEquals(Role.Checkbox, before[SemanticsProperties.Role])
        assertEquals(ToggleableState.Off, before[SemanticsProperties.ToggleableState])
        selector.assertIsOff().performClick().assertIsOn()
    }

    @Test
    fun drawerExposesSeparateClearAndCloseActions() {
        composeRule.onNodeWithText("New Song").performClick()
        composeRule.onNodeWithContentDescription("Open songs drawer").performClick()

        composeRule.onNodeWithContentDescription("Close drawer").assertExists()
        composeRule.onNodeWithText("Search songs").performTextInput("UI")
        composeRule.onNodeWithContentDescription("Clear search").assertExists()
        composeRule.onNodeWithContentDescription("Close drawer").assertExists()

        composeRule.onNodeWithContentDescription("Clear search").performClick()
        composeRule.onNodeWithText("Create New Song").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Close drawer").performClick()
        composeRule.onNodeWithContentDescription("Open songs drawer").assertIsDisplayed()
    }

    @Test
    fun assistantExposesExplicitCloseAction() {
        composeRule.onNodeWithText("New Song").performClick()
        composeRule.onNodeWithText("UnBlock").performClick()

        composeRule.onNodeWithContentDescription("Close assistant").assertIsDisplayed().performClick()
        composeRule.onNodeWithTag("unBlockAction").assertIsDisplayed()
    }

    @Test
    fun stressAndIpaToggleRendersProsodyPreviewInAssistant() {
        // Stress + IPA was moved from the assistant panel to Settings → Editor tab.
        // Enable it there first, then open the assistant panel to verify prosody renders.
        openNewSong()
        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInput("[Verse]\nyellow music\nfollow music")

        // Open Settings and navigate to the Editor tab.
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithText("Settings").performClick()
        composeRule.onNodeWithText("Editor").performClick()

        // Enable Stress + IPA in the Editor tab.
        composeRule.onNodeWithText("Stress + IPA").performScrollTo().performClick()

        // Dismiss Settings.
        composeRule.onNodeWithContentDescription("Close").performClick()

        // Now open the assistant panel and verify prosody preview is rendered.
        composeRule.onNodeWithText("UnBlock").performClick()
        composeRule.onNodeWithText("ˈDA da | ˈDA da").performScrollTo().assertIsDisplayed()
        composeRule.onNode(hasText("jɛloʊ", substring = true)).performScrollTo().assertIsDisplayed()
    }

    @Test
    fun assistantStopCancelsSuggestionRequest() {
        assumeTrue(
            "Skipping assistant cancellation gate: android/local.properties has no geminiTestKey.",
            BuildConfig.GEMINI_TEST_KEY.isNotBlank()
        )
        openNewSong()
        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInput("[Verse]\nyellow music\nfollow music")

        composeRule.onNodeWithText("UnBlock").performClick()
        composeRule.onNodeWithText("Suggest Next Line").performScrollTo().performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText("Stop").fetchSemanticsNodes().isNotEmpty()
        }

        composeRule.onNodeWithText("Stop").performClick()

        composeRule.onNodeWithText("Suggest Next Line").performScrollTo().assertIsDisplayed()
    }

    @Test
    fun assistantOfflineFailureShowsConnectionMessage() {
        assumeTrue(
            "Skipping offline provider gate: android/local.properties has no geminiTestKey.",
            BuildConfig.GEMINI_TEST_KEY.isNotBlank()
        )
        setEmulatorNetworkEnabled(false)
        try {
            openNewSong()
            composeRule.onNodeWithTag("lyricsEditor").performClick()
            composeRule.onNodeWithTag("lyricsEditor").performTextInput("[Verse]\nyellow music\nfollow music")

            composeRule.onNodeWithText("UnBlock").performClick()
            composeRule.onNodeWithText("Suggest Next Line").performScrollTo().performClick()

            composeRule.waitUntil(timeoutMillis = 45_000) {
                composeRule.onAllNodesWithText("Provider request failed — check your connection and try again.")
                    .fetchSemanticsNodes()
                    .isNotEmpty()
            }
            composeRule.onNodeWithText("Suggest Next Line").performScrollTo().assertIsDisplayed()
        } finally {
            setEmulatorNetworkEnabled(true)
        }
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun selectedRewriteDockPreservesNativeSelectionAndRootSafe() {
        composeRule.onNodeWithText("New Song").performClick()

        val lyrics = (1..20).joinToString("\n") { line ->
            "Testing selected rewrite placement line $line"
        }
        val selectionStart = lyrics.indexOf("line 20")
        val selectionEnd = selectionStart + "line 20".length

        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInput(lyrics)
        composeRule.onNodeWithTag("lyricsEditor").performTextInputSelection(
            TextRange(selectionStart, selectionEnd)
        )

        composeRule.onNodeWithTag("rewriteChipBar").assertIsDisplayed()
        val fieldSelection = composeRule.onNodeWithTag("lyricsEditor")
            .fetchSemanticsNode()
            .config
            .getOrNull(SemanticsProperties.TextSelectionRange)
        assertTrue(
            "Native text selection must stay expanded so both selection handles remain available",
            fieldSelection != null &&
                !fieldSelection.collapsed &&
                fieldSelection.start == selectionStart &&
                fieldSelection.end == selectionEnd
        )
        val rewriteBounds = composeRule.onNodeWithTag("rewriteChipBar").getUnclippedBoundsInRoot()
        val rootBounds = composeRule.onRoot().getUnclippedBoundsInRoot()
        assertTrue("Rewrite dock must stay within the visible root", rewriteBounds.bottom <= rootBounds.bottom)

        // The swipe-to-collapse-keyboard NestedScrollConnection gates on the IME
        // being visible, which doesn't happen in instrumented Compose tests
        // (performTextInput bypasses the soft keyboard). Manual QA covers it.
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun rewriteChipBarReplacesFloatingActionsUntilSelectionClears() {
        composeRule.onNodeWithText("New Song").performClick()

        val lyrics = "The harbor lights are burning low"
        val editor = composeRule.onNodeWithTag("lyricsEditor")
        editor.performClick().performTextInput(lyrics)
        composeRule.onNodeWithTag("unBlockAction").assertIsDisplayed()
        composeRule.onNodeWithTag("micButton").assertIsDisplayed()

        editor.performTextInputSelection(TextRange(4, 10))
        composeRule.onNodeWithTag("rewriteChipBar").assertIsDisplayed()
        composeRule.onNodeWithTag("unBlockAction").assertDoesNotExist()
        composeRule.onNodeWithTag("micButton").assertDoesNotExist()

        editor.performTextInputSelection(TextRange(lyrics.length))
        composeRule.onNodeWithTag("rewriteChipBar").assertDoesNotExist()
        composeRule.onNodeWithTag("unBlockAction").assertIsDisplayed()
        composeRule.onNodeWithTag("micButton").assertIsDisplayed()
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun singleWordSelectionShowsRewriteChipWithLookupIntoInspector() {
        composeRule.onNodeWithText("New Song").performClick()

        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInput("Yellow mellow fellow")
        // Select just the single word "Yellow".
        composeRule.onNodeWithTag("lyricsEditor").performTextInputSelection(TextRange(0, 6))

        // A single-word selection raises the punch-up/rewrite chip together with
        // the leading look-up (magnifying glass) button.
        composeRule.onNodeWithTag("rewriteChipBar").assertIsDisplayed()
        composeRule.onNodeWithTag("inspectAction").assertIsDisplayed()
        captureRootScreenshot("rewrite-chip-single-word.png")

        // Tapping look-up opens the Word Inspector sheet.
        composeRule.onNodeWithTag("inspectAction").performClick()
        composeRule.onNodeWithTag("wordInspectorSheet").assertIsDisplayed()
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun rewriteActionsOpenReviewBarAndCancelBackToChipBar() {
        composeRule.onNodeWithText("New Song").performClick()

        val lyrics = "yellow music\nfollow music"
        val selection = TextRange(0, "yellow music".length)
        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInput(lyrics)
        composeRule.onNodeWithTag("lyricsEditor").performTextInputSelection(selection)

        listOf("Rephrase", "Harder Rhyme", "Punch Up").forEach { action ->
            composeRule.onNodeWithText(action).assertIsDisplayed().performClick()
            composeRule.onNodeWithTag("inlineRewriteReviewBar").assertIsDisplayed()
            if (action == "Punch Up") {
                captureRootScreenshot("rewrite-review-punch-up.png")
            }
            composeRule.onNodeWithText("Cancel").performClick()
            composeRule.onNodeWithTag("rewriteChipBar").assertIsDisplayed()
        }
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun liveGemini35FlashSelectedRewriteActionsReachReviewPreview() {
        verifyLiveGeminiSelectedRewriteActions(AIModel.GEMINI_35_FLASH)
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun liveGemini31ProSelectedRewriteActionsReachReviewPreview() {
        verifyLiveGeminiSelectedRewriteActions(AIModel.GEMINI_31_PRO)
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun harderRhymeSingleWordPreviewRejectsReality() {
        composeRule.onNodeWithText("New Song").performClick()

        val lyrics = """
            We're lost
            We don't even know what's real
            We're lost
            We go with what we feel
        """.trimIndent()
        val selectionStart = lyrics.indexOf("real")
        val selection = TextRange(selectionStart, selectionStart + "real".length)

        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInput(lyrics)
        composeRule.onNodeWithTag("lyricsEditor").performTextInputSelection(selection)

        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java]
                .seedRewritePreviewForTesting(
                    action = RewriteAction.HARDER_RHYME,
                    range = selection,
                    original = "real",
                    preview = "feel"
                )
        }

        composeRule.onNodeWithTag("inlineRewriteReviewBar").assertIsDisplayed()
        assertTrue(
            "Harder Rhyme preview must not show the rejected E2B expansion",
            composeRule.onAllNodesWithText("reality", substring = true).fetchSemanticsNodes().isEmpty()
        )
        composeRule.onNode(hasText("feel", substring = true)).assertIsDisplayed()
        captureRootScreenshot("harder-rhyme-real-feel-preview.png")
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun rewriteLoadingShowsMotionOverSelection() {
        composeRule.onNodeWithText("New Song").performClick()

        val lyrics = """
            [Verse]
            yellow music
            follow music
        """.trimIndent()
        val selectedText = "yellow music"
        val selectionStart = lyrics.indexOf(selectedText)
        val selection = TextRange(selectionStart, selectionStart + selectedText.length)

        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInput(lyrics)
        composeRule.onNodeWithTag("lyricsEditor").performTextInputSelection(selection)
        composeRule.mainClock.autoAdvance = false

        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java]
                .seedRewriteLoadingForTesting(
                    action = RewriteAction.PUNCH_UP,
                    range = selection,
                    original = selectedText
                )
        }

        composeRule.mainClock.advanceTimeBy(600)
        composeRule.onNodeWithTag("inlineRewriteReviewBar").assertIsDisplayed()
        composeRule.onNodeWithTag("lyricsEditor").assertIsDisplayed()
        val editorBounds = composeRule.onNodeWithTag("lyricsEditor").getUnclippedBoundsInRoot()
        captureRootScreenshot("rewrite-loading-${BuildConfig.REWRITE_MOTION_STYLE}-start.png")

        composeRule.mainClock.advanceTimeBy(300)
        captureRootScreenshot("rewrite-loading-${BuildConfig.REWRITE_MOTION_STYLE}.png")

        composeRule.mainClock.advanceTimeBy(300)
        assertEquals(editorBounds, composeRule.onNodeWithTag("lyricsEditor").getUnclippedBoundsInRoot())
        captureRootScreenshot("rewrite-loading-${BuildConfig.REWRITE_MOTION_STYLE}-loop-end.png")
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun harderRhymeReportedExamplesRenderSafePreviewAndRefusal() {
        composeRule.onNodeWithText("New Song").performClick()

        val lyrics = """
            In the land of make believe
            Where we claim to be free
            Hypnotized by TVs
            Personalized social feeds

            Cold corporate walls
            Birds chirping in phone calls
        """.trimIndent()
        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInput(lyrics)

        val wallsStart = lyrics.indexOf("walls")
        val wallsRange = TextRange(wallsStart, wallsStart + "walls".length)
        composeRule.onNodeWithTag("lyricsEditor").performTextInputSelection(wallsRange)
        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java]
                .seedRewritePreviewForTesting(
                    action = RewriteAction.HARDER_RHYME,
                    range = wallsRange,
                    original = "walls",
                    preview = "calls"
                )
        }

        composeRule.onNodeWithTag("inlineRewriteReviewBar").assertIsDisplayed()
        composeRule.onNode(hasText("calls", substring = true)).assertIsDisplayed()
        captureRootScreenshot("harder-rhyme-walls-calls-preview.png")

        composeRule.onNodeWithText("Cancel").performClick()
        val callsStart = lyrics.indexOf("calls")
        val callsRange = TextRange(callsStart, callsStart + "calls".length)
        composeRule.onNodeWithTag("lyricsEditor").performTextInputSelection(callsRange)
        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java]
                .seedRewriteErrorForTesting(
                    action = RewriteAction.HARDER_RHYME,
                    range = callsRange,
                    original = "calls",
                    error = "No safe rhyme. Select the line."
                )
        }

        composeRule.onNodeWithTag("inlineRewriteReviewBar").assertIsDisplayed()
        composeRule.onNode(hasText("No safe rhyme", substring = true)).assertIsDisplayed()
        captureRootScreenshot("harder-rhyme-no-safe-single-word.png")
    }

    @OptIn(ExperimentalTestApi::class)
    private fun verifyLiveGeminiSelectedRewriteActions(model: AIModel) {
        assumeTrue(
            "Skipping live Gemini UI rewrite gate: android/local.properties has no geminiTestKey.",
            BuildConfig.GEMINI_TEST_KEY.isNotBlank()
        )

        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java].run {
                saveProvider(AIProvider.GEMINI)
                saveModel(model)
            }
        }

        composeRule.onNodeWithText("New Song").performClick()

        val lyrics = "yellow music\nfollow music"
        val selection = TextRange(0, "yellow music".length)
        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInput(lyrics)
        composeRule.onNodeWithTag("lyricsEditor").performTextInputSelection(selection)
        composeRule.onNodeWithTag("rewriteChipBar").assertIsDisplayed()
        captureRootScreenshot("live-gemini-${model.screenshotSlug()}-rewrite-chip.png")

        listOf(RewriteAction.REPHRASE, RewriteAction.HARDER_RHYME, RewriteAction.PUNCH_UP).forEach { action ->
            composeRule.onNodeWithText(action.label).assertIsDisplayed().performClick()
            composeRule.onNodeWithTag("inlineRewriteReviewBar").assertIsDisplayed()
            composeRule.waitUntil(timeoutMillis = 120_000) {
                composeRule.onAllNodesWithText("Previewing ${action.label}", substring = true)
                    .fetchSemanticsNodes().isNotEmpty() ||
                    composeRule.onAllNodesWithText("Provider", substring = true)
                        .fetchSemanticsNodes().isNotEmpty()
            }
            val providerErrors = composeRule.onAllNodesWithText("Provider", substring = true)
                .fetchSemanticsNodes()
            assertTrue(
                "Live Gemini selected rewrite produced a provider error for ${model.id} ${action.label}",
                providerErrors.isEmpty()
            )
            captureRootScreenshot("live-gemini-${model.screenshotSlug()}-${action.name.lowercase()}-preview.png")
            composeRule.onNodeWithText("Cancel").performClick()
            composeRule.onNodeWithTag("rewriteChipBar").assertIsDisplayed()
        }
    }

    private fun captureRootScreenshot(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val uniqueName = name.substringBeforeLast('.') +
            "-${System.currentTimeMillis()}." +
            name.substringAfterLast('.')
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, uniqueName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RhymeAI-Test")
        }
        val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: error("Could not create screenshot media row for $uniqueName")
        context.contentResolver.openOutputStream(uri).use { output ->
            requireNotNull(output) { "Could not open screenshot output stream for $uniqueName" }
            composeRule.onRoot().captureToImage().asAndroidBitmap()
                .compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output)
        }
        println("SCREENSHOT_PATH /sdcard/Pictures/RhymeAI-Test/$uniqueName")
    }

    private fun AIModel.screenshotSlug(): String =
        id.replace(Regex("[^A-Za-z0-9_-]"), "_")

    private fun lyricsEditorFocused(): Boolean {
        return composeRule.onNodeWithTag("lyricsEditor")
            .fetchSemanticsNode()
            .config
            .getOrNull(SemanticsProperties.Focused) == true
    }

    private fun createSavedSong(title: String) {
        openNewSong()
        composeRule.onNodeWithTag("songTitleEditor").performTextInput(title)
        composeRule.waitUntil(timeoutMillis = 3_000) {
            var projectSaved = false
            scenario?.onActivity { activity ->
                projectSaved = ViewModelProvider(activity)[MainViewModel::class.java]
                    .projects
                    .any { it.title == title }
            }
            projectSaved
        }
    }

    private fun openNewSong() {
        composeRule.onNodeWithText("New Song").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithTag("lyricsEditor").fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun setEmulatorNetworkEnabled(enabled: Boolean) {
        if (enabled) {
            shell("cmd connectivity airplane-mode disable")
            shell("svc wifi enable")
            shell("svc data enable")
        } else {
            shell("svc wifi disable")
            shell("svc data disable")
            shell("cmd connectivity airplane-mode enable")
        }
    }

    private fun setFontScale(scale: Float) {
        check(previousFontScale == null) { "Font scale was already changed by this test" }
        previousFontScale = shell("settings get system font_scale").trim()
        shell("settings put system font_scale $scale")
    }

    private fun restoreFontScale() {
        val previous = previousFontScale ?: return
        if (previous == "null") {
            shell("settings delete system font_scale")
        } else {
            shell("settings put system font_scale $previous")
        }
        previousFontScale = null
    }

    private fun setAnimatorDurationScale(scale: Float) {
        check(previousAnimatorDurationScale == null) {
            "Animator duration scale was already changed by this test"
        }
        previousAnimatorDurationScale = shell("settings get global animator_duration_scale").trim()
        shell("settings put global animator_duration_scale $scale")
    }

    private fun restoreAnimatorDurationScale() {
        val previous = previousAnimatorDurationScale ?: return
        if (previous == "null") {
            shell("settings delete global animator_duration_scale")
        } else {
            shell("settings put global animator_duration_scale $previous")
        }
        previousAnimatorDurationScale = null
    }

    private fun relaunchActivity() {
        scenario?.close()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        composeRule.waitForIdle()
    }

    private fun imeBottomPx(): Int {
        var bottom = 0
        scenario?.onActivity { activity ->
            bottom = ViewCompat.getRootWindowInsets(activity.window.decorView)
                ?.getInsets(WindowInsetsCompat.Type.ime())
                ?.bottom ?: 0
        }
        return bottom
    }

    private fun decorHeightPx(): Int {
        var height = 0
        scenario?.onActivity { activity -> height = activity.window.decorView.height }
        return height
    }

    private fun shell(command: String): String {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        return ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(command)).use {
            it.readBytes().toString(Charsets.UTF_8)
        }
    }
}
