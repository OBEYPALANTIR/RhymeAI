package com.rhymeai.app

import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.util.SectionMap

internal object RhymeContextAnalyzer {
    fun compute(text: String, cursor: Int, scheme: String): RhymeContext {
        if (text.isEmpty()) {
            return RhymeContext(null, scheme.firstOrNull()?.toString() ?: "A", emptyList(), 0)
        }

        // The context describes the line a suggestion will be inserted as, not the cursor's line.
        val placement = NextLinePlacement(text, cursor)
        val sectionRef = SectionMap.parse(text).sectionAt(placement.cursorLineIndex)

        if (scheme.isEmpty()) {
            return RhymeContext(null, "A", placement.stanzaRows, placement.rowIndex, sectionRef.type)
        }

        return RhymeContext(
            targetLine = placement.anchorLine(scheme),
            currentLetter = placement.letter(scheme).toString(),
            stanzaLines = placement.stanzaRows,
            currentLineIndex = placement.rowIndex,
            currentSection = sectionRef.type,
            currentSectionRef = sectionRef
        )
    }

    fun currentSongSection(text: String, cursor: Int): SongSection {
        val safeCursor = cursor.coerceIn(0, text.length)
        val currentLineIndex = text.substring(0, safeCursor).count { it == '\n' }
        return SectionMap.parse(text).sectionAt(currentLineIndex).type
    }
}
