import Foundation
import SwiftUI
import UniformTypeIdentifiers

private let providerSectionAnimation = RhymeAITokens.Motion.presentation

private enum CloudBackupAction {
    case backup
    case restore
}

struct SettingsView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var persistenceState: AppPersistenceState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance

    @State private var editingKeys: [String: String] = [:]
    @State private var showKey: Bool = false
    @State private var savedConfirmation: Bool = false
    @State private var saveError: String?
    @State private var installedModelFiles: Set<String> = []
    @State private var activeDownloadID: String?
    @State private var downloadMessage: String?
    @State private var downloadError: String?
    @State private var downloadTask: Task<Void, Never>?
    @State private var ggufEngineChoice: GGUFEngineChoice = GGUFEngineChoice.current
    @State private var selectedGGUFFileName: String? = GGUFModelSelection.currentFileName
    @State private var customModels: [GGUFCustomModel] = GGUFCustomModelRegistry.models()
    @State private var customModelImporterPresented = false
    @State private var activeHelp: FeatureHelp?
    @State private var cloudBackupPassphraseEntry: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                settingsBackground

                ScrollView {
                    settingsContent
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 34)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                loadSettingsState()
            }
            .onDisappear {
                downloadTask?.cancel()
                cloudBackupPassphraseEntry = ""
            }
            .sheet(item: $activeHelp) { help in
                FeatureHelpSheet(help: help)
            }
            .fileImporter(
                isPresented: $customModelImporterPresented,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false,
                onCompletion: importCustomModel
            )
        }
        .environment(\.colorScheme, appearance.preferredColorScheme)
        .preferredColorScheme(appearance.preferredColorScheme)
    }

    private var settingsBackground: some View {
        AppWritingBackground()
    }

    private var settingsContent: some View {
        contentStack
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppearanceSettingsSection()

            AnalysisStyleSettingsSection()

            providerSection

            providerSpecificSection

            modelSection

            editorSection

            cloudBackupSection

            saveSection
        }
        .rhymeAnimation(providerSectionAnimation, value: viewModel.selectedProvider)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionTitle("AI Provider", systemImage: "sparkles")

            Picker("AI Provider", selection: Binding(
                get: { viewModel.selectedProvider },
                set: { provider in
                    withRhymeAnimation(providerSectionAnimation, reduceMotion: reduceMotion) {
                        viewModel.saveProvider(provider)
                    }
                }
            )) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 22)
    }

    @ViewBuilder
    private var providerSpecificSection: some View {
        if viewModel.selectedProvider == .local {
            localModelSection
                .transition(.opacity)
        } else {
            apiKeySection
                .transition(.opacity)
        }
    }

    private var localModelSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if GGUFModelService.isEngineAvailable {
                customModelSelector
            }

            localStatusRow

            if GGUFModelService.isEngineAvailable {
                // Engine picker: only shown when at least one GGUF is installed.
                if GGUFModelSelection.resolvedModelURL() != nil {
                    enginePickerRow
                }

                SettingsSectionTitle("Recommended Gemma Downloads", systemImage: "arrow.down.circle")

                ForEach(GGUFModelCatalog.models) { option in
                    gemmaDownloadRow(option)
                }

                if let downloadMessage {
                    Label(downloadMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.success)
                        .accessibilityIdentifier("gemmaDownloadMessage")
                }

                if let downloadError {
                    Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.error)
                        .accessibilityIdentifier("gemmaDownloadError")
                }

                Text(GGUFModelSelection.resolvedModelURL() == nil
                     ? "Download a Gemma model to enable on-device inference without Apple Intelligence. Files are stored in the app sandbox."
                     : "Gemma uses the downloaded GGUF model directly via llama.cpp. Apple Intelligence is the fallback when no GGUF is present."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Gemma downloads and the GGUF engine are unavailable in this build. Apple Intelligence remains the on-device local option.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("gemmaUnavailableMessage")
            }
        }
    }

    private var enginePickerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("On-Device Engine", systemImage: "cpu")

            Picker("On-device engine", selection: Binding(
                get: { ggufEngineChoice },
                set: { choice in
                    ggufEngineChoice = choice
                    choice.save()
                    if choice == .appleIntelligence {
                        Task { await AIService.unloadGGUFRunner() }
                    }
                }
            )) {
                ForEach(GGUFEngineChoice.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("ggufEnginePicker")
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 22)
    }

    private var localStatusRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(appearance.palette.action)
                .frame(width: 42, height: 42)
                .liquidGlassSurface(cornerRadius: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Foundation Models")
                    .font(.headline)

                Text("Runs suggestions on-device when Apple Intelligence is available. No API key is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 22)
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionTitle("\(viewModel.selectedProvider.displayName) API Key", systemImage: "key")

            HStack(spacing: 12) {
                Group {
                    if showKey {
                        TextField(
                            "",
                            text: apiKeyBinding,
                            prompt: Text("API Key")
                                .foregroundStyle(appearance.palette.placeholder)
                        )
                    } else {
                        SecureField(
                            "",
                            text: apiKeyBinding,
                            prompt: Text("API Key")
                                .foregroundStyle(appearance.palette.placeholder)
                        )
                    }
                }
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(appearance.palette.primaryInk)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.plain)

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel(showKey ? "Hide API key" : "Show API key")
            }
            .padding(14)
            .liquidGlassSurface(cornerRadius: 16, interactive: true)

            Text(viewModel.selectedProvider.keyHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.selectedProvider != .local {
                Text(viewModel.cloudAISharingDisclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 22)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionTitle("Model", systemImage: "cpu")

            Picker("Model", selection: Binding(
                get: { viewModel.selectedModel },
                set: { viewModel.saveModel($0) }
            )) {
                ForEach(AIModel.models(for: viewModel.selectedProvider)) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .liquidGlassSurface(cornerRadius: 16, interactive: true)

            Text(viewModel.selectedModel.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 22)
    }

    private var cloudSyncStatusRow: some View {
        Label(cloudSyncStatusText, systemImage: cloudSyncStatusIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("iCloudSyncStatus")
    }

    private var cloudSyncStatusText: String {
        switch persistenceState.cloudSyncStatus {
        case .syncing:
            return "iCloud sync: Checking…"
        case .available:
            return "iCloud sync: On"
        case .localOnly, .accountUnavailable:
            return "iCloud sync: Off — sign in to iCloud in system Settings to sync across devices."
        }
    }

    private var cloudSyncStatusIcon: String {
        switch persistenceState.cloudSyncStatus {
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .available:
            return "checkmark.icloud.fill"
        case .localOnly, .accountUnavailable:
            return "icloud.slash"
        }
    }

    private var cloudBackupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionTitle("Cloud Backup", systemImage: "externaldrive.badge.icloud")

            cloudSyncStatusRow

            Text("Backs up projects, trash, and voice recordings to your Google Drive app data. Cloud-provider API keys are stored in the Keychain and excluded from these backups; they are sent only to the selected provider to authenticate AI requests.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(
                viewModel.cloudBackupHasStoredPassphrase ? "Stored passphrase ready" : "Backup passphrase",
                text: $cloudBackupPassphraseEntry
            )
            .textContentType(.password)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(.body, design: .rounded))
            .padding(14)
            .liquidGlassSurface(cornerRadius: 16, interactive: true)
            .accessibilityIdentifier("cloudBackupPassphrase")

            HStack(spacing: 10) {
                Button {
                    runCloudBackupAction(.backup)
                } label: {
                    Label("Back Up Now", systemImage: "arrow.up.doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.rhymePress)

                Button {
                    runCloudBackupAction(.restore)
                } label: {
                    Label("Restore", systemImage: "arrow.down.doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.rhymePress)
            }
            .font(.subheadline.weight(.semibold))
            .disabled(!cloudBackupControlsEnabled)

            Label(viewModel.cloudBackupStatusText, systemImage: cloudBackupStatusIcon)
                .font(.caption)
                .foregroundStyle(cloudBackupStatusColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cloudBackupStatus")

            Text("Background backup runs only after you set up Google Drive and save a passphrase here. It will never open Google sign-in from the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your songs and recordings are also included in your device's iCloud backup and synced across your iCloud devices. Only the optional Google Drive backup is encrypted with your passphrase. Cloud-provider API keys remain in the Keychain, are excluded from Google Drive backups, and are sent to the selected provider only to authenticate AI requests.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 22)
    }

    private var cloudBackupControlsEnabled: Bool {
        viewModel.cloudBackupConfigured
            && !viewModel.cloudBackupIsWorking
            && (viewModel.cloudBackupHasStoredPassphrase || !cloudBackupPassphraseEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var cloudBackupStatusIcon: String {
        if viewModel.cloudBackupIsWorking {
            return "arrow.triangle.2.circlepath"
        }
        return viewModel.cloudBackupLastResultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var cloudBackupStatusColor: Color {
        if viewModel.cloudBackupIsWorking {
            return .secondary
        }
        return viewModel.cloudBackupLastResultIsError ? appearance.palette.error : appearance.palette.success
    }

    private func runCloudBackupAction(_ action: CloudBackupAction) {
        let passphrase = cloudBackupPassphraseEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        if !passphrase.isEmpty {
            viewModel.updateCloudBackupPassphrase(passphrase)
        }

        Task { @MainActor in
            switch action {
            case .backup:
                await viewModel.backUpNow()
            case .restore:
                await viewModel.restoreBackupNow()
            }
            if !passphrase.isEmpty {
                cloudBackupPassphraseEntry = ""
            }
        }
    }


    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                saveAll()
            } label: {
                HStack {
                    Spacer()
                    Label(
                        savedConfirmation ? "Saved" : "Save Settings",
                        systemImage: savedConfirmation ? "checkmark.circle.fill" : "checkmark"
                    )
                    .font(.headline)
                    .foregroundStyle(savedConfirmation ? appearance.palette.success : appearance.palette.primaryInk)
                    Spacer()
                }
                .padding(.vertical, 15)
                .padding(.horizontal, 16)
                .liquidGlassSurface(
                    cornerRadius: 18,
                    tint: savedConfirmation ? appearance.palette.success : nil,
                    interactive: true,
                    fallbackOpacity: 0.08
                )
            }
            .buttonStyle(.rhymePress)
            .disabled(savedConfirmation)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(appearance.palette.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settingsSaveError")
            }
        }
    }

    private func gemmaDownloadRow(_ option: GGUFModelDescriptor) -> some View {
        let isDownloaded = installedModelFiles.contains(option.fileName)
        let isDownloading = activeDownloadID == option.id
        let isSelected = selectedGGUFFileName == option.fileName
        let hasEnoughMemory = ProcessInfo.processInfo.physicalMemory >= option.minimumPhysicalMemoryBytes

        return Button {
            if isDownloaded {
                selectGGUFModel(option)
            } else {
                startGemmaDownload(option)
            }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isDownloaded ? appearance.palette.success : appearance.palette.action)
                    .frame(width: 36, height: 36)
                    .liquidGlassSurface(cornerRadius: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("\(option.subtitle) - \(option.size)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text(isSelected ? "Selected" : (isDownloaded ? "Select" : (isDownloading ? "Downloading" : "Download")))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDownloaded ? appearance.palette.success : appearance.palette.primaryInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .liquidGlassSurface(cornerRadius: 14)
            }
            .padding(14)
            .liquidGlassSurface(cornerRadius: 18, interactive: !isDownloaded)
        }
        .buttonStyle(.rhymePress)
        .disabled(activeDownloadID != nil || !hasEnoughMemory)
        .accessibilityIdentifier("gemmaDownload.\(option.id)")
    }

    private var customModelSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionTitle("Custom Models", systemImage: "externaldrive")

            ForEach(customModels) { model in
                Button {
                    selectCustomGGUFModel(model)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedGGUFFileName == model.fileName
                              ? "checkmark.circle.fill"
                              : "externaldrive.fill")
                            .foregroundStyle(appearance.palette.action)
                        Text(model.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(selectedGGUFFileName == model.fileName ? "Selected" : "Select")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(appearance.palette.secondaryInk)
                    }
                    .padding(14)
                    .liquidGlassSurface(cornerRadius: 18, interactive: true)
                }
                .buttonStyle(.rhymePress)
                .disabled(activeDownloadID != nil)
                .accessibilityIdentifier("customGGUF.\(model.id)")
            }

            Button {
                customModelImporterPresented = true
            } label: {
                Label("Import Custom GGUF", systemImage: "folder.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
                    .liquidGlassSurface(cornerRadius: 18, interactive: true)
            }
            .buttonStyle(.rhymePress)
            .disabled(activeDownloadID != nil)
            .accessibilityIdentifier("importCustomGGUF")
        }
    }

    // MARK: - Editor Section

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionTitle("Editor", systemImage: "textformat")

            settingsToggleRow(
                "Whole Song Context",
                help: .wholeSongContext,
                isOn: Binding(
                    get: { viewModel.useWholeSongContext },
                    set: { viewModel.saveUseWholeSongContext($0) }
                )
            )

            settingsToggleRow(
                "Highlight Rhymes",
                help: .highlightRhymes,
                isOn: Binding(
                    get: { viewModel.isHighlightEnabled },
                    set: { viewModel.saveIsHighlightEnabled($0) }
                )
            )

            settingsToggleRow(
                "Syllable Guide",
                help: .underlineSyllables,
                isOn: Binding(
                    get: { viewModel.isSyllableColoringEnabled },
                    set: { viewModel.saveIsSyllableColoringEnabled($0) }
                )
            )

            settingsToggleRow(
                "Stress + IPA",
                help: .stressIPA,
                isOn: Binding(
                    get: { viewModel.isStressPreviewEnabled },
                    set: { viewModel.saveIsStressPreviewEnabled($0) }
                )
            )

            settingsToggleRow(
                "Rhyme Families",
                help: .colorRhymes,
                isOn: Binding(
                    get: { viewModel.isRhymeHighlightEnabled },
                    set: { viewModel.saveIsRhymeHighlightEnabled($0) }
                )
            )

            settingsToggleRow(
                "Beat Grid",
                help: .beatGrid,
                isOn: Binding(
                    get: { viewModel.isBeatGridEnabled },
                    set: { viewModel.saveIsBeatGridEnabled($0) }
                )
            )
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 22)
    }

    // Replicates AssistantPanelView's toggleHelpRow pattern with the persisting
    // save functions, keeping FeatureHelp affordances alongside each toggle.
    private func settingsToggleRow(
        _ text: String,
        help: FeatureHelp,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            HStack(spacing: RhymeAITokens.Spacing.xs) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                settingsHelpButton(help)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(appearance.palette.action)
                .accessibilityLabel(text)
        }
    }

    private func settingsHelpButton(_ help: FeatureHelp) -> some View {
        Button {
            activeHelp = help
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum, alignment: .center)
        }
        .buttonStyle(.rhymePress)
        .contentShape(Rectangle())
        .accessibilityLabel("\(help.title) help")
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { editingKeys[viewModel.selectedProvider.rawValue] ?? "" },
            set: { editingKeys[viewModel.selectedProvider.rawValue] = $0 }
        )
    }

    private func loadSettingsState() {
        for provider in AIProvider.allCases {
            editingKeys[provider.rawValue] = viewModel.apiKey(for: provider)
        }
        ggufEngineChoice = GGUFEngineChoice.current
        cloudBackupPassphraseEntry = ""
        viewModel.refreshCloudBackupState()
        refreshInstalledModels()
    }

    private func saveAll() {
        saveError = nil
        for provider in AIProvider.allCases {
            if let key = editingKeys[provider.rawValue] {
                guard viewModel.saveApiKey(provider: provider, key: key) else {
                    let action = key.isEmpty ? "remove" : "save"
                    saveError = "Couldn't \(action) the \(provider.displayName) API key in the Keychain. Try again after unlocking the device."
                    return
                }
            }
        }
        savedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            savedConfirmation = false
        }
    }

    private func selectGGUFModel(_ option: GGUFModelDescriptor) {
        guard activeDownloadID == nil else { return }
        downloadTask = Task {
            await MainActor.run {
                activeDownloadID = option.id
                downloadMessage = "Verifying \(option.title)..."
                downloadError = nil
            }
            do {
                let modelURL = try Self.modelsDirectory().appendingPathComponent(option.fileName)
                try await Task.detached(priority: .userInitiated) {
                    try GGUFModelCatalog.validateFile(at: modelURL, against: option)
                }.value
                await MainActor.run { activateGGUFModel(option, message: "\(option.title) selected.") }
            } catch {
                await MainActor.run {
                    activeDownloadID = nil
                    downloadMessage = nil
                    downloadError = "Could not select \(option.title): \(error.localizedDescription)"
                }
            }
        }
    }

    private func selectCustomGGUFModel(_ model: GGUFCustomModel) {
        guard activeDownloadID == nil else { return }
        do {
            let modelURL = try Self.modelsDirectory().appendingPathComponent(model.fileName)
            try GGUFModelCatalog.validateCustomFile(at: modelURL)
            activateCustomGGUFModel(model, message: "\(model.displayName) selected.")
        } catch {
            downloadMessage = nil
            downloadError = "Could not select \(model.displayName): \(error.localizedDescription)"
        }
    }

    private func importCustomModel(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let sourceURL = urls.first else {
            if case .failure(let error) = result {
                downloadError = "Could not open the model: \(error.localizedDescription)"
            }
            return
        }
        guard activeDownloadID == nil else { return }
        downloadTask?.cancel()
        downloadTask = Task {
            activeDownloadID = "custom-import"
            downloadMessage = "Importing \(sourceURL.lastPathComponent)..."
            downloadError = nil
            do {
                let model = try await Task.detached(priority: .userInitiated) {
                    let accessed = sourceURL.startAccessingSecurityScopedResource()
                    defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
                    try GGUFModelCatalog.validateCustomFile(at: sourceURL)
                    let directory = try GGUFModelCatalog.modelsDirectory(create: true)
                    let fileName = "custom-\(UUID().uuidString).gguf"
                    let destination = directory.appendingPathComponent(fileName)
                    let stagingURL = directory.appendingPathComponent("\(fileName).import")
                    var importCompleted = false
                    defer {
                        if !importCompleted {
                            try? FileManager.default.removeItem(at: stagingURL)
                            try? FileManager.default.removeItem(at: destination)
                        }
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
                    try GGUFModelCatalog.validateCustomFile(at: stagingURL)
                    try FileManager.default.moveItem(at: stagingURL, to: destination)
                    importCompleted = true
                    let displayName = sourceURL.deletingPathExtension().lastPathComponent
                    return GGUFCustomModel(
                        id: fileName,
                        displayName: displayName.isEmpty ? "Custom Model" : displayName,
                        fileName: fileName
                    )
                }.value
                GGUFCustomModelRegistry.register(model)
                customModels = GGUFCustomModelRegistry.models()
                activateCustomGGUFModel(model, message: "\(model.displayName) imported and selected.")
            } catch is CancellationError {
                activeDownloadID = nil
                downloadMessage = nil
            } catch {
                activeDownloadID = nil
                downloadMessage = nil
                downloadError = "Could not import this model: \(error.localizedDescription)"
            }
        }
    }

    private func startGemmaDownload(_ option: GGUFModelDescriptor) {
        guard activeDownloadID == nil else { return }
        downloadTask?.cancel()
        downloadTask = Task {
            await MainActor.run {
                activeDownloadID = option.id
                downloadMessage = "Downloading \(option.title)..."
                downloadError = nil
            }

            do {
                let directory = try Self.modelsDirectory()
                let destination = directory.appendingPathComponent(option.fileName)
                let stagingURL = directory.appendingPathComponent("\(option.fileName).download")
                try Self.ensureDeviceSuitability(for: option, directory: directory)

                if FileManager.default.fileExists(atPath: destination.path) {
                    try await Task.detached(priority: .userInitiated) {
                        try GGUFModelCatalog.validateFile(at: destination, against: option)
                    }.value
                    await MainActor.run { activateGGUFModel(option, message: "\(option.title) selected.") }
                    return
                }

                try? FileManager.default.removeItem(at: stagingURL)
                try await BoundedFileDownloader.download(
                    from: option.url,
                    to: stagingURL,
                    expectedBytes: option.expectedBytes
                )
                try await Task.detached(priority: .userInitiated) {
                    try GGUFModelCatalog.validateFile(at: stagingURL, against: option)
                }.value

                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: stagingURL, to: destination)

                await MainActor.run { activateGGUFModel(option, message: "\(option.title) downloaded and selected.") }
            } catch is CancellationError {
                await MainActor.run {
                    activeDownloadID = nil
                    downloadMessage = nil
                }
            } catch {
                await MainActor.run {
                    activeDownloadID = nil
                    downloadMessage = nil
                    downloadError = "Failed to download \(option.title): \(error.localizedDescription)"
                }
            }
        }
    }

    private func activateGGUFModel(_ option: GGUFModelDescriptor, message: String) {
        viewModel.saveProvider(.local)
        viewModel.saveModel(.localModel)
        GGUFModelSelection.save(fileName: option.fileName)
        selectedGGUFFileName = option.fileName
        GGUFEngineChoice.gemma.save()
        ggufEngineChoice = .gemma
        installedModelFiles.insert(option.fileName)
        activeDownloadID = nil
        downloadMessage = message
    }

    private func activateCustomGGUFModel(_ model: GGUFCustomModel, message: String) {
        viewModel.saveProvider(.local)
        viewModel.saveModel(.localModel)
        GGUFModelSelection.save(fileName: model.fileName)
        selectedGGUFFileName = model.fileName
        GGUFEngineChoice.gemma.save()
        ggufEngineChoice = .gemma
        activeDownloadID = nil
        downloadMessage = message
    }

    private func refreshInstalledModels() {
        guard let directory = try? Self.modelsDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              ) else {
            installedModelFiles = []
            return
        }
        installedModelFiles = Set(contents.map(\.lastPathComponent).filter {
            GGUFModelCatalog.descriptor(fileName: $0) != nil
        })
        customModels = GGUFCustomModelRegistry.models().filter { model in
            contents.contains { $0.lastPathComponent == model.fileName }
        }
        GGUFCustomModelRegistry.save(customModels)
        selectedGGUFFileName = GGUFModelSelection.resolvedModelURL()?.lastPathComponent
    }

    private static func modelsDirectory() throws -> URL {
        try GGUFModelCatalog.modelsDirectory(create: true)
    }

    private static func ensureDeviceSuitability(for option: GGUFModelDescriptor, directory: URL) throws {
        guard ProcessInfo.processInfo.physicalMemory >= option.minimumPhysicalMemoryBytes else {
            throw DownloadValidationError.insufficientMemory
        }
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < option.expectedBytes + 1_000_000_000 {
            throw DownloadValidationError.insufficientStorage
        }
    }
}

