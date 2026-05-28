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
        if normalized.contains("chorus") && !normalized.contains("pre-chorus") { return .chorus }
        return .unknown
    }
}

struct RhymeContext {
    let targetLine: String?
    let currentLetter: String
    let stanzaLines: [String]
    let currentLineIndex: Int
    let currentSection: SongSection

    static func emptyContext(currentLetter: String = "A", currentSection: SongSection = .unknown) -> RhymeContext {
        RhymeContext(
            targetLine: nil,
            currentLetter: currentLetter,
            stanzaLines: [],
            currentLineIndex: 0,
            currentSection: currentSection
        )
    }
}
