package com.rhymeai.app

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.text.TextRange
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.data.model.RewriteAction
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SongAnalysisInteractionUiTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null

    @Before
    fun setUp() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        composeRule.waitForIdle()
        if (composeRule.onAllNodesWithText("New Song").fetchSemanticsNodes().isNotEmpty()) {
            composeRule.onNodeWithText("New Song").performClick()
        }
        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java].apply {
                setAppAppearance(AppAppearance.INK)
                seedEditorForTesting(
                    title = "Analysis Interaction Fixture",
                    lyrics = TEST_LYRICS,
                    selection = TextRange(cursorInSecondLine())
                )
                useWholeSongContext = false
                isStressPreviewEnabled = false
                isHighlightEnabled = true
                isSyllableColoringEnabled = true
                isRhymeHighlightEnabled = false
                isBeatGridEnabled = false
            }
        }
    }

    @After
    fun tearDown() {
        scenario?.close()
        scenario = null
    }

    @Test
    fun creatingNewSongClearsAnActiveRewritePreview() {
        val start = TEST_LYRICS.indexOf("lanterns")
        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java]
                .seedRewritePreviewForTesting(
                    action = RewriteAction.REPHRASE,
                    range = TextRange(start, start + "lanterns".length),
                    original = "lanterns",
                    preview = "headlights"
                )
        }
        composeRule.onNodeWithTag("inlineRewriteReviewBar").assertIsDisplayed()

        composeRule.onNodeWithContentDescription("Open songs drawer").performClick()
        composeRule.onNodeWithText("Create New Song").performClick()

        check(composeRule.onAllNodesWithText("Previewing Rephrase", substring = true)
            .fetchSemanticsNodes().isEmpty())
        composeRule.onNodeWithTag("lyricsEditor").assertIsDisplayed()
    }

    @Test
    fun settingsSeparateLyricToolsFromAssistantToolsAndLabelTapTogglesTheGuide() {
        composeRule.onNodeWithContentDescription("Settings").performClick()
        composeRule.onNodeWithText("Editor").performClick()

        val settingsPage = composeRule.onNodeWithContentDescription("Settings page")
            .assertIsDisplayed()
            .fetchSemanticsNode()
            .config
        check(settingsPage[SemanticsProperties.PaneTitle] == "Settings")
        check(settingsPage.getOrNull(SemanticsActions.OnClick) == null)
        check(composeRule.onNodeWithText("Lyrics").fetchSemanticsNode().config
            .contains(SemanticsProperties.Heading))
        check(composeRule.onNodeWithText("Assistant").fetchSemanticsNode().config
            .contains(SemanticsProperties.Heading))
        composeRule.onNodeWithText("Changes save automatically").assertIsDisplayed()
        check(composeRule.onAllNodesWithText("Save Settings").fetchSemanticsNodes().isEmpty())

        composeRule.onNodeWithText("Syllable Guide").assertIsOn()
        composeRule.onNodeWithText("Syllable Guide").performClick()
        composeRule.onNodeWithText("Syllable Guide").assertIsOff()
    }

    @Test
    fun beatGridCommunicatesFitDurationAndNamedTempoControls() {
        scenario?.onActivity { activity ->
            ViewModelProvider(activity)[MainViewModel::class.java].apply {
                isBeatGridEnabled = true
                isStressPreviewEnabled = true
            }
        }

        composeRule.onNodeWithTag("unBlockAction").performClick()
        composeRule.onNodeWithText("BPM").performScrollTo()
        composeRule.onNodeWithContentDescription("Decrease BPM").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Increase BPM").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("BPM, 90").assertIsDisplayed()
        composeRule.onAllNodesWithText("Overflow · 4.7s", substring = true)[0]
            .performScrollTo()
            .assertIsDisplayed()
    }

    @Test
    fun assistantHidesEditorSemanticsAndAnnouncesItsPane() {
        composeRule.onNodeWithTag("unBlockAction").performClick()

        val assistant = composeRule.onNodeWithContentDescription("Assistant panel")
            .assertIsDisplayed()
            .fetchSemanticsNode()
            .config
        check(assistant[SemanticsProperties.PaneTitle] == "Assistant")
        check(composeRule.onAllNodesWithContentDescription("Settings").fetchSemanticsNodes().isEmpty())
        check(composeRule.onAllNodesWithContentDescription("Open songs drawer").fetchSemanticsNodes().isEmpty())
        composeRule.onNodeWithContentDescription("Close assistant").assertIsDisplayed()
    }

    private fun cursorInSecondLine(): Int = TEST_LYRICS.indexOf('\n') + 6

    private companion object {
        val TEST_LYRICS = """
            Paper lanterns mark the road
            Quiet engines hum below
            Silver windows catch the rain
            Morning calls us home again
        """.trimIndent()
    }
}
