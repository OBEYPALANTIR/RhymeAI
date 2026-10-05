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

            RhymeSegmentedControl(
                options: AnalysisPresentationStyle.allCases,
                selection: presentation,
                accessibilityIdentifier: "analysisStylePicker",
                label: "Analysis Style",
                title: \.displayName
            )

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
        // A sample, not a control: it sits on the group card without a
        // second border of its own.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, RhymeAITokens.Spacing.xxs)
        .accessibilityLabel("Sample lyric in the \(style.displayName) style")
    }
}
