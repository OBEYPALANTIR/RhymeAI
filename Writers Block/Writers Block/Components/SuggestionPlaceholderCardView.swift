import SwiftUI

/// Slot arithmetic and timing for the placeholders shown while next-line
/// suggestions stream in. One ghost card is open at a time: it opens in the
/// first slot when a request starts, each streamed line takes its slot in
/// place while the next ghost opens below, and the ghost still waiting when
/// the stream stops collapses. While a ghost waits, two scribbled lines write
/// themselves tip first, hold, are wiped and write again, on the ghost's own
/// clock from when it appeared.
///
/// Android mirror: `SuggestionPlaceholderMotion` in
/// `ui/components/SuggestionPlaceholderCard.kt`.
enum SuggestionInkLineMotion {
    static let ghostOpacity: Double = 0.08
    static let ghostSoftOpacity: Double = 0.06

    static let textBarFractions: [CGFloat] = [0.72, 0.56, 0.64]
    /// The second scribble's width as a share of the first's.
    static let secondLineShare: CGFloat = 0.6

    // MARK: Scribble loop

    static let writeDuration: TimeInterval = 1.3
    static let holdDuration: TimeInterval = 0.35
    static let loopPeriod: TimeInterval = writeDuration + holdDuration
    /// The share of the write the first line takes; the second takes the rest.
    static let firstLineShare: Double = 0.63
    /// Reduce Motion holds one frame: the first line drawn, the second 60% along.
    static let stillProgress: (first: CGFloat, second: CGFloat) = (1, 0.6)

    // MARK: Scribble wave

    static let wavePeriod: CGFloat = 34
    static let waveHeight: CGFloat = 10
    static let strokeWidth: CGFloat = 1.6
    /// One period of the wave, as fractions of the period and of the wave's height.
    static let waveShape: [CGPoint] = [
        CGPoint(x: 0, y: 0.55), CGPoint(x: 0.18, y: 0.25), CGPoint(x: 0.42, y: 0.78),
        CGPoint(x: 0.68, y: 0.28), CGPoint(x: 1, y: 0.58),
    ]

    /// Ghost cards waiting for a line: one, in the next slot, while the stream
    /// runs, and none once it stops.
    static func placeholderCount(arrived: Int, isLoading: Bool) -> Int {
        isLoading ? 1 : 0
    }

    /// Slots to lay out: every line that has arrived plus the ghosts still waiting.
    static func slotCount(arrived: Int, isLoading: Bool) -> Int {
        arrived + placeholderCount(arrived: arrived, isLoading: isLoading)
    }

    static func textBarFraction(slot: Int) -> CGFloat {
        textBarFractions[max(0, slot) % textBarFractions.count]
    }

    /// How far each scribble is drawn `elapsed` seconds after the ghost
    /// appeared: the first line over the first 63% of the write, the second
    /// over the rest, both held drawn through the hold, then wiped.
    static func lineProgress(elapsed: TimeInterval) -> (first: CGFloat, second: CGFloat) {
        let wrapped = elapsed - (elapsed / loopPeriod).rounded(.down) * loopPeriod
        let phase = wrapped / writeDuration
        return (
            CGFloat(min(max(phase / firstLineShare, 0), 1)),
            CGFloat(min(max((phase - firstLineShare) / (1 - firstLineShare), 0), 1))
        )
    }

    /// One line on the same loop (the model row's indeterminate download): written tip
    /// first over the whole write, held, then wiped.
    static func singleLineProgress(elapsed: TimeInterval) -> CGFloat {
        let wrapped = elapsed - (elapsed / loopPeriod).rounded(.down) * loopPeriod
        return CGFloat(min(max(wrapped / writeDuration, 0), 1))
    }

    /// The wave tiled along `width` at its fixed period, the last period cut at the edge.
    static func wavePoints(width: CGFloat, height: CGFloat = waveHeight) -> [CGPoint] {
        guard width > 0 else { return [] }
        var points = [CGPoint(x: 0, y: waveShape[0].y * height)]
        var period: CGFloat = 0
        while points[points.count - 1].x < width {
            for point in waveShape.dropFirst() {
                let next = CGPoint(x: (period + point.x) * wavePeriod, y: point.y * height)
                let last = points[points.count - 1]
                if next.x >= width {
                    let share = next.x > last.x ? (width - last.x) / (next.x - last.x) : 0
                    points.append(CGPoint(x: width, y: last.y + (next.y - last.y) * share))
                    break
                }
                points.append(next)
            }
            period += 1
        }
        return points
    }
}

/// One scribbled line, `widthShare` of the space it is given, drawn tip first to `progress`.
private struct ScribbleStroke: Shape {
    var widthShare: CGFloat
    var progress: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines(SuggestionInkLineMotion.wavePoints(width: rect.width * widthShare, height: rect.height))
        return path.offsetBy(dx: rect.minX, dy: rect.minY).trimmedPath(from: 0, to: progress)
    }
}

