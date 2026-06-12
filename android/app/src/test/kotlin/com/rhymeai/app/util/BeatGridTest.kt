package com.rhymeai.app.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BeatGridTest {

    // ---------------------------------------------------------------------------
    // Basic math
    // ---------------------------------------------------------------------------

    @Test
    fun syllablesMapToBeatsAndBars() {
        // "hello world" → 3 syllables, 1 syllable/beat, 4 beats/bar
        // beats = 3, bars = 0.75 → FITS
        val result = BeatGrid.compute("hello world", bpm = 90)
        assertEquals(1, result.lines.size)
        val line = result.lines[0]
        assertEquals(3, line.syllableCount)
        assertEquals(3.0, line.beats, 0.001)
        assertEquals(0.75, line.bars, 0.001)
        assertEquals(BeatGrid.Fit.FITS, line.fit)
    }

    @Test
    fun secondsPerLineCalculation() {
        // 4 syllables at 1 syl/beat = 4 beats; 120 bpm → 4 * 60/120 = 2.0 s
        val result = BeatGrid.compute("four sy lla bles", bpm = 120)
        // syllableCount may vary by the counter; verify the formula directly
        val line = result.lines[0]
        val expected = line.beats * 60.0 / 120
        assertEquals(expected, line.secondsPerLine, 0.001)
    }

    // ---------------------------------------------------------------------------
    // Classification boundaries
    // ---------------------------------------------------------------------------

    @Test
    fun exactlyOneBarClassifiedAsFits() {
        // Need exactly 4 syllables (= 4 beats = 1 bar in 4/4).
        // "be a gon da" — 4 single-syllable tokens (fallback counter).
        val result = BeatGrid.compute("one two three four", bpm = 90)
        assertEquals(1, result.lines.size)
        val line = result.lines[0]
        assertEquals(4, line.syllableCount)
        assertEquals(BeatGrid.Fit.FITS, line.fit)
    }

    @Test
    fun oneBarPlusOneBeatClassifiedAsTight() {
        // 5 syllables at 4/4 → beats = 5 > 4 but ≤ 5 → TIGHT
        val result = BeatGrid.compute("one two three four five", bpm = 90)
        assertEquals(1, result.lines.size)
        assertEquals(BeatGrid.Fit.TIGHT, result.lines[0].fit)
    }

    @Test
    fun moreThanOneBarPlusOneBeatClassifiedAsOverflow() {
        // 6 syllables → beats = 6 > 5 → OVERFLOW
        val result = BeatGrid.compute("one two three four five six", bpm = 90)
        assertEquals(1, result.lines.size)
        assertEquals(BeatGrid.Fit.OVERFLOW, result.lines[0].fit)
    }

    // ---------------------------------------------------------------------------
    // Header-line skipping
    // ---------------------------------------------------------------------------

    @Test
    fun bracketedHeadersAreSkipped() {
        val lyrics = """
            [Verse 1]
            hello world
        """.trimIndent()
        val result = BeatGrid.compute(lyrics, bpm = 90)
        // Only the lyric line should appear; the [Verse 1] header is excluded.
        assertEquals(1, result.lines.size)
        assertTrue(result.lines[0].text.contains("hello") || result.lines[0].text.contains("world"))
    }

    @Test
    fun bareHeadersAreSkipped() {
        val lyrics = """
            chorus
            one two three
        """.trimIndent()
        val result = BeatGrid.compute(lyrics, bpm = 90)
        assertEquals(1, result.lines.size)
    }

    @Test
    fun blankLinesAreSkipped() {
        val lyrics = "one two\n\nthree four"
        val result = BeatGrid.compute(lyrics, bpm = 90)
        assertEquals(2, result.lines.size)
    }

    // ---------------------------------------------------------------------------
    // Tap-tempo averaging
    // ---------------------------------------------------------------------------

    @Test
    fun tapTempoAveragesFourTapsAt500msIntervals() {
        // 5 timestamps with 500 ms gaps → 4 intervals of 500 ms each
        // avgInterval = 500 ms → 60_000 / 500 = 120 bpm
        val base = 0L
        val timestamps = listOf(base, base + 500, base + 1000, base + 1500, base + 2000)
        val bpm = BeatGrid.tapTempoBpm(timestamps)
        assertEquals(120, bpm)
    }

    @Test
    fun tapTempoRequiresAtLeastTwoTimestamps() {
        assertNull(BeatGrid.tapTempoBpm(emptyList()))
        assertNull(BeatGrid.tapTempoBpm(listOf(1000L)))
    }

    @Test
    fun tapTempoResultClampedTo40() {
        // Very slow taps (10 s interval → 6 bpm) → clamp to 40
        val bpm = BeatGrid.tapTempoBpm(listOf(0L, 10_000L))
        assertEquals(40, bpm)
    }

    @Test
    fun tapTempoResultClampedTo220() {
        // Very fast taps (100 ms interval → 600 bpm) → clamp to 220
        val bpm = BeatGrid.tapTempoBpm(listOf(0L, 100L))
        assertEquals(220, bpm)
    }

    // ---------------------------------------------------------------------------
    // BPM clamping
    // ---------------------------------------------------------------------------

    @Test
    fun bpmClampedToMinimum40() {
        val result = BeatGrid.compute("hello", bpm = 0)
        assertEquals(40, result.bpm)
    }

    @Test
    fun bpmClampedToMaximum220() {
        val result = BeatGrid.compute("hello", bpm = 999)
        assertEquals(220, result.bpm)
    }

    @Test
    fun bpmPassedThroughWhenInRange() {
        val result = BeatGrid.compute("hello", bpm = 90)
        assertEquals(90, result.bpm)
    }
}
