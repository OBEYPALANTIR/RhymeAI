import SwiftUI

struct SongNotebookView: View {
    @Environment(\.appAppearanceStyle) private var appearance
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var draftIsFocused: Bool
    @State private var tab = 0
    @State private var draft = ""
    @State private var versionToRestore: DraftVersion?
    /// Several versions can be open at once, to compare them.
    @State private var expandedVersions: Set<DraftVersion.ID> = []
    /// The version opened last; it scrolls to the top of the sheet.
    @State private var openedVersion: DraftVersion.ID?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        RhymeSegmentedControl(
                            options: [0, 1],
                            selection: $tab,
                            accessibilityIdentifier: "notebookTabPicker",
                            label: "Notebook",
                            title: { $0 == 0 ? "Alternates" : "Draft History" }
                        )
                    }
                    .listRowBackground(Color.clear)
                    Group {
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
                                Text("Ideas for another verse can wait here.").foregroundStyle(appearance.palette.secondaryInk)
                            }
                            ForEach(viewModel.companion.alternates) { alternate in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(alternate.text).textSelection(.enabled)
                                    let actionsLayout = dynamicTypeSize.isAccessibilitySize
                                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: RhymeAITokens.Spacing.sm))
                                        : AnyLayout(HStackLayout(spacing: RhymeAITokens.Spacing.md))
                                    actionsLayout {
                                        Button {
                                            viewModel.insertSuggestion(alternate.text)
                                            dismiss()
                                        } label: {
                                            actionLabel("Insert")
                                        }
                                        Button { UIPasteboard.general.string = alternate.text } label: {
                                            actionLabel("Copy")
                                        }
                                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                        Button(role: .destructive) { viewModel.removeAlternate(alternate) } label: {
                                            actionLabel("Remove")
                                        }
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
                                Text("Your saved versions will appear here.").foregroundStyle(appearance.palette.secondaryInk)
                            }
                            ForEach(viewModel.companion.versions) { version in
                                DisclosureGroup(isExpanded: Binding(
                                    get: { expandedVersions.contains(version.id) },
                                    set: { isOpen in
                                        if isOpen {
                                            expandedVersions.insert(version.id)
                                            openedVersion = version.id
                                        } else {
                                            expandedVersions.remove(version.id)
                                            if openedVersion == version.id { openedVersion = nil }
                                        }
                                    }
                                )) {
                                    // Restore comes before the lyrics so it sits right
                                    // under the opened version even when the lyrics run
                                    // past the bottom of the sheet at large text sizes.
                                    Button("Restore this version") { versionToRestore = version }
                                        .frame(minHeight: RhymeAITokens.Touch.minimum)
                                    Text(version.lyrics).textSelection(.enabled)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(version.createdAt, format: .dateTime.month().day().hour().minute())
                                        Text(WritingCompanion.lyricPreview(version.lyrics) ?? version.title)
                                            .font(.subheadline).foregroundStyle(appearance.palette.secondaryInk).lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(appearance.palette.raisedSurface)
                }
                // The stock grouped list is a cool grey that belongs to none of
                // the three appearances.
                .scrollContentBackground(.hidden)
                .background(AppWritingBackground())
                // An opened version moves to the top of the sheet, so its Restore
                // button is on screen even when the row was at the bottom edge.
                .onChange(of: openedVersion) { _, id in
                    guard let id else { return }
                    withRhymeAnimation(RhymeAITokens.Motion.state, reduceMotion: reduceMotion) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .navigationTitle("Song Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Restore this draft? Your current lyrics will be kept as a version.", isPresented: Binding(get: { versionToRestore != nil }, set: { if !$0 { versionToRestore = nil } }), titleVisibility: .visible) {
                if let version = versionToRestore {
                    Button("Restore version") {
                        viewModel.restoreVersion(version)
                        versionToRestore = nil
                    }
                }
            }
        }
    }

    /// The 44pt frame sits inside the button so the whole area takes the tap.
    private func actionLabel(_ title: String) -> some View {
        Text(title)
            .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
            .contentShape(Rectangle())
    }
}
