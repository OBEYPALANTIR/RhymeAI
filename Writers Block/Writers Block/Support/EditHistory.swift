import Foundation

struct LyricsEditState: Equatable {
    let text: String
    let cursorPosition: Int
    let selectedRange: NSRange
}

final class EditHistory<State: Equatable> {
    private let capacity: Int
    private let coalescingWindowMilliseconds: Int64
    private var undoStack: [State] = []
    private var redoStack: [State] = []
    private var lastUserEditTimestamp: Int64?

    init(capacity: Int = 100, coalescingWindowMilliseconds: Int64 = 750) {
        precondition(capacity > 0)
        precondition(coalescingWindowMilliseconds >= 0)
        self.capacity = capacity
        self.coalescingWindowMilliseconds = coalescingWindowMilliseconds
    }

    // Xcode 26.6's optimizer crashes on the synthesized generic deinitializer.
    @_optimize(none)
    deinit {}

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func recordUserEdit(previous: State, current: State, timestampMilliseconds: Int64) {
        guard previous != current else { return }
        let isWithinWindow = lastUserEditTimestamp.map {
            timestampMilliseconds >= $0 && timestampMilliseconds - $0 <= coalescingWindowMilliseconds
        } ?? false
        if !isWithinWindow || !redoStack.isEmpty {
            append(previous, to: &undoStack)
        }
        redoStack.removeAll(keepingCapacity: true)
        lastUserEditTimestamp = timestampMilliseconds
    }

    func recordAtomicEdit(previous: State, current: State) {
        guard previous != current else { return }
        append(previous, to: &undoStack)
        redoStack.removeAll(keepingCapacity: true)
        lastUserEditTimestamp = nil
    }

    func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        append(current, to: &redoStack)
        lastUserEditTimestamp = nil
        return previous
    }

    func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        append(current, to: &undoStack)
        lastUserEditTimestamp = nil
        return next
    }

    func reset() {
        undoStack.removeAll(keepingCapacity: true)
        redoStack.removeAll(keepingCapacity: true)
        lastUserEditTimestamp = nil
    }

    private func append(_ state: State, to stack: inout [State]) {
        if stack.count == capacity {
            stack.removeFirst()
        }
        stack.append(state)
    }
}
