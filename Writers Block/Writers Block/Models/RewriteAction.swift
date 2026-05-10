import Foundation

enum RewriteAction: String, CaseIterable, Identifiable {
    case rephrase
    case harderRhyme
    case punchUp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rephrase: return "Rephrase"
        case .harderRhyme: return "Harder Rhyme"
        case .punchUp: return "Punch Up"
        }
    }

    var instruction: String {
        switch self {
        case .rephrase:
            return "Rewrite this passage using different wording while preserving the exact meaning and tone. Keep roughly the same syllable count and the same rhyme positions at the end of each line."
        case .harderRhyme:
            return "Rewrite this passage so the last word of each line forms a stronger rhyme with the prior line's ending word. Preserve meaning and meter. Prefer multi-syllable rhymes where they fit."
        case .punchUp:
            return "Rewrite this passage with sharper, more visceral, and more aggressive imagery. Preserve meaning and rhyme positions. Avoid clichés. Hit harder."
        }
    }
}
