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

        let song = try #require(WelcomeView.continueSong(in: try Self.fetchProjects(context), lastOpenedId: viewModel.currentProjectId))
        WelcomeView.continueSong(song, viewModel)

        #expect(viewModel.currentProjectId == "newest")
        #expect(viewModel.loadedProjectRow == newest.persistentModelID)
        #expect(viewModel.lyrics == "new words")
        #expect(!viewModel.showWelcome && !viewModel.showProjectsSheet)
    }

    @MainActor
    @Test func noSongsMeansNoContinue() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        #expect(WelcomeView.continueSong(in: try Self.fetchProjects(context), lastOpenedId: viewModel.currentProjectId) == nil)
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
        let fallback = WelcomeView.continueSong(in: try Self.fetchProjects(context), lastOpenedId: "last")
        #expect(fallback?.id == "other")

        // With the only remaining song trashed too, nothing is opened directly.
        #expect(viewModel.moveProjectToTrash(other))
        #expect(WelcomeView.continueSong(in: try Self.fetchProjects(context), lastOpenedId: "other") == nil)
    }

    @MainActor
    @Test func loadSongStillOpensTheProjectsSheet() throws {
        let (viewModel, context, container) = try Self.makeHarness()
        _ = container
        context.insert(SongProject(id: "song", title: "Song", lyrics: "words", theme: ""))
        try context.save()
        #expect(WelcomeView.continueSong(in: try Self.fetchProjects(context), lastOpenedId: nil) != nil)

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
