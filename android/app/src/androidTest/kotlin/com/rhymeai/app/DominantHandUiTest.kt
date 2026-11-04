package com.rhymeai.app

import android.app.Application
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.DpRect
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rhymeai.app.data.model.DominantHand
import com.rhymeai.app.data.repository.ProjectRepository
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DominantHandUiTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val app: Application = ApplicationProvider.getApplicationContext()
    private val repository = ProjectRepository(app)
    private var scenario: ActivityScenario<MainActivity>? = null

    @After
    fun tearDown() {
        scenario?.close()
        scenario = null
        runBlocking { repository.saveDominantHand(DominantHand.RIGHT) }
    }

    @Test
    fun leftHandPutsTheRoundButtonsOutermostOnTheLeft() {
        launchWith(DominantHand.LEFT)
        openEditor()
        assertCluster(DominantHand.LEFT, round = bounds(tag = "micButton"), pill = bounds(tag = "unBlockAction"))
        openOneLiners()
        assertCluster(DominantHand.LEFT, round = bounds(description = "Type a one liner"), pill = bounds(description = "Record a one liner"))
    }

    @Test
    fun rightHandPutsTheRoundButtonsOutermostOnTheRight() {
        launchWith(DominantHand.RIGHT)
        openEditor()
        assertCluster(DominantHand.RIGHT, round = bounds(tag = "micButton"), pill = bounds(tag = "unBlockAction"))
        openOneLiners()
        assertCluster(DominantHand.RIGHT, round = bounds(description = "Type a one liner"), pill = bounds(description = "Record a one liner"))
    }

    @Test
    fun settingsControlMovesTheEditorChromeAndPersists() {
        launchWith(DominantHand.RIGHT)
        openEditor()
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithText("Settings").performClick()
        composeRule.onNode(hasText("Editor") and hasClickAction()).performClick()
        composeRule.onNode(hasText("Left") and hasClickAction()).performClick()
        composeRule.onNodeWithContentDescription("Close").performClick()
        waitFor { composeRule.onAllNodesWithTag("micButton").fetchSemanticsNodes().isNotEmpty() }

        assertCluster(DominantHand.LEFT, round = bounds(tag = "micButton"), pill = bounds(tag = "unBlockAction"))
        runBlocking { withTimeout(5_000) { repository.dominantHandFlow.first { it == DominantHand.LEFT } } }
    }

    private fun launchWith(hand: DominantHand) {
        runBlocking { repository.saveDominantHand(hand) }
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    private fun openEditor() {
        composeRule.onNodeWithText("New Song").performClick()
        waitFor { composeRule.onAllNodesWithTag("micButton").fetchSemanticsNodes().isNotEmpty() }
    }

    private fun openOneLiners() {
        composeRule.onNodeWithContentDescription("One Liners").performClick()
        waitFor { composeRule.onAllNodesWithContentDescription("Type a one liner").fetchSemanticsNodes().isNotEmpty() }
    }

    private fun waitFor(condition: () -> Boolean) = composeRule.waitUntil(timeoutMillis = 5_000, condition = condition)

    private fun bounds(tag: String? = null, description: String? = null): DpRect =
        (if (tag != null) composeRule.onNodeWithTag(tag) else composeRule.onNodeWithContentDescription(description!!))
            .getUnclippedBoundsInRoot()

    /** The round button sits outside the pill, within 40dp of the hand's edge, fully on screen. */
    private fun assertCluster(hand: DominantHand, round: DpRect, pill: DpRect) {
        val width = composeRule.onRoot().getUnclippedBoundsInRoot().right
        listOf(round, pill).forEach {
            assertTrue("$it should be on screen (width $width)", it.left.value >= 0f && it.right <= width)
        }
        if (hand == DominantHand.LEFT) {
            assertTrue("round $round should sit left of pill $pill", round.right <= pill.left)
            assertTrue("round should hug the left edge, was at ${round.left}", round.left.value < 40f)
        } else {
            assertTrue("round $round should sit right of pill $pill", round.left >= pill.right)
            assertTrue("round should hug the right edge, ended at ${round.right} of $width", (width - round.right).value < 40f)
        }
    }
}
