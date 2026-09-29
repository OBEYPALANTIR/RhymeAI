package com.rhymeai.app

import android.graphics.Rect
import android.util.Log
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.SONG_TEMPLATES
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.components.TemplateSheetOffsetPx
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs
import kotlin.math.min

@RunWith(AndroidJUnit4::class)
class PageTransitionUiTest {
    @get:Rule val composeRule = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null

    private data class SheetSample(
        val offsetPx: Float,
        val headingXInsidePx: Float,
        val headingYInsidePx: Float,
        val widthPx: Int,
        val heightPx: Int,
        val surfaceLeftPx: Float,
        val surfaceTopPx: Float,
        val windowLeftPx: Float,
        val windowTopPx: Float,
        val windowWidthPx: Int,
        val windowHeightPx: Int
    ) {
        val topPx get() = surfaceTopPx + offsetPx
        val bottomPx get() = topPx + heightPx
        val windowRightPx get() = windowLeftPx + windowWidthPx
        val windowBottomPx get() = windowTopPx + windowHeightPx
    }

    private fun sheetSample(): SheetSample {
        val surface = composeRule.onNodeWithTag("templatesSheetSurface").fetchSemanticsNode()
        val root = generateSequence(surface) { it.parent }.last()
        val heading = composeRule.onNodeWithText("Choose a Template").fetchSemanticsNode()
        val offset = surface.config[TemplateSheetOffsetPx]
        assertTrue("Sheet offset must be laid out", offset.isFinite())
        return SheetSample(
            offset,
            heading.positionOnScreen.x - surface.positionOnScreen.x,
            heading.positionOnScreen.y - surface.positionOnScreen.y - offset,
            surface.size.width,
            surface.size.height,
            surface.positionOnScreen.x,
            surface.positionOnScreen.y,
            root.positionOnScreen.x,
            root.positionOnScreen.y,
            root.size.width,
            root.size.height
        )
    }

    @Before
    fun launch() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    @After
    fun close() {
        composeRule.mainClock.autoAdvance = true
        scenario?.close()
    }

    @Test
    fun settingsRemainsStationaryAndDismissesAfterFade() {
        composeRule.onNodeWithText("New Song").performClick()
        composeRule.onNodeWithContentDescription("Song actions").assertIsDisplayed()
        composeRule.mainClock.autoAdvance = false
        composeRule.onNodeWithContentDescription("Song actions").performClick()
        composeRule.mainClock.advanceTimeBy(160)
        composeRule.onNodeWithText("Settings").performClick()
        composeRule.mainClock.advanceTimeBy(64)
        val entering = composeRule.onNodeWithContentDescription("Close").getUnclippedBoundsInRoot()
        composeRule.mainClock.advanceTimeBy(240)
        val settled = composeRule.onNodeWithContentDescription("Close").getUnclippedBoundsInRoot()
        assertEquals(settled.left.value, entering.left.value, 0.5f)
        assertEquals(settled.top.value, entering.top.value, 0.5f)
        composeRule.onNodeWithContentDescription("Close").performClick()
        composeRule.mainClock.advanceTimeBy(32)
        composeRule.onNodeWithContentDescription("Settings page").assertExists()
        composeRule.mainClock.advanceTimeBy(240)
        composeRule.onNodeWithContentDescription("Settings page").assertDoesNotExist()
        composeRule.onNodeWithContentDescription("Song actions").assertIsDisplayed()
    }

