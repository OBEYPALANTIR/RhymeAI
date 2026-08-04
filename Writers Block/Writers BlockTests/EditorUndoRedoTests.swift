import Testing
@testable import Writers_Block

struct EditorUndoRedoTests {
    @Test
    func typingCanBeUndoneAndRedone() {
        let viewModel = EditorViewModel()
        viewModel.newProject()
        viewModel.onLyricsChanged("first line", timestampMilliseconds: 0)

        viewModel.undoLyrics()

        #expect(viewModel.lyrics == "")
        #expect(viewModel.canRedoLyrics)

        viewModel.redoLyrics()

        #expect(viewModel.lyrics == "first line")
        #expect(viewModel.canUndoLyrics)
    }

    @Test
    func insertedSuggestionIsOneUndoableEdit() {
        let viewModel = EditorViewModel()
        viewModel.newProject()
        viewModel.lyrics = "opening line"
        viewModel.cursorPosition = viewModel.lyrics.utf16.count

        viewModel.insertSuggestion("next line")
        viewModel.undoLyrics()

        #expect(viewModel.lyrics == "opening line")
    }

    @Test
    func loadingAnotherProjectClearsHistory() {
        let viewModel = EditorViewModel()
        viewModel.newProject()
        viewModel.onLyricsChanged("temporary draft", timestampMilliseconds: 0)

        viewModel.loadProject(SongProject(title: "Loaded", lyrics: "saved lyrics"))

        #expect(!viewModel.canUndoLyrics)
        #expect(!viewModel.canRedoLyrics)
    }
}
