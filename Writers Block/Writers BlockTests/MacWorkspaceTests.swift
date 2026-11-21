#if os(macOS)
import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Writers_Block

@MainActor
struct MacCommandStateTests {
    @Test
    func songCommandsAreDisabledWithNoSongOpen() {
        // Given
        let viewModel = EditorViewModel()
        let workspace = MacWorkspaceModel()
        workspace.windowOpen = true

        // When
        let state = MacCommandState(viewModel: viewModel, workspace: workspace)

        // Then
        #expect(viewModel.showWelcome)
        #expect(state == MacCommandState(viewModel: EditorViewModel(), workspace: MacWorkspaceModel()))
        #expect(!state.songOpen && !state.canExport && !state.canUndo && !state.canSuggest)
    }

    @Test
    func songCommandsFollowTheOpenSong() {
        // Given
        let viewModel = EditorViewModel()
        let workspace = MacWorkspaceModel()
        workspace.windowOpen = true
        viewModel.newProject()
        viewModel.onLyricsChanged("city lights", timestampMilliseconds: 0)
        viewModel.selectedRange = NSRange(location: 0, length: 4)

        // When
        let state = MacCommandState(viewModel: viewModel, workspace: workspace, localModelReady: true)

        // Then
        #expect(state.songOpen && state.canExport && state.canUndo && state.canSuggest)
        #expect(!state.canRedo && !state.canCancelGeneration)
        #expect(state.canRewrite && state.canInspectWord && state.canInsertSection)
    }

    @Test
    func suggestNeedsAReadyModelWhenTheLocalProviderIsChosen() {
        let viewModel = EditorViewModel()
        let workspace = MacWorkspaceModel()
        workspace.windowOpen = true
        viewModel.newProject()
        viewModel.onLyricsChanged("city lights", timestampMilliseconds: 0)
        viewModel.selectedProvider = .local

        #expect(!MacCommandState(viewModel: viewModel, workspace: workspace, localModelReady: false).canSuggest)
        #expect(MacCommandState(viewModel: viewModel, workspace: workspace, localModelReady: true).canSuggest)
    }

    @Test
    func rewriteIsOffForASelectionOfOnlySpaces() {
        let viewModel = EditorViewModel()
        let workspace = MacWorkspaceModel()
        workspace.windowOpen = true
        viewModel.newProject()
        viewModel.onLyricsChanged("city   lights", timestampMilliseconds: 0)
        viewModel.selectedRange = NSRange(location: 4, length: 3)

        #expect(!MacCommandState(viewModel: viewModel, workspace: workspace, localModelReady: true).canRewrite)
    }

    @Test
    func anActiveRewriteBlocksEditsAndAllowsCancel() {
        // Given
        let viewModel = EditorViewModel()
        let workspace = MacWorkspaceModel()
        workspace.windowOpen = true
        viewModel.newProject()
        viewModel.onLyricsChanged("city lights", timestampMilliseconds: 0)
        viewModel.selectedRange = NSRange(location: 0, length: 4)

        // When
        viewModel.rewriteAction = .rephrase
        viewModel.rewriteLoading = true
        let loading = MacCommandState(viewModel: viewModel, workspace: workspace)
        viewModel.rewriteLoading = false
        let preview = MacCommandState(viewModel: viewModel, workspace: workspace)

        // Then
        #expect(loading.canCancelGeneration)
        #expect(!loading.canUndo && !loading.canRewrite && !loading.canInspectWord && !loading.canInsertSection)
        #expect(!preview.canCancelGeneration, "a finished preview is closed by Accept or Dismiss")
        #expect(!preview.canUndo && !preview.canRewrite)
    }

    @Test
    func songCommandsAreDisabledAwayFromTheEditor() {
        // Given
        let viewModel = EditorViewModel()
        let workspace = MacWorkspaceModel()
        workspace.windowOpen = true
        viewModel.newProject()
        viewModel.onLyricsChanged("city lights", timestampMilliseconds: 0)

        // When
        workspace.detail = .oneLiners
        let inOneLiners = MacCommandState(viewModel: viewModel, workspace: workspace)
        workspace.detail = .editor
        workspace.windowOpen = false
        let windowClosed = MacCommandState(viewModel: viewModel, workspace: workspace)

        // Then
        #expect(!inOneLiners.songOpen && !inOneLiners.canUndo)
        #expect(!windowClosed.songOpen && !windowClosed.canExport)
    }
}

