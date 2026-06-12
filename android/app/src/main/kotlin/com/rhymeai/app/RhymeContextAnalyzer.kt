package com.rhymeai.app

import com.rhymeai.app.data.model.SongSection

internal object RhymeContextAnalyzer {
    private val sectionHeaderRegex = Regex("^\\s*\\[.*]\\s*$")
    private val sectionHeaderCaptureRegex = Regex("^\\s*\\[(.+)]\\s*$")

    fun compute(text: String, cursor: Int, scheme: String): RhymeContext {
        if (text.isEmpty()) {
            return RhymeContext(null, scheme.firstOrNull()?.toString() ?: "A", emptyList(), 0)
        }

        val pos = cursor.coerceIn(0, text.length)
        val currentSection = currentSongSection(text, pos)
        val textBefore = text.substring(0, pos)
        val textAfter = text.substring(pos)

        val lastDoubleNewline = textBefore.lastIndexOf("\n\n")
        val stanzaStart = if (lastDoubleNewline == -1) 0 else lastDoubleNewline + 2

        val nextDoubleNewline = textAfter.indexOf("\n\n")
        val stanzaEnd = if (nextDoubleNewline == -1) text.length else pos + nextDoubleNewline

        val currentStanza = text.substring(stanzaStart, stanzaEnd)
        val stanzaLines = currentStanza.split("\n")

        val stanzaTextBefore = textBefore.substring(stanzaStart)
        val rawCursorLineIndex = stanzaTextBefore.split("\n").size - 1

        val lyricLinePos = stanzaLines.take(rawCursorLineIndex + 1).count { line ->
            !sectionHeaderRegex.matches(line) && line.isNotBlank()
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
            if (sectionHeaderRegex.matches(line) || line.isEmpty()) continue
            val letterForThis = schemeLetters[lyricCount % schemeLetters.size].toString()
            if (letterForThis == currentLetter) {
                targetLine = line
            }
            lyricCount++
        }

        return RhymeContext(targetLine, currentLetter, stanzaLines, rawCursorLineIndex, currentSection)
    }

    fun currentSongSection(text: String, cursor: Int): SongSection {
        val textBeforeCursor = text.take(cursor.coerceIn(0, text.length))
        val header = textBeforeCursor
            .lineSequence()
            .mapNotNull { sectionHeaderCaptureRegex.matchEntire(it)?.groupValues?.getOrNull(1) }
            .lastOrNull()
        return header?.let(SongSection::fromHeader) ?: SongSection.UNKNOWN
    }
}
