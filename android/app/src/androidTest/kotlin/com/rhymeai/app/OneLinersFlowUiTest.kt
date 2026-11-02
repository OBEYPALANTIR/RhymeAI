package com.rhymeai.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.rhymeai.app.data.repository.OneLinersStore
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Songs drawer → One Liners card → Type → Save: the line lands in the pool with its prosody badge. */
@RunWith(AndroidJUnit4::class)
class OneLinersFlowUiTest {
    @get:Rule val composeRule = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null
    private var store: OneLinersStore? = null
    private val line = "Harbour lights ${System.nanoTime() % 100_000} on a paper sea"

    @Before
    fun launch() {
        scenario = ActivityScenario.launch(MainActivity::class.java).onActivity { activity ->
            store = ViewModelProvider(activity)[MainViewModel::class.java].oneLinersStore
        }
    }

    @After
    fun cleanUp() {
        // The device's pool is left as it was: the line this test made goes, Trash and all.
        runBlocking {
            store?.all()?.filter { it.text == line }?.forEach { saved ->
                store?.trash(saved.id)
                store?.permanentlyDelete(saved.id)
            }
        }
        scenario?.close()
    }

    @Test
    fun typedLineIsSavedFromTheDrawerCard() {
        composeRule.onNodeWithText("Load Song").performClick()
        composeRule.onNodeWithContentDescription("One Liners", substring = true).performClick()
        composeRule.onNodeWithTag("oneLinersScreen").assertIsDisplayed()

        composeRule.onNodeWithContentDescription("Type a one liner").performClick()
        composeRule.onNodeWithTag("oneLinerField").performTextInput(line)
        composeRule.onNodeWithText("Save").performClick()

        // The typed words are in the field too, so wait for the sheet to close before looking for the row.
        composeRule.waitUntil(5_000) { composeRule.onAllNodesWithTag("oneLinerCaptureSheet").fetchSemanticsNodes().isEmpty() }
        composeRule.onNodeWithText(line).assertIsDisplayed()
        val saved = runBlocking { store!!.all().single { it.text == line } }
        composeRule.onNodeWithText(saved.prosodyBadge).assertIsDisplayed()
        assertEquals("sea", saved.prosodyBadge.substringAfter("· "))
    }
}
