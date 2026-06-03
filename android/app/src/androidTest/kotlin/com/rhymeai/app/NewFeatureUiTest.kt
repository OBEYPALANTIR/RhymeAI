package com.rhymeai.app

import android.content.ContentValues
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
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
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.TextRange
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.lifecycle.ViewModelProvider
import com.rhymeai.app.data.model.RewriteAction
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

    private var scenario: ActivityScenario<MainActivity>? = null

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
        scenario?.close()
        scenario = null
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

    @Test
    fun assistantStopCancelsSuggestionRequest() {
        composeRule.onNodeWithText("New Song").performClick()
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
        setEmulatorNetworkEnabled(false)
        try {
            composeRule.onNodeWithText("New Song").performClick()
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

    private fun captureRootScreenshot(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RhymeAI-Test")
        }
        val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: error("Could not create screenshot media row for $name")
        context.contentResolver.openOutputStream(uri).use { output ->
            requireNotNull(output) { "Could not open screenshot output stream for $name" }
            composeRule.onRoot().captureToImage().asAndroidBitmap()
                .compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output)
        }
        println("SCREENSHOT_PATH /sdcard/Pictures/RhymeAI-Test/$name")
    }

    private fun lyricsEditorFocused(): Boolean {
        return composeRule.onNodeWithTag("lyricsEditor")
            .fetchSemanticsNode()
            .config
            .getOrNull(SemanticsProperties.Focused) == true
    }

    private fun createSavedSong(title: String) {
        composeRule.onNodeWithText("New Song").performClick()
        composeRule.onNodeWithTag("songTitleEditor").performTextInput(title)
        composeRule.waitUntil(timeoutMillis = 3_000) {
            composeRule.onAllNodesWithText("Saved").fetchSemanticsNodes().isNotEmpty()
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

    private fun shell(command: String) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(command)).use {
            it.readBytes()
        }
    }
}
