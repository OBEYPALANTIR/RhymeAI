package com.rhymeai.app

import android.os.SystemClock
import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.ViewModelProvider
import kotlinx.coroutines.CompletableDeferred
import com.rhymeai.app.ui.screens.EditorInsertionHighlightAlpha
import com.rhymeai.app.ui.screens.EditorOpenSettleAlpha
import com.rhymeai.app.ui.screens.EditorScreen
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.RhymeAITheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Rule
import org.junit.Test

/**
 * The real editor against the real view model: a song opening cross-fades the writing column,
 * New Song puts the caret in the title, and a used line's highlight dries instead of switching off.
 */
@OptIn(ExperimentalTestApi::class)
class SongOpenSettleUiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private lateinit var vm: MainViewModel
    private val draft = "The ropes drip water on the train"

    @After fun releaseHooks() { SongOpenTestHooks.beforeSwap?.complete(Unit); SongOpenTestHooks.beforeSwap = null }

    private fun showEditor(animations: Boolean) {
        compose.activityRule.scenario.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
        compose.waitUntil(10_000) { vm.appearanceLoaded && !vm.restoringDraft }
        compose.runOnIdle { vm.seedEditorForTesting("Harbour Lights", draft, TextRange(draft.length)) }
        compose.setContent {
            RhymeAITheme {
                CompositionLocalProvider(LocalAnimationsEnabled provides animations) {
                    EditorScreen(viewModel = vm)
                }
            }
        }
        compose.onNodeWithTag("songTitleEditor").assertIsDisplayed()
    }

    private fun settleAlpha() =
        compose.onNodeWithTag("editorScrollContainer").fetchSemanticsNode().config[EditorOpenSettleAlpha]

    private fun highlightAlpha() =
        compose.onNodeWithTag("lyricsEditor").fetchSemanticsNode().config[EditorInsertionHighlightAlpha]

    /** Steps the paused clock one frame at a time while the view model finishes its work. */
    private fun stepUntil(what: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (!condition()) {
            check(SystemClock.uptimeMillis() < deadline) { "Timed out waiting for $what" }
            compose.mainClock.advanceTimeByFrame()
        }
    }

    @Test fun openingAnotherSongCrossFadesTheWritingColumnOnTheStateTier() {
        showEditor(animations = true)
        assertEquals(1f, settleAlpha(), 0f)
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { vm.applyTemplate("Pop Song", "", "We folded every promise twice") }
        stepUntil("the template to open") { vm.title == "Untitled Pop Song" }
        compose.mainClock.advanceTimeByFrame()
        val entering = settleAlpha()
        compose.mainClock.advanceTimeBy(64)
        val during = settleAlpha()
        compose.mainClock.advanceTimeBy(600)
        val settled = settleAlpha()
        assertTrue("Incoming column must fade in: $entering / $during / $settled", entering < 0.5f && during > entering && during < 1f)
        assertEquals(1f, settled, 0.001f)
        compose.mainClock.autoAdvance = true
    }

    @Test fun openingASavedSongFadesTheColumnOutThenInAgain() {
        showEditor(animations = true)
        // Save one song and start another, so a saved song opens while a different one is on screen.
        compose.runOnUiThread { vm.applyTemplate("Pop Song", "", "We folded every promise twice") }
        compose.waitUntil(10_000) { vm.projects.any { it.title == "Untitled Pop Song" } }
        val saved = vm.projects.first { it.title == "Untitled Pop Song" }
        compose.runOnUiThread { vm.applyTemplate("Ballad", "", draft) }
        compose.waitUntil(10_000) { vm.title == "Untitled Ballad" }
        compose.mainClock.autoAdvance = false
        // Let the syllable analysis land before sampling the resting ink.
        compose.mainClock.advanceTimeBy(600)
        val restingInk = columnInk()
        // Hold the swap so the leaving column can be sampled; the beat itself runs in real time.
        val hold = CompletableDeferred<Unit>()
        SongOpenTestHooks.beforeSwap = hold
        compose.runOnUiThread { vm.loadProject(saved) }
        stepUntil("the column to start leaving") { settleAlpha() < 1f }
        val leaving = settleAlpha()
        compose.mainClock.advanceTimeBy(48)
        val leavingInk = columnInk()
        val leavingTitle = vm.title
        SongOpenTestHooks.beforeSwap = null
        hold.complete(Unit)
        stepUntil("the saved song to open") { vm.title == "Untitled Pop Song" }
        compose.mainClock.advanceTimeByFrame()
        val arriving = settleAlpha()
        val arrivingInk = columnInk()
        compose.mainClock.advanceTimeBy(64)
        val duringInk = columnInk()
        compose.mainClock.advanceTimeBy(600)
        val settledInk = columnInk()
        assertTrue("Column must fade out, then in: $leaving / $arriving", leaving < 1f && arriving < 0.5f)
        assertEquals(1f, settleAlpha(), 0.001f)
        // Rendered pixels, not just the probe: the old song's ink thins while it is still the old song,
        // the page is blank as the new song lands, and the new ink grows in.
        assertEquals("Sampled the leaving column while it still showed the old song", "Untitled Ballad", leavingTitle)
        assertTrue("Old ink must thin, not snap: $restingInk / $leavingInk / $arrivingInk", leavingInk < restingInk && leavingInk > arrivingInk)
        assertTrue("Ink must arrive gradually: $arrivingInk / $duringInk / $settledInk", arrivingInk < duringInk && duringInk < settledInk)
        compose.mainClock.autoAdvance = true
    }

    /** Darkness of the writing column's top rows (1 = all ink); the canvas is near white. */
    private fun columnInk(): Double {
        // The test clock is paused; the renderer still needs a real vsync to present the last frame.
        Thread.sleep(48)
        val pixels = compose.onNodeWithTag("editorScrollContainer").captureToImage().toPixelMap()
        val rows = minOf(pixels.height, 260)
        var sum = 0.0
        for (y in 0 until rows) for (x in 0 until pixels.width) {
            val p = pixels[x, y]
            sum += 1f - (0.299f * p.red + 0.587f * p.green + 0.114f * p.blue)
        }
        return sum / (rows * pixels.width)
    }

    @Test fun reducedMotionOpensAnotherSongInOneFrame() {
        showEditor(animations = false)
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread { vm.applyTemplate("Pop Song", "", "We folded every promise twice") }
        stepUntil("the template to open") { vm.title == "Untitled Pop Song" }
        compose.mainClock.advanceTimeByFrame()
        assertEquals(1f, settleAlpha(), 0f)
        compose.mainClock.autoAdvance = true
    }

    @Test fun newSongPutsTheCaretInTheTitle() {
        showEditor(animations = true)
        compose.runOnUiThread { vm.newProject() }
        compose.waitUntil(10_000) { vm.newSongOpenRevision == vm.openRevision && vm.title.isEmpty() }
        compose.onNodeWithTag("songTitleEditor").assertIsFocused()
    }

    @Test fun useLineHighlightHoldsTwoSecondsThenDriesOnTheSettleSpring() {
        showEditor(animations = true)
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread {
            vm.onLyricsChanged(TextFieldValue(draft, TextRange(draft.length)))
            vm.insertSuggestion("A gull cries out above the chain")
        }
        compose.mainClock.advanceTimeByFrame()
        assertEquals(1f, highlightAlpha(), 0f)
        // Sampled at the end of the hold, once the inserted line's syllable analysis (real-time work)
        // has been drawn, so only the fill differs between the samples.
        compose.mainClock.advanceTimeBy(1_900)
        Thread.sleep(600)
        compose.mainClock.advanceTimeByFrame()
        assertEquals("Held for the full two seconds", 1f, highlightAlpha(), 0f)
        val heldInk = lyricsInk()
        compose.mainClock.advanceTimeBy(100 + 48)
        val drying = highlightAlpha()
        compose.mainClock.advanceTimeBy(96)
        val drier = highlightAlpha()
        val dryingInk = lyricsInk()
        compose.mainClock.advanceTimeBy(1_500)
        val driedInk = lyricsInk()
        assertTrue("Highlight must fade rather than switch off: $drying / $drier", drying < 1f && drying > 0f && drier < drying)
        assertEquals(0f, highlightAlpha(), 0f)
        // Rendered pixels: the 12% fill makes the lyrics darker while held, less so while drying, not at all once dry.
        assertTrue("Fill must be drawn and dry away: $heldInk / $dryingInk / $driedInk", heldInk > dryingInk && dryingInk > driedInk)
        compose.mainClock.autoAdvance = true
    }

    /** Darkness of the lyrics field (1 = all ink); the insertion fill adds to it. */
    private fun lyricsInk(): Double {
        Thread.sleep(48)
        val pixels = compose.onNodeWithTag("lyricsEditor").captureToImage().toPixelMap()
        var sum = 0.0
        for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
            val p = pixels[x, y]
            sum += 1f - (0.299f * p.red + 0.587f * p.green + 0.114f * p.blue)
        }
        return sum / (pixels.height * pixels.width)
    }

    @Test fun reducedMotionClearsTheUseLineHighlightInOneFrame() {
        showEditor(animations = false)
        compose.mainClock.autoAdvance = false
        compose.runOnUiThread {
            vm.onLyricsChanged(TextFieldValue(draft, TextRange(draft.length)))
            vm.insertSuggestion("A gull cries out above the chain")
        }
        compose.mainClock.advanceTimeByFrame()
        assertEquals(1f, highlightAlpha(), 0f)
        compose.mainClock.advanceTimeBy(2_000 + 32)
        assertEquals(0f, highlightAlpha(), 0f)
        compose.mainClock.autoAdvance = true
    }
}
