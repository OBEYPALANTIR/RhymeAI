import SwiftUI

// Per-word rhyme keys and syllable counts are pure functions of the word and the
// static pronunciation dictionary, but analyzing the editor recomputes them for every
// word on every keystroke, which drops frames on long lyrics. Caching by lowercased
// word (both lookups normalize case internally, so this is output-identical) means a
// keystroke only pays for words it hasn't seen before.
nonisolated private final class WordAnalysisCache: @unchecked Sendable {
    static let shared = WordAnalysisCache()

    private let lock = NSLock()
    private var entries: [String: (rhymeKeys: [String], syllableCount: Int)] = [:]
    private static let capacity = 4096

    func analysis(for word: String) -> (rhymeKeys: [String], syllableCount: Int) {
        let key = word.lowercased()
        lock.lock()
        if let hit = entries[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let value = (RhymePhonetics.rhymeKeys(for: key), SyllableCounter.count(key))
        lock.lock()
        defer { lock.unlock() }
        if let hit = entries[key] { return hit }
        if entries.count >= Self.capacity {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = value
        return value
    }
}

private struct HighlightToken: Sendable {
    let location: Int
    let length: Int
    let familyKey: String?
    let syllableCount: Int
}

private struct HighlightAnalysis: Sendable {
    let source: String
    let tokens: [HighlightToken]
}

private struct HighlightAnalysisRequest: Hashable, Sendable {
    let source: String
    let rhymeEnabled: Bool
}

struct LyricsColorSpan: Sendable {
    let range: NSRange
    let foreground: Color?
    let underline: Color?
}

nonisolated private final class HighlightAnalysisCache: @unchecked Sendable {
    static let shared = HighlightAnalysisCache()

    private let lock = NSLock()
    private var latestRequest: HighlightAnalysisRequest?
    private var latestAnalysis: HighlightAnalysis?

    func analysis(
        for request: HighlightAnalysisRequest,
        build: () -> HighlightAnalysis
    ) -> HighlightAnalysis {
        lock.lock()
        if latestRequest == request, let latestAnalysis {
            lock.unlock()
            return latestAnalysis
        }
        lock.unlock()

        let computed = build()
        lock.lock()
        defer { lock.unlock() }
        if latestRequest == request, let latestAnalysis {
            return latestAnalysis
        }
        latestRequest = request
        latestAnalysis = computed
        return computed
    }
}

enum LyricsHighlighting {
    nonisolated private static let palettePastel: [Color] = [
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

    nonisolated private static let paletteDark: [Color] = [
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

    static func spans(text: String, rhymeEnabled: Bool, syllablesEnabled: Bool, isDark: Bool) async -> [LyricsColorSpan] {
        await Task.detached(priority: .userInitiated) {
            let request = HighlightAnalysisRequest(source: text, rhymeEnabled: rhymeEnabled)
            let analysis = HighlightAnalysisCache.shared.analysis(for: request) {
                analyze(text: text, rhymeEnabled: rhymeEnabled)
            }
            return analysis.tokens.compactMap { token in
                let foreground: Color?
                if rhymeEnabled, let key = token.familyKey {
                    foreground = colorFor(key: key, isDark: isDark)
                } else if !rhymeEnabled && syllablesEnabled {
                    foreground = syllableColor(for: token.syllableCount, isDark: isDark)
                } else {
                    foreground = nil
                }
                return LyricsColorSpan(
                    range: NSRange(location: token.location, length: token.length),
                    foreground: foreground,
                    underline: rhymeEnabled && syllablesEnabled
                        ? syllableColor(for: token.syllableCount, isDark: isDark) : nil
                )
            }
        }.value
    }

    nonisolated private static func analyze(
        text: String,
        rhymeEnabled: Bool
    ) -> HighlightAnalysis {
        let nsText = text as NSString
        let headerRanges = SectionMap.headerRanges(text)
        let matches = LyricRegex.word.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ).filter { match in
            !SectionMap.intersectsHeader(match.range, headerRanges: headerRanges)
        }
        let analyses = matches.map { match in
            WordAnalysisCache.shared.analysis(for: nsText.substring(with: match.range))
        }
        let keysPerToken: [[String]] = analyses.map { $0.rhymeKeys }

        var keyOccurrences: [String: Int] = [:]
        if rhymeEnabled {
            for keys in keysPerToken {
                for key in keys { keyOccurrences[key, default: 0] += 1 }
            }
        }
        let familyKeyPerToken: [String?] = keysPerToken.map { keys in
            rhymeEnabled ? keys.last { (keyOccurrences[$0] ?? 0) >= 2 } : nil
        }

        let tokens = matches.enumerated().map { index, match in
            HighlightToken(
                location: match.range.location,
                length: match.range.length,
                familyKey: familyKeyPerToken[index],
                syllableCount: analyses[index].syllableCount
            )
        }
        return HighlightAnalysis(source: text, tokens: tokens)
    }

    nonisolated private static func colorFor(key: String, isDark: Bool) -> Color {
        let palette = isDark ? palettePastel : paletteDark
        // Stable across launches: Swift's `hashValue` is per-process seeded, so a
        // rhyme family would recolor every launch. FNV-1a over the key's UTF-8
        // bytes is deterministic. `&*`/`&+` wrap on overflow instead of trapping.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let index = Int(hash % UInt64(palette.count))
        return palette[index]
    }

    nonisolated private static func syllableColor(for count: Int, isDark: Bool) -> Color {
        if isDark {
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
