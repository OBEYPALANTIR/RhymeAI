import Foundation
import SwiftData
import Testing
@testable import Writers_Block

struct PersistenceTests {

    @MainActor
    @Test func importProjectPersistsProjectAndSelectsItForEditing() throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context
        let exported = SongProjectExport(
            from: SongProject(
                id: "source-project-id",
                title: "",
                lyrics: "  imported first line\nimported second line",
                theme: "clear signal",
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        viewModel.importProject(exported)

        let projects = try Self.fetchProjects(context)
        let imported = try #require(projects.first)

        #expect(projects.count == 1)
        #expect(imported.id != exported.id)
        #expect(imported.title == "Imported Song")
        #expect(imported.lyrics == exported.lyrics)
        #expect(imported.theme == exported.theme)
        #expect(viewModel.currentProjectId == imported.id)
        #expect(viewModel.title == imported.title)
        #expect(viewModel.lyrics == imported.lyrics)
        #expect(viewModel.theme == imported.theme)
        #expect(viewModel.cursorPosition == imported.lyrics.count)
        #expect(viewModel.saveStatus == .saved)
    }

    @MainActor
    @Test func autoSaveCreatesProjectAndPersistsEditorFields() async throws {
        let harness = try Self.makeHarness()
        let viewModel = harness.viewModel
        let context = harness.context

        viewModel.title = "Autosaved Draft"
        viewModel.lyrics = "first line\nsecond line"
        viewModel.theme = "late-night resolve"
        viewModel.triggerAutoSave()

        try await Task.sleep(for: .milliseconds(1_300))

        let projects = try Self.fetchProjects(context)
        let saved = try #require(projects.first)

        #expect(projects.count == 1)
        #expect(viewModel.currentProjectId == saved.id)
        #expect(viewModel.saveStatus == .saved)
        #expect(saved.title == "Autosaved Draft")
        #expect(saved.lyrics == "first line\nsecond line")
        #expect(saved.theme == "late-night resolve")
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
        var descriptor = FetchDescriptor<SongProject>(
            sortBy: [SortDescriptor(\.title)]
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
