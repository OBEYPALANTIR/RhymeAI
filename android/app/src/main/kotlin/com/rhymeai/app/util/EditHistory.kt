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

    /** Moves on with every change to the history, so an edit can be identified later. */
    var revision = 0L
        private set

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
        revision++
    }

    fun recordAtomicEdit(previous: State, current: State) {
        if (previous == current) return
        append(previous, undoStack)
        redoStack.clear()
        lastUserEditTimestamp = null
        revision++
    }

    fun undo(current: State): State? {
        val previous = undoStack.removeLastOrNull() ?: return null
        append(current, redoStack)
        lastUserEditTimestamp = null
        revision++
        return previous
    }

    fun redo(current: State): State? {
        val next = redoStack.removeLastOrNull() ?: return null
        append(current, undoStack)
        lastUserEditTimestamp = null
        revision++
        return next
    }

    fun reset() {
        undoStack.clear()
        redoStack.clear()
        lastUserEditTimestamp = null
        revision++
    }

    /**
     * Undoes the edit recorded at [revision] only while it is still the latest change; any
     * edit, undo or redo since (even one that leaves the same text) keeps the history as is.
     */
    fun undoIfLatest(revision: Long, current: State): State? =
        if (revision == this.revision) undo(current) else null

    private fun append(state: State, stack: ArrayDeque<State>) {
        if (stack.size == capacity) {
            stack.removeFirst()
        }
        stack.addLast(state)
    }
}
