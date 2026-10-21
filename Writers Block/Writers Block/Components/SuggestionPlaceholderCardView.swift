import SwiftUI

/// Slot arithmetic and timing for the placeholders shown while next-line
/// suggestions stream in. When a request starts, three slots open as ghost
/// cards; each streamed line takes the next slot in place, lines past the
/// third append below, and any slot still empty when the stream stops
/// collapses. While a ghost waits, its text bar is written like an ink line,
/// held, cleared and written again. Every step is one tier of the motion
/// ladder, so none passes the 0.5s cap on utilitarian motion, and all the
/// ghosts share one start so their lines write together.
///
/// Android mirror: `SuggestionPlaceholderMotion` in
/// `ui/components/SuggestionPlaceholderCard.kt`.
enum SuggestionInkLineMotion {
    /// Slots opened as ghost cards when a request starts.
    static let reservedSlots = 3

    static let drawDuration: TimeInterval = RhymeAITokens.Motion.settleDuration
    static let holdDuration: TimeInterval = RhymeAITokens.Motion.stateDuration
    static let fadeDuration: TimeInterval = RhymeAITokens.Motion.feedbackDuration
    static let restDuration: TimeInterval = RhymeAITokens.Motion.stateDuration
    static var cycleDuration: TimeInterval { drawDuration + holdDuration + fadeDuration + restDuration }

    static let restingInkOpacity: Double = 0.08
    static let strokeInkOpacity: Double = 0.34
    /// Bar opacity under Reduce Motion: a still bar must read on its own.
    static let staticInkOpacity: Double = 0.16
    static let ghostOpacity: Double = 0.08
    static let ghostSoftOpacity: Double = 0.06

    static let textBarFractions: [CGFloat] = [0.72, 0.56, 0.64]

    /// Ghost cards still waiting for a line: the reserved slots the stream has
    /// not filled yet, and none once it stops.
    static func placeholderCount(arrived: Int, isLoading: Bool) -> Int {
        guard isLoading else { return 0 }
        return max(0, reservedSlots - arrived)
    }

    /// Slots to lay out: every line that has arrived plus the ghosts still waiting.
    static func slotCount(arrived: Int, isLoading: Bool) -> Int {
        arrived + placeholderCount(arrived: arrived, isLoading: isLoading)
    }

    static func textBarFraction(slot: Int) -> CGFloat {
        textBarFractions[max(0, slot) % textBarFractions.count]
    }

    /// Position inside the cycle, `elapsed` seconds after writing started.
    static func phase(elapsed: TimeInterval) -> TimeInterval {
        guard elapsed > 0 else { return 0 }
        return elapsed.truncatingRemainder(dividingBy: cycleDuration)
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
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 10
    @ScaledMetric(relativeTo: .caption) private var softBarHeight: CGFloat = 8
    @ScaledMetric(relativeTo: .subheadline) private var actionBarHeight: CGFloat = 20

    let slot: Int
    /// Mirrors `SuggestionCardView.showProsody`: reserves the stress-and-IPA rows.
    var showProsody: Bool = false
    /// When writing started; every ghost shares it so their lines move together.
    var writingStartedAt: Date = .now

    var body: some View {
        let ink = appearance.palette.primaryInk
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            HStack(alignment: .top, spacing: RhymeAITokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                    lineSlot(ink: ink)

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
                    .padding(.horizontal, RhymeAITokens.Spacing.xs)
                    .padding(.vertical, RhymeAITokens.Spacing.xs)
                    .hidden()
                    .background {
                        RoundedRectangle(cornerRadius: RhymeAITokens.Radius.xs, style: .continuous)
                            .fill(ink.opacity(SuggestionInkLineMotion.ghostOpacity))
                    }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: RhymeAITokens.Spacing.md) { actionGhosts(ink: ink) }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) { actionGhosts(ink: ink) }
            }
        }
        .padding(RhymeAITokens.Spacing.lg)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, fallbackOpacity: 0.06)
        .accessibilityHidden(true)
    }

    /// The serif line, held by one hidden line of the card's font so the slot
    /// is as tall as the line that will land in it; the ink bar is drawn over it.
    private func lineSlot(ink: Color) -> some View {
        Text(verbatim: "Placeholder")
            .font(.system(.body, design: .serif))
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Group {
                    if reduceMotion {
                        Capsule()
                            .fill(ink.opacity(SuggestionInkLineMotion.staticInkOpacity))
                    } else {
                        // 30 frames a second is plenty for a bar this size.
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                            let phase = SuggestionInkLineMotion.phase(elapsed: context.date.timeIntervalSince(writingStartedAt))
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(ink.opacity(SuggestionInkLineMotion.restingInkOpacity))
                                Capsule()
                                    .fill(ink.opacity(SuggestionInkLineMotion.strokeInkOpacity))
                                    .scaleEffect(x: max(0.001, SuggestionInkLineMotion.strokeExtent(phase: phase)), anchor: .leading)
                                    .opacity(SuggestionInkLineMotion.strokeOpacity(phase: phase))
                            }
                        }
                    }
                }
                .frame(height: barHeight)
                .scaleEffect(x: SuggestionInkLineMotion.textBarFraction(slot: slot), anchor: .leading)
            }
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
    VStack(spacing: RhymeAITokens.Spacing.xs) {
        SuggestionPlaceholderCardView(slot: 0)
        SuggestionPlaceholderCardView(slot: 1, showProsody: true)
        SuggestionPlaceholderCardView(slot: 2)
    }
    .padding()
}