/// A ghost of `SuggestionCardView` that holds a slot until its line arrives.
/// Each row is held by hidden text in the card's own font, so the ghost grows
/// with Dynamic Type exactly as the card does: one serif body line, the
/// stress-and-IPA rows when that preview is on, the syllable badge, and the
/// two actions in the same `ViewThatFits`, so they stack when the real buttons
/// would. A suggestion that wraps to a second line still grows its card when
/// it lands. Hidden from VoiceOver, which hears "Writing suggestions" when
/// writing starts.
struct SuggestionPlaceholderCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance
    @ScaledMetric(relativeTo: .caption) private var softBarHeight: CGFloat = 8
    @ScaledMetric(relativeTo: .subheadline) private var actionBarHeight: CGFloat = 20

    let slot: Int
    /// Mirrors `SuggestionCardView.showProsody`: reserves the stress-and-IPA rows.
    var showProsody: Bool = false
    /// The ghost's own scribble clock starts when it appears.
    @State private var appeared = Date()

    var body: some View {
        let ink = appearance.palette.primaryInk
        VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.related) {
            HStack(alignment: .top, spacing: RhymeAITokens.Rhythm.related) {
                VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.related) {
                    lineSlot(ink: appearance.palette.placeholder)

                    if showProsody {
                        // SuggestionProsodyPreviewView: two caption monospace lines.
                        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.hairline) {
                            softRow(fraction: 0.4, ink: ink)
                            softRow(fraction: 0.66, ink: ink)
                        }
                        .font(.caption.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // The syllable count badge, in its own font and padding.
                Text(verbatim: "00")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, RhymeAITokens.Rhythm.tight)
                    .padding(.vertical, RhymeAITokens.Rhythm.tight)
                    .hidden()
                    .background {
                        RoundedRectangle(cornerRadius: RhymeAITokens.Radius.xs, style: .continuous)
                            .fill(ink.opacity(SuggestionInkLineMotion.ghostOpacity))
                    }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: RhymeAITokens.Rhythm.standard) { actionGhosts(ink: ink) }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.tight) { actionGhosts(ink: ink) }
            }
        }
        .padding(RhymeAITokens.Rhythm.standard)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, fallbackOpacity: 0.06)
        .accessibilityHidden(true)
    }

    /// The serif line, held by one hidden line of the card's font so the slot
    /// is exactly as tall as a one-line card, with two scribbled lines
    /// writing themselves centred over it. The scribble is an overlay, so it
    /// never sizes the slot: where it is taller than the line it runs into
    /// the card's padding, and the slot grows only with the hidden text
    /// (Dynamic Type). Under Reduce Motion the timeline pauses on one still frame.
    private func lineSlot(ink: Color) -> some View {
        let first = SuggestionInkLineMotion.textBarFraction(slot: slot)
        return Text(verbatim: "Placeholder")
            .font(.system(.body, design: .serif))
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
                    let progress = reduceMotion
                        ? SuggestionInkLineMotion.stillProgress
                        : SuggestionInkLineMotion.lineProgress(elapsed: context.date.timeIntervalSince(appeared))
                    VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.related) {
                        scribble(widthShare: first, progress: progress.first, ink: ink)
                        scribble(widthShare: first * SuggestionInkLineMotion.secondLineShare, progress: progress.second, ink: ink)
                    }
                }
            }
    }

    private func scribble(widthShare: CGFloat, progress: CGFloat, ink: Color) -> some View {
        ScribbleStroke(widthShare: widthShare, progress: progress)
            .stroke(ink, style: StrokeStyle(lineWidth: SuggestionInkLineMotion.strokeWidth, lineCap: .round, lineJoin: .round))
            .frame(maxWidth: .infinity)
            .frame(height: SuggestionInkLineMotion.waveHeight)
    }

    /// One caption line of the prosody preview, held by hidden text in the
    /// enclosing font so it scales like the real row.
    private func softRow(fraction: CGFloat, ink: Color) -> some View {
        Text(verbatim: "/x/")
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(ink.opacity(SuggestionInkLineMotion.ghostSoftOpacity))
                    .frame(height: softBarHeight)
                    .scaleEffect(x: fraction, anchor: .leading)
            }
    }

    /// "Use line" and "Keep for later", held by hidden labels in the buttons'
    /// fonts and minimum height, so they measure and stack as the real ones do.
    @ViewBuilder
    private func actionGhosts(ink: Color) -> some View {
        Label("Use line", systemImage: "plus")
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .hidden()
            .overlay {
                Capsule()
                    .fill(ink.opacity(SuggestionInkLineMotion.ghostOpacity))
                    .frame(height: actionBarHeight)
            }
        Label("Keep for later", systemImage: "bookmark")
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .hidden()
            .overlay {
                Capsule()
                    .fill(ink.opacity(SuggestionInkLineMotion.ghostSoftOpacity))
                    .frame(height: actionBarHeight)
            }
    }
}

#Preview {
    VStack(spacing: RhymeAITokens.Rhythm.standard) {
        SuggestionPlaceholderCardView(slot: 0)
        SuggestionPlaceholderCardView(slot: 1, showProsody: true)
        SuggestionPlaceholderCardView(slot: 2)
    }
    .padding()
}
