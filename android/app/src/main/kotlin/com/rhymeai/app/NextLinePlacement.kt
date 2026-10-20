package com.rhymeai.app

import com.rhymeai.app.util.SectionMap

/**
 * Where an accepted next-line suggestion goes, and what that position means for the
 * rhyme scheme. The rhyme context and the insertion both read this one value, so the
 * letter and anchor sent to the model always describe the line that gets inserted.
 *
 * Placement rule (identical on iOS, `NextLinePlacement.swift`):
 * - cursor on a blank line: the suggestion takes that line, and a blank line is kept after it;
 * - cursor anywhere on a non-blank line (lyric or header): the suggestion becomes a new
 *   line directly after it. A lyric line is never split.
 *
 * Scheme rule: a stanza starts after a blank line or a section header. The new line's
 * letter is `scheme[earlier lyric lines in the stanza % scheme length]`, and its anchor
 * is the latest earlier lyric line in the same stanza with that letter, if any.
 */
internal class NextLinePlacement(text: String, cursor: Int) {
    /** Document lines, split on "\n". */
    val lines: List<String> = text.split("\n")

    /** Line the cursor is on. */
    val cursorLineIndex: Int = text.substring(0, cursor.coerceIn(0, text.length)).count { it == '\n' }

    /** True when the cursor line is blank and the suggestion takes its place. */
    val fillsBlankLine: Boolean = lines[cursorLineIndex].isBlank()

    /**
     * The blank-line-delimited block around the cursor, with one empty row at
     * [rowIndex] standing for the line to be inserted.
     */
    val stanzaRows: List<String>
    val rowIndex: Int

    /** Trimmed lyric lines before the new line, back to the stanza start. */
    val earlierLyricLines: List<String>

    init {
        val blockStart = (0 until cursorLineIndex).lastOrNull { lines[it].isBlank() }?.plus(1) ?: 0
        if (fillsBlankLine) {
            stanzaRows = lines.subList(blockStart, cursorLineIndex + 1)
            rowIndex = cursorLineIndex - blockStart
        } else {
            val blockEnd = (cursorLineIndex + 1 until lines.size).firstOrNull { lines[it].isBlank() } ?: lines.size
            stanzaRows = lines.subList(blockStart, cursorLineIndex + 1) + "" +
                lines.subList(cursorLineIndex + 1, blockEnd)
            rowIndex = cursorLineIndex - blockStart + 1
        }

        val earlier = mutableListOf<String>()
        for (row in stanzaRows.take(rowIndex)) {
            val line = row.trim()
            if (SectionMap.headerTitle(line) != null) earlier.clear()
            else if (line.isNotEmpty()) earlier += line
        }
        earlierLyricLines = earlier
    }

    /** Scheme letter of the line to be inserted. The scheme repeats in a longer stanza. */
    fun letter(scheme: String): Char? =
        if (scheme.isEmpty()) null else scheme[earlierLyricLines.size % scheme.length]

    /** Latest earlier line in the stanza with the new line's letter; null when it opens a rhyme sound. */
    fun anchorLine(scheme: String): String? {
        val letter = letter(scheme) ?: return null
        return earlierLyricLines.indices
            .lastOrNull { scheme[it % scheme.length] == letter }
            ?.let { earlierLyricLines[it] }
    }

    /** [start, end) is the inserted suggestion; [cursor] is where the caret lands. */
    data class Insertion(val text: String, val start: Int, val end: Int, val cursor: Int)

    fun inserting(suggestion: String): Insertion {
        val newLines = lines.toMutableList()
        val suggestionIndex: Int
        val cursorOnFollowingLine: Boolean
        if (fillsBlankLine) {
            suggestionIndex = cursorLineIndex
            newLines[cursorLineIndex] = suggestion
            newLines.add(cursorLineIndex + 1, "")
            cursorOnFollowingLine = true
        } else {
            suggestionIndex = cursorLineIndex + 1
            newLines.add(suggestionIndex, suggestion)
            cursorOnFollowingLine = suggestionIndex == newLines.lastIndex
            if (cursorOnFollowingLine) newLines += ""
        }

        val start = newLines.take(suggestionIndex).sumOf { it.length + 1 }
        val end = start + suggestion.length
        return Insertion(
            text = newLines.joinToString("\n"),
            start = start,
            end = end,
            cursor = end + if (cursorOnFollowingLine) 1 else 0
        )
    }
}
