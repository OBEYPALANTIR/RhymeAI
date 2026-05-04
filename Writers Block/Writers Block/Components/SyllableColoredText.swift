import SwiftUI

struct SyllableColoredText: View {
    let text: String
    let enabled: Bool

    var body: some View {
        if enabled && !text.isEmpty {
            Text(coloredAttributedString)
                .font(.system(size: 16))
        } else {
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.primary.opacity(0.9))
        }
    }

    private static let wordPattern = try! NSRegularExpression(pattern: "[a-zA-Z0-9']+")

    private var coloredAttributedString: AttributedString {
        var result = AttributedString()
        let nsText = text as NSString
        let matches = Self.wordPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var lastEnd = text.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }

            // Append non-word characters before this match
            if lastEnd < matchRange.lowerBound {
                var segment = AttributedString(String(text[lastEnd..<matchRange.lowerBound]))
                segment.foregroundColor = .primary.opacity(0.9)
                result += segment
            }

            // Append word with syllable color
            let word = String(text[matchRange])
            let count = SyllableCounter.count(word)
            var segment = AttributedString(word)
            segment.foregroundColor = Self.syllableColor(for: count)
            result += segment

            lastEnd = matchRange.upperBound
        }

        // Append remaining text
        if lastEnd < text.endIndex {
            var segment = AttributedString(String(text[lastEnd...]))
            segment.foregroundColor = .primary.opacity(0.9)
            result += segment
        }

        return result
    }

    static func syllableColor(for count: Int) -> Color {
        switch count {
        case 1: return Color(red: 110.0 / 255, green: 231.0 / 255, blue: 183.0 / 255) // Emerald
        case 2: return Color(red: 147.0 / 255, green: 197.0 / 255, blue: 253.0 / 255) // Blue
        case 3: return Color(red: 216.0 / 255, green: 180.0 / 255, blue: 254.0 / 255) // Purple
        default: return Color(red: 253.0 / 255, green: 164.0 / 255, blue: 175.0 / 255) // Rose
        }
    }
}
