package com.rhymeai.app.ui.components

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SuggestionPlaceholderMotionTest {
    // Slots

    @Test
    fun `one ghost opens before the first line arrives`() {
        assertEquals(1, SuggestionPlaceholderMotion.placeholderCount(arrived = 0, isLoading = true))
        assertEquals(1, SuggestionPlaceholderMotion.slotCount(arrived = 0, isLoading = true))
    }

    @Test
    fun `each arriving line opens the next ghost below it`() {
        assertEquals(1, SuggestionPlaceholderMotion.placeholderCount(arrived = 1, isLoading = true))
        assertEquals(1, SuggestionPlaceholderMotion.placeholderCount(arrived = 5, isLoading = true))
        assertEquals(2, SuggestionPlaceholderMotion.slotCount(arrived = 1, isLoading = true))
        assertEquals(6, SuggestionPlaceholderMotion.slotCount(arrived = 5, isLoading = true))
    }

    @Test
    fun `no ghosts remain once generation stops, however many lines came`() {
        assertEquals(0, SuggestionPlaceholderMotion.placeholderCount(arrived = 0, isLoading = false))
        assertEquals(0, SuggestionPlaceholderMotion.placeholderCount(arrived = 1, isLoading = false))
        assertEquals(1, SuggestionPlaceholderMotion.slotCount(arrived = 1, isLoading = false))
        // A request that ends with no lines leaves nothing, so the section closes.
        assertEquals(0, SuggestionPlaceholderMotion.slotCount(arrived = 0, isLoading = false))
    }

    @Test
    fun `bar fractions cycle across slots, second line shorter, never out of range`() {
        assertEquals(SuggestionPlaceholderMotion.textBarFraction(0), SuggestionPlaceholderMotion.textBarFraction(3))
        assertEquals(SuggestionPlaceholderMotion.textBarFraction(0), SuggestionPlaceholderMotion.textBarFraction(-1))
        assertEquals(SuggestionPlaceholderMotion.secondBarFraction(1), SuggestionPlaceholderMotion.secondBarFraction(4))
        assertTrue(SuggestionPlaceholderMotion.textBarFractions.all { it in 0.4f..0.9f })
        assertEquals(0.72f * 0.6f, SuggestionPlaceholderMotion.secondBarFraction(0), 1e-6f)
    }

    // Scribble loop

    @Test
    fun `loop is a 1300ms write and a 350ms hold`() {
        assertEquals(1300, SuggestionPlaceholderMotion.WRITE_MILLIS)
        assertEquals(350, SuggestionPlaceholderMotion.HOLD_MILLIS)
        assertEquals(1650, SuggestionPlaceholderMotion.PERIOD_MILLIS)
    }

    @Test
    fun `both lines start blank`() {
        assertEquals(0f to 0f, SuggestionPlaceholderMotion.lineProgress(0))
    }

    @Test
    fun `first line draws alone over the first 63 percent of the write`() {
        val (first, second) = SuggestionPlaceholderMotion.lineProgress(400)
        assertEquals(400f / (1300f * 0.63f), first, 1e-4f)
        assertEquals(0f, second)
    }

    @Test
    fun `second line starts where the first ends`() {
        // 63% of 1300ms is 819ms; just past it the first is full and the second has begun.
        val (first, second) = SuggestionPlaceholderMotion.lineProgress(830)
        assertEquals(1f, first)
        assertTrue(second > 0f && second < 0.05f, "second was $second")
        assertEquals(0f, SuggestionPlaceholderMotion.lineProgress(800).second)
        val (_, mid) = SuggestionPlaceholderMotion.lineProgress(1100)
        assertTrue(mid > 0.3f && mid < 1f, "second mid-draw was $mid")
    }

    @Test
    fun `both lines hold fully drawn after the write`() {
        for (t in listOf(1300L, 1450L, 1649L)) {
            assertEquals(1f to 1f, SuggestionPlaceholderMotion.lineProgress(t), "at $t")
        }
    }

    @Test
    fun `lines wipe and the scribble starts again`() {
        assertEquals(0f to 0f, SuggestionPlaceholderMotion.lineProgress(1650))
        assertEquals(SuggestionPlaceholderMotion.lineProgress(400), SuggestionPlaceholderMotion.lineProgress(1650 * 3 + 400L))
    }

    @Test
    fun `still frame draws the first line and stops the second 60 percent along`() {
        assertEquals(1f to 0.6f, SuggestionPlaceholderMotion.STILL_FRAME)
    }

    // Wave path

    @Test
    fun `scribble is a 34 period wave, 10 tall, stroked 1_6`() {
        assertEquals(34f, SuggestionPlaceholderMotion.WAVE_PERIOD_DP)
        assertEquals(10f, SuggestionPlaceholderMotion.WAVE_HEIGHT_DP)
        assertEquals(1.6f, SuggestionPlaceholderMotion.STROKE_WIDTH_DP)
    }

    @Test
    fun `one period follows the design's five wave points`() {
        val points = SuggestionPlaceholderMotion.wavePoints(width = 34f, period = 34f, height = 10f)
        val expected = listOf(0f to 5.5f, 6.12f to 2.5f, 14.28f to 7.8f, 23.12f to 2.8f, 34f to 5.8f)
        assertEquals(expected.size, points.size)
        expected.zip(points).forEach { (e, p) ->
            assertEquals(e.first, p.x, 1e-4f)
            assertEquals(e.second, p.y, 1e-4f)
        }
    }

    @Test
    fun `wave keeps its 34 period and is cut at the width`() {
        val points = SuggestionPlaceholderMotion.wavePoints(width = 80f, period = 34f, height = 10f)
        assertEquals(0f, points.first().x)
        assertEquals(5.5f, points.first().y, 1e-4f)
        // One full wave ends at 34, its height 0.58.
        assertEquals(34f, points[4].x, 1e-4f)
        assertEquals(5.8f, points[4].y, 1e-4f)
        // The second wave repeats the first's shape one period on.
        assertEquals(34f + 0.18f * 34f, points[5].x, 1e-4f)
        assertEquals(points[1].y, points[5].y, 1e-4f)
        assertEquals(80f, points.last().x, 1e-4f)
        assertTrue(points.all { it.x <= 80f && it.y in 0f..10f })
        assertTrue(points.zipWithNext().all { (a, b) -> b.x > a.x }, "x must increase: $points")
    }

    @Test
    fun `a width shorter than one wave still ends exactly at the edge`() {
        val points = SuggestionPlaceholderMotion.wavePoints(width = 10f, period = 34f, height = 10f)
        assertEquals(10f, points.last().x, 1e-4f)
        assertEquals(3, points.size)
    }
}
