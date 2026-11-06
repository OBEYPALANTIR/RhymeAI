package com.rhymeai.app.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame

class SyllableCounterTest {
    private val song = "[Verse]\nThe harbor lights are burning low\r\nI've got 99 problems tonight\n\nChorus:\n" +
        "Beautiful and unforgettable, the night\n"

    @Test
    fun `memoised lyric counts match counting the lyric content from scratch`() {
        val content = SectionMap.lyricContent(song)
        assertEquals(SyllableCounter.wordCount(content), SyllableCounter.lyricWordCount(song))
        assertEquals(ProsodyAnalyzer.analyzeLine(content).syllableCount, SyllableCounter.lyricSyllableCount(song))
        assertEquals(ProsodyAnalyzer.analyzeLine(content).syllableCount, SyllableCounter.countText(content))
    }

    @Test
    fun `a word counts the same however it is spelled in the lyric`() {
        assertEquals(ProsodyAnalyzer.countWord("unforgettable"), SyllableCounter.count("Unforgettable"))
        assertEquals(SyllableCounter.count("I've"), SyllableCounter.count("I’ve"))
        assertEquals(0, SyllableCounter.count("99"))
    }

    @Test
    fun `an unchanged line is served from the memo and a header line counts as empty`() {
        val line = "The harbor lights are burning low"
        assertSame(SyllableCounter.lyricLine(line), SyllableCounter.lyricLine(StringBuilder(line).toString()))
        val header = SyllableCounter.lyricLine("[Chorus]")
        assertEquals(0, header.words)
        assertEquals(0, header.tokens.size)
    }
}
