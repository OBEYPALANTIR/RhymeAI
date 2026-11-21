#if os(macOS)
import Combine
import SwiftUI
import SwiftData

/// The Mac window's own state, shared by the workspace view and the menu bar:
/// what the detail pane shows, which columns are open, and the panels the
/// menus can open. The song itself stays in `EditorViewModel`.
final class MacWorkspaceModel: ObservableObject {
    enum Detail: Hashable {
        /// The open song, or the empty state when none is open.
        case editor
        case oneLiners
        case trash
    }

    @Published var detail: Detail = .editor
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// The writer's choice to show the assistant column; Focus hides it
    /// without changing the choice.
    @Published var showsAssistant = true
    @Published var isFocusMode = false
    @Published var recordingSong: SongRecordingTarget?
    @Published var songImporterPresented = false
    @Published var audioImporterPresented = false
    @Published var importError: String?
    /// Why File › Save did not save, until the writer dismisses it.
    @Published var saveError: String?
    /// The editor window is on screen. The menus act only through it.
    @Published var windowOpen = false

    /// A song is open in the editor pane, so song commands can act on it.
    func songOpen(in viewModel: EditorViewModel) -> Bool {
        windowOpen && detail == .editor && !viewModel.showWelcome
    }

    /// The assistant column is on screen whenever a song is open.
    var assistantVisible: Bool { showsAssistant && !isFocusMode }

    /// Showing the assistant leaves Focus, which hides it.
    func toggleAssistant() {
        if assistantVisible {
            showsAssistant = false
        } else {
            isFocusMode = false
            showsAssistant = true
        }
    }

    func toggleSidebar() {
        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
    }

    /// The song open the sidebar's row selection put on screen: its lyric editor
    /// leaves the focus in the list, so Delete trashes the selected song. Every other
    /// open issues a new token, so it never matches and the lyrics take the focus.
    private(set) var sidebarSelectedOpen: EditorViewModel.EditorOpen?

    /// Shows the song in the editor pane, opening that stored row unless the editor
    /// was loaded from it. False when the open song could not be kept, so the view model stayed on it.
    @discardableResult
    func openSong(_ project: SongProject, in viewModel: EditorViewModel, bySidebarSelection: Bool = false) -> Bool {
        detail = .editor
        if project.persistentModelID != viewModel.loadedProjectRow || viewModel.showWelcome {
            viewModel.loadProject(project)
        }
        let opened = viewModel.loadedProjectRow == project.persistentModelID && !viewModel.showWelcome
        sidebarSelectedOpen = bySidebarSelection && opened ? viewModel.editorOpen : nil
        return opened
    }

    /// File › Save: writes the open song now. When it cannot, says why.
    func save(_ viewModel: EditorViewModel) {
        guard !viewModel.flushCurrentDraft(checkpoint: true) else { return }
        saveError = viewModel.cloudOperationHoldsEditor
            ? "A backup or restore is running. Your edits are kept and are saved when it finishes."
            : viewModel.errorMessage ?? "Couldn't save this song. Your edits remain open."
    }

    /// Song › Cancel Generation: stops a running suggestion or rewrite. A finished
    /// rewrite preview stays for Accept or Dismiss.
    func cancelGeneration(_ viewModel: EditorViewModel) {
        viewModel.cancelSuggestions()
        if viewModel.rewriteLoading { viewModel.dismissRewrite() }
    }

    /// Opens the song's recordings, saving a new song first so it has an id.
    func showRecordings(for viewModel: EditorViewModel) {
        guard let id = viewModel.ensureProjectForRecording() else { return }
        recordingSong = SongRecordingTarget(id: id, title: viewModel.title.isEmpty ? "Untitled Song" : viewModel.title)
    }

    /// Song › Suggest Next Line: bring the assistant into view, leaving
    /// Focus, then ask for lines (the iOS UnBlock path).
    func suggestNextLine(_ viewModel: EditorViewModel) {
        isFocusMode = false
        showsAssistant = true
        viewModel.getSuggestions()
    }

    /// Copies dropped or picked audio into the open song's recordings and
    /// shows them.
    func importRecordings(_ urls: [URL], into viewModel: EditorViewModel) {
        guard let projectId = viewModel.ensureProjectForRecording() else { return }
        Task {
            for url in urls {
                do {
                    try await viewModel.importRecording(at: url, projectId: projectId)
                } catch is CancellationError {
                    return
                } catch {
                    importError = "Couldn't import this recording. Choose a playable M4A, MP3, WAV, or AAC file and try again."
                    return
                }
            }
            // Only if that song is still open: another song's recordings, or a
            // blank song saved to hold them, would be the wrong result.
            if viewModel.currentProjectId == projectId { showRecordings(for: viewModel) }
        }
    }

    /// A file picker that failed, other than by the writer cancelling it.
    func reportPickerFailure(_ error: Error) {
        guard (error as? CocoaError)?.code != .userCancelled else { return }
        importError = "Couldn't open the chosen file. Try choosing it again."
    }

