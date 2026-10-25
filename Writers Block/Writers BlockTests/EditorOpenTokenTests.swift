import Foundation
import SwiftData
import Testing
@testable import Writers_Block

/// The editor's open token drives the writing column's cross-fade and the New
/// Song title focus: one fresh token per song opened or started, none for a save.
struct EditorOpenTokenTests {
    @MainActor
    private static func makeViewModel() throws -> (EditorViewModel, ModelContainer) {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let viewModel = EditorViewModel()
        viewModel.modelContext = container.mainContext
        return (viewModel, container)
    }

    @MainActor
    @Test func newSongIssuesAFreshTokenThatAsksForTitleFocus() throws {
        let (viewModel, _) = try Self.makeViewModel()
        let before = viewModel.editorOpen
        #expect(!before.isNewSong)

        viewModel.newProject()

        #expect(viewModel.editorOpen != before)
        #expect(viewModel.editorOpen.isNewSong)
    }

    @MainActor
    @Test func openingASavedSongIssuesAFreshTokenWithoutTitleFocus() throws {
        let (viewModel, container) = try Self.makeViewModel()
        let project = SongProject(id: "song-1", title: "Harbour Lights", lyrics: "The ropes drip water on the train", theme: "")
        container.mainContext.insert(project)
        try container.mainContext.save()
        viewModel.newProject()
        let newSongOpen = viewModel.editorOpen

        viewModel.loadProject(project)

        #expect(viewModel.editorOpen != newSongOpen)
        #expect(!viewModel.editorOpen.isNewSong)
        #expect(viewModel.title == "Harbour Lights")
    }

    @MainActor
    @Test func anUnsavedSongsFirstSaveKeepsItsToken() throws {
        let (viewModel, _) = try Self.makeViewModel()
        viewModel.newProject()
        let open = viewModel.editorOpen

        viewModel.title = "Paper Moon"
        #expect(viewModel.flushCurrentDraft())

        #expect(viewModel.currentProjectId != nil)
        #expect(viewModel.editorOpen == open)
    }
}
