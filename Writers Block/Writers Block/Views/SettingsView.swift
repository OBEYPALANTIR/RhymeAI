import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editingKeys: [String: String] = [:]
    @State private var showKey: Bool = false
    @State private var savedConfirmation: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Provider
                Section("AI Provider") {
                    Picker("Provider", selection: Binding(
                        get: { viewModel.selectedProvider },
                        set: { viewModel.saveProvider($0) }
                    )) {
                        ForEach(AIProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if viewModel.selectedProvider == .local {
                    Section {
                        Label("Apple Foundation Models", systemImage: "iphone.gen3.radiowaves.left.and.right")
                            .font(.body.weight(.medium))

                        Text("Runs suggestions on-device when Apple Intelligence is available. No API key is needed and lyrics stay on the device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("On-Device Model")
                    } footer: {
                        Text(viewModel.selectedProvider.keyHint)
                    }
                } else {
                    // MARK: - API Key
                    Section {
                        HStack {
                            if showKey {
                                TextField("API Key", text: apiKeyBinding)
                                    .font(.system(.body, design: .monospaced))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            } else {
                                SecureField("API Key", text: apiKeyBinding)
                                    .font(.system(.body, design: .monospaced))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }

                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("\(viewModel.selectedProvider.displayName) API Key")
                    } footer: {
                        Text(viewModel.selectedProvider.keyHint)
                    }
                }

                // MARK: - Model
                Section("Model") {
                    Picker("Model", selection: Binding(
                        get: { viewModel.selectedModel },
                        set: { viewModel.saveModel($0) }
                    )) {
                        ForEach(AIModel.models(for: viewModel.selectedProvider)) { model in
                            VStack(alignment: .leading) {
                                Text(model.displayName)
                                Text(model.id)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(model)
                        }
                    }
                }

                // MARK: - Save
                Section {
                    Button {
                        saveAll()
                    } label: {
                        HStack {
                            Spacer()
                            if savedConfirmation {
                                Label("Saved!", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Text("Save Settings")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(savedConfirmation)
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
                // Load current keys for editing
                for provider in AIProvider.allCases {
                    editingKeys[provider.rawValue] = viewModel.apiKeys[provider.rawValue] ?? ""
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { editingKeys[viewModel.selectedProvider.rawValue] ?? "" },
            set: { editingKeys[viewModel.selectedProvider.rawValue] = $0 }
        )
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
}

#Preview {
    SettingsView()
        .environmentObject(EditorViewModel())
}
