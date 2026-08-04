package com.rhymeai.app.ui.motion

import org.junit.Assert.assertEquals
import org.junit.Test

class RewriteLoadingHighlightTest {
    @Test
    fun pencilCycleReturnsToItsStartingStateWithoutSnapping() {
        assertEquals(0f, pencilRevealFraction(0f), 0.0001f)
        assertEquals(1f, pencilRevealFraction(0.60f), 0.0001f)
        assertEquals(1f, pencilRevealFraction(0.82f), 0.0001f)
        assertEquals(0f, pencilRevealFraction(1f), 0.0001f)
        assertEquals(0f, pencilFleckAlpha(0f), 0.0001f)
        assertEquals(0f, pencilFleckAlpha(1f), 0.0001f)
    }

    @Test
    fun paperSlipSlidesInThenHoldsBeforeFading() {
        assertEquals(0f, paperSlipEnterFraction(0f), 0.0001f)
        assertEquals(1f, paperSlipEnterFraction(0.24f), 0.0001f)
        assertEquals(1f, paperSlipEnterFraction(0.72f), 0.0001f)
        assertEquals(1f, paperSlipAlpha(0.72f), 0.0001f)
        assertEquals(0f, paperSlipAlpha(1f), 0.0001f)
    }

    @Test
    fun reducedMotionProgressShowsEveryStyleAtRest() {
        val progress = RewriteHighlightState.stableProgress

        assertEquals(1f, pencilRevealFraction(progress), 0.0001f)
        assertEquals(1f, pencilFleckAlpha(progress), 0.0001f)
        assertEquals(1f, paperSlipEnterFraction(progress), 0.0001f)
        assertEquals(1f, paperSlipAlpha(progress), 0.0001f)
    }
}