private enum DownloadValidationError: LocalizedError {
    case incomplete(expected: Int64, actual: Int64)
    case oversized
    case insufficientMemory
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case let .incomplete(expected, actual):
            return "download was incomplete: \(Self.format(actual)) of \(Self.format(expected))"
        case .oversized:
            return "the download exceeded the approved model size"
        case .insufficientMemory:
            return "this device does not have enough memory for that model"
        case .insufficientStorage:
            return "at least 1 GB of free space beyond the model size is required"
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Fetches the model over several concurrent ranged connections, writing each
/// span straight to its offset in a preallocated file. All delegate callbacks
/// land on a serial queue, so the per-segment bookkeeping needs no extra locking;
/// only the handful of fields touched from `cancel()` are lock-guarded.
private final class BoundedFileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct SegmentWriter {
        let segment: GGUFDownloadSegment
        let handle: FileHandle
        var written: Int64 = 0
    }

    private let destination: URL
    private let expectedBytes: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var tasks: [URLSessionTask] = []
    private var writers: [Int: SegmentWriter] = [:]
    private var liveTaskCount = 0
    private var terminalError: Error?

    private init(destination: URL, expectedBytes: Int64) {
        self.destination = destination
        self.expectedBytes = expectedBytes
    }

    static func download(from url: URL, to destination: URL, expectedBytes: Int64) async throws {
        let downloader = BoundedFileDownloader(destination: destination, expectedBytes: expectedBytes)
        try await withTaskCancellationHandler {
            try await downloader.start(url: url)
        } onCancel: {
            downloader.cancel()
        }
    }

