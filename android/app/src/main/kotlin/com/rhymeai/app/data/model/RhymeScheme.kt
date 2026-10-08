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
    // Simple and Complex carry numeric, checkable targets (words per line and the
    // end word's syllables) that pair with the level-aware allowed end-word list
    // (RhymeConstraint.levelEndWords); only COMPLEX asks for wordplay. promptHint is
    // byte-identical to iOS RhymeComplexity.promptHint and finetune/eval/prompts.py.
    SIMPLE(0, "Simple", "Plain language, no wordplay",
        "Each line must be 4 to 7 plain, everyday words. End each line on a one-syllable word. No wordplay."),
    MODERATE(1, "Moderate", "Balanced vocabulary, natural phrasing",
        "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear rather than clever."),
    COMPLEX(2, "Complex", "Advanced vocabulary, wordplay, intricate rhymes",
        "Each line must be 8 to 12 words. End each line on a word of two or more syllables, or put an internal rhyme inside the line. Use vivid, specific, less common words and double meanings.")
}
