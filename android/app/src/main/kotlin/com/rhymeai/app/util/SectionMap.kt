package com.rhymeai.app.util

import com.rhymeai.app.data.model.SongSection

/**
 * Parses lyrics text into an ordered list of sections. Understands both
 * bracketed headers ("[Verse 2]") and bare keyword headers ("chorus", "verse 1").
 *
 * Bare headers are only recognised when the *entire* trimmed line is a keyword
 * plus an optional number — this prevents a lyric like "meet me at the bridge"
 * from being misread as a Bridge header.
 */
data class SectionRef(
    val type: SongSection,
    /** 1-based ordinal per type (first [Verse] is ordinal 1, second is 2, …). */
    val ordinal: Int,
    /** The label as it appears in the text, e.g. "Verse 2", "Chorus". */
    val label: String,
    /** The half-open line range [first, last) covered by this section. */
    val lineRange: IntRange
)

data class SectionInsertion(
    val text: String,
    val cursor: Int
)

class SectionMap private constructor(private val refs: List<SectionRef>) {

    /** All parsed sections in document order. */
    val allSections: List<SectionRef> = refs

    /**
     * Returns the section that contains [lineIndex], or the implicit first
     * section (UNKNOWN, ordinal 1) when the line precedes any header.
     */
    fun sectionAt(lineIndex: Int): SectionRef {
        return refs.lastOrNull { lineIndex >= it.lineRange.first } ?: refs.first()
    }

    companion object {
        val standardLabels = listOf(
            "Intro",
            "Verse",
            "Pre-Chorus",
            "Chorus",
            "Hook",
            "Bridge",
            "Refrain",
            "Interlude",
            "Outro"
        )

        // Matches both "[Verse 2]" and bare "verse 2" / "Chorus" / "hook"
        // The bare form requires the whole trimmed line to be keyword [+ number].
        private val bracketedHeader = Regex("""^\s*\[(.+)]\s*$""")
        private val bareHeader = Regex(
            """^(?i)(verse|chorus|hook|bridge|pre[- ]?chorus|intro|outro|refrain|interlude)(\s+\d+)?$"""
        )

        fun headerTitle(line: String): String? {
            val trimmed = line.trim()
            val bracketed = bracketedHeader.matchEntire(trimmed)?.groupValues?.getOrNull(1)?.trim()
            if (!bracketed.isNullOrEmpty()) return bracketed
            return trimmed.takeIf { it.isNotEmpty() && bareHeader.matches(it) }
        }

        fun lyricContent(lyrics: String): String =
            lyrics.lineSequence()
                .filter { headerTitle(it) == null }
                .joinToString("\n")

        fun headerRanges(lyrics: String): List<IntRange> {
            val ranges = mutableListOf<IntRange>()
            var lineStart = 0
            lyrics.split('\n').forEach { line ->
                if (line.isNotEmpty() && headerTitle(line) != null) {
                    ranges += lineStart until (lineStart + line.length)
                }
                lineStart += line.length + 1
            }
            return ranges
        }

        fun insertHeader(lyrics: String, cursor: Int, label: String): SectionInsertion {
            val safeCursor = cursor.coerceIn(0, lyrics.length)
            val cleanLabel = label.trim().removePrefix("[").removeSuffix("]").trim()
            require(cleanLabel.isNotEmpty()) { "Section label cannot be blank." }

            val before = lyrics.substring(0, safeCursor)
            val after = lyrics.substring(safeCursor)
            val leading = when {
                before.isEmpty() || before.endsWith("\n\n") -> ""
                before.endsWith("\n") -> "\n"
                else -> "\n\n"
            }
            val trailing = when {
                after.isEmpty() -> "\n"
                after.startsWith("\n\n") -> ""
                after.startsWith("\n") -> "\n"
                else -> "\n\n"
            }
            val inserted = "$leading[$cleanLabel]$trailing"
            return SectionInsertion(
                text = before + inserted + after,
                cursor = safeCursor + inserted.length
            )
        }

        fun parse(lyrics: String): SectionMap {
            val lines = lyrics.split('\n')

            // Collect header positions: (lineIndex, label).
            data class RawHeader(val lineIndex: Int, val label: String)
            val headers = mutableListOf<RawHeader>()
            lines.forEachIndexed { idx, line ->
                headerTitle(line)?.let { title ->
                    headers += RawHeader(idx, title)
                }
            }

            // Build ordinal counters per SongSection type.
            val ordinalCounter = mutableMapOf<SongSection, Int>()

            val refs = mutableListOf<SectionRef>()

            // Lines before the first header belong to an implicit UNKNOWN section.
            val implicitEnd = headers.firstOrNull()?.lineIndex ?: lines.size
            refs += SectionRef(
                type = SongSection.UNKNOWN,
                ordinal = 1,
                label = "Intro",
                lineRange = 0 until implicitEnd
            )

            // Build a section ref for each header; its range ends at the next header.
            headers.forEachIndexed { i, raw ->
                val type = SongSection.fromHeader(raw.label)
                val ordinal = (ordinalCounter[type] ?: 0) + 1
                ordinalCounter[type] = ordinal
                val rangeEnd = headers.getOrNull(i + 1)?.lineIndex ?: lines.size
                refs += SectionRef(
                    type = type,
                    ordinal = ordinal,
                    label = raw.label,
                    lineRange = raw.lineIndex until rangeEnd
                )
            }

            // Drop the implicit UNKNOWN preamble if it has no lines (document starts
            // immediately with a header at line 0).
            val filtered = if (refs.first().lineRange.isEmpty()) refs.drop(1) else refs

            // Guarantee at least one ref so sectionAt() never throws.
            return if (filtered.isEmpty()) {
                SectionMap(
                    listOf(
                        SectionRef(SongSection.UNKNOWN, 1, "Intro", 0 until lines.size)
                    )
                )
            } else {
                SectionMap(filtered)
            }
        }
    }
}
