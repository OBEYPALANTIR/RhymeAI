package com.rhymeai.app.util

import com.rhymeai.app.data.model.RhymeType
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Rhyme-word-first constrained generation: candidate ending words, tier
 * verification, and the returned-line filter. The tier and filter cases
 * mirror iOS `RhymeConstraintTests.swift`.
 */
class RhymeConstraintTest {
    private val dictionary = PronunciationDictionary.fromLines(
        sequenceOf(
            "road\tR OW1 D",
            "glowed\tG L OW1 D",
            "showed\tSH OW1 D",
            "stone\tS T OW1 N",
            "bones\tB OW1 N Z",
            "wrote\tR OW1 T",
            "red\tR EH1 D",
            "night\tN AY1 T",
            "rain\tR EY1 N"
        )
    )

    private val bundled: PronunciationDictionary by lazy {
        sequenceOf(
            "../../shared/pronunciation/cmudict-rhymeai.tsv",
            "../shared/pronunciation/cmudict-rhymeai.tsv",
            "shared/pronunciation/cmudict-rhymeai.tsv"
        ).map(::File).first(File::isFile).bufferedReader().useLines(PronunciationDictionary::fromLines)
    }

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
        assertEquals(listOf("bones", "red", "stone"), RhymeConstraint.candidateEndWords("road", RhymeType.SLANT, dictionary = dictionary))
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

    @Test
    fun filterAndRankAdmitsOnlyTheRequestedRelation() {
        val lines = listOf(
            "The window glowed",
            "Words I never wrote",
            "Cold as stone",
            "Everything burned red",
            "Walking through the night"
        )

        assertEquals(
            listOf("Words I never wrote"),
            RhymeConstraint.filterAndRank(lines, "Down the road", RhymeType.NEAR, 2, dictionary)
        )
        assertEquals(
            listOf("Cold as stone", "Everything burned red"),
            RhymeConstraint.filterAndRank(lines, "Down the road", RhymeType.SLANT, 2, dictionary)
        )
        assertEquals(
            listOf("The window glowed"),
            RhymeConstraint.filterAndRank(lines, "Down the road", RhymeType.PERFECT, 2, dictionary)
        )
    }

    @Test
    fun nearRequestKeepsOnlyNearLinesFromAMixedResponse() {
        // Perfect, near, slant, and non-rhyming endings, perfect first.
        val lines = listOf(
            "The lonely window showed",
            "It glowed",
            "Something that I never wrote",
            "Cold as stone",
            "Everything burned red",
            "Walking through the night",
            "I wrote"
        )

        // Closest syllable count to the three-syllable target first.
        assertEquals(
            listOf("I wrote", "Something that I never wrote"),
            RhymeConstraint.filterAndRank(lines, "Down the road", RhymeType.NEAR, 6, dictionary)
        )
    }

    @Test
    fun slantRequestKeepsSlantLinesBehindSixPerfectAndNearOnes() {
        val deviations = listOf(
            "The window glowed", "The lantern showed", "Words I never wrote",
            "It glowed", "It showed", "The note I wrote"
        )
        val slant = listOf("Cold as stone", "Everything burned red")

        assertEquals(slant, RhymeConstraint.filterAndRank(deviations + slant, "Down the road", RhymeType.SLANT, 6, dictionary))
    }

    @Test
    fun rhymeTiersNameEveryRelationTruthfully() {
        assertEquals(2, RhymeConstraint.rhymeTier("The window glowed", "road", dictionary))
        assertEquals(1, RhymeConstraint.rhymeTier("Words I never wrote", "road", dictionary))
        assertEquals(3, RhymeConstraint.rhymeTier("Cold as stone", "road", dictionary))
        assertEquals(3, RhymeConstraint.rhymeTier("Everything burned red", "road", dictionary))
    }

    @Test
    fun bundledAlternateTargetPronunciationCanMakeAPerfectRhyme() {
        assertEquals(2, bundled.pronunciations("abuse").size)
        assertEquals(2, bundled.pronunciations("news").size)
        assertEquals(1, bundled.pronunciations("blues").size)
        assertEquals(2, RhymeConstraint.rhymeTier("The evening news", "abuse", bundled))
        assertEquals(2, RhymeConstraint.rhymeTier("I sing the blues", "abuse", bundled))
        assertEquals(2, RhymeConstraint.rhymeTier("A little juice", "abuse", bundled))
        assertEquals(0, RhymeConstraint.rhymeTier("The long night", "abuse", bundled))
        assertEquals(0, RhymeConstraint.rhymeTier("The evening news", "unknownzz", bundled))
        assertEquals(0, RhymeConstraint.rhymeTier("My abuse", "abuse", bundled))
        assertNull(ProsodyAnalyzer.rhymeTail("the", bundled))
    }

