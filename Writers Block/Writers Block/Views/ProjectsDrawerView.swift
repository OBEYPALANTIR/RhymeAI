import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private let projectDrawerAnimationDuration: TimeInterval = 0.26

struct ProjectsDrawerView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var viewModel: EditorViewModel
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]
    @State private var searchText = ""
    @State private var fileImporterPresented = false
    @State private var importError: String?
    @State private var drawerVisible = false
    @State private var isClosing = false

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
        GeometryReader { proxy in
            let drawerWidth = min(max(proxy.size.width - 36, 300), 360)

            ZStack(alignment: .leading) {
                Color.black.opacity(drawerVisible ? 0.42 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer() }

                drawerContent
                    .frame(width: drawerWidth)
                    .frame(maxHeight: .infinity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 26, x: 10, y: 0)
                    .offset(x: drawerVisible ? 0 : -drawerWidth)
            }
            .animation(.easeInOut(duration: projectDrawerAnimationDuration), value: drawerVisible)
        }
        .onAppear {
            DispatchQueue.main.async {
                drawerVisible = true
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

    private var drawerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                searchField

                Button {
                    closeDrawer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close drawer")
            }
            .padding(.top, 18)

            Button {
                viewModel.newProject()
                closeDrawer()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                    Text("Create New Song")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .liquidGlassSurface(cornerRadius: 16, tint: .indigo.opacity(0.10), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.top, 14)

            Text("Recent Songs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 22)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if projects.isEmpty {
                        emptyState(systemImage: "music.note", title: "No saved songs yet.")
                    } else if filteredProjects.isEmpty {
                        emptyState(systemImage: "magnifyingglass", title: "No songs match your search.")
                    } else {
                        ForEach(filteredProjects, id: \.id) { project in
                            projectRow(project)
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            Button {
                importError = nil
                fileImporterPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import From File")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .liquidGlassSurface(cornerRadius: 16, interactive: true)
            }
            .buttonStyle(.plain)

            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .safeAreaPadding(.top, 4)
        .safeAreaPadding(.bottom, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search songs", text: $searchText)
                .textInputAutocapitalization(.never)
                .foregroundStyle(.primary)

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
        .padding(.horizontal, 12)
        .frame(height: 46)
        .liquidGlassSurface(cornerRadius: 16, interactive: true)
    }

    private func projectRow(_ project: SongProject) -> some View {
        let isActive = viewModel.currentProjectId == project.id

        return HStack(spacing: 8) {
            Button {
                viewModel.loadProject(project)
                closeDrawer()
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.title.isEmpty ? "Untitled Song" : project.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(project.updatedAt, style: .date)
                            Text("·")
                            Text("\(SyllableCounter.wordCount(project.lyrics)) words")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.indigo)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                viewModel.deleteProject(project)
            } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(project.title.isEmpty ? "Untitled Song" : project.title)")
        }
        .padding(.vertical, 12)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isActive ? Color.indigo.opacity(0.18) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isActive ? Color.indigo.opacity(0.6) : Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func emptyState(systemImage: String, title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary.opacity(0.7))
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private func closeDrawer() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(.easeInOut(duration: projectDrawerAnimationDuration)) {
            drawerVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + projectDrawerAnimationDuration) {
            isPresented = false
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
                closeDrawer()
            } catch {
                importError = "Could not import this file. Pick a RhymeAI project JSON."
            }
        case .failure:
            importError = "Could not open the selected file."
        }
    }
}

#Preview {
    ProjectsDrawerView(isPresented: .constant(true))
        .environmentObject(EditorViewModel())
        .modelContainer(for: SongProject.self, inMemory: true)
        .preferredColorScheme(.dark)
}
