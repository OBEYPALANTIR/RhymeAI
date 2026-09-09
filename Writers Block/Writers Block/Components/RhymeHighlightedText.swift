import SwiftUI

extension InkUnderlinePattern {
    var lineStyle: Text.LineStyle {
        switch self {
        case .solid: Text.LineStyle(pattern: .solid)
        case .dashed: Text.LineStyle(pattern: .dash)
        case .dotted: Text.LineStyle(pattern: .dot)
        case .dashDot: Text.LineStyle(pattern: .dashDot)
        }
    }
}

// Per-word rhyme keys and syllable counts are pure functions of the word and the
// static pronunciation dictionary, but the editor overlay recomputes them for every
// word on every keystroke, which drops frames on long lyrics. Caching by lowercased
// word (both lookups normalize case internally, so this is output-identical) means a
// keystroke only pays for words it hasn't seen before.
private final class WordAnalysisCache: @unchecked Sendable {
    static let shared = WordAnalysisCache()

    private let lock = NSLock()
    private var entries: [String: (rhymeKeys: [String], syllableCount: Int)] = [:]
    private static let capacity = 4096

    func analysis(for word: String) -> (rhymeKeys: [String], syllableCount: Int) {
        let key = word.lowercased()
        lock.lock()
        defer { lock.unlock() }
        if let hit = entries[key] { return hit }

        let value = (RhymePhonetics.rhymeKeys(for: key), SyllableCounter.count(key))
        // A song's vocabulary is far below the cap, so wholesale eviction is
        // effectively never hit; it just bounds memory without LRU bookkeeping,
        // and a refill costs one render.
        if entries.count >= Self.capacity {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = value
        return value
    }
}

struct RhymeHighlightedText: View, Equatable {
    let text: String
    let enabled: Bool
    let syllablesEnabled: Bool

    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.analysisPresentationStyle) private var analysisPresentation

    init(text: String, enabled: Bool, syllablesEnabled: Bool = false) {
        self.text = text
        self.enabled = enabled
        self.syllablesEnabled = syllablesEnabled
    }

    static func == (lhs: RhymeHighlightedText, rhs: RhymeHighlightedText) -> Bool {
        lhs.text == rhs.text
            && lhs.enabled == rhs.enabled
            && lhs.syllablesEnabled == rhs.syllablesEnabled
    }

    private var palette: [Color] {
        appearance.analysisRhymeHexValues.map { Color(hex: $0) }
    }

    var body: some View {
        if (enabled || syllablesEnabled) && !text.isEmpty {
            Text(highlightedAttributedString)
                .font(.body)
        } else {
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }

    private var highlightedAttributedString: AttributedString {
        let nsText = text as NSString
        let matches = LyricRegex.word.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        struct Token {
            let value: String
            let range: Range<String.Index>
        }
        var tokens: [Token] = []
        for match in matches {
            guard let r = Range(match.range, in: text) else { continue }
            tokens.append(Token(value: String(text[r]), range: r))
        }

        let analyses = tokens.map { WordAnalysisCache.shared.analysis(for: $0.value) }
        let keysPerToken: [[String]] = analyses.map(\.rhymeKeys)

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
                pre.foregroundColor = .primary
                result += pre
            }
            let count = analyses[i].syllableCount
            var seg = AttributedString(tok.value)
            if enabled, let familyKey = familyKeyPerToken[i] {
                switch analysisPresentation {
                case .color:
                    seg.foregroundColor = colorFor(key: familyKey)
                    seg.font = .body.weight(.semibold)
                    if syllablesEnabled {
                        seg.underlineStyle = Text.LineStyle(
                            pattern: .solid,
                            color: syllableColor(for: count)
                        )
                    }
                case .inkMarks:
                    seg.foregroundColor = appearance.palette.primaryInk
                    seg.underlineStyle = analysisInkPattern(for: familyKey).lineStyle
                    if let weight = analysisFontWeight(
                        syllableCount: count,
                        syllableGuideEnabled: syllablesEnabled
                    ) {
                        seg.font = .body.weight(weight)
                    }
                }
            } else if analysisPresentation == .inkMarks, syllablesEnabled {
                seg.foregroundColor = appearance.palette.primaryInk
                seg.font = .body.weight(analysisFontWeight(syllableCount: count))
            } else if !enabled && syllablesEnabled {
                seg.foregroundColor = syllableColor(for: count)
                seg.font = .body.weight(.semibold)
            } else {
                seg.foregroundColor = .primary
                if syllablesEnabled {
                    seg.underlineStyle = Text.LineStyle(
                        pattern: .solid,
                        color: syllableColor(for: count)
                    )
                }
            }
            result += seg
            cursor = tok.range.upperBound
        }

        if cursor < text.endIndex {
            var tail = AttributedString(String(text[cursor...]))
            tail.foregroundColor = .primary
            result += tail
        }

        return result
    }

    private func colorFor(key: String) -> Color {
        let p = palette
        // Stable across launches: Swift's `hashValue` is per-process seeded, so a
        // rhyme family would recolor every launch. FNV-1a over the key's UTF-8
        // bytes is deterministic. `&*`/`&+` wrap on overflow instead of trapping.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let index = Int(hash % UInt64(p.count))
        return p[index]
    }

    private func syllableColor(for count: Int) -> Color {
        if appearance.usesDarkAnalysisPalette {
            switch count {
            case 1: return Color(red: 110.0 / 255, green: 231.0 / 255, blue: 183.0 / 255)
            case 2: return Color(red: 147.0 / 255, green: 197.0 / 255, blue: 253.0 / 255)
            case 3: return Color(red: 216.0 / 255, green: 180.0 / 255, blue: 254.0 / 255)
            default: return Color(red: 253.0 / 255, green: 164.0 / 255, blue: 175.0 / 255)
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