struct MacPickerFailureTests {
    @Test
    func aCancelledPickerIsSilentAndAFailedOneIsShown() {
        let workspace = MacWorkspaceModel()

        workspace.reportPickerFailure(CocoaError(.userCancelled))
        #expect(workspace.importError == nil)

        workspace.reportPickerFailure(CocoaError(.fileReadNoPermission))
        #expect(workspace.importError != nil)
    }
}

@MainActor
struct MacSongSidebarTests {
    /// Copy A loaded, and copy B under the same song id, as a restore on two devices leaves them after sync.
    private static func copies() throws -> (EditorViewModel, SongProject, SongProject, ModelContainer) {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let a = SongProject(id: "a", title: "Harbour Lights", lyrics: "ropes")
        let b = SongProject(id: "a", title: "Paper Moon", lyrics: "tide")
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        try container.mainContext.save()
        let viewModel = EditorViewModel()
        viewModel.modelContext = container.mainContext
        viewModel.loadProject(a)
        return (viewModel, a, b, container)
    }

    @Test
    func withALoadedAndOnlyBShownNothingIsHighlightedAndBOpens() throws {
        let (viewModel, _, b, container) = try Self.copies()
        _ = container

        #expect(MacSongSidebar.openRow(loaded: viewModel.loadedProjectRow, openID: viewModel.currentProjectId, in: [b]) == nil)
        #expect(MacWorkspaceModel().openSong(b, in: viewModel))
        #expect(viewModel.loadedProjectRow == b.persistentModelID)
    }

    @Test
    func aRefusedOpenCanBeRetried() throws {
        let (viewModel, a, b, container) = try Self.copies()
        let workspace = MacWorkspaceModel()
        viewModel.modelContext = nil
        viewModel.lyrics = "ropes and tide"

        #expect(!workspace.openSong(b, in: viewModel), "the outgoing edit cannot be saved")
        #expect(viewModel.loadedProjectRow == a.persistentModelID)

        viewModel.modelContext = container.mainContext
        #expect(workspace.openSong(b, in: viewModel))
        #expect(viewModel.loadedProjectRow == b.persistentModelID)
    }

    @Test
    func theCopyLoadedElsewhereIsHighlightedAndTheOtherOpens() throws {
        let (viewModel, a, b, container) = try Self.copies()
        _ = container
        viewModel.loadProject(b)

        #expect(MacSongSidebar.openRow(loaded: viewModel.loadedProjectRow, openID: viewModel.currentProjectId, in: [a, b]) === b)
        #expect(MacWorkspaceModel().openSong(a, in: viewModel))
        // The row, not its words: the outgoing save writes to the first row with the id (main's save path, a follow-up).
        #expect(viewModel.loadedProjectRow == a.persistentModelID)
    }
}

@MainActor
struct MacOpenSongTests {
    @Test
    func openReportsWhetherTheRequestedSongIsTheOneLoaded() {
        let song = SongProject(id: "song-1", title: "Harbour Lights", lyrics: "ropes")
        // Unsaved words with no library to keep them: the view model stays on them.
        let refusing = EditorViewModel()
        refusing.newProject()
        refusing.lyrics = "words that cannot be saved"
        let workspace = MacWorkspaceModel()

        #expect(!workspace.openSong(song, in: refusing))
        #expect(refusing.currentProjectId == nil)

        let fresh = EditorViewModel()
        #expect(workspace.openSong(song, in: fresh))
        #expect(fresh.currentProjectId == "song-1")
    }
}

struct LyricsContextMenuItemTests {
    private let lyrics = "city lights don't sleep"

    @Test
    func rightClickOnAWordOffersTheWordInspector() {
        // When: a click inside "lights" with no selection
        let items = LyricsContextMenuItem.items(
            lyrics: lyrics, selection: NSRange(location: 0, length: 0), clickedIndex: 7, rewriteActive: false
        )

        // Then
        #expect(items == [.wordInspector(word: "lights", range: NSRange(location: 5, length: 6))])
    }

