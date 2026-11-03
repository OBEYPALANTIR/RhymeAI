package com.rhymeai.app.data.sync

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Backup state shown in Settings; the same cases exist on iOS. */
sealed class BackupStatus {
    data object NotConnected : BackupStatus()
    data class Connected(val lastBackupAt: Long?) : BackupStatus()
    data object Pending : BackupStatus()
    data object BackingUp : BackupStatus()
    data class Failed(val reason: String, val lastBackupAt: Long?) : BackupStatus()
    /** This device has no songs and Drive has [remoteSongCount]: nothing uploads until Restore or a confirmed Back up now. */
    data class Paused(val remoteSongCount: Int) : BackupStatus()
}

/**
 * Restore first: a device with no songs (active or in Trash) never backs up automatically
 * over a Drive that lists songs (a reinstall, before Restore). Back up now asks first.
 * A library that could not be read yet ([localSongCount] null) never backs up.
 */
object BackupGate {
    enum class Decision { RUN, PAUSE, CONFIRM }

    fun decide(localSongCount: Int?, remoteSongCount: Int, interactive: Boolean, userConfirmed: Boolean): Decision = when {
        localSongCount == null -> Decision.PAUSE
        localSongCount > 0 || remoteSongCount == 0 || userConfirmed -> Decision.RUN
        interactive -> Decision.CONFIRM
        else -> Decision.PAUSE
    }
}

/** "Nov 1, 3:14 PM · 14 KB" for one earlier Drive backup (its contents are read only once it is chosen). */
fun revisionLabel(revision: BackupRevision, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String {
    val time = revisionTime(revision, zone, locale)
    val size = revision.sizeBytes ?: return time
    return "$time · ${if (size < 1024) "$size bytes" else "${(size + 1023) / 1024} KB"}"
}

/** What recovering the chosen version does, with what it holds, said before it runs. */
fun recoverRevisionConfirmation(contents: RevisionContents, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String =
    "The backup from ${revisionTime(contents.revision, zone, locale)} holds ${count(contents.songCount, "song")} and " +
        "${count(contents.recordingCount, "recording")}. Songs from that earlier backup that aren't on this phone are added as new songs. " +
        "Nothing on Drive is changed or deleted."

private fun revisionTime(revision: BackupRevision, zone: ZoneId, locale: Locale): String =
    revision.modifiedTime?.let { runCatching { DateTimeFormatter.ofPattern("MMM d, h:mm a", locale).format(Instant.parse(it).atZone(zone)) }.getOrNull() }
        ?: "an unknown time"

private fun count(n: Int, noun: String) = if (n == 1) "1 $noun" else "$n ${noun}s"

/** The Back up now confirmation for an empty device over a Drive with songs. */
fun emptyBackupConfirmation(remoteSongCount: Int): String {
    val songs = if (remoteSongCount == 1) "1 song" else "$remoteSongCount songs"
    return "This phone has no songs. Backing up now merges Drive's $songs with nothing from this phone. To get them back here, tap Restore instead."
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
    is BackupStatus.Paused -> "Backup paused: this phone has no songs and Drive has ${status.remoteSongCount}. Restore to continue."
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
