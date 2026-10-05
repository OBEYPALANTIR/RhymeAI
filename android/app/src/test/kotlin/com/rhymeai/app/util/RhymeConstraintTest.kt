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
            "wrote\tR OW1 T",
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
    fun candidateEndWordsKeepRhymeModesExclusive() {
        // D and T are both plosives; N is a nasal, so "stone" is assonance.
        assertEquals(listOf("wrote"), RhymeConstraint.candidateEndWords("road", RhymeType.NEAR, dictionary = dictionary))
        assertEquals(listOf("stone"), RhymeConstraint.candidateEndWords("road", RhymeType.SLANT, dictionary = dictionary))
    }

    @Test
    fun candidateEndWordsIsEmptyForUnknownWords() {
        assertTrue(RhymeConstraint.candidateEndWords("zzzqq", RhymeType.PERFECT, dictionary = dictionary).isEmpty())
        assertTrue(RhymeConstraint.candidateEndWords("blorvex", RhymeType.SLANT, dictionary = dictionary).isEmpty())
    }

    @Test
    fun rhymeTierClassifiesPerfectNearAndMisses() {
        assertEquals(2, RhymeConstraint.rhymeTier("The window glowed", "road", dictionary))
        assertEquals(1, RhymeConstraint.rhymeTier("Words I never wrote", "road", dictionary))
        assertEquals(0, RhymeConstraint.rhymeTier("Walking in the night", "road", dictionary))
        assertEquals(0, RhymeConstraint.rhymeTier("", "road", dictionary))
    }

    private fun crowdedRainDictionary(): PronunciationDictionary = PronunciationDictionary.fromLines(
        sequenceOf("rain\tR EY1 N", "pain\tP EY1 N") +
            (0 until 65).asSequence().map { index ->
                "rhyme${'a' + index / 26}${'a' + index % 26}\tR EY1 N"
            } + sequenceOf("wane\tW EY1 N", "night\tN AY1 T")
    )

    @Test
    fun perfectRhymeOutsideCappedPoolStillReceivesTierTwo() {
        val crowded = crowdedRainDictionary()
        val matches = ProsodyAnalyzer.findRhymes(
            "rain", dictionary = crowded, wordFrequency = WordFrequency()
        )

        assertEquals(60, matches.perfect.size)
        assertFalse("wane" in matches.perfect)
        assertEquals(0, RhymeConstraint.rhymeTier("The lights wane", matches))
        assertEquals(2, RhymeConstraint.rhymeTier("The lights wane", "rain", matches, crowded))
        assertEquals(2, RhymeConstraint.rhymeTier("The lights wane!", "RAIN", crowded))
        assertEquals(0, RhymeConstraint.rhymeTier("The dark night", "rain", matches, crowded))
        assertEquals(12, RhymeConstraint.candidateEndWords("rain", RhymeType.PERFECT, dictionary = crowded).size)
    }

    @Test
    fun pairwiseFallbackUsesAllPronunciationsFromTheSuppliedDictionary() {
        val variants = PronunciationDictionary.fromLines(sequenceOf(
            "read\tR IY1 D|R EH1 D",
            "red\tR EH1 D",
            "reed\tR IY1 D",
            "rain\tR EY1 N",
            "wane\tW AH1 N"
        ))

        assertEquals(2, RhymeConstraint.rhymeTier("Paint it red", "read", RhymeMatches.EMPTY, variants))
        assertEquals(2, RhymeConstraint.rhymeTier("Words I read", "red", RhymeMatches.EMPTY, variants))
        assertEquals(2, RhymeConstraint.rhymeTier("A broken reed", "read", RhymeMatches.EMPTY, variants))
        assertEquals(0, RhymeConstraint.rhymeTier("The lights wane", "rain", RhymeMatches.EMPTY, variants))
    }

    @Test
    fun alternatePronunciationPerfectRhymeOverridesCachedNearTier() {
        // Pronunciations from the bundled CMU dictionary; abuse has noun/verb variants.
        val variants = PronunciationDictionary.fromLines(sequenceOf(
            "abuse\tAH0 B Y UW1 S|AH0 B Y UW1 Z",
            "news\tN UW1 Z|N Y UW1 Z",
            "blues\tB L UW1 Z",
            "goose\tG UW1 S",
            "truth\tT R UW1 TH"
        ))
        val matches = ProsodyAnalyzer.findRhymes("abuse", dictionary = variants)

        for (word in listOf("news", "blues")) {
            assertEquals(1, RhymeConstraint.rhymeTier(word, matches))
            assertEquals(2, RhymeConstraint.rhymeTier(word, "abuse", matches, variants))
            assertEquals(2, RhymeConstraint.rhymeTier(word, "abuse", RhymeMatches.EMPTY, variants))
        }
        assertEquals(2, RhymeConstraint.rhymeTier("goose", matches))
        assertEquals(2, RhymeConstraint.rhymeTier("goose", "abuse", matches, variants))
        assertEquals(1, RhymeConstraint.rhymeTier("truth", matches))
        assertEquals(1, RhymeConstraint.rhymeTier("truth", "abuse", matches, variants))
        assertEquals(0, RhymeConstraint.rhymeTier("truth", "abuse", RhymeMatches.EMPTY, variants))
    }

    @Test
    fun pairwiseFallbackDoesNotCertifyTargetsStopwordsOrUnknownSpellings() {
        val guarded = PronunciationDictionary.fromLines(sequenceOf(
            "rain\tR EY1 N", "wane\tW EY1 N", "glow\tG L OW1", "so\tS OW1"
        ))

        assertEquals(0, RhymeConstraint.rhymeTier("The rain", "rain", RhymeMatches.EMPTY, guarded))
        assertEquals(0, RhymeConstraint.rhymeTier("Even so", "glow", RhymeMatches.EMPTY, guarded))
        assertEquals(0, RhymeConstraint.rhymeTier("A soft glow", "so", RhymeMatches.EMPTY, guarded))
        assertEquals(0, RhymeConstraint.rhymeTier("Unknown spane", "rain", RhymeMatches.EMPTY, guarded))
        assertEquals(0, RhymeConstraint.rhymeTier("The lights wane", "spane", RhymeMatches.EMPTY, guarded))
        assertEquals(0, RhymeConstraint.rhymeTier("Unknown blane", "spane", RhymeMatches.EMPTY, guarded))
        assertEquals(0, RhymeConstraint.rhymeTier("The lights wane", "rain", RhymeMatches.EMPTY, dictionary))
    }

    @Test
    fun targetAwareBatchTierPreservesExistingNearAndMissClassifications() {
        val matches = ProsodyAnalyzer.findRhymes("road", dictionary = dictionary)

        assertEquals(1, RhymeConstraint.rhymeTier("Words I never wrote", "road", matches, dictionary))
        assertEquals(0, RhymeConstraint.rhymeTier("Into the night", "road", matches, dictionary))
        assertEquals(0, RhymeConstraint.rhymeTier("The sky rains", "road", RhymeMatches.EMPTY, dictionary))
    }

    @Test
    fun rankingDoesNotDemotePerfectRhymesOutsideTheDisplayPool() {
        val crowded = crowdedRainDictionary()
        val lines = listOf("My lonely journey starts to wane", "My lonely journey brings me pain")

        for (type in RhymeType.entries) {
            assertEquals(
                listOf(lines.first()),
                RhymeConstraint.filterAndRank(lines, "My lonely journey ends in rain", type, 1, crowded)
            )
        }
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
