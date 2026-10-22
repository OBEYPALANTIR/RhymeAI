import SwiftUI
import UIKit

struct WordInspectorSheetView: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let word: String
    let prosody: WordProsody?
    let matches: RhymeMatches?
    let synonyms: [String]
    let synonymsLoading: Bool
    let synonymsError: String?
    let synonymsRecovery: SynonymRecoveryAction?
    let onReplace: (String) -> Void
    let onRetrySynonyms: () -> Void
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    @State private var lookupStarted = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            header

            wordHero

            ScrollView {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
                    switch RhymeResultPresentation.state(for: matches) {
                    case .finding:
                        HStack(spacing: RhymeAITokens.Spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text(RhymeResultPresentation.findingMessage)
                                .font(.caption)
                                .foregroundStyle(appearance.palette.secondaryInk)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("wordInspectorFindingRhymes")
                    case .results(let matches):
                        ResultsSection(
                            title: "Perfect rhymes",
                            empty: "No perfect rhymes in dictionary.",
                            items: matches.perfect,
                            onTap: onReplace
                        )

                        ResultsSection(
                            title: "Multi-syllabic rhymes",
                            empty: "No multi-syllabic matches.",
                            items: matches.multi,
                            onTap: onReplace
                        )

                        ResultsSection(
                            title: "Near rhymes",
                            empty: "No near rhymes found.",
                            items: matches.near,
                            onTap: onReplace
                        )
                    }

                    synonymsSection
                }
                .padding(.bottom, RhymeAITokens.Spacing.md)
            }
        }
        .padding(RhymeAITokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(appearance.palette.primaryInk)
        // Without its own surface the sheet is system glass, and the editor's
        // floating buttons show through it as dark smudges.
        .background(AppWritingBackground())
        .accessibilityIdentifier("wordInspectorSheet")
        .onAppear { lookupStarted = Date() }
        .onChange(of: word) { lookupStarted = Date() }
        .onChange(of: matches) { _, matches in
            guard let matches,
                  let message = RhymeResultPresentation.announcement(
                      for: matches,
                      waited: Date().timeIntervalSince(lookupStarted)
                  ) else { return }
            AccessibilityNotification.Announcement(message).post()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(appearance.palette.action)
                Text("Word inspector")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(appearance.palette.secondaryInk)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(appearance.palette.secondaryInk)
                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private var wordHero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(word)
                .font(.system(.largeTitle, design: .serif, weight: .bold))

            HStack(spacing: RhymeAITokens.Spacing.sm) {
                if let ipa = prosody?.ipa, !ipa.isEmpty {
                    Text("/\(ipa)/")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(appearance.palette.secondaryInk)
                }
                if let count = prosody?.syllableCount, count > 0 {
                    Text("\(count) \(count == 1 ? "syllable" : "syllables")")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.secondaryInk)
                }
                if let stress = prosody?.stressPattern, !stress.isEmpty {
                    StressDots(pattern: stress)
                }
            }
        }
    }

    @ViewBuilder
    private var synonymsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Synonyms")
                    .font(.footnote.weight(.semibold))
                Spacer()
                if synonymsLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let synonymsRecovery {
                    switch synonymsRecovery {
                    case .retry:
                        Button(action: onRetrySynonyms) {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                                // Taller hit area without growing the row: on
                                // iPad's short sheet a 44pt row pushed the
                                // error text below the fold.
                                .padding(.vertical, RhymeAITokens.Spacing.sm)
                                .contentShape(Rectangle())
                                .padding(.vertical, -RhymeAITokens.Spacing.sm)
                        }
                    case .openSettings:
                        Button(action: onOpenSettings) {
                            Label("Settings", systemImage: "gearshape")
                                .font(.caption.weight(.semibold))
                                // Taller hit area without growing the row: on
                                // iPad's short sheet a 44pt row pushed the
                                // error text below the fold.
                                .padding(.vertical, RhymeAITokens.Spacing.sm)
                                .contentShape(Rectangle())
                                .padding(.vertical, -RhymeAITokens.Spacing.sm)
                        }
                    }
                }
            }

            if !synonyms.isEmpty {
                FlowChips(items: synonyms, onTap: onReplace)
            }
            if let error = synonymsError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(appearance.palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if synonyms.isEmpty, !synonymsLoading {
                Text("No synonyms yet.")
                    .font(.caption)
                    .foregroundStyle(appearance.palette.secondaryInk)
            }
        }
    }
}

