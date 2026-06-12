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
        // Matches both "[Verse 2]" and bare "verse 2" / "Chorus" / "hook"
        // The bare form requires the whole trimmed line to be keyword [+ number].
        private val bracketedHeader = Regex("""^\s*\[(.+)]\s*$""")
        private val bareHeader = Regex(
            """^(?i)(verse|chorus|hook|bridge|pre[- ]?chorus|intro|outro)(\s+\d+)?$"""
        )

        fun parse(lyrics: String): SectionMap {
            val lines = lyrics.split('\n')

            // Collect header positions: (lineIndex, label).
            data class RawHeader(val lineIndex: Int, val label: String)
            val headers = mutableListOf<RawHeader>()
            lines.forEachIndexed { idx, line ->
                val trimmed = line.trim()
                val bracketed = bracketedHeader.matchEntire(line)?.groupValues?.get(1)?.trim()
                if (bracketed != null) {
                    headers += RawHeader(idx, bracketed)
                    return@forEachIndexed
                }
                if (bareHeader.matches(trimmed) && trimmed.isNotEmpty()) {
                    headers += RawHeader(idx, trimmed)
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
