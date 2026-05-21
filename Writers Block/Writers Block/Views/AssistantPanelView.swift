import SwiftUI

struct AssistantPanelView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @State private var activeHelp: FeatureHelp?
    var isInline: Bool = false
    var onDismiss: (() -> Void)?

    var body: some View {
        let rhymeContext = viewModel.rhymeContext

        Group {
            if isInline {
                inlineContent(rhymeContext: rhymeContext)
            } else {
                sheetContent(rhymeContext: rhymeContext)
            }
        }
        .onAppear {
            viewModel.positionSeededProsodyCursorForUITests()
        }
        .sheet(item: $activeHelp) { help in
            FeatureHelpSheet(help: help)
        }
    }

    private func sheetContent(rhymeContext: RhymeContext) -> some View {
        NavigationStack {
            panelScrollView(rhymeContext: rhymeContext)
                .background(Color(UIColor.systemBackground))
                .navigationTitle("Assistant")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let onDismiss {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: onDismiss) {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("Close Assistant")
                        }
                    }
                }
        }
    }

    private func inlineContent(rhymeContext: RhymeContext) -> some View {
        VStack(spacing: 0) {
            // Simple header
            HStack {
                Label("Assistant", systemImage: "pencil")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, RhymeAITokens.Spacing.md)
            .padding(.vertical, RhymeAITokens.Spacing.sm)
            .liquidGlassSurface(cornerRadius: 0, fallbackOpacity: 0.02)
            .overlay(Divider(), alignment: .bottom)

            panelScrollView(rhymeContext: rhymeContext)
        }
        .background(Color(UIColor.systemBackground))
    }

    private func panelScrollView(rhymeContext: RhymeContext) -> some View {
        ScrollView {
            panelControls(rhymeContext: rhymeContext)
                .padding(RhymeAITokens.Spacing.md)
                .liquidGlassGroup(spacing: RhymeAITokens.Spacing.md)
        }
    }

    private func panelControls(rhymeContext: RhymeContext) -> some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
            // MARK: - Context & Theme
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                HStack(spacing: RhymeAITokens.Spacing.xs) {
                    Label("Context & Theme", systemImage: "pencil")
                        .font(.headline)
                    helpButton(.contextTheme)
                }

                TextField("What is this song about?", text: $viewModel.theme, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.plain)
                    .padding(RhymeAITokens.Spacing.sm)
                    .liquidGlassSurface(
                        cornerRadius: RhymeAITokens.Radius.md,
                        tint: viewModel.useWholeSongContext ? .gray.opacity(0.12) : .white.opacity(0.04),
                        interactive: !viewModel.useWholeSongContext,
                        fallbackOpacity: viewModel.useWholeSongContext ? 0.04 : 0.06
                    )
                    .disabled(viewModel.useWholeSongContext)
            }

            Divider()

            // MARK: - Target Line
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                HStack {
                    Label("Target Line", systemImage: "text.alignleft")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    helpButton(.targetLine)

                    Spacer()

                    if let targetLine = rhymeContext.targetLine {
                        Text("\(SyllableCounter.countText(targetLine)) syl")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, RhymeAITokens.Spacing.xs)
                            .padding(.vertical, 3)
                            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xs, fallbackOpacity: 0.08)
                    }
                }

                Group {
                    if let targetLine = rhymeContext.targetLine {
                        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                            Text("\"\(targetLine)\"")
                                .font(.system(.body, design: .serif))
                                .italic()
                                .foregroundStyle(.primary.opacity(0.9))

                            if viewModel.isStressPreviewEnabled {
                                AssistantProsodyPreviewView(text: targetLine)
                            }
                        }
                    } else {
                        Text("New rhyme sound (or place cursor on a line)")
                            .font(.caption)
                            .foregroundStyle(.secondary.opacity(0.5))
                            .italic()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(RhymeAITokens.Spacing.sm)
                .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.sm, tint: .white.opacity(0.03), fallbackOpacity: 0.05)
            }

            // MARK: - Rhyme Scheme
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                HStack {
                    featureHelpLabel("Rhyme Scheme", help: .rhymeScheme)

                    Spacer()

                    Picker("Scheme", selection: $viewModel.rhymeScheme) {
                        ForEach(RhymeScheme.allCases, id: \.self) { scheme in
                            Text(scheme.label).tag(scheme)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.indigo)
                }

                if viewModel.rhymeScheme == .custom {
                    TextField("e.g. AABBCC", text: $viewModel.customRhymeScheme)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.characters)
                        .padding(RhymeAITokens.Spacing.sm)
                        .frame(minHeight: RhymeAITokens.Touch.minimum)
                        .liquidGlassSurface(
                            cornerRadius: RhymeAITokens.Radius.md,
                            tint: .white.opacity(0.04),
                            interactive: true,
                            fallbackOpacity: 0.06
                        )
                        .onChange(of: viewModel.customRhymeScheme) { _, newValue in
                            viewModel.customRhymeScheme = newValue.uppercased().filter { $0.isLetter }
                        }
                }

                if !viewModel.lyrics.isEmpty {
                    RhymeSchemeDisplayView(
                        rhymeContext: rhymeContext,
                        activeScheme: viewModel.activeRhymeScheme
                    )
                }
            }

            // MARK: - Rhyme Density
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                featureHelpLabel("Rhyme Density", help: .rhymeDensity)

                Picker("Type", selection: $viewModel.rhymeType) {
                    ForEach(RhymeType.allCases, id: \.self) { type in
                        Text(type.shortName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }

            // MARK: - Complexity
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                HStack {
                    featureHelpLabel("Complexity", help: .complexity)
                    Spacer()
                    Text(viewModel.rhymeComplexity.label)
                        .font(.caption)
                        .foregroundStyle(.indigo)
                }

                Slider(
                    value: Binding(
                        get: { Double(viewModel.rhymeComplexity.rawValue) },
                        set: { viewModel.rhymeComplexity = RhymeComplexity(rawValue: Int($0)) ?? .moderate }
                    ),
                    in: 0...2,
                    step: 1
                )
                .tint(.indigo)

                Text(viewModel.rhymeComplexity.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Toggles
            toggleHelpRow(
                "Whole Song Context",
                help: .wholeSongContext,
                isOn: $viewModel.useWholeSongContext
            )

            toggleHelpRow(
                "Highlight Rhymes",
                help: .highlightRhymes,
                isOn: $viewModel.isHighlightEnabled
            )

            toggleHelpRow(
                "Underline Syllables",
                help: .underlineSyllables,
                isOn: Binding(
                    get: { viewModel.isSyllableColoringEnabled },
                    set: { viewModel.isSyllableColoringEnabled = $0 }
                )
            )

            toggleHelpRow(
                "Stress + IPA",
                help: .stressIPA,
                isOn: Binding(
                    get: { viewModel.isStressPreviewEnabled },
                    set: { viewModel.isStressPreviewEnabled = $0 }
                )
            )

            toggleHelpRow(
                "Color Rhymes",
                help: .colorRhymes,
                isOn: Binding(
                    get: { viewModel.isRhymeHighlightEnabled },
                    set: { viewModel.isRhymeHighlightEnabled = $0 }
                )
            )

            // MARK: - Suggest Button — turns into Stop while streaming
            Button {
                if viewModel.isLoading {
                    viewModel.cancelSuggestions()
                } else {
                    viewModel.getSuggestions()
                }
            } label: {
                let isDisabled = viewModel.lyrics.isEmpty && !viewModel.isLoading
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .tint(.white)
                        Text("Stop")
                    } else {
                        Image(systemName: "sparkles")
                        Text("Suggest Next Line")
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, RhymeAITokens.Spacing.sm)
                .frame(minHeight: RhymeAITokens.Touch.minimum)
                .liquidGlassSurface(
                    cornerRadius: RhymeAITokens.Radius.md,
                    tint: isDisabled ? .gray.opacity(0.2) : .indigo,
                    interactive: !isDisabled,
                    fallbackOpacity: isDisabled ? 0.12 : 0.32
                )
            }
            .disabled(viewModel.lyrics.isEmpty && !viewModel.isLoading)
            .buttonStyle(.rhymePress)

            // MARK: - Error
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(RhymeAITokens.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.sm, tint: .red.opacity(0.12), fallbackOpacity: 0.08)
            }

            // MARK: - Suggestions
            if !viewModel.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                    Text("Suggestions")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    ForEach(Array(viewModel.suggestions.enumerated()), id: \.offset) { _, suggestion in
                        SuggestionCardView(
                            suggestion: suggestion,
                            highlightRhyme: viewModel.isHighlightEnabled,
                            showProsody: viewModel.isStressPreviewEnabled
                        ) {
                            viewModel.insertSuggestion(suggestion)
                            if !isInline {
                                viewModel.showAssistantSheet = false
                            }
                        }
                    }
                }
            }
        }
    }

    private func featureHelpLabel(
        _ text: String,
        help: FeatureHelp,
        font: Font = .subheadline.weight(.medium),
        color: Color = .secondary
    ) -> some View {
        HStack(spacing: RhymeAITokens.Spacing.xs) {
            Text(text)
                .font(font)
                .foregroundStyle(color)
            helpButton(help)
        }
    }

    private func toggleHelpRow(
        _ text: String,
        help: FeatureHelp,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            featureHelpLabel(text, help: help, font: .subheadline)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.indigo)
                .accessibilityLabel(text)
        }
    }

    private func helpButton(_ help: FeatureHelp) -> some View {
        Button {
            activeHelp = help
        } label: {
            ZStack {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum, alignment: .center)
        }
        .buttonStyle(.rhymePress)
        .contentShape(Rectangle())
        .accessibilityLabel("\(help.title) help")
    }
}

