import SwiftUI

struct RhymeHighlightedText: View {
    let text: String
    let enabled: Bool
    let syllablesEnabled: Bool

    init(text: String, enabled: Bool, syllablesEnabled: Bool = false) {
        self.text = text
        self.enabled = enabled
        self.syllablesEnabled = syllablesEnabled
    }

    private static let palette: [Color] = [
        Color(red: 252/255, green: 165/255, blue: 165/255), // rose
        Color(red: 252/255, green: 211/255, blue: 77/255),  // amber
        Color(red: 134/255, green: 239/255, blue: 172/255), // green
        Color(red: 125/255, green: 211/255, blue: 252/255), // sky
        Color(red: 196/255, green: 181/255, blue: 253/255), // violet
        Color(red: 249/255, green: 168/255, blue: 212/255), // pink
        Color(red: 253/255, green: 186/255, blue: 116/255), // orange
        Color(red: 103/255, green: 232/255, blue: 249/255), // cyan
        Color(red: 167/255, green: 243/255, blue: 208/255), // mint
        Color(red: 233/255, green: 213/255, blue: 255/255), // light purple
        Color(red: 254/255, green: 240/255, blue: 138/255), // yellow
        Color(red: 190/255, green: 242/255, blue: 100/255)  // lime
    ]

    private static let wordPattern = try! NSRegularExpression(pattern: "[a-zA-Z']+")

    var body: some View {
        if (enabled || syllablesEnabled) && !text.isEmpty {
            Text(highlightedAttributedString)
                .font(.system(size: 16))
        } else {
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.primary.opacity(0.9))
        }
    }

    private var highlightedAttributedString: AttributedString {
        let nsText = text as NSString
        let matches = Self.wordPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        struct Token {
            let value: String
            let range: Range<String.Index>
        }
        var tokens: [Token] = []
        for match in matches {
            guard let r = Range(match.range, in: text) else { continue }
            tokens.append(Token(value: String(text[r]), range: r))
        }

        let keysPerToken: [[String]] = tokens.map { RhymePhonetics.rhymeKeys(for: $0.value) }

        var keyOccurrences: [String: Int] = [:]
        for keys in keysPerToken {
            for k in keys { keyOccurrences[k, default: 0] += 1 }
        }

        let familyKeyPerToken: [String?] = keysPerToken.map { keys in
            keys.last { (keyOccurrences[$0] ?? 0) >= 2 }
        }

        var result = AttributedString()
        var cursor = text.startIndex

        for (i, tok) in tokens.enumerated() {
            if cursor < tok.range.lowerBound {
                var pre = AttributedString(String(text[cursor..<tok.range.lowerBound]))
                pre.foregroundColor = .primary.opacity(0.9)
                result += pre
            }
            var seg = AttributedString(tok.value)
            if enabled, let familyKey = familyKeyPerToken[i] {
                seg.foregroundColor = colorFor(key: familyKey)
                seg.font = .system(size: 16, weight: .semibold)
            } else {
                seg.foregroundColor = .primary.opacity(0.9)
            }
            if syllablesEnabled {
                let count = SyllableCounter.count(tok.value)
                seg.underlineStyle = Text.LineStyle(
                    pattern: .solid,
                    color: Self.syllableColor(for: count)
                )
            }
            result += seg
            cursor = tok.range.upperBound
        }

        if cursor < text.endIndex {
            var tail = AttributedString(String(text[cursor...]))
            tail.foregroundColor = .primary.opacity(0.9)
            result += tail
        }

        return result
    }

    private func colorFor(key: String) -> Color {
        let h = abs(key.hashValue)
        return Self.palette[h % Self.palette.count]
    }

    private static func syllableColor(for count: Int) -> Color {
        switch count {
        case 1: return Color(red: 110.0 / 255, green: 231.0 / 255, blue: 183.0 / 255)
        case 2: return Color(red: 147.0 / 255, green: 197.0 / 255, blue: 253.0 / 255)
        case 3: return Color(red: 216.0 / 255, green: 180.0 / 255, blue: 254.0 / 255)
        default: return Color(red: 253.0 / 255, green: 164.0 / 255, blue: 175.0 / 255)
        }
    }
}
