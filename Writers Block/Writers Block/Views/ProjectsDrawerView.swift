import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private let projectDrawerAnimationDuration: TimeInterval = RhymeAITokens.Motion.presentationDuration

struct ProjectsDrawerView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var viewModel: EditorViewModel
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]
    @Query(sort: \TrashedSongProject.deletedAt, order: .reverse) private var trashedProjects: [TrashedSongProject]
    @State private var searchText = ""
    @State private var fileImporterPresented = false
    @State private var importError: String?
    @State private var drawerVisible = false
    @State private var isClosing = false
    @State private var pendingDeleteProject: SongProject?
    @State private var trashBinPresented = false
    @State private var activeTab: DrawerTab = .songs
    // Recordings list is refreshed on appear and after delete/rename.
    @State private var allRecordings: [RecordingItem] = []
    // Rename alert state — non-nil means the alert is showing.
    @State private var renamingItem: RecordingItem?
    @State private var renameText: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum DrawerTab: String, CaseIterable {
        case songs = "Songs"
        case recordings = "Recordings"
    }

    // Flat list of every memo URL plus resolved project title.
    private struct RecordingItem: Identifiable {
        let id: String          // memo URL absoluteString
        let url: URL
        let projectId: String
        let projectTitle: String // "Deleted song" when projectId not in SwiftData
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
        ZStack {
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
                        .background(Color(UIColor.systemBackground).opacity(0.88))
                        .shadow(color: .black.opacity(0.35), radius: 26, x: 10, y: 0)
                        .offset(x: drawerVisible ? 0 : -drawerWidth)
                }
                .rhymeAnimation(RhymeAITokens.Motion.presentation, value: drawerVisible)
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

    private func drawerContent(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        let resolvedTopInset = topInset > 0 ? topInset : 45

        return VStack(alignment: .leading, spacing: 0) {
            // Top bar: search/close + tab picker
            HStack(spacing: RhymeAITokens.Spacing.xs) {
                if activeTab == .songs {
                    searchField
                } else {
                    // No search on Recordings tab — title serves as context
                    Text("Recordings")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

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

            // Tab picker — spans Songs and Recordings
            Picker("Tab", selection: $activeTab) {
                ForEach(DrawerTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, RhymeAITokens.Spacing.sm)

            if activeTab == .songs {
                songsTabContent
            } else {
                recordingsTabContent
            }
        }
        .padding(.horizontal, RhymeAITokens.Spacing.lg)
        .padding(.top, resolvedTopInset + RhymeAITokens.Spacing.sm)
        .padding(.bottom, bottomInset + RhymeAITokens.Spacing.lg)
        .onAppear { reloadRecordings() }
    }

    // MARK: - Songs Tab

    private var songsTabContent: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                .frame(height: RhymeAITokens.Spacing.xxl)
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
                    trashBinPresented = true
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
                    .foregroundStyle(.red)
                    .padding(.top, RhymeAITokens.Spacing.xs)
            }
        }
    }

    // MARK: - Recordings Tab

    private var recordingsTabContent: some View {
        ScrollView {
            LazyVStack(spacing: RhymeAITokens.Spacing.sm) {
                if allRecordings.isEmpty {
                    emptyState(systemImage: "mic.slash", title: "No recordings yet.")
                        .padding(.top, RhymeAITokens.Spacing.md)
                } else {
                    ForEach(allRecordings) { item in
                        recordingRow(item)
                    }
                }
            }
            .padding(.top, RhymeAITokens.Spacing.md)
            .padding(.bottom, RhymeAITokens.Spacing.sm)
        }
        // Rename alert — presented when renamingItem is non-nil.
        .alert("Rename Recording", isPresented: Binding(
            get: { renamingItem != nil },
            set: { if !$0 { renamingItem = nil } }
        )) {
            TextField("Name", text: $renameText)
                .autocorrectionDisabled()
            Button("Rename") {
                if let item = renamingItem {
                    _ = try? viewModel.voiceMemoService.renameMemo(at: item.url, to: renameText)
                    reloadRecordings()
                }
                renamingItem = nil
            }
            Button("Cancel", role: .cancel) {
                renamingItem = nil
            }
        } message: {
            Text("Enter a new name for this recording.")
        }
    }

    private func recordingRow(_ item: RecordingItem) -> some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            // Play / pause
            PlayPauseButton(url: item.url, service: viewModel.voiceMemoService)

            // Song title + date / display name
            Button {
                // Load the song so the user can edit it after tapping the row
                if let project = projects.first(where: { $0.id == item.projectId }) {
                    viewModel.loadProject(project)
                    closeDrawer()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.projectTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(displayLabel(url: item.url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.rhymePress)
            .disabled(item.projectTitle == "Deleted song")

            // Delete
            Button(role: .destructive) {
                viewModel.voiceMemoService.deleteMemo(at: item.url)
                reloadRecordings()
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.red.opacity(0.75))
                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
            }
            .buttonStyle(.rhymePress)
            .accessibilityLabel("Delete recording")
        }
        .padding(.horizontal, RhymeAITokens.Spacing.sm)
        .padding(.vertical, RhymeAITokens.Spacing.xs)
        .liquidGlassSurface(
            cornerRadius: RhymeAITokens.Radius.sm,
            tint: .white.opacity(0.03),
            fallbackOpacity: 0.05
        )
        // Swipe from leading edge to rename.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                let stem = item.url.deletingPathExtension().lastPathComponent
                // Pre-fill with existing custom name or empty for timestamps.
                renameText = isTimestampStem(stem) ? "" : stem
                renamingItem = item
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.indigo)
        }
    }

    /// True when the stem is a pure millisecond-epoch timestamp (all digits,
    /// 13 chars — matches the `VoiceMemoService.newMemoURL` naming scheme).
    private func isTimestampStem(_ stem: String) -> Bool {
        stem.count == 13 && stem.allSatisfy(\.isNumber)
    }

    /// Display label beneath the project title in a recording row.
    /// Shows the custom display name when it isn't a raw timestamp; otherwise
    /// falls back to the human-readable date string.
    private func displayLabel(url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if isTimestampStem(stem) {
            return formattedDate(url: url)
        }
        return stem
    }

    private func formattedDate(url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let ms = Double(stem) {
            let date = Date(timeIntervalSince1970: ms / 1000)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return stem
    }

    private func reloadRecordings() {
        // Build a lookup from projectId → display title using the SwiftData query
        // results. Unknown IDs (orphaned memos from deleted songs) show "Deleted song".
        let titleMap = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.title.isEmpty ? "Untitled Song" : $0.title) })
        let root = VoiceMemoService.memosRoot()

        guard let subfolders = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            allRecordings = []
            return
        }

        var items: [RecordingItem] = []
        for folder in subfolders {
            let projectId = folder.lastPathComponent
            let title = titleMap[projectId] ?? "Deleted song"
            let memos = VoiceMemoService.memos(for: projectId)
            for url in memos {
                items.append(RecordingItem(
                    id: url.absoluteString,
                    url: url,
                    projectId: projectId,
                    projectTitle: title
                ))
            }
        }
        // Newest first — filenames are ms timestamps so descending sort works directly
        allRecordings = items.sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
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
                pendingDeleteProject = project
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red.opacity(0.85))
                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.rhymePress)
            .accessibilityLabel("Delete \(project.title.isEmpty ? "Untitled Song" : project.title)")
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
        guard !isClosing else { return }
        isClosing = true
        withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
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

// MARK: - Play / Pause Helper

// Isolated view so each recording row tracks its own playing state independently.
// The service serialises playback — tapping a second row stops the first — so the
// worst case is one extra render cycle where both rows show "playing".
private struct PlayPauseButton: View {
    let url: URL
    let service: VoiceMemoService

    @State private var rowIsPlaying = false

    var body: some View {
        Button {
            rowIsPlaying.toggle()
            service.togglePlayback(url: url)
        } label: {
            Image(systemName: rowIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(rowIsPlaying ? .red : .accentColor)
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
        }
        .accessibilityLabel(rowIsPlaying ? "Pause recording" : "Play recording")
    }
}

#Preview {
    ProjectsDrawerView(isPresented: .constant(true))
        .environmentObject(EditorViewModel())
        .modelContainer(for: [SongProject.self, TrashedSongProject.self], inMemory: true)
}
