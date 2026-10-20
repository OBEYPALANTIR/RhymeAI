package com.rhymeai.app.util

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The word inspector's blank first result was a pending lookup, not a dictionary miss. */
class WordInspectorLookupTest {
    private val bundled: PronunciationDictionary by lazy {
        val asset = sequenceOf(
            "../../shared/pronunciation/cmudict-rhymeai.tsv",
            "../shared/pronunciation/cmudict-rhymeai.tsv",
            "shared/pronunciation/cmudict-rhymeai.tsv"
        ).map(::File).first(File::isFile)
        asset.bufferedReader().useLines(PronunciationDictionary::fromLines)
    }

    @Test
    fun selectedWordResolvesInTheBundledDictionaryHoweverItWasTyped() {
        listOf("harbor", "Harbor", "HARBOR", "harbor,").forEach { selected ->
            val prosody = ProsodyAnalyzer.analyzeWord(selected, bundled)

            assertFalse(prosody.isFallback, "$selected should come from the dictionary")
            assertEquals(2, prosody.syllableCount)
            assertEquals(listOf(1, 0), prosody.stressPattern)
            assertTrue(prosody.ipa.isNotEmpty())
        }
    }

    @Test
    fun firstRhymeLookupReturnsMatchesOnceTheIndexIsBuilt() {
        val first = ProsodyAnalyzer.findRhymes("harbor", dictionary = bundled)
        val second = ProsodyAnalyzer.findRhymes("night", dictionary = bundled)

        assertTrue("arbor" in first.perfect, "harbor rhymes were ${first.perfect.take(8)}")
        assertTrue(first.near.isNotEmpty())
        assertTrue(second.perfect.isNotEmpty())
    }
}
