package com.rhymeai.app.service

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Pure-function tests for amplitude normalization logic used by the mic FAB spectralizer.
 *
 * The normalization formula is: (raw / 32767f).coerceIn(0f, 1f)
 * The smoothing formula is:     smoothed = smoothed * 0.7f + raw * 0.3f
 *
 * These tests exercise the math without involving MediaRecorder or any Android API.
 */
class AmplitudeNormalizationTest {

    private fun normalize(raw: Int): Float = (raw / 32767f).coerceIn(0f, 1f)

    private fun smooth(previous: Float, raw: Float): Float = previous * 0.7f + raw * 0.3f

    @Test
    fun zeroInputNormalizesToZero() {
        assertEquals(0f, normalize(0))
    }

    @Test
    fun maxInputNormalizesToOne() {
        assertEquals(1f, normalize(32767))
    }

    @Test
    fun midpointNormalizesCorrectly() {
        val result = normalize(16383)
        assertTrue(result in 0.49f..0.51f, "Expected ~0.5 but was $result")
    }

    @Test
    fun negativeInputClampedToZero() {
        assertEquals(0f, normalize(-1))
    }

    @Test
    fun overMaxInputClampedToOne() {
        assertEquals(1f, normalize(65535))
    }

    @Test
    fun smoothingRetainsHistoryWeight() {
        // With previous = 1f and new = 0f, result should be 0.7 (retains 70% of history).
        val result = smooth(previous = 1f, raw = 0f)
        assertEquals(0.7f, result, absoluteTolerance = 0.0001f)
    }

    @Test
    fun smoothingBlendsFreshSignal() {
        // With previous = 0f and new = 1f, result should be 0.3 (30% of new signal).
        val result = smooth(previous = 0f, raw = 1f)
        assertEquals(0.3f, result, absoluteTolerance = 0.0001f)
    }

    @Test
    fun smoothingConvergesAfterRepeatedApplications() {
        // Applying smoothing with a constant input of 1f should converge toward 1f.
        var value = 0f
        repeat(40) { value = smooth(value, 1f) }
        assertTrue(value > 0.999f, "Expected convergence near 1.0 but was $value")
    }

    @Test
    fun barShiftMovesOldestValueOff() {
        // Simulates the "shift left, push new reading on right" logic used for spectralizer bars.
        val bars = FloatArray(14) { it * 0.01f }
        val original1 = bars[1]
        val next = FloatArray(14)
        for (i in 0 until 13) next[i] = bars[i + 1]
        next[13] = 0.99f
        // First bar should now hold what was originally bar[1].
        assertEquals(original1, next[0], absoluteTolerance = 0.0001f)
        // Last bar should hold the new value.
        assertEquals(0.99f, next[13], absoluteTolerance = 0.0001f)
    }
}
