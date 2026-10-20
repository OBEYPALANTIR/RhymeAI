package com.rhymeai.app.service

import com.rhymeai.app.SuggestedLine
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.util.PronunciationDictionary
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull

/**
 * Returned suggestion lines on the streaming path admit only the requested
 * relation, as iOS `emitLines` does.
 */
class SuggestionRhymeFilterTest {
    private val dictionary = PronunciationDictionary.fromLines(
        sequenceOf(
            "road\tR OW1 D",
            "glowed\tG L OW1 D",
            "showed\tSH OW1 D",
            "wrote\tR OW1 T",
            "stone\tS T OW1 N",
            "red\tR EH1 D",
            "night\tN AY1 T"
        )
    )
    private val service = AIService()

    private fun constraint(type: RhymeType) =
        assertNotNull(service.suggestionRhymeConstraint("Down the road", type, dictionary))

    private val perfectAndNear = listOf(
        "The window glowed", "The lantern showed", "Words I never wrote",
        "It glowed", "It showed", "The note I wrote"
    )

    private fun streamed(raw: List<String>, constraint: AIService.SuggestionRhymeConstraint?): List<SuggestedLine> =
        runBlocking {
            flow<SuggestedLine> {
                with(service) { emitLinesFromTokens(flowOf(raw.joinToString("\n") + "\n"), constraint) }
            }.toList()
        }

    @Test
    fun streamedSlantRequestKeepsSlantLinesBehindSixPerfectAndNearOnes() {
        val lines = streamed(perfectAndNear + listOf("Cold as stone", "Walking through the night", "Everything burned red"), constraint(RhymeType.SLANT))

        assertEquals(listOf("Cold as stone", "Everything burned red"), lines.map { it.text })
        assertEquals(listOf(3, 3), lines.map { it.rhymeTier })
    }

    @Test
    fun streamedNearRequestDropsPerfectSlantAndNonRhymingLines() {
        val lines = streamed(
            listOf("The window glowed", "Cold as stone", "Words I never wrote", "Walking through the night", "Everything burned red"),
            constraint(RhymeType.NEAR)
        )

        assertEquals(listOf("Words I never wrote"), lines.map { it.text })
        assertEquals(listOf(1), lines.map { it.rhymeTier })
    }

    @Test
    fun streamedPerfectRequestNoLongerPadsWithMisses() {
        val lines = streamed(listOf("Walking through the night", "The window glowed", "Cold as stone"), constraint(RhymeType.PERFECT))

        assertEquals(listOf("The window glowed"), lines.map { it.text })
        assertEquals(listOf(2), lines.map { it.rhymeTier })
    }

    @Test
    fun streamWithNoMatchingLineReportsTheRequestedRelation() {
        val error = assertFailsWith<AIService.NoMatchingRhymesException> {
            streamed(perfectAndNear.take(3), constraint(RhymeType.SLANT))
        }
        assertEquals(
            "The provider returned lines, but none matched the requested slant rhyme. Try another rhyme type.",
            error.message
        )
    }

    @Test
    fun noRhymeRequiredPositionStreamsEveryLineInArrivalOrder() {
        val raw = listOf("Walking through the night", "The window glowed", "Cold as stone")

        assertEquals(raw, streamed(raw, constraint = null).map { it.text })
        assertEquals(listOf(0, 0, 0), streamed(raw, constraint = null).map { it.rhymeTier })
    }
}
