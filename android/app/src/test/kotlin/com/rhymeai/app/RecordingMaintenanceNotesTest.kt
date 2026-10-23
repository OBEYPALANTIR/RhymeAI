package com.rhymeai.app

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** T5.3, T5.12, T5.13, T5.22: what the launch check kept is reported, and nothing is reported when nothing was kept. */
class RecordingMaintenanceNotesTest {
    @Test
    fun eachKeptKindIsReportedOnceAndNothingIsReportedWhenNothingWasKept() {
        assertTrue(recordingMaintenanceNotes(0, 0, 0, 0, 0).isEmpty())
        val notes = recordingMaintenanceNotes(leftInPlace = 1, unresolved = 2, unreadableTrash = 3, heldRestores = 1, setAside = 4)
        assertEquals(
            listOf(
                "1 older recording file(s) could not be renamed because a file with their new name already exists. They were left in place.",
                "2 recording move(s) could not be finished. The recordings were kept.",
                "3 file(s) in the recordings Trash have names this version cannot read. They were kept and are listed in the Trash Bin.",
                "An interrupted restore from an older version could not be finished. Its files were kept.",
                "4 deleted recording(s) were set aside on this device."
            ),
            notes
        )
    }
}
