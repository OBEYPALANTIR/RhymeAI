import SwiftUI

private let providerSectionAnimation = RhymeAITokens.Motion.presentation

struct SettingsView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var ggufDownloadManager: GGUFDownloadManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance

    @State private var editingKeys: [String: String] = [:]
    /// Keys as last read from or written to the Keychain. API keys are the
    /// only settings that wait for Save; everything else applies as it changes.
    @State private var storedKeys: [String: String] = [:]
    @State private var confirmingUnsavedKeys = false
    @State private var showKey = false
    @State private var savedConfirmation = false
    @State private var saveError: String?
    @State private var activeHelp: FeatureHelp?
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if hasUnsavedKeys {
                            confirmingUnsavedKeys = true
                        } else {
                            dismiss()
                        }
                    }
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

    private var providerSection: some View {
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
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl, tint: .indigo.opacity(0.08), fallbackOpacity: 0.06)
    }

    @ViewBuilder
    private var providerSpecificSection: some View {
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
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, tint: .white.opacity(0.04), interactive: true, fallbackOpacity: 0.06)

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
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl, tint: .purple.opacity(0.08), fallbackOpacity: 0.06)
    }

    private var modelSection: some View {
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
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, tint: .white.opacity(0.04), interactive: true, fallbackOpacity: 0.06)

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
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl, tint: .blue.opacity(0.08), fallbackOpacity: 0.06)
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

    private var hasUnsavedKeys: Bool {
        editingKeys != storedKeys
    }

    private func loadSettingsState() {
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

    @discardableResult
    private func saveAll() -> Bool {
        savedConfirmation = false
        saveError = nil
        for provider in AIProvider.allCases {
            if let key = editingKeys[provider.rawValue] {
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
        .environmentObject(AppPersistenceState(persistenceDegraded: false, cloudSyncStatus: .available, usesCloudBackedStore: true))
        .environmentObject(GGUFDownloadManager())
}
