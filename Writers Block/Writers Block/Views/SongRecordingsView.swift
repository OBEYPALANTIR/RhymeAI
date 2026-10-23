import SwiftUI
import UniformTypeIdentifiers

/// The song identity is captured when this sheet opens, including during file picking.
struct SongRecordingsView: View {
    let projectId: String
    let projectTitle: String
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance
    @State private var searchText = ""
    @State private var undoToast: UndoToast?
    @State private var fileImporterPresented = false
    @State private var importTask: Task<Void, Never>?
    // Refresh after import, recording completion, rename, and trash changes.
    @State private var recordingFolders: [RecordingFolder] = []
    @State private var expandedFolders: Set<String> = []
    @State private var isSelectingRecordings = false
    @State private var selectedRecordingIDs: Set<String> = []
    @State private var pendingBulkDelete = false
    // Rename alert state — non-nil means the alert is showing.
    @State private var renamingItem: RecordingItem?
    @State private var renameText: String = ""
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
        NavigationStack {
            VStack(spacing: RhymeAITokens.Spacing.sm) {
                searchField
                Button {
                    fileImporterPresented = true
                } label: {
                    Label("Import Recording", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum)
                }
                .disabled(importTask != nil)
                .accessibilityIdentifier("importRecording")
                if importTask != nil {
                    HStack {
                        ProgressView("Importing recording…")
                        Button("Cancel") { importTask?.cancel() }
                    }
                }
                pendingTakesRow
                recordingsTabContent
            }
            .padding(RhymeAITokens.Spacing.lg)
            .background(AppWritingBackground())
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let toast = undoToast { undoToastView(toast).padding() }
            }
        }
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.mpeg4Audio, .mp3, .wav, UTType(filenameExtension: "aac") ?? .audio]) { result in
            switch result {
            case .success(let url):
                importTask = Task {
                    do {
                        _ = try await VoiceMemoService.importMemo(from: url, projectId: projectId, publisher: viewModel.voiceMemoService.publisher)
                        reloadRecordings()
                        viewModel.voiceMemoService.onFilesChanged?()
                    } catch is CancellationError {
                        // Cancelling leaves neither a recording nor a partial file.
                    } catch {
                        viewModel.voiceMemoService.lastError = "Couldn't import this recording. Choose a playable M4A, MP3, WAV, or AAC file and try again."
                    }
                    importTask = nil
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    viewModel.voiceMemoService.lastError = "Couldn't open the selected audio file."
                }
            }
        }
        .onAppear { reloadRecordings() }
        .onChange(of: viewModel.voiceMemoService.isRecording) { _, _ in reloadRecordings() }
        .onChange(of: viewModel.voiceMemoService.publishedRevision) { _, _ in reloadRecordings() }
        .onDisappear {
            importTask?.cancel()
            viewModel.voiceMemoService.stopPlayback()
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
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
            withAnimation(reduceMotion ? nil : RhymeAITokens.Motion.settle) {
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
    /// 13 chars — matches the `RecordingFiles.newMemoURL` naming scheme).
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

    /// Takes that finished but are not saved yet (A27), with Retry.
    @ViewBuilder
    private var pendingTakesRow: some View {
        let waiting = viewModel.voiceMemoService.pendingTakes.filter { $0.projectId == projectId }.count
        let failed = viewModel.voiceMemoService.failedTakes.filter { $0.projectId == projectId }.count
        if failed > 0 {
            Text("\(failed) \(failed == 1 ? "recording" : "recordings") could not be saved; the audio is kept on this device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("failedRecordings")
        }
        if waiting > 0 {
            HStack(spacing: RhymeAITokens.Spacing.sm) {
                Text("\(waiting) \(waiting == 1 ? "recording" : "recordings") waiting to be saved")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Retry") { viewModel.retryPendingRecordings() }
                    .buttonStyle(.rhymePress)
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
                    .accessibilityIdentifier("retryPendingRecordings")
            }
            .accessibilityIdentifier("pendingRecordings")
        }
    }

    private func reloadRecordings() {
        let items = (viewModel.recordingListsSuspended ? [] : RecordingFiles.memos(for: projectId)).map {
            RecordingItem(id: $0.absoluteString, url: $0, projectId: projectId, projectTitle: projectTitle)
        }
        recordingFolders = items.isEmpty ? [] : [RecordingFolder(id: projectId, title: projectTitle, items: items)]
        expandedFolders = [projectId]
    }

    private var searchField: some View {
        HStack(spacing: RhymeAITokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                "",
                text: $searchText,
                prompt: Text("Search recordings")
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

}

// MARK: - Play / Pause Helper

// Observe the shared player so every row reflects playback and completion.
private struct PlayPauseButton: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let url: URL
    let service: VoiceMemoService

    private var rowIsPlaying: Bool { service.isPlayingMemo(at: url) }

    var body: some View {
        Button {
            service.togglePlayback(url: url)
        } label: {
            Image(systemName: rowIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundStyle(rowIsPlaying ? appearance.palette.recording : appearance.palette.action)
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
        }
        .buttonStyle(.rhymePress)
        .disabled(service.isRecording)
        .accessibilityLabel(rowIsPlaying ? "Pause recording" : "Play recording")
    }
}
