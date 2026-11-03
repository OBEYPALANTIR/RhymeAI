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
        assertEquals(
            "Backup paused: this phone has no songs and Drive has 12. Restore to continue.",
            backupStatusLine(BackupStatus.Paused(12), now)
        )
    }

    @Test
    fun failedResultsKeepTheirSettingsWording() {
        assertEquals("Google Drive is not available on this device.", backupFailureReason(SyncResult.NotConfigured))
        assertEquals(DRIVE_SIGN_IN_CANCELLED, backupFailureReason(SyncResult.AuthorizationFailed(DRIVE_SIGN_IN_CANCELLED, retryable = false)))
        assertEquals(
            "Google closed sign-in without granting access. If you didn't cancel it, this build's signing certificate " +
                "or OAuth client is not registered: check the Android OAuth client (package com.rhymeai.app and this " +
                "build's SHA-1) in the Google Cloud console.",
            backupFailureReason(SyncResult.AuthorizationFailed(DRIVE_SIGN_IN_NOT_GRANTED, retryable = false))
        )
        assertEquals(
            "Google rejected this build's signing certificate or OAuth setup. Check the Android OAuth client " +
                "(package com.rhymeai.app and this build's SHA-1) and the consent screen's drive.appdata scope.",
            backupFailureReason(SyncResult.AuthorizationFailed(driveAuthorizationFailure(10).reason, retryable = false))
        )
        assertEquals("Backup failed: offline", backupFailureReason(SyncResult.NetworkError("offline")))
    }

    @Test
    fun aDismissedConsentScreenSaysCancelledOnlyWhenPlayServicesDoes() {
        assertEquals(driveAuthorizationFailure(16), consentDismissedFailure(driveAuthorizationFailure(16)))
        assertEquals(DRIVE_SIGN_IN_CANCELLED, consentDismissedFailure(driveAuthorizationFailure(16)).reason)
        assertEquals(driveAuthorizationFailure(10), consentDismissedFailure(driveAuthorizationFailure(10)))
        assertEquals(
            DriveAuthorization.Failed(DRIVE_SIGN_IN_NOT_GRANTED, retryable = false),
            consentDismissedFailure(DriveAuthorization.Unavailable)
        )
    }

    @Test
    fun firstRunSheetAndResultNoticesUseTheSharedWording() {
        assertEquals(
            "We found 3 songs and 1 recording in your Google Drive backup.",
            restoreOfferBody(BackupProbe(projectCount = 3, recordingCount = 1, legacyBackupPresent = false))
        )
        assertEquals(
            "We found 1 song and 2 recordings in your Google Drive backup. Not now leaves Drive as it is; backup stays paused until you restore.",
            restoreOfferBody(BackupProbe(projectCount = 1, recordingCount = 2, legacyBackupPresent = false), backupPaused = true)
        )
        assertEquals(
            "This phone has no songs. Backing up now merges Drive's 5 songs with nothing from this phone. To get them back here, tap Restore instead.",
            emptyBackupConfirmation(5)
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

    @Test
    fun anEmptyLibraryNeverBacksUpAutomaticallyOverADriveWithSongs() {
        val d = BackupGate::decide
        // The reinstall case: nothing here, songs in Drive.
        assertEquals(BackupGate.Decision.PAUSE, d(0, 7, false, false))
        assertEquals(BackupGate.Decision.CONFIRM, d(0, 7, true, false))
        assertEquals(BackupGate.Decision.RUN, d(0, 7, true, true))
        // Nothing to protect, or something here to add: back up as before.
        assertEquals(BackupGate.Decision.RUN, d(0, 0, false, false))
        assertEquals(BackupGate.Decision.RUN, d(0, 0, true, false))
        assertEquals(BackupGate.Decision.RUN, d(1, 7, false, false))
        assertEquals(BackupGate.Decision.RUN, d(3, 0, true, false))
        // A library not read yet never backs up, whatever else holds.
        assertEquals(BackupGate.Decision.PAUSE, d(null, 0, false, false))
        assertEquals(BackupGate.Decision.PAUSE, d(null, 0, true, true))
    }

    @Test
    fun earlierBackupsReadAsTimeSongsAndRecordings() {
        val revision = BackupRevision("f", "r", "2026-11-01T15:14:00Z", sizeBytes = 14_000L)
        val utc = java.time.ZoneOffset.UTC
        val us = java.util.Locale.US
        assertEquals("Nov 1, 3:14 PM · 14 KB", revisionLabel(revision, utc, us))
        assertEquals("Nov 1, 3:14 PM · 900 bytes", revisionLabel(revision.copy(sizeBytes = 900L), utc, us))
        assertEquals("an unknown time", revisionLabel(revision.copy(modifiedTime = null, sizeBytes = null), utc, us))
        assertEquals(
            "The backup from Nov 1, 3:14 PM holds 12 songs and 1 recording. They will be merged into this phone and your current backup; songs already here stay. " +
                "Nothing in Google Drive is deleted, and Drive will keep this earlier version.",
            recoverRevisionConfirmation(RevisionContents(revision, songCount = 12, recordingCount = 1), utc, us)
        )
    }
}
