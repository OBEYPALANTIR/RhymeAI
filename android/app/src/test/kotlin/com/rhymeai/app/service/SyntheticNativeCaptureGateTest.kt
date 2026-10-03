package com.rhymeai.app.service

import kotlinx.coroutines.channels.Channel
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SyntheticNativeCaptureGateTest {
    @Test
    fun queuedNativeTailSurvivesRelayBoundaryAndStopsOnlyAfterCleanup() {
        val arrived = mutableListOf<Pair<String, Long>>()
        val gate = gate(arrived)
        val relay = Channel<String>(Channel.UNLIMITED)
        val boundary = GenerationBoundary(listOf("<turn|>"), 4096)

        for ((chunk, time) in listOf("A" to 101L, "<turn|>" to 102L, "C" to 103L)) {
            gate.recordNativeCallback(chunk, time)
            relay.trySend(chunk).getOrThrow()
        }
        val emitted = mutableListOf<String>()
        while (true) {
            val bounded = boundary.accept(relay.tryReceive().getOrThrow())
            emitted += bounded.text
            if (bounded.terminationReason != null) break
        }

        assertEquals(listOf("A", ""), emitted)
        assertEquals(listOf("A" to 1L, "<turn|>" to 2L, "C" to 3L), arrived)
        assertEquals("C", relay.tryReceive().getOrThrow())
        gate.finish()
        gate.recordNativeCallback("after cleanup", 104L)
        assertEquals(3, arrived.size)
    }

    @Test
    fun parserCancellationDoesNotDiscardCallbacksBeforeNativeCleanup() {
        val arrived = mutableListOf<Pair<String, Long>>()
        val gate = gate(arrived)
        val relay = Channel<String>(Channel.UNLIMITED)
        gate.recordNativeCallback("first", 101L)
        relay.trySend("first").getOrThrow()
        assertEquals("first", relay.tryReceive().getOrThrow())

        // Parser cancellation closes the relay while native completion is still unwinding.
        relay.close()
        gate.recordNativeCallback("queued", 102L)
        assertTrue(relay.trySend("queued").isFailure)
        gate.recordNativeCallback("last", 103L)
        assertTrue(relay.trySend("last").isFailure)
        assertEquals(listOf("first" to 1L, "queued" to 2L, "last" to 3L), arrived)
        gate.finish()
        gate.recordNativeCallback("after cleanup", 104L)
        assertEquals(3, arrived.size)
    }

    private fun gate(arrived: MutableList<Pair<String, Long>>): SyntheticNativeCaptureGate =
        SyntheticNativeCaptureGate().apply {
            begin(SyntheticGenerationCapture(
                runId = "synthetic-test",
                expectedPromptSha256 = "0".repeat(64),
                seed = 37,
                onNativeChunk = { chunk, elapsed -> arrived += chunk to elapsed },
                onParserChunk = { _, _ -> }
            ), startedAtNs = 100L)
        }
}
