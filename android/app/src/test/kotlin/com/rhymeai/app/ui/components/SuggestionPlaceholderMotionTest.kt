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
    fun `text bar fractions cycle across slots and never index out of range`() {
        assertEquals(SuggestionPlaceholderMotion.textBarFraction(0), SuggestionPlaceholderMotion.textBarFraction(3))
        assertEquals(SuggestionPlaceholderMotion.textBarFraction(0), SuggestionPlaceholderMotion.textBarFraction(-1))
        assertTrue(SuggestionPlaceholderMotion.textBarFractions.all { it in 0.4f..0.9f })
    }

    // Ink line timing

    @Test
    fun `stroke draws on the settle tier, inside the utilitarian cap`() {
        assertEquals(420, SuggestionPlaceholderMotion.DRAW_MILLIS)
        assertTrue(SuggestionPlaceholderMotion.DRAW_MILLIS <= 500)
    }

    @Test
    fun `stroke starts on a blank bar`() {
        assertEquals(0f, SuggestionPlaceholderMotion.strokeExtent(elapsedMillis = 0))
        assertEquals(0f, SuggestionPlaceholderMotion.strokeExtent(elapsedMillis = -5))
    }

    @Test
    fun `stroke rises once to full and stays there`() {
        val draw = SuggestionPlaceholderMotion.DRAW_MILLIS.toLong()
        val extents = (0L..draw step 20).map { SuggestionPlaceholderMotion.strokeExtent(it) }
        assertTrue(extents.zipWithNext().all { (a, b) -> b >= a }, "extents were $extents")
        val midDraw = SuggestionPlaceholderMotion.strokeExtent(draw / 2)
        assertTrue(midDraw > 0f && midDraw < 1f, "mid-draw extent was $midDraw")
        assertEquals(1f, SuggestionPlaceholderMotion.strokeExtent(draw))
        // No wraparound: a ghost waiting on a slow model keeps its full bar.
        assertEquals(1f, SuggestionPlaceholderMotion.strokeExtent(draw + 1))
        assertEquals(1f, SuggestionPlaceholderMotion.strokeExtent(1_100))
        assertEquals(1f, SuggestionPlaceholderMotion.strokeExtent(60_000))
    }

    @Test
    fun `bar rests at the ghost's own ink`() {
        assertEquals(0.08f, SuggestionPlaceholderMotion.RESTING_INK_ALPHA)
        assertEquals(SuggestionPlaceholderMotion.GHOST_ALPHA, SuggestionPlaceholderMotion.RESTING_INK_ALPHA)
    }
}
