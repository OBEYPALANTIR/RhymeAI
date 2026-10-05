package com.rhymeai.app.ui.components

import com.rhymeai.app.RhymeContextAnalyzer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RhymeSchemeDisplayTest {
    @Test
    fun headerFreeLyricsKeepTheirSchemePositions() {
        val lyrics = "first light\nsecond night\nthird rain"
        val rows = rowsFor(lyrics)

        // The last row is the line a suggestion would add.
        assertEquals(listOf("A", "A", "B", "B"), rows.map { it.letter })
        assertEquals(listOf(false, false, false, true), rows.map { it.isCurrent })
    }

    @Test
    fun verseHeaderRemainsVisibleWithoutTakingALetter() {
        val lyrics = "[Verse]\nfirst light\nsecond night\nthird rain\nfourth train"
        val rows = rowsFor(lyrics)

        assertEquals("[Verse]", rows.first().line)
        assertEquals(listOf(null, "A", "A", "B", "B", "A"), rows.map { it.letter })
        assertTrue(rows.last().isCurrent)
        assertEquals("", rows.last().line)
    }

    @Test
    fun whitespaceOnlyLineEndsTheStanzaAndCurrentBlankUsesAnalyzerLetter() {
        val lyrics = "[Verse]\nfirst light\n \nsecond night\n"
        val context = RhymeContextAnalyzer.compute(lyrics, lyrics.length, "AABB")
        val rows = rhymeSchemeRows(context, "AABB")

        assertEquals(listOf("second night", ""), rows.map { it.line })
        assertEquals("A", context.currentLetter)
        assertEquals("second night", context.targetLine)
        assertEquals(listOf("A", context.currentLetter), rows.map { it.letter })
        assertFalse(rows[0].isCurrent)
        assertTrue(rows[1].isCurrent)
    }

    @Test
    fun earlierCaretMarksTheLineAfterItWhileLaterRowsKeepTheirLetters() {
        val lyrics = "[Verse]\nfirst light\nsecond night\nthird rain"
        val context = RhymeContextAnalyzer.compute(lyrics, lyrics.indexOf("second") + 3, "AABB")
        val rows = rhymeSchemeRows(context, "AABB")

        assertEquals(listOf(null, "A", "A", "B", "B"), rows.map { it.letter })
        assertEquals(listOf(false, false, false, true, false), rows.map { it.isCurrent })
        assertEquals("", rows.single { it.isCurrent }.line)
        assertEquals(context.currentLetter, rows.single { it.isCurrent }.letter)
    }

    private fun rowsFor(lyrics: String, cursor: Int = lyrics.length): List<RhymeSchemeRow> =
        rhymeSchemeRows(RhymeContextAnalyzer.compute(lyrics, cursor, "AABB"), "AABB")
}
