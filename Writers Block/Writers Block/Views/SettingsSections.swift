import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case editor = "Editor"

    var id: Self { self }
}

struct SettingsTabPicker: View {
    @Binding var selection: SettingsTab

    var body: some View {
        RhymeSegmentedControl(
            options: SettingsTab.allCases,
            selection: $selection,
            accessibilityIdentifier: "settingsTabPicker",
            label: "Settings section",
            title: \.rawValue
        )
    }
}

struct RhymeSegmentedControl<Option: Hashable>: View {
    @Namespace private var selectionAnimation
    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let options: [Option]
    @Binding var selection: Option
    let accessibilityIdentifier: String
    /// Spoken name of the whole control, e.g. "Appearance".
    let label: String
    let title: (Option) -> String

    var body: some View {
        // More than two options cannot share a row at accessibility sizes
        // without truncating ("Gemi…", "Ope…", "Clau…"), so they stack.
        let stacked = dynamicTypeSize.isAccessibilitySize && options.count > 2
        let layout = stacked
            ? AnyLayout(VStackLayout(spacing: RhymeAITokens.Spacing.xxs))
            : AnyLayout(HStackLayout(spacing: RhymeAITokens.Spacing.xxs))
        let control = layout { segments }
            .padding(RhymeAITokens.Spacing.xxs)
            .background(
                appearance.palette.raisedSurface,
                in: RoundedRectangle(cornerRadius: RhymeAITokens.Radius.md, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RhymeAITokens.Radius.md, style: .continuous)
                    .strokeBorder(appearance.palette.outline, lineWidth: 1)
            }
            // Only the sliding selection animates. The choice itself is
            // applied at once, so a control that switches the whole
            // appearance does not cross-fade every surface in the app.
            .rhymeAnimation(RhymeAITokens.Motion.state, value: selection)

        if stacked {
            // Stacked segments no longer line up with a one-row segmented
            // control, so each button speaks for itself with its selected
            // trait.
            control
                .accessibilityElement(children: .contain)
                .accessibilityLabel(label)
                .accessibilityIdentifier(accessibilityIdentifier)
        } else {
            // Assistive technology and UI tests get the system segmented
            // control: one named group whose segments report selection and
            // position ("2 of 3"), laid out over the equal-width segments
            // drawn above.
            control
                .accessibilityRepresentation {
                    Picker(label, selection: $selection) {
                        ForEach(options, id: \.self) { option in
                            Text(title(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier(accessibilityIdentifier)
                }
        }
    }

    @ViewBuilder
    private var segments: some View {
        ForEach(options, id: \.self) { option in
            let isSelected = selection == option
            Button {
                selection = option
            } label: {
                Text(title(option))
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? appearance.palette.onAction : appearance.palette.primaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: RhymeAITokens.Radius.sm, style: .continuous)
                                .fill(appearance.palette.action)
                                .matchedGeometryEffect(id: "selection", in: selectionAnimation)
                        }
                    }
            }
            .buttonStyle(.rhymePress)
            .accessibilityLabel(title(option))
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

struct SettingsSaveBar: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let saved: Bool
    /// Only API keys wait for Save, so the button is live only while a typed
    /// key differs from the stored one.
    let hasChanges: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                saved ? "Saved" : "Save Settings",
                systemImage: saved ? "checkmark.circle.fill" : "checkmark"
            )
            .font(.headline)
            .foregroundStyle(appearance.palette.onAction)
            .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum)
            .appearanceActionSurface(cornerRadius: RhymeAITokens.Radius.lg)
            .opacity(saved || hasChanges ? 1 : 0.45)
        }
        .buttonStyle(.rhymePress)
        .disabled(saved || !hasChanges)
        .accessibilityHint(hasChanges ? "Saves your API key" : "Nothing to save. Settings apply as you change them")
        .accessibilityIdentifier("saveSettingsButton")
    }
}

