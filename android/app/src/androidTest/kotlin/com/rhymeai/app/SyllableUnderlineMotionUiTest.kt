package com.rhymeai.app

import android.graphics.Bitmap
import android.os.SystemClock
import android.util.Log
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.isRoot
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
import com.rhymeai.app.ui.components.analyzeSyllableUnderlines
import com.rhymeai.app.ui.components.buildAnalysisText
import com.rhymeai.app.ui.components.colorSyllableUnderlines
import com.rhymeai.app.ui.screens.lyricStatsFor
import com.rhymeai.app.ui.theme.rhymePalette
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/**
 * Drives the editor's syllable underlines one frame at a time (main clock paused) and reads what
 * the lyric field actually draws. The lyric has no rhymes and no descenders, so the words keep the
 * base ink and every coloured pixel under the line is an underline.
 */
@OptIn(ExperimentalTestApi::class)
class SyllableUnderlineMotionUiTest {
    @get:Rule val composeRule = createEmptyComposeRule()
    private var scenario: ActivityScenario<MainActivity>? = null
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var vm: MainViewModel
    private var originalRhymes = false
    private var originalSyllables = true
    private var clock = SystemClock.uptimeMillis()
    private val lyric = "Wonderful dream at last"
    private lateinit var underlineRows: IntRange

