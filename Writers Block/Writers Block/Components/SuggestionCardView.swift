import SwiftUI

struct SuggestionCardView: View {
    let suggestion: String
    let highlightRhyme: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: RhymeAITokens.Spacing.sm) {
                highlightedText
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineSpacing(4)
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
