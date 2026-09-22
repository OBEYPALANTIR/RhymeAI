package com.rhymeai.app

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertDoesNotExist
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rhymeai.app.ui.components.TemplatesDialog
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TemplatesSheetUiTest {
    @get:Rule val composeRule = createComposeRule()

    private var shown by mutableStateOf(true)
    private var selections = 0
    private var dismissals = 0

    private fun showFixture() {
        composeRule.setContent {
            MaterialTheme {
                TextButton(onClick = { shown = true }) { Text("Open templates") }
                if (shown) {
                    TemplatesDialog(
                        onSelectTemplate = { _, _, _ -> selections++; shown = false },
                        onDismiss = { dismissals++; shown = false }
                    )
                }
            }
        }
        composeRule.onNodeWithText("Choose a Template").assertIsDisplayed()
    }

    @Test
    fun selectingWaitsForHideAndCloseDoesNotReplacePendingSelection() {
        showFixture()
        composeRule.mainClock.autoAdvance = false
        composeRule.onNodeWithText("Pop Song").performClick()
        composeRule.onNodeWithContentDescription("Close").performClick()
        composeRule.runOnIdle {
            assertEquals(0, selections)
            assertEquals(0, dismissals)
        }
        composeRule.mainClock.advanceTimeBy(1_000)
        composeRule.waitForIdle()
        composeRule.runOnIdle {
            assertEquals(1, selections)
            assertEquals(1, dismissals)
        }
        composeRule.onNodeWithText("Choose a Template").assertDoesNotExist()
    }

    @Test
    fun closeCompletesBeforeRemovalAndSheetCanReopen() {
        showFixture()
        composeRule.mainClock.autoAdvance = false
        composeRule.onNodeWithContentDescription("Close").performClick()
        composeRule.runOnIdle { assertEquals(0, dismissals) }
        composeRule.mainClock.advanceTimeBy(1_000)
        composeRule.waitForIdle()
        composeRule.runOnIdle { assertEquals(1, dismissals) }
        composeRule.onNodeWithText("Choose a Template").assertDoesNotExist()
        composeRule.mainClock.autoAdvance = true
        composeRule.onNodeWithText("Open templates").performClick()
        composeRule.onNodeWithText("Choose a Template").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Close").performClick()
        composeRule.waitForIdle()
        composeRule.runOnIdle {
            assertEquals(2, dismissals)
            assertEquals(0, selections)
        }
    }
}
