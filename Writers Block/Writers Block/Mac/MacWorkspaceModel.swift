#if os(macOS)
import Combine
import SwiftUI

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

    /// Shows the song in the editor pane, opening it unless it is already open.
    /// False when the open song could not be kept, so the view model stayed on it.
    @discardableResult
    func openSong(_ project: SongProject, in viewModel: EditorViewModel) -> Bool {
        detail = .editor
        if project.id != viewModel.currentProjectId || viewModel.showWelcome {
            viewModel.loadProject(project)
        }
        return viewModel.currentProjectId == project.id && !viewModel.showWelcome
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
            showRecordings(for: viewModel)
        }
    }

    /// Opens a song JSON export, as the drawer's Import From File does.
    func importSong(_ url: URL, into viewModel: EditorViewModel) {
        do {
            if try viewModel.importSongFile(at: url) { detail = .editor }
        } catch {
            importError = "Could not import this file. Pick a RhymeAI project JSON."
        }
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

    init(viewModel: EditorViewModel, workspace: MacWorkspaceModel) {
        let songOpen = workspace.songOpen(in: viewModel)
        self.songOpen = songOpen
        guard songOpen else { return }
        let rewriting = viewModel.hasActiveRewrite
        canExport = !viewModel.lyrics.isEmpty
        canUndo = viewModel.canUndoLyrics && !rewriting
        canRedo = viewModel.canRedoLyrics && !rewriting
        canSuggest = !viewModel.lyrics.isEmpty && !viewModel.isLoading
        canCancelGeneration = viewModel.isLoading || rewriting
        canRewrite = viewModel.selectedRange.length > 0 && !rewriting
        canInspectWord = viewModel.singleWordSelection != nil && !rewriting
    }
}

/// Where files dropped on the window go.
enum MacDropRoute: Equatable {
    /// A RhymeAI song export, opened as a song.
    case song(URL)
    /// Audio for the open song's recordings.
    case recordings([URL])
    case none

    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac"]

    static func route(_ urls: [URL], songOpen: Bool) -> MacDropRoute {
        if let song = urls.first(where: { $0.pathExtension.lowercased() == "json" }) {
            return .song(song)
        }
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
        let clickInSelection = selection.length > 0
            && clickedIndex >= selection.location
            && clickedIndex <= NSMaxRange(selection)
        if clickInSelection {
            var items: [Self] = []
            if let word = EditorViewModel.singleWord(in: lyrics, range: selection) {
                items.append(.wordInspector(word: word.word, range: word.range))
            }
            return items + RewriteAction.allCases.map { .rewrite($0, range: selection) }
        }
        guard let word = word(in: lyrics, at: clickedIndex) else { return [] }
        return [.wordInspector(word: word.word, range: word.range)]
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