    /// Opens song JSON exports, as the drawer's Import From File does; the last
    /// one imported is open. Files that fail are named, with how many imported.
    func importSongs(_ urls: [URL], into viewModel: EditorViewModel) {
        var failed: [String] = []
        var reason = ""
        for url in urls {
            do {
                if try viewModel.importSongFile(at: url) {
                    detail = .editor
                    continue
                }
                // Read, but not saved (or the open song could not be kept first).
                reason = viewModel.errorMessage ?? "Couldn't save the imported song. The file was not imported."
            } catch {
                reason = "Could not import this file. Pick a RhymeAI project JSON."
            }
            failed.append(url.lastPathComponent)
        }
        guard !failed.isEmpty else { return }
        importError = urls.count == 1
            ? reason
            : "Imported \(urls.count - failed.count) of \(urls.count) songs. Could not import: \(failed.joined(separator: ", ")). Pick RhymeAI project JSON files."
    }
}

/// Which menu bar commands can act right now. Derived from the view model and
/// the window state so the menus and their tests read the same rules.
struct MacCommandState: Equatable {
    var songOpen = false
    var canExport = false
    var canUndo = false
    var canRedo = false
    var canSuggest = false
    var canCancelGeneration = false
    var canRewrite = false
    var canInspectWord = false

    var canInsertSection = false

    /// `localModelReady` is whether the on-device model can answer; nil reads it
    /// now. Tests pass it so they do not depend on installed files.
    @MainActor
    init(
        viewModel: EditorViewModel,
        workspace: MacWorkspaceModel,
        localModelReady: Bool? = nil
    ) {
        let songOpen = workspace.songOpen(in: viewModel)
        self.songOpen = songOpen
        guard songOpen else { return }
        let rewriting = viewModel.hasActiveRewrite
        canExport = !viewModel.lyrics.isEmpty
        canUndo = viewModel.canUndoLyrics && !rewriting
        canRedo = viewModel.canRedoLyrics && !rewriting
        canSuggest = !viewModel.lyrics.isEmpty && !viewModel.isLoading
            && (viewModel.selectedProvider != .local || (localModelReady ?? LocalReadiness.current().canGenerate))
        // A finished rewrite preview has nothing to cancel; Accept or Dismiss close it.
        canCancelGeneration = viewModel.isLoading || viewModel.rewriteLoading
        canRewrite = LyricsContextMenuItem.hasText(viewModel.lyrics, in: viewModel.selectedRange) && !rewriting
        canInsertSection = !rewriting
        canInspectWord = viewModel.singleWordSelection != nil && !rewriting
    }
}

/// Where files dropped on the window go.
enum MacDropRoute: Equatable {
    /// RhymeAI song exports, each opened as a song.
    case songs([URL])
    /// Audio for the open song's recordings.
    case recordings([URL])
    case none

    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac"]

    static func route(_ urls: [URL], songOpen: Bool) -> MacDropRoute {
        let songs = urls.filter { $0.pathExtension.lowercased() == "json" }
        if !songs.isEmpty { return .songs(songs) }
        let audio = urls.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard songOpen, !audio.isEmpty else { return .none }
        return .recordings(audio)
    }
}

/// The custom items of the lyric editor's right-click menu.
enum LyricsContextMenuItem: Equatable {
    case wordInspector(word: String, range: NSRange)
    case rewrite(RewriteAction, range: NSRange)

    var title: String {
        switch self {
        case .wordInspector(let word, _): "Look Up “\(word)”"
        case .rewrite(let action, _): action.label
        }
    }

    /// A click inside the selection acts on the selection: the rewrites, and
    /// the Word Inspector when it is one word. A click elsewhere offers the
    /// Word Inspector for the word under the pointer. Nothing while a rewrite
    /// is shown, since the text on screen is then not the lyric.
    static func items(lyrics: String, selection: NSRange, clickedIndex: Int, rewriteActive: Bool) -> [Self] {
        guard !rewriteActive else { return [] }
        // NSMaxRange is the first index after the selection.
        let clickInSelection = selection.length > 0
            && clickedIndex >= selection.location
            && clickedIndex < NSMaxRange(selection)
        if clickInSelection {
            var items: [Self] = []
            if let word = EditorViewModel.singleWord(in: lyrics, range: selection) {
                items.append(.wordInspector(word: word.word, range: word.range))
            }
            guard hasText(lyrics, in: selection) else { return items }
            return items + RewriteAction.allCases.map { .rewrite($0, range: selection) }
        }
        guard let word = word(in: lyrics, at: clickedIndex) else { return [] }
        return [.wordInspector(word: word.word, range: word.range)]
    }

    /// The range holds more than spaces and line breaks, as a rewrite needs.
    static func hasText(_ lyrics: String, in range: NSRange) -> Bool {
        let ns = lyrics as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return false }
        return !ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The word around a UTF-16 index, by the Word Inspector's word rule.
    static func word(in lyrics: String, at index: Int) -> (word: String, range: NSRange)? {
        let ns = lyrics as NSString
        guard index >= 0, index < ns.length else { return nil }
        func isWordUnit(_ i: Int) -> Bool {
            guard let scalar = Unicode.Scalar(ns.character(at: i)) else { return false }
            return scalar == "'" || CharacterSet.letters.contains(scalar)
        }
        guard isWordUnit(index) else { return nil }
        var start = index
        while start > 0, isWordUnit(start - 1) { start -= 1 }
        var end = index + 1
        while end < ns.length, isWordUnit(end) { end += 1 }
        return EditorViewModel.singleWord(in: lyrics, range: NSRange(location: start, length: end - start))
    }
}
#endif
