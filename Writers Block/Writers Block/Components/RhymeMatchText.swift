import SwiftUI

/// Marks the rhyme being matched: the line's end word in the highlight colour,
/// semibold, with a single underline at 60% of that colour. Shared by the
/// suggestion cards and the assistant's quoted target line.
enum RhymeMatchText {
    static func attributed(
        _ text: String,
        highlight: Color,
        font: Font = .system(.body, design: .serif)
    ) -> AttributedString {
        guard let match = LyricRegex.lastWord.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges == 4,
              let wordRange = Range(match.range(at: 2), in: text) else {
            return AttributedString(text)
        }

        var word = AttributedString(String(text[wordRange]))
        // A run with its own font ignores the Text's font, so the caller's font
        // is carried here with the weight applied.
        word.font = font.weight(.semibold)
        word.foregroundColor = highlight
        word.underlineStyle = .single
        word.underlineColor = UIColor(highlight.opacity(0.6))

        var result = AttributedString()
        if let prefixRange = Range(match.range(at: 1), in: text) {
            result += AttributedString(String(text[prefixRange]))
        }
        result += word
        if let suffixRange = Range(match.range(at: 3), in: text) {
            result += AttributedString(String(text[suffixRange]))
        }
        return result
    }
}
