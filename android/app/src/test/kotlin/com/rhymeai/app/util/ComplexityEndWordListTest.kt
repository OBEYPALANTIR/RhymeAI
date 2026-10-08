package com.rhymeai.app.util

import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The complexity level's view of the allowed end-word list
 * (`RhymeConstraint.levelEndWords`): two-or-more-syllable rhymes first at
 * Complex, one-syllable rhymes only at Simple (with the under-six fallback),
 * and Moderate untouched. The shared fixture pins the exact lists the eval's
 * `scoring.candidate_end_words` builds for the same anchors; iOS asserts the
 * same rule in `RhymeConstraintTests.swift`.
 */
class ComplexityEndWordListTest {
    // Perfect rhymes of "road". No frequency list, so the order is the
    // dictionary (insertion) order; "episode" (EH1 P AH0 S OW2 D) comes from
    // the multisyllabic pool, after every exact match.
    private val dictionary = PronunciationDictionary.fromLines(
        sequenceOf(
            "road\tR OW1 D",
            "explode\tIH0 K S P L OW1 D",
            "glowed\tG L OW1 D",
            "overload\tOW2 V ER0 L OW1 D",
            "showed\tSH OW1 D",
            "bestowed\tB IH0 S T OW1 D",
            "rode\tR OW1 D",
            "code\tK OW1 D",
            "load\tL OW1 D",
            "owed\tOW1 D",
            "towed\tT OW1 D",
            "episode\tEH1 P AH0 S OW2 D"
        )
    )
    private val noFrequency = WordFrequency()

    private fun list(complexity: RhymeComplexity, limit: Int = 12): List<String> =
        RhymeConstraint.candidateEndWords(
            "road", RhymeType.PERFECT, limit = limit, dictionary = dictionary, wordFrequency = noFrequency,
            complexity = complexity
        )

    @Test
    fun moderateIsTheFrequencyOrderAndTheDefault() {
        val moderate = listOf(
            "explode", "glowed", "overload", "showed", "bestowed", "rode", "code", "load", "owed", "towed", "episode"
        )
        assertEquals(moderate, list(RhymeComplexity.MODERATE))
        assertEquals(
            moderate,
            RhymeConstraint.candidateEndWords("road", RhymeType.PERFECT, dictionary = dictionary, wordFrequency = noFrequency)
        )
        assertEquals(moderate.take(12), RhymeConstraint.levelEndWords(moderate, RhymeComplexity.MODERATE, 12, dictionary))
    }

    @Test
    fun complexPutsTwoOrMoreSyllableWordsFirstStably() {
        assertEquals(
            listOf("explode", "overload", "bestowed", "episode", "glowed", "showed", "rode", "code", "load", "owed", "towed"),
            list(RhymeComplexity.COMPLEX)
        )
        assertEquals(listOf("explode", "overload", "bestowed", "episode"), list(RhymeComplexity.COMPLEX, limit = 4))
        assertEquals(listOf("explode", "overload", "bestowed", "episode", "glowed"), list(RhymeComplexity.COMPLEX, limit = 5))
    }

    @Test
    fun simpleKeepsOneSyllableWordsOnly() {
        assertEquals(listOf("glowed", "showed", "rode", "code", "load", "owed", "towed"), list(RhymeComplexity.SIMPLE))
    }

    @Test
    fun simpleFallsBackToTheRemainingWordsBelowSix() {
        val ordered = listOf("explode", "glowed", "overload", "showed", "bestowed")
        assertEquals(
            listOf("glowed", "showed", "explode", "overload", "bestowed"),
            RhymeConstraint.levelEndWords(ordered, RhymeComplexity.SIMPLE, 12, dictionary)
        )
        assertEquals(
            listOf("glowed", "showed", "explode"),
            RhymeConstraint.levelEndWords(ordered, RhymeComplexity.SIMPLE, 3, dictionary)
        )
        assertEquals(6, RhymeConstraint.SIMPLE_MIN_MONOSYLLABLES)
    }