private struct ResultsSection: View {
    @Environment(\.appAppearanceStyle) private var appearance
    let title: String
    let empty: String
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
            if items.isEmpty {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(appearance.palette.secondaryInk)
            } else {
                FlowChips(items: items, onTap: onTap)
            }
        }
    }
}

private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        // Each chip's 44pt hit frame already separates the rows, so the
        // layout adds no vertical gap of its own.
        FlowLayout(spacing: 6, rowSpacing: 0) {
            ForEach(items, id: \.self) { item in
                ChipButton(label: item, onTap: { onTap(item) })
            }
        }
    }
}

private struct ChipButton: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let label: String
    let onTap: () -> Void
    @State private var copyFlash = false
    @State private var longPressed = false

    var body: some View {
        Button {
            // A long press copies; lifting the finger afterwards must not
            // also replace the word.
            if longPressed {
                longPressed = false
            } else {
                onTap()
            }
        } label: {
            Text(label)
                .font(.callout)
                .foregroundStyle(appearance.palette.primaryInk)
                .padding(.horizontal, RhymeAITokens.Spacing.sm)
                .padding(.vertical, Self.verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: RhymeAITokens.Radius.pill, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RhymeAITokens.Radius.pill, style: .continuous)
                        .stroke(copyFlash ? appearance.palette.success : appearance.palette.outline, lineWidth: 1)
                )
                // The chip keeps its drawn height; the tappable area grows to
                // the touch minimum around it. The press style makes the whole
                // frame the hit shape. The small outer padding keeps rows
                // apart once large text makes a chip taller than that minimum.
                .padding(.vertical, RhymeAITokens.Spacing.xxs)
                .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
        }
        // The action does not run when the finger lifts outside the chip, so
        // the suppression is cleared when the press ends, one turn later so an
        // action for this same touch still sees it.
        .buttonStyle(RhymeAIPressButtonStyle(onPressingChanged: { isPressed in
            if !isPressed {
                DispatchQueue.main.async { longPressed = false }
            }
        }))
        .accessibilityLabel(label)
        .accessibilityHint("Replaces the selected word")
        .accessibilityAction(named: "Copy") { copy() }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                longPressed = true
                copy()
            }
        )
        .rhymeAnimation(RhymeAITokens.Motion.feedback, value: copyFlash)
    }

    private static let verticalPadding: CGFloat = 6

    private func copy() {
        UIPasteboard.general.string = label
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        copyFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { copyFlash = false }
    }
}

private struct StressDots: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let pattern: [Int]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(pattern.enumerated()), id: \.offset) { _, stress in
                let (size, alpha): (CGFloat, Double) = {
                    switch stress {
                    case 1: return (8, 1.0)
                    case 2: return (6, 0.7)
                    default: return (4, 0.4)
                    }
                }()
                Circle()
                    .fill(appearance.palette.action.opacity(alpha))
                    .frame(width: size, height: size)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    /// Gap between rows; defaults to `spacing`.
    var rowSpacing: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var currentRowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty, currentRowWidth + spacing + size.width > maxWidth {
                rows.append([])
                totalHeight += currentRowHeight + (rowSpacing ?? spacing)
                currentRowWidth = 0
                currentRowHeight = 0
            }
            if !rows[rows.count - 1].isEmpty { currentRowWidth += spacing }
            rows[rows.count - 1].append(size)
            currentRowWidth += size.width
            currentRowHeight = max(currentRowHeight, size.height)
        }
        totalHeight += currentRowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : currentRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        var firstInRow = true

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !firstInRow, x + spacing + size.width > bounds.maxX {
                y += rowHeight + (rowSpacing ?? spacing)
                x = bounds.minX
                rowHeight = 0
                firstInRow = true
            }
            if !firstInRow { x += spacing }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width
            rowHeight = max(rowHeight, size.height)
            firstInRow = false
            _ = maxWidth
        }
    }
}
