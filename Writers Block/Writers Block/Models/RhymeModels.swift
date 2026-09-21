import Foundation

enum RhymeScheme: String, CaseIterable, Codable {
    case aabb = "AABB"
    case abab = "ABAB"
    case abcb = "ABCB"
    case aaaa = "AAAA"
    case custom = "Custom"

    var label: String { rawValue }

    var pattern: String {
        switch self {
        case .custom: return ""
        default: return rawValue
        }
    }
}

enum RhymeType: String, CaseIterable, Codable {
    case perfect = "Perfect Rhyme"
    case near = "Near Rhyme"
    case slant = "Slant Rhyme"

    var displayName: String { rawValue }

    var shortName: String {
        switch self {
        case .perfect: return "Perfect"
        case .near: return "Near"
        case .slant: return "Slant"
        }
    }
}

enum RhymeComplexity: Int, CaseIterable, Codable {
    case simple = 0
    case moderate = 1
    case complex = 2

    var label: String {
        switch self {
        case .simple: return "Simple"
        case .moderate: return "Moderate"
        case .complex: return "Complex"
        }
    }

    var description: String {
        switch self {
        case .simple: return "Basic vocabulary, straightforward rhymes"
        case .moderate: return "Balanced vocabulary, clever wordplay"
        case .complex: return "Advanced vocabulary, intricate rhymes"
        }
    }

    var promptHint: String {
        switch self {
        case .simple:
            return "Use simple, everyday vocabulary. Keep the language accessible and straightforward. Aim for clear, easy-to-understand rhymes."
        case .moderate:
            return "Use a balanced vocabulary with some clever wordplay. The rhymes should be interesting but not overly complex."
        case .complex:
            return "Use advanced, rich vocabulary with intricate multi-syllable rhymes, internal rhymes, and sophisticated wordplay. Push the boundaries of lyrical complexity."
        }
    }
}

enum SongSection: String, Codable {
    case verse
    case chorus
    case bridge
    case unknown

    var displayName: String {
        switch self {
        case .verse: return "Verse"
        case .chorus: return "Chorus"
        case .bridge: return "Bridge"
        case .unknown: return "Unmarked section"
        }
    }

    var promptHint: String {
        switch self {
        case .verse:
            return "Section direction: write it like a verse. Advance the narrative with concrete details, cause-and-effect, and a clear speaker perspective."
        case .chorus:
            return "Section direction: write it like a chorus or hook. Make it memorable, compact, repeatable, and emotionally direct without sounding like a slogan."
        case .bridge:
            return "Section direction: write it like a bridge. Create a harmonic or emotional turn, add contrast, and set up a satisfying return."
        case .unknown:
            return "Section direction: no verse, chorus, or bridge header was detected. Fit the immediate stanza and surrounding lyric context."
        }
    }

    nonisolated static func fromHeader(_ header: String) -> SongSection {
        let normalized = header
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.contains("verse") { return .verse }
        if normalized.contains("bridge") { return .bridge }
        if normalized.contains("hook") { return .chorus }
        if normalized.contains("chorus") {
            // "Pre-Chorus" / "Pre Chorus" / "PreChorus" are not the chorus.
            let squashed = normalized
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")
            return squashed.contains("prechorus") ? .unknown : .chorus
        }
        return .unknown
    }
}

/// A suggestion line paired with its rhyme-quality tier so the UI can badge it.
/// Tier 2 = perfect or multi-syllable rhyme; 1 = near rhyme; 0 = unverified.
struct SuggestedLine: Identifiable {
    let id = UUID()
    let text: String
    let tier: Int
    /// True when this is a chorus repeat and the end word matches the first chorus.
    let isHookRepeat: Bool

    init(text: String, tier: Int, isHookRepeat: Bool = false) {
        self.text = text
        self.tier = tier
        self.isHookRepeat = isHookRepeat
    }
}

struct RhymeContext {
    let targetLine: String?
    let currentLetter: String
    let stanzaLines: [String]
    let currentLineIndex: Int
    let currentSection: SongSection
    /// 1-based ordinal of the current section among sections of the same type.
    let sectionOrdinal: Int
    /// Non-header lyric lines from the FIRST chorus/hook in the song, used to
    /// enforce hook consistency on subsequent choruses. Nil when not applicable.
    let firstChorusLines: [String]?

    static let empty = RhymeContext(
        targetLine: nil,
        currentLetter: "A",
        stanzaLines: [],
        currentLineIndex: 0,
        currentSection: .unknown,
        sectionOrdinal: 1,
        firstChorusLines: nil
    )

    static func emptyContext(currentLetter: String = "A", currentSection: SongSection = .unknown) -> RhymeContext {
        RhymeContext(
            targetLine: nil,
            currentLetter: currentLetter,
            stanzaLines: [],
            currentLineIndex: 0,
            currentSection: currentSection,
            sectionOrdinal: 1,
            firstChorusLines: nil
        )
    }
}

func suggestionRhymeBadgeLabel(rhymeTier: Int, isHookRepeat: Bool) -> String? {
    if isHookRepeat { return "hook" }
    switch rhymeTier {
    case 3: return "slant"
    case 2: return "perfect"
    case 1: return "near"
    default: return nil
    }
}
