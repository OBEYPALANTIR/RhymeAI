package com.rhymeai.app

import com.rhymeai.app.data.model.SongSection
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class RhymeContextAnalyzerTest {

    @Test
    fun ignoresSectionHeadersForSchemePosition() {
        val lyrics = "[Verse 1]\nfirst light\nsecond night"

        val context = RhymeContextAnalyzer.compute(
            text = lyrics,
            cursor = lyrics.length,
            scheme = "AABB"
        )

        assertEquals("A", context.currentLetter)
        assertEquals("first light", context.targetLine)
        assertEquals(2, context.currentLineIndex)
        assertEquals(SongSection.VERSE, context.currentSection)
    }

    @Test
    fun usesLatestPreviousLyricWithSameLetter() {
        val lyrics = "[Chorus]\nfirst glow\nsecond rain\nthird road\nfourth rain"

        val context = RhymeContextAnalyzer.compute(
            text = lyrics,
            cursor = lyrics.length,
            scheme = "ABAB"
        )

        assertEquals("B", context.currentLetter)
        assertEquals("second rain", context.targetLine)
        assertEquals(SongSection.CHORUS, context.currentSection)
    }

    @Test
    fun ignoresBareSectionHeadersForSchemePositionAndSectionDetection() {
        val lyrics = "verse\nfirst light\nsecond night\npre-chorus\nbuild higher"

        val context = RhymeContextAnalyzer.compute(
            text = lyrics,
            cursor = lyrics.length,
            scheme = "ABAB"
        )

        assertEquals("A", context.currentLetter)
        assertEquals(SongSection.UNKNOWN, context.currentSection)
        assertEquals("pre-chorus", context.currentSectionRef?.label)
    }

    @Test
    fun detectsBridgeSectionForPromptShaping() {
        val lyrics = "[Verse 1]\nfirst line\n\n[Bridge]\nnew angle"

        val context = RhymeContextAnalyzer.compute(
            text = lyrics,
            cursor = lyrics.length,
            scheme = "AABB"
        )

        assertEquals(SongSection.BRIDGE, context.currentSection)
    }

    @Test
    fun preservesUtf16CursorContextAndSectionReference() {
        val lyrics = "[Verse]\nfirst glow\n🎵 second rain\nthird road"
        val cursor = lyrics.indexOf("third") + 2

        val context = RhymeContextAnalyzer.compute(
            text = lyrics,
            cursor = cursor,
            scheme = "ABAB"
        )

        assertEquals("A", context.currentLetter)
        assertEquals("first glow", context.targetLine)
        assertEquals(3, context.currentLineIndex)
        assertEquals(SongSection.VERSE, context.currentSection)
        assertEquals("Verse", context.currentSectionRef?.label)
        assertEquals(1, context.currentSectionRef?.ordinal)
    }

    @Test
    fun clampsCursorAndFallsBackForEmptyScheme() {
        val lyrics = "[Verse]\nfirst line\nsecond line"

        val context = RhymeContextAnalyzer.compute(
            text = lyrics,
            cursor = Int.MAX_VALUE,
            scheme = ""
        )

        assertEquals("A", context.currentLetter)
        assertNull(context.targetLine)
        assertEquals(2, context.currentLineIndex)
        assertEquals(SongSection.VERSE, context.currentSection)
        assertNull(context.currentSectionRef)
    }

    @Test
    fun emptyLyricsUseFirstSchemeLetter() {
        val context = RhymeContextAnalyzer.compute(
            text = "",
            cursor = 100,
            scheme = "BABA"
        )

        assertEquals("B", context.currentLetter)
        assertNull(context.targetLine)
        assertEquals(emptyList(), context.stanzaLines)
        assertEquals(0, context.currentLineIndex)
        assertEquals(SongSection.UNKNOWN, context.currentSection)
    }
}
