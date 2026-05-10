import SwiftUI

struct AssistantPanelView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    var isInline: Bool = false
    var onDismiss: (() -> Void)?

    var body: some View {
        let rhymeContext = viewModel.computeRhymeContext()

        if isInline {
            inlineContent(rhymeContext: rhymeContext)
        } else {
            sheetContent(rhymeContext: rhymeContext)
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
                        Label("Context & Theme", systemImage: "pencil")
                            .font(.headline)

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
                            Text("Rhyme Scheme")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)

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
                        Text("Rhyme Density")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

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
                            Text("Complexity")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
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
                    Toggle("Whole Song Context", isOn: $viewModel.useWholeSongContext)
                        .font(.subheadline)
                        .tint(.indigo)

                    Toggle("Highlight Rhymes", isOn: $viewModel.isHighlightEnabled)
                        .font(.subheadline)
                        .tint(.indigo)

                    Toggle("Color Syllables", isOn: Binding(
                        get: { viewModel.isSyllableColoringEnabled },
                        set: { newValue in
                            viewModel.isSyllableColoringEnabled = newValue
                            if newValue { viewModel.isRhymeHighlightEnabled = false }
                        }
                    ))
                    .font(.subheadline)
                    .tint(.indigo)

                    Toggle("Color Rhymes", isOn: Binding(
                        get: { viewModel.isRhymeHighlightEnabled },
                        set: { newValue in
                            viewModel.isRhymeHighlightEnabled = newValue
                            if newValue { viewModel.isSyllableColoringEnabled = false }
                        }
                    ))
                    .font(.subheadline)
                    .tint(.indigo)

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
    }

#Preview {
    AssistantPanelView()
        .environmentObject(EditorViewModel())
}
