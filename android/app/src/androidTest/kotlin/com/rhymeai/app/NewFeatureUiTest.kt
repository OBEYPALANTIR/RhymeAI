package com.rhymeai.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextInputSelection
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.TextRange
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rhymeai.app.util.PronunciationDictionary
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NewFeatureUiTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    private lateinit var scenario: ActivityScenario<MainActivity>

    @Before
    fun setUp() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        context.assets.open("cmudict-rhymeai.tsv").use(PronunciationDictionary::initialize)
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    @After
    fun tearDown() {
        scenario.close()
    }

    @Test
    fun movingSongToTrashShowsFullPageTrashBinAndRestoreActions() {
        createSavedSong(title = "UI Trash Song")

        composeRule.onNodeWithContentDescription("Open songs drawer").performClick()
        composeRule.onNodeWithContentDescription("Delete UI Trash Song").performClick()
        composeRule.onNodeWithText("Move to Trash").performClick()
        composeRule.onNodeWithContentDescription("Open Trash Bin").performClick()

        composeRule.onNodeWithText("Trash").assertIsDisplayed()
        composeRule.onNodeWithText("UI Trash Song").assertIsDisplayed()
        composeRule.onNode(hasText("30 days left", substring = true)).assertIsDisplayed()

        composeRule.onNodeWithText("UI Trash Song").performClick()
        composeRule.onNodeWithText("Restore").assertIsEnabled()
        composeRule.onNodeWithText("Delete").assertIsEnabled()
    }

    @Test
    fun stressAndIpaToggleRendersProsodyPreviewInAssistant() {
        composeRule.onNodeWithText("New Song").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performClick()
        composeRule.onNodeWithTag("lyricsEditor").performTextInput("[Verse]\nyellow music\nfollow music")

        composeRule.onNodeWithText("UnBlock").performClick()
        composeRule.onNodeWithText("Stress + IPA").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Toggle Stress + IPA").performScrollTo().performClick()

        composeRule.onNodeWithText("ˈDA da | ˈDA da").performScrollTo().assertIsDisplayed()
        composeRule.onNode(hasText("jɛloʊ", substring = true)).performScrollTo().assertIsDisplayed()
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun selectedRewriteDockPreservesNativeSelectionAndRootSafe() {
        composeRule.onNodeWithText("New Song").performClick()

        val lyrics = (1..12).joinToString("\n") { line ->
            "Testing selected rewrite placement line $line"
        }
        val selectionStart = lyrics.indexOf("line 12")
        val selectionEnd = selectionStart + "line 12".length

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
    }

    private fun createSavedSong(title: String) {
        composeRule.onNodeWithText("New Song").performClick()
        composeRule.onNodeWithTag("songTitleEditor").performTextInput(title)
        composeRule.waitUntil(timeoutMillis = 3_000) {
            composeRule.onAllNodesWithText("Saved").fetchSemanticsNodes().isNotEmpty()
        }
    }
}
