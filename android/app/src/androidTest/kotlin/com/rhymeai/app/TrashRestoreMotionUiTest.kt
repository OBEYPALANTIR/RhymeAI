package com.rhymeai.app

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.ui.components.ProjectsDrawer
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.RhymeAITheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Restore from Trash: the row leaves on the dismiss tier and the drawer's snackbar says so. */
class TrashRestoreMotionUiTest {
    @get:Rule val compose = createComposeRule()

    private val harbour = SongProject(title = "Harbour Lights")
    private val paper = SongProject(title = "Paper Moon")
    private val trashed = mutableStateOf(listOf(TrashedSongProject(harbour, 2_000L), TrashedSongProject(paper, 1_000L)))
    private var opened: SongProject? = null

    private fun showTrash(animations: Boolean) {
        compose.setContent {
            RhymeAITheme {
                CompositionLocalProvider(LocalAnimationsEnabled provides animations) {
                    ProjectsDrawer(
                        projects = emptyList(),
                        trashedProjects = trashed.value,
                        currentProjectId = null,
                        onLoadProject = { opened = it },
                        onNewProject = {},
                        onDeleteProject = { _, _ -> },
                        onRestoreProject = { id, onCommitted ->
                            trashed.value = trashed.value.filterNot { it.project.id == id }
                            onCommitted(true)
                        },
                        onPermanentlyDeleteProject = {},
                        onPurgeExpiredTrash = {},
                        onRecordingPurgeIncomplete = {},
                        onImportProject = {},
                        onDismiss = {}
                    )
                }
            }
        }
        compose.onNodeWithContentDescription("Open Trash Bin").performClick()
        compose.onNodeWithText("Harbour Lights").assertIsDisplayed()
    }

    private fun paperMoonTop() = compose.onNodeWithText("Paper Moon").getUnclippedBoundsInRoot().top.value

    @Test fun restoredRowLeavesOnTheDismissTierAndTheRowBelowClosesTheGapOnTheSpring() {
        showTrash(animations = true)
        val before = paperMoonTop()
        compose.onNodeWithText("Harbour Lights").performClick()
        compose.mainClock.autoAdvance = false
        compose.onNodeWithText("Restore").performClick()
        compose.mainClock.advanceTimeBy(48)
        val closing = paperMoonTop()
        compose.mainClock.advanceTimeBy(600)
        val settled = paperMoonTop()
        assertTrue("Row below must travel up on the spring: $before / $closing / $settled", settled < before - 2 && closing < before - 2 && closing > settled + 2)
        compose.onNodeWithText("Harbour Lights").assertDoesNotExist()
        compose.onNodeWithText("Restored “Harbour Lights”").assertIsDisplayed()
        compose.onNodeWithText("Open").performClick()
        compose.mainClock.advanceTimeBy(400)
        assertEquals(harbour, opened)
        compose.mainClock.autoAdvance = true
    }

    /** The bottom row has no successor moving into its bounds, so its own pixels can be watched leaving. */
    @Test fun restoredBottomRowFadesOutOverTheDismissTier() {
        showTrash(animations = true)
        val bounds = compose.onNodeWithText("Paper Moon").getBoundsInRoot()
        compose.onNodeWithText("Paper Moon").performClick()
        compose.waitForIdle()
        // The tap's ripple settles in real time; sample the resting row after it.
        Thread.sleep(700)
        compose.mainClock.autoAdvance = false
        val before = ink(bounds)
        compose.onNodeWithText("Restore").performClick()
        compose.mainClock.advanceTimeBy(96)
        val leaving = ink(bounds)
        compose.mainClock.advanceTimeBy(600)
        val gone = ink(bounds)
        assertTrue("Row must fade, not snap: $before / $leaving / $gone", leaving < before && leaving > gone)
        compose.onNodeWithText("Paper Moon").assertDoesNotExist()
        compose.onNodeWithText("Harbour Lights").assertIsDisplayed()
        compose.mainClock.autoAdvance = true
    }

    /** Mean darkness of a root-relative region (1 = all ink). */
    private fun ink(bounds: androidx.compose.ui.unit.DpRect): Double {
        // The test clock is paused; the renderer still needs a real vsync to present the last frame.
        Thread.sleep(48)
        val pixels = compose.onRoot().captureToImage().toPixelMap()
        val d = compose.density.density
        val x0 = (bounds.left.value * d).toInt().coerceIn(0, pixels.width - 1); val x1 = (bounds.right.value * d).toInt().coerceIn(x0 + 1, pixels.width)
        val y0 = (bounds.top.value * d).toInt().coerceIn(0, pixels.height - 1); val y1 = (bounds.bottom.value * d).toInt().coerceIn(y0 + 1, pixels.height)
        var sum = 0.0
        for (y in y0 until y1) for (x in x0 until x1) {
            val p = pixels[x, y]; sum += 1f - (0.299f * p.red + 0.587f * p.green + 0.114f * p.blue)
        }
        return sum / ((y1 - y0) * (x1 - x0))
    }

    @Test fun reducedMotionRemovesRestoredRowsInOneFrameAndNamesTheEmptyTrash() {
        showTrash(animations = false)
        compose.onNodeWithText("Harbour Lights").performClick()
        compose.onNodeWithText("Paper Moon").performClick()
        compose.mainClock.autoAdvance = false
        compose.onNodeWithText("Restore").performClick()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Harbour Lights").assertDoesNotExist()
        compose.onNodeWithText("Paper Moon").assertDoesNotExist()
        compose.onNodeWithText("No songs in the Trash Bin.").assertIsDisplayed()
        compose.onNodeWithText("Deleted songs stay here for 30 days.").assertIsDisplayed()
        compose.mainClock.advanceTimeBy(400)
        compose.onNodeWithText("2 songs restored").assertIsDisplayed()
        compose.mainClock.autoAdvance = true
    }
}
