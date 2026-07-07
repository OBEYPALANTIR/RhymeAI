import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private let projectDrawerDismissDuration: TimeInterval = RhymeAITokens.Motion.feedbackDuration

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
    // Recordings folders refresh when the Recordings tab is shown and after delete/rename.
    @State private var recordingFolders: [RecordingFolder] = []
    @State private var expandedFolders: Set<String> = []
    @State private var isSelectingRecordings = false
    @State private var selectedRecordingIDs: Set<String> = []
    @State private var pendingBulkDelete = false
    // Rename alert state — non-nil means the alert is showing.
    @State private var renamingItem: RecordingItem?
    @State private var renameText: String = ""
    @State private var pendingDeleteRecording: RecordingItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum DrawerTab: String, CaseIterable {
        case songs = "Songs"
        case recordings = "Recordings"
    }

    // Flat memo URL plus resolved project title, used inside a grouped folder.
    nonisolated private struct RecordingItem: Identifiable, Sendable {
        let id: String          // memo URL absoluteString
        let url: URL
        let projectId: String
        let projectTitle: String // "Deleted song" when projectId not in SwiftData
    }

    nonisolated private struct RecordingFolder: Identifiable, Sendable {
        let id: String          // projectId
        let title: String
        let items: [RecordingItem]
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

    private var filteredRecordingFolders: [RecordingFolder] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recordingFolders }

        return recordingFolders.compactMap { folder in
            if folder.title.localizedCaseInsensitiveContains(query) {
                return folder
            }

            let matchingItems = folder.items.filter { item in
                displayLabel(url: item.url).localizedCaseInsensitiveContains(query)
            }

            return matchingItems.isEmpty
                ? nil
                : RecordingFolder(id: folder.id, title: folder.title, items: matchingItems)
        }
    }

    var body: some View {
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
                        .background(.ultraThinMaterial)
                        .background(Color(UIColor.systemBackground).opacity(0.88))
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
        }
        .onAppear {
            DispatchQueue.main.async {
                withRhymeAnimation(RhymeAITokens.Motion.presentation, reduceMotion: reduceMotion) {
                    drawerVisible = true
                }
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
            // Full-width search; the trailing X inside the field clears the query
            // while typing and closes the drawer when the field is empty.
            searchField
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
        .onChange(of: activeTab) { _, tab in
            if tab == .recordings {
                reloadRecordings()
            }
        }
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
                    withRhymeAnimation(RhymeAITokens.Motion.presentation, reduceMotion: reduceMotion) {
                        trashBinPresented = true
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
                    .foregroundStyle(.red)
                    .padding(.top, RhymeAITokens.Spacing.xs)
            }
        }
    }

    // MARK: - Recordings Tab

    private var recordingsTabContent: some View {
        Group {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filteredRecordingFolders.isEmpty {
                ScrollView {
                    emptyState(systemImage: "magnifyingglass", title: "No recordings match your search.")
                        .padding(.top, RhymeAITokens.Spacing.md)
                }
            } else if recordingFolders.isEmpty {
                ScrollView {
                    emptyState(systemImage: "mic.slash", title: "No recordings yet.")
                        .padding(.top, RhymeAITokens.Spacing.md)
                }
            } else {
                VStack(spacing: RhymeAITokens.Spacing.xs) {
                    HStack {
                        Spacer()
                        if isSelectingRecordings {
                            Button("Cancel") {
                                isSelectingRecordings = false
                                selectedRecordingIDs = []
                            }
                            .buttonStyle(.rhymePress)

                            Button("Delete (\(selectedRecordingIDs.count))", role: .destructive) {
                                pendingBulkDelete = true
                            }
                            .buttonStyle(.rhymePress)
                            .disabled(selectedRecordingIDs.isEmpty)
                        } else {
                            Button("Select") {
                                isSelectingRecordings = true
                            }
                            .buttonStyle(.rhymePress)
                        }
                    }
                    .padding(.horizontal, RhymeAITokens.Spacing.xs)

                    List {
                        ForEach(filteredRecordingFolders) { folder in
                            Section {
                                folderHeaderRow(folder)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)

                                if isRecordingFolderExpanded(folder) {
                                    ForEach(folder.items) { item in
                                        recordingRow(
                                            item,
                                            isSelecting: isSelectingRecordings,
                                            isSelected: selectedRecordingIDs.contains(item.id),
                                            onSelectionChanged: { selected in
                                                if selected {
                                                    selectedRecordingIDs.insert(item.id)
                                                } else {
                                                    selectedRecordingIDs.remove(item.id)
                                                }
                                            }
                                        )
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                pendingDeleteRecording = item
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .alert("Recording Error", isPresented: Binding(
            get: { viewModel.voiceMemoService.lastError != nil },
            set: { if !$0 { viewModel.voiceMemoService.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.voiceMemoService.lastError = nil }
        } message: {
            Text(viewModel.voiceMemoService.lastError ?? "")
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
                    do {
                        try viewModel.voiceMemoService.renameMemo(at: item.url, to: renameText)
                        reloadRecordings()
                    } catch {
                        viewModel.voiceMemoService.lastError = "Couldn't rename recording: \(error.localizedDescription)"
                    }
                }
                renamingItem = nil
            }
            Button("Cancel", role: .cancel) {
                renamingItem = nil
            }
        } message: {
            Text("Enter a new name for this recording.")
        }
        .confirmationDialog("Delete Recording?", isPresented: Binding(
            get: { pendingDeleteRecording != nil },
            set: { if !$0 { pendingDeleteRecording = nil } }
        ), titleVisibility: .visible, presenting: pendingDeleteRecording) { item in
            Button("Move to Trash", role: .destructive) {
                viewModel.voiceMemoService.trashMemo(at: item.url, projectId: item.projectId)
                reloadRecordings()
                pendingDeleteRecording = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteRecording = nil }
        } message: { _ in
            Text("This recording will move to Trash Bin and be fully deleted after 30 days.")
        }
        .confirmationDialog("Delete Recordings?", isPresented: $pendingBulkDelete, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                let selectedIDs = selectedRecordingIDs
                recordingFolders
                    .flatMap(\.items)
                    .filter { selectedIDs.contains($0.id) }
                    .forEach { viewModel.voiceMemoService.trashMemo(at: $0.url, projectId: $0.projectId) }
                pendingBulkDelete = false
                isSelectingRecordings = false
                selectedRecordingIDs = []
                reloadRecordings()
            }
            Button("Cancel", role: .cancel) { pendingBulkDelete = false }
        } message: {
            Text("\(selectedRecordingIDs.count) recordings will move to Trash Bin and be fully deleted after 30 days.")
        }
    }

    private var isSearchingRecordings: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isRecordingFolderExpanded(_ folder: RecordingFolder) -> Bool {
        isSearchingRecordings || expandedFolders.contains(folder.id)
    }

    private func folderHeaderRow(_ folder: RecordingFolder) -> some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                Text(folder.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(folder.title == "Deleted song" ? .secondary : .primary)
                    .lineLimit(1)
                Text("\(folder.items.count) \(folder.items.count == 1 ? "recording" : "recordings")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: isRecordingFolderExpanded(folder) ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: RhymeAITokens.Touch.comfortable)
        .padding(.vertical, RhymeAITokens.Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(reduceMotion ? nil : RhymeAITokens.Motion.expressive) {
                if expandedFolders.contains(folder.id) {
                    expandedFolders.remove(folder.id)
                } else {
                    expandedFolders.insert(folder.id)
                }
            }
        }
    }

    private func recordingRow(
        _ item: RecordingItem,
        isSelecting: Bool,
        isSelected: Bool,
        onSelectionChanged: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            if isSelecting {
                Button {
                    onSelectionChanged(!isSelected)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? .red : .secondary)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel(isSelected ? "Deselect recording" : "Select recording")
            }

            PlayPauseButton(url: item.url, service: viewModel.voiceMemoService)

            Text(displayLabel(url: item.url))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                let stem = item.url.deletingPathExtension().lastPathComponent
                renameText = isTimestampStem(stem) ? "" : stem
                renamingItem = item
            } label: {
                Image(systemName: "pencil")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
            }
            .buttonStyle(.rhymePress)
            .accessibilityLabel("Rename recording")
        }
        .padding(.vertical, RhymeAITokens.Spacing.xxs)
        .padding(.leading, RhymeAITokens.Spacing.md)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                onSelectionChanged(!isSelected)
            }
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

    private static let recordingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func formattedDate(url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let ms = Double(stem) {
            let date = Date(timeIntervalSince1970: ms / 1000)
            return Self.recordingDateFormatter.string(from: date)
        }
        return stem
    }

    private func reloadRecordings() {
        // Snapshot SwiftData-backed project titles on the main actor before
        // doing file-system work in a detached task.
        let titleMap = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.title.isEmpty ? "Untitled Song" : $0.title) })
        let root = VoiceMemoService.memosRoot()

        Task {
            let folders = await Task.detached(priority: .userInitiated) { () -> [RecordingFolder] in
                guard let subfolders = try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                ) else {
                    return []
                }

                var folders: [RecordingFolder] = []
                for folder in subfolders {
                    let projectId = folder.lastPathComponent
                    let memos = VoiceMemoService.memos(for: projectId)
                    guard !memos.isEmpty else { continue }
                    let title = titleMap[projectId] ?? "Deleted song"
                    let items = memos
                        .map {
                            RecordingItem(
                                id: $0.absoluteString,
                                url: $0,
                                projectId: projectId,
                                projectTitle: title
                            )
                        }
                        .sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
                    folders.append(RecordingFolder(id: projectId, title: title, items: items))
                }

                return folders.sorted {
                    ($0.items.first?.url.lastPathComponent ?? "") > ($1.items.first?.url.lastPathComponent ?? "")
                }
            }.value

            await MainActor.run {
                recordingFolders = folders
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

            TextField(activeTab == .songs ? "Search songs" : "Search recordings", text: $searchText)
                .textInputAutocapitalization(.never)
                .foregroundStyle(.primary)

            Button {
                if searchText.isEmpty {
                    closeDrawer()
                } else {
                    searchText = ""
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.rhymePress)
            .accessibilityLabel(searchText.isEmpty ? "Close drawer" : "Clear search")
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
        let removalDelay = reduceMotion ? 0 : projectDrawerDismissDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + removalDelay) {
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
