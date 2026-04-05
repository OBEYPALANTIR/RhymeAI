package com.rhymeai.app.data.model

data class SongTemplate(
    val name: String,
    val theme: String,
    val lyrics: String
)

val SONG_TEMPLATES = listOf(
    SongTemplate(
        name = "Pop Song",
        theme = "Upbeat, catchy, relatable",
        lyrics = "[Verse 1]\n\n\n[Pre-Chorus]\n\n\n[Chorus]\n\n\n[Verse 2]\n\n\n[Pre-Chorus]\n\n\n[Chorus]\n\n\n[Bridge]\n\n\n[Chorus]\n\n\n[Outro]\n"
    ),
    SongTemplate(
        name = "Rap / Hip-Hop",
        theme = "Storytelling, rhythm, flow",
        lyrics = "[Intro]\n\n\n[Verse 1]\n\n\n[Hook]\n\n\n[Verse 2]\n\n\n[Hook]\n\n\n[Bridge]\n\n\n[Hook]\n\n\n[Outro]\n"
    ),
    SongTemplate(
        name = "Country",
        theme = "Storytelling, acoustic, heartfelt",
        lyrics = "[Verse 1]\n\n\n[Chorus]\n\n\n[Verse 2]\n\n\n[Chorus]\n\n\n[Bridge]\n\n\n[Chorus]\n\n\n[Outro]\n"
    ),
    SongTemplate(
        name = "Haiku",
        theme = "Nature, concise, 5-7-5 syllables",
        lyrics = "Line 1 (5 syllables):\n\nLine 2 (7 syllables):\n\nLine 3 (5 syllables):\n"
    )
)