private enum FeatureLegend {
    case syllables
    case rhymes
}

private enum FeatureHelp: String, Identifiable {
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

private struct AssistantProsodyPreviewView: View {
    let text: String
    private var prosody: LineProsody { ProsodyAnalyzer.analyzeLine(text) }

    var body: some View {
        if prosody.syllableCount > 0 {
            VStack(alignment: .leading, spacing: 2) {
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

private struct FeatureHelpSheet: View {
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
    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            Text("Underline colors")
                .font(.subheadline.weight(.semibold))

            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 1), label: "1 syllable")
            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 2), label: "2 syllables")
            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 3), label: "3 syllables")
            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 4), label: "4+ syllables")
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
    private let palette: [Color] = [
        Color(red: 252/255, green: 165/255, blue: 165/255),
        Color(red: 252/255, green: 211/255, blue: 77/255),
        Color(red: 134/255, green: 239/255, blue: 172/255),
        Color(red: 125/255, green: 211/255, blue: 252/255),
        Color(red: 196/255, green: 181/255, blue: 253/255),
        Color(red: 249/255, green: 168/255, blue: 212/255)
    ]

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
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        )
                }
            }
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .white.opacity(0.04), fallbackOpacity: 0.06)
    }
}

#Preview {
    AssistantPanelView()
        .environmentObject(EditorViewModel())
}
