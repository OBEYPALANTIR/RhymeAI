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
    fun usesFallbackForUnknownWords() {
        val prosody = ProsodyAnalyzer.analyzeWord("Scottys", dictionary)

        assertEquals(2, prosody.syllableCount)
        assertEquals(listOf(1, 0), prosody.stressPattern)
        assertTrue(prosody.isFallback)
    }

    @Test
    fun rhymeKeysUseCmuPhones() {
        val roadKeys = ProsodyAnalyzer.rhymeKeys("road", dictionary = dictionary)
        val glowedKeys = ProsodyAnalyzer.rhymeKeys("glowed", dictionary = dictionary)

        assertTrue(roadKeys.intersect(glowedKeys.toSet()).isNotEmpty())
    }
}
