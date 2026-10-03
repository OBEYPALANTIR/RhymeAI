package com.rhymeai.app

import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import com.rhymeai.app.ui.components.SlidingSegmentedControl
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.RhymeAITheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Rendered intermediate positions distinguish travel from an instant swap. */
class MotionRestorationUiTest {
    @get:Rule val compose = createComposeRule()

    @Test fun selectionTravelsAndCanReverseBeforeSettling() = exercise(true)
    @Test fun reducedMotionSelectionChangesImmediately() = exercise(false)

    private fun exercise(animations: Boolean) {
        val selected = mutableIntStateOf(0)
        compose.setContent {
            RhymeAITheme {
                CompositionLocalProvider(LocalAnimationsEnabled provides animations) {
                    SlidingSegmentedControl(listOf("First", "Second", "Third"), selected.intValue,
                        { selected.intValue = it }, Modifier.width(300.dp).testTag("picker"))
                }
            }
        }
        compose.waitForIdle()
        val start = highlightCenter()
        compose.mainClock.autoAdvance = false
        compose.onNodeWithText("Third").performClick()
        compose.mainClock.advanceTimeBy(64)
        val during = highlightCenter()
        compose.mainClock.advanceTimeBy(1500)
        val end = highlightCenter()
        if (animations) {
            assertTrue("Highlight must travel between cells: $start / $during / $end",
                during > start + 2 && during < end - 2)
            compose.onNodeWithText("First").performClick()
            compose.mainClock.advanceTimeBy(64)
            val returning = highlightCenter()
            assertTrue(returning < end - 2 && returning > start + 2)
            compose.onNodeWithText("Third").performClick()
            compose.mainClock.advanceTimeBy(1500)
            assertTrue(kotlin.math.abs(highlightCenter() - end) < 2)
        } else {
            assertTrue("Reduced motion must use immediate selection", kotlin.math.abs(during - end) < 2)
        }
        compose.mainClock.autoAdvance = true
    }

    private fun highlightCenter(): Double {
        val pixels = compose.onNodeWithTag("picker").captureToImage().toPixelMap()
        // Sample below text, through the dark Ink selection fill.
        val y = (pixels.height * 0.72).toInt()
        val xs = (0 until pixels.width).filter { x ->
            val p = pixels[x, y]
            p.red < 0.3f && p.green < 0.3f && p.blue < 0.3f
        }
        assertTrue("Expected visible selection fill", xs.size > pixels.width / 6)
        return xs.average()
    }
}