struct SettingsLocalModelSection: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @State private var customModelImporterPresented = false
    @State private var customImportError: String?

    @EnvironmentObject private var ggufDownloadManager: GGUFDownloadManager
    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
            localStatusRow

            if GGUFModelService.isEngineAvailable {
                if !ggufDownloadManager.installedModelFiles.isEmpty {
                    enginePickerRow
                }

                customModelSelector

                SettingsSectionTitle("RhymeAI Gemma Downloads", systemImage: "arrow.down.circle")

                ForEach(GGUFDownloadCatalog.options) { option in
                    gemmaDownloadRow(option)
                }

                if let statusMessage = ggufDownloadManager.statusMessage {
                    Label(
                        statusMessage,
                        systemImage: ggufDownloadManager.activeDownloadID == nil
                            ? "checkmark.circle.fill"
                            : "arrow.down.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(ggufDownloadManager.activeDownloadID == nil ? appearance.palette.success : appearance.palette.secondaryInk)
                    .accessibilityIdentifier("gemmaDownloadMessage")
                }

                if let errorMessage = ggufDownloadManager.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.error)
                        .accessibilityIdentifier("gemmaDownloadError")
                }

                Text(ggufDownloadManager.installedModelFiles.isEmpty
                     ? "Download a RhymeAI-tuned Gemma model for private on-device suggestions. Downloads continue if you close Settings."
                     : "The selected GGUF model runs directly on this device with llama.cpp. Apple Intelligence remains available as an alternative."
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

    private var customModelSelector: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            SettingsSectionTitle("Custom Models", systemImage: "externaldrive")
            ForEach(GGUFCustomModelRegistry.models().filter { ggufDownloadManager.installedModelFiles.contains($0.fileName) }) { model in
                Button {
                    viewModel.cancelEditorAIWork()
                    if ggufDownloadManager.selectCustom(model) {
                        viewModel.saveProvider(.local)
                        viewModel.saveModel(.localModel)
                    }
                } label: {
                    Label(model.displayName, systemImage: ggufDownloadManager.selectedModelFileName == model.fileName ? "checkmark.circle.fill" : "externaldrive")
                        .frame(minHeight: RhymeAITokens.Touch.minimum)
                }
                .accessibilityIdentifier("customGGUF.\(model.id)")
            }
            Button {
                customModelImporterPresented = true
            } label: {
                Label("Import GGUF Model", systemImage: "square.and.arrow.down")
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("importCustomGGUFModel")
            if let customImportError { Text(customImportError).foregroundStyle(appearance.palette.error) }
        }
        .disabled(ggufDownloadManager.activeDownloadID != nil || ggufDownloadManager.isRestoringDownloads || ggufDownloadManager.isVerifying)
        .fileImporter(isPresented: $customModelImporterPresented, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let source = urls.first else { return }
                customImportError = nil
                viewModel.cancelEditorAIWork()
                Task {
                    if await ggufDownloadManager.importCustomModel(from: source) {
                        viewModel.saveProvider(.local)
                        viewModel.saveModel(.localModel)
                    }
                }
            case .failure(let error):
                customImportError = error.localizedDescription
            }
        }
    }

    private var localStatusRow: some View {
        HStack(alignment: .top, spacing: RhymeAITokens.Spacing.md) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(appearance.palette.action)
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)

            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                Text("Apple Foundation Models")
                    .font(.headline)

                Text("Runs suggestions on-device when Apple Intelligence is available. No API key is needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl, tint: .teal.opacity(0.08), fallbackOpacity: 0.06)
    }

    private var enginePickerRow: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            SettingsSectionTitle("On-Device Engine", systemImage: "cpu")

            RhymeSegmentedControl(
                options: GGUFEngineChoice.allCases,
                selection: Binding(
                    get: { ggufDownloadManager.engineChoice },
                    set: { choice in
                        viewModel.cancelEditorAIWork()
                        ggufDownloadManager.selectEngine(choice)
                    }
                ),
                accessibilityIdentifier: "ggufEnginePicker",
                label: "On-Device Engine",
                title: \.displayName
            )
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl, tint: .teal.opacity(0.08), fallbackOpacity: 0.06)
    }

    private func gemmaDownloadRow(_ option: GGUFDownloadOption) -> some View {
        let isDownloaded = ggufDownloadManager.installedModelFiles.contains(option.fileName)
        let isSelected = ggufDownloadManager.selectedModelFileName == option.fileName
        let isDownloading = ggufDownloadManager.activeDownloadID == option.id

        return Button {
            if isDownloading {
                ggufDownloadManager.pauseDownload()
            } else if isDownloaded {
                viewModel.cancelEditorAIWork()
                ggufDownloadManager.select(option)
            } else {
                ggufDownloadManager.start(option)
            }
        } label: {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
                // Beside each other at standard sizes; stacked at accessibility
                // sizes, where a row left the title one or two letters wide.
                let stacked = dynamicTypeSize.isAccessibilitySize
                let rowLayout = stacked
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: RhymeAITokens.Spacing.sm))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: RhymeAITokens.Spacing.md))
                rowLayout {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isSelected ? appearance.palette.success : appearance.palette.action)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        if option.isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(appearance.palette.action)
                        }

                        Text("\(option.subtitle) · \(option.size)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                    if !stacked {
                        Spacer(minLength: RhymeAITokens.Spacing.sm)
                    }

                    Text(downloadActionTitle(isDownloaded: isDownloaded, isSelected: isSelected, isDownloading: isDownloading))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? appearance.palette.success : appearance.palette.primaryInk)
                        .fixedSize()
                        .padding(.horizontal, RhymeAITokens.Spacing.sm)
                        .padding(.vertical, 7)
                        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .white.opacity(0.05), fallbackOpacity: 0.07)
                }

                if isDownloading {
                    ProgressView(value: ggufDownloadManager.progress)
                        .tint(appearance.palette.action)
                        .accessibilityValue("\(Int(ggufDownloadManager.progress * 100)) percent")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(RhymeAITokens.Spacing.md)
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, tint: .teal.opacity(0.08), interactive: !isSelected, fallbackOpacity: 0.05)
        }
        .buttonStyle(.rhymePress)
        .disabled(ggufDownloadManager.isRestoringDownloads || ggufDownloadManager.isPausing ||
                  ggufDownloadManager.isVerifying ||
                  (ggufDownloadManager.activeDownloadID != nil && !isDownloading))
        .accessibilityIdentifier("gemmaDownload.\(option.id)")
    }

    private func downloadActionTitle(isDownloaded: Bool, isSelected: Bool, isDownloading: Bool) -> String {
        if isDownloading { return "Pause" }
        if isSelected { return "Selected" }
        if isDownloaded { return "Use" }
        return "Download"
    }
}

