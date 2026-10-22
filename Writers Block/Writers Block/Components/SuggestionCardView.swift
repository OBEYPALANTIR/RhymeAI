import SwiftUI

func suggestionRhymeBadgeLabel(rhymeTier: Int, isHookRepeat: Bool) -> String? {
    if isHookRepeat { return "hook" }
    switch rhymeTier {
    case 3: return "slant"
    case 2: return "perfect"
    case 1: return "near"
    default: return nil
    }
}

struct SuggestionCardView: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let suggestion: String
    /// Rhyme quality tier: 3 = slant, 2 = perfect/multi, 1 = near, 0 = unverified (no badge shown).
    var rhymeTier: Int = 0
    /// True when this is a chorus repeat and the end word matches the hook's established end word.
    var isHookRepeat: Bool = false
    let highlightRhyme: Bool
    var showProsody: Bool = false
    let onUse: () -> Void
    let onKeep: () -> Void
    var isKept: Bool = false

    var body: some View {
        let prosody = ProsodyAnalyzer.analyzeLine(suggestion)
        VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.related) {
            HStack(alignment: .top, spacing: RhymeAITokens.Rhythm.related) {
                VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.related) {
                    highlightedText
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if showProsody {
                        SuggestionProsodyPreviewView(prosody: prosody)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: RhymeAITokens.Rhythm.tight) {
                    if let badge = tierBadgeLabel {
                        Text(badge)
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(tierBadgeColor)
                            .padding(.horizontal, RhymeAITokens.Rhythm.tight)
                            .padding(.vertical, RhymeAITokens.Rhythm.tight)
                            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xs, tint: tierBadgeColor.opacity(0.08), fallbackOpacity: 0.08)
                            .accessibilityHidden(true)
                    }

                    Text("\(prosody.syllableCount)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.horizontal, RhymeAITokens.Rhythm.tight)
                        .padding(.vertical, RhymeAITokens.Rhythm.tight)
                        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xs, fallbackOpacity: 0.08)

                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: RhymeAITokens.Rhythm.standard) { suggestionActions }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.tight) { suggestionActions }
            }
        }
        .padding(RhymeAITokens.Rhythm.standard)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, fallbackOpacity: 0.06)
    }

    @ViewBuilder
    private var suggestionActions: some View {
        Button(action: onUse) {
            Label("Use line", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: RhymeAITokens.Touch.minimum)
        }
        .accessibilityIdentifier("useSuggestionButton")
        Button(action: onKeep) {
            Label(isKept ? "Kept" : "Keep for later", systemImage: isKept ? "bookmark.fill" : "bookmark")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: RhymeAITokens.Touch.minimum)
        }
        .disabled(isKept)
        .accessibilityHint(isKept ? "Saved in Song Notebook, Alternates" : "Saves to Song Notebook without changing your lyrics")
        .accessibilityIdentifier("keepSuggestionButton")
    }

    // "hook" overrides "perfect" on chorus repeats.
    private var tierBadgeLabel: String? {
        suggestionRhymeBadgeLabel(rhymeTier: rhymeTier, isHookRepeat: isHookRepeat)
    }

    private var tierBadgeColor: Color {
        if isHookRepeat { return .indigo }
        return rhymeTier >= 2 ? .green : .orange
    }

    @ViewBuilder
    private var highlightedText: some View {
        if highlightRhyme {
            // The appearance's violet rhyme colour: the previous fixed pale
            // indigo was about 1.8:1 on the light appearances.
            Text(RhymeMatchText.attributed(suggestion, highlight: Color(hex: appearance.analysisRhymeHexValues[4])))
        } else {
            Text(suggestion)
        }
    }
}

private struct SuggestionProsodyPreviewView: View {
    let prosody: LineProsody

    var body: some View {
        if prosody.syllableCount > 0 {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.hairline) {
                if !prosody.feet.isEmpty {
                    Text(prosody.feet)
                }
                if !prosody.ipa.isEmpty {
                    Text("/\(prosody.ipa)/")
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary.opacity(0.72))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
