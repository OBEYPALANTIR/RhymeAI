#if os(macOS)
import AppKit
import Foundation
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

struct MacSongSidebarTests {
    @Test
    func deleteIgnoresASelectedSongTheSearchHides() {
        let songs = [SongProject(id: "a", title: "Harbour Lights", lyrics: "ropes"),
                     SongProject(id: "b", title: "Paper Moon", lyrics: "tide")]

        #expect(MacSongSidebar.songToDelete(selectedID: "a", in: songs, searchText: "moon") == nil)
        #expect(MacSongSidebar.songToDelete(selectedID: "b", in: songs, searchText: "moon")?.id == "b")
        #expect(MacSongSidebar.songToDelete(selectedID: nil, in: songs, searchText: "") == nil)
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
        // Given: the editor wired as makeNSView wires it, after one edit
        let viewModel = EditorViewModel()
        viewModel.newProject()
        viewModel.onLyricsChanged("city lights", timestampMilliseconds: 0)
        let lyrics = LyricsNSTextView(usingTextLayoutManager: true)
        var editable = true
        lyrics.connectHistory(to: viewModel) { editable }
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
#endif
