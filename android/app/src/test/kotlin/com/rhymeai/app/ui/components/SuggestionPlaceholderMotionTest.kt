package com.rhymeai.app.ui.components

import com.rhymeai.app.ui.theme.DesignTokens
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
    fun `text bar fractions cycle across slots and never index out of range`() {
        assertEquals(SuggestionPlaceholderMotion.textBarFraction(0), SuggestionPlaceholderMotion.textBarFraction(3))
        assertEquals(SuggestionPlaceholderMotion.textBarFraction(0), SuggestionPlaceholderMotion.textBarFraction(-1))
        assertTrue(SuggestionPlaceholderMotion.textBarFractions.all { it in 0.4f..0.9f })
    }

    // Ink line timing

    @Test
    fun `cycle is built from the motion ladder`() {
        assertEquals(420, SuggestionPlaceholderMotion.DRAW_MILLIS)
        assertEquals(DesignTokens.Motion.standardMillis, SuggestionPlaceholderMotion.HOLD_MILLIS)
        assertEquals(DesignTokens.Motion.dismissMillis, SuggestionPlaceholderMotion.FADE_MILLIS)
        assertEquals(DesignTokens.Motion.standardMillis, SuggestionPlaceholderMotion.REST_MILLIS)
        assertEquals(1100, SuggestionPlaceholderMotion.CYCLE_MILLIS)
    }

    @Test
    fun `no step passes the utilitarian cap`() {
        val steps = listOf(
            SuggestionPlaceholderMotion.DRAW_MILLIS,
            SuggestionPlaceholderMotion.HOLD_MILLIS,
            SuggestionPlaceholderMotion.FADE_MILLIS,
            SuggestionPlaceholderMotion.REST_MILLIS
        )
        assertTrue(steps.all { it <= 500 }, "steps were $steps")
    }

    @Test
    fun `a loop starts on a blank bar`() {
        assertEquals(0, SuggestionPlaceholderMotion.phaseMillis(elapsedMillis = 0))
        assertEquals(0, SuggestionPlaceholderMotion.phaseMillis(elapsedMillis = -5))
        assertEquals(0f, SuggestionPlaceholderMotion.strokeExtent(0))
    }

    @Test
    fun `stroke draws then holds then fades`() {
        val midDraw = SuggestionPlaceholderMotion.strokeExtent(SuggestionPlaceholderMotion.DRAW_MILLIS / 2)
        assertTrue(midDraw > 0f && midDraw < 1f, "mid-draw extent was $midDraw")
        assertEquals(1f, SuggestionPlaceholderMotion.strokeExtent(SuggestionPlaceholderMotion.DRAW_MILLIS))

        val holdEnd = SuggestionPlaceholderMotion.DRAW_MILLIS + SuggestionPlaceholderMotion.HOLD_MILLIS
        assertEquals(1f, SuggestionPlaceholderMotion.strokeAlpha(holdEnd - 1))
        val midFade = SuggestionPlaceholderMotion.strokeAlpha(holdEnd + SuggestionPlaceholderMotion.FADE_MILLIS / 2)
        assertTrue(midFade > 0f && midFade < 1f, "mid-fade alpha was $midFade")
        assertEquals(0f, SuggestionPlaceholderMotion.strokeAlpha(holdEnd + SuggestionPlaceholderMotion.FADE_MILLIS))
        assertEquals(0f, SuggestionPlaceholderMotion.strokeAlpha(SuggestionPlaceholderMotion.CYCLE_MILLIS - 1))
    }

    @Test
    fun `the loop wraps at the end of each cycle`() {
        val cycle = SuggestionPlaceholderMotion.CYCLE_MILLIS.toLong()
        assertEquals(0, SuggestionPlaceholderMotion.phaseMillis(cycle))
        assertEquals(100, SuggestionPlaceholderMotion.phaseMillis(cycle + 100))
        assertEquals(250, SuggestionPlaceholderMotion.phaseMillis(3 * cycle + 250))
    }

    @Test
    fun `still bar reads more strongly than the resting bar`() {
        assertTrue(SuggestionPlaceholderMotion.STATIC_INK_ALPHA > SuggestionPlaceholderMotion.RESTING_INK_ALPHA)
        assertTrue(SuggestionPlaceholderMotion.STATIC_INK_ALPHA < SuggestionPlaceholderMotion.STROKE_INK_ALPHA)
    }
}
