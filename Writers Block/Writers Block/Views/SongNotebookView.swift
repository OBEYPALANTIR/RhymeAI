import SwiftUI

struct SongNotebookView: View {
    @Environment(\.appAppearanceStyle) private var appearance
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var draftIsFocused: Bool
    @State private var tab = 0
    @State private var draft = ""
    @State private var versionToRestore: DraftVersion?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Notebook", selection: $tab) {
                        Text("Alternates").tag(0)
                        Text("Draft History").tag(1)
                    }
                    .pickerStyle(.segmented)
                }
                if let error = viewModel.companionError {
                    Text(error).foregroundStyle(appearance.palette.error)
                }
                if tab == 0 {
                    Section {
                        TextField("Keep a line for later", text: $draft, axis: .vertical)
                            .lineLimit(2...6)
                            .focused($draftIsFocused)
                        Button("Keep alternate") {
                            viewModel.keepAlternate(draft)
                            if viewModel.companionError == nil {
                                draft = ""
                                draftIsFocused = false
                            }
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !viewModel.selectedLyrics.isEmpty {
                            Button("Keep selection") { viewModel.keepAlternate(viewModel.selectedLyrics) }
                        }
                    } footer: {
                        Text("Up to 50 alternates stay with this song on this device. Keeping a line does not change your lyrics.")
                    }
                    if viewModel.companion.alternates.isEmpty {
                        Text("Ideas for another verse can wait here.").foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.companion.alternates) { alternate in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(alternate.text).textSelection(.enabled)
                            let actionsLayout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: RhymeAITokens.Spacing.sm))
                                : AnyLayout(HStackLayout(spacing: RhymeAITokens.Spacing.md))
                            actionsLayout {
                                Button("Insert") {
                                    viewModel.insertSuggestion(alternate.text)
                                    dismiss()
                                }
                                .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
                                Button("Copy") { UIPasteboard.general.string = alternate.text }
                                    .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
                                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                Button("Remove", role: .destructive) { viewModel.removeAlternate(alternate) }
                                    .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
                            }
                            .buttonStyle(.borderless)
                            .frame(minHeight: RhymeAITokens.Touch.minimum)
                        }
                    }
                } else {
                    Section {
                        Button("Save version") { viewModel.flushCurrentDraft(checkpoint: true) }
                            .disabled(viewModel.title.isEmpty && viewModel.lyrics.isEmpty && viewModel.theme.isEmpty)
                    } footer: {
                        Text("The latest 20 distinct drafts stay on this device. Versions are saved as you write, at least five minutes apart, and when you leave a song. Restoring keeps your current draft first.")
                    }
                    if viewModel.companion.versions.isEmpty {
                        Text("Your saved versions will appear here.").foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.companion.versions) { version in
                        DisclosureGroup {
                            Text(version.lyrics).textSelection(.enabled)
                            Button("Restore this version") { versionToRestore = version }
                                .frame(minHeight: RhymeAITokens.Touch.minimum)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(version.createdAt, format: .dateTime.month().day().hour().minute())
                                Text(WritingCompanion.lyricPreview(version.lyrics) ?? version.title)
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Song Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Restore this draft? Your current lyrics will be kept as a version.", isPresented: Binding(get: { versionToRestore != nil }, set: { if !$0 { versionToRestore = nil } })) {
                if let version = versionToRestore {
                    Button("Restore version") {
                        viewModel.restoreVersion(version)
                        versionToRestore = nil
                    }
                }
            }
        }
    }
}
