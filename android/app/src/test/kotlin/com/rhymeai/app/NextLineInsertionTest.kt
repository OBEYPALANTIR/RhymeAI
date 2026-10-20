package com.rhymeai.app

import kotlin.test.Test
import kotlin.test.assertEquals

/** Insertion half of the shared table in `NextLineRhymeContextTest.kt`. */
class NextLineInsertionTest {
    @Test
    fun acceptedSuggestionLandsOnTheLineTheContextDescribed() {
        for (case in nextLineCases) {
            val insertion = NextLinePlacement(case.text, case.cursor).inserting("NEW")

            assertEquals(case.textAfter, insertion.text, "${case.id} text")
            assertEquals(case.cursorAfter, insertion.cursor, "${case.id} cursor")
            assertEquals("NEW", insertion.text.substring(insertion.start, insertion.end), "${case.id} highlight")
        }
    }

    @Test
    fun insertedLineHasTheLetterAndAnchorThatWereComputedForIt() {
        for (case in nextLineCases) {
            val insertion = NextLinePlacement(case.text, case.cursor).inserting("NEW")
            val lines = insertion.text.split("\n")
            val newLineIndex = insertion.text.substring(0, insertion.start).count { it == '\n' }

            // Recompute from the resulting text: the line directly above the inserted one
            // (or the stanza start) must lead to the same letter and anchor.
            val textAbove = lines.take(newLineIndex).joinToString("\n") + "\n"
            val recomputed = NextLinePlacement(textAbove, textAbove.length)

            assertEquals("NEW", lines[newLineIndex], "${case.id} inserted line")
            assertEquals(case.letter, recomputed.letter(case.scheme).toString(), "${case.id} letter after insertion")
            assertEquals(case.anchor, recomputed.anchorLine(case.scheme), "${case.id} anchor after insertion")
        }
    }
}
