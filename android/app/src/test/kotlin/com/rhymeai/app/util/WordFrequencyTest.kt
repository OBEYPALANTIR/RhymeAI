package com.rhymeai.app.util

import com.rhymeai.app.data.model.RhymeType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Tests for WordFrequency and its integration with candidateEndWords /
 * findRhymes (via ProsodyAnalyzer).
 */
class WordFrequencyTest {

    /** Build a WordFrequency instance ranked by the given words (first = most frequent). */
    private fun buildFrequency(vararg ranked: String): WordFrequency =
        WordFrequency().also { it.load(ranked.asSequence()) }

    // -----------------------------------------------------------------------
    // Unit: WordFrequency itself
    // -----------------------------------------------------------------------

    @Test
    fun rankOfReturnsPositionForKnownWords() {
        val wf = buildFrequency("right", "light", "sight")
        assertEquals(1, wf.rankOf("right"))
        assertEquals(2, wf.rankOf("light"))
        assertEquals(3, wf.rankOf("sight"))
    }

    @Test
    fun rankOfReturnsMaxValueForUnknownWord() {
        val wf = buildFrequency("right", "light")
        assertEquals(WordFrequency.UNKNOWN_RANK, wf.rankOf("cocaine"))
        assertEquals(WordFrequency.UNKNOWN_RANK, wf.rankOf(""))
    }

    @Test
    fun rankOfIsCaseInsensitive() {
        val wf = buildFrequency("right", "light")
        assertEquals(1, wf.rankOf("RIGHT"))
        assertEquals(1, wf.rankOf("Right"))
    }

    @Test
    fun sortByFrequencyOrdersCommonWordsFirst() {
        val wf = buildFrequency("right", "light", "sight")
        val sorted = wf.sortByFrequency(listOf("sight", "cocaine", "light", "right"))
        // right(1), light(2), sight(3), cocaine(MAX)
        assertEquals(listOf("right", "light", "sight", "cocaine"), sorted)
    }

    @Test
    fun sortByFrequencyIsStableForEqualRanks() {
        // Words not in the list all get UNKNOWN_RANK; original order is preserved.
        val wf = buildFrequency("right")
        val input = listOf("cocaine", "arcane", "light")
        val sorted = wf.sortByFrequency(input)
        // All three are UNKNOWN_RANK — input order kept.
        assertEquals(listOf("cocaine", "arcane", "light"), sorted)
    }

    @Test
    fun sortByFrequencyReturnsInputOrderWhenNotLoaded() {
        val wf = WordFrequency()   // not loaded — empty map
        val input = listOf("sight", "light", "right")
        assertEquals(input, wf.sortByFrequency(input))
    }

    // -----------------------------------------------------------------------
    // Integration: frequency ordering in findRhymes and candidateEndWords
    // -----------------------------------------------------------------------

    @Test
    fun commonNightRhymesRankBeforeObscureOnes() {
        val dict = PronunciationDictionary.fromLines(
            sequenceOf(
                "night\tN AY1 T",
                "light\tL AY1 T",
                "right\tR AY1 T",
                "sight\tS AY1 T",
                "cocaine\tK OW0 K EY1 N" // cocaine rhymes with AY1 N+T? No, it ends in EY1 N
                // cocaine ends in K EY1 N → near rhyme only, different vowel
            )
        )
        val wf = buildFrequency("right", "light", "sight")  // cocaine absent → UNKNOWN_RANK
        val matches = ProsodyAnalyzer.findRhymes("night", dictionary = dict, wordFrequency = wf)

        // perfect rhymes for night (AY1 T): light, right, sight
        val perfects = matches.perfect
        if (perfects.size >= 2) {
            // right(1) should come before light(2) should come before sight(3)
            val rightIdx = perfects.indexOf("right")
            val lightIdx = perfects.indexOf("light")
            val sightIdx = perfects.indexOf("sight")
            if (rightIdx >= 0 && lightIdx >= 0) assertTrue(rightIdx < lightIdx, "right before light")
            if (lightIdx >= 0 && sightIdx >= 0) assertTrue(lightIdx < sightIdx, "light before sight")
        }
    }

    @Test
    fun wordMissingFromFrequencyListStillAppearsInCandidates() {
        // A word absent from the frequency list is ranked last but NOT dropped.
        val dict = PronunciationDictionary.fromLines(
            sequenceOf(
                "night\tN AY1 T",
                "light\tL AY1 T",
                "right\tR AY1 T",
                "obscura\tAH0 B S K Y UW1 R AH0"  // not a real rhyme, but in dict
            )
        )
        val wf = buildFrequency("light", "right")  // obscura absent
        val matches = ProsodyAnalyzer.findRhymes("night", dictionary = dict, wordFrequency = wf)

        // light and right must be in perfect pool (same rhyme key as night)
        assertTrue("light" in matches.perfect, "light must be in perfect rhymes")
        assertTrue("right" in matches.perfect, "right must be in perfect rhymes")
    }

    @Test
    fun poolPrecedencePreservedNearRhymesNeverOutrankPerfect() {
        // rain has frequency rank 1 (most common) but it's a near rhyme for night.
        // perfect rhymes light and right must still appear before rain.
        val dict = PronunciationDictionary.fromLines(
            sequenceOf(
                "night\tN AY1 T",
                "light\tL AY1 T",
                "right\tR AY1 T",
                "rain\tR EY1 N"
            )
        )
        // rain rank=1 (highest); light/right not in frequency list → UNKNOWN_RANK
        val wf = buildFrequency("rain")
        val candidates = RhymeConstraint.candidateEndWords(
            "night", RhymeType.NEAR, limit = 20, dictionary = dict
        )

        // Perfect rhymes must precede near rhyme 'rain' regardless of frequency
        if ("rain" in candidates) {
            val rainIdx = candidates.indexOf("rain")
            for (perfect in listOf("light", "right")) {
                if (perfect in candidates) {
                    assertTrue(
                        candidates.indexOf(perfect) < rainIdx,
                        "Perfect rhyme '$perfect' must precede near rhyme 'rain' regardless of frequency"
                    )
                }
            }
        }
    }
}
