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
        case .simple: return "Plain language, no wordplay"
        case .moderate: return "Balanced vocabulary, natural phrasing"
        case .complex: return "Advanced vocabulary, wordplay, intricate rhymes"
        }
    }

    /// Simple and Complex carry numeric, checkable targets (words per line and
    /// the end word's syllables) that pair with the level-aware allowed
    /// end-word list (`RhymeConstraint.levelEndWords`); only Complex asks for
    /// wordplay. Simple only prefers one-syllable endings: its list falls back
    /// to longer words when an anchor has fewer than six one-syllable rhymes,
    /// and chorus hook words are never filtered by the level. Byte-identical to
    /// Android `RhymeComplexity.promptHint` and finetune/eval/prompts.py.
    var promptHint: String {
        switch self {
        case .simple:
            return "Each line must be 4 to 7 plain, everyday words. Prefer one-syllable end words. No wordplay."
        case .moderate:
            return "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear rather than clever."
        case .complex:
            return "Each line must be 8 to 12 words. End each line on a word of two or more syllables, or put an internal rhyme inside the line. Use vivid, specific, less common words and double meanings."
        }
    }
}

nonisolated enum SongSection: String, Codable, Sendable {
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
            return "Section direction: follow any explicit section label that is provided; otherwise fit the immediate stanza and surrounding lyric context."
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

/// Rhyme context of the line a next-line suggestion will be inserted as
/// (see `NextLinePlacement`), not of the line the cursor is on.
nonisolated struct RhymeContext: Sendable {
    /// Rhyme anchor: the latest earlier line in the stanza with `currentLetter`.
    let targetLine: String?
    /// Scheme letter of the line to be inserted.
    let currentLetter: String
    /// The cursor's blank-line-delimited block, with an empty row at
    /// `currentLineIndex` standing for the line to be inserted.
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

    /// The block's existing lines, without the row reserved for the new line.
    var existingStanzaLines: [String] {
        guard stanzaLines.indices.contains(currentLineIndex),
              stanzaLines[currentLineIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return stanzaLines
        }
        var lines = stanzaLines
        lines.remove(at: currentLineIndex)
        return lines
    }

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
