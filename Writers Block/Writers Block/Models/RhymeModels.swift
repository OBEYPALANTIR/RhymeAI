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

struct RhymeContext {
    let targetLine: String?
    let currentLetter: String
    let stanzaLines: [String]
    let currentLineIndex: Int
}
