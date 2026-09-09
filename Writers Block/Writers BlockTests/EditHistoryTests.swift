import Testing
@testable import Writers_Block

struct EditHistoryTests {
    @Test
    func undoAndRedoRestoreRecordedStates() {
        // Given
        let history = EditHistory<String>()
        history.recordAtomicEdit(previous: "", current: "first line")

        // When
        let undone = history.undo(current: "first line")
        let redone = history.redo(current: undone ?? "")

        // Then
        #expect(undone == "")
        #expect(redone == "first line")
        #expect(history.canUndo)
        #expect(!history.canRedo)
    }

    @Test
    func rapidTypingCoalescesIntoOneUndoStep() {
        // Given
        let history = EditHistory<String>(coalescingWindowMilliseconds: 750)
        history.recordUserEdit(previous: "", current: "h", timestampMilliseconds: 0)
        history.recordUserEdit(previous: "h", current: "he", timestampMilliseconds: 200)
        history.recordUserEdit(previous: "he", current: "hey", timestampMilliseconds: 400)

        // When
        let undone = history.undo(current: "hey")

        // Then
        #expect(undone == "")
        #expect(!history.canUndo)
    }

    @Test
    func typingAfterAPauseStartsAnotherUndoStep() {
        // Given
        let history = EditHistory<String>(coalescingWindowMilliseconds: 750)
        history.recordUserEdit(previous: "", current: "a", timestampMilliseconds: 0)
        history.recordUserEdit(previous: "a", current: "ab", timestampMilliseconds: 1_000)

        // When
        let undone = history.undo(current: "ab")

        // Then
        #expect(undone == "a")
        #expect(history.canUndo)
    }

    @Test
    func newEditAfterUndoClearsRedoHistory() {
        // Given
        let history = EditHistory<String>()
        history.recordAtomicEdit(previous: "", current: "first")
        let restored = history.undo(current: "first") ?? ""

        // When
        history.recordAtomicEdit(previous: restored, current: "second")

        // Then
        #expect(!history.canRedo)
        #expect(history.undo(current: "second") == "")
    }

    @Test
    func resetClearsBothDirections() {
        // Given
        let history = EditHistory<String>()
        history.recordAtomicEdit(previous: "", current: "draft")
        _ = history.undo(current: "draft")

        // When
        history.reset()

        // Then
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }
}
