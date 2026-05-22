import SwiftUI

struct SuggestionCardView: View {
    let suggestion: String
    let highlightRhyme: Bool
    var showProsody: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: RhymeAITokens.Spacing.sm) {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                    highlightedText
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(.primary.opacity(0.9))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if showProsody {
                        SuggestionProsodyPreviewView(text: suggestion)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: RhymeAITokens.Spacing.xs) {
                    Text("\(SyllableCounter.countText(suggestion))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.horizontal, RhymeAITokens.Spacing.xs)
                        .padding(.vertical, RhymeAITokens.Spacing.xs)
                        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xs, fallbackOpacity: 0.08)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.3))
                }
            }
            .padding(RhymeAITokens.Spacing.lg)
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .white.opacity(0.04), interactive: true, fallbackOpacity: 0.06)
        }
        .buttonStyle(.rhymePress)
    }

    @ViewBuilder
    private var highlightedText: some View {
        if highlightRhyme, let attributed = highlightLastWord(in: suggestion) {
            Text(attributed)
        } else {
            Text(suggestion)
        }
    }

    private static let lastWordPattern = try! NSRegularExpression(pattern: "(.*?)(\\b\\w+\\b)([^\\w]*)$")

    private func highlightLastWord(in text: String) -> AttributedString? {
        let regex = Self.lastWordPattern
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
    let text: String
    private var prosody: LineProsody { ProsodyAnalyzer.analyzeLine(text) }

    var body: some View {
        if prosody.syllableCount > 0 {
            VStack(alignment: .leading, spacing: 2) {
                if !prosody.feet.isEmpty {
                    Text(prosody.feet)
                }
                if !prosody.ipa.isEmpty {
                    Text("/\(prosody.ipa)/")
                }
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary.opacity(0.72))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