struct SettingsEditorSection: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.appAppearanceStyle) private var appearance
    @Binding var activeHelp: FeatureHelp?

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
            SettingsSectionTitle("Editor", systemImage: "textformat")

            settingsToggleRow("Whole Song Context", help: .wholeSongContext, isOn: binding(viewModel.useWholeSongContext, setter: viewModel.saveUseWholeSongContext))
            settingsToggleRow("Highlight Rhymes", help: .highlightRhymes, isOn: binding(viewModel.isHighlightEnabled, setter: viewModel.saveIsHighlightEnabled))
            settingsToggleRow("Underline Syllables", help: .underlineSyllables, isOn: binding(viewModel.isSyllableColoringEnabled, setter: viewModel.saveIsSyllableColoringEnabled))
            settingsToggleRow("Stress + IPA", help: .stressIPA, isOn: binding(viewModel.isStressPreviewEnabled, setter: viewModel.saveIsStressPreviewEnabled))
            settingsToggleRow("Color Rhymes", help: .colorRhymes, isOn: binding(viewModel.isRhymeHighlightEnabled, setter: viewModel.saveIsRhymeHighlightEnabled))
            settingsToggleRow("Beat Grid", help: .beatGrid, isOn: binding(viewModel.isBeatGridEnabled, setter: viewModel.saveIsBeatGridEnabled))
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl, tint: .indigo.opacity(0.06), fallbackOpacity: 0.06)
        .accessibilityIdentifier("editorSettingsSection")
    }

    private func binding(_ value: Bool, setter: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: setter)
    }

    private func settingsToggleRow(_ text: String, help: FeatureHelp, isOn: Binding<Bool>) -> some View {
        HStack {
            HStack(spacing: RhymeAITokens.Spacing.xs) {
                Text(text)
                    .font(.subheadline)
                Button {
                    activeHelp = help
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel("\(help.title) help")
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(appearance.palette.action)
                .accessibilityLabel(text)
        }
    }
}

struct SettingsCloudBackupSection: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var persistenceState: AppPersistenceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance
    @State private var isExpanded = false
    @State private var passphraseEntry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withRhymeAnimation(RhymeAITokens.Motion.settle, reduceMotion: reduceMotion) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: RhymeAITokens.Spacing.md) {
                    VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                        SettingsSectionTitle("Cloud Backup", systemImage: "externaldrive.badge.icloud")
                        cloudSyncStatusRow
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.rhymePress)
            .accessibilityIdentifier("cloudBackupDisclosure")
            .accessibilityLabel(isExpanded ? "Collapse cloud backup" : "Expand cloud backup")

            // Clipped so the controls reveal below the header instead of
            // sliding over it and the card above.
            VStack(spacing: 0) {
                if isExpanded {
                    backupControls
                        .padding(.top, RhymeAITokens.Spacing.md)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            // Full width so the clip only grows downward, not from the leading edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(RhymeAITokens.Spacing.md)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl, tint: .cyan.opacity(0.08), fallbackOpacity: 0.06)
        .onDisappear {
            passphraseEntry = ""
        }
    }

    private var backupControls: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
            Text("Backs up projects, trash, and voice recordings to your Google Drive app data. API keys stay on this device and are never included.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField(
                viewModel.cloudBackupHasStoredPassphrase ? "Stored passphrase ready" : "Backup passphrase",
                text: $passphraseEntry
            )
            .textContentType(.password)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.system(.body, design: .rounded))
            .padding(.horizontal, RhymeAITokens.Spacing.sm)
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, tint: .white.opacity(0.04), interactive: true, fallbackOpacity: 0.06)
            .accessibilityIdentifier("cloudBackupPassphrase")

            HStack(spacing: RhymeAITokens.Spacing.sm) {
                backupButton("Back Up Now", systemImage: "arrow.up.doc.fill", action: backUpNow)
                backupButton("Restore", systemImage: "arrow.down.doc.fill", action: restoreNow)
            }
            .disabled(!controlsEnabled)
            .opacity(controlsEnabled ? 1 : 0.45)

            Label(viewModel.cloudBackupStatusText, systemImage: backupStatusIcon)
                .font(.caption)
                .foregroundStyle(backupStatusColor)
                .accessibilityIdentifier("cloudBackupStatus")

            Text("Background backup runs only after you set up Google Drive and save a passphrase here. Your songs and recordings also remain covered by iCloud backup and sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func backupButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum)
        }
        .buttonStyle(.rhymePress)
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
        case .syncing: "iCloud sync: Checking…"
        case .available: "iCloud sync: On"
        case .localOnly, .accountUnavailable: "iCloud sync: Off"
        }
    }

    private var cloudSyncStatusIcon: String {
        switch persistenceState.cloudSyncStatus {
        case .syncing: "arrow.triangle.2.circlepath"
        case .available: "checkmark.icloud.fill"
        case .localOnly, .accountUnavailable: "icloud.slash"
        }
    }

    private var controlsEnabled: Bool {
        viewModel.cloudBackupConfigured
            && !viewModel.cloudBackupIsWorking
            && (viewModel.cloudBackupHasStoredPassphrase || !trimmedPassphrase.isEmpty)
    }

    private var backupStatusIcon: String {
        if viewModel.cloudBackupIsWorking { return "arrow.triangle.2.circlepath" }
        return viewModel.cloudBackupLastResultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var backupStatusColor: Color {
        if viewModel.cloudBackupIsWorking { return .secondary }
        return viewModel.cloudBackupLastResultIsError ? appearance.palette.error : appearance.palette.success
    }

    private var trimmedPassphrase: String {
        passphraseEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func backUpNow() {
        runCloudBackupAction(viewModel.backUpNow)
    }

    private func restoreNow() {
        runCloudBackupAction(viewModel.restoreBackupNow)
    }

    private func runCloudBackupAction(_ action: @escaping @MainActor () async -> Void) {
        let passphrase = trimmedPassphrase
        if !passphrase.isEmpty {
            viewModel.updateCloudBackupPassphrase(passphrase)
        }

        Task { @MainActor in
            await action()
            if !passphrase.isEmpty {
                passphraseEntry = ""
            }
        }
    }
}

struct SettingsSectionTitle: View {
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
