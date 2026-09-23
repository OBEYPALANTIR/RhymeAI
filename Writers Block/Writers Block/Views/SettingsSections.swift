import SwiftUI

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
            title: \.rawValue
        )
    }
}

struct RhymeSegmentedControl<Option: Hashable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionAnimation
    @Environment(\.appAppearanceStyle) private var appearance

    let options: [Option]
    @Binding var selection: Option
    let accessibilityIdentifier: String
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: RhymeAITokens.Spacing.xxs) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    withRhymeAnimation(RhymeAITokens.Motion.state, reduceMotion: reduceMotion) {
                        selection = option
                    }
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
        .padding(RhymeAITokens.Spacing.xxs)
        .background(
            appearance.palette.raisedSurface,
            in: RoundedRectangle(cornerRadius: RhymeAITokens.Radius.md, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RhymeAITokens.Radius.md, style: .continuous)
                .strokeBorder(appearance.palette.outline, lineWidth: 1)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct SettingsSaveBar: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let saved: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                saved ? "Saved" : "Save Settings",
                systemImage: saved ? "checkmark.circle.fill" : "checkmark"
            )
            .font(.headline)
            .foregroundStyle(saved ? appearance.palette.success : appearance.palette.onAction)
            .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum)
            .appearanceActionSurface(cornerRadius: RhymeAITokens.Radius.lg)
        }
        .buttonStyle(.rhymePress)
        .disabled(saved)
        .accessibilityIdentifier("saveSettingsButton")
    }
}

struct SettingsLocalModelSection: View {
    @EnvironmentObject private var ggufDownloadManager: GGUFDownloadManager
    @Environment(\.appAppearanceStyle) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
            localStatusRow

            if GGUFModelService.isEngineAvailable {
                if !ggufDownloadManager.installedModelFiles.isEmpty {
                    enginePickerRow
                }

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

    private var localStatusRow: some View {
        HStack(alignment: .top, spacing: RhymeAITokens.Spacing.md) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(appearance.palette.action)
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .teal.opacity(0.14), fallbackOpacity: 0.08)

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
        .padding(RhymeAITokens.Spacing.lg)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xl, tint: .teal.opacity(0.08), fallbackOpacity: 0.06)
    }

    private var enginePickerRow: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            SettingsSectionTitle("On-Device Engine", systemImage: "cpu")

            RhymeSegmentedControl(
                options: GGUFEngineChoice.allCases,
                selection: Binding(
                    get: { ggufDownloadManager.engineChoice },
                    set: ggufDownloadManager.selectEngine
                ),
                accessibilityIdentifier: "ggufEnginePicker",
                title: \.displayName
            )
        }
        .padding(RhymeAITokens.Spacing.lg)
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
                ggufDownloadManager.select(option)
            } else {
                ggufDownloadManager.start(option)
            }
        } label: {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
                HStack(alignment: .center, spacing: RhymeAITokens.Spacing.md) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isSelected ? appearance.palette.success : appearance.palette.action)
                        .frame(width: 36, height: 36)
                        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.pill, tint: .white.opacity(0.04), fallbackOpacity: 0.06)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: RhymeAITokens.Spacing.xs) {
                            Text(option.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            if option.isRecommended {
                                Text("Recommended")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(appearance.palette.action)
                            }
                        }

                        Text("\(option.subtitle) · \(option.size)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: RhymeAITokens.Spacing.sm)

                    Text(downloadActionTitle(isDownloaded: isDownloaded, isSelected: isSelected, isDownloading: isDownloading))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? appearance.palette.success : appearance.palette.primaryInk)
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
            .padding(RhymeAITokens.Spacing.md)
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xxl, tint: .teal.opacity(0.08), interactive: !isSelected, fallbackOpacity: 0.05)
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
        .padding(RhymeAITokens.Spacing.lg)
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
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
            Button {
                withRhymeAnimation(RhymeAITokens.Motion.state, reduceMotion: reduceMotion) {
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

            if isExpanded {
                backupControls
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(RhymeAITokens.Spacing.lg)
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
            .padding(RhymeAITokens.Spacing.md)
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xxl, tint: .white.opacity(0.04), interactive: true, fallbackOpacity: 0.06)
            .accessibilityIdentifier("cloudBackupPassphrase")

            HStack(spacing: RhymeAITokens.Spacing.sm) {
                backupButton("Back Up Now", systemImage: "arrow.up.doc.fill", action: backUpNow)
                backupButton("Restore", systemImage: "arrow.down.doc.fill", action: restoreNow)
            }
            .disabled(!controlsEnabled)

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
