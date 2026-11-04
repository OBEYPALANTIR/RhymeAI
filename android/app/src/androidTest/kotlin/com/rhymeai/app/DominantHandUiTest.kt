package com.rhymeai.app

import android.app.Application
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rhymeai.app.data.model.DominantHand
import com.rhymeai.app.data.repository.ProjectRepository
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
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

    @Before
    fun setUp() {
        runBlocking { repository.saveDominantHand(DominantHand.LEFT) }
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    @After
    fun tearDown() {
        scenario?.close()
        scenario = null
        runBlocking { repository.saveDominantHand(DominantHand.RIGHT) }
    }

    @Test
    fun leftHandPutsTheMicOutermostOnTheLeftOfUnBlock() {
        composeRule.onNodeWithText("New Song").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithTag("micButton").fetchSemanticsNodes().isNotEmpty()
        }
        val mic = composeRule.onNodeWithTag("micButton").getUnclippedBoundsInRoot()
        val unBlock = composeRule.onNodeWithTag("unBlockAction").getUnclippedBoundsInRoot()
        assertTrue("mic $mic should sit left of UnBlock $unBlock", mic.right <= unBlock.left)
        // The cluster hugs the left edge (21dp in), not the right.
        assertTrue("mic should start near the left edge, was at ${mic.left}", mic.left.value < 40f)
    }
}
