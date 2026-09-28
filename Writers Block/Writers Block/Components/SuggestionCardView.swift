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
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            HStack(alignment: .top, spacing: RhymeAITokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
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

                HStack(spacing: RhymeAITokens.Spacing.xs) {
                    if let badge = tierBadgeLabel {
                        Text(badge)
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(tierBadgeColor)
                            .padding(.horizontal, RhymeAITokens.Spacing.xs)
                            .padding(.vertical, 2)
                            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xs, tint: tierBadgeColor.opacity(0.08), fallbackOpacity: 0.08)
                            .accessibilityHidden(true)
                    }

                    Text("\(prosody.syllableCount)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.horizontal, RhymeAITokens.Spacing.xs)
                        .padding(.vertical, RhymeAITokens.Spacing.xs)
                        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xs, fallbackOpacity: 0.08)

                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: RhymeAITokens.Spacing.md) { suggestionActions }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) { suggestionActions }
            }
        }
        .padding(RhymeAITokens.Spacing.lg)
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
        if highlightRhyme, let attributed = highlightLastWord(in: suggestion) {
            Text(attributed)
        } else {
            Text(suggestion)
        }
    }

    private func highlightLastWord(in text: String) -> AttributedString? {
        let regex = LyricRegex.lastWord
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 4 else {
            return nil
        }

        var result = AttributedString()

        // Prefix
        if let prefixRange = Range(match.range(at: 1), in: text) {
            result += AttributedString(String(text[prefixRange]))
        }

        // Last word - highlighted
        if let wordRange = Range(match.range(at: 2), in: text) {
            var word = AttributedString(String(text[wordRange]))
            word.foregroundColor = Color(red: 165.0 / 255, green: 180.0 / 255, blue: 252.0 / 255) // Indigo 200
            word.underlineStyle = .single
            word.underlineColor = UIColor(Color.indigo.opacity(0.6))
            result += word
        }

        // Suffix
        if let suffixRange = Range(match.range(at: 3), in: text) {
            result += AttributedString(String(text[suffixRange]))
        }

        return result
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
