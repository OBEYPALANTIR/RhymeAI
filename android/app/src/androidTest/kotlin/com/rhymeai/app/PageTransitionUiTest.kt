package com.rhymeai.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PageTransitionUiTest {
    @get:Rule val composeRule = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null

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
    fun templatesRemainStationaryAndDismissWithTheirScrim() {
        composeRule.onNodeWithText("Song Templates").assertIsDisplayed()
        composeRule.mainClock.autoAdvance = false
        composeRule.onNodeWithText("Song Templates").performClick()
        composeRule.mainClock.advanceTimeBy(64)
        val entering = composeRule.onNodeWithText("Choose a Template").getUnclippedBoundsInRoot()
        composeRule.mainClock.advanceTimeBy(240)
        val settled = composeRule.onNodeWithText("Choose a Template").getUnclippedBoundsInRoot()
        assertEquals(settled.left.value, entering.left.value, 0.5f)
        assertEquals(settled.top.value, entering.top.value, 0.5f)
        composeRule.onNodeWithContentDescription("Close").performClick()
        composeRule.mainClock.advanceTimeBy(32)
        composeRule.onNodeWithText("Choose a Template").assertExists()
        composeRule.mainClock.advanceTimeBy(240)
        composeRule.onNodeWithText("Choose a Template").assertDoesNotExist()
        composeRule.onNodeWithText("Song Templates").assertIsDisplayed()
    }
}
