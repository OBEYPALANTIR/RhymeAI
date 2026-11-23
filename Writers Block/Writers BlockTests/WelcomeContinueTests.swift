// Welcome is the iPhone and iPad screen; the Mac window has its own.
#if !os(macOS)
import Foundation
import SwiftData
import Testing
@testable import Writers_Block

struct WelcomeContinueTests {

    @MainActor
    @Test func continueOpensExactlyTheMostRecentSong() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        let older = SongProject(id: "older", title: "Older", lyrics: "old words", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newest = SongProject(id: "newest", title: "Newest", lyrics: "new words", theme: "", updatedAt: Date(timeIntervalSince1970: 2_000))
        context.insert(older)
        context.insert(newest)
        try context.save()

        let song = try #require(viewModel.continueSong(in: try Self.fetchProjects(context), context: context))
        viewModel.continueSong(song)

        #expect(viewModel.currentProjectId == "newest")
        #expect(viewModel.loadedProjectRow == newest.persistentModelID)
        #expect(viewModel.lyrics == "new words")
        #expect(!viewModel.showWelcome && !viewModel.showProjectsSheet)
    }

    @MainActor
    @Test func continuePrefersTheLastOpenSongOverANewerOne() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        let lastOpen = SongProject(id: "last-open", title: "Last Open", lyrics: "open words", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = SongProject(id: "newer", title: "Newer", lyrics: "newer words", theme: "", updatedAt: Date(timeIntervalSince1970: 2_000))
        context.insert(lastOpen)
        context.insert(newer)
        try context.save()
        viewModel.loadProject(lastOpen)
        viewModel.goToStartMenu()
        #expect(viewModel.showWelcome)

        // Back on Welcome, the song last open still wins even if another was updated later (sync, import).
        newer.updatedAt = Date().addingTimeInterval(3_600)
        try context.save()
        #expect(viewModel.continueSong(in: try Self.fetchProjects(context), context: context)?.id == "last-open")
    }

    @MainActor
    @Test func continuePrefersTheBoundRowOverANewerDuplicate() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        let opened = SongProject(id: "dup", title: "Dup", lyrics: "opened words", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newerDuplicate = SongProject(id: "dup", title: "Dup", lyrics: "other device words", theme: "", updatedAt: Date(timeIntervalSince1970: 2_000))
        context.insert(opened)
        context.insert(newerDuplicate)
        try context.save()
        viewModel.loadProject(opened)
        viewModel.goToStartMenu()

        let song = viewModel.continueSong(in: try Self.fetchProjects(context), context: context)
        #expect(song?.persistentModelID == opened.persistentModelID)
    }

    @MainActor
    @Test func noSongsMeansNoContinue() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        #expect(viewModel.continueSong(in: try Self.fetchProjects(context), context: context) == nil)
    }

    @MainActor
    @Test func aTrashedLastOpenSongIsNeverContinued() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        let other = SongProject(id: "other", title: "Other", lyrics: "other words", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000))
        let last = SongProject(id: "last", title: "Last", lyrics: "last words", theme: "", updatedAt: Date(timeIntervalSince1970: 2_000))
        context.insert(other)
        context.insert(last)
        try context.save()
        viewModel.loadProject(last)
        viewModel.goToStartMenu()

        // The last-open song goes to Trash: Continue falls back to the newest song still listed, as on Android.
        #expect(viewModel.moveProjectToTrash(last))
        #expect(viewModel.continueSong(in: try Self.fetchProjects(context), context: context)?.id == "other")

        // With the only remaining song trashed too, nothing is opened directly.
        #expect(viewModel.moveProjectToTrash(other))
        #expect(viewModel.continueSong(in: try Self.fetchProjects(context), context: context) == nil)
    }

    @MainActor
    @Test func aSongAStoredTombstoneWillRemoveIsNotContinued() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        let doomed = SongProject(id: "doomed", title: "Doomed", lyrics: "gone words", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000))
        context.insert(doomed)
        // Another device deleted it later; the launch pass that applies this has not run yet.
        try DeletionStore.upsert(SyncDeletion(projectId: "doomed", deletedAt: 2_000_000), in: context)
        try context.save()

        #expect(viewModel.continueSong(in: try Self.fetchProjects(context), context: context) == nil)
        viewModel.continueSong(doomed)
        #expect(viewModel.currentProjectId == nil && viewModel.showWelcome)
    }

    @MainActor
    @Test func aRowRemovedAfterTheCardWasDrawnIsNotOpened() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        context.insert(SongProject(id: "kept", title: "Kept", lyrics: "kept words", theme: "", updatedAt: Date(timeIntervalSince1970: 1_000)))
        context.insert(SongProject(id: "drawn", title: "Drawn", lyrics: "drawn words", theme: "", updatedAt: Date(timeIntervalSince1970: 2_000)))
        try context.save()
        let drawn = try #require(viewModel.continueSong(in: try Self.fetchProjects(context), context: context))
        #expect(drawn.id == "drawn")

        // Sync removes the drawn row before the tap arrives.
        context.delete(drawn)
        try context.save()
        viewModel.continueSong(drawn)

        #expect(viewModel.currentProjectId == nil && viewModel.showWelcome)
    }

    @MainActor
    @Test func aSecondContinueTapDoesNotOpenAgain() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        context.insert(SongProject(id: "song", title: "Song", lyrics: "words", theme: ""))
        try context.save()
        let song = try #require(viewModel.continueSong(in: try Self.fetchProjects(context), context: context))

        viewModel.continueSong(song)
        let firstOpen = viewModel.editorOpen
        viewModel.continueSong(song)

        #expect(viewModel.currentProjectId == "song")
        #expect(viewModel.editorOpen == firstOpen)
    }

    @MainActor
    @Test func loadSongStillOpensTheProjectsSheet() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        context.insert(SongProject(id: "song", title: "Song", lyrics: "words", theme: ""))
        try context.save()

        WelcomeView.loadSong(viewModel)

        #expect(viewModel.showProjectsSheet)
        #expect(viewModel.showWelcome && viewModel.currentProjectId == nil)
    }

    @MainActor
    private static func makeHarness() throws -> (EditorViewModel, ModelContext, ModelContainer) {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        // In-memory notebook, as TrashLifecycleTests does for songs that go to Trash.
        let viewModel = EditorViewModel(companionStore: WritingCompanionStore(inMemory: true))
        viewModel.modelContext = container.mainContext
        return (viewModel, container.mainContext, container)
    }

    @MainActor
    private static func fetchProjects(_ context: ModelContext) throws -> [SongProject] {
        // The projects sheet's order.
        var descriptor = FetchDescriptor<SongProject>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }
}
#endif