    @Test
    func rightClickOnAnApostropheWordKeepsTheWholeWord() {
        let items = LyricsContextMenuItem.items(
            lyrics: lyrics, selection: NSRange(location: 0, length: 0), clickedIndex: 13, rewriteActive: false
        )

        #expect(items == [.wordInspector(word: "don't", range: NSRange(location: 12, length: 5))])
    }

    @Test
    func rightClickOnASpaceOffersNothing() {
        let items = LyricsContextMenuItem.items(
            lyrics: lyrics, selection: NSRange(location: 0, length: 0), clickedIndex: 4, rewriteActive: false
        )

        #expect(items.isEmpty)
    }

    @Test
    func rightClickInAMultiWordSelectionOffersTheRewrites() {
        // Given
        let selection = NSRange(location: 0, length: 11)

        // When
        let items = LyricsContextMenuItem.items(lyrics: lyrics, selection: selection, clickedIndex: 6, rewriteActive: false)

        // Then
        #expect(items == RewriteAction.allCases.map { .rewrite($0, range: selection) })
    }

    @Test
    func rightClickInAOneWordSelectionOffersTheInspectorAndRewrites() {
        let selection = NSRange(location: 0, length: 4)

        let items = LyricsContextMenuItem.items(lyrics: lyrics, selection: selection, clickedIndex: 2, rewriteActive: false)

        #expect(items.first == .wordInspector(word: "city", range: selection))
        #expect(Array(items.dropFirst()) == RewriteAction.allCases.map { .rewrite($0, range: selection) })
    }

    @Test
    func rightClickOutsideTheSelectionActsOnTheClickedWord() {
        let items = LyricsContextMenuItem.items(
            lyrics: lyrics, selection: NSRange(location: 0, length: 4), clickedIndex: 19, rewriteActive: false
        )

        #expect(items == [.wordInspector(word: "sleep", range: NSRange(location: 18, length: 5))])
    }

    @Test
    func rightClickJustAfterTheSelectionIsOutsideIt() {
        // Index 4 is the space after "city": the selection's end, not inside it.
        let items = LyricsContextMenuItem.items(
            lyrics: lyrics, selection: NSRange(location: 0, length: 4), clickedIndex: 4, rewriteActive: false
        )

        #expect(items.isEmpty)
    }

    @Test
    func aSelectionOfOnlySpacesOffersNoRewrites() {
        let items = LyricsContextMenuItem.items(
            lyrics: "city   lights", selection: NSRange(location: 4, length: 3), clickedIndex: 5, rewriteActive: false
        )

        #expect(items.isEmpty)
    }

    @Test
    func anActiveRewriteHidesTheCustomItems() {
        let items = LyricsContextMenuItem.items(
            lyrics: lyrics, selection: NSRange(location: 0, length: 11), clickedIndex: 6, rewriteActive: true
        )

        #expect(items.isEmpty)
    }
}

struct MacDropRouteTests {
    private let song = URL(fileURLWithPath: "/tmp/Song.JSON")
    private let memo = URL(fileURLWithPath: "/tmp/take.m4a")
    private let wav = URL(fileURLWithPath: "/tmp/take.WAV")
    private let image = URL(fileURLWithPath: "/tmp/cover.png")

    @Test
    func aSongFileOpensAsASongEvenWithNoSongOpen() {
        #expect(MacDropRoute.route([song], songOpen: false) == .songs([song]))
        #expect(MacDropRoute.route([memo, song], songOpen: true) == .songs([song]))
    }

    @Test
    func everyDroppedSongFileIsImported() {
        let second = URL(fileURLWithPath: "/tmp/Second.json")

        #expect(MacDropRoute.route([song, memo, second], songOpen: true) == .songs([song, second]))
    }

    @Test
    func audioGoesToTheOpenSongsRecordings() {
        #expect(MacDropRoute.route([memo, image, wav], songOpen: true) == .recordings([memo, wav]))
    }

    @Test
    func audioIsRefusedWithNoSongOpen() {
        #expect(MacDropRoute.route([memo], songOpen: false) == .none)
    }

