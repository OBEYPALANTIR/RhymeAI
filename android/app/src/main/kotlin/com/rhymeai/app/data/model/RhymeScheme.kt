package com.rhymeai.app.data.model

enum class RhymeScheme(val label: String, val pattern: String) {
    AABB("AABB", "AABB"),
    ABAB("ABAB", "ABAB"),
    ABCB("ABCB", "ABCB"),
    AAAA("AAAA", "AAAA"),
    CUSTOM("Custom...", "");

    companion object {
        fun fromLabel(label: String): RhymeScheme =
            entries.find { it.label == label } ?: AABB
    }
}

enum class RhymeType(val displayName: String) {
    PERFECT("Perfect Rhyme"),
    NEAR("Near Rhyme"),
    SLANT("Slant Rhyme")
}
