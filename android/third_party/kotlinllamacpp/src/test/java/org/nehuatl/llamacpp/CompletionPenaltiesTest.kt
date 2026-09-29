package org.nehuatl.llamacpp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CompletionPenaltiesTest {
    @Test
    fun absentPenaltiesAreUnsetSoTheModelBaselineIsKept() {
        val penalties = CompletionPenalties.from(mapOf("prompt" to "text", "temperature" to 0.7))

        assertEquals(CompletionPenalties.UNSET_LAST_N, penalties.lastN)
        assertTrue(penalties.repeat.isNaN())
        assertTrue(penalties.freq.isNaN())
        assertTrue(penalties.present.isNaN())
    }

    @Test
    fun requestedPenaltiesArePassedThrough() {
        val penalties = CompletionPenalties.from(
            mapOf(
                "penalty_last_n" to 128,
                "penalty_repeat" to 1.15,
                "penalty_freq" to 0.2,
                "penalty_present" to 0.3
            )
        )

        assertEquals(128, penalties.lastN)
        assertEquals(1.15f, penalties.repeat, 0.0f)
        assertEquals(0.2f, penalties.freq, 0.0f)
        assertEquals(0.3f, penalties.present, 0.0f)
    }

    @Test
    fun eachFieldIsIndependent() {
        val penalties = CompletionPenalties.from(mapOf("penalty_repeat" to 1.3))

        assertEquals(CompletionPenalties.UNSET_LAST_N, penalties.lastN)
        assertEquals(1.3f, penalties.repeat, 0.0f)
        assertTrue(penalties.freq.isNaN())
        assertTrue(penalties.present.isNaN())
    }

    @Test
    fun aRequestedContextSizeWindowIsNotTheUnsetSentinel() {
        // -1 means "context size" to the sampler and is a real request; only Int.MIN_VALUE means unset.
        val penalties = CompletionPenalties.from(mapOf("penalty_last_n" to -1))

        assertEquals(-1, penalties.lastN)
    }
}
