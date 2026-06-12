package com.rhymeai.app.util

/**
 * Pure beat-grid model. Maps lyric lines to bars at a given tempo so songwriters
 * can see which lines overflow the bar without any AI calls.
 *
 * Section headers (bracketed or bare keyword lines) are skipped — they carry no
 * syllables and would produce misleading 0-beat rows.
 */
object BeatGrid {

    // Mirrors SectionMap's header patterns so we skip the same lines.
    private val bracketedHeader = Regex("""^\s*\[(.+)]\s*$""")
    private val bareHeader = Regex(
        """^(?i)(verse|chorus|hook|bridge|pre[- ]?chorus|intro|outro)(\s+\d+)?$"""
    )

    /** How a line's beat count relates to one bar. */
    enum class Fit { FITS, TIGHT, OVERFLOW }

    data class LineResult(
        val text: String,
        val syllableCount: Int,
        /** beats = syllableCount / syllablesPerBeat */
        val beats: Double,
        /** bars = beats / beatsPerBar */
        val bars: Double,
        val fit: Fit,
        /** Wall-clock duration of the line at the given BPM. */
        val secondsPerLine: Double
    )

    data class GridResult(
        val lines: List<LineResult>,
        val bpm: Int,
        val beatsPerBar: Int
    )

    /**
     * Computes beat-grid data for every lyric line at [bpm].
     *
     * [bpm] is clamped to 40–220.
     * [beatsPerBar] defaults to 4 (common time).
     * [syllablesPerBeat] defaults to 1.0 (one syllable per beat).
     */
    fun compute(
        lyrics: String,
        bpm: Int,
        beatsPerBar: Int = 4,
        syllablesPerBeat: Double = 1.0
    ): GridResult {
        val clampedBpm = bpm.coerceIn(40, 220)
        val lines = lyrics.split('\n')
        val results = mutableListOf<LineResult>()

        for (line in lines) {
            val trimmed = line.trim()
            // Skip blank lines and section headers.
            if (trimmed.isEmpty()) continue
            if (bracketedHeader.matches(line) || bareHeader.matches(trimmed)) continue

            val syllables = SyllableCounter.countText(trimmed)
            if (syllables == 0) continue

            val beats = syllables / syllablesPerBeat
            val bars = beats / beatsPerBar

            // fits  → beats ≤ beatsPerBar        (≤ exactly 1 bar)
            // tight → beats ≤ beatsPerBar + 1    (1 bar + 1 beat grace)
            // overflow → more than that
            val fit = when {
                beats <= beatsPerBar -> Fit.FITS
                beats <= beatsPerBar + 1 -> Fit.TIGHT
                else -> Fit.OVERFLOW
            }

            val secondsPerLine = beats * 60.0 / clampedBpm

            results += LineResult(
                text = trimmed,
                syllableCount = syllables,
                beats = beats,
                bars = bars,
                fit = fit,
                secondsPerLine = secondsPerLine
            )
        }

        return GridResult(lines = results, bpm = clampedBpm, beatsPerBar = beatsPerBar)
    }

    /**
     * Averages the intervals between [timestamps] (milliseconds) to produce a BPM.
     * Requires at least 2 timestamps; returns null otherwise.
     * Result is clamped to 40–220.
     */
    fun tapTempoBpm(timestamps: List<Long>): Int? {
        if (timestamps.size < 2) return null
        val intervals = timestamps.zipWithNext { a, b -> (b - a).toDouble() }
        val avgIntervalMs = intervals.average()
        val bpm = (60_000.0 / avgIntervalMs).toInt()
        return bpm.coerceIn(40, 220)
    }
}
