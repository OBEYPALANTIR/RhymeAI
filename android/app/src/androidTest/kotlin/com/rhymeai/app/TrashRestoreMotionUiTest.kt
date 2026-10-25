package com.rhymeai.app

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
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
