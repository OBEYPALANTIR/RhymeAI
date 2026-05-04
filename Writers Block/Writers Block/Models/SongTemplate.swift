import Foundation

struct SongTemplate: Identifiable {
    let id = UUID()
    let name: String
    let theme: String
    let lyrics: String
    let icon: String

    static let builtIn: [SongTemplate] = [
        SongTemplate(
            name: "Pop Song",
            theme: "Upbeat, catchy, relatable",
            lyrics: "[Verse 1]\n\n\n[Pre-Chorus]\n\n\n[Chorus]\n\n\n[Verse 2]\n\n\n[Pre-Chorus]\n\n\n[Chorus]\n\n\n[Bridge]\n\n\n[Chorus]\n\n\n[Outro]\n",
            icon: "music.mic"
        ),
        SongTemplate(
            name: "Rap / Hip-Hop",
            theme: "Storytelling, rhythm, flow",
            lyrics: "[Intro]\n\n\n[Verse 1]\n\n\n[Hook]\n\n\n[Verse 2]\n\n\n[Hook]\n\n\n[Bridge]\n\n\n[Hook]\n\n\n[Outro]\n",
            icon: "beats.headphones"
        ),
        SongTemplate(
            name: "Country",
            theme: "Storytelling, acoustic, heartfelt",
            lyrics: "[Verse 1]\n\n\n[Chorus]\n\n\n[Verse 2]\n\n\n[Chorus]\n\n\n[Bridge]\n\n\n[Chorus]\n\n\n[Outro]\n",
            icon: "guitars"
        ),
        SongTemplate(
            name: "Haiku",
            theme: "Nature, concise, 5-7-5 syllables",
            lyrics: "Line 1 (5 syllables):\n\nLine 2 (7 syllables):\n\nLine 3 (5 syllables):\n",
            icon: "leaf"
        )
    ]
}
