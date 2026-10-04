import SwiftUI

struct AssistantPanelView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var downloads: GGUFDownloadManager
    @ObservedObject private var inferenceStatus = LocalInferenceStatus.shared
    @State private var readiness = LocalReadiness.current()
    @State private var showModelSetup = false
    @State private var activeHelp: FeatureHelp?
    @State private var rhymeOptionsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance
    var isInline: Bool = false
    var onDismiss: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        let rhymeContext = viewModel.rhymeContext

        Group {
            if isInline {
                inlineContent(rhymeContext: rhymeContext)
            } else {
                sheetContent(rhymeContext: rhymeContext)
            }
        }
        .foregroundStyle(appearance.palette.primaryInk)
        .onAppear {
            viewModel.positionSeededProsodyCursorForUITests()
        }
        .task {
            while !Task.isCancelled {
                readiness = LocalReadiness.current()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(isPresented: $showModelSetup) {
            SettingsView()
        }
        .sheet(item: $activeHelp) { help in
            FeatureHelpSheet(help: help)
        }
    }

    private var suggestionDisabled: Bool {
        !viewModel.isLoading && (viewModel.lyrics.isEmpty || (viewModel.selectedProvider == .local && !readiness.canGenerate))
    }

    private var localStatusTitle: String {
        if inferenceStatus.loadingCount > 0 { return "Loading model" }
        if viewModel.isLoading { return "Writing locally" }
        if viewModel.errorMessage != nil { return "Try again" }
        if downloads.activeDownloadID != nil && !readiness.canGenerate { return "Downloading model" }
        return readiness.title
    }

    private func sheetContent(rhymeContext: RhymeContext) -> some View {
        NavigationStack {
            panelScrollView(rhymeContext: rhymeContext)
                .background {
                    AppWritingBackground()
                }
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
            HStack {
                Label("Assistant", systemImage: "pencil")
                    .font(.headline)
                Spacer()

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                    }
                    .buttonStyle(.rhymePress)
                    .accessibilityLabel("Hide Assistant")
                    .accessibilityIdentifier("hideInlineAssistantButton")
                }
            }
            .padding(.leading, RhymeAITokens.Spacing.md)
            .padding(.trailing, RhymeAITokens.Spacing.xs)
            .frame(minHeight: RhymeAITokens.Touch.comfortable)
            .liquidGlassSurface(cornerRadius: 0, fallbackOpacity: 0.02)
            .overlay(Divider(), alignment: .bottom)

            panelScrollView(rhymeContext: rhymeContext)
        }
        .background {
            AppWritingBackground()
        }
    }

    private func panelScrollView(rhymeContext: RhymeContext) -> some View {
        ScrollView {
            panelControls(rhymeContext: rhymeContext)
                .padding(RhymeAITokens.Spacing.md)
                .liquidGlassGroup(spacing: RhymeAITokens.Spacing.md)
        }
        .accessibilityIdentifier("assistantScrollView")
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
                            .padding(.vertical, RhymeAITokens.Spacing.xxs)
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

            // MARK: - Rhyme Options
            // Scheme, density, and complexity live behind one disclosure so the
            // panel leads with the writing flow; the header summary keeps the
            // current tuning visible while collapsed.
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
                Button {
                    withRhymeAnimation(RhymeAITokens.Motion.settle, reduceMotion: reduceMotion) {
                        rhymeOptionsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: RhymeAITokens.Spacing.sm) {
                        Text("Rhyme Options")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(viewModel.rhymeScheme.label) \u{00b7} \(viewModel.rhymeType.shortName) \u{00b7} \(viewModel.rhymeComplexity.label)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(appearance.palette.action)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(rhymeOptionsExpanded ? 180 : 0))
                    }
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel(rhymeOptionsExpanded ? "Collapse rhyme options" : "Expand rhyme options")

                if rhymeOptionsExpanded {
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
                        .tint(appearance.palette.action)
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
                            .foregroundStyle(appearance.palette.action)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(viewModel.rhymeComplexity.rawValue) },
                            set: { viewModel.rhymeComplexity = RhymeComplexity(rawValue: Int($0)) ?? .moderate }
                        ),
                        in: 0...2,
                        step: 1
                    )
                    .tint(appearance.palette.action)

                    Text(viewModel.rhymeComplexity.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                }

                // Visual stanza display stays visible: it is feedback on the
                // lyrics, not a tuning control.
                if !viewModel.lyrics.isEmpty {
                    RhymeSchemeDisplayView(
                        rhymeContext: rhymeContext,
                        activeScheme: viewModel.activeRhymeScheme
                    )
                }
            }

            // Beat Grid tempo controls remain in the panel (not Settings) so the
            // user can adjust tempo while editing without leaving the assistant.
            // Visible only when Beat Grid is enabled (controlled in Settings).
            if viewModel.isBeatGridEnabled {
                BeatGridTempoControl(bpm: $viewModel.beatGridBpm)

                if !viewModel.lyrics.isEmpty {
                    BeatGridPreviewView(lyrics: viewModel.lyrics, bpm: viewModel.beatGridBpm)
                }
            }

            if viewModel.selectedProvider == .local {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                    Label(localStatusTitle, systemImage: "desktopcomputer")
                        .font(.subheadline.weight(.semibold))
                    Text(readiness.detail).font(.caption).foregroundStyle(.secondary)
                    // Bordered like the panel's other secondary actions: as plain
                    // text in the ink-coloured tint it read as a caption.
                    Button("Local model setup") { showModelSetup = true }
                        .buttonStyle(.bordered)
                        .tint(appearance.palette.action)
                        .frame(minHeight: RhymeAITokens.Touch.minimum)
                }
                .accessibilityIdentifier("localAIReadiness")
            }

            // MARK: - Suggest Button — turns into Stop while streaming
            Button {
                if viewModel.isLoading {
                    viewModel.cancelSuggestions()
                } else {
                    viewModel.getSuggestions()
                }
            } label: {
                let isDisabled = suggestionDisabled
                HStack {
                    if viewModel.isLoading {
                        ProgressView()
                            .tint(appearance.palette.onAction)
                        Text("Stop")
                    } else {
                        Image(systemName: "sparkles")
                        Text("Suggest Next Line")
                    }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(appearance.palette.onAction)
                .frame(maxWidth: .infinity)
                .padding(.vertical, RhymeAITokens.Spacing.sm)
                .frame(minHeight: RhymeAITokens.Touch.minimum)
                .appearanceActionSurface(cornerRadius: RhymeAITokens.Radius.md)
                .opacity(isDisabled ? 0.45 : 1)
            }
            .disabled(suggestionDisabled)
            .buttonStyle(.rhymePress)

            // MARK: - Error
            if let error = viewModel.errorMessage {
                let recoveryAction = AIErrorRecoveryAction(errorMessage: error)
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(appearance.palette.error)

                    Button(recoveryAction == .openSettings ? "Open Settings" : "Retry") {
                        switch recoveryAction {
                        case .openSettings:
                            if let onOpenSettings {
                                onOpenSettings()
                            } else {
                                viewModel.showSettingsSheet = true
                            }
                        case .retry:
                            viewModel.getSuggestions()
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(recoveryAction == .openSettings ? appearance.palette.action : appearance.palette.error)
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
                }
                .padding(RhymeAITokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassSurface(
                    cornerRadius: RhymeAITokens.Radius.sm,
                    tint: appearance.palette.error,
                    fallbackOpacity: 0.08
                )
            }

            // MARK: - Suggestions
            if !viewModel.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                    Text("Suggestions")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text("AI-generated · review before use")
                        .font(.caption.italic())
                        .foregroundStyle(.secondary.opacity(0.8))

                    ForEach(viewModel.suggestions) { suggestion in
                        SuggestionCardView(
                            suggestion: suggestion.text,
                            rhymeTier: suggestion.tier,
                            isHookRepeat: suggestion.isHookRepeat,
                            highlightRhyme: viewModel.isHighlightEnabled,
                            showProsody: viewModel.isStressPreviewEnabled,
                            onUse: {
                                viewModel.insertSuggestion(suggestion.text)
                                if !isInline { viewModel.showAssistantSheet = false }
                            },
                            onKeep: { viewModel.keepAlternate(suggestion.text) },
                            isKept: viewModel.companion.alternates.contains(where: { $0.text == suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines) })
                        )
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
                .tint(appearance.palette.action)
                .accessibilityLabel(text)
        }
    }

    private func helpButton(_ help: FeatureHelp) -> some View {
        Button {
            activeHelp = help
        } label: {
            ZStack {
                Image(systemName: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum, alignment: .center)
        }
        .buttonStyle(.rhymePress)
        .contentShape(Rectangle())
        .accessibilityLabel("\(help.title) help")
    }
}

private struct SuggestionSkeletonRow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: RhymeAITokens.Radius.lg, style: .continuous)
            .fill(Color.secondary.opacity(0.18))
            .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
            .opacity(0.6)
            .accessibilityHidden(true)
    }
}

#Preview {
    AssistantPanelView()
        .environmentObject(EditorViewModel())
}
