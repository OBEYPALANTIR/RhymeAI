package com.rhymeai.app.service

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.math.log10

/**
 * Pure-function tests for amplitude normalization logic used by the mic FAB spectralizer.
 *
 * The normalization formula maps MediaRecorder's linear peak through -60..0 dB into 0..1.
 * The smoothing formula is:     smoothed = smoothed * 0.7f + raw * 0.3f
 *
 * These tests exercise the math without involving MediaRecorder or any Android API.
 */
class AmplitudeNormalizationTest {

    private fun normalize(raw: Int): Float =
        if (raw <= 0) {
            0f
        } else {
            (((20.0 * log10((raw / 32767f).toDouble()) + 60.0) / 60.0).toFloat())
                .coerceIn(0f, 1f)
        }

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
        assertTrue(result in 0.89f..0.91f, "Expected ~0.90 but was $result")
    }

    @Test
    fun lowLevelSignalIsPerceptuallyLifted() {
        val result = normalize(327)
        assertTrue(result > 0.25f, "Expected low-level speech to lift visibly but was $result")
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
        val bars = FloatArray(22) { it * 0.01f }
        val original1 = bars[1]
        val next = FloatArray(22)
        for (i in 0 until 21) next[i] = bars[i + 1]
        next[21] = 0.99f
        // First bar should now hold what was originally bar[1].
        assertEquals(original1, next[0], absoluteTolerance = 0.0001f)
        // Last bar should hold the new value.
        assertEquals(0.99f, next[21], absoluteTolerance = 0.0001f)
    }
}
