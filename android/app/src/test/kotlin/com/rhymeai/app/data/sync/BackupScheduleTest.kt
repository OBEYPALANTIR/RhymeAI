package com.rhymeai.app.data.sync

import com.rhymeai.app.BackupAction
import com.rhymeai.app.backupResultNotice
import com.rhymeai.app.ui.components.restoreOfferBody
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class BackupScheduleTest {
    private val minute = 60_000L

    @Test
    fun backoffDoublesFromOneMinuteAndCapsAtOneHour() {
        assertEquals(0L, BackupSchedule.retryDelayMillis(0))
        assertEquals(
            listOf(1L, 2L, 4L, 8L, 16L, 32L, 60L, 60L),
            (1..8).map { BackupSchedule.retryDelayMillis(it) / minute }
        )
        assertEquals(60L * minute, BackupSchedule.retryDelayMillis(Int.MAX_VALUE))
    }

    @Test
    fun automaticBackupWaitsForTheDebounceAndAnyRemainingBackoff() {
        assertEquals(30_000L, BackupSchedule.autoBackupDelayMillis(nowMillis = 1_000L, retryNotBeforeMillis = 0L))
        assertEquals(4 * minute, BackupSchedule.autoBackupDelayMillis(nowMillis = 0L, retryNotBeforeMillis = 4 * minute))
    }

    @Test
    fun statusLinesMatchTheSharedCopy() {
        val now = 10 * 24 * 60 * minute
        assertEquals("Not connected", backupStatusLine(BackupStatus.NotConnected, now))
        assertEquals("Connected · Google Drive", backupStatusLine(BackupStatus.Connected(null), now))
        assertEquals("Last backed up just now · Google Drive", backupStatusLine(BackupStatus.Connected(now - 20_000L), now))
        assertEquals("Last backed up 2 min ago · Google Drive", backupStatusLine(BackupStatus.Connected(now - 2 * minute), now))
        assertEquals("Last backed up 3 h ago · Google Drive", backupStatusLine(BackupStatus.Connected(now - 190 * minute), now))
        assertEquals("Last backed up yesterday · Google Drive", backupStatusLine(BackupStatus.Connected(now - 30 * 60 * minute), now))
        assertEquals("Last backed up 4 days ago · Google Drive", backupStatusLine(BackupStatus.Connected(now - 4 * 24 * 60 * minute), now))
        assertEquals("Backup failed: offline", backupStatusLine(BackupStatus.Failed("Backup failed: offline", null), now))
    }

    @Test
    fun firstRunSheetAndResultNoticesUseTheSharedWording() {
        assertEquals(
            "We found 3 songs and 1 recording in your Google Drive backup.",
            restoreOfferBody(BackupProbe(projectCount = 3, recordingCount = 1, legacyBackupPresent = false))
        )
        assertNull(backupResultNotice(SyncResult.Success(SyncBlob()), BackupAction.BackUp))
        assertEquals(
            "Your older encrypted backup was moved to the new format. Its files stay in your Google Drive. 2 recordings are over 16 MB and were skipped.",
            backupResultNotice(SyncResult.Success(SyncBlob(), skippedLargeRecordings = 2, migratedLegacyBackup = true), BackupAction.BackUp)
        )
        assertEquals(
            "3 older recordings could not be moved; the older backup was kept.",
            backupResultNotice(SyncResult.Success(SyncBlob(), unmovedLegacyRecordings = 3), BackupAction.BackUp)
        )
        assertEquals(
            "Restored 0 songs and 0 recordings. 1 recording did not match its backup checksum and was not saved.",
            backupResultNotice(SyncResult.Success(SyncBlob(), damagedRecordings = 1), BackupAction.Restore)
        )
    }
}
