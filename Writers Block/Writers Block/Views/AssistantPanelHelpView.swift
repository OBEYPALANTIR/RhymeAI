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

    func message(for presentation: AnalysisPresentationStyle) -> String {
        switch self {
        case .contextTheme:
            return "Adds a short topic or mood for the assistant when Whole Song Context is off. Use it to steer the next line without sending the full lyric."
        case .targetLine:
            return "The lyric line the assistant is matching. Put the cursor on a line when you want suggestions to rhyme with that exact sound."
        case .rhymeScheme:
            return "Chooses the pattern the song should follow. Common patterns like AABB pair nearby lines, while Custom lets you type your own letter pattern."
        case .rhymeDensity:
            return "Controls how tightly the suggestion should rhyme. Perfect is strict, Near gives a little room, and Slant is the most flexible."
        case .complexity:
            return "Changes how advanced the generated line should be. Higher complexity leans toward richer wording, multisyllable rhymes, and denser phrasing."
        case .wholeSongContext:
            return "Uses the full current lyric as context so suggestions fit the story, tone, and previous lines. Turning it off uses only the theme and target line."
        case .highlightRhymes:
            return "Highlights rhyme words in suggestions so matching sounds are easier to spot before you insert a line."
        case .underlineSyllables:
            switch presentation {
            case .color:
                return "Marks words by syllable count with semantic colors. When Rhyme Families is on, the syllable colors move to underlines so both guides remain readable."
            case .inkMarks:
                return "Uses progressively heavier text for higher syllable counts, so syllable cues remain distinct alongside rhyme-family underline patterns."
            }
        case .stressIPA:
            return "Shows dictionary-backed syllable stress and IPA previews for the target line and suggestions. Primary stress is ˈDA, secondary stress is ˌDA, and unstressed syllables are da."
        case .colorRhymes:
            switch presentation {
            case .color:
                return "Colors identify words that share a rhyme sound. Matching colors belong to the same rhyme family."
            case .inkMarks:
                return "Underline patterns identify words that share a rhyme sound. Matching patterns belong to the same rhyme family."
            }
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
    @Environment(\.analysisPresentationStyle) private var analysisPresentation

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.lg) {
                    Text(help.message(for: analysisPresentation))
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
    @Environment(\.analysisPresentationStyle) private var analysisPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Text(analysisPresentation == .color ? "Syllable colors" : "Syllable weights")
                .font(.subheadline.weight(.semibold))

            if analysisPresentation == .color {
                SyllableLegendRow(color: syllableColor(1), label: "1 syllable")
                SyllableLegendRow(color: syllableColor(2), label: "2 syllables")
                SyllableLegendRow(color: syllableColor(3), label: "3 syllables")
                SyllableLegendRow(color: syllableColor(4), label: "4+ syllables")
            } else {
                SyllableWeightLegendRow(count: 1, label: "1 syllable")
                SyllableWeightLegendRow(count: 2, label: "2 syllables")
                SyllableWeightLegendRow(count: 3, label: "3 syllables")
                SyllableWeightLegendRow(count: 4, label: "4+ syllables")
            }
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

private struct SyllableWeightLegendRow: View {
    let count: Int
    let label: String

    var body: some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            Text("Aa")
                .font(.caption.weight(analysisFontWeight(syllableCount: count)))
                .frame(width: 28)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
    @Environment(\.analysisPresentationStyle) private var analysisPresentation

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
            Text(analysisPresentation == .color ? "Rhyme family colors" : "Rhyme family patterns")
                .font(.subheadline.weight(.semibold))

            Text(
                analysisPresentation == .color
                    ? "Matching colors belong to the same rhyme family."
                    : "Matching underline patterns belong to the same rhyme family."
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            if analysisPresentation == .color {
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
            } else {
                HStack(spacing: RhymeAITokens.Spacing.md) {
                    ForEach(InkUnderlinePattern.allCases, id: \.self) { pattern in
                        patternSample(pattern)
                    }
                }
            }
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .white.opacity(0.04), fallbackOpacity: 0.06)
    }

    private func patternSample(_ pattern: InkUnderlinePattern) -> Text {
        var sample = AttributedString("rhyme")
        sample.foregroundColor = appearance.palette.primaryInk
        sample.underlineStyle = pattern.lineStyle
        return Text(sample).font(.caption)
    }
}
