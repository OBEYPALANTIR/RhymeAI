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
                .foregroundStyle(appearance.palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Gemma downloads and the GGUF engine are unavailable in this build. Apple Intelligence remains the on-device local option.")
                    .font(.caption)
                    .foregroundStyle(appearance.palette.secondaryInk)
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
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                Text("Apple Foundation Models")
                    .font(.headline)

                Text("Runs suggestions on-device when Apple Intelligence is available. No API key is needed.")
                    .font(.caption)
                    .foregroundStyle(appearance.palette.secondaryInk)
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
                            .foregroundStyle(appearance.palette.secondaryInk)
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
                        .foregroundStyle(appearance.palette.secondaryInk)
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
    @Environment(\.openURL) private var openURL
    @State private var isExpanded = false
    @State private var migratePromptShown = false
    @State private var migratePassphrase = ""
    @State private var importerShown = false
    @State private var exporterShown = false
    @State private var pendingExport: (fileName: String, document: ExportDocument)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withRhymeAnimation(RhymeAITokens.Motion.settle, reduceMotion: reduceMotion) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: RhymeAITokens.Spacing.md) {
                    VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                        SettingsSectionTitle("Backup", systemImage: "externaldrive.badge.icloud")
                        cloudSyncStatusRow
                        providerStatusRow
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(appearance.palette.secondaryInk)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.rhymePress)
            .accessibilityIdentifier("cloudBackupDisclosure")
            .accessibilityLabel(isExpanded ? "Collapse backup" : "Expand backup")

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
        .alert("Migrate older encrypted backup", isPresented: $migratePromptShown) {
            SecureField("Backup passphrase", text: $migratePassphrase)
                .accessibilityIdentifier("migratePassphrase")
            Button("Cancel", role: .cancel) { migratePassphrase = "" }
            Button("Migrate") {
                let passphrase = migratePassphrase
                migratePassphrase = ""
                Task { await viewModel.migrateLegacyBackup(passphrase: passphrase) }
            }
        } message: {
            Text("Enter the passphrase of your older encrypted backup. It is used once to move that backup to the new format and is not kept.")
        }
        .fileImporter(isPresented: $importerShown, allowedContentTypes: [.zip, .json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            Task { await viewModel.importBackupFile(data) }
        }
        .fileExporter(
            isPresented: $exporterShown,
            document: pendingExport?.document,
            contentType: .zip,
            defaultFilename: pendingExport?.fileName
        ) { _ in
            pendingExport = nil
        }
    }

    private var backupControls: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            if case .failed = viewModel.backupStatus {
                row("Retry", systemImage: "arrow.clockwise", id: "backupRetry", enabled: viewModel.canRunCloudBackup) {
                    Task { await viewModel.backUpNow() }
                }
            }
            if viewModel.cloudBackupConnected {
                row("Disconnect", systemImage: "link.badge.minus", id: "disconnectGoogleDrive", enabled: !viewModel.cloudBackupIsWorking) {
                    Task { await viewModel.disconnectGoogleDrive() }
                }
            } else {
                row("Connect Google Drive", systemImage: "link.badge.plus", id: "connectGoogleDrive", enabled: viewModel.cloudBackupConfigured) {
                    Task { await viewModel.connectGoogleDrive() }
                }
            }
            row("Back up now", systemImage: "arrow.up.doc.fill", id: "backUpNow", enabled: viewModel.canRunCloudBackup) {
                Task { await viewModel.backUpNow() }
            }
            row("Restore from backup", systemImage: "arrow.down.doc.fill", id: "restoreFromBackup", enabled: viewModel.canRunCloudBackup) {
                Task { await viewModel.restoreBackupNow() }
            }
            if viewModel.legacyBackupNeedsPassphrase {
                row("Migrate older encrypted backup…", systemImage: "lock.open", id: "migrateLegacyBackup", enabled: viewModel.canRunCloudBackup) {
                    migratePromptShown = true
                }
            }
            row("Export all songs…", systemImage: "square.and.arrow.up", id: "exportAllSongs", enabled: !viewModel.cloudBackupIsWorking) {
                if let archive = viewModel.exportAllSongs() {
                    pendingExport = (archive.fileName, ExportDocument(data: archive.data))
                    exporterShown = true
                }
            }
            row("Import from file…", systemImage: "square.and.arrow.down", id: "importBackupFile", enabled: !viewModel.cloudBackupIsWorking) {
                importerShown = true
            }

            if !viewModel.cloudBackupStatusText.isEmpty {
                Label(viewModel.cloudBackupStatusText, systemImage: viewModel.cloudBackupLastResultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(viewModel.cloudBackupLastResultIsError ? appearance.palette.error : appearance.palette.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloudBackupStatus")
            }
            if viewModel.oversizedRecordingCount > 0 {
                let count = viewModel.oversizedRecordingCount
                Text("\(count) \(count == 1 ? "recording is" : "recordings are") over 16 MB and \(count == 1 ? "stays" : "stay") on this device only.")
                    .font(.caption)
                    .foregroundStyle(appearance.palette.secondaryInk)
                    .accessibilityIdentifier("oversizedRecordingsNote")
            }
            if !viewModel.recordingsNeedingAttention.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("These recordings couldn't move to their new file names because another file is in the way. Both are kept on this device.")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(viewModel.recordingsNeedingAttention, id: \.self) { url in
                        HStack {
                            Text(viewModel.attentionLabel(for: url))
                                .font(.caption)
                                .lineLimit(2)
                            Spacer()
                            Button("Keep separately") { Task { await viewModel.keepRecordingSeparately(url) } }
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: RhymeAITokens.Touch.minimum)
                                .accessibilityIdentifier("keepRecordingSeparately")
                        }
                    }
                }
                .accessibilityIdentifier("recordingsNeedingAttention")
            }
            if !viewModel.recordingNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.recordingNotes, id: \.self) { note in
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(appearance.palette.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Check recordings again") { Task { _ = await viewModel.reconcileRecordings() } }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: RhymeAITokens.Touch.minimum)
                        .accessibilityIdentifier("checkRecordingsAgain")
                }
                .accessibilityIdentifier("recordingNotes")
            }
            if viewModel.recordingRecordsDamaged {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A record of recordings changes is damaged, so recordings can't be changed. Every file is kept. Repairing sets a damaged move record aside; a deletion record without a time is never given one, so it is kept.")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Repair recordings records") { Task { await viewModel.repairRecordingRecords() } }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: RhymeAITokens.Touch.minimum)
                        .accessibilityIdentifier("repairRecordingRecords")
                }
            }
            if viewModel.recordingAdoptionStalled {
                Text("Some recordings couldn't be read into the library yet. They stay on this device.")
                    .font(.caption)
                    .foregroundStyle(appearance.palette.secondaryInk)
                    .accessibilityIdentifier("recordingsStalledNote")
            }
            if !viewModel.cloudBackupConfigured {
                Text("Google Drive isn't set up in this build.")
                    .font(.caption)
                    .foregroundStyle(appearance.palette.secondaryInk)
            }
            Text("Songs, trash and recordings are backed up to your Google Drive's private app storage. API keys are never included. Songs and recordings also sync through iCloud.")
                .font(.caption)
                .foregroundStyle(appearance.palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("backupFooter")
        }
    }

    private func row(_ title: String, systemImage: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.rhymePress)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier(id)
    }

    /// "Last backed up 2 minutes ago · Google Drive"; refreshed while visible.
    private var providerStatusRow: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let text = providerStatusText(now: context.date)
            Label {
                Text(text)
            } icon: {
                Image(systemName: providerStatusIcon)
                    // "just now" wears the success colour at the save indicator's 80%; the text stays in ink.
                    .foregroundStyle(providerStatusIconColor(now: context.date))
                    .symbolEffect(.rotate, isActive: isBackingUp && !reduceMotion)
            }
            .font(.caption)
            .foregroundStyle(isFailed ? appearance.palette.error : appearance.palette.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            // Text and glyph cross-fade in place on the state tier instead of swapping in one frame.
            .contentTransition(.opacity)
            .rhymeAnimation(RhymeAITokens.Motion.state, value: text)
            .accessibilityIdentifier("backupProviderStatus")
        }
    }

    private var isFailed: Bool {
        if case .failed = viewModel.backupStatus { return true }
        return false
    }

    private var isBackingUp: Bool {
        if case .backingUp = viewModel.backupStatus { return true }
        return false
    }

    /// True while the row reads "Last backed up just now".
    static func isJustBackedUp(_ lastBackupAt: Date?, now: Date) -> Bool {
        guard let lastBackupAt else { return false }
        return now.timeIntervalSince(lastBackupAt) < 60
    }

    private func providerStatusIconColor(now: Date) -> Color {
        Self.providerStatusIconColor(viewModel.backupStatus, now: now, palette: appearance.palette)
    }

    /// The status glyph's colour: error while failed, the success colour at
    /// the save indicator's 80% while "just now", otherwise secondary ink.
    static func providerStatusIconColor(_ status: BackupStatus, now: Date, palette: AppAppearancePalette) -> Color {
        switch status {
        case .failed:
            return palette.error
        case .connected(let last) where isJustBackedUp(last, now: now):
            return palette.success.opacity(EditorViewConstants.TopBar.savedStatusOpacity)
        case .connected, .notConnected, .pending, .backingUp:
            return palette.secondaryInk
        }
    }

    private func providerStatusText(now: Date) -> String {
        switch viewModel.backupStatus {
        case .notConnected:
            return "Google Drive not connected"
        case .connected(let last):
            return "\(lastBackedUp(last, now: now)) · Google Drive"
        case .pending:
            return "Waiting to back up · Google Drive"
        case .backingUp:
            return "Backing up… · Google Drive"
        case .failed(let reason, _):
            return reason
        }
    }

    private func lastBackedUp(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not backed up yet" }
        guard !Self.isJustBackedUp(date, now: now) else { return "Last backed up just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last backed up \(formatter.localizedString(for: date, relativeTo: now))"
    }

    private var providerStatusIcon: String {
        switch viewModel.backupStatus {
        case .notConnected: "externaldrive.badge.xmark"
        case .connected: "checkmark.circle"
        case .pending, .backingUp: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    @ViewBuilder
    private var cloudSyncStatusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: RhymeAITokens.Spacing.xs) {
            Label(cloudSyncStatusText, systemImage: cloudSyncStatusIcon)
                .font(.caption)
                .foregroundStyle(appearance.palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("iCloudSyncStatus")
            if persistenceState.cloudSyncStatus == .noAccount,
               let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(settings) }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("iCloudOpenSettings")
            }
        }
    }

    private var cloudSyncStatusText: String {
        switch persistenceState.cloudSyncStatus {
        case .checking: "iCloud sync: Checking…"
        case .on: "iCloud sync: On"
        case .noAccount: "iCloud sync: Off. Sign in to iCloud to sync songs."
        case .restricted: "iCloud sync: Off. iCloud is restricted on this device."
        case .localOnlyFallback: "iCloud sync: Off. The iCloud library could not be opened, so songs are saved on this device only."
        case .temporarilyUnavailable: "iCloud sync: Paused. iCloud is temporarily unavailable."
        }
    }

    private var cloudSyncStatusIcon: String {
        switch persistenceState.cloudSyncStatus {
        case .checking: "arrow.triangle.2.circlepath"
        case .on: "checkmark.icloud.fill"
        case .noAccount, .restricted, .localOnlyFallback, .temporarilyUnavailable: "icloud.slash"
        }
    }
}

/// "Restore your songs?" — offered once Drive holds songs this device lacks.
struct FirstRunRestoreSheet: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.appAppearanceStyle) private var appearance
    let offer: FirstRunRestoreOffer

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.lg) {
            Text("Restore your songs?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(appearance.palette.primaryInk)
            Text("We found \(count(offer.songs, "song")) and \(count(offer.recordings, "recording")) in your Google Drive backup.")
                .font(.body)
                .foregroundStyle(appearance.palette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("firstRunRestoreBody")
            VStack(spacing: RhymeAITokens.Spacing.sm) {
                Button {
                    Task { await viewModel.acceptFirstRunRestore() }
                } label: {
                    Text("Restore")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("firstRunRestore")
                Button {
                    viewModel.declineFirstRunRestore()
                } label: {
                    Text("Not now")
                        .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum)
                }
                .accessibilityIdentifier("firstRunNotNow")
            }
        }
        .padding(RhymeAITokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(appearance.palette.canvas)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
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
