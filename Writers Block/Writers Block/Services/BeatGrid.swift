import Foundation

/// Pure beat-grid model. Maps lyric lines to bars at a given tempo so songwriters
/// can see which lines overflow the bar without any AI calls.
///
/// Section headers (bracketed or bare keyword lines) are skipped — they carry no
/// syllables and would produce misleading 0-beat rows.
enum BeatGrid {

    // MARK: - Types

    /// How a line's beat count relates to one bar.
    enum Fit {
        case fits       // beats ≤ beatsPerBar
        case tight      // beats ≤ beatsPerBar + 1
        case overflow   // beats > beatsPerBar + 1
    }

    struct LineResult {
        let text: String
        let syllableCount: Int
        /// beats = syllableCount / syllablesPerBeat
        let beats: Double
        /// bars = beats / beatsPerBar
        let bars: Double
        let fit: Fit
        /// Wall-clock duration of the line at the given BPM.
        let secondsPerLine: Double
    }

    struct GridResult {
        let lines: [LineResult]
        let bpm: Int
        let beatsPerBar: Int
    }

    // MARK: - Compute

    /// Computes beat-grid data for every lyric line at `bpm`.
    ///
    /// `bpm` is clamped to 40–220.
    /// `beatsPerBar` defaults to 4 (common time).
    /// `syllablesPerBeat` defaults to 1.0 (one syllable per beat).
    static func compute(
        lyrics: String,
        bpm: Int,
        beatsPerBar: Int = 4,
        syllablesPerBeat: Double = 1.0
    ) -> GridResult {
        let clampedBpm = max(40, min(220, bpm))
        let rawLines = lyrics.components(separatedBy: "\n")
        var results: [LineResult] = []

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip blank lines and section headers.
            guard !trimmed.isEmpty else { continue }
            guard SectionMap.headerTitle(trimmed) == nil else { continue }

            let syllables = SyllableCounter.countText(trimmed)
            guard syllables > 0 else { continue }

            let beats = Double(syllables) / syllablesPerBeat
            let bars = beats / Double(beatsPerBar)

            // fits  → beats ≤ beatsPerBar        (≤ exactly 1 bar)
            // tight → beats ≤ beatsPerBar + 1    (1 bar + 1 beat grace)
            // overflow → more than that
            let fit: Fit
            if beats <= Double(beatsPerBar) {
                fit = .fits
            } else if beats <= Double(beatsPerBar) + 1.0 {
                fit = .tight
            } else {
                fit = .overflow
            }

            let secondsPerLine = beats * 60.0 / Double(clampedBpm)

            results.append(LineResult(
                text: trimmed,
                syllableCount: syllables,
                beats: beats,
                bars: bars,
                fit: fit,
                secondsPerLine: secondsPerLine
            ))
        }

        return GridResult(lines: results, bpm: clampedBpm, beatsPerBar: beatsPerBar)
    }

    // MARK: - Tap Tempo

    /// Averages the intervals between `timestamps` (milliseconds) to produce a BPM.
    /// Requires at least 2 timestamps; returns nil otherwise.
    /// Result is clamped to 40–220.
    static func tapTempoBpm(timestamps: [TimeInterval]) -> Int? {
        guard timestamps.count >= 2 else { return nil }
        let intervals = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }
        let avgIntervalMs = intervals.reduce(0, +) / Double(intervals.count)
        let bpm = Int(60_000.0 / avgIntervalMs)
        return max(40, min(220, bpm))
    }
}
