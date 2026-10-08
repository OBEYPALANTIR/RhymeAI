import SwiftUI

/// Timing for the "ink line" placeholders shown while next-line suggestions
/// stream in. Each placeholder is the suggestion card at its real paddings
/// whose text bar is written from the left, held, and faded, so the list
/// reads as lines being written in the order they will arrive.
///
/// Android mirror: `SuggestionPlaceholderMotion` in
/// `ui/components/SuggestionPlaceholderCard.kt`.
enum SuggestionInkLineMotion {
    /// Ghost rows shown before the first line lands.
    static let initialRows = 3

    /// The settle tier (0.42s) stretched by φ: the bar is written, not flashed.
    static let drawDuration: TimeInterval = 0.68
    static let holdDuration: TimeInterval = RhymeAITokens.Motion.stateDuration
    static let fadeDuration: TimeInterval = RhymeAITokens.Motion.feedbackDuration
    static let restDuration: TimeInterval = RhymeAITokens.Motion.stateDuration
    static var cycleDuration: TimeInterval { drawDuration + holdDuration + fadeDuration + restDuration }

    /// Rows start one state tier apart, top to bottom.
    static let rowOffset: TimeInterval = RhymeAITokens.Motion.stateDuration

    static let restingInkOpacity: Double = 0.08
    static let strokeInkOpacity: Double = 0.34
    /// Bar opacity under Reduce Motion: a still bar must read on its own.
    static let staticInkOpacity: Double = 0.16
    static let ghostOpacity: Double = 0.08
    static let ghostSoftOpacity: Double = 0.06

    static let textBarFractions: [CGFloat] = [0.72, 0.56, 0.64]
    static let arrivalRise: CGFloat = 8

    /// How many ghost rows to show: three before anything arrives, one trailing
    /// row while the stream is still open, none once it closes or is stopped.
    static func placeholderCount(suggestionCount: Int, isLoading: Bool) -> Int {
        guard isLoading else { return 0 }
        return suggestionCount == 0 ? initialRows : 1
    }

    static func textBarFraction(row: Int) -> CGFloat {
        textBarFractions[max(0, row) % textBarFractions.count]
    }

    /// Position inside the cycle for a row, 0 until that row's offset has elapsed.
    static func phase(elapsed: TimeInterval, row: Int) -> TimeInterval {
        let shifted = elapsed - Double(max(0, row)) * rowOffset
        guard shifted > 0 else { return 0 }
        return shifted.truncatingRemainder(dividingBy: cycleDuration)
    }

    /// Horizontal extent of the stroke, 0...1, eased while drawing.
    static func strokeExtent(phase: TimeInterval) -> CGFloat {
        guard phase > 0 else { return 0 }
        guard phase < drawDuration else { return 1 }
        return CGFloat(UnitCurve.easeInOut.value(at: phase / drawDuration))
    }

    /// Stroke opacity: solid through draw and hold, eased out, then resting.
    static func strokeOpacity(phase: TimeInterval) -> Double {
        let fadeStart = drawDuration + holdDuration
        guard phase >= fadeStart else { return 1 }
        let fadeEnd = fadeStart + fadeDuration
        guard phase < fadeEnd else { return 0 }
        return 1 - UnitCurve.easeIn.value(at: (phase - fadeStart) / fadeDuration)
    }
}

/// A ghost of `SuggestionCardView` that holds the slot a streamed line will
/// fill. Hidden from VoiceOver; the "Writing lines…" caption above the list
/// is what gets announced.
struct SuggestionPlaceholderCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance

    let row: Int

    @State private var start = Date()

    var body: some View {
        let ink = appearance.palette.primaryInk
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            HStack(alignment: .top, spacing: RhymeAITokens.Spacing.sm) {
                textBar(ink: ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Syllable badge ghost.
                ghost(width: 26, height: 22, radius: RhymeAITokens.Radius.xs, color: ink.opacity(SuggestionInkLineMotion.ghostOpacity))
            }

            // Action row ghosts: "Use line" and "Keep for later".
            HStack(spacing: RhymeAITokens.Spacing.md) {
                ghost(width: 92, height: 20, radius: 10, color: ink.opacity(SuggestionInkLineMotion.ghostOpacity))
                ghost(width: 112, height: 20, radius: 10, color: ink.opacity(SuggestionInkLineMotion.ghostSoftOpacity))
            }
            .frame(minHeight: RhymeAITokens.Touch.minimum)
        }
        .padding(RhymeAITokens.Spacing.lg)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, fallbackOpacity: 0.06)
        .accessibilityHidden(true)
    }

    private func ghost(width: CGFloat, height: CGFloat, radius: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color)
            .frame(width: width, height: height)
    }

    @ViewBuilder
    private func textBar(ink: Color) -> some View {
        let fraction = SuggestionInkLineMotion.textBarFraction(row: row)
        Group {
            if reduceMotion {
                Capsule()
                    .fill(ink.opacity(SuggestionInkLineMotion.staticInkOpacity))
                    .frame(height: 10)
            } else {
                TimelineView(.animation) { context in
                    let phase = SuggestionInkLineMotion.phase(elapsed: context.date.timeIntervalSince(start), row: row)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(ink.opacity(SuggestionInkLineMotion.restingInkOpacity))
                        Capsule()
                            .fill(ink.opacity(SuggestionInkLineMotion.strokeInkOpacity))
                            .scaleEffect(x: SuggestionInkLineMotion.strokeExtent(phase: phase), anchor: .leading)
                            .opacity(SuggestionInkLineMotion.strokeOpacity(phase: phase))
                    }
                    .frame(height: 10)
                }
            }
        }
        // Mirrors the serif body line box so an arriving card does not shift the list.
        .scaleEffect(x: fraction, anchor: .leading)
        .frame(height: 22)
    }
}

#Preview {
    VStack(spacing: RhymeAITokens.Spacing.xs) {
        SuggestionPlaceholderCardView(row: 0)
        SuggestionPlaceholderCardView(row: 1)
        SuggestionPlaceholderCardView(row: 2)
    }
    .padding()
}
