package com.rhymeai.app.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ProsodyAnalyzerTest {
    private val dictionary = PronunciationDictionary.fromLines(
        sequenceOf(
            "yellow\tY EH1 L OW0",
            "music\tM Y UW1 Z IH0 K",
            "road\tR OW1 D",
            "glowed\tG L OW1 D",
            "radio\tR EY1 D IY0 OW2",
            "orange\tAO1 R AH0 N JH|AO1 R IH0 N JH"
        )
    )

    @Test
    fun countsLineSyllablesFromDictionaryStress() {
        val prosody = ProsodyAnalyzer.analyzeLine("yellow music", dictionary)

        assertEquals(4, prosody.syllableCount)
        assertEquals(listOf(1, 0, 1, 0), prosody.stressPattern)
        assertEquals("ˈDA da | ˈDA da", prosody.feet)
    }

    @Test
    fun rendersIpaPreviewWithStressMarkers() {
        val prosody = ProsodyAnalyzer.analyzeWord("music", dictionary)

        assertEquals("ˈmjuzɪk", prosody.ipa)
        assertFalse(prosody.isFallback)
    }

    @Test
    fun rendersSecondaryStressInIpaPreview() {
        val prosody = ProsodyAnalyzer.analyzeWord("radio", dictionary)

        assertEquals("ˈreɪdiˌoʊ", prosody.ipa)
        assertEquals(listOf(1, 0, 2), prosody.stressPattern)
        assertFalse(prosody.isFallback)
    }

    @Test
    fun usesFallbackForUnknownWords() {
        val prosody = ProsodyAnalyzer.analyzeWord("Scottys", dictionary)

        assertEquals(2, prosody.syllableCount)
        assertEquals(listOf(1, 0), prosody.stressPattern)
        assertTrue(prosody.isFallback)
    }

    @Test
    fun fallbackDistinguishesSyllabicLeFromSilentE() {
        // None of these are in the injected mini-dictionary, so all hit the fallback.
        // Consonant+"les" is a spoken syllable; vowel+"les" is a silent e.
        assertEquals(2, ProsodyAnalyzer.analyzeWord("tables", dictionary).syllableCount)
        assertEquals(3, ProsodyAnalyzer.analyzeWord("examples", dictionary).syllableCount)
        assertEquals(1, ProsodyAnalyzer.analyzeWord("miles", dictionary).syllableCount)
        assertEquals(1, ProsodyAnalyzer.analyzeWord("makes", dictionary).syllableCount)
    }

    @Test
    fun normalizesPunctuationDigitsAndInternalApostrophes() {
        assertEquals("don't", ProsodyAnalyzer.normalizeWord("  'Don't!!42"))

        val prosody = ProsodyAnalyzer.analyzeLine("Don't stop, road-99 glowed.", dictionary)

        assertEquals(listOf("don't", "stop", "road", "glowed"), prosody.words.map { it.normalized })
        assertEquals(4, prosody.syllableCount)
        assertEquals(listOf(1, 1, 1, 1), prosody.stressPattern)
    }

    @Test
    fun rhymeKeysUseCmuPhones() {
        val roadKeys = ProsodyAnalyzer.rhymeKeys("road", dictionary = dictionary)
        val glowedKeys = ProsodyAnalyzer.rhymeKeys("glowed", dictionary = dictionary)

        assertTrue(roadKeys.intersect(glowedKeys.toSet()).isNotEmpty())
    }

    @Test
    fun rhymeKeysIncludeMultipleDictionaryPronunciations() {
        val keys = ProsodyAnalyzer.rhymeKeys("orange", dictionary = dictionary)

        assertEquals(
            listOf(
                "AO R AH N JH",
                "AO R IH N JH"
            ),
            keys
        )
    }

    @Test
    fun findRhymesReturnsPerfectMatchesFromDictionary() {
        val matches = ProsodyAnalyzer.findRhymes("road", dictionary = dictionary)

        assertTrue(matches.perfect.contains("glowed"), "expected glowed as a perfect rhyme for road")
        assertFalse(matches.perfect.contains("road"), "perfect bucket should exclude the query word")
    }

    @Test
    fun findRhymesIsEmptyForStopwords() {
        val matches = ProsodyAnalyzer.findRhymes("the", dictionary = dictionary)

        assertTrue(matches.isEmpty)
    }

    @Test
    fun findRhymesIsEmptyForUnknownVeryShortWord() {
        val matches = ProsodyAnalyzer.findRhymes("a", dictionary = dictionary)

        assertTrue(matches.isEmpty)
    }
}
