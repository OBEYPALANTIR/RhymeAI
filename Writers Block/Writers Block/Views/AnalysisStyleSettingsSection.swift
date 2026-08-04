import SwiftUI

struct AnalysisStyleSettingsSection: View {
    @Environment(\.analysisPresentationBinding) private var presentation
    @Environment(\.appAppearanceStyle) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Label("Analysis Style", systemImage: "textformat.abc.dottedunderline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.palette.secondaryInk)
                .textCase(.uppercase)

            Picker("Analysis Style", selection: presentation) {
                ForEach(AnalysisPresentationStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("analysisStylePicker")

            AnalysisStylePreview(style: presentation.wrappedValue)

            Group {
                if presentation.wrappedValue == .inkMarks {
                    Text("Solid, dashed, dotted, and dash-dot lines identify rhyme families.")
                    Text("Heavier words contain more syllables.")
                } else {
                    Text("Color identifies rhyme families and syllable counts.")
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(appearance.palette.secondaryInk)
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl)
    }
}

private struct AnalysisStylePreview: View {
    let style: AnalysisPresentationStyle

    var body: some View {
        RhymeHighlightedText(
            text: "Light in the night\nFire climbing higher",
            enabled: true,
            syllablesEnabled: true
        )
        .environment(\.analysisPresentationStyle, style)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RhymeAITokens.Spacing.sm)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md)
    }
}
