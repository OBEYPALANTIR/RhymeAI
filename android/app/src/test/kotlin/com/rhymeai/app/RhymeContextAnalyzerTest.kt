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

        // The next line is the verse's third lyric line: "B", a new sound.
        assertEquals("B", context.currentLetter)
        assertNull(context.targetLine)
        assertEquals(3, context.currentLineIndex)
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

        // The next line is the fifth lyric line: the scheme repeats, so it is "A",
        // anchored to the latest "A" line (line 3), not the first.
        assertEquals("A", context.currentLetter)
        assertEquals("third road", context.targetLine)
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

        // A header starts a new stanza: the next line is the second line under
        // "pre-chorus", so it opens "B" and does not rhyme across the header.
        assertEquals("B", context.currentLetter)
        assertNull(context.targetLine)
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

        // The next line follows "third road": fourth lyric line, "B", rhyming with line 2.
        assertEquals("B", context.currentLetter)
        assertEquals("🎵 second rain", context.targetLine)
        assertEquals(4, context.currentLineIndex)
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
        assertEquals(3, context.currentLineIndex)
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
