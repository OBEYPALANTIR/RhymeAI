package com.rhymeai.app.util

import com.rhymeai.app.data.model.RhymeType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RhymeConstraintTest {
    private val dictionary = PronunciationDictionary.fromLines(
        sequenceOf(
            "road\tR OW1 D",
            "glowed\tG L OW1 D",
            "showed\tSH OW1 D",
            "stone\tS T OW1 N",
            "night\tN AY1 T",
            "rain\tR EY1 N"
        )
    )

    @Test
    fun lineEndWordStripsPunctuationQuotesAndDashes() {
        assertEquals("rain", RhymeConstraint.lineEndWord("alive through rain!"))
        assertEquals("rain", RhymeConstraint.lineEndWord("she said \"rain\""))
        assertEquals("rain", RhymeConstraint.lineEndWord("cold as the rain—"))
        assertEquals("rain", RhymeConstraint.lineEndWord("  rain...  "))
        assertEquals("", RhymeConstraint.lineEndWord("—!?"))
    }

    @Test
    fun candidateEndWordsReturnsPerfectRhymesAndExcludesTarget() {
        val words = RhymeConstraint.candidateEndWords("road", RhymeType.PERFECT, dictionary = dictionary)

        assertTrue(words.isNotEmpty(), "expected perfect rhyme candidates for road")
        assertTrue("glowed" in words)
        assertTrue("showed" in words)
        assertFalse("road" in words, "candidates must exclude the target word")
        assertFalse("stone" in words, "perfect rhyme type must not pad with near rhymes")
    }

    @Test
    fun candidateEndWordsPadsLooserTypesWithNearRhymes() {
        val words = RhymeConstraint.candidateEndWords("road", RhymeType.SLANT, dictionary = dictionary)

        assertEquals(listOf("glowed", "showed", "stone"), words)
    }

    @Test
    fun candidateEndWordsIsEmptyForUnknownWords() {
        assertTrue(RhymeConstraint.candidateEndWords("zzzqq", RhymeType.PERFECT, dictionary = dictionary).isEmpty())
        assertTrue(RhymeConstraint.candidateEndWords("blorvex", RhymeType.SLANT, dictionary = dictionary).isEmpty())
    }

    @Test
    fun rhymeTierClassifiesPerfectNearAndMisses() {
        assertEquals(2, RhymeConstraint.rhymeTier("The window glowed", "road", dictionary))
        assertEquals(1, RhymeConstraint.rhymeTier("Cold as stone", "road", dictionary))
        assertEquals(0, RhymeConstraint.rhymeTier("Walking in the night", "road", dictionary))
        assertEquals(0, RhymeConstraint.rhymeTier("", "road", dictionary))
    }

    @Test
    fun filterAndRankPrefersPerfectRhymeRegardlessOfInputOrder() {
        val lines = listOf("Walking in the night", "The window glowed")

        val ranked = RhymeConstraint.filterAndRank(
            lines = lines,
            targetLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            want = 1,
            dictionary = dictionary
        )

        assertEquals(listOf("The window glowed"), ranked)
    }

    @Test
    fun filterAndRankBreaksTierTiesBySyllableDistance() {
        // Both end in perfect rhymes; the closer syllable count should win
        // even though it arrives later in the input.
        val lines = listOf("The lonely window showed", "It glowed")

        val ranked = RhymeConstraint.filterAndRank(
            lines = lines,
            targetLine = "Down the road",
            rhymeType = RhymeType.PERFECT,
            want = 2,
            dictionary = dictionary
        )

        assertEquals(listOf("It glowed", "The lonely window showed"), ranked)
    }

    @Test
    fun filterAndRankTopsUpWithNonRhymingLinesWhenTooFewPass() {
        val lines = listOf("Walking in the night", "The window glowed")

        val ranked = RhymeConstraint.filterAndRank(
            lines = lines,
            targetLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            want = 2,
            dictionary = dictionary
        )

        assertEquals(listOf("The window glowed", "Walking in the night"), ranked)
    }

    @Test
    fun filterAndRankNeverReturnsEmptyForNonEmptyInput() {
        val lines = listOf("Counting every breath", "Holding to the wheel")

        val ranked = RhymeConstraint.filterAndRank(
            lines = lines,
            targetLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            want = 2,
            dictionary = dictionary
        )

        assertEquals(lines, ranked)
    }

    @Test
    fun filterAndRankDedupesByNormalizedText() {
        val lines = listOf("The window glowed", "the window GLOWED!!", "Cold as stone")

        val ranked = RhymeConstraint.filterAndRank(
            lines = lines,
            targetLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            want = 3,
            dictionary = dictionary
        )

        assertEquals(listOf("The window glowed", "Cold as stone"), ranked)
    }
}