    // --- Shared fixture: byte-for-byte parity with finetune/eval/scoring.py ---

    private fun repoFile(path: String): File =
        sequenceOf("../../$path", "../$path", path).map(::File).first(File::isFile)

    private val bundled: PronunciationDictionary by lazy {
        repoFile("shared/pronunciation/cmudict-rhymeai.tsv").bufferedReader().useLines(PronunciationDictionary::fromLines)
    }
    private val bundledFrequency: WordFrequency by lazy {
        WordFrequency().also { wf -> repoFile("shared/pronunciation/word-frequency.txt").bufferedReader().useLines(wf::load) }
    }

    @Test
    fun listsMatchTheSharedEvalFixtureAtEveryLevel() {
        val fixture = Json.parseToJsonElement(repoFile("shared/fixtures/complexity-end-words-v1.json").readText()).jsonObject
        val limit = fixture.getValue("limit").jsonPrimitive.int
        val cases = fixture.getValue("cases").jsonArray.map { it.jsonObject }
        assertEquals(33, cases.size)
        for (case in cases) {
            val anchor = case.getValue("anchor").jsonPrimitive.content
            val type = RhymeType.valueOf(case.getValue("rhymeType").jsonPrimitive.content)
            val complexity = RhymeComplexity.valueOf(case.getValue("complexity").jsonPrimitive.content)
            val expected = case.getValue("expected").jsonArray.map { it.jsonPrimitive.content }
            assertEquals(
                expected,
                RhymeConstraint.candidateEndWords(
                    anchor, type, limit = limit, dictionary = bundled, wordFrequency = bundledFrequency,
                    complexity = complexity
                ),
                "$anchor $type $complexity"
            )
        }
    }

    @Test
    fun bundledListsFollowTheLevelRule() {
        fun syllables(word: String) = ProsodyAnalyzer.analyzeWord(word, bundled).syllableCount
        fun bundledList(anchor: String, complexity: RhymeComplexity) = RhymeConstraint.candidateEndWords(
            anchor, RhymeType.PERFECT, dictionary = bundled, wordFrequency = bundledFrequency, complexity = complexity
        )
        for (anchor in listOf("home", "night", "road", "alone", "glow", "time")) {
            val moderate = bundledList(anchor, RhymeComplexity.MODERATE)
            val complex = bundledList(anchor, RhymeComplexity.COMPLEX)
            val simple = bundledList(anchor, RhymeComplexity.SIMPLE)
            assertTrue(complex.all { syllables(it) >= 2 }, "$anchor complex $complex")
            assertTrue(simple.all { syllables(it) == 1 }, "$anchor simple $simple")
            assertEquals(12, complex.size, anchor)
            assertEquals(12, simple.size, anchor)
            // The frequency order survives inside each group.
            assertEquals(moderate.filter { syllables(it) >= 2 }, complex.filter { it in moderate }, anchor)
            assertEquals(moderate.filter { syllables(it) == 1 }, simple.filter { it in moderate }, anchor)
        }
        // Fewer than six one-syllable rhymes: they lead, then the rest in order.
        for (anchor in listOf("world", "love")) {
            val simple = bundledList(anchor, RhymeComplexity.SIMPLE)
            val mono = simple.filter { syllables(it) == 1 }
            assertTrue(mono.size in 1..5, "$anchor $simple")
            assertEquals(mono, simple.take(mono.size), anchor)
            assertEquals(12, simple.size, anchor)
        }
        // No one-syllable rhyme at all, and fewer than twelve rhymes: every level lists the same words.
        val arrival = bundledList("arrival", RhymeComplexity.MODERATE)
        assertTrue(arrival.size in 1..5, "$arrival")
        assertEquals(arrival, bundledList("arrival", RhymeComplexity.SIMPLE))
        assertEquals(arrival, bundledList("arrival", RhymeComplexity.COMPLEX))
    }
}
