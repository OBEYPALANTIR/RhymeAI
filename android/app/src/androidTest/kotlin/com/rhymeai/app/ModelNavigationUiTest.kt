package com.rhymeai.app

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.service.AIProvider
import java.io.File
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalTestApi::class)
class ModelNavigationUiTest {
    @get:Rule val composeRule = createEmptyComposeRule()
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var vm: MainViewModel

    @Before fun launch() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
        composeRule.waitUntil(10_000) { vm.appearanceLoaded }
        composeRule.onNodeWithText("New Song").performScrollTo().performClick()
        composeRule.runOnIdle {
            vm.selectedProvider = AIProvider.LOCAL
            vm.setAppAppearance(AppAppearance.GRAPHITE)
        }
        composeRule.onNodeWithTag("unBlockAction").performClick()
        composeRule.waitUntil(5_000) {
            composeRule.onNodeWithContentDescription("Assistant panel")
                .getUnclippedBoundsInRoot().top.value < 1f
        }
    }

    @After fun close() { scenario.close() }

    @Test fun setupCloseAndSystemBackReturnToSameAssistant() {
        composeRule.onNodeWithContentDescription("Expand context and theme", useUnmergedTree = true)
            .performTouchInput { click() }
        composeRule.onNodeWithContentDescription("Collapse context and theme").assertExists()
        composeRule.onNodeWithText("Set up model").performClick()
        composeRule.onNodeWithContentDescription("Settings page").assertIsDisplayed()
        composeRule.onNodeWithText("Paper").performClick()
        composeRule.onNodeWithContentDescription("Close").performClick()
        composeRule.onNodeWithContentDescription("Assistant panel").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Collapse context and theme").assertExists()
        composeRule.onNodeWithText("Set up model").performClick()
        assertTrue(InstrumentationRegistry.getInstrumentation().uiAutomation
            .performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK))
        composeRule.waitUntil(5_000) {
            composeRule.onAllNodesWithContentDescription("Settings page").fetchSemanticsNodes().isEmpty()
        }
        composeRule.onNodeWithContentDescription("Assistant panel").assertIsDisplayed()
        capture("setup-return")
        composeRule.onNodeWithContentDescription("Close assistant").performClick()
        composeRule.onNodeWithTag("unBlockAction").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Song actions").performClick()
        composeRule.onNodeWithText("Settings", substring = false).performClick()
        composeRule.onNodeWithContentDescription("Close").performClick()
        composeRule.onNodeWithContentDescription("Assistant panel").assertDoesNotExist()
        composeRule.onNodeWithTag("unBlockAction").assertIsDisplayed()
    }

    @Test fun readyModelStatusIsLegibleAndManageReturnsToAssistant() {
        // Readiness is display state here; this test does not claim real inference.
        composeRule.runOnIdle { vm.localModelLoaded = true }
        val status = composeRule.onNodeWithText("Local AI · Ready")
        status.performScrollTo().assertIsDisplayed()
        val pixels = status.captureToImage().toPixelMap()
        var lightInkPixels = 0
        for (y in 0 until pixels.height) for (x in 0 until pixels.width) {
            val p = pixels[x, y]
            if (p.red > 0.7f && p.green > 0.7f && p.blue > 0.7f) lightInkPixels++
        }
        assertTrue("Graphite model status must render light ink on its dark background", lightInkPixels > 20)
        capture("graphite-ready")
        composeRule.onNodeWithText("Manage model").performClick()
        composeRule.onNodeWithContentDescription("Close").performClick()
        composeRule.onNodeWithContentDescription("Assistant panel").assertIsDisplayed()
        status.assertIsDisplayed()
    }

    private fun capture(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val directory = File(instrumentation.targetContext.getExternalFilesDir(null), "model-navigation")
        directory.mkdirs()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }
}
