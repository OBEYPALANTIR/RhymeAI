package com.rhymeai.app

import kotlin.test.Test
import kotlin.test.assertEquals

/** The editor's failed-save state, as on Apple: it stays until a save of the open words commits. */
class SaveFailureRulesTest {
    private data class Row(val case: String, val actual: Any, val expected: Any)

    @Test
    fun failedSaveStateFollowsTheAppleTable() {
        val r = SaveFailureRules
        val write = SaveFailureRules.WriteFailure.WRITE_ERROR
        val corrupt = SaveFailureRules.WriteFailure.REREAD_CORRUPT
        val missing = SaveFailureRules.WriteFailure.MISSING_ROW
        listOf(
            // SET
            Row("generic write failure of the open draft, words unedited", r.failedAfterWriteError(false, "a", "a", write, wordsEdited = false), true),
            Row("corrupt library on the reread", r.failedAfterWriteError(false, "a", "a", corrupt, wordsEdited = false), true),
            Row("missing row with edited words", r.failedAfterWriteError(false, "a", "a", missing, wordsEdited = true), true),
            Row("missing row with unedited words", r.failedAfterWriteError(false, "a", "a", missing, wordsEdited = false), false),
            Row("stale completion after a switch leaves the new draft clear", r.failedAfterWriteError(false, "old", "new", write, wordsEdited = true), false),
            Row("stale completion after a switch keeps the new draft's own failure", r.failedAfterWriteError(true, "old", "new", missing, wordsEdited = false), true),
            Row("stale completion after a detach", r.failedAfterWriteError(false, "old", null, write, wordsEdited = true), false),
            // Retry of an intentional erase still writes; with no song there is nothing to save
            Row("empty editor, failed erase of a held song", r.emptyDraftNeedsWrite(failed = true, holdsSong = true), true),
            Row("empty editor, no failure", r.emptyDraftNeedsWrite(failed = false, holdsSong = true), false),
            Row("empty editor, detached draft", r.emptyDraftNeedsWrite(failed = true, holdsSong = false), false),
            // Cancellation and finished saves
            Row("cancelled retry of a failed draft", r.restingStatus(failed = true), SaveStatus.FAILED),
            Row("cancelled ordinary save", r.restingStatus(failed = false), SaveStatus.IDLE),
            // CLEAR
            Row("commit of the open words", r.failedAfterCommit(true, "a", "a", wordsMatchEditor = true), false),
            Row("commit while the words changed again", r.failedAfterCommit(true, "a", "a", wordsMatchEditor = false), true),
            Row("commit of another song", r.failedAfterCommit(true, "b", "a", wordsMatchEditor = true), true),
            Row("completed switch, close, new song or Trash", r.failedAfterTransition(true, completed = true), false),
            Row("failed switch, close, new song or Trash", r.failedAfterTransition(true, completed = false), true)
        ).forEach { assertEquals(it.expected, it.actual, it.case) }
    }
}
