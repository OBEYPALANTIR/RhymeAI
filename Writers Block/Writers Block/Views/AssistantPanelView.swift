import SwiftUI

struct AssistantPanelView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var downloads: GGUFDownloadManager
    @ObservedObject private var inferenceStatus = LocalInferenceStatus.shared
    @State private var readiness = LocalReadiness.current()
    @State private var showModelSetup = false
    @State private var activeHelp: FeatureHelp?
    @State private var rhymeOptionsExpanded = false
    /// When the current suggestion request started writing; the ghost cards
    /// share it so their ink lines move together.
    @State private var writingStartedAt = Date()
    @AppStorage("assistant.targetLineStressExpanded") private var stressDetailExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance
    var isInline: Bool = false
    /// Height the host keeps clear below the panel: the home-indicator inset,
    /// or the keyboard while it is up. The compact sheet ignores the safe
    /// area, so its host has to pass this in; the inline column leaves it 0.
    var bottomInset: CGFloat = 0
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
        VStack(spacing: 0) {
            // A plain title row rather than a navigation bar: the bar added a
            // second band of top chrome under the drag handle.
            HStack {
                Text("Assistant")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()

                if let onDismiss {
                    closeButton(label: "Close Assistant", identifier: "closeAssistantButton", action: onDismiss)
                }
            }
            .padding(.leading, RhymeAITokens.Spacing.md)
            .padding(.trailing, RhymeAITokens.Spacing.xs)
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .overlay(Divider(), alignment: .bottom)

            panelScrollView(rhymeContext: rhymeContext)
        }
        .background {
            AppWritingBackground()
        }
    }

    private func inlineContent(rhymeContext: RhymeContext) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label("Assistant", systemImage: "pencil")
                    .font(.headline)
                Spacer()

                if let onDismiss {
                    closeButton(label: "Hide Assistant", identifier: "hideInlineAssistantButton", action: onDismiss)
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

    private func closeButton(label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appearance.palette.secondaryInk)
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
        }
        .buttonStyle(.rhymePress)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func panelScrollView(rhymeContext: RhymeContext) -> some View {
        ScrollViewReader { scroll in
            // The primary action stays reachable below the scrolling controls.
            // The scroll view ends at the bar rather than running under it, so
            // the last content is never hidden and nothing sits behind the
            // button where a tap or VoiceOver focus could land on it.
            VStack(spacing: 0) {
                ScrollView {
                    panelControls(rhymeContext: rhymeContext)
                        .padding(RhymeAITokens.Spacing.md)
                        .liquidGlassGroup(spacing: RhymeAITokens.Spacing.md)
                }
                .accessibilityIdentifier("assistantScrollView")

                suggestBar
            }
            // Results arrive below the controls, which can be off-screen now
            // that the button no longer sits directly above them.
            .onChange(of: viewModel.suggestions.isEmpty) { _, isEmpty in
                if !isEmpty { revealResults(scroll) }
            }
            .onChange(of: viewModel.errorMessage) { _, error in
                if error != nil { revealResults(scroll) }
            }
        }
    }

    private func revealResults(_ scroll: ScrollViewProxy) {
        withRhymeAnimation(RhymeAITokens.Motion.state, reduceMotion: reduceMotion) {
            scroll.scrollTo(Self.resultsAnchor, anchor: .top)
        }
    }

    private static let resultsAnchor = "assistantResults"
    private static let writingAnnouncement = "Writing suggestions"

    /// The Suggestions section is on screen while any slot is: a line that
    /// arrived, or a ghost still waiting for one.
    private var showsSuggestions: Bool {
        SuggestionInkLineMotion.slotCount(arrived: viewModel.suggestions.count, isLoading: viewModel.isLoading) > 0
    }

    // MARK: - Suggest Button — turns into Stop while streaming
    private var suggestBar: some View {
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
        .padding(.horizontal, RhymeAITokens.Spacing.md)
        .padding(.top, RhymeAITokens.Spacing.sm)
        .padding(.bottom, RhymeAITokens.Spacing.sm + bottomInset)
        .background(appearance.palette.canvas)
        .overlay(Divider(), alignment: .top)
        .rhymeAnimation(RhymeAITokens.Motion.state, value: bottomInset)
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
                        tint: .white.opacity(0.04),
                        interactive: true,
                        fallbackOpacity: 0.06
                    )
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
                                stressDisclosure(for: targetLine)
                            }
                        }
                    } else {
                        Text("New rhyme sound: no earlier line to match")
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

            // MARK: - Results
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
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
            // Three slots open as ghost cards when a request starts. Each
            // arriving line takes the next slot in place, cross-fading out of
            // its ghost; lines past the third append below, and any slot still
            // empty when writing stops leaves on the dismiss tier.
            let arrived = viewModel.suggestions.count
            let placeholderCount = SuggestionInkLineMotion.placeholderCount(
                arrived: arrived,
                isLoading: viewModel.isLoading
            )
            if showsSuggestions {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: RhymeAITokens.Spacing.xs) {
                        Text("Suggestions")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        if viewModel.isLoading {
                            Text("Writing…")
                                .font(.caption)
                                .foregroundStyle(.secondary.opacity(0.8))
                                .accessibilityLabel(Self.writingAnnouncement)
                                .accessibilityIdentifier("suggestionsWriting")
                                .transition(.opacity)
                        }
                    }

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
                        .transition(.opacity)
                    }

                    // Identified by slot, so a ghost stays put while the slots
                    // above it fill and only the one being filled fades.
                    ForEach(arrived..<(arrived + placeholderCount), id: \.self) { slot in
                        SuggestionPlaceholderCardView(
                            slot: slot,
                            showProsody: viewModel.isStressPreviewEnabled,
                            writingStartedAt: writingStartedAt
                        )
                        .transition(.opacity)
                    }
                }
                .rhymeAnimation(RhymeAITokens.Motion.state, value: arrived)
                // Writing starts on the state tier; when it stops, any slot
                // still empty leaves on the dismiss tier.
                .rhymeAnimation(viewModel.isLoading ? RhymeAITokens.Motion.state : RhymeAITokens.Motion.dismiss, value: viewModel.isLoading)
                .transition(.opacity)
            }
            }
            .id(Self.resultsAnchor)
            // The section opens on the state tier and, when a request ends
            // with no lines, fades away on the dismiss tier.
            .rhymeAnimation(viewModel.isLoading ? RhymeAITokens.Motion.state : RhymeAITokens.Motion.dismiss, value: showsSuggestions)
            .onChange(of: viewModel.isLoading) { _, isLoading in
                guard isLoading else { return }
                writingStartedAt = .now
                // A caption inserted into the hierarchy is not read on its own,
                // so tell VoiceOver that writing has started, as the Word
                // Inspector does for its results.
                AccessibilityNotification.Announcement(Self.writingAnnouncement).post()
            }
        }
    }

    /// Stress pattern and IPA are reference detail: collapsed until asked
    /// for, and the choice is remembered.
    @ViewBuilder
    private func stressDisclosure(for targetLine: String) -> some View {
        Button {
            withRhymeAnimation(RhymeAITokens.Motion.state, reduceMotion: reduceMotion) {
                stressDetailExpanded.toggle()
            }
        } label: {
            HStack(spacing: RhymeAITokens.Spacing.xxs) {
                Text(stressDetailExpanded ? "Hide stress pattern" : "Show stress pattern")
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(stressDetailExpanded ? 180 : 0))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(appearance.palette.secondaryInk)
            .frame(minHeight: RhymeAITokens.Touch.minimum)
        }
        .buttonStyle(.rhymePress)
        .accessibilityIdentifier("targetLineStressDisclosure")

        if stressDetailExpanded {
            AssistantProsodyPreviewView(text: targetLine)
                .transition(.opacity)
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

#Preview {
    AssistantPanelView()
        .environmentObject(EditorViewModel())
}
