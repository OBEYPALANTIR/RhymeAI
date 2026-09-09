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

    @Test
    func loadingAnotherProjectClearsHistory() {
        // Given
        let viewModel = EditorViewModel()
        viewModel.newProject()
        viewModel.onLyricsChanged("temporary draft", timestampMilliseconds: 0)

        // When
        viewModel.loadProject(SongProject(title: "Loaded", lyrics: "saved lyrics"))

        // Then
        #expect(!viewModel.canUndoLyrics)
        #expect(!viewModel.canRedoLyrics)
    }
}
