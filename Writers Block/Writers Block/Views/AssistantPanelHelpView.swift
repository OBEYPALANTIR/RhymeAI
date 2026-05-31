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
        case .underlineSyllables: return "Underline Syllables"
        case .stressIPA: return "Stress + IPA"
        case .colorRhymes: return "Color Rhymes"
        }
    }

    var message: String {
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
            return "Draws colored underlines under words by syllable count. This keeps syllable cues visible while leaving rhyme colors free for rhyme families."
        case .stressIPA:
            return "Shows dictionary-backed syllable stress and IPA previews for the target line and suggestions. Stressed syllables are shown as DA and unstressed syllables as da."
        case .colorRhymes:
            return "Colors words that share the same rhyme sound. Each color represents a rhyme family, so matching colors should rhyme or echo each other."
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
            .font(.caption2.monospaced())
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
            .background(Color(UIColor.systemBackground))
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Text("Underline colors")
                .font(.subheadline.weight(.semibold))

            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 1, scheme: colorScheme), label: "1 syllable")
            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 2, scheme: colorScheme), label: "2 syllables")
            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 3, scheme: colorScheme), label: "3 syllables")
            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 4, scheme: colorScheme), label: "4+ syllables")
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .white.opacity(0.04), fallbackOpacity: 0.06)
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
    @Environment(\.colorScheme) private var colorScheme

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
        colorScheme == .dark ? palettePastel : paletteDark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Text("Rhyme colors")
                .font(.subheadline.weight(.semibold))

            Text("Matching colors belong to the same rhyme family. New rhyme families get the next available color.")
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
