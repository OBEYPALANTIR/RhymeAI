package com.rhymeai.app.util

import com.rhymeai.app.data.model.RhymeType
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The allowed end words the next-line prompt sends for Near and Slant, built
 * from the bundled dictionary and frequency list. iOS asserts the same lists
 * in `NearSlantCandidateListTests.swift`.
 */
class NearSlantCandidateListTest {
    private fun asset(name: String): File = sequenceOf(
        "../../shared/pronunciation/$name",
        "../shared/pronunciation/$name",
        "shared/pronunciation/$name"
    ).map(::File).first(File::isFile)

    private val dictionary: PronunciationDictionary by lazy {
        asset("cmudict-rhymeai.tsv").bufferedReader().useLines(PronunciationDictionary::fromLines)
    }
    private val frequency: WordFrequency by lazy {
        WordFrequency().also { wf -> asset("word-frequency.txt").bufferedReader().useLines(wf::load) }
    }

    private fun list(anchor: String, type: RhymeType): List<String> =
        RhymeConstraint.candidateEndWords(anchor, type, dictionary = dictionary, wordFrequency = frequency)

    private fun relation(candidate: String, target: String): RhymeType? =
        ProsodyAnalyzer.rhymeRelation(candidate, target, dictionary)

    private class Case(
        val anchor: String,
        val nearIncludes: List<String>,
        val nearExcludes: List<String>,
        val slantIncludes: List<String>,
        val slantExcludes: List<String>
    )

    private val cases = listOf(
        Case("chair", listOf("shared", "scared", "stairs", "prepared"), listOf("then", "when", "as", "them", "very", "said"),
            listOf("far", "star", "war", "sure"), listOf("then", "for", "are", "or", "your", "our")),
        Case("would", listOf("look", "took", "book", "foot"), listOf("your", "sure", "good", "full"),
            listOf("said", "food", "need", "full"), listOf("had", "did", "good")),
        Case("night", listOf("like", "side", "high", "try"), listOf("time", "line", "life", "while", "live", "light"),
            listOf("time", "life", "out", "find"), listOf("that", "it", "at", "not", "but", "what")),
        Case("home", listOf("phone", "known", "alone", "go"), listOf("so", "no", "those", "though", "both", "most"),
            listOf("time", "same", "name", "hope"), listOf("from", "some", "them", "him", "am")),
        Case("river", listOf("silver", "differ", "scissor"), listOf("dinner", "bigger", "winner", "twitter", "rivers"),
            listOf("over", "never", "cover", "winter"), listOf("however", "whatever", "whoever", "whenever")),
        Case("alone", listOf("home", "know", "go", "below"), listOf("so", "no", "those", "job", "in", "on"),
            listOf("one", "down", "done", "seen"), listOf("in", "on", "an", "can", "when", "than", "then", "been"))
    )

    @Test
    fun nearAndSlantListsHoldRealMatchesOnly() {
        for (case in cases) {
            val anchor = case.anchor
            val perfect = list(anchor, RhymeType.PERFECT).toSet()
            val near = list(anchor, RhymeType.NEAR)
            val slant = list(anchor, RhymeType.SLANT)

            case.nearIncludes.forEach { assertTrue(it in near, "$anchor near $near lacks $it") }
            case.nearExcludes.forEach { assertFalse(it in near, "$anchor near $near has $it") }
            case.slantIncludes.forEach { assertTrue(it in slant, "$anchor slant $slant lacks $it") }
            case.slantExcludes.forEach { assertFalse(it in slant, "$anchor slant $slant has $it") }

            assertFalse(anchor in near || anchor in slant)
            assertTrue(perfect.intersect(near.toSet()).isEmpty() && perfect.intersect(slant.toSet()).isEmpty())
            assertTrue(near.intersect(slant.toSet()).isEmpty())
            near.forEach {
                assertEquals(RhymeType.NEAR, relation(it, anchor), "$it is listed as near for $anchor")
            }
            slant.forEach {
                assertEquals(RhymeType.SLANT, relation(it, anchor), "$it is listed as slant for $anchor")
            }
            // Content words come before function words.
            for (words in listOf(near, slant)) {
                val firstFunction = words.indexOfFirst(ProsodyAnalyzer::isFunctionWord).takeIf { it >= 0 } ?: words.size
                assertTrue(words.drop(firstFunction).all(ProsodyAnalyzer::isFunctionWord), "$words")
            }
        }
    }

