import SwiftData
import Testing
@testable import Writers_Block

struct EditorUndoRedoTests {
    @Test
    func typingCanBeUndoneAndRedone() {
        // Given
        let viewModel = EditorViewModel()
        viewModel.newProject()
        viewModel.onLyricsChanged("first line", timestampMilliseconds: 0)

        // When
        viewModel.undoLyrics()

        // Then
        #expect(viewModel.lyrics == "")
        #expect(viewModel.canRedoLyrics)

        // When
        viewModel.redoLyrics()

        // Then
        #expect(viewModel.lyrics == "first line")
        #expect(viewModel.canUndoLyrics)
    }

    @Test
    func insertedSuggestionIsOneUndoableEdit() {
        // Given
        let viewModel = EditorViewModel()
        viewModel.newProject()
        viewModel.lyrics = "opening line"
        viewModel.cursorPosition = viewModel.lyrics.utf16.count

        // When
        viewModel.insertSuggestion("next line")
        viewModel.undoLyrics()

        // Then
        #expect(viewModel.lyrics == "opening line")
    }

    @MainActor
    @Test
    func loadingAnotherProjectClearsHistory() throws {
        // Given
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let viewModel = EditorViewModel()
        viewModel.modelContext = container.mainContext
        viewModel.newProject()
        viewModel.onLyricsChanged("temporary draft", timestampMilliseconds: 0)

        let loaded = SongProject(title: "Loaded", lyrics: "saved lyrics")
        container.mainContext.insert(loaded)
        try container.mainContext.save()

        // When
        viewModel.loadProject(loaded)

        // Then
        #expect(viewModel.currentProjectId == loaded.id)
        #expect(try container.mainContext.fetch(FetchDescriptor<SongProject>()).contains { $0.lyrics == "temporary draft" })
        #expect(!viewModel.canUndoLyrics)
        #expect(!viewModel.canRedoLyrics)
    }
}
