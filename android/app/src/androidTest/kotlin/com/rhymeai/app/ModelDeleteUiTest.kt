package com.rhymeai.app

import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.ui.components.GEMMA_DOWNLOADS
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Through the real Activity, ViewModel and Settings: confirming Delete removes the file and the row offers Download. */
@OptIn(ExperimentalTestApi::class)
class ModelDeleteUiTest {
    @get:Rule val composeRule = createEmptyComposeRule()
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var vm: MainViewModel
    private val model = GEMMA_DOWNLOADS.first()
    private val installed = File(ApplicationProvider.getApplicationContext<android.content.Context>().filesDir, model.fileName)
    private var wroteFixture = false

    @Before fun launch() {
        // Never touch a real download; a stale (wrong-size) file stands in for an installed one.
        assumeFalse("a real model is installed on this device", installed.isFile && installed.length() > 1_000_000L)
        installed.writeBytes(ByteArray(32))
        wroteFixture = true
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
        composeRule.waitUntil(10_000) { vm.appearanceLoaded && vm.aiSettingsLoaded }
        composeRule.onNodeWithText("New Song").performScrollTo().performClick()
        composeRule.runOnIdle { vm.selectedProvider = AIProvider.LOCAL }
        composeRule.onNodeWithContentDescription("Song actions").performClick()
        composeRule.onNodeWithText("Settings", substring = false).performClick()
        composeRule.onNodeWithText("AI setup").performScrollTo().performClick()
    }

    @After fun cleanUp() {
        if (wroteFixture) installed.delete()
        if (::scenario.isInitialized) scenario.close()
    }

    @Test fun confirmingDeleteRemovesTheFileThroughTheViewModelAndTheRowOffersDownload() {
        deleteButton().performScrollTo().assertIsEnabled().performClick()
        composeRule.onNodeWithText("Delete ${model.label}?").assertIsDisplayed()
        composeRule.onNodeWithText("Delete").performClick()

        composeRule.waitUntil(10_000) { !installed.exists() && vm.gemmaDeletingModel == null }
        composeRule.onNodeWithText("Delete ${model.label}?").assertDoesNotExist()
        deleteButton().assertDoesNotExist()
        assertNull(vm.gemmaDownloadError)
        assertFalse(model.fileName in vm.verifiedGemmaFileNames)
        composeRule.onNode(hasText(model.label) and hasClickAction()).performScrollTo().assertIsEnabled()
        composeRule.onNodeWithText(model.description).assertIsDisplayed()
    }

    private fun deleteButton() = composeRule.onNodeWithContentDescription("Delete ${model.label}")
}
