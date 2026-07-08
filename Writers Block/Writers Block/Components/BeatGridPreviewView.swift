import SwiftUI

// MARK: - Tempo control

/// BPM stepper + slider (40–220) with a tap-tempo button.
struct BeatGridTempoControl: View {
    @Binding var bpm: Int
    /// Rolling tap timestamps (milliseconds since reference) for tap-tempo.
    @State private var tapTimestamps: [TimeInterval] = []

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("BPM")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                // Tap-tempo button
                Button {
                    let now = Date().timeIntervalSince1970 * 1000
                    let updated = Array((tapTimestamps + [now]).suffix(5))
                    tapTimestamps = updated
                    if let computed = BeatGrid.tapTempoBpm(timestamps: updated) {
                        bpm = computed
                    }
                } label: {
                    Label("Tap", systemImage: "music.note")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.indigo)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tap tempo")

                // Stepper
                Stepper(
                    value: $bpm,
                    in: 40...220,
                    step: 1
                ) {
                    Text("\(bpm)")
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .center)
                }
                .labelsHidden()
            }

            Slider(value: Binding(
                get: { Double(bpm) },
                set: { bpm = Int($0) }
            ), in: 40...220, step: 1)
            .tint(.indigo)
        }
    }
}

// MARK: - Per-line preview

/// Renders the beat-grid preview strip for every lyric line.
///
/// Each row shows: truncated line text, a filled-segment bar visualization
/// (colored by fit classification), and a "Nsyl · M.m beats" label.
///
/// Recomputes only when `lyrics` or `bpm` change — same lazy let idiom
/// used elsewhere in the assistant panel.
struct BeatGridPreviewView: View {
    let lyrics: String
    let bpm: Int

    var body: some View {
        let grid = BeatGrid.compute(lyrics: lyrics, bpm: bpm)
        if grid.lines.isEmpty { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(grid.lines.enumerated()), id: \.offset) { _, line in
                    BeatGridLineRow(line: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }
}

// MARK: - Row

private struct BeatGridLineRow: View {
    let line: BeatGrid.LineResult

    var body: some View {
        HStack(spacing: 8) {
            // Truncated line text
            Text(line.text)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Bar visualization
            BeatSegmentsView(beats: line.beats, beatsPerBar: 4, color: barColor)

            // "Nsyl · M.m beats"
            Text("\(line.syllableCount)syl · \(String(format: "%.1f", line.beats))b")
                .font(.system(size: 12))
                .foregroundStyle(labelColor)
                .frame(width: 76, alignment: .trailing)
        }
    }

    private var barColor: Color {
        switch line.fit {
        case .fits:     return .accentColor
        case .tight:    return Color(red: 1.0, green: 0.627, blue: 0.0) // amber
        case .overflow: return .red
        }
    }

    private var labelColor: Color {
        switch line.fit {
        case .fits:     return .secondary
        case .tight:    return Color(red: 1.0, green: 0.627, blue: 0.0)
        case .overflow: return .red
        }
    }
}

// MARK: - Beat Segments

private struct BeatSegmentsView: View {
    let beats: Double
    let beatsPerBar: Int
    let color: Color

    var body: some View {
        let totalSegments = max(beatsPerBar, Int(beats))
        let filledSegments = min(Int(beats), totalSegments)

        HStack(spacing: 2) {
            ForEach(0..<totalSegments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < filledSegments ? color : color.opacity(0.15))
                    .frame(width: 8, height: 12)
                // Subtle gap between bars
                if i < totalSegments - 1 && (i + 1) % beatsPerBar == 0 {
                    Spacer().frame(width: 3)
                }
            }
        }
    }
}
