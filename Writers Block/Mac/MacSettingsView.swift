import SwiftUI
import UniformTypeIdentifiers

struct MacSettingsView: View {
    @EnvironmentObject private var editor: EditorViewModel
    @AppStorage(AppAppearanceStyle.storageKey) private var appearanceRaw = AppAppearanceStyle.ink.rawValue
    @State private var key = ""
    @State private var keyMessage: String?
    @State private var deletingKey = false
    @State private var modelImport = false
    @State private var modelBusy = false
    @State private var modelMessage: String?
    @State private var models = GGUFCustomModelRegistry.models()
    @State private var selectedFile = GGUFModelSelection.currentFileName ?? ""
    @State private var engine = GGUFEngineChoice.current
    @State private var passphrase = ""

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Writing surface", selection: $appearanceRaw) {
                    ForEach(AppAppearanceStyle.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            Section("AI Provider") {
                Picker("Provider", selection: Binding(get: { editor.selectedProvider }, set: { provider in
                    key = ""; keyMessage = nil
                    editor.cancelSuggestions(); editor.dismissRewrite()
                    editor.saveProvider(provider)
                })) {
                    ForEach(AIProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Model", selection: Binding(get: { editor.selectedModel }, set: editor.saveModel)) {
                    ForEach(AIModel.models(for: editor.selectedProvider)) { Text($0.displayName).tag($0) }
                }
                if editor.selectedProvider != .local {
                    Text(editor.hasApiKey(for: editor.selectedProvider) ? "API key stored in Keychain" : "No API key stored").font(.caption)
                    SecureField("New API key", text: $key).textContentType(.password)
                    HStack {
                        Button("Save Key") {
                            if editor.saveApiKey(provider: editor.selectedProvider, key: key.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                key = ""; keyMessage = "API key saved in Keychain."
                            } else { keyMessage = "The key could not be saved. Your existing key is unchanged." }
                        }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Delete Key", role: .destructive) { deletingKey = true }.disabled(!editor.hasApiKey(for: editor.selectedProvider))
                    }
                    if let keyMessage { Text(keyMessage).font(.caption) }
                    Text("Cloud requests require consent before lyrics leave this Mac.").font(.caption).foregroundStyle(.secondary)
                    Button("Revoke Lyrics Sharing Permission") {
                        editor.setCloudAISharingConsent(false, for: editor.selectedProvider, scope: .selectedContext)
                        editor.setCloudAISharingConsent(false, for: editor.selectedProvider, scope: .wholeSong)
                    }
                }
            }
            Section("On-Device Models") {
                Picker("Local engine", selection: $engine) {
                    ForEach(GGUFEngineChoice.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.onChange(of: engine) { _, value in
                    editor.cancelSuggestions(); editor.dismissRewrite()
                    value.save()
                    Task { await AIService.ggufRunner.unload() }
                }
                if engine == .gemma {
                    Picker("GGUF model", selection: $selectedFile) {
                        Text("Choose a model").tag("")
                        ForEach(models) { Text($0.displayName).tag($0.fileName) }
                        ForEach(GGUFModelCatalog.models.filter { model in
                            guard let directory = try? GGUFModelCatalog.modelsDirectory(create: false) else { return false }
                            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(model.fileName).path)
                        }) { Text($0.title).tag($0.fileName) }
                    }.onChange(of: selectedFile) { _, value in
                        editor.cancelSuggestions(); editor.dismissRewrite()
                        GGUFModelSelection.save(fileName: value)
                    }
                    Button("Import GGUF Model…") { modelImport = true }.disabled(modelBusy)
                    if modelBusy { ProgressView("Copying and checking model…") }
                    Text("Choose a Gemma GGUF with its original chat template. The model is copied into this app’s private storage; generation stays on this Mac.").font(.caption).foregroundStyle(.secondary)
                    if let modelMessage { Text(modelMessage).font(.caption).textSelection(.enabled) }
                } else {
                    Text("Apple Intelligence requires a supported Mac with Apple Intelligence enabled. If unavailable, the assistant explains how to select a GGUF model.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Encrypted Google Drive Backup") {
                Text(editor.cloudBackupStatusText).font(.caption)
                if editor.cloudBackupConfigured {
                    SecureField("Backup passphrase", text: $passphrase)
                    Button("Save Passphrase") { editor.updateCloudBackupPassphrase(passphrase); passphrase = "" }.disabled(passphrase.isEmpty)
                    HStack {
                        Button("Back Up Now") { Task { await editor.backUpNow() } }
                        Button("Restore Backup") { Task { await editor.restoreBackupNow() } }
                    }.disabled(editor.cloudBackupIsWorking)
                }
                Text("The song library is stored locally on this Mac. iCloud synchronization is not enabled for this Mac target.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 570, height: 710)
        .task { editor.refreshCloudBackupState() }
        .onDisappear { key = ""; passphrase = "" }
        .confirmationDialog("Delete the stored API key?", isPresented: $deletingKey) {
            Button("Delete Key", role: .destructive) {
                keyMessage = editor.saveApiKey(provider: editor.selectedProvider, key: "") ? "API key deleted." : "The key could not be deleted. Try again."
            }
        }
        .fileImporter(isPresented: $modelImport, allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data]) { result in
            switch result {
            case .failure(let error): modelMessage = error.localizedDescription
            case .success(let url): importModel(url)
            }
        }
    }

    private func importModel(_ url: URL) {
        modelBusy = true
        modelMessage = nil
        Task {
            do {
                let model = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try GGUFModelCatalog.importCustomFile(at: url)
                }.value
                GGUFCustomModelRegistry.register(model)
                GGUFModelSelection.save(fileName: model.fileName)
                models = GGUFCustomModelRegistry.models()
                selectedFile = model.fileName
                engine = .gemma
                engine.save()
                editor.saveProvider(.local)
                modelMessage = "Model imported. Use UnBlock to generate locally."
            } catch { modelMessage = error.localizedDescription }
            modelBusy = false
        }
    }
}