    @Test
    func otherFilesAreRefused() {
        #expect(MacDropRoute.route([image], songOpen: true) == .none)
    }
}

/// Edit › Undo is AppKit's responder-chain item: the lyric editor answers it
/// with the lyric history, any other field with its own undo.
@MainActor
struct LyricsUndoRoutingTests {
    @Test
    func theEditMenusUndoStepsTheViewModelsLyricHistory() {
        // Given: the editor built by makeNSView's own factory, after one edit
        let viewModel = EditorViewModel()
        viewModel.newProject()
        viewModel.onLyricsChanged("city lights", timestampMilliseconds: 0)
        var editable = true
        let lyrics = LyricsTextView.makeTextView(history: viewModel) { editable }
        #expect(!lyrics.allowsUndo, "AppKit's own text undo stays off")
        let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")

        // Then
        #expect(lyrics.validateMenuItem(undo))
        #expect(!lyrics.validateMenuItem(redo))
        #expect(lyrics.tryToPerform(Selector(("undo:")), with: nil))
        #expect(viewModel.lyrics.isEmpty)
        #expect(lyrics.validateMenuItem(redo))

        editable = false
        #expect(!lyrics.validateMenuItem(redo), "a read-only editor (a rewrite preview) offers no history")
    }
}

/// An opened song's lyric editor takes the focus, unless the sidebar's row
/// selection opened it: then the list keeps the focus and Delete stays its own.
/// The real editor pane (`MacEditorDetail`) beside a sidebar List, in a window.
@MainActor
struct LyricsOpenFocusTests {
    private let viewModel: EditorViewModel
    private let container: ModelContainer
    private let workspace = MacWorkspaceModel()

    init() throws {
        (viewModel, container) = try MacWorkspaceLibraryTests.library()
    }

    private func song(_ id: String, _ lyrics: String) throws -> SongProject {
        let song = SongProject(id: id, title: id, lyrics: lyrics, theme: "")
        container.mainContext.insert(song)
        try container.mainContext.save()
        return song
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HStack {
            List(selection: .constant(Optional(1))) { Text("Song").tag(1) }.listStyle(.sidebar).frame(width: 200)
            DetailSwitch()
        }
        .environmentObject(viewModel)
        .environmentObject(workspace)
        .modelContainer(container))
        return window
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The workspace's detail switch, as far as these tests need it: the editor pane
    /// leaves for another screen (Trash) and is built again on the way back.
    private struct DetailSwitch: View {
        @EnvironmentObject private var workspace: MacWorkspaceModel
        var body: some View {
            if workspace.detail == .editor { MacEditorDetail() } else { Text("Trash") }
        }
    }

