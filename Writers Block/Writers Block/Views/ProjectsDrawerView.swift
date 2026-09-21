import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private let projectDrawerDismissDuration: TimeInterval = RhymeAITokens.Motion.feedbackDuration

enum ProjectsDrawerPresentation {
    case overlay
    case persistentSidebar
    case transientSidebar

    var isSidebar: Bool {
        self != .overlay
    }

    var dismissesAfterNavigation: Bool {
        self != .persistentSidebar
    }
}

struct ProjectsDrawerView: View {
    @Binding var isPresented: Bool
    let presentation: ProjectsDrawerPresentation
    let onOpenTrash: (() -> Void)?
    @EnvironmentObject private var viewModel: EditorViewModel
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]
    @Query(sort: \TrashedSongProject.deletedAt, order: .reverse) private var trashedProjects: [TrashedSongProject]
    @State private var searchText = ""
    @State private var fileImporterPresented = false
    @State private var importError: String?
    @State private var drawerVisible = false
    @State private var isClosing = false
    @State private var undoToast: UndoToast?
    @State private var trashBinPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance

    init(
        isPresented: Binding<Bool>,
        presentation: ProjectsDrawerPresentation = .overlay,
        onOpenTrash: (() -> Void)? = nil
    ) {
        _isPresented = isPresented
        self.presentation = presentation
        self.onOpenTrash = onOpenTrash
    }

    private struct UndoToast: Identifiable {
        let id = UUID()
        let message: String
        let undo: () -> Void
    }

    private func showUndoToast(_ message: String, undo: @escaping () -> Void) {
        withRhymeAnimation(RhymeAITokens.Motion.feedback, reduceMotion: reduceMotion) {
            undoToast = UndoToast(message: message, undo: undo)
        }
    }

    private func undoToastView(_ toast: UndoToast) -> some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            Text(toast.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: RhymeAITokens.Spacing.sm)
            Button("Undo") {
                toast.undo()
                withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
                    undoToast = nil
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(appearance.palette.action)
            .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
        }
        .padding(.horizontal, RhymeAITokens.Spacing.lg)
        .padding(.vertical, RhymeAITokens.Spacing.sm)
        .frame(minHeight: RhymeAITokens.Touch.minimum)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, tint: .white.opacity(0.06), fallbackOpacity: 0.14)
        .shadow(color: .black.opacity(0.3), radius: 14, y: 4)
        // Auto-dismiss after 4s; a new toast restarts the clock via its id.
        .task(id: toast.id) {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard undoToast?.id == toast.id else { return }
            withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
                undoToast = nil
            }
        }
    }

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
        Group {
            if presentation.isSidebar {
                sidebarSurface
            } else {
                overlaySurface
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

    private var overlaySurface: some View {
        ZStack {
            GeometryReader { proxy in
                // Full-page drawer: cover the entire width instead of the 3/4 panel.
                let drawerWidth = proxy.size.width

                ZStack(alignment: .leading) {
                    Color.black.opacity(drawerVisible ? 0.42 : 0)
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }

                    drawerContent(topInset: proxy.safeAreaInsets.top, bottomInset: proxy.safeAreaInsets.bottom)
                        .frame(width: drawerWidth)
                        .frame(maxHeight: .infinity)
                        .background(AppWritingBackground())
                        .shadow(color: .black.opacity(0.35), radius: 26, x: 10, y: 0)
                        // Push-style reveal: while the trash screen slides in from
                        // the right, the drawer slides toward the left like a
                        // navigation push instead of sitting still under an overlay.
                        .offset(x: drawerVisible ? (trashBinPresented ? -proxy.size.width * 0.3 : 0) : -drawerWidth)
                }
            }
            .ignoresSafeArea()

            if trashBinPresented {
                TrashBinView(onDismiss: {
                    withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
                        trashBinPresented = false
                    }
                })
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(2)
            }

            if let toast = undoToast {
                undoToastView(toast)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, RhymeAITokens.Spacing.lg)
                    .padding(.bottom, RhymeAITokens.Spacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                withRhymeAnimation(RhymeAITokens.Motion.presentation, reduceMotion: reduceMotion) {
                    drawerVisible = true
                }
            }
        }
    }

    private var sidebarSurface: some View {
        GeometryReader { proxy in
            ZStack {
                drawerContent(
                    topInset: proxy.safeAreaInsets.top,
                    bottomInset: proxy.safeAreaInsets.bottom
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let toast = undoToast {
                    undoToastView(toast)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.horizontal, RhymeAITokens.Spacing.md)
                        .padding(
                            .bottom,
                            RhymeAITokens.Touch.minimum + RhymeAITokens.Spacing.xl
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(AppWritingBackground())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ipadProjectsSidebar")
    }

    private func drawerContent(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let resolvedTopInset = topInset > 0 ? topInset : 45

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: RhymeAITokens.Spacing.sm) {
                searchField

                Button(action: closeDrawer) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Close drawer")
            }
                .padding(.top, RhymeAITokens.Spacing.lg)

            songsTabContent
        }
        .padding(.horizontal, RhymeAITokens.Spacing.lg)
        .padding(.top, resolvedTopInset + RhymeAITokens.Spacing.sm)
        .padding(.bottom, bottomInset + RhymeAITokens.Spacing.lg)

    }

    // MARK: - Songs Tab

    private var songsTabContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                viewModel.newProject()
                dismissAfterNavigation()
            } label: {
                HStack(spacing: RhymeAITokens.Spacing.sm) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                    Text("Create New Song")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(appearance.palette.onAction)
                .frame(maxWidth: .infinity)
                .frame(height: RhymeAITokens.Spacing.xxl)
                .appearanceActionSurface(cornerRadius: RhymeAITokens.Radius.lg)
            }
            .buttonStyle(.rhymePress)
            .padding(.top, RhymeAITokens.Spacing.md)

            Text("Recent Songs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, RhymeAITokens.Spacing.md)
                .padding(.bottom, RhymeAITokens.Spacing.xs)

            ScrollView {
                LazyVStack(spacing: RhymeAITokens.Spacing.sm) {
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

            HStack(spacing: RhymeAITokens.Spacing.sm) {
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

                Button {
                    viewModel.purgeExpiredTrashedProjects()
                    undoToast = nil
                    if let onOpenTrash {
                        onOpenTrash()
                    } else {
                        withRhymeAnimation(RhymeAITokens.Motion.presentation, reduceMotion: reduceMotion) {
                            trashBinPresented = true
                        }
                    }
                } label: {
                    trashBinButtonLabel
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Open Trash Bin")
                .accessibilityValue(trashedProjects.isEmpty ? "Empty" : "Deleted songs available")
            }

            if let importError {
                Text(importError)
                    .font(.caption)
                    .foregroundStyle(appearance.palette.error)
                    .padding(.top, RhymeAITokens.Spacing.xs)
            }
        }
    }

    private var trashBinButtonLabel: some View {
        Image(systemName: "trash")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, interactive: true)
    }

    private var searchField: some View {
        HStack(spacing: RhymeAITokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                "",
                text: $searchText,
                prompt: Text("Search songs")
                    .foregroundStyle(appearance.palette.placeholder)
            )
                .textInputAutocapitalization(.never)
                .foregroundStyle(appearance.palette.primaryInk)

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
        .padding(.horizontal, RhymeAITokens.Spacing.sm)
        .frame(height: RhymeAITokens.Touch.minimum)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, interactive: true)
    }

    private func projectRow(_ project: SongProject) -> some View {
        let isActive = viewModel.currentProjectId == project.id

        return HStack(spacing: RhymeAITokens.Spacing.xs) {
            Button {
                viewModel.loadProject(project)
                dismissAfterNavigation()
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
                            .foregroundStyle(appearance.palette.action)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.rhymePress)

            Button(role: .destructive) {
                let title = project.title.isEmpty ? "Untitled Song" : project.title
                let projectId = project.id
                guard viewModel.moveProjectToTrash(project) else { return }
                showUndoToast("\u{201c}\(title)\u{201d} moved to Trash") {
                    if let trashed = trashedProjects.first(where: { $0.id == projectId }) {
                        viewModel.restoreTrashedProject(trashed)
                    }
                }
            } label: {
                Image(systemName: "trash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.palette.error.opacity(0.85))
                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.rhymePress)
            .accessibilityLabel("Move \(project.title.isEmpty ? "Untitled Song" : project.title) to Trash")
        }
        .frame(minHeight: 76)
        .padding(.vertical, RhymeAITokens.Spacing.sm)
        .padding(.leading, RhymeAITokens.Spacing.md)
        .padding(.trailing, RhymeAITokens.Spacing.xs)
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
        if presentation.isSidebar {
            isPresented = false
            return
        }

        guard !isClosing else { return }
        isClosing = true
        withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
            drawerVisible = false
        }
        let removalDelay = reduceMotion ? 0 : projectDrawerDismissDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + removalDelay) {
            isPresented = false
        }
    }

    private func dismissAfterNavigation() {
        guard presentation.dismissesAfterNavigation else { return }
        closeDrawer()
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
                if viewModel.importProject(exported) {
                    dismissAfterNavigation()
                }
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
        .modelContainer(for: [SongProject.self, TrashedSongProject.self], inMemory: true)
}
