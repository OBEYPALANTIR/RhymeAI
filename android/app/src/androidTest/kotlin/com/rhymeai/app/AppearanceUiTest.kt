package com.rhymeai.app

import android.app.Application
import android.content.ContentValues
import android.provider.MediaStore
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.ui.theme.InkSurfaceLow
import com.rhymeai.app.ui.theme.PaperWhite
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppearanceUiTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val app: Application = ApplicationProvider.getApplicationContext()
    private val repository = ProjectRepository(app)
    private var scenario: ActivityScenario<MainActivity>? = null

    @Before
    fun setUp() {
        runBlocking {
            repository.saveAppearance(AppAppearance.INK)
        }
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    @After
    fun tearDown() {
        scenario?.close()
        scenario = null
        runBlocking {
            repository.saveAppearance(AppAppearance.INK)
        }
    }

    @Test
    fun appearanceSelectionAppliesImmediatelyAndPersistsAfterRelaunch() {
        openEditor()
        openAppearanceSettings()
        val selectorBounds = composeRule.onNodeWithTag(
            "appearanceSelector",
            useUnmergedTree = true
        )
            .getUnclippedBoundsInRoot()
        val selectorHeight = selectorBounds.bottom - selectorBounds.top
        assertTrue(
            "Appearance selector needs a 48dp touch target; measured $selectorHeight",
            selectorHeight.value >= 48f
        )
        composeRule.onNode(hasText("Ink") and isSelected()).assertExists()
        AppAppearance.entries.forEach { appearance ->
            composeRule.onNodeWithTag("appearancePreview${appearance.displayName}").assertDoesNotExist()
        }
        captureRootScreenshot("appearance-ink-settings.png")
        closeSettings()
        captureRootScreenshot("appearance-ink-editor.png")
        assertInkWordmarkUsesLightForeground()

        openAppearanceSettings()
        composeRule.onNode(hasText("Paper") and hasClickAction()).performClick()
        composeRule.onNode(hasText("Paper") and isSelected()).assertExists()
        captureRootScreenshot("appearance-paper-settings.png")
        closeSettings()
        captureRootScreenshot("appearance-paper-editor.png")

        openAppearanceSettings()
        composeRule.onNode(hasText("Graphite") and hasClickAction()).performClick()
        composeRule.onNode(hasText("Graphite") and isSelected()).assertExists()
        captureRootScreenshot("appearance-graphite-settings.png")
        closeSettings()
        captureRootScreenshot("appearance-graphite-editor.png")

        runBlocking {
            withTimeout(5_000) {
                repository.appearanceFlow.first { it == AppAppearance.GRAPHITE }
            }
        }

        scenario?.close()
        scenario = ActivityScenario.launch(MainActivity::class.java)
        openEditor()
        openAppearanceSettings()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodes(hasText("Graphite") and isSelected())
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
        captureRootScreenshot("appearance-graphite-relaunch.png")
    }

    @Test
    fun settingsApiKeyGuidanceMeetsTextContrast() {
        openEditor()
        openAppearanceSettings()
        composeRule.onNodeWithText("AI setup").performClick()
        composeRule.onNode(hasText("Gemini") and hasClickAction()).performClick()

        val placeholderContrast = maxRenderedContrast(
            composeRule.onNodeWithText("Paste your API key here...")
                .performScrollTo()
                .assertIsDisplayed()
                .captureToImage()
                .asAndroidBitmap(),
            InkSurfaceLow.toArgb()
        )
        val helperContrast = maxRenderedContrast(
            composeRule.onNodeWithText("Get a key at aistudio.google.com")
                .performScrollTo()
                .assertIsDisplayed()
                .captureToImage()
                .asAndroidBitmap(),
            PaperWhite.toArgb()
        )
        val syncSummaryContrast = maxRenderedContrast(
            composeRule.onNodeWithText("Not set up")
                .performScrollTo()
                .assertIsDisplayed()
                .captureToImage()
                .asAndroidBitmap(),
            PaperWhite.toArgb()
        )

        assertTrue("API key placeholder must meet 4.5:1 contrast", placeholderContrast >= 4.5)
        assertTrue("API key helper must meet 4.5:1 contrast", helperContrast >= 4.5)
        assertTrue("Settings support text must meet 4.5:1 contrast", syncSummaryContrast >= 4.5)
    }

    private fun openEditor() {
        composeRule.onNodeWithText("New Song").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithContentDescription("Song actions")
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
    }

    private fun openAppearanceSettings() {
        composeRule.onNodeWithTag("songActionsMenuButton").performClick()
        composeRule.onNodeWithText("Settings").performClick()
        composeRule.onNodeWithText("Appearance").assertExists()
    }

    private fun closeSettings() {
        composeRule.onNodeWithContentDescription("Close").performClick()
        composeRule.waitUntil(timeoutMillis = 3_000) {
            composeRule.onAllNodesWithContentDescription("Song actions")
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
    }

    private fun captureRootScreenshot(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val uniqueName = name.substringBeforeLast('.') +
            "-${System.currentTimeMillis()}." +
            name.substringAfterLast('.')
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, uniqueName)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RhymeAI-Test")
        }
        val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            ?: error("Could not create screenshot media row for $uniqueName")
        context.contentResolver.openOutputStream(uri).use { output ->
            requireNotNull(output) { "Could not open screenshot output stream for $uniqueName" }
            composeRule.onRoot().captureToImage().asAndroidBitmap()
                .compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output)
        }
        println("SCREENSHOT_PATH /sdcard/Pictures/RhymeAI-Test/$uniqueName")
    }

    private fun assertInkWordmarkUsesLightForeground() {
        val bitmap = composeRule.onNodeWithText("UnBlock", useUnmergedTree = true)
            .captureToImage()
            .asAndroidBitmap()
        var lightPixels = 0
        var opaquePixels = 0
        for (y in 0 until bitmap.height) {
            for (x in 0 until bitmap.width) {
                val pixel = bitmap.getPixel(x, y)
                if (android.graphics.Color.alpha(pixel) < 128) continue
                opaquePixels += 1
                val luminance = (
                    android.graphics.Color.red(pixel) +
                        android.graphics.Color.green(pixel) +
                        android.graphics.Color.blue(pixel)
                    ) / 3
                if (luminance >= 180) lightPixels += 1
            }
        }
        assertTrue(
            "Ink UnBlock text must use the light on-primary foreground",
            opaquePixels > 0 && lightPixels * 20 > opaquePixels
        )
    }

    private fun maxRenderedContrast(bitmap: android.graphics.Bitmap, background: Int): Double {
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        val maxAlpha = pixels.maxOfOrNull(android.graphics.Color::alpha) ?: return 0.0
        val backgroundLuminance = relativeLuminance(background)
        return pixels
            .asSequence()
            .filter { android.graphics.Color.alpha(it) == maxAlpha }
            .maxOfOrNull { pixel ->
                val foregroundLuminance = relativeLuminance(compositeOver(pixel, background))
                (maxOf(backgroundLuminance, foregroundLuminance) + 0.05) /
                    (minOf(backgroundLuminance, foregroundLuminance) + 0.05)
            } ?: 0.0
    }

    private fun compositeOver(foreground: Int, background: Int): Int {
        val alpha = android.graphics.Color.alpha(foreground) / 255.0
        fun channel(component: (Int) -> Int): Int =
            (component(foreground) * alpha + component(background) * (1.0 - alpha)).toInt()
        return android.graphics.Color.rgb(
            channel(android.graphics.Color::red),
            channel(android.graphics.Color::green),
            channel(android.graphics.Color::blue)
        )
    }

    private fun relativeLuminance(color: Int): Double {
        fun channel(component: Int): Double {
            val value = component / 255.0
            return if (value <= 0.04045) value / 12.92 else Math.pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(android.graphics.Color.red(color)) +
            0.7152 * channel(android.graphics.Color.green(color)) +
            0.0722 * channel(android.graphics.Color.blue(color))
    }
}