    /// Lets SwiftUI put the open song's editor on screen. `outgoing` is an editor
    /// fading out, which shows the new lyrics too until it goes.
    private func editor(for lyrics: String, in window: NSWindow, excluding outgoing: NSView? = nil) async throws -> LyricsNSTextView {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            if let editor = views(LyricsNSTextView.self, in: content).first(where: { $0.string == lyrics && $0 !== outgoing }) {
                return editor
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    /// The list with the focus, as a click on a row or Tab into it leaves it.
    private func focusList(in window: NSWindow) throws -> NSTableView {
        let content = try #require(window.contentView)
        let list = try #require(views(NSTableView.self, in: content).first, "the sidebar List is an AppKit table view")
        #expect(window.makeFirstResponder(list))
        return list
    }

    @Test
    func aSongTheSidebarSelectionOpensLeavesTheFocusInTheList() async throws {
        // Given: a song opened by a command, then the list focused
        let a = try song("a", "harbour lights"), b = try song("b", "paper moon")
        let window = makeWindow()
        workspace.openSong(a, in: viewModel)
        let first = try await editor(for: a.lyrics, in: window)
        #expect(window.firstResponder === first, "an open from elsewhere focuses the lyrics")
        let list = try focusList(in: window)

        // When: the sidebar's row selection opens another song
        #expect(workspace.openSong(b, in: viewModel, bySidebarSelection: true))
        _ = try await editor(for: b.lyrics, in: window, excluding: first)

        // Then
        #expect(window.firstResponder === list)
    }

    @Test
    func theSidebarSelectedSongBackFromTrashFocusesTheLyrics() async throws {
        // Given: the sidebar's row selection opened a song, with the list focused
        let a = try song("a", "harbour lights")
        let window = makeWindow()
        #expect(workspace.openSong(a, in: viewModel, bySidebarSelection: true))
        let open = viewModel.editorOpen
        let first = try await editor(for: a.lyrics, in: window)
        let list = try focusList(in: window)

        // When: the detail goes to Trash and back to songs, the same open
        workspace.detail = .trash
        let content = try #require(window.contentView)
        let deadline = ContinuousClock.now + .seconds(5)
        while !views(LyricsNSTextView.self, in: content).isEmpty, ContinuousClock.now < deadline {
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        workspace.detail = .editor
        let rebuilt = try await editor(for: a.lyrics, in: window, excluding: first)

        // Then: the rebuilt editor's lyrics take the focus from the list
        #expect(viewModel.editorOpen == open)
        let focusDeadline = ContinuousClock.now + .seconds(2)
        while window.firstResponder === list, ContinuousClock.now < focusDeadline {
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.firstResponder === rebuilt)
    }

    @Test
    func anImportAfterASidebarSelectionThatLoadedNothingFocusesTheLyrics() async throws {
        // Given: the sidebar selected the song already open, so nothing loaded, with the list focused
        let a = try song("a", "harbour lights")
        let window = makeWindow()
        workspace.openSong(a, in: viewModel, bySidebarSelection: true)
        let outgoing = try await editor(for: a.lyrics, in: window)
        let list = try focusList(in: window)
        #expect(workspace.openSong(a, in: viewModel, bySidebarSelection: true))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Tide.json")
        try LyricsExporter.data(for: SongProject(id: "t", title: "Tide", lyrics: "rope and tide", theme: ""), format: .json).write(to: file)

        // When: a song opens from outside the sidebar (File › Import Song, or a drop)
        workspace.importSongs([file], into: viewModel)

        // Then: the imported song's lyrics take the focus from the list
        // (The outgoing editor shows the new lyrics too while it fades out.)
        _ = try await editor(for: "rope and tide", in: window)
        let deadline = ContinuousClock.now + .seconds(2)
        while window.firstResponder === list, ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let focused = window.firstResponder as? LyricsNSTextView
        #expect(focused != nil && focused !== outgoing && focused?.string == "rope and tide")
    }
}
/// Save, Quit, multi-file import and Cancel Generation, against a real library.
@MainActor
struct MacWorkspaceLibraryTests {
    static func library() throws -> (EditorViewModel, ModelContainer) {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let viewModel = EditorViewModel()
        viewModel.modelContext = container.mainContext
        return (viewModel, container)
    }

    /// An open song with an edit the library cannot take: its row was removed meanwhile.
    private static func unsavableEdit() throws -> (EditorViewModel, ModelContainer) {
        let (viewModel, container) = try library()
        let song = SongProject(id: "gone", title: "Harbour Lights", lyrics: "ropes", theme: "")
        container.mainContext.insert(song)
        try container.mainContext.save()
        viewModel.loadProject(song)
        container.mainContext.delete(song)
        try container.mainContext.save()
        viewModel.lyrics = "ropes and tide"
        return (viewModel, container)
    }

    @Test
    func quitIsHeldWhileTheOpenSongCannotBeSaved() throws {
        let (viewModel, container) = try Self.unsavableEdit()
        _ = container
        viewModel.triggerAutoSave()
        var reasons: [String] = []
        var answers: [MacAppDelegate.FailedSaveChoice] = [.tryAgain, .keepOpen]

        let held = MacAppDelegate.terminateReply(viewModel: viewModel) { reasons.append($0); return answers.removeFirst() }
        let quit = MacAppDelegate.terminateReply(viewModel: viewModel) { _ in .quitAnyway }

        #expect(held == .terminateCancel)
        #expect(reasons == Array(repeating: "This song is no longer in the library. Your edits remain open.", count: 2), "Try Again saves again")
        #expect(quit == .terminateNow)
    }

    @Test
    func quitWithNothingUnsavedDoesNotAskOrWrite() throws {
        let (viewModel, container) = try Self.library()
        let song = SongProject(id: "s", title: "Harbour Lights", lyrics: "ropes", theme: "")
        container.mainContext.insert(song)
        try container.mainContext.save()
        viewModel.loadProject(song)
        song.lyrics = "ropes and a synced line"
        try container.mainContext.save()

        let reply = MacAppDelegate.terminateReply(viewModel: viewModel) { _ in
            Issue.record("asked with nothing unsaved")
            return .keepOpen
        }

        #expect(reply == .terminateNow)
        #expect(song.lyrics == "ropes and a synced line")
    }

    @Test
    func saveThatCannotWriteSaysWhy() throws {
        let (viewModel, container) = try Self.unsavableEdit()
        _ = container
        let workspace = MacWorkspaceModel()

        workspace.save(viewModel)

        #expect(workspace.saveError == "This song is no longer in the library. Your edits remain open.")
    }

    @Test
    func aMultiFileImportSaysHowManyImportedAndWhichFailed() throws {
        let (viewModel, container) = try Self.library()
        _ = container
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let song = folder.appendingPathComponent("Paper Moon.json")
        try LyricsExporter.data(for: SongProject(id: "p", title: "Paper Moon", lyrics: "tide", theme: ""), format: .json).write(to: song)
        let notes = folder.appendingPathComponent("notes.json")
        try Data("not a song".utf8).write(to: notes)
        let workspace = MacWorkspaceModel()

        workspace.importSongs([song, notes], into: viewModel)

        #expect(workspace.importError == "Imported 1 of 2 songs. Could not import: notes.json. Pick RhymeAI project JSON files.")
        #expect(viewModel.title == "Paper Moon")
    }

    @Test
    func cancelGenerationKeepsAFinishedRewritePreview() {
        let viewModel = EditorViewModel()
        let workspace = MacWorkspaceModel()
        viewModel.newProject()
        viewModel.onLyricsChanged("city lights", timestampMilliseconds: 0)
        viewModel.rewriteAction = .rephrase
        viewModel.rewritePreview = "city glow"

        workspace.cancelGeneration(viewModel)
        #expect(viewModel.rewritePreview == "city glow", "a finished preview waits for Accept or Dismiss")

        viewModel.rewriteLoading = true
        workspace.cancelGeneration(viewModel)
        #expect(viewModel.rewriteAction == nil && !viewModel.rewriteLoading)
    }
}

@MainActor
struct MacDetailSizeTests {
    /// The window takes the detail pane's minimum size, so One Liners must fit the
    /// default 780pt window or opening it grows the window (its wrapped caption did).
    @Test
    func oneLinersFitsTheDefaultWindow() throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, OneLiner.self, TrashedOneLiner.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let host = NSHostingController(rootView: OneLinersView(onDismiss: {})
            .environmentObject(EditorViewModel())
            .modelContainer(container))

        #expect(host.sizeThatFits(in: .zero).height < 780)
    }

    /// The detail pane's minimum, not each page's own, sets the window's minimum width,
    /// so hiding the sidebar cannot shrink a page (One Liners went to 147pt and clipped
    /// its rows to single letters). Every page is narrower than the pane's minimum.
    @Test
    func everyDetailPageTakesThePanesMinimumWidth() throws {
        let (viewModel, container) = try MacWorkspaceLibraryTests.library()
        var widths: [CGFloat] = []
        for detail in [MacWorkspaceModel.Detail.editor, .oneLiners, .trash] {
            let workspace = MacWorkspaceModel()
            workspace.sidebarVisibility = .detailOnly
            workspace.detail = detail
            let view = NSHostingView(rootView: MacWorkspaceView()
                .environmentObject(viewModel)
                .environmentObject(workspace)
                .environmentObject(AppPersistenceState(persistenceDegraded: false, cloudSyncStatus: .localOnlyFallback, usesCloudBackedStore: false))
                .environmentObject(GGUFDownloadManager.shared)
                .modelContainer(container))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            widths.append(view.fittingSize.width)
            window.close()
        }
        #expect(Set(widths).count == 1, "\(widths)")
        #expect(widths.allSatisfy { $0 >= MacWorkspaceView.detailMinWidth }, "\(widths)")
    }
}
#endif
