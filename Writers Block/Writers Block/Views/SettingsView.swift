import SwiftUI

private let providerSectionAnimation = RhymeAITokens.Motion.presentation

struct SettingsView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var ggufDownloadManager: GGUFDownloadManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) var appearance

    @State private var editingKeys: [String: String] = [:]
    /// Keys as last read from or written to the Keychain. API keys are the
    /// only settings that wait for Save; everything else applies as it changes.
    @State private var storedKeys: [String: String] = [:]
    @State private var confirmingUnsavedKeys = false
    @State private var showKey = false
    @State var savedConfirmation = false
    @State var saveError: String?
    @State var activeHelp: FeatureHelp?
    @State private var selectedTab: SettingsTab = .general
    #if os(macOS)
    /// The Settings window opens on the tab it last showed, as Mac apps do.
    @AppStorage("macSettingsTab") var macSettingsTab = "general"
    @FocusState private var apiKeyFieldFocused: Bool
    @Environment(\.openSettings) var openSettingsWindow
    #endif

    var body: some View {
        #if os(macOS)
        macBody
        #else
        NavigationStack {
            VStack(spacing: 0) {
                SettingsTabPicker(selection: $selectedTab)
                    .padding(.horizontal, RhymeAITokens.Spacing.lg)
                    .padding(.vertical, RhymeAITokens.Spacing.sm)

                Divider()

                ScrollView {
                    settingsContent
                        .padding(.horizontal, RhymeAITokens.Spacing.lg)
                        .padding(.vertical, RhymeAITokens.Spacing.md)
                }

                Divider()

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settingsSaveError")
                        .padding(.horizontal, RhymeAITokens.Spacing.lg)
                        .padding(.top, RhymeAITokens.Spacing.sm)
                }

                if hasUnsavedKeys {
                    Text("Your API key is not saved yet. Other settings apply as you change them.")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("settingsUnsavedKeyNote")
                        .padding(.horizontal, RhymeAITokens.Spacing.lg)
                        .padding(.top, RhymeAITokens.Spacing.sm)
                }

                SettingsSaveBar(saved: savedConfirmation, hasChanges: hasUnsavedKeys, action: { saveAll() })
                    .padding(.horizontal, RhymeAITokens.Spacing.lg)
                    .padding(.top, RhymeAITokens.Spacing.sm)
                    .padding(.bottom, RhymeAITokens.Spacing.sm)
                    .background(appearance.palette.surface)
            }
            .foregroundStyle(appearance.palette.primaryInk)
            .background {
                AppWritingBackground()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(appearance.palette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(appearance.preferredColorScheme, for: .navigationBar)
            .toolbar {
                // iPadOS draws toolbar buttons on a shared glass capsule, which
                // failed the contrast audit on hardware. Without it, Done is the
                // action colour on the canvas toolbar, the pair used across the app.
                if #available(iOS 26.0, macOS 26.0, *) {
                    ToolbarItem(placement: .cancellationAction) { doneButton }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) { doneButton }
                }
            }
            .confirmationDialog(
                "Save your API key before closing?",
                isPresented: $confirmingUnsavedKeys,
                titleVisibility: .visible
            ) {
                Button("Save") {
                    if saveAll() { dismiss() }
                }
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            } message: {
                Text("The key you typed has not been saved. Your other settings are already applied.")
            }
            // A swipe would otherwise drop a typed key without asking.
            .interactiveDismissDisabled(hasUnsavedKeys)
            .onAppear(perform: loadSettingsState)
            .sheet(item: $activeHelp) { help in
                FeatureHelpSheet(help: help)
            }
            .sheet(item: $viewModel.firstRunRestoreOffer) { offer in
                FirstRunRestoreSheet(offer: offer)
            }
        }
        #endif
    }

    private var doneButton: some View {
        Button {
            if hasUnsavedKeys {
                confirmingUnsavedKeys = true
            } else {
                dismiss()
            }
        } label: {
            Text("Done").foregroundStyle(appearance.palette.action)
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        selectedTabContent
            .rhymeAnimation(RhymeAITokens.Motion.state, value: selectedTab)
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .general:
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.lg) {
                AppearanceSettingsSection()
                providerSection
                providerSpecificSection
                modelSection
                SettingsCloudBackupSection()
            }
            .transition(.opacity)
        case .editor:
            SettingsEditorSection(activeHelp: $activeHelp)
                .transition(.opacity)
        }
    }

    var providerSection: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
            SettingsSectionTitle("AI Provider", systemImage: "sparkles")

            RhymeSegmentedControl(
                options: AIProvider.allCases,
                selection: Binding(
                    get: { viewModel.selectedProvider },
                    set: saveProvider
                ),
                accessibilityIdentifier: "providerPicker",
                label: "AI Provider",
                title: \.displayName
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: SettingsMetrics.groupRadius, tint: .indigo.opacity(0.08), fallbackOpacity: 0.06)
    }

    @ViewBuilder
    var providerSpecificSection: some View {
        if viewModel.selectedProvider == .local {
            SettingsLocalModelSection()
                .transition(.opacity)
        } else {
            apiKeySection
                .transition(.opacity)
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
            SettingsSectionTitle("\(viewModel.selectedProvider.displayName) API Key", systemImage: "key")

            HStack(spacing: RhymeAITokens.Spacing.xs) {
                Group {
                    if showKey {
                        TextField("API Key", text: apiKeyBinding)
                    } else {
                        SecureField("API Key", text: apiKeyBinding)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.plain)
                #if os(macOS)
                // Mac preferences apply as they change: a key saves when the
                // field is committed with Return or loses focus.
                .focused($apiKeyFieldFocused)
                .onSubmit { saveKeysIfChanged() }
                .onChange(of: apiKeyFieldFocused) { _, focused in
                    if !focused { saveKeysIfChanged() }
                }
                #endif

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(appearance.palette.secondaryInk)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel(showKey ? "Hide API key" : "Show API key")
            }
            .padding(.horizontal, RhymeAITokens.Spacing.sm)
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .liquidGlassSurface(cornerRadius: SettingsMetrics.fieldRadius, tint: .white.opacity(0.04), interactive: true, fallbackOpacity: 0.06)

            Text(viewModel.selectedProvider.keyHint)
                .font(.caption)
                .foregroundStyle(appearance.palette.secondaryInk)

            Text(viewModel.cloudAISharingDisclosure)
                .font(.caption)
                .foregroundStyle(appearance.palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "Allow theme, line, and selection sharing",
                isOn: Binding(
                    get: { viewModel.hasCloudAISharingConsent(scope: .selectedContext) },
                    set: { viewModel.setCloudAISharingConsent($0, scope: .selectedContext) }
                )
            )
            .tint(.indigo)
            .accessibilityIdentifier("cloudAISelectedContextConsent")

            Toggle(
                "Allow full lyric sharing",
                isOn: Binding(
                    get: { viewModel.hasCloudAISharingConsent(scope: .wholeSong) },
                    set: { viewModel.setCloudAISharingConsent($0, scope: .wholeSong) }
                )
            )
            .tint(.indigo)
            .accessibilityIdentifier("cloudAIWholeSongConsent")
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: SettingsMetrics.groupRadius, tint: .purple.opacity(0.08), fallbackOpacity: 0.06)
    }

    var modelSection: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
            SettingsSectionTitle("Model", systemImage: "cpu")

            Picker("Model", selection: Binding(
                get: { viewModel.selectedModel },
                set: viewModel.saveModel
            )) {
                ForEach(AIModel.models(for: viewModel.selectedProvider)) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, RhymeAITokens.Spacing.sm)
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .liquidGlassSurface(cornerRadius: SettingsMetrics.fieldRadius, tint: .white.opacity(0.04), interactive: true, fallbackOpacity: 0.06)

            // Cloud model ids are what the provider's docs call the model; the
            // on-device placeholder id ("local-model") means nothing to a writer.
            if viewModel.selectedProvider != .local {
                Text(viewModel.selectedModel.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(appearance.palette.secondaryInk)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: SettingsMetrics.groupRadius, tint: .blue.opacity(0.08), fallbackOpacity: 0.06)
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { editingKeys[viewModel.selectedProvider.rawValue] ?? "" },
            set: { editingKeys[viewModel.selectedProvider.rawValue] = $0 }
        )
    }

    private func saveProvider(_ provider: AIProvider) {
        withRhymeAnimation(providerSectionAnimation, reduceMotion: reduceMotion) {
            viewModel.saveProvider(provider)
        }
    }

    var hasUnsavedKeys: Bool {
        editingKeys != storedKeys
    }

    func loadSettingsState() {
        // The sheet reappears after a help sheet closes; a key being typed
        // must survive that.
        if !hasUnsavedKeys {
            for provider in AIProvider.allCases {
                editingKeys[provider.rawValue] = viewModel.apiKey(for: provider)
            }
            storedKeys = editingKeys
        }
        viewModel.refreshCloudBackupState()
        ggufDownloadManager.refreshInstalledModels()
    }

    /// The Save path, run only when a typed key differs from the Keychain's.
    func saveKeysIfChanged() {
        if hasUnsavedKeys { saveAll() }
    }

    @discardableResult
    func saveAll() -> Bool {
        savedConfirmation = false
        saveError = nil
        for provider in AIProvider.allCases {
            // Only keys the writer changed: an untouched key that read as empty
            // (a Keychain read failure) must not be saved as a removal.
            if let key = editingKeys[provider.rawValue], key != storedKeys[provider.rawValue] {
                guard viewModel.saveApiKey(provider: provider, key: key) else {
                    let action = key.isEmpty ? "remove" : "save"
                    saveError = "Couldn't \(action) the \(provider.displayName) API key in the Keychain. Try again after unlocking the device."
                    return false
                }
                storedKeys[provider.rawValue] = key
            }
        }
        savedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            savedConfirmation = false
        }
        return true
    }
}

#Preview {
    SettingsView()
        .environmentObject(EditorViewModel())
        .environmentObject(AppPersistenceState(persistenceDegraded: false, cloudSyncStatus: .on, usesCloudBackedStore: true))
        .environmentObject(GGUFDownloadManager())
}
