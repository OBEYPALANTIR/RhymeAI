package com.rhymeai.app.ui.components

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SuggestionPlaceholderMotionTest {
    @Test
    fun threePlaceholdersBeforeTheFirstLineLands() {
        assertEquals(3, SuggestionPlaceholderMotion.placeholderCount(suggestionCount = 0, isLoading = true))
    }

    @Test
    fun onePlaceholderTrailsTheListWhileTheStreamIsOpen() {
        assertEquals(1, SuggestionPlaceholderMotion.placeholderCount(suggestionCount = 1, isLoading = true))
        assertEquals(1, SuggestionPlaceholderMotion.placeholderCount(suggestionCount = 6, isLoading = true))
    }

    @Test
    fun noPlaceholdersOnceTheStreamClosesOrIsStopped() {
        assertEquals(0, SuggestionPlaceholderMotion.placeholderCount(suggestionCount = 0, isLoading = false))
        assertEquals(0, SuggestionPlaceholderMotion.placeholderCount(suggestionCount = 4, isLoading = false))
    }

    @Test
    fun cycleSumsTheMotionLadder() {
        assertEquals(680, SuggestionPlaceholderMotion.DRAW_MILLIS)
        assertEquals(260, SuggestionPlaceholderMotion.HOLD_MILLIS)
        assertEquals(160, SuggestionPlaceholderMotion.FADE_MILLIS)
        assertEquals(260, SuggestionPlaceholderMotion.REST_MILLIS)
        assertEquals(1360, SuggestionPlaceholderMotion.CYCLE_MILLIS)
        assertEquals(260, SuggestionPlaceholderMotion.ROW_OFFSET_MILLIS)
    }

    @Test
    fun strokeDrawsThenHoldsThenFades() {
        assertEquals(0f, SuggestionPlaceholderMotion.strokeExtent(0))
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
    fun laterRowsStartOneStateTierLater() {
        assertEquals(0, SuggestionPlaceholderMotion.phaseMillis(elapsedMillis = 100, row = 1))
        assertEquals(100, SuggestionPlaceholderMotion.phaseMillis(elapsedMillis = 360, row = 1))
        assertEquals(100, SuggestionPlaceholderMotion.phaseMillis(elapsedMillis = 620, row = 2))
        assertEquals(0, SuggestionPlaceholderMotion.phaseMillis(elapsedMillis = 1360, row = 0))
    }

    @Test
    fun textBarFractionsCycleAcrossRows() {
        assertEquals(SuggestionPlaceholderMotion.textBarFraction(0), SuggestionPlaceholderMotion.textBarFraction(3))
        assertTrue(SuggestionPlaceholderMotion.textBarFractions.all { it in 0.4f..0.9f })
    }
}
