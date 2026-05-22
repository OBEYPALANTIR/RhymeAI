package com.rhymeai.app.data.model

enum class SongSection(
    val displayName: String,
    val promptHint: String
) {
    VERSE(
        "Verse",
        "Section direction: write it like a verse. Advance the narrative with concrete details, cause-and-effect, and a clear speaker perspective."
    ),
    CHORUS(
        "Chorus",
        "Section direction: write it like a chorus or hook. Make it memorable, compact, repeatable, and emotionally direct without sounding like a slogan."
    ),
    BRIDGE(
        "Bridge",
        "Section direction: write it like a bridge. Create a harmonic or emotional turn, add contrast, and set up a satisfying return."
    ),
    UNKNOWN(
        "Unmarked section",
        "Section direction: no verse, chorus, or bridge header was detected. Fit the immediate stanza and surrounding lyric context."
    );

    companion object {
        fun fromHeader(header: String): SongSection {
            val normalized = header
                .trim()
                .removePrefix("[")
                .removeSuffix("]")
                .trim()
                .lowercase()

            return when {
                normalized.contains("verse") -> VERSE
                normalized.contains("bridge") -> BRIDGE
                normalized.contains("hook") -> CHORUS
                normalized.contains("chorus") && !normalized.contains("pre-chorus") -> CHORUS
                else -> UNKNOWN
            }
        }
    }
}
