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

        #expect(MacSongSidebar.openRow(loaded: viewModel.loadedProjectRow, in: [b]) == nil)
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

    /// A restore that brings in a change to the second copy. Stands in for Drive.
    @MainActor
    private final class RestoringBackup: CloudBackupServicing {
        let isConfigured = true
        let isConnected = true
        private(set) var restores = 0
        private let change: () -> Void
        init(_ change: @escaping () -> Void) { self.change = change }
        func backupNow(modelContext: ModelContext) async throws {}
        func backupInBackgroundIfPossible(modelContext: ModelContext) async {}
        func restoreNow(modelContext: ModelContext) async throws {
            restores += 1
            change()
            try modelContext.save()
        }
    }

    @Test
    func aRestoreKeepsTheEditorOnTheCopyItHoldsThroughOpenExportAndTheNextSave() async throws {
        // Given: two stored copies under one song id, the second open from the context menu
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let a = SongProject(id: "s", title: "Harbour Lights", lyrics: "ropes", theme: "")
        let b = SongProject(id: "s", title: "Paper Moon", lyrics: "tide", theme: "")
        container.mainContext.insert(a)
        try container.mainContext.save()
        container.mainContext.insert(b)
        try container.mainContext.save()
        let restore = RestoringBackup { b.lyrics = "tide and a restored line" }
        let viewModel = EditorViewModel(backupService: restore, companionStore: WritingCompanionStore(inMemory: true))
        viewModel.modelContext = container.mainContext
        let workspace = MacWorkspaceModel()
        #expect(workspace.openSong(b, in: viewModel))
        #expect(viewModel.canRunCloudBackup)

        // When: a restore reconciles the open song, then the context menu opens that copy
        await viewModel.restoreBackupNow()
        #expect(restore.restores == 1)
        #expect(workspace.openSong(b, in: viewModel))

        // Then: the editor holds that copy's restored words, and exports them
        #expect(viewModel.loadedProjectRow == b.persistentModelID)
        let exported = try #require(String(data: LyricsExporter.data(for: viewModel.snapshotForExport(), format: .txt), encoding: .utf8))
        #expect(exported.contains("Paper Moon") && exported.contains("tide and a restored line"), "\(exported)")
        #expect(!exported.contains("Harbour Lights") && !exported.contains("ropes"), "\(exported)")

        // And: an edit is written to that copy as the other one opens, leaving the other as it was
        viewModel.lyrics = "tide and a restored line, edited"
        #expect(workspace.openSong(a, in: viewModel))
        #expect(viewModel.loadedProjectRow == a.persistentModelID)
        #expect(a.title == "Harbour Lights" && a.lyrics == "ropes", "\(a.title): \(a.lyrics)")
        #expect(b.title == "Paper Moon" && b.lyrics == "tide and a restored line, edited", "\(b.title): \(b.lyrics)")
    }

    @Test
    func aRestoreThatRemovesTheOpenCopyShowsTheRemainingOneBeforeTheEditorClaimsIt() async throws {
        // Given: two stored copies under one song id, the second open and unedited
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let a = SongProject(id: "s", title: "Harbour Lights", lyrics: "ropes", theme: "")
        let b = SongProject(id: "s", title: "Paper Moon", lyrics: "tide", theme: "")
        container.mainContext.insert(a)
        try container.mainContext.save()
        container.mainContext.insert(b)
        try container.mainContext.save()
        let restore = RestoringBackup { container.mainContext.delete(b) }
        let viewModel = EditorViewModel(backupService: restore, companionStore: WritingCompanionStore(inMemory: true))
        viewModel.modelContext = container.mainContext
        #expect(MacWorkspaceModel().openSong(b, in: viewModel))

        // When: a restore removes that copy
        await viewModel.restoreBackupNow()
        #expect(restore.restores == 1)

        // Then: the editor shows the remaining copy's own words, unchanged, before it is the open row
        #expect(viewModel.loadedProjectRow == a.persistentModelID)
        #expect(viewModel.title == "Harbour Lights" && viewModel.lyrics == "ropes", "\(viewModel.title): \(viewModel.lyrics)")
        #expect(a.title == "Harbour Lights" && a.lyrics == "ropes", "\(a.title): \(a.lyrics)")
    }

    @Test
    func openingASongRestoredFromTrashUnderTheOpenSongsIdShowsAndExportsItsOwnWords() throws {
        // Given: a song open, and a Trash entry under the same song id
        let (viewModel, container) = try MacWorkspaceLibraryTests.library()
        let a = SongProject(id: "s", title: "Harbour Lights", lyrics: "ropes", theme: "")
        container.mainContext.insert(a)
        container.mainContext.insert(TrashedSongProject(project: SongProject(id: "s", title: "Paper Moon", lyrics: "tide", theme: "")))
        try container.mainContext.save()
        let workspace = MacWorkspaceModel()
        #expect(workspace.openSong(a, in: viewModel))

        // When: the Mac Trash pane restores it, then the context menu opens the restored song
        let entry = try #require(try container.mainContext.fetch(FetchDescriptor<TrashedSongProject>()).first)
        let restored = try #require(viewModel.restoreTrashedProject(entry))
        #expect(workspace.openSong(restored, in: viewModel))

        // Then: the restored song keeps its words, and the editor holds and exports them
        #expect(restored.title == "Paper Moon" && restored.lyrics == "tide", "\(restored.title): \(restored.lyrics)")
        #expect(viewModel.loadedProjectRow == restored.persistentModelID)
        let exported = try #require(String(data: LyricsExporter.data(for: viewModel.snapshotForExport(), format: .txt), encoding: .utf8))
        #expect(exported.contains("Paper Moon") && exported.contains("tide") && !exported.contains("ropes"), "\(exported)")
    }

    @Test
    func editsToACopyThatDisappearedStayOpenAndNeverLandOnTheOtherCopy() throws {
        // Given: copy A open, and copy B under the same song id
        let (viewModel, a, b, container) = try Self.copies()
        // When: copy A is removed (by sync), the writer edits, then opens copy B
        container.mainContext.delete(a)
        try container.mainContext.save()
        viewModel.lyrics = "ropes, edited"
        #expect(!MacWorkspaceModel().openSong(b, in: viewModel), "the edits have nowhere of their own to go")

        // Then: the edits stay open in the editor, and copy B keeps its own words
        #expect(viewModel.lyrics == "ropes, edited")
        #expect(viewModel.errorMessage == "This song is no longer in the library. Your edits remain open.")
        #expect(b.title == "Paper Moon" && b.lyrics == "tide", "\(b.title): \(b.lyrics)")
    }

    @Test
    func keepAlternateAndSaveVersionOnACopyThatDisappearedKeepNothingUnderTheOtherCopysId() throws {
        // Given: copy A open and unedited, copy B under the same song id, and A removed (by sync)
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let a = SongProject(id: "a", title: "Harbour Lights", lyrics: "ropes", theme: "")
        let b = SongProject(id: "a", title: "Paper Moon", lyrics: "tide", theme: "")
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        try container.mainContext.save()
        let store = WritingCompanionStore(inMemory: true)
        let viewModel = EditorViewModel(companionStore: store)
        viewModel.modelContext = container.mainContext
        viewModel.loadProject(a)
        container.mainContext.delete(a)
        try container.mainContext.save()
        let notebookBefore = try store.read("a")

        // When: the writer keeps an alternate line, then saves a version
        viewModel.keepAlternate("salt on the rope")
        let versionSaved = viewModel.flushCurrentDraft(checkpoint: true)

        // Then: neither reports success, and nothing is stored under the song id copy B now holds
        #expect(viewModel.companionError == "Could not keep this line because the song did not save. Try again.")
        #expect(!versionSaved, "Save Version has no row of its own to save")
        #expect(try store.read("a") == notebookBefore)
        #expect(b.title == "Paper Moon" && b.lyrics == "tide", "\(b.title): \(b.lyrics)")
    }

    enum EditTiming: CaseIterable, Sendable {
        case pendingWhenTheRestoreStarts
        case madeDuringTheRestore
    }

    @Test(arguments: EditTiming.allCases)
    func aRestoreThatRemovesTheEditedOpenCopyKeepsTheEditsOffTheOtherCopy(_ timing: EditTiming) async throws {
        // Given: copies A and B under one song id with the same words, A open
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let a = SongProject(id: "s", title: "Harbour Lights", lyrics: "ropes", theme: "sea")
        let b = SongProject(id: "s", title: "Harbour Lights", lyrics: "ropes", theme: "sea")
        container.mainContext.insert(a)
        try container.mainContext.save()
        container.mainContext.insert(b)
        try container.mainContext.save()
        var editor: EditorViewModel?
        let restore = RestoringBackup {
            container.mainContext.delete(a)
            if timing == .madeDuringTheRestore {
                editor?.lyrics = "ropes, edited"
                editor?.triggerAutoSave()
            }
        }
        let viewModel = EditorViewModel(backupService: restore, companionStore: WritingCompanionStore(inMemory: true))
        editor = viewModel
        viewModel.modelContext = container.mainContext
        #expect(MacWorkspaceModel().openSong(a, in: viewModel))
        if timing == .pendingWhenTheRestoreStarts {
            viewModel.lyrics = "ropes, edited"
            viewModel.triggerAutoSave()
        }

        // When: a restore removes copy A
        await viewModel.restoreBackupNow()
        #expect(restore.restores == 1)

        // Then: copy B is unchanged, and A's edited words are a separate song the editor holds
        #expect(b.id == "s" && b.title == "Harbour Lights" && b.lyrics == "ropes" && b.theme == "sea", "\(b.title): \(b.lyrics)")
        let rows = try container.mainContext.fetch(FetchDescriptor<SongProject>())
        let recovered = try #require(rows.first { $0.lyrics == "ropes, edited" }, "\(rows.map(\.lyrics))")
        #expect(recovered.id != "s")
        #expect(recovered.title == "Harbour Lights" && recovered.theme == "sea")
        #expect(viewModel.loadedProjectRow == recovered.persistentModelID)
        #expect(viewModel.lyrics == "ropes, edited")
    }

    @Test
    func deleteMovesTheSelectedShownSongToTrash() throws {
        // The positive control for the filtered Delete in SidebarSelectionFocusTests.
        let (viewModel, container) = try MacWorkspaceLibraryTests.library()
        let song = SongProject(id: "d", title: "Harbour Lights", lyrics: "ropes", theme: "")
        container.mainContext.insert(song)
        try container.mainContext.save()
        viewModel.loadProject(song)
        let shown = try container.mainContext.fetch(FetchDescriptor<SongProject>())

        let selected = MacSongSidebar.openRow(loaded: viewModel.loadedProjectRow, in: shown)?.persistentModelID
        #expect(MacSongSidebar.delete(selected, in: shown, viewModel: viewModel))

        #expect(try container.mainContext.fetch(FetchDescriptor<SongProject>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedSongProject>()).map(\.id) == ["d"])
    }

    @Test
    func theCopyLoadedElsewhereIsHighlightedAndTheOtherOpens() throws {
        let (viewModel, a, b, container) = try Self.copies()
        _ = container
        viewModel.loadProject(b)

        #expect(MacSongSidebar.openRow(loaded: viewModel.loadedProjectRow, in: [a, b]) === b)
        #expect(MacWorkspaceModel().openSong(a, in: viewModel))
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
    func aSongTheSidebarSelectionOpensDoesNotTakeTheFocusTheLyricsHad() async throws {
        // Given: a song opened by a command, its lyrics focused (a row click in the app
        // left them so)
        let a = try song("a", "harbour lights"), b = try song("b", "paper moon")
        let window = makeWindow()
        workspace.openSong(a, in: viewModel)
        let first = try await editor(for: a.lyrics, in: window)
        #expect(window.firstResponder === first)

        // When: the sidebar's row selection opens another song
        #expect(workspace.openSong(b, in: viewModel, bySidebarSelection: true))
        let second = try await editor(for: b.lyrics, in: window, excluding: first)
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()

        // Then: its lyrics do not take the keyboard. This harness's List is a stand-in that
        // the open never focuses, so the keyboard ends on the window here; that it lands in
        // the list is asserted through the real sidebar in SidebarSelectionFocusTests.
        #expect(window.firstResponder !== second)
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

    /// An open song whose row was removed meanwhile, its words not edited.
    private static func vanishedUnedited() throws -> (EditorViewModel, ModelContainer) {
        let (viewModel, container) = try library()
        let song = SongProject(id: "gone", title: "Harbour Lights", lyrics: "ropes", theme: "")
        container.mainContext.insert(song)
        try container.mainContext.save()
        viewModel.loadProject(song)
        container.mainContext.delete(song)
        try container.mainContext.save()
        return (viewModel, container)
    }

    /// Waits for the autosave just scheduled: it shows .saving while it waits, then ends.
    /// One with nothing to write ends without showing .saving.
    private static func autosaveFinished(_ viewModel: EditorViewModel) async throws {
        var waited = 0
        while viewModel.saveStatus != .saving, waited < 40 { try await Task.sleep(for: .milliseconds(50)); waited += 1 }
        waited = 0
        while viewModel.saveStatus == .saving, waited < 400 { try await Task.sleep(for: .milliseconds(50)); waited += 1 }
    }

    @Test
    func quitAsksAfterTheAutosaveRefusedAnEditThatErasedTheSong() async throws {
        // Given: an open song whose row is gone, then every field erased, and its autosave run
        let (viewModel, container) = try Self.vanishedUnedited()
        _ = container
        viewModel.title = ""
        viewModel.lyrics = ""
        viewModel.theme = ""
        viewModel.triggerAutoSave()
        try await Self.autosaveFinished(viewModel)

        // When: the writer quits
        var reasons: [String] = []
        let reply = MacAppDelegate.terminateReply(viewModel: viewModel) { reasons.append($0); return .keepOpen }

        // Then: Quit asks, with the reason
        #expect(reply == .terminateCancel)
        #expect(reasons == ["This song is no longer in the library. Your edits remain open."])
        #expect(viewModel.saveStatus == .failed)
    }

    @Test
    func quitAsksAfterARefusedOpenCancelledThePendingAutosave() throws {
        // Given: copy A open, copy B under its song id, A removed, and an edit waiting to autosave
        let (viewModel, container) = try Self.library()
        let a = SongProject(id: "s", title: "Harbour Lights", lyrics: "ropes", theme: "")
        let b = SongProject(id: "s", title: "Paper Moon", lyrics: "tide", theme: "")
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        try container.mainContext.save()
        viewModel.loadProject(a)
        container.mainContext.delete(a)
        try container.mainContext.save()
        viewModel.lyrics = "ropes and tide"
        viewModel.triggerAutoSave()

        // When: opening B is refused, which cancels the waiting autosave, then the writer quits
        #expect(!MacWorkspaceModel().openSong(b, in: viewModel))
        var reasons: [String] = []
        let reply = MacAppDelegate.terminateReply(viewModel: viewModel) { reasons.append($0); return .keepOpen }

        // Then: Quit asks, and B keeps its own words
        #expect(reply == .terminateCancel)
        #expect(reasons == ["This song is no longer in the library. Your edits remain open."])
        #expect(b.title == "Paper Moon" && b.lyrics == "tide", "\(b.title): \(b.lyrics)")
    }

    @Test(arguments: [true, false])
    func quitDoesNotAskForAnUneditedSongWhoseRowIsGone(autosavePending: Bool) async throws {
        // Given: an open song whose row is gone, its words unedited, with an autosave waiting or run
        let (viewModel, container) = try Self.vanishedUnedited()
        _ = container
        viewModel.triggerAutoSave()
        if !autosavePending {
            try await Self.autosaveFinished(viewModel)
            #expect(viewModel.saveStatus == .idle, "nothing to save is not a save in progress")
        }

        // When: the writer quits
        let reply = MacAppDelegate.terminateReply(viewModel: viewModel) { _ in
            Issue.record("asked with nothing unsaved")
            return .keepOpen
        }

        // Then: the app quits without asking
        #expect(reply == .terminateNow)
        #expect(viewModel.saveStatus != .failed)
    }

    @Test
    func aFailedSaveClearsOnALaterSaveOrOpen() throws {
        // Given: an edit the library refused, and a second song
        let (viewModel, container) = try Self.library()
        let song = SongProject(id: "s", title: "Harbour Lights", lyrics: "ropes", theme: "")
        let other = SongProject(id: "t", title: "Paper Moon", lyrics: "tide", theme: "")
        container.mainContext.insert(song)
        container.mainContext.insert(other)
        try container.mainContext.save()
        viewModel.loadProject(song)
        viewModel.lyrics = "ropes and tide"
        viewModel.modelContext = nil
        #expect(!viewModel.flushCurrentDraft())
        #expect(viewModel.saveStatus == .failed)

        // When: a later save succeeds
        viewModel.modelContext = container.mainContext
        let workspace = MacWorkspaceModel()
        workspace.save(viewModel)

        // Then: the failure is gone and Quit does not ask
        #expect(workspace.saveError == nil)
        #expect(viewModel.saveStatus == .saved)
        #expect(MacAppDelegate.terminateReply(viewModel: viewModel) { _ in Issue.record("asked after a save"); return .keepOpen } == .terminateNow)

        // Given: then an edit refused because the open song's row is gone, undone again
        container.mainContext.delete(song)
        try container.mainContext.save()
        viewModel.lyrics = "ropes and tide, edited"
        #expect(!viewModel.flushCurrentDraft())
        #expect(viewModel.saveStatus == .failed)
        viewModel.lyrics = "ropes and tide"

        // When: the writer opens the other song
        #expect(workspace.openSong(other, in: viewModel))

        // Then: the failure is gone and Quit does not ask
        #expect(viewModel.saveStatus == .idle)
        #expect(MacAppDelegate.terminateReply(viewModel: viewModel) { _ in Issue.record("asked after an open"); return .keepOpen } == .terminateNow)
    }

    @Test
    func fileSaveOnAnUneditedSongWhoseRowIsGoneSaysNothingAndStaysIdle() throws {
        let (viewModel, container) = try Self.vanishedUnedited()
        _ = container
        let workspace = MacWorkspaceModel()

        workspace.save(viewModel)

        #expect(workspace.saveError == nil)
        #expect(viewModel.saveStatus == .idle)
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

extension OneLinerRouterSuites {
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

        /// The library the app opens: a fresh in-memory store with every model of the app's
        /// own schema, holding a song and a One Liner so each page lays out a real row.
        private static func appLibrary() throws -> (ModelContainer, SongProject) {
            let schema = try #require(ModelContainerBootstrap.shared.container?.schema)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            let song = SongProject(id: "s", title: "Harbour Lights", lyrics: "ropes and tide", theme: "")
            container.mainContext.insert(song)
            container.mainContext.insert(OneLiner(text: "the harbour keeps the light we left on the water"))
            try container.mainContext.save()
            return (container, song)
        }

        private static func workspace(_ detail: MacWorkspaceModel.Detail, sidebar: NavigationSplitViewVisibility, opening song: SongProject?, assistant: Bool, in container: ModelContainer) -> (EditorViewModel, MacWorkspaceModel) {
            let viewModel = EditorViewModel(companionStore: WritingCompanionStore(inMemory: true))
            viewModel.modelContext = container.mainContext
            if let song { viewModel.loadProject(song) }
            let workspace = MacWorkspaceModel()
            workspace.sidebarVisibility = sidebar
            workspace.detail = detail
            workspace.windowOpen = true
            workspace.showsAssistant = assistant
            return (viewModel, workspace)
        }

        /// The window's minimum width with this page shown, as AppKit sets it once the hosted
        /// window has run its layout, and the widths of the sidebar and Assistant columns laid
        /// out beside the page (0 when hidden).
        private static func minimumWidth(of detail: MacWorkspaceModel.Detail, sidebar: NavigationSplitViewVisibility, opening song: SongProject? = nil, assistant: Bool = false, in container: ModelContainer) throws -> (window: CGFloat, sidebar: CGFloat, assistant: CGFloat, songShown: Bool, settle: String) {
            let (viewModel, workspace) = Self.workspace(detail, sidebar: sidebar, opening: song, assistant: assistant, in: container)
            let view = NSHostingView(rootView: MacWorkspaceView()
                .environmentObject(viewModel)
                .environmentObject(workspace)
                .environmentObject(AppPersistenceState(persistenceDegraded: false, cloudSyncStatus: .localOnlyFallback, usesCloudBackedStore: false))
                .environmentObject(GGUFDownloadManager.shared)
                .modelContainer(container))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            func splits(_ v: NSView) -> [NSSplitView] { ((v as? NSSplitView).map { [$0] } ?? []) + v.subviews.flatMap(splits) }
            // One layout pass: the window's minimum, the shown sidebar and Assistant widths, and
            // every split view's columns for the failure message.
            func measure() throws -> (window: CGFloat, sidebar: CGFloat, assistant: CGFloat, columns: String) {
                view.layoutSubtreeIfNeeded()
                // The outer split view holds the sidebar and the detail column; the detail's own
                // split view holds the page and the Assistant.
                let all = splits(view)
                let columns = try #require(all.first, "a split view is laid out").arrangedSubviews
                let inner = try #require(all.dropFirst().first, "the detail's split view is laid out").arrangedSubviews
                let sidebarWidth = columns.count > 1 && !columns[0].isHidden ? columns[0].frame.width : 0
                let assistantWidth = inner.count > 1 && !inner[1].isHidden ? inner[1].frame.width : 0
                let layout = all.map { $0.arrangedSubviews.map { "\($0.isHidden ? "hidden" : "shown") \($0.frame.width)" }.joined(separator: ", ") }.joined(separator: " | ")
                return (window.contentMinSize.width, sidebarWidth, assistantWidth, layout)
            }
            // The page's floor follows the sidebar inset it reads back a pass or more later, which
            // a fixed wait can miss on a busy machine: pump the run loop until the requested columns
            // are in effect and the floor holds on two passes in a row, for up to 2 s. On timeout
            // the last pass goes back as it is, so the caller's expectation reports it.
            func holds(_ m: (window: CGFloat, sidebar: CGFloat, assistant: CGFloat, columns: String)) -> Bool {
                (m.sidebar > 0) == (sidebar != .detailOnly) && (m.assistant > 0) == assistant
                    && abs(m.window - m.sidebar - m.assistant - Self.pageFloor) <= 1
            }
            let start = ContinuousClock.now
            let first = try measure()
            var last = first
            var heldBefore = false
            while !(heldBefore && holds(last)) && ContinuousClock.now - start < .seconds(2) {
                heldBefore = holds(last)
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                last = try measure()
            }
            let settle = "after \(ContinuousClock.now - start): first min \(first.window) [\(first.columns)], last min \(last.window) [\(last.columns)]"
            return (last.window, last.sidebar, last.assistant, workspace.songOpen(in: viewModel), settle)
        }

        /// At the window's minimum every page keeps 440pt beside whatever sidebar and Assistant
        /// are shown (with the floor on the page itself the sidebar counted twice: 960 for One
        /// Liners in the real window, 728 here). This asserts that relation, not absolute widths:
        /// the harness lays out a 144pt sidebar where the app shows 260 (700 there, and 1060 for
        /// a song with the Assistant).
        @Test
        func everyPageKeepsAReadingWidthAtTheWindowsMinimum() throws {
            let (container, song) = try Self.appLibrary()
            var cases: [(String, (window: CGFloat, sidebar: CGFloat, assistant: CGFloat, songShown: Bool, settle: String))] = []
            for sidebar in [NavigationSplitViewVisibility.all, .detailOnly] {
                for detail in [MacWorkspaceModel.Detail.oneLiners, .trash] {
                    cases.append(("\(detail) \(sidebar)", try Self.minimumWidth(of: detail, sidebar: sidebar, in: container)))
                }
                for assistant in [false, true] {
                    cases.append(("song assistant=\(assistant) \(sidebar)", try Self.minimumWidth(of: .editor, sidebar: sidebar, opening: song, assistant: assistant, in: container)))
                }
            }
            for (name, m) in cases {
                #expect(abs(m.window - m.sidebar - m.assistant - Self.pageFloor) <= 1, "\(name): \(m)")
            }
            #expect(cases.filter { $0.0.hasPrefix("song") }.allSatisfy { $0.1.songShown }, "the editor, not the welcome screen")
            #expect(cases.contains { $0.1.sidebar > 0 } && cases.contains { $0.1.assistant > 0 }, "the sidebar and the Assistant are each laid out somewhere")
        }

        /// Written out rather than read from MacWorkspaceView, so changing the floor fails here.
        private static let pageFloor: CGFloat = 440
    }

    /// A song the sidebar's selection opens leaves the keyboard in the list, whatever held
    /// it before, so Delete and the arrows act on the list. The real sidebar in the real
    /// workspace, selected through its outline view as a row click selects. (A click on the
    /// row that is already selected changes no selection and is not covered here.) An open
    /// the outgoing song's unsaved edit refuses leaves the keyboard where it was.
    @MainActor
    struct SidebarSelectionFocusTests {
        enum Start: String, CaseIterable { case windowAfterTrash, lyrics, title, backFromTrashToTheOpenSong, refusedOpen }

        private static func settle(_ view: NSView, _ seconds: Double = 0.5) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { view.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }

        private static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
        }

        private static func host(_ viewModel: EditorViewModel, _ workspace: MacWorkspaceModel, _ container: ModelContainer) -> (NSView, NSWindow) {
            let view = NSHostingView(rootView: MacWorkspaceView()
                .environmentObject(viewModel)
                .environmentObject(workspace)
                .environmentObject(AppPersistenceState(persistenceDegraded: false, cloudSyncStatus: .localOnlyFallback, usesCloudBackedStore: false))
                .environmentObject(GGUFDownloadManager.shared)
                .modelContainer(container))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            return (view, window)
        }

        /// Types into the sidebar's search field as the writer does.
        private static func search(_ text: String, in view: NSView) throws {
            let field = try #require(views(NSSearchField.self, in: view).first)
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            settle(view)
        }

        @Test
        func aNewSongsSavedCopyIsTheOneSelectedSoASiblingUnderItsIdIsNeverDeleted() throws {
            let schema = try #require(ModelContainerBootstrap.shared.container?.schema)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            let viewModel = EditorViewModel(companionStore: WritingCompanionStore(inMemory: true))
            viewModel.modelContext = container.mainContext
            let workspace = MacWorkspaceModel()
            workspace.windowOpen = true
            let (view, window) = Self.host(viewModel, workspace, container)
            defer { window.close() }

            // Given: a song made with New Song and saved for the first time
            workspace.detail = .editor
            viewModel.newProject()
            viewModel.title = "Harbour Lights"
            viewModel.lyrics = "ropes"
            viewModel.triggerAutoSave()
            #expect(viewModel.savePendingEdit())
            let id = try #require(viewModel.currentProjectId)
            let a = try #require(try container.mainContext.fetch(FetchDescriptor<SongProject>()).first)
            // and a second copy under its id (a restore on another device, then sync), newer
            let b = SongProject(id: id, title: "Paper Moon", lyrics: "tide", theme: "")
            b.updatedAt = a.updatedAt.addingTimeInterval(60)
            container.mainContext.insert(b)
            try container.mainContext.save()
            Self.settle(view)
            let outline = try #require(Self.views(NSOutlineView.self, in: view).first)

            // When: the search shows only the second copy while the first stays open
            let rows = outline.numberOfRows
            try Self.search("Paper", in: view)
            #expect(outline.numberOfRows == rows - 1, "the search hides the open song's row")

            // Then: no song row is selected
            #expect(outline.selectedRowIndexes.isEmpty, "selected rows: \(Array(outline.selectedRowIndexes)) of \(outline.numberOfRows)")

            // When: Delete runs on the sidebar's selection. (Its key command needs a key window,
            // which this one is not, so the test calls the action the command calls.)
            let shown = SongProject.matching(try container.mainContext.fetch(FetchDescriptor<SongProject>()), searchText: "Paper")
            let selected = MacSongSidebar.openRow(loaded: viewModel.loadedProjectRow, in: shown)?.persistentModelID
            #expect(!MacSongSidebar.delete(selected, in: shown, viewModel: viewModel))

            // Then: both copies keep their words and nothing went to Trash
            #expect(a.title == "Harbour Lights" && a.lyrics == "ropes", "\(a.title): \(a.lyrics)")
            #expect(b.title == "Paper Moon" && b.lyrics == "tide", "\(b.title): \(b.lyrics)")
            #expect(try container.mainContext.fetch(FetchDescriptor<SongProject>()).filter { $0.id == id }.count == 2)
            #expect(try container.mainContext.fetch(FetchDescriptor<TrashedSongProject>()).isEmpty)

            // And: with the search cleared the open song's row is selected again (the older, last row)
            try Self.search("", in: view)
            #expect(Array(outline.selectedRowIndexes) == [outline.numberOfRows - 1], "selected rows: \(Array(outline.selectedRowIndexes)) of \(outline.numberOfRows)")
            #expect(viewModel.loadedProjectRow == a.persistentModelID)
        }

        @Test(arguments: Start.allCases)
        func aSongSelectedInTheSidebarTakesTheKeyboardIntoTheList(_ start: Start) throws {
            let schema = try #require(ModelContainerBootstrap.shared.container?.schema)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            let a = SongProject(id: "a", title: "Alpha", lyrics: "harbour lights", theme: "")
            let b = SongProject(id: "b", title: "Beta", lyrics: "paper moon", theme: "")
            a.updatedAt = Date(timeIntervalSince1970: 1_000)
            b.updatedAt = Date(timeIntervalSince1970: 2_000)
            container.mainContext.insert(a)
            container.mainContext.insert(b)
            try container.mainContext.save()
            let viewModel = EditorViewModel(companionStore: WritingCompanionStore(inMemory: true))
            viewModel.modelContext = container.mainContext
            let workspace = MacWorkspaceModel()
            workspace.windowOpen = true
            let view = NSHostingView(rootView: MacWorkspaceView()
                .environmentObject(viewModel)
                .environmentObject(workspace)
                .environmentObject(AppPersistenceState(persistenceDegraded: false, cloudSyncStatus: .localOnlyFallback, usesCloudBackedStore: false))
                .environmentObject(GGUFDownloadManager.shared)
                .modelContainer(container))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }

            // Given: Alpha opened by a command, then the keyboard where this case puts it
            workspace.openSong(a, in: viewModel)
            Self.settle(view)
            let outline = try #require(Self.views(NSOutlineView.self, in: view).first)
            switch start {
            case .lyrics:
                #expect(window.firstResponder is LyricsNSTextView)
            case .refusedOpen:
                #expect(window.firstResponder is LyricsNSTextView)
                // An edit with no library to save it to: opening another song is refused.
                viewModel.modelContext = nil
                viewModel.lyrics = "harbour lights and tide"
            case .title:
                // Its accessibility identifier, songTitleEditor, is not on the AppKit field, so
                // the title is found by its own prompt, which the theme field does not share.
                let title = try #require(Self.views(NSTextField.self, in: view).first { $0.placeholderString == "Song Title..." })
                #expect(window.makeFirstResponder(title))
                #expect((window.firstResponder as? NSTextView)?.delegate === title, "the title's field editor has the keyboard")
            case .windowAfterTrash, .backFromTrashToTheOpenSong:
                workspace.detail = .trash
                Self.settle(view)
                #expect(window.firstResponder === window, "the focused lyrics left with the editor")
            }
            #expect(window.firstResponder !== outline)
            let before = window.firstResponder
            if start == .refusedOpen { #expect(before is LyricsNSTextView) }

            // When: the sidebar selects a song (songs are the last rows, newest first)
            let opening = start == .backFromTrashToTheOpenSong ? a : b
            outline.selectRowIndexes([outline.numberOfRows - (opening === a ? 1 : 2)], byExtendingSelection: false)
            Self.settle(view)

            // Then
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            if start == .refusedOpen {
                #expect(viewModel.loadedProjectRow == a.persistentModelID, "the refused open keeps Alpha")
                #expect(window.firstResponder === before, "the lyrics keep the keyboard, not the list, where Delete would trash Alpha: \(responder)")
                // Save the edit to its library now; the close's own save does not retry a failed
                // one and would report the song unsaved in a modal alert.
                viewModel.modelContext = container.mainContext
                #expect(viewModel.flushCurrentDraft())
                #expect(a.lyrics == "harbour lights and tide")
            } else {
                #expect(viewModel.loadedProjectRow == opening.persistentModelID && workspace.detail == .editor)
                #expect(window.firstResponder === outline, "\(start): \(responder)")
            }
        }
    }
}
#endif
