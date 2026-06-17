import SwiftUI

struct SyllableColoredText: View {
    let text: String
    let enabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if enabled && !text.isEmpty {
            Text(coloredAttributedString)
                .font(.system(size: 16))
        } else {
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
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
                segment.foregroundColor = .primary
                result += segment
            }

            let word = String(text[matchRange])
            let count = SyllableCounter.count(word)
            var segment = AttributedString(word)
            segment.foregroundColor = .primary
            segment.underlineStyle = Text.LineStyle(
                pattern: .solid,
                color: syllableColor(for: count)
            )
            result += segment

            lastEnd = matchRange.upperBound
        }

        // Append remaining text
        if lastEnd < text.endIndex {
            var segment = AttributedString(String(text[lastEnd...]))
            segment.foregroundColor = .primary
            result += segment
        }

        return result
    }

    private func syllableColor(for count: Int) -> Color {
        Self.syllableColor(for: count, scheme: colorScheme)
    }

    static func syllableColor(for count: Int, scheme: ColorScheme) -> Color {
        if scheme == .dark {
            switch count {
            case 1: return Color(red: 110.0 / 255, green: 231.0 / 255, blue: 183.0 / 255) // Emerald-300
            case 2: return Color(red: 147.0 / 255, green: 197.0 / 255, blue: 253.0 / 255) // Blue-300
            case 3: return Color(red: 216.0 / 255, green: 180.0 / 255, blue: 254.0 / 255) // Purple-300
            default: return Color(red: 253.0 / 255, green: 164.0 / 255, blue: 175.0 / 255) // Rose-300
            }
        } else {
            switch count {
            case 1: return Color(red:   4 / 255.0, green: 120 / 255.0, blue:  87 / 255.0) // emerald-700
            case 2: return Color(red:   3 / 255.0, green: 105 / 255.0, blue: 161 / 255.0) // sky-700
            case 3: return Color(red: 126 / 255.0, green:  34 / 255.0, blue: 206 / 255.0) // purple-700
            default: return Color(red: 185 / 255.0, green:  28 / 255.0, blue:  28 / 255.0) // rose-700
            }
        }
    }
}