    @Test
    fun alternateTargetAndCandidatePronunciationsPreserveNearAndSlant() {
        val variants = PronunciationDictionary.fromLines(sequenceOf(
            "anchor\tR OW1 D|R AY1 M",
            "match\tK AY1 M",
            "alternate\tK EH1 P|K AY1 M",
            "nearword\tN OW1 T",
            "slantword\tS EH1 D",
            "miss\tM UW1 P"
        ))
        assertEquals(RhymeType.PERFECT, ProsodyAnalyzer.rhymeRelation("match", "anchor", variants))
        assertEquals(RhymeType.PERFECT, ProsodyAnalyzer.rhymeRelation("alternate", "anchor", variants))
        assertEquals(RhymeType.NEAR, ProsodyAnalyzer.rhymeRelation("nearword", "anchor", variants))
        assertEquals(RhymeType.SLANT, ProsodyAnalyzer.rhymeRelation("slantword", "anchor", variants))
        assertNull(ProsodyAnalyzer.rhymeRelation("miss", "anchor", variants))
        assertNull(ProsodyAnalyzer.rhymeRelation("anchor", "anchor", variants))
    }

    @Test
    fun filterAndRankClassifiesReturnedEndingsOutsidePromptCap() {
        val words = (0 until 61).map { "zz" + "a".repeat(it + 2) }
        val crowded = PronunciationDictionary.fromLines(
            sequenceOf("anchor\tR AY1 M") + words.asSequence().map { "$it\tR AY1 M" }
        )
        val capped = ProsodyAnalyzer.findRhymes("anchor", dictionary = crowded, wordFrequency = WordFrequency()).perfect.toSet()
        val outsideCap = words.first { it !in capped }
        val line = "Beyond the $outsideCap"

        assertEquals(2, RhymeConstraint.rhymeTier(line, "anchor", crowded))
        assertEquals(listOf(line), RhymeConstraint.filterAndRank(listOf(line), "Find the anchor", RhymeType.PERFECT, 1, crowded))
    }

    @Test
    fun filterAndRankPrefersRhymingLinesRegardlessOfOrder() {
        val rhyming = "We chase the fading light"
        val nonRhyming = "Nothing here can save us"

        assertEquals(listOf(rhyming), RhymeConstraint.filterAndRank(listOf(nonRhyming, rhyming), "We own the night", RhymeType.PERFECT, 1, bundled))
        assertEquals(listOf(rhyming), RhymeConstraint.filterAndRank(listOf(rhyming, nonRhyming), "We own the night", RhymeType.PERFECT, 1, bundled))
    }

    @Test
    fun filterAndRankRejectsKnownNonRhymingLines() {
        val rhyming = "Out beyond the light"
        val ranked = RhymeConstraint.filterAndRank(
            listOf("Nothing here can save us", rhyming, "The morning comes too soon"),
            "We own the night", RhymeType.PERFECT, 3, bundled
        )

        assertEquals(listOf(rhyming), ranked)
    }

    @Test
    fun filterAndRankReturnsEmptyWhenKnownTargetHasNoMatchingSuggestion() {
        val lines = listOf("The morning comes too soon", "Nothing here can save us")

        assertTrue(RhymeConstraint.filterAndRank(lines, "We own the night", RhymeType.PERFECT, 2, bundled).isEmpty())
        // No rhyme required: an unknown target word keeps arrival order.
        assertEquals(listOf(lines[0]), RhymeConstraint.filterAndRank(lines, "Surrounded by the zzzqxv", RhymeType.PERFECT, 1, bundled))
    }

    @Test
    fun filterAndRankBreaksTierTiesBySyllableDistance() {
        val ranked = RhymeConstraint.filterAndRank(
            listOf("The lonely window showed", "It glowed"), "Down the road", RhymeType.PERFECT, 2, dictionary
        )

        assertEquals(listOf("It glowed", "The lonely window showed"), ranked)
    }

    @Test
    fun filterAndRankDedupesByNormalizedText() {
        val line = "We chase the light"

        assertEquals(
            listOf(line),
            RhymeConstraint.filterAndRank(listOf(line, "WE CHASE THE LIGHT!!"), "We own the night", RhymeType.PERFECT, 6, bundled)
        )
    }

    @Test
    fun rhymeLineFilterMirrorsThePromptGate() {
        assertNotNull(RhymeLineFilter.create("We own the night", RhymeType.PERFECT, bundled))
        assertNull(RhymeLineFilter.create(null, RhymeType.PERFECT, bundled))
        assertNull(RhymeLineFilter.create("  ", RhymeType.PERFECT, bundled))
        assertNull(RhymeLineFilter.create("Surrounded by the zzzqxv", RhymeType.PERFECT, bundled))
        // No near rhyme in the fixture for "rain", so a Near request is not filtered.
        assertNull(RhymeLineFilter.create("Out in the rain", RhymeType.NEAR, dictionary))
    }
}
