import SwiftUI

/// Slot arithmetic and timing for the placeholders shown while next-line
/// suggestions stream in. One ghost card is open at a time: it opens in the
/// first slot when a request starts, each streamed line takes its slot in
/// place while the next ghost opens below, and the ghost still waiting when
/// the stream stops collapses. When a ghost opens, its text bar is written
/// once, left to right on the settle tier, and the ink settles to the resting
/// bar, which then holds still until the line arrives.
///
/// Android mirror: `SuggestionPlaceholderMotion` in
/// `ui/components/SuggestionPlaceholderCard.kt`.
enum SuggestionInkLineMotion {
    static let drawDuration: TimeInterval = RhymeAITokens.Motion.settleDuration
    static let draw: Animation = .easeInOut(duration: drawDuration)

    /// The bar's ink while it waits, and under Reduce Motion, where it is never drawn.
    static let restingInkOpacity: Double = 0.08
    /// The ink at the pen as the stroke starts; it settles to the resting ink as it draws.
    static let strokeInkOpacity: Double = 0.34
    static let ghostOpacity: Double = 0.08
    static let ghostSoftOpacity: Double = 0.06

    static let textBarFractions: [CGFloat] = [0.72, 0.56, 0.64]

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
    /// Flips on appear, so each ghost writes its line once as it opens.
    @State private var drawn = false

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
                Capsule()
                    .fill(ink)
                    .opacity(drawn ? SuggestionInkLineMotion.restingInkOpacity : SuggestionInkLineMotion.strokeInkOpacity)
                    .scaleEffect(x: drawn ? 1 : 0.001, anchor: .leading)
                    .frame(height: barHeight)
                    .scaleEffect(x: SuggestionInkLineMotion.textBarFraction(slot: slot), anchor: .leading)
            }
            .onAppear {
                // Under Reduce Motion the bar is simply there, still, at the resting ink.
                withRhymeAnimation(SuggestionInkLineMotion.draw, reduceMotion: reduceMotion) { drawn = true }
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