    @Test
    fun templatesRiseFromBottomWithStableContentAndCloseBackToWelcome() {
        composeRule.onNodeWithText("Song Templates").assertIsDisplayed()
        val activityWindow = Rect()
        scenario!!.onActivity {
            activityWindow.set(it.windowManager.currentWindowMetrics.bounds)
        }
        val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
        val tolerancePx = density * 0.5f
        composeRule.mainClock.autoAdvance = false
        composeRule.onNodeWithText("Song Templates").performClick()
        val entrySamples = mutableListOf<SheetSample>()
        var settledFrames = 0
        // A bounded 2 s observation, not a specified native animation duration.
        for (step in 0 until 125) {
            composeRule.mainClock.advanceTimeBy(16)
            composeRule.waitForIdle()
            val sample = sheetSample()
            entrySamples += sample
            val expandedTop = sample.windowBottomPx - sample.heightPx
            settledFrames = if (abs(sample.topPx - expandedTop) <= tolerancePx) settledFrames + 1 else 0
            if (settledFrames >= 3) break
        }
        assertTrue("Sheet did not settle at its bottom anchor: $entrySamples", settledFrames >= 3)
        val entry = entrySamples.first()
        val settled = entrySamples.last()
        Log.i("TemplateGeometry", "window=$activityWindow entryOffsets=${entrySamples.map { it.offsetPx }}")
        // The modal semantics root is the sheet window; this checks the edge-to-edge
        // coordinate transform before comparing native offsets with window bounds.
        assertEquals(activityWindow.left.toFloat(), settled.windowLeftPx, tolerancePx)
        assertEquals(activityWindow.top.toFloat(), settled.windowTopPx, tolerancePx)
        assertEquals(activityWindow.width(), settled.windowWidthPx)
        assertEquals(activityWindow.height(), settled.windowHeightPx)
        assertTrue("Sheet must rise from below: $entrySamples", entry.offsetPx > settled.offsetPx + tolerancePx)
        assertEquals("Sheet entry should start at the window bottom", entry.windowBottomPx, entry.topPx, tolerancePx)
        assertTrue("Sheet entry reversed its native travel: $entrySamples", entrySamples.zipWithNext().all { (a, b) -> b.offsetPx <= a.offsetPx + tolerancePx })
        assertTrue("Sheet must have positive size: $settled", settled.widthPx > 0 && settled.heightPx > 0)
        assertEquals(min(settled.windowWidthPx.toFloat(), DesignTokens.Drawer.expandedWidth.value * density), settled.widthPx.toFloat(), tolerancePx)
        assertTrue("Sheet left must fit its window: $settled", settled.surfaceLeftPx >= settled.windowLeftPx - tolerancePx)
        assertTrue("Sheet right must fit its window: $settled", settled.surfaceLeftPx + settled.widthPx <= settled.windowRightPx + tolerancePx)
        assertTrue("Sheet top must fit its window: $settled", settled.topPx >= settled.windowTopPx - tolerancePx)
        assertEquals("Settled sheet must meet the window bottom", settled.windowBottomPx, settled.bottomPx, tolerancePx)
        entrySamples.forEach { sample ->
            assertEquals(settled.windowLeftPx, sample.windowLeftPx, tolerancePx)
            assertEquals(settled.windowTopPx, sample.windowTopPx, tolerancePx)
            assertEquals(settled.windowWidthPx, sample.windowWidthPx)
            assertEquals(settled.windowHeightPx, sample.windowHeightPx)
            assertEquals("Heading x within sheet: $entrySamples", settled.headingXInsidePx, sample.headingXInsidePx, tolerancePx)
            assertEquals("Heading y within sheet: $entrySamples", settled.headingYInsidePx, sample.headingYInsidePx, tolerancePx)
        }

        composeRule.onNodeWithContentDescription("Close").performClick()
        val exitSamples = mutableListOf<SheetSample>()
        var removed = false
        for (step in 0 until 125) {
            composeRule.mainClock.advanceTimeBy(16)
            composeRule.waitForIdle()
            if (composeRule.onAllNodesWithTag("templatesSheetSurface").fetchSemanticsNodes().isEmpty()) {
                removed = true
                break
            }
            val sample = sheetSample()
            exitSamples += sample
            assertEquals(settled.windowLeftPx, sample.windowLeftPx, tolerancePx)
            assertEquals(settled.windowTopPx, sample.windowTopPx, tolerancePx)
            assertEquals(settled.windowWidthPx, sample.windowWidthPx)
            assertEquals(settled.windowHeightPx, sample.windowHeightPx)
            assertEquals("Heading x during dismissal: $exitSamples", settled.headingXInsidePx, sample.headingXInsidePx, tolerancePx)
            assertEquals("Heading y during dismissal: $exitSamples", settled.headingYInsidePx, sample.headingYInsidePx, tolerancePx)
        }
        Log.i("TemplateGeometry", "exitOffsets=${exitSamples.map { it.offsetPx }} removed=$removed")
        assertTrue("Sheet did not finish hiding within the test timeout: $exitSamples", removed)
        assertTrue("Sheet did not move toward the bottom: $exitSamples", exitSamples.any { it.offsetPx > settled.offsetPx + tolerancePx })
        assertTrue("Sheet exit reversed its native travel: $exitSamples", exitSamples.zipWithNext().all { (a, b) -> b.offsetPx >= a.offsetPx - tolerancePx })
        composeRule.onNodeWithText("Choose a Template").assertDoesNotExist()
        composeRule.onNodeWithText("Song Templates").assertIsDisplayed()
        composeRule.mainClock.autoAdvance = true
        composeRule.onNodeWithText("Song Templates").performClick()
        composeRule.onNodeWithText("Choose a Template").assertIsDisplayed()
    }

    @Test
    fun templateSelectionOpensEditorWithSelectedContent() {
        composeRule.onNodeWithText("Song Templates").performClick()
        composeRule.onNodeWithText("Pop Song").performClick()
        var viewModel: MainViewModel? = null
        scenario!!.onActivity { viewModel = ViewModelProvider(it)[MainViewModel::class.java] }
        val template = SONG_TEMPLATES.first { it.name == "Pop Song" }
        composeRule.waitUntil(5_000) {
            viewModel?.let { it.title == "Untitled Pop Song" && it.lyrics == template.lyrics && !it.showStartMenu } == true
        }
        composeRule.onNodeWithTag("songTitleEditor").assertIsDisplayed()
        composeRule.onNodeWithText("Song Templates").assertDoesNotExist()
    }
}
