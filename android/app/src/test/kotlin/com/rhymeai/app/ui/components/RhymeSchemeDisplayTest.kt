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

        assertEquals(listOf("A", "A", "B"), rows.map { it.letter })
        assertEquals(listOf(false, false, true), rows.map { it.isCurrent })
    }

    @Test
    fun verseHeaderRemainsVisibleWithoutTakingALetter() {
        val lyrics = "[Verse]\nfirst light\nsecond night\nthird rain\nfourth train"
        val rows = rowsFor(lyrics)

        assertEquals("[Verse]", rows.first().line)
        assertEquals(listOf(null, "A", "A", "B", "B"), rows.map { it.letter })
        assertTrue(rows.last().isCurrent)
    }

    @Test
    fun blankRowsDoNotAdvanceTheSchemeAndCurrentBlankUsesAnalyzerLetter() {
        val lyrics = "[Verse]\nfirst light\n \nsecond night\n"
        val context = RhymeContextAnalyzer.compute(lyrics, lyrics.length, "AABB")
        val rows = rhymeSchemeRows(context, "AABB")

        assertEquals(listOf(null, "A", null, "A", context.currentLetter), rows.map { it.letter })
        assertFalse(rows[2].isCurrent)
        assertTrue(rows[4].isCurrent)
        assertEquals("", rows[4].line)
    }

    @Test
    fun earlierCaretMarksItsLyricWhileLaterRowsKeepTheirLetters() {
        val lyrics = "[Verse]\nfirst light\nsecond night\nthird rain"
        val context = RhymeContextAnalyzer.compute(lyrics, lyrics.indexOf("second") + 3, "AABB")
        val rows = rhymeSchemeRows(context, "AABB")

        assertEquals(listOf(null, "A", "A", "B"), rows.map { it.letter })
        assertEquals(listOf(false, false, true, false), rows.map { it.isCurrent })
        assertEquals(context.currentLetter, rows.single { it.isCurrent }.letter)
    }

    private fun rowsFor(lyrics: String, cursor: Int = lyrics.length): List<RhymeSchemeRow> =
        rhymeSchemeRows(RhymeContextAnalyzer.compute(lyrics, cursor, "AABB"), "AABB")
}
