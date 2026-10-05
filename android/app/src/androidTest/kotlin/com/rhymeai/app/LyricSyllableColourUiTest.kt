package com.rhymeai.app

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.ui.theme.syllableColor
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/**
 * Renders one lyric that mixes 1-, 2-, 3- and 4+-syllable words across every
 * appearance, Editor toggle, Focus state and selection state, and records which
 * syllable palette colours the lyric field actually draws.
 */
@OptIn(ExperimentalTestApi::class)
class LyricSyllableColourUiTest {
    @get:Rule val composeRule = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var vm: MainViewModel
    private lateinit var originalAppearance: AppAppearance
    private val lyric = "The harbor lights are burning low\nBeautiful and unforgettable tonight"
    private val harbor = TextRange(4, 10)
    private val outputDirectory: File by lazy {
        File(instrumentation.targetContext.filesDir, "syllable-colours").apply { mkdirs() }
    }

    @Before fun start() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
        waitUntil { vm.appearanceLoaded }
        originalAppearance = vm.appAppearance
        composeRule.onNodeWithText("New Song", useUnmergedTree = true).performScrollTo().performClick()
        waitUntil { !vm.savingBeforeNavigation && !vm.showStartMenu && vm.lyrics.isEmpty() }
        onMain {
            vm.onTitleChanged("Syllable colours")
            vm.onLyricsChanged(TextFieldValue(lyric, TextRange(lyric.length)))
        }
        composeRule.onNodeWithTag("lyricsEditor").performClick()
    }

    @After fun stop() {
        if (::vm.isInitialized) onMain { vm.setAppAppearance(originalAppearance) }
        scenario?.close()
    }

    @Test fun syllableColoursFollowAppearanceTogglesFocusAndSelection() {
        val report = StringBuilder("appearance,rhymes,syllables,focus,selection,coloursDrawn(1|2|3|4+)\n")
        val failures = mutableListOf<String>()
        for (appearance in AppAppearance.entries) {
            for (rhymes in listOf(false, true)) {
                for (syllables in listOf(true, false)) {
                    for (focus in listOf(false, true)) {
                        setFocus(focus)
                        for (selected in listOf(false, true)) {
                            onMain {
                                vm.setAppAppearance(appearance)
                                vm.isRhymeHighlightEnabled = rhymes
                                vm.isSyllableColoringEnabled = syllables
                                vm.onLyricsChanged(
                                    TextFieldValue(lyric, if (selected) harbor else TextRange(lyric.length))
                                )
                            }
                            settle()
                            val drawn = drawnSyllableColours(appearance.isDark)
                            val cell = "${appearance.storageValue},rhymes=$rhymes,syllables=$syllables," +
                                "focus=$focus,selection=$selected"
                            report.append("$cell,${drawn.joinToString("|")}\n")
                            capture(
                                "${appearance.storageValue}-rhymes_${rhymes}-syllables_${syllables}" +
                                    "-focus_${focus}-selection_${selected}"
                            )
                            // Rhyme colouring owns the foreground when it is on, so the
                            // per-word syllable tint is only asserted with rhymes off.
                            if (!rhymes) {
                                val expected = List(4) { syllables && !focus }
                                if (drawn != expected) failures += "$cell drew $drawn, expected $expected"
                            }
                        }
                    }
                }
            }
        }
        setFocus(false)
        File(outputDirectory, "matrix.csv").writeText(report.toString())
        assertEquals("Syllable colours did not match the product rule", emptyList<String>(), failures)
    }

    private fun setFocus(enabled: Boolean) {
        val inFocus = composeRule.onAllNodes(hasText("Exit Focus")).fetchSemanticsNodes().isNotEmpty()
        if (inFocus != enabled) {
            composeRule.onNodeWithTag("focusWritingToggle").performClick()
            composeRule.waitForIdle()
        }
    }

    private fun settle() {
        composeRule.waitForIdle()
        // Lyric analysis is debounced and built off the main thread.
        SystemClock.sleep(700)
        composeRule.waitForIdle()
    }

    private fun drawnSyllableColours(isDark: Boolean): List<Boolean> {
        val bitmap = composeRule.onNodeWithTag("lyricsEditor").captureToImage().asAndroidBitmap()
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return (1..4).map { count ->
            val target = syllableColor(count, isDark).toArgb()
            pixels.count { it == target } >= MIN_GLYPH_PIXELS
        }
    }

    private fun capture(name: String) {
        instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
            File(outputDirectory, "$name.png").outputStream().use {
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
        }
    }

    private fun onMain(block: () -> Unit) {
        instrumentation.runOnMainSync(block)
        instrumentation.waitForIdleSync()
    }

    private fun waitUntil(condition: () -> Boolean) {
        val until = SystemClock.uptimeMillis() + 8_000
        while (SystemClock.uptimeMillis() < until) {
            if (condition()) return
            SystemClock.sleep(50)
        }
        error("Syllable colour fixture did not settle")
    }

    private companion object {
        const val MIN_GLYPH_PIXELS = 40
    }
}
