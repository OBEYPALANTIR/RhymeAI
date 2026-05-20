import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private let projectDrawerAnimationDuration: TimeInterval = RhymeAITokens.Motion.presentationDuration

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
            let drawerWidth = min(max(proxy.size.width - RhymeAITokens.Layout.drawerHorizontalMargin, RhymeAITokens.Layout.drawerMinWidth), RhymeAITokens.Layout.drawerMaxWidth)

            ZStack(alignment: .leading) {
                Color.black.opacity(drawerVisible ? 0.42 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer() }

                drawerContent(topInset: proxy.safeAreaInsets.top, bottomInset: proxy.safeAreaInsets.bottom)
                    .frame(width: drawerWidth)
                    .frame(maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .background(Color.black.opacity(0.28))
                    .shadow(color: .black.opacity(0.35), radius: 26, x: 10, y: 0)
                    .offset(x: drawerVisible ? 0 : -drawerWidth)
            }
            .animation(RhymeAITokens.Motion.presentation, value: drawerVisible)
        }
        .ignoresSafeArea()
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

    private func drawerContent(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let resolvedTopInset = topInset > 0 ? topInset : 45

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: RhymeAITokens.Spacing.xs) {
                searchField

                Button {
                    closeDrawer()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Close drawer")
            }
            .padding(.top, RhymeAITokens.Spacing.lg)

            Button {
                viewModel.newProject()
                closeDrawer()
            } label: {
                HStack(spacing: RhymeAITokens.Spacing.sm) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                    Text("Create New Song")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, tint: .indigo.opacity(0.10), interactive: true)
            }
            .buttonStyle(.rhymePress)
            .padding(.top, RhymeAITokens.Spacing.md)

            Text("Recent Songs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, RhymeAITokens.Spacing.md)
                .padding(.bottom, RhymeAITokens.Spacing.xs)

            ScrollView {
                LazyVStack(spacing: RhymeAITokens.Spacing.xs) {
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
                .padding(.bottom, RhymeAITokens.Spacing.sm)
            }

            Button {
                importError = nil
                fileImporterPresented = true
            } label: {
                HStack(spacing: RhymeAITokens.Spacing.xs) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import From File")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: RhymeAITokens.Touch.minimum)
                .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, interactive: true)
            }
            .buttonStyle(.rhymePress)

            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, RhymeAITokens.Spacing.xs)
            }
        }
        .padding(.horizontal, RhymeAITokens.Spacing.lg)
        .padding(.top, resolvedTopInset + RhymeAITokens.Spacing.sm)
        .padding(.bottom, bottomInset + RhymeAITokens.Spacing.lg)
        .liquidGlassGroup(spacing: RhymeAITokens.Spacing.lg)
    }

    private var searchField: some View {
        HStack(spacing: RhymeAITokens.Spacing.xs) {
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
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, RhymeAITokens.Spacing.sm)
        .frame(height: RhymeAITokens.Touch.minimum)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, interactive: true)
    }

    private func projectRow(_ project: SongProject) -> some View {
        let isActive = viewModel.currentProjectId == project.id

        return HStack(spacing: RhymeAITokens.Spacing.xs) {
            Button {
                viewModel.loadProject(project)
                closeDrawer()
            } label: {
                HStack(spacing: RhymeAITokens.Spacing.sm) {
                    VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                        Text(project.title.isEmpty ? "Untitled Song" : project.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: RhymeAITokens.Spacing.xs) {
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
            .buttonStyle(.rhymePress)

            Button(role: .destructive) {
                viewModel.deleteProject(project)
            } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.rhymePress)
            .accessibilityLabel("Delete \(project.title.isEmpty ? "Untitled Song" : project.title)")
        }
        .padding(.vertical, RhymeAITokens.Spacing.sm)
        .padding(.leading, RhymeAITokens.Spacing.md)
        .padding(.trailing, RhymeAITokens.Spacing.xs)
        .liquidGlassSurface(
            cornerRadius: RhymeAITokens.Radius.lg,
            tint: isActive ? .indigo.opacity(0.16) : .white.opacity(0.03),
            fallbackOpacity: isActive ? 0.12 : 0.05
        )
    }

    private func emptyState(systemImage: String, title: String) -> some View {
        VStack(spacing: RhymeAITokens.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary.opacity(0.7))
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RhymeAITokens.Touch.minimum)
    }

    private func closeDrawer() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(RhymeAITokens.Motion.dismiss) {
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
