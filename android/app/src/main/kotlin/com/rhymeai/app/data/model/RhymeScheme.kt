package com.rhymeai.app.data.model

enum class RhymeScheme(val label: String, val pattern: String) {
    AABB("AABB", "AABB"),
    ABAB("ABAB", "ABAB"),
    ABCB("ABCB", "ABCB"),
    AAAA("AAAA", "AAAA"),
    CUSTOM("Custom...", "")
}

enum class RhymeType(val displayName: String) {
    PERFECT("Perfect Rhyme"),
    NEAR("Near Rhyme"),
    SLANT("Slant Rhyme")
}

enum class RhymeComplexity(val level: Int, val label: String, val description: String, val promptHint: String) {
    // Only COMPLEX asks for wordplay. promptHint is byte-identical to iOS RhymeComplexity.promptHint.
    SIMPLE(0, "Simple", "Plain language, no wordplay",
        "Use plain, simple, everyday language. No wordplay, puns, or clever twists. Use clear rhymes that are easy to hear."),
    MODERATE(1, "Moderate", "Balanced vocabulary, natural phrasing",
        "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear rather than clever."),
    COMPLEX(2, "Complex", "Advanced vocabulary, wordplay, intricate rhymes",
        "Use advanced, rich vocabulary with clever wordplay and intricate rhymes: multi-syllable rhymes, internal rhymes, and double meanings.")
}
