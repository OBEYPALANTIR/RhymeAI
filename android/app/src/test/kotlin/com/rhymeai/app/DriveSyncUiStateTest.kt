package com.rhymeai.app

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DriveSyncUiStateTest {
    @Test
    fun successStatusMentionsProjectsTrashRecordingsAndApiKeys() {
        val status = formatDriveSyncSuccessStatus(
            action = DriveSyncAction.Sync,
            projectCount = 2,
            trashedCount = 1,
            recordingCount = 3
        )

        assertTrue(status.contains("2 projects"), status)
        assertTrue(status.contains("1 trashed"), status)
        assertTrue(status.contains("3 recordings"), status)
        assertTrue(status.contains("API keys stay on this device"), status)
    }

    @Test
    fun restoreStatusUsesRestoreCopyAndPreservesApiKeyWarning() {
        val status = formatDriveSyncSuccessStatus(
            action = DriveSyncAction.Restore,
            projectCount = 1,
            trashedCount = 0,
            recordingCount = 1
        )

        assertTrue(status.startsWith("Restore complete"), status)
        assertTrue(status.contains("1 project"), status)
        assertTrue(status.contains("0 trashed"), status)
        assertTrue(status.contains("1 recording"), status)
        assertTrue(status.contains("API keys stay on this device"), status)
    }

    @Test
    fun progressLabelMatchesActiveAction() {
        assertTrue(driveSyncProgressLabel(DriveSyncAction.Sync).contains("Syncing"), driveSyncProgressLabel(DriveSyncAction.Sync))
        assertTrue(driveSyncProgressLabel(DriveSyncAction.Restore).contains("Restoring"), driveSyncProgressLabel(DriveSyncAction.Restore))
    }

    @Test
    fun authorizationRetryPreservesRestoreAction() {
        assertTrue(
            nextDriveSyncActionAfterAuthorization(DriveSyncAction.Restore) == DriveSyncAction.Restore,
            "Approving Restore consent must retry restore, not sync"
        )
    }

    @Test
    fun backgroundSyncRunsOnlyAfterSetupAndWhenIdle() {
        assertFalse(shouldAttemptBackgroundDriveSync(hasPassphrase = false, authorizedForNonInteractiveSync = true, syncInProgress = false))
        assertFalse(shouldAttemptBackgroundDriveSync(hasPassphrase = true, authorizedForNonInteractiveSync = false, syncInProgress = false))
        assertFalse(shouldAttemptBackgroundDriveSync(hasPassphrase = true, authorizedForNonInteractiveSync = true, syncInProgress = true))
        assertTrue(shouldAttemptBackgroundDriveSync(hasPassphrase = true, authorizedForNonInteractiveSync = true, syncInProgress = false))
    }

    @Test
    fun backgroundSyncDefersInsideMinimumInterval() {
        assertTrue(shouldDeferBackgroundDriveSync(nowMillis = 10_000L, lastAttemptMillis = 1_000L, minIntervalMillis = 15_000L))
        assertFalse(shouldDeferBackgroundDriveSync(nowMillis = 16_000L, lastAttemptMillis = 1_000L, minIntervalMillis = 15_000L))
    }
}
