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

    @Test
    fun undoIfLatestUndoesThatEditWhileItIsStillTheLatest() {
        val history = EditHistory<String>()
        history.recordUserEdit(previous = "", current = "verse", timestampMilliseconds = 0)
        history.recordAtomicEdit(previous = "verse", current = "verse\nsent line")
        val insertion = history.revision

        assertEquals("verse", history.undoIfLatest(insertion, current = "verse\nsent line"))
    }

    @Test
    fun undoIfLatestLeavesLaterEditsAloneEvenWhenTheTextMatchesAgain() {
        val history = EditHistory<String>()
        history.recordAtomicEdit(previous = "verse", current = "verse\nsent line")
        val insertion = history.revision
        // The writer deletes the sent line, then types the same words back.
        history.recordUserEdit(previous = "verse\nsent line", current = "verse", timestampMilliseconds = 0)
        history.recordUserEdit(previous = "verse", current = "verse\nsent line", timestampMilliseconds = 5_000)

        assertEquals(null, history.undoIfLatest(insertion, current = "verse\nsent line"))
        // The writer's own undo still steps back through their typing.
        assertEquals("verse", history.undo(current = "verse\nsent line"))
    }
}
