package com.rhymeai.app.data.sync

/** Backup state shown in Settings; the same cases exist on iOS. */
sealed class BackupStatus {
    data object NotConnected : BackupStatus()
    data class Connected(val lastBackupAt: Long?) : BackupStatus()
    data object Pending : BackupStatus()
    data object BackingUp : BackupStatus()
    data class Failed(val reason: String, val lastBackupAt: Long?) : BackupStatus()
}

object BackupSchedule {
    const val DEBOUNCE_MILLIS = 30_000L
    private const val FIRST_RETRY_MILLIS = 60_000L
    private const val MAX_RETRY_MILLIS = 60 * 60_000L

    /** 1, 2, 4, 8 … minutes after consecutive failures, capped at one hour. */
    fun retryDelayMillis(consecutiveFailures: Int): Long {
        if (consecutiveFailures <= 0) return 0L
        val doublings = (consecutiveFailures - 1).coerceAtMost(30)
        return (FIRST_RETRY_MILLIS shl doublings).coerceAtMost(MAX_RETRY_MILLIS)
    }

    /** An automatic run waits for the debounce and for any backoff still in force. */
    fun autoBackupDelayMillis(nowMillis: Long, retryNotBeforeMillis: Long): Long =
        maxOf(DEBOUNCE_MILLIS, retryNotBeforeMillis - nowMillis)
}

/** The Settings status line for a result that stops a backup. */
internal fun backupFailureReason(result: SyncResult): String = when (result) {
    SyncResult.NotConfigured -> "Google Drive is not available on this device."
    is SyncResult.AuthorizationFailed -> result.reason
    SyncResult.CorruptRemote -> BackupManifest.DAMAGED_MESSAGE
    SyncResult.UnsupportedVersion -> "This backup was made by a newer version of Writers Block. Update the app to use it."
    is SyncResult.NetworkError -> "Backup failed: ${result.message}"
    is SyncResult.UnknownError -> "Backup failed: ${result.cause.message ?: "unexpected error"}"
    is SyncResult.Success, is SyncResult.AuthorizationRequired, SyncResult.NoBackup, SyncResult.WrongPassphrase ->
        error("$result is not a failure")
}

/** "Last backed up 2 min ago · Google Drive" and the other status lines. */
fun backupStatusLine(status: BackupStatus, nowMillis: Long): String = when (status) {
    BackupStatus.NotConnected -> "Not connected"
    BackupStatus.Pending -> "Waiting to back up · Google Drive"
    BackupStatus.BackingUp -> "Backing up… · Google Drive"
    is BackupStatus.Connected -> status.lastBackupAt
        ?.let { "Last backed up ${relativeTime(nowMillis, it)} · Google Drive" }
        ?: "Connected · Google Drive"
    is BackupStatus.Failed -> status.reason
}

internal fun relativeTime(nowMillis: Long, thenMillis: Long): String {
    val minutes = (nowMillis - thenMillis).coerceAtLeast(0L) / 60_000L
    return when {
        minutes < 1 -> "just now"
        minutes < 60 -> "$minutes min ago"
        minutes < 24 * 60 -> "${minutes / 60} h ago"
        minutes < 2 * 24 * 60 -> "yesterday"
        else -> "${minutes / (24 * 60)} days ago"
    }
}
