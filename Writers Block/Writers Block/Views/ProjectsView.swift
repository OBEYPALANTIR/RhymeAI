import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ProjectsView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]
    @Query(sort: \TrashedSongProject.deletedAt, order: .reverse) private var trashedProjects: [TrashedSongProject]
    @State private var searchText = ""
    @State private var fileImporterPresented = false
    @State private var importError: String?
    @State private var pendingDeleteProject: SongProject?
    @State private var trashBinPresented = false

    private var filteredProjects: [SongProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }

        return projects.filter { project in
            let title = project.title.isEmpty ? "Untitled Song" : project.title
            return title.localizedCaseInsensitiveContains(query)
                || project.lyrics.localizedCaseInsensitiveContains(query)
                || project.theme.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: RhymeAITokens.Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search songs", text: $searchText)
                        .textInputAutocapitalization(.never)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.rhymePress)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.vertical, RhymeAITokens.Spacing.xs)
                .padding(.horizontal, RhymeAITokens.Spacing.sm)
                .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, interactive: true)
                .listRowBackground(Color.clear)

                Button {
                    viewModel.newProject()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "plus")
                            .foregroundStyle(.indigo)
                        Text("Create New Song")
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: RhymeAITokens.Touch.minimum)
                    .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, tint: .indigo.opacity(0.10), interactive: true)
                }
                .listRowBackground(Color.clear)

                Button {
                    importError = nil
                    fileImporterPresented = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(.secondary)
                        Text("Import From File")
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: RhymeAITokens.Touch.minimum)
                    .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, interactive: true)
                }
                .listRowBackground(Color.clear)

                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }

                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No Saved Songs", systemImage: "music.note")
                    } description: {
                        Text("Your songs will appear here once you start writing.")
                    }
                    .listRowBackground(Color.clear)
                } else if filteredProjects.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Songs", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a title, lyric, or theme.")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredProjects, id: \.id) { project in
                        Button {
                            viewModel.loadProject(project)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                                    Text(project.title.isEmpty ? "Untitled Song" : project.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    HStack(spacing: RhymeAITokens.Spacing.xs) {
                                        Text(project.updatedAt, style: .date)
                                        Text("·")
                                        Text("\(SyllableCounter.wordCount(project.lyrics)) words")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if viewModel.currentProjectId == project.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.indigo)
                                }
                            }
                            .padding(.vertical, RhymeAITokens.Spacing.xxs)
                        }
                        .listRowBackground(
                            viewModel.currentProjectId == project.id
                                ? Color.indigo.opacity(0.1)
                                : Color.clear
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteProject = project
                            } label: {
                                Label("Trash", systemImage: "xmark")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Song Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.purgeExpiredTrashedProjects()
                        trashBinPresented = true
                    } label: {
                        trashToolbarLabel
                    }
                    .accessibilityLabel("Open Trash Bin")
                    .accessibilityValue(trashedProjects.isEmpty ? "Empty" : "Deleted songs available")
                }
            }
            .navigationDestination(isPresented: $trashBinPresented) {
                TrashBinView()
            }
            .fileImporter(
                isPresented: $fileImporterPresented,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
        .alert(
            "Delete this song?",
            isPresented: Binding(
                get: { pendingDeleteProject != nil },
                set: { if !$0 { pendingDeleteProject = nil } }
            ),
            presenting: pendingDeleteProject
        ) { project in
            Button("Cancel", role: .cancel) {
                pendingDeleteProject = nil
            }
            Button("Move to Trash", role: .destructive) {
                viewModel.moveProjectToTrash(project)
                pendingDeleteProject = nil
            }
        } message: { project in
            Text("\"\(project.title.isEmpty ? "Untitled Song" : project.title)\" will move to Trash Bin and be fully deleted after 30 days.")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let exported = try LyricsExporter.decodeJsonExport(data)
                viewModel.importProject(exported)
                dismiss()
            } catch {
                importError = "Could not import this file. Pick a RhymeAI project JSON."
            }
        case .failure:
            importError = "Could not open the selected file."
        }
    }

    private var trashToolbarLabel: some View {
        Image(systemName: "trash")
    }
}

#Preview {
    ProjectsView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: [SongProject.self, TrashedSongProject.self], inMemory: true)
}
