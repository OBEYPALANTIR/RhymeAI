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
    SIMPLE(0, "Simple", "Basic vocabulary, straightforward rhymes",
        "Use simple, everyday vocabulary. Keep the language accessible and straightforward. Aim for clear, easy-to-understand rhymes."),
    MODERATE(1, "Moderate", "Balanced vocabulary, clever wordplay",
        "Use a balanced vocabulary with some clever wordplay. The rhymes should be interesting but not overly complex."),
    COMPLEX(2, "Complex", "Advanced vocabulary, intricate rhymes",
        "Use advanced, rich vocabulary with intricate multi-syllable rhymes, internal rhymes, and sophisticated wordplay. Push the boundaries of lyrical complexity.")
}
