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
    @State private var drawerError: String?
    @State private var drawerVisible = false
    @State private var isClosing = false
    @State private var undoToast: UndoToast?
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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

    private struct UndoToast: Identifiable {
        let id = UUID()
        let message: String
        let undo: () -> Void
    }

    nonisolated private struct RecordingFolder: Identifiable, Sendable {
        let id: String          // projectId
        let title: String
        let items: [RecordingItem]
    }

    private func showUndoToast(_ message: String, undo: @escaping () -> Void) {
        withRhymeAnimation(RhymeAITokens.Motion.state, reduceMotion: reduceMotion) {
            undoToast = UndoToast(message: message, undo: undo)
        }
    }

    private func trashRecordingWithUndo(_ item: RecordingItem) {
        guard let trashed = viewModel.voiceMemoService.trashMemo(at: item.url, projectId: item.projectId) else {
            reloadRecordings()
            return
        }
        reloadRecordings()
        showUndoToast("Recording moved to Trash") {
            viewModel.voiceMemoService.restoreTrashedMemo(trashed)
            reloadRecordings()
        }
    }

    private func undoToastView(_ toast: UndoToast) -> some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            Text(toast.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
            Spacer(minLength: RhymeAITokens.Spacing.sm)
            Button {
                withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
                    toast.undo()
                    undoToast = nil
                }
            } label: {
                Text("Undo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.palette.action)
                    .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
            }
            .buttonStyle(.rhymePress)
        }
        .padding(.horizontal, RhymeAITokens.Spacing.lg)
        .padding(.vertical, RhymeAITokens.Spacing.sm)
        .frame(minHeight: RhymeAITokens.Touch.minimum)
        // A toast, not a banner: on iPad it otherwise spans the whole screen.
        .frame(maxWidth: RhymeAITokens.Layout.assistantReadableWidth)
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
                let drawerWidth = overlayPanelWidth(for: proxy.size.width)

                ZStack(alignment: .leading) {
                    // The palette scrim: ink on Ink and Paper, a deeper black on
                    // Graphite, where black at 42% barely set the panel apart.
                    appearance.palette.scrim.opacity(drawerVisible ? 1 : 0)
                        .ignoresSafeArea()
                        // The panel is still off-screen until the open
                        // animation starts on the next run-loop tick; a tap
                        // in that gap must not dismiss a drawer nobody saw.
                        .onTapGesture { if drawerVisible { closeDrawer() } }
                        // VoiceOver reaches the scrim as a close control, as
                        // UIKit does for a popover's dimming view.
                        .accessibilityElement()
                        .accessibilityLabel("Dismiss songs drawer")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { closeDrawer() }

                    drawerContent(topInset: proxy.safeAreaInsets.top, bottomInset: proxy.safeAreaInsets.bottom)
                        .frame(width: drawerWidth)
                        .frame(maxHeight: .infinity)
                        // The background opts out of hit testing, so without a
                        // shape of its own the panel's padding and gaps let taps
                        // fall through to the scrim and dismiss the drawer.
                        .contentShape(Rectangle())
                        // The shadow belongs to the panel surface. Applied to
                        // the content it also rendered under every control,
                        // which read as grey smudges on the light appearances.
                        .background {
                            AppWritingBackground()
                                .shadow(color: .black.opacity(0.35), radius: 26, x: 10, y: 0)
                                // A black shadow vanishes on Graphite's canvas; the
                                // hairline keeps the panel edge in every appearance.
                                .overlay(alignment: .trailing) {
                                    Rectangle()
                                        .fill(appearance.palette.outline)
                                        .frame(width: RhymeAITokens.Spacing.hairline)
                                }
                        }
                        // Push-style reveal: while the trash screen slides in from
                        // the right, the drawer slides toward the left like a
                        // navigation push instead of sitting still under an overlay.
                        .offset(x: drawerVisible ? (trashBinPresented ? -drawerWidth * 0.3 : 0) : -drawerWidth)
                }
            }
            .ignoresSafeArea()
            // The Trash screen covers the drawer; keep VoiceOver from reaching
            // the drawer's controls beneath it.
            .accessibilityHidden(trashBinPresented)

            if trashBinPresented {
                TrashBinView(onDismiss: {
                    withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
                        trashBinPresented = false
                    }
                })
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                .zIndex(2)
            }

            if let toast = undoToast {
                undoToastView(toast)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, RhymeAITokens.Spacing.lg)
                    // Centre the toast on the panel, not the whole window.
                    .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                        overlayPanelWidth(for: width)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Clear the Import / Trash row (44pt plus the panel's
                    // bottom padding) instead of sitting on top of it.
                    .padding(
                        .bottom,
                        RhymeAITokens.Touch.minimum + RhymeAITokens.Spacing.lg + RhymeAITokens.Spacing.sm
                    )
                    .transition(reduceMotion ? .opacity : .offset(y: RhymeAITokens.Spacing.lg).combined(with: .opacity))
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

    /// Full width on compact; on regular width a leading side panel on the
    /// golden split, with the scrim over the rest of the window.
    private func overlayPanelWidth(for windowWidth: CGFloat) -> CGFloat {
        horizontalSizeClass == .regular
            ? RhymeAITokens.Layout.sideColumnWidth(for: windowWidth)
            : windowWidth
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
                        .transition(reduceMotion ? .opacity : .offset(y: RhymeAITokens.Spacing.lg).combined(with: .opacity))
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
                        .foregroundStyle(appearance.palette.secondaryInk)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Close drawer")
            }
                .padding(.top, RhymeAITokens.Spacing.lg)

            // Tab picker — spans Songs and Recordings
            RhymeSegmentedControl(
                options: DrawerTab.allCases,
                selection: $activeTab,
                accessibilityIdentifier: "drawerTabPicker",
                label: "Tab",
                title: \.rawValue
            )
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
                dismissAfterNavigation()
            } label: {
                HStack(spacing: RhymeAITokens.Spacing.sm) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                    Text("Create New Song")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(appearance.palette.onAction)
                .multilineTextAlignment(.center)
                .padding(.vertical, RhymeAITokens.Spacing.xs)
                .padding(.horizontal, RhymeAITokens.Spacing.sm)
                .frame(maxWidth: .infinity)
                .frame(minHeight: RhymeAITokens.Spacing.xxl)
                .appearanceActionSurface(cornerRadius: RhymeAITokens.Radius.lg)
            }
            .buttonStyle(.rhymePress)
            .padding(.top, RhymeAITokens.Spacing.md)

            Text("Recent Songs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.palette.secondaryInk)
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
                    drawerError = nil
                    fileImporterPresented = true
                } label: {
                    HStack(spacing: RhymeAITokens.Spacing.xs) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import From File")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RhymeAITokens.Spacing.xs)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
                    .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, interactive: true)
                }
                .buttonStyle(.rhymePress)

                Button {
                    viewModel.purgeExpiredTrashedProjects()
                    withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
                        undoToast = nil
                    }
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

            if let drawerError = drawerError ?? viewModel.projectDeletionNotice {
                Text(drawerError)
                    .font(.caption)
                    .foregroundStyle(appearance.palette.error)
                    .padding(.top, RhymeAITokens.Spacing.xs)
            }
        }
    }

    // MARK: - Recordings Tab

    /// Text-only toolbar actions still need the minimum touch target.
    private func recordingsToolbarLabel(_ title: String) -> some View {
        Text(title)
            .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
    }

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
                            Button {
                                isSelectingRecordings = false
                                selectedRecordingIDs = []
                            } label: {
                                recordingsToolbarLabel("Cancel")
                            }
                            .buttonStyle(.rhymePress)

                            Button(role: .destructive) {
                                pendingBulkDelete = true
                            } label: {
                                recordingsToolbarLabel("Delete (\(selectedRecordingIDs.count))")
                            }
                            .buttonStyle(.rhymePress)
                            .disabled(selectedRecordingIDs.isEmpty)
                        } else {
                            Button {
                                isSelectingRecordings = true
                            } label: {
                                recordingsToolbarLabel("Select")
                            }
                            .buttonStyle(.rhymePress)
                        }
                    }
                    .padding(.horizontal, RhymeAITokens.Spacing.xs)
                    .padding(.top, RhymeAITokens.Spacing.xs)

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
                                                trashRecordingWithUndo(item)
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
                    .foregroundStyle(appearance.palette.secondaryInk)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(appearance.palette.secondaryInk)
                .rotationEffect(.degrees(isRecordingFolderExpanded(folder) ? 90 : 0))
                .accessibilityHidden(true)
        }
        .frame(minHeight: RhymeAITokens.Touch.comfortable)
        .padding(.vertical, RhymeAITokens.Spacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isRecordingFolderExpanded(folder) ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .onTapGesture {
            withRhymeAnimation(RhymeAITokens.Motion.settle, reduceMotion: reduceMotion) {
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
                        .foregroundStyle(isSelected ? appearance.palette.action : Color.secondary)
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
                    .foregroundStyle(appearance.palette.secondaryInk)
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
        let root = RecordingFiles.memosRoot()

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
                    let memos = RecordingFiles.memos(for: projectId)
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
                .foregroundStyle(appearance.palette.secondaryInk)

            TextField(
                "",
                text: $searchText,
                prompt: Text(activeTab == .songs ? "Search songs" : "Search recordings")
                    .foregroundStyle(appearance.palette.placeholder)
            )
                .textInputAutocapitalization(.never)
                .foregroundStyle(appearance.palette.primaryInk)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(appearance.palette.secondaryInk)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, RhymeAITokens.Spacing.sm)
        .frame(minHeight: RhymeAITokens.Touch.minimum)
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
                            // Three lines at accessibility sizes, as in Trash.
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)

                        // Side by side while both facts fit on one line;
                        // stacked once larger text would squeeze the date
                        // into a hyphenated column.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: RhymeAITokens.Spacing.xs) {
                                Text(project.updatedAt, style: .date)
                                Text("·")
                                    .accessibilityHidden(true)
                                Text("\(SyllableCounter.wordCount(project.lyrics)) words")
                            }
                            .lineLimit(1)
                            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                                Text(project.updatedAt, style: .date)
                                Text("\(SyllableCounter.wordCount(project.lyrics)) words")
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                        .foregroundStyle(appearance.palette.secondaryInk)
                    }
                    .multilineTextAlignment(.leading)

                    Spacer(minLength: 8)

                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(appearance.palette.action)
                    }
                }
                .frame(minHeight: RhymeAITokens.Touch.minimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(.rhymePress)

            Button(role: .destructive) {
                let title = project.title.isEmpty ? "Untitled Song" : project.title
                let projectId = project.id
                let moved = withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
                    viewModel.moveProjectToTrash(project)
                }
                guard moved else {
                    // A refusal during a backup or restore is shown from the view
                    // model's notice, which clears itself when the operation ends.
                    drawerError = viewModel.projectDeletionNotice == nil ? viewModel.errorMessage : nil
                    return
                }
                drawerError = nil
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
                .foregroundStyle(appearance.palette.secondaryInk)
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
                drawerError = "Could not import this file. Pick a RhymeAI project JSON."
            }
        case .failure:
            drawerError = "Could not open the selected file."
        }
    }
}

// MARK: - Play / Pause Helper

// Isolated view so each recording row tracks its own playing state independently.
// The service serialises playback — tapping a second row stops the first — so the
// worst case is one extra render cycle where both rows show "playing".
private struct PlayPauseButton: View {
    @Environment(\.appAppearanceStyle) private var appearance

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
                .foregroundStyle(rowIsPlaying ? appearance.palette.recording : appearance.palette.action)
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
