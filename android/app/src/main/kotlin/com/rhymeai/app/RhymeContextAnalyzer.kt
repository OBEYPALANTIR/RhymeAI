package com.rhymeai.app

import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.util.SectionMap

internal object RhymeContextAnalyzer {
    fun compute(text: String, cursor: Int, scheme: String): RhymeContext {
        if (text.isEmpty()) {
            return RhymeContext(null, scheme.firstOrNull()?.toString() ?: "A", emptyList(), 0)
        }

        val pos = cursor.coerceIn(0, text.length)
        val textBefore = text.substring(0, pos)
        val textAfter = text.substring(pos)
        val currentLineIndex = textBefore.count { it == '\n' }
        val sectionRef = SectionMap.parse(text).sectionAt(currentLineIndex)
        val currentSection = sectionRef.type

        val lastDoubleNewline = textBefore.lastIndexOf("\n\n")
        val stanzaStart = if (lastDoubleNewline == -1) 0 else lastDoubleNewline + 2

        val nextDoubleNewline = textAfter.indexOf("\n\n")
        val stanzaEnd = if (nextDoubleNewline == -1) text.length else pos + nextDoubleNewline

        val currentStanza = text.substring(stanzaStart, stanzaEnd)
        val stanzaLines = currentStanza.split("\n")

        val stanzaTextBefore = textBefore.substring(stanzaStart)
        val rawCursorLineIndex = stanzaTextBefore.split("\n").size - 1

        val lyricLinePos = stanzaLines.take(rawCursorLineIndex + 1).count { line ->
            SectionMap.headerTitle(line) == null && line.isNotBlank()
        } - 1
        val effectiveLineIndex = maxOf(lyricLinePos, 0)

        val schemeLetters = scheme.toList()
        if (schemeLetters.isEmpty()) {
            return RhymeContext(null, "A", stanzaLines, rawCursorLineIndex, currentSection)
        }

        val currentLetter = schemeLetters[effectiveLineIndex % schemeLetters.size].toString()

        var targetLine: String? = null
        var lyricCount = 0
        for (i in stanzaLines.indices) {
            if (i >= rawCursorLineIndex) break
            val line = stanzaLines[i].trim()
            if (SectionMap.headerTitle(line) != null || line.isEmpty()) continue
            val letterForThis = schemeLetters[lyricCount % schemeLetters.size].toString()
            if (letterForThis == currentLetter) {
                targetLine = line
            }
            lyricCount++
        }

        return RhymeContext(
            targetLine = targetLine,
            currentLetter = currentLetter,
            stanzaLines = stanzaLines,
            currentLineIndex = rawCursorLineIndex,
            currentSection = currentSection,
            currentSectionRef = sectionRef
        )
    }

    fun currentSongSection(text: String, cursor: Int): SongSection {
        val safeCursor = cursor.coerceIn(0, text.length)
        val currentLineIndex = text.substring(0, safeCursor).count { it == '\n' }
        return SectionMap.parse(text).sectionAt(currentLineIndex).type
    }
}
