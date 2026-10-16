package com.rhymeai.app.service

import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.util.PronunciationDictionary
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * Resilient local rule (PARITY.md): fewer than six survivors after sanitize + rhyme
 * filter retries the generation once and merges; three to five survivors are shown;
 * fewer than three after the retry is the existing error. Mirrors iOS
 * `LocalGenerationBoundaryTests` retry cases.
 */
class LocalSuggestionRetryTest {
    private val service = AIService()
    private val rhymes = listOf(
        "The ropes drip water on the train",
        "A gull cries out above the chain",
        "The boats lean out beyond the pane",
        "Your footsteps leave a fading stain",
        "The tide climbs slowly up the drain",
        "The windows face a narrow lane",
        "I trace your name to ease the pain",
        "The morning warms the sacks of grain"
    )
    private val misses = listOf(
        "The harbor sleeps beneath the stars",
        "Lanterns flicker on the pier",
        "A seagull circles overhead",
        "The fog rolls in across the bay"
    )
    private val dictionary = PronunciationDictionary.fromLines(
        sequenceOf("rain\tR EY1 N", "chain\tCH EY1 N", "drain\tD R EY1 N",
            "train\tT R EY1 N", "pane\tP EY1 N", "stain\tS T EY1 N",
            "lane\tL EY1 N", "pain\tP EY1 N", "grain\tG R EY1 N")
    )
    private val constraint = AIService.SuggestionRhymeConstraint(
        "I wait beneath the rain", "rain", emptyList(), RhymeType.PERFECT, dictionary
    )

    /** A null response makes that attempt throw, like a local generation timeout. */
    private class Attempts(private val responses: List<String?>) {
        var calls = 0
        fun next(): String = responses[calls++] ?: throw IllegalStateException("generation failed")
    }

    private fun streamed(vararg responses: String?): Pair<List<String>, Int> = runBlocking {
        val attempts = Attempts(responses.toList())
        val tokens: () -> Flow<String> = { flow { emit(attempts.next()) } }
        val lines = service.validatedLocalSuggestionStream(tokens, "Existing lyric", constraint).toList()
        lines.map { it.text } to attempts.calls
    }

    private fun batched(vararg responses: String?): Pair<List<String>, Int> = runBlocking {
        val attempts = Attempts(responses.toList())
        val lines = service.localSuggestionLines({ attempts.next() }, "Existing lyric", constraint)
        lines to attempts.calls
    }

    private fun response(lines: List<String>) = lines.joinToString("\n")

    // The batch path ranks survivors by syllable distance, so compare membership, not order.
    @Test
    fun sixSurvivorsDoNotRetry() {
        val full = response(rhymes.take(6))
        assertEquals(rhymes.take(6), streamed(full).first)
        for (run in listOf(streamed(full), batched(full))) {
            assertEquals(rhymes.take(6).toSet(), run.first.toSet())
            assertEquals(1, run.second)
        }
    }

    @Test
    fun fourSurvivorsRetryAndMergeToSixKeepingFirstAttemptFirst() {
        val first = response(rhymes.take(4) + misses.take(2))
        // Retry repeats two first-attempt lines (deduped) and brings two new rhymes.
        val retry = response(rhymes.take(2) + misses.take(2) + rhymes.subList(4, 6))
        assertEquals(rhymes.take(6), streamed(first, retry).first)
        for (run in listOf(streamed(first, retry), batched(first, retry))) {
            assertEquals(rhymes.take(4).toSet(), run.first.take(4).toSet())
            assertEquals(rhymes.subList(4, 6), run.first.drop(4))
            assertEquals(2, run.second)
        }
    }

    @Test
    fun fourSurvivorsWithEmptyRetryAreShown() {
        val first = response(rhymes.take(4) + misses.take(2))
        val retry = response(rhymes.take(4) + misses.take(2))
        assertEquals(rhymes.take(4), streamed(first, retry).first)
        for (run in listOf(streamed(first, retry), batched(first, retry))) {
            assertEquals(rhymes.take(4).toSet(), run.first.toSet())
            assertEquals(2, run.second)
        }
    }