    @Test
    fun everyAnchorPronunciationDecidesTheRelation() {
        // abuse ends in /s/ or /z/: "news" is perfect against /z/, "used" near.
        assertEquals(RhymeType.PERFECT, ProsodyAnalyzer.rhymeRelation("news", "abuse", dictionary))
        assertEquals(RhymeType.NEAR, ProsodyAnalyzer.rhymeRelation("used", "abuse", dictionary))
        assertFalse("news" in list("abuse", RhymeType.NEAR))
        assertFalse("news" in list("abuse", RhymeType.SLANT))
        assertFalse("used" in list("abuse", RhymeType.SLANT))
    }

    /** Anchors with more than one pronunciation in the bundled dictionary. */
    private val multiPronunciationAnchors = listOf(
        "abuse", "read", "live", "close", "lead", "tear", "wind", "wound",
        "bow", "news", "minute", "record", "present", "object"
    )

    @Test
    fun everyListedWordVerifiesAsItsListsRelation() {
        for (anchor in multiPronunciationAnchors) {
            assertTrue(dictionary.pronunciations(anchor).size > 1, anchor)
            val matches = ProsodyAnalyzer.findRhymes(anchor, dictionary = dictionary, wordFrequency = frequency)
            for (type in RhymeType.entries) {
                // Only words that survive end-word extraction can come back in a line.
                for (word in list(anchor, type).filter { ProsodyAnalyzer.normalizeWord(it) == it }) {
                    assertEquals(type, ProsodyAnalyzer.rhymeRelation(word, anchor, dictionary), "$word is listed as $type for $anchor")
                    // Android's returned-line tiers: 2 perfect, 1 near; it has no slant tier.
                    val tier = RhymeConstraint.rhymeTier("I keep coming back to $word", anchor, matches, dictionary)
                    when (type) {
                        RhymeType.PERFECT -> assertEquals(2, tier, "perfect $word for $anchor")
                        RhymeType.NEAR -> assertEquals(1, tier, "near $word for $anchor")
                        RhymeType.SLANT -> Unit
                    }
                }
            }
        }
    }

    @Test
    fun theObservedChairEndingIsNoRhymeAtAll() {
        val matches = ProsodyAnalyzer.findRhymes("chair", dictionary = dictionary, wordFrequency = frequency)
        assertNull(relation("then", "chair"))
        assertFalse("then" in matches.near)
        assertFalse("then" in matches.slant)
    }

    @Test
    fun perfectListsAreUnchanged() {
        assertEquals(
            listOf(
                "good", "could", "should", "wood", "understood", "stood", "hollywood",
                "childhood", "neighborhood", "hood", "neighbourhood", "likelihood"
            ),
            list("would", RhymeType.PERFECT)
        )
        assertEquals(
            listOf(
                "right", "might", "white", "light", "quite", "fight", "site", "website",
                "tonight", "write", "despite", "flight"
            ),
            list("night", RhymeType.PERFECT)
        )
        assertEquals(
            listOf(
                "own", "known", "phone", "shown", "stone", "zone", "loan", "grown",
                "unknown", "tone", "bone", "iphone"
            ),
            list("alone", RhymeType.PERFECT)
        )
    }

    @Test
    fun tooFewMatchesReturnFewerWordsInsteadOfPadding() {
        val small = PronunciationDictionary.fromLines(
            sequenceOf("road\tR OW1 D", "wrote\tR OW1 T", "then\tDH EH1 N", "chair\tCH EH1 R")
        )
        assertEquals(listOf("wrote"), RhymeConstraint.candidateEndWords("road", RhymeType.NEAR, dictionary = small))
        assertTrue(RhymeConstraint.candidateEndWords("chair", RhymeType.NEAR, dictionary = small).isEmpty())
        assertTrue(RhymeConstraint.candidateEndWords("chair", RhymeType.SLANT, dictionary = small).isEmpty())
    }

    @Test
    fun relationsFollowTheSongwritingDefinitions() {
        assertEquals(RhymeType.NEAR, relation("ride", "night")) // same consonant family
        assertEquals(RhymeType.NEAR, relation("stairs", "chair")) // added consonant
        assertEquals(RhymeType.NEAR, relation("caring", "chair")) // extra unstressed syllable
        assertEquals(RhymeType.NEAR, relation("happy", "free")) // stress falls differently
        assertEquals(RhymeType.SLANT, relation("door", "chair")) // consonance
        assertEquals(RhymeType.SLANT, relation("time", "night")) // assonance
        assertNull(relation("then", "chair")) // R-coloured vowel differs, coda differs
    }
}
