import Testing
@testable import Writers_Block

struct EditHistoryTests {
    @Test
    func undoAndRedoRestoreRecordedStates() {
        let history = EditHistory<String>()
        history.recordAtomicEdit(previous: "", current: "first line")

        let undone = history.undo(current: "first line")
        let redone = history.redo(current: undone ?? "")

        #expect(undone == "")
        #expect(redone == "first line")
        #expect(history.canUndo)
        #expect(!history.canRedo)
    }

    @Test
    func rapidTypingCoalescesIntoOneUndoStep() {
        let history = EditHistory<String>(coalescingWindowMilliseconds: 750)
        history.recordUserEdit(previous: "", current: "h", timestampMilliseconds: 0)
        history.recordUserEdit(previous: "h", current: "he", timestampMilliseconds: 200)
        history.recordUserEdit(previous: "he", current: "hey", timestampMilliseconds: 400)

        let undone = history.undo(current: "hey")

        #expect(undone == "")
        #expect(!history.canUndo)
    }

    @Test
    func typingAfterAPauseStartsAnotherUndoStep() {
        let history = EditHistory<String>(coalescingWindowMilliseconds: 750)
        history.recordUserEdit(previous: "", current: "a", timestampMilliseconds: 0)
        history.recordUserEdit(previous: "a", current: "ab", timestampMilliseconds: 1_000)

        let undone = history.undo(current: "ab")

        #expect(undone == "a")
        #expect(history.canUndo)
    }

    @Test
    func newEditAfterUndoClearsRedoHistory() {
        let history = EditHistory<String>()
        history.recordAtomicEdit(previous: "", current: "first")
        let restored = history.undo(current: "first") ?? ""

        history.recordAtomicEdit(previous: restored, current: "second")

        #expect(!history.canRedo)
        #expect(history.undo(current: "second") == "")
    }

    @Test
    func resetClearsBothDirections() {
        let history = EditHistory<String>()
        history.recordAtomicEdit(previous: "", current: "draft")
        _ = history.undo(current: "draft")

        history.reset()

        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }
}
