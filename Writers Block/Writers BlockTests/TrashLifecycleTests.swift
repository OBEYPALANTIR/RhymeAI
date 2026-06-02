import Foundation
import SwiftData
import Testing
@testable import Writers_Block

struct TrashLifecycleTests {

    @MainActor
    @Test func moveProjectToTrashClearsCurrentEditorAndCreatesTrashEntry() throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context
        let updatedAt = Date(timeIntervalSince1970: 1_780_374_654)
        let project = SongProject(
            id: "song-1",
            title: "Draft",
            lyrics: "yellow music",
            theme: "late-night resolve",
            updatedAt: updatedAt
        )
        context.insert(project)
        try context.save()

        viewModel.title = project.title
        viewModel.lyrics = project.lyrics
        viewModel.theme = project.theme
        viewModel.currentProjectId = project.id
        viewModel.suggestions = ["keep this clear"]

        viewModel.moveProjectToTrash(project)

        let activeProjects = try Self.fetchProjects(context)
        let trash = try Self.fetchTrash(context)
        let trashed = try #require(trash.first)

        #expect(activeProjects.isEmpty)
        #expect(trash.count == 1)
        #expect(trashed.id == "song-1")
        #expect(trashed.title == "Draft")
        #expect(trashed.lyrics == "yellow music")
        #expect(trashed.theme == "late-night resolve")
        #expect(trashed.updatedAt == updatedAt)
        #expect(trashed.deleteAfter.timeIntervalSince(trashed.deletedAt) == trashRetentionInterval)
        #expect(viewModel.currentProjectId == nil)
        #expect(viewModel.title.isEmpty)
        #expect(viewModel.lyrics.isEmpty)
        #expect(viewModel.theme.isEmpty)
        #expect(viewModel.suggestions.isEmpty)
    }

    @MainActor
    @Test func restoreTrashedProjectReplacesExistingActiveProject() throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context
        let staleActive = SongProject(
            id: "song-1",
            title: "Stale Active",
            lyrics: "old lyrics",
            theme: "",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let trashed = TrashedSongProject(
            id: "song-1",
            title: "Restored Draft",
            lyrics: "new lyrics",
            theme: "clear signal",
            updatedAt: Date(timeIntervalSince1970: 200),
            deletedAt: Date(timeIntervalSince1970: 300)
        )
        context.insert(staleActive)
        context.insert(trashed)
        try context.save()

        viewModel.restoreTrashedProject(trashed)

        let activeProjects = try Self.fetchProjects(context)
        let restored = try #require(activeProjects.first)

        #expect(activeProjects.count == 1)
        #expect(restored.id == "song-1")
        #expect(restored.title == "Restored Draft")
        #expect(restored.lyrics == "new lyrics")
        #expect(restored.theme == "clear signal")
        #expect(restored.updatedAt > trashed.deletedAt)
        #expect(try Self.fetchTrash(context).isEmpty)
    }

    @MainActor
    @Test func purgeExpiredTrashedProjectsKeepsUnexpiredTrash() throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context
        let now = Date()
        let expired = TrashedSongProject(
            id: "expired",
            title: "Expired",
            lyrics: "",
            theme: "",
            updatedAt: now,
            deletedAt: now.addingTimeInterval(-trashRetentionInterval - 60),
            deleteAfter: now.addingTimeInterval(-60)
        )
        let retained = TrashedSongProject(
            id: "retained",
            title: "Retained",
            lyrics: "",
            theme: "",
            updatedAt: now,
            deletedAt: now,
            deleteAfter: now.addingTimeInterval(60)
        )
        context.insert(expired)
        context.insert(retained)
        try context.save()

        viewModel.purgeExpiredTrashedProjects()

        let trashIds = try Self.fetchTrash(context).map(\.id)

        #expect(trashIds == ["retained"])
    }

    @MainActor
    private static func makeHarness() throws -> Harness {
        let schema = Schema([SongProject.self, TrashedSongProject.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let viewModel = EditorViewModel()
        viewModel.modelContext = container.mainContext
        return Harness(viewModel: viewModel, container: container)
    }

    @MainActor
    private static func fetchProjects(_ context: ModelContext) throws -> [SongProject] {
        try context.fetch(FetchDescriptor<SongProject>())
    }

    @MainActor
    private static func fetchTrash(_ context: ModelContext) throws -> [TrashedSongProject] {
        var descriptor = FetchDescriptor<TrashedSongProject>(
            sortBy: [SortDescriptor(\.id)]
        )
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    @MainActor
    private struct Harness {
        let viewModel: EditorViewModel
        let container: ModelContainer

        var context: ModelContext {
            container.mainContext
        }
    }
}
