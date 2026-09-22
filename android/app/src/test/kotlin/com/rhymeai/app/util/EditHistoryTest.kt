package com.rhymeai.app.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditHistoryTest {
    @Test
    fun undoAndRedoRestoreRecordedStates() {
        // Given
        val history = EditHistory<String>()
        history.recordAtomicEdit(previous = "", current = "first line")

        // When
        val undone = history.undo(current = "first line")
        val redone = history.redo(current = undone.orEmpty())

        // Then
        assertEquals("", undone)
        assertEquals("first line", redone)
        assertTrue(history.canUndo)
        assertFalse(history.canRedo)
    }

    @Test
    fun rapidTypingCoalescesIntoOneUndoStep() {
        // Given
        val history = EditHistory<String>(coalescingWindowMilliseconds = 750)
        history.recordUserEdit(previous = "", current = "h", timestampMilliseconds = 0)
        history.recordUserEdit(previous = "h", current = "he", timestampMilliseconds = 200)
        history.recordUserEdit(previous = "he", current = "hey", timestampMilliseconds = 400)

        // When
        val undone = history.undo(current = "hey")

        // Then
        assertEquals("", undone)
        assertFalse(history.canUndo)
    }

    @Test
    fun typingAfterAPauseStartsAnotherUndoStep() {
        // Given
        val history = EditHistory<String>(coalescingWindowMilliseconds = 750)
        history.recordUserEdit(previous = "", current = "a", timestampMilliseconds = 0)
        history.recordUserEdit(previous = "a", current = "ab", timestampMilliseconds = 1_000)

        // When
        val undone = history.undo(current = "ab")

        // Then
        assertEquals("a", undone)
        assertTrue(history.canUndo)
    }

    @Test
    fun newEditAfterUndoClearsRedoHistory() {
        // Given
        val history = EditHistory<String>()
        history.recordAtomicEdit(previous = "", current = "first")
        val restored = history.undo(current = "first").orEmpty()

        // When
        history.recordAtomicEdit(previous = restored, current = "second")

        // Then
        assertFalse(history.canRedo)
        assertEquals("", history.undo(current = "second"))
    }

    @Test
    fun resetClearsBothDirections() {
        // Given
        val history = EditHistory<String>()
        history.recordAtomicEdit(previous = "", current = "draft")
        history.undo(current = "draft")

        // When
        history.reset()

        // Then
        assertFalse(history.canUndo)
        assertFalse(history.canRedo)
    }
}
