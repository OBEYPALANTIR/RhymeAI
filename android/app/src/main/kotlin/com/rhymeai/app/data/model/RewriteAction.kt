package com.rhymeai.app.data.model

enum class RewriteAction(
    val label: String,
    val instruction: String
) {
    REPHRASE(
        label = "Rephrase",
        instruction = "Rewrite this passage using different wording while preserving the exact meaning and tone. Keep roughly the same syllable count and the same rhyme positions at the end of each line."
    ),
    HARDER_RHYME(
        label = "Harder Rhyme",
        instruction = "Rewrite this passage so the last word of each line forms a stronger rhyme with the prior line's ending word. Preserve meaning and meter. Prefer multi-syllable rhymes where they fit."
    ),
    PUNCH_UP(
        label = "Punch Up",
        instruction = "Rewrite this passage with sharper, more visceral, and more aggressive imagery. Preserve meaning and rhyme positions. Avoid clichés. Hit harder."
    )
}