    @Test
    fun twoSurvivorsAfterRetryStillFail() {
        val first = response(rhymes.take(2) + misses)
        val retry = response(rhymes.take(2) + misses)
        for (run in listOf<() -> Unit>({ streamed(first, retry) }, { batched(first, retry) })) {
            val error = assertFailsWith<RuntimeException> { run() }
            assertEquals("Local model returned an incomplete response. Try again or use a cloud provider.", error.message)
        }
        val none = response(misses)
        for (run in listOf<() -> Unit>({ streamed(none, none) }, { batched(none, none) })) {
            assertFailsWith<AIService.NoMatchingRhymesException> { run() }
        }
    }

    @Test
    fun fourSurvivorsWithFailedRetryAreShown() {
        val first = response(rhymes.take(4) + misses.take(2))
        assertEquals(rhymes.take(4), streamed(first, null).first)
        for (run in listOf(streamed(first, null), batched(first, null))) {
            assertEquals(rhymes.take(4).toSet(), run.first.toSet())
            assertEquals(2, run.second)
        }
    }

    @Test
    fun fourSurvivorsWithRetryThatFailsMidLineDropTheRetryTail() = runBlocking {
        val attempts = Attempts(listOf(response(rhymes.take(4) + misses.take(2)), rhymes[4]))
        val tokens: () -> Flow<String> = {
            flow {
                emit(attempts.next())
                if (attempts.calls == 2) throw IllegalStateException("generation failed")
            }
        }
        val lines = service.validatedLocalSuggestionStream(tokens, "Existing lyric", constraint).toList()
        assertEquals(rhymes.take(4), lines.map { it.text })
    }

    @Test
    fun sixSurvivorsStopReadingTheModelBeforeALaterProducerFailure() = runBlocking {
        val tokens: () -> Flow<String> = {
            flow {
                rhymes.take(6).forEach { emit(it + "\n") }
                throw IllegalStateException("generation failed")
            }
        }
        val lines = service.validatedLocalSuggestionStream(tokens, "Existing lyric", constraint).toList()
        assertEquals(rhymes.take(6), lines.map { it.text })
    }

    @Test
    fun twoSurvivorsWithRetryThatEmitsThenFailsStillSurfaceTheRetryError() = runBlocking {
        val attempts = Attempts(listOf(response(rhymes.take(2) + misses), rhymes[2] + "\n"))
        val tokens: () -> Flow<String> = {
            flow {
                val text = attempts.next()
                emit(text)
                if (attempts.calls == 2) throw IllegalStateException("generation failed")
            }
        }
        val error = assertFailsWith<IllegalStateException> {
            service.validatedLocalSuggestionStream(tokens, "Existing lyric", constraint).toList()
        }
        assertEquals("generation failed", error.message)
    }

    @Test
    fun twoSurvivorsWithFailedRetrySurfaceTheRetryError() {
        val first = response(rhymes.take(2) + misses)
        for (run in listOf<() -> Unit>({ streamed(first, null) }, { batched(first, null) })) {
            val error = assertFailsWith<IllegalStateException> { run() }
            assertEquals("generation failed", error.message)
        }
    }

    @Test
    fun retryGetsItsOwnRawLineBudget() {
        // The first pass spends the whole 12-line budget on two rhymes and ten misses.
        val first = response(rhymes.take(2) + overproducedMisses)
        val retry = response(rhymes.subList(2, 6))
        val run = streamed(first, retry)
        assertEquals(rhymes.take(6), run.first)
        assertEquals(2, run.second)
    }

    @Test
    fun batchPassCapsAtTwelveCandidatesBeforeRanking() {
        // Rhymes past the 12-candidate budget are not ranked; the retry supplies them.
        val first = response(misses + overproducedMisses + rhymes)
        val run = batched(first, response(rhymes))
        assertEquals(rhymes.take(6).toSet(), run.first.toSet())
        assertEquals(2, run.second)
    }

    private val overproducedMisses = listOf(
        "Quiet lanterns drift across the bay",
        "Old ropes curl beside the door",
        "The sailors laugh into the night",
        "A bell rings out along the shore",
        "Gray clouds roll over every roof",
        "The nets hang heavy on the pier",
        "My coat still smells of salt and smoke",
        "The lighthouse blinks its steady eye",
        "We count the boats along the dock",
        "The gulls fight over scraps of bread"
    )
}
