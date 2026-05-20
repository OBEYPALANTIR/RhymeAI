import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ProjectsView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]
    @State private var searchText = ""
    @State private var fileImporterPresented = false
    @State private var importError: String?

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
                HStack(spacing: 8) {
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
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .liquidGlassSurface(cornerRadius: 12, interactive: true)
                .listRowBackground(Color.clear)

                // New Song button
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
                    .padding(.vertical, 8)
                    .liquidGlassSurface(cornerRadius: 14, tint: .indigo.opacity(0.10), interactive: true)
                }
                .listRowBackground(Color.clear)

                // Import from file
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
                    .padding(.vertical, 8)
                    .liquidGlassSurface(cornerRadius: 14, interactive: true)
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
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.title.isEmpty ? "Untitled Song" : project.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    HStack(spacing: 8) {
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
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(
                            viewModel.currentProjectId == project.id
                                ? Color.indigo.opacity(0.1)
                                : Color.clear
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.deleteProject(project)
                            } label: {
                                Label("Delete", systemImage: "trash")
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
            }
            .fileImporter(
                isPresented: $fileImporterPresented,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
        .preferredColorScheme(.dark)
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
}

#Preview {
    ProjectsView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: SongProject.self, inMemory: true)
}
