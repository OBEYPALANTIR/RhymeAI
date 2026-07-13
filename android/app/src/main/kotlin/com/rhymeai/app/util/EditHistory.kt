package com.rhymeai.app.util

internal class EditHistory<State>(
    private val capacity: Int = 100,
    private val coalescingWindowMilliseconds: Long = 750
) {
    private val undoStack = ArrayDeque<State>()
    private val redoStack = ArrayDeque<State>()
    private var lastUserEditTimestamp: Long? = null

    init {
        require(capacity > 0)
        require(coalescingWindowMilliseconds >= 0)
    }

    val canUndo: Boolean get() = undoStack.isNotEmpty()
    val canRedo: Boolean get() = redoStack.isNotEmpty()

    fun recordUserEdit(previous: State, current: State, timestampMilliseconds: Long) {
        if (previous == current) return
        val lastTimestamp = lastUserEditTimestamp
        val isWithinWindow = lastTimestamp != null &&
            timestampMilliseconds >= lastTimestamp &&
            timestampMilliseconds - lastTimestamp <= coalescingWindowMilliseconds
        if (!isWithinWindow || redoStack.isNotEmpty()) {
            append(previous, undoStack)
        }
        redoStack.clear()
        lastUserEditTimestamp = timestampMilliseconds
    }

    fun recordAtomicEdit(previous: State, current: State) {
        if (previous == current) return
        append(previous, undoStack)
        redoStack.clear()
        lastUserEditTimestamp = null
    }

    fun undo(current: State): State? {
        val previous = undoStack.removeLastOrNull() ?: return null
        append(current, redoStack)
        lastUserEditTimestamp = null
        return previous
    }

    fun redo(current: State): State? {
        val next = redoStack.removeLastOrNull() ?: return null
        append(current, undoStack)
        lastUserEditTimestamp = null
        return next
    }

    fun reset() {
        undoStack.clear()
        redoStack.clear()
        lastUserEditTimestamp = null
    }

    private fun append(state: State, stack: ArrayDeque<State>) {
        if (stack.size == capacity) {
            stack.removeFirst()
        }
        stack.addLast(state)
    }
}
