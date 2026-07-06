import SwiftUI

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

    @Environment(\.colorScheme) private var colorScheme

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

    private static let palettePastel: [Color] = [
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

    private static let paletteDark: [Color] = [
        Color(red: 185/255, green:  28/255, blue:  28/255), // rose-700
        Color(red: 180/255, green:  83/255, blue:   9/255), // amber-700
        Color(red:  21/255, green: 128/255, blue:  61/255), // green-700
        Color(red:   3/255, green: 105/255, blue: 161/255), // sky-700
        Color(red: 109/255, green:  40/255, blue: 217/255), // violet-700
        Color(red: 190/255, green:  24/255, blue:  93/255), // pink-700
        Color(red: 194/255, green:  65/255, blue:  12/255), // orange-700
        Color(red:  14/255, green: 116/255, blue: 144/255), // cyan-700
        Color(red:   4/255, green: 120/255, blue:  87/255), // emerald-700
        Color(red: 126/255, green:  34/255, blue: 206/255), // purple-700
        Color(red: 161/255, green:  98/255, blue:   7/255), // yellow-700
        Color(red:  77/255, green: 124/255, blue:  15/255)  // lime-700
    ]

    private var palette: [Color] {
        colorScheme == .dark ? Self.palettePastel : Self.paletteDark
    }

    var body: some View {
        if (enabled || syllablesEnabled) && !text.isEmpty {
            Text(highlightedAttributedString)
                .font(.system(size: 16))
        } else {
            Text(text)
                .font(.system(size: 16))
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
                seg.foregroundColor = colorFor(key: familyKey)
                seg.font = .system(size: 16, weight: .semibold)
                if syllablesEnabled {
                    seg.underlineStyle = Text.LineStyle(
                        pattern: .solid,
                        color: syllableColor(for: count)
                    )
                }
            } else if !enabled && syllablesEnabled {
                seg.foregroundColor = syllableColor(for: count)
                seg.font = .system(size: 16, weight: .semibold)
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
        if colorScheme == .dark {
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