    private func start(url: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let segments = GGUFDownloadPlan.segments(totalBytes: expectedBytes)
        // Preallocate so each segment can seek straight to its own offset.
        let preallocation = try FileHandle(forWritingTo: destination)
        try preallocation.truncate(atOffset: UInt64(expectedBytes))
        try preallocation.close()

        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpMaximumConnectionsPerHost = GGUFDownloadPlan.segmentCount
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session

            do {
                for segment in segments {
                    var request = URLRequest(url: url)
                    request.setValue(
                        "bytes=\(segment.start)-\(segment.endInclusive)",
                        forHTTPHeaderField: "Range"
                    )
                    let task = session.dataTask(with: request)
                    let handle = try FileHandle(forWritingTo: destination)
                    try handle.seek(toOffset: UInt64(segment.start))
                    writers[task.taskIdentifier] = SegmentWriter(segment: segment, handle: handle)
                    tasks.append(task)
                }
            } catch {
                terminalError = error
                self.continuation = nil
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }

            liveTaskCount = tasks.count
            let started = tasks
            lock.unlock()
            started.forEach { $0.resume() }
        }
    }

    private func cancel() {
        lock.lock()
        terminalError = CancellationError()
        let running = tasks
        lock.unlock()
        running.forEach { $0.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse,
              let writer = writers[dataTask.taskIdentifier] else {
            terminalError = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }
        // 200 to a ranged request means the whole file arrived; writing that at a
        // segment offset would silently corrupt the model.
        guard httpResponse.statusCode == 206 else {
            terminalError = URLError(.badServerResponse)
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > 0,
           response.expectedContentLength != writer.segment.size {
            terminalError = DownloadValidationError.incomplete(
                expected: writer.segment.size,
                actual: response.expectedContentLength
            )
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard var writer = writers[dataTask.taskIdentifier] else { return }
        guard writer.written + Int64(data.count) <= writer.segment.size else {
            terminalError = DownloadValidationError.oversized
            dataTask.cancel()
            return
        }
        do {
            try writer.handle.write(contentsOf: data)
            writer.written += Int64(data.count)
            writers[dataTask.taskIdentifier] = writer
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let writer = writers[task.taskIdentifier] {
            try? writer.handle.close()
            if terminalError == nil, error == nil, writer.written != writer.segment.size {
                terminalError = DownloadValidationError.incomplete(
                    expected: writer.segment.size,
                    actual: writer.written
                )
            }
        }
        if terminalError == nil, let error {
            terminalError = error
        }

        liveTaskCount -= 1
        guard liveTaskCount == 0 else {
            // One segment failing dooms the download; stop the rest immediately.
            if terminalError != nil {
                lock.lock()
                let running = tasks
                lock.unlock()
                running.forEach { $0.cancel() }
            }
            return
        }

        let finalError = terminalError
        if finalError != nil {
            try? FileManager.default.removeItem(at: destination)
        }

        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        if let finalError {
            continuation?.resume(throwing: finalError)
        } else {
            continuation?.resume()
        }
        session.finishTasksAndInvalidate()
    }
}

private struct SettingsSectionTitle: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(appearance.palette.secondaryInk)
            .textCase(.uppercase)
            .labelStyle(.titleAndIcon)
    }
}

#Preview {
    SettingsView()
        .environmentObject(EditorViewModel())
        .environmentObject(AppPersistenceState(persistenceDegraded: false, cloudSyncStatus: .available, usesCloudBackedStore: true))
}
