import SwiftUI

struct AssistantPanelView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @State private var activeHelp: FeatureHelp?
    var isInline: Bool = false
    var onDismiss: (() -> Void)?

    var body: some View {
        let rhymeContext = viewModel.computeRhymeContext()

        Group {
            if isInline {
                inlineContent(rhymeContext: rhymeContext)
            } else {
                sheetContent(rhymeContext: rhymeContext)
            }
        }
        .sheet(item: $activeHelp) { help in
            FeatureHelpSheet(help: help)
                .preferredColorScheme(.dark)
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
        .preferredColorScheme(.dark)
    }

    private func inlineContent(rhymeContext: RhymeContext) -> some View {
        VStack(spacing: 0) {
            // Simple header
            HStack {
                Label("Assistant", systemImage: "pencil")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .liquidGlassSurface(cornerRadius: 0, fallbackOpacity: 0.02)
            .overlay(Divider(), alignment: .bottom)

            panelScrollView(rhymeContext: rhymeContext)
        }
        .background(Color(UIColor.systemBackground))
        .preferredColorScheme(.dark)
    }

    private func panelScrollView(rhymeContext: RhymeContext) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                    // MARK: - Context & Theme
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Label("Context & Theme", systemImage: "pencil")
                                .font(.headline)
                            helpButton(.contextTheme)
                        }

                        TextField("What is this song about?", text: $viewModel.theme, axis: .vertical)
                            .lineLimit(3...6)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.useWholeSongContext)
                    }

                    Divider()

                    // MARK: - Target Line
                    VStack(alignment: .leading, spacing: 8) {
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
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.ultraThinMaterial)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }

                        Group {
                            if let targetLine = rhymeContext.targetLine {
                                Text("\"\(targetLine)\"")
                                    .font(.system(.body, design: .serif))
                                    .italic()
                                    .foregroundStyle(.primary.opacity(0.9))
                            } else {
                                Text("New rhyme sound (or place cursor on a line)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary.opacity(0.5))
                                    .italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // MARK: - Rhyme Scheme
                    VStack(alignment: .leading, spacing: 8) {
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
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.characters)
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
                    VStack(alignment: .leading, spacing: 8) {
                        featureHelpLabel("Rhyme Density", help: .rhymeDensity)

                        Picker("Type", selection: $viewModel.rhymeType) {
                            ForEach(RhymeType.allCases, id: \.self) { type in
                                Text(type.shortName).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    // MARK: - Complexity
                    VStack(alignment: .leading, spacing: 8) {
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
                        "Color Rhymes",
                        help: .colorRhymes,
                        isOn: Binding(
                            get: { viewModel.isRhymeHighlightEnabled },
                            set: { viewModel.isRhymeHighlightEnabled = $0 }
                        )
                    )

                    // MARK: - Suggest Button
                    Button {
                        viewModel.getSuggestions()
                    } label: {
                        let isDisabled = viewModel.lyrics.isEmpty || viewModel.isLoading
                        HStack {
                            if viewModel.isLoading {
                                ProgressView()
                                    .tint(.white)
                                Text("Thinking...")
                            } else {
                                Image(systemName: "sparkles")
                                Text("Suggest Next Line")
                            }
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .liquidGlassSurface(
                            cornerRadius: 14,
                            tint: isDisabled ? .gray.opacity(0.2) : .indigo,
                            interactive: !isDisabled,
                            fallbackOpacity: isDisabled ? 0.12 : 0.32
                        )
                    }
                    .disabled(viewModel.lyrics.isEmpty || viewModel.isLoading)

                    // MARK: - Error
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    // MARK: - Suggestions
                    if !viewModel.suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggestions")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

                            ForEach(Array(viewModel.suggestions.enumerated()), id: \.offset) { _, suggestion in
                                SuggestionCardView(
                                    suggestion: suggestion,
                                    highlightRhyme: viewModel.isHighlightEnabled
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
                .padding(20)
            }
        }

    private func featureHelpLabel(
        _ text: String,
        help: FeatureHelp,
        font: Font = .subheadline.weight(.medium),
        color: Color = .secondary
    ) -> some View {
        HStack(spacing: 6) {
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
        }
    }

    private func helpButton(_ help: FeatureHelp) -> some View {
        Button {
            activeHelp = help
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
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

private struct FeatureHelpSheet: View {
    let help: FeatureHelp
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
                .padding(20)
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
    }
}

private struct SyllableLegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Underline colors")
                .font(.subheadline.weight(.semibold))

            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 1), label: "1 syllable")
            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 2), label: "2 syllables")
            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 3), label: "3 syllables")
            SyllableLegendRow(color: SyllableColoredText.syllableColor(for: 4), label: "4+ syllables")
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SyllableLegendRow: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Rhyme colors")
                .font(.subheadline.weight(.semibold))

            Text("Matching colors belong to the same rhyme family. New rhyme families get the next available color.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
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
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    AssistantPanelView()
        .environmentObject(EditorViewModel())
}
