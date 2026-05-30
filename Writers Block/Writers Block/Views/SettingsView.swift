import Foundation
import SwiftUI

private struct GemmaDownloadOption: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let size: String
    let fileName: String
    let expectedBytes: Int64
    let url: URL
}

private let gemmaDownloadOptions: [GemmaDownloadOption] = [
    GemmaDownloadOption(
        id: "gemma-4-e2b",
        title: "Gemma 4 E2B",
        subtitle: "Recommended faster local model",
        size: "3.18 GB",
        fileName: "gemma-4-E2B-it-UD-Q4_K_XL.gguf",
        expectedBytes: 3_184_494_720,
        url: URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-UD-Q4_K_XL.gguf?download=true")!
    ),
    GemmaDownloadOption(
        id: "gemma-4-e4b",
        title: "Gemma 4 E4B",
        subtitle: "Larger model for richer suggestions",
        size: "5.13 GB",
        fileName: "gemma-4-E4B-it-UD-Q4_K_XL.gguf",
        expectedBytes: 5_126_304_928,
        url: URL(string: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-UD-Q4_K_XL.gguf?download=true")!
    )
]

private let providerSectionAnimation = Animation.spring(response: 0.34, dampingFraction: 0.88)

struct SettingsView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var editingKeys: [String: String] = [:]
    @State private var showKey: Bool = false
    @State private var savedConfirmation: Bool = false
    @State private var installedModelFiles: Set<String> = []
    @State private var activeDownloadID: String?
    @State private var downloadMessage: String?
    @State private var downloadError: String?
    @State private var downloadTask: Task<Void, Never>?

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
            }
        }
    }

    private var settingsBackground: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.indigo.opacity(0.26),
                    Color.teal.opacity(0.08),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.pink.opacity(0.08)
                ],
                startPoint: .center,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 16) {
                contentStack
            }
        } else {
            contentStack
        }
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            providerSection

            providerSpecificSection

            modelSection
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
        .liquidGlassSurface(cornerRadius: 22, tint: .indigo.opacity(0.08), fallbackOpacity: 0.06)
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
            localStatusRow

            SettingsSectionTitle("Recommended Gemma Downloads", systemImage: "arrow.down.circle")

            ForEach(gemmaDownloadOptions) { option in
                gemmaDownloadRow(option)
            }

            if let downloadMessage {
                Label(downloadMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("gemmaDownloadMessage")
            }

            if let downloadError {
                Label(downloadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("gemmaDownloadError")
            }

            Text("iOS suggestions currently use Apple Foundation Models. These GGUF downloads match Android's local-model files and are stored in the app sandbox.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localStatusRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.teal)
                .frame(width: 42, height: 42)
                .liquidGlassSurface(cornerRadius: 14, tint: .teal.opacity(0.14), fallbackOpacity: 0.08)

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
        .liquidGlassSurface(cornerRadius: 22, tint: .teal.opacity(0.08), fallbackOpacity: 0.06)
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionTitle("\(viewModel.selectedProvider.displayName) API Key", systemImage: "key")

            HStack(spacing: 12) {
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
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showKey ? "Hide API key" : "Show API key")
            }
            .padding(14)
            .liquidGlassSurface(cornerRadius: 16, tint: .white.opacity(0.04), interactive: true, fallbackOpacity: 0.06)

            Text(viewModel.selectedProvider.keyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 22, tint: .purple.opacity(0.08), fallbackOpacity: 0.06)
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
            .liquidGlassSurface(cornerRadius: 16, tint: .white.opacity(0.04), interactive: true, fallbackOpacity: 0.06)

            Text(viewModel.selectedModel.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 22, tint: .blue.opacity(0.08), fallbackOpacity: 0.06)
    }

    private var saveSection: some View {
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
                .foregroundStyle(savedConfirmation ? .green : .primary)
                Spacer()
            }
            .padding(.vertical, 15)
            .padding(.horizontal, 16)
            .liquidGlassSurface(cornerRadius: 18, tint: .green.opacity(0.12), interactive: true, fallbackOpacity: 0.08)
        }
        .buttonStyle(.plain)
        .disabled(savedConfirmation)
    }

    private func gemmaDownloadRow(_ option: GemmaDownloadOption) -> some View {
        let isDownloaded = installedModelFiles.contains(option.fileName)
        let isDownloading = activeDownloadID == option.id

        return Button {
            startGemmaDownload(option)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isDownloaded ? .green : .teal)
                    .frame(width: 36, height: 36)
                    .liquidGlassSurface(cornerRadius: 18, tint: .white.opacity(0.04), fallbackOpacity: 0.06)

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

                Text(isDownloaded ? "Downloaded" : (isDownloading ? "Downloading" : "Download"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDownloaded ? .green : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .liquidGlassSurface(cornerRadius: 14, tint: .white.opacity(0.05), fallbackOpacity: 0.07)
            }
            .padding(14)
            .liquidGlassSurface(cornerRadius: 18, tint: .teal.opacity(0.08), interactive: !isDownloaded, fallbackOpacity: 0.05)
        }
        .buttonStyle(.plain)
        .disabled(activeDownloadID != nil || isDownloaded)
        .accessibilityIdentifier("gemmaDownload.\(option.id)")
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
        refreshInstalledModels()
    }

    private func saveAll() {
        for provider in AIProvider.allCases {
            if let key = editingKeys[provider.rawValue] {
                viewModel.saveApiKey(provider: provider, key: key)
            }
        }
        savedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            savedConfirmation = false
        }
    }

    private func startGemmaDownload(_ option: GemmaDownloadOption) {
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

                if FileManager.default.fileExists(atPath: destination.path) {
                    await MainActor.run {
                        installedModelFiles.insert(option.fileName)
                        activeDownloadID = nil
                        downloadMessage = "\(option.title) is already downloaded."
                    }
                    return
                }

                try? FileManager.default.removeItem(at: stagingURL)

                let (temporaryURL, response) = try await URLSession.shared.download(from: option.url)
                try Task.checkCancellation()

                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    throw URLError(.badServerResponse)
                }

                try FileManager.default.moveItem(at: temporaryURL, to: stagingURL)
                let attributes = try FileManager.default.attributesOfItem(atPath: stagingURL.path)
                let downloadedBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                guard downloadedBytes >= option.expectedBytes else {
                    try? FileManager.default.removeItem(at: stagingURL)
                    throw DownloadValidationError.incomplete(expected: option.expectedBytes, actual: downloadedBytes)
                }

                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: stagingURL, to: destination)

                await MainActor.run {
                    viewModel.saveProvider(.local)
                    viewModel.saveModel(.localModel)
                    installedModelFiles.insert(option.fileName)
                    activeDownloadID = nil
                    downloadMessage = "\(option.title) downloaded. Local provider selected."
                }
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

    private func refreshInstalledModels() {
        guard let directory = try? Self.modelsDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil
              ) else {
            installedModelFiles = []
            return
        }
        installedModelFiles = Set(contents.map(\.lastPathComponent))
    }

    private static func modelsDirectory() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = baseURL
            .appendingPathComponent("RhymeAI", isDirectory: true)
            .appendingPathComponent("Gemma", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private enum DownloadValidationError: LocalizedError {
    case incomplete(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case let .incomplete(expected, actual):
            return "download was incomplete: \(Self.format(actual)) of \(Self.format(expected))"
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct SettingsSectionTitle: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .labelStyle(.titleAndIcon)
    }
}

#Preview {
    SettingsView()
        .environmentObject(EditorViewModel())
}