    @Before fun start() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
        waitUntil { vm.appearanceLoaded }
        composeRule.onNodeWithText("New Song", useUnmergedTree = true).performScrollTo().performClick()
        waitUntil { !vm.savingBeforeNavigation && !vm.showStartMenu && vm.lyrics.isEmpty() }
        onMain {
            originalRhymes = vm.isRhymeHighlightEnabled
            originalSyllables = vm.isSyllableColoringEnabled
            vm.isRhymeHighlightEnabled = true // underlines draw only while rhymes own the word colour
            vm.isSyllableColoringEnabled = true
            vm.onTitleChanged("Underline motion")
        }
        type(lyric)
        composeRule.onNodeWithTag("lyricsEditor").performClick()
        settleInRealTime()
        // The underline rows are what appears when syllables are switched on over the same text.
        val on = saturatedPixels(capture())
        onMain { vm.isSyllableColoringEnabled = false }
        settleInRealTime()
        val off = saturatedPixels(capture())
        onMain { vm.isSyllableColoringEnabled = true }
        settleInRealTime()
        val rows = on.rows.filter { y -> (0 until on.width).count { x -> on[x, y] && !off[x, y] } >= 10 }
        assertTrue("no underline rows found", rows.isNotEmpty())
        underlineRows = rows.first()..rows.last()
        composeRule.mainClock.autoAdvance = false
    }

    @After fun stop() {
        composeRule.mainClock.autoAdvance = true
        if (::vm.isInitialized) onMain {
            vm.isRhymeHighlightEnabled = originalRhymes
            vm.isSyllableColoringEnabled = originalSyllables
        }
        scenario?.close()
    }

    @Test fun twoQuickDeletionsEaseShorterWithoutABlankFrame() {
        val rest = underline()
        type(lyric.dropLast(1))
        frame()
        val firstFrame = underline()
        type(lyric.dropLast(2))
        val frames = listOf(firstFrame) + List(24) { frame(); underline() }
        settle()
        val final = underline()

        assertTrue("blank frame in $frames", frames.all { it.pixels > 0 })
        assertTrue("first frame snapped: $rest -> $firstFrame", firstFrame.right >= rest.right - 3)
        frames.zipWithNext().forEach { (a, b) -> assertTrue("grew while shrinking: $frames", b.right <= a.right + 2) }
        assertTrue("no eased frame between $rest and $final", frames.any { it.right in (final.right + 4)..(rest.right - 4) })
        assertTrue("did not shorten: $rest -> $final", final.right < rest.right - 10)
    }

    @Test fun bulkPasteSnapsInsteadOfGrowingEveryWord() {
        val pasted = (lyric + "\n").repeat(12).trimEnd()
        type(pasted)
        frame()
        val first = saturatedPixels(capture())
        repeat(12) { frame() }
        val later = saturatedPixels(capture())
        assertTrue("nothing drawn after the paste", first.count > 0)
        assertTrue("underlines kept moving after a ${pasted.length}-character paste", first.differenceFrom(later) <= 30)
    }

    @Test fun switchingSyllablesOffMidFadeClearsTheFadingLine() {
        type("$lyric a")
        settle()
        val rest = underline()
        type("$lyric ")
        frame()
        assertTrue("the deleted word's line should still be fading", underline().right >= rest.right - 3)
        onMain { vm.isSyllableColoringEnabled = false }
        frame()
        assertEquals("a dead underline outlived the analysis", 0, underline().pixels)
    }

    @Test fun shorteningAWrappedWordStaysOnItsRow() {
        val long = "unbelievable".repeat(8)
        type("Wonderful $long at last")
        settle()
        type("Wonderful unbel at last")
        val frames = List(14) { frame(); saturatedPixels(capture()) }
        settle()
        val final = saturatedPixels(capture())
        frames.forEachIndexed { index, pixels ->
            val stray = pixels.extraOver(final)
            assertTrue("frame $index drew $stray pixels outside the shortened word's row", stray <= 40)
        }
    }

    @Test fun undoAndRedoEaseTheLineBackAndForth() {
        type(lyric.dropLast(2))
        settle()
        val short = underline()
        onMain { vm.undoLyrics() }
        val undoFrames = List(20) { frame(); underline() }
        settle()
        val restored = underline()
        onMain { vm.redoLyrics() }
        val redoFrames = List(20) { frame(); underline() }
        settle()
        val redone = underline()

        assertEquals(lyric.dropLast(2), vm.lyrics)
        assertTrue("blank frame during undo/redo", (undoFrames + redoFrames).all { it.pixels > 0 })
        assertTrue("undo snapped", undoFrames.first().right < restored.right - 3)
        assertTrue("redo snapped", redoFrames.first().right > redone.right + 3)
        assertTrue(abs(redone.right - short.right) <= 2)
    }

    @Test fun imeCompositionKeepsTheUnderlineAndEasesIt() {
        val rest = underline()
        val connection = inputConnection()
        val frames = mutableListOf<Underline>()
        onMain { connection.setComposingText("ly", 1) }
        repeat(8) { frame(); frames += underline() }
        onMain { connection.finishComposingText() }
        repeat(4) { frame(); frames += underline() }
        settle()
        val final = underline()

        assertEquals("${lyric}ly", vm.lyrics)
        assertTrue("blank frame while composing: $frames", frames.all { it.pixels > 0 })
        assertTrue("composition did not lengthen the line: $rest -> $final", final.right > rest.right + 3)
    }

    /** Logs what one keystroke costs each analysis, and one whole editor frame, for two song sizes. */
    @Test fun perKeystrokeCost() {
        val verse = "The harbor lights are burning low tonight\nI keep on walking through the city in the rain\n" +
            "Beautiful and unforgettable the night\nEvery single word I write is just the same\n"
        fun median(samples: List<Double>) = "%.2f".format(samples.sorted()[samples.size / 2])
        fun timed(block: () -> Unit): Double {
            val started = System.nanoTime()
            block()
            return (System.nanoTime() - started) / 1e6
        }
        for (targetWords in listOf(600, 5_000)) {
            val song = buildString { while (lyricStatsFor(toString()).wordCount < targetWords) append(verse) }
            type(song)
            settle()
            val stats = mutableListOf<Double>()
            val underlines = mutableListOf<Double>()
            val colouring = mutableListOf<Double>()
            var text = song
            repeat(15) { index ->
                text = if (index % 2 == 0) text.dropLast(1) else text + "e"
                stats += timed { assertTrue(lyricStatsFor(text).wordCount >= targetWords - 1) }
                underlines += timed {
                    val spans = colorSyllableUnderlines(analyzeSyllableUnderlines(text, enabled = true), isDark = false)
                    assertTrue(spans.last().endExclusive <= text.length)
                }
                colouring += timed {
                    buildAnalysisText(text, Color.Black, rhymePalette(false), isDark = false, rhymeEnabled = true, syllablesEnabled = true)
                }
            }
            val frames = listOf(true to true, true to false, false to false).associate { (rhymes, syllables) ->
                onMain {
                    vm.isRhymeHighlightEnabled = rhymes
                    vm.isSyllableColoringEnabled = syllables
                }
                settle()
                val samples = List(9) { index ->
                    text = if (index % 2 == 0) text.dropLast(1) else text + "e"
                    type(text)
                    timed { frame() }
                }
                "rhymes=$rhymes,syllables=$syllables" to median(samples)
            }
            Log.i(
                "SyllableCost",
                "words=${lyricStatsFor(song).wordCount} chars=${song.length} statsMs=${median(stats)} " +
                    "underlineAnalysisMs=${median(underlines)} colouringMs=${median(colouring)} editorFrameMs=$frames"
            )
            onMain {
                vm.isRhymeHighlightEnabled = true
                vm.isSyllableColoringEnabled = true
            }
        }
    }

    private data class Underline(val right: Int, val pixels: Int)

    private class Pixels(val width: Int, val height: Int, private val set: BooleanArray) {
        operator fun get(x: Int, y: Int) = set[y * width + x]
        val count get() = set.count { it }
        val rows get() = (0 until height).filter { y -> (0 until width).any { x -> this[x, y] } }
        fun differenceFrom(other: Pixels) = set.indices.count { set[it] != other.set[it] }
        fun extraOver(other: Pixels) = set.indices.count { set[it] && !other.set[it] }
    }

    private fun underline(): Underline {
        val pixels = saturatedPixels(capture())
        var right = -1
        var count = 0
        for (y in underlineRows) for (x in 0 until pixels.width) if (pixels[x, y]) {
            count++
            right = maxOf(right, x)
        }
        return Underline(right, count)
    }

    // The last row's underline sits just below the field's bounds, so capture the window around it.
    private fun capture(): Bitmap {
        repeat(2) { runCatching { return captureOnce() } }
        return captureOnce()
    }

    private fun captureOnce(): Bitmap {
        val bounds = composeRule.onNodeWithTag("lyricsEditor").fetchSemanticsNode().boundsInRoot
        val window = composeRule.onAllNodes(isRoot())[0].captureToImage().asAndroidBitmap()
        val top = bounds.top.toInt().coerceAtLeast(0)
        val bottom = (bounds.bottom.toInt() + UNDERLINE_MARGIN_PX).coerceAtMost(window.height)
        return Bitmap.createBitmap(window, 0, top, window.width, bottom - top)
    }

    private fun saturatedPixels(bitmap: Bitmap): Pixels {
        val argb = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(argb, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return Pixels(bitmap.width, bitmap.height, BooleanArray(argb.size) { i ->
            val c = argb[i]
            val r = (c shr 16) and 0xFF
            val g = (c shr 8) and 0xFF
            val b = c and 0xFF
            maxOf(r, g, b) - minOf(r, g, b) > 40
        })
    }

    private fun inputConnection(): InputConnection {
        var connection: InputConnection? = null
        scenario!!.onActivity { activity ->
            val view = requireNotNull(activity.window.decorView.findFocus()) { "the lyric field is not focused" }
            connection = view.onCreateInputConnection(EditorInfo())
        }
        return requireNotNull(connection) { "no input connection for the lyric field" }
    }

    private fun type(text: String) {
        clock += 10_000 // a separate undo step per edit
        onMain { vm.onLyricsChanged(TextFieldValue(text, TextRange(text.length)), timestampMilliseconds = clock) }
    }

    private fun frame() = composeRule.mainClock.advanceTimeByFrame()

    // Frame by frame: an animation takes its start time from the first frame it sees.
    private fun settle() {
        repeat(40) { frame() }
        composeRule.waitForIdle()
    }

    private fun settleInRealTime() {
        composeRule.waitForIdle()
        SystemClock.sleep(600)
        composeRule.waitForIdle()
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
        error("Editor fixture did not settle")
    }

    private fun abs(value: Int) = kotlin.math.abs(value)

    private companion object {
        const val UNDERLINE_MARGIN_PX = 48
    }
}
