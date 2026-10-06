import SwiftUI

enum FeatureLegend {
    case syllables
    case rhymes
}

enum FeatureHelp: String, Identifiable {
    case contextTheme
    case targetLine
    case rhymeScheme
    case rhymeDensity
    case complexity
    case wholeSongContext
    case highlightRhymes
    case underlineSyllables
    case stressIPA
    case colorRhymes
    case beatGrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contextTheme: return "Context & Theme"
        case .targetLine: return "Target Line"
        case .rhymeScheme: return "Rhyme Scheme"
        case .rhymeDensity: return "Rhyme Density"
        case .complexity: return "Complexity"
        case .wholeSongContext: return "Whole Song Context"
        case .highlightRhymes: return "Highlight Rhymes"
        case .underlineSyllables: return "Syllable Guide"
        case .stressIPA: return "Stress + IPA"
        case .colorRhymes: return "Rhyme Families"
        case .beatGrid: return "Beat Grid"
        }
    }

    var message: String {
        switch self {
        case .contextTheme:
            return "Adds a short topic or mood that steers the next line. It is sent with every suggestion request, together with the full lyric when Whole Song Context is on. Leave it empty and the assistant works from the lyrics alone."
        case .targetLine:
            return "The earlier line the next suggestion has to rhyme with, picked by your rhyme scheme for the line being added. It is empty when the next line starts a new rhyme sound."
        case .rhymeScheme:
            return "Chooses the pattern the song should follow. Common patterns like AABB pair nearby lines, while Custom lets you type your own letter pattern."
        case .rhymeDensity:
            return "Controls how tightly the suggestion should rhyme. Perfect is strict, Near gives a little room, and Slant is the most flexible."
        case .complexity:
            return "Changes how advanced the suggested lines should be. Simple keeps the language plain with no wordplay, Moderate uses a balanced vocabulary, and Complex asks for clever wordplay and intricate rhymes."
        case .wholeSongContext:
            return "Uses the full current lyric as context so suggestions fit the story, tone, and previous lines. Turning it off uses only the theme and target line."
        case .highlightRhymes:
            return "Highlights rhyme words in suggestions so matching sounds are easier to spot before you insert a line."
        case .underlineSyllables:
            return "Marks words by syllable count with semantic colors. When Rhyme Families is on, the syllable colors move to underlines so both guides remain readable."
        case .stressIPA:
            return "Shows dictionary-backed syllable stress and IPA previews for the target line and suggestions. Primary stress is ˈDA, secondary stress is ˌDA, and unstressed syllables are da."
        case .colorRhymes:
            return "Colors identify words that share a rhyme sound. Matching colors belong to the same rhyme family."
        case .beatGrid:
            return "Shows how many beats each line fills at the current BPM. Lines that fit within one bar are normal, tight lines use one extra beat of grace, and overflow lines exceed the bar in red."
        }
    }

    var legend: FeatureLegend? {
        switch self {
        case .underlineSyllables: return .syllables
        case .colorRhymes: return .rhymes
        default: return nil
        }
    }
}

struct AssistantProsodyPreviewView: View {
    let text: String
    private var prosody: LineProsody { ProsodyAnalyzer.analyzeLine(text) }

    var body: some View {
        if prosody.syllableCount > 0 {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.hairline) {
                if !prosody.feet.isEmpty {
                    Text(prosody.feet)
                }
                if !prosody.ipa.isEmpty {
                    Text("/\(prosody.ipa)/")
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary.opacity(0.72))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FeatureHelpSheet: View {
    let help: FeatureHelp
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.lg) {
                    Text(help.message)
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)

                    switch help.legend {
                    case .syllables:
                        SyllableLegendView()
                    case .rhymes:
                        RhymeLegendView()
                    case nil:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(RhymeAITokens.Spacing.md)
            }
            .background(AppWritingBackground())
            .navigationTitle(help.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SyllableLegendView: View {
    @Environment(\.appAppearanceStyle) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Text("Syllable colors")
                .font(.subheadline.weight(.semibold))

            SyllableLegendRow(color: syllableColor(1), label: "1 syllable")
            SyllableLegendRow(color: syllableColor(2), label: "2 syllables")
            SyllableLegendRow(color: syllableColor(3), label: "3 syllables")
            SyllableLegendRow(color: syllableColor(4), label: "4+ syllables")
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .white.opacity(0.04), fallbackOpacity: 0.06)
    }

    private func syllableColor(_ count: Int) -> Color {
        SyllableColoredText.syllableColor(
            for: count,
            usesDarkPalette: appearance.usesDarkAnalysisPalette
        )
    }
}

private struct SyllableLegendRow: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            Capsule()
                .fill(color)
                .frame(width: 28, height: 4)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RhymeLegendView: View {
    @Environment(\.appAppearanceStyle) private var appearance

    private let palettePastel: [Color] = [
        Color(red: 252/255, green: 165/255, blue: 165/255),
        Color(red: 252/255, green: 211/255, blue:  77/255),
        Color(red: 134/255, green: 239/255, blue: 172/255),
        Color(red: 125/255, green: 211/255, blue: 252/255),
        Color(red: 196/255, green: 181/255, blue: 253/255),
        Color(red: 249/255, green: 168/255, blue: 212/255)
    ]

    private let paletteDark: [Color] = [
        Color(red: 185/255, green:  28/255, blue:  28/255),
        Color(red: 180/255, green:  83/255, blue:   9/255),
        Color(red:  21/255, green: 128/255, blue:  61/255),
        Color(red:   3/255, green: 105/255, blue: 161/255),
        Color(red: 109/255, green:  40/255, blue: 217/255),
        Color(red: 190/255, green:  24/255, blue:  93/255)
    ]

    private var palette: [Color] {
        appearance.usesDarkAnalysisPalette ? palettePastel : paletteDark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Text("Rhyme family colors")
                .font(.subheadline.weight(.semibold))

            Text("Matching colors belong to the same rhyme family.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: RhymeAITokens.Spacing.xs) {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(width: RhymeAITokens.Spacing.md, height: RhymeAITokens.Spacing.md)
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.18), lineWidth: RhymeAITokens.Spacing.hairline)
                        )
                }
            }
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .white.opacity(0.04), fallbackOpacity: 0.06)
    }
}
