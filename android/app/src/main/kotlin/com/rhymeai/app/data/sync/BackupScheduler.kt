package com.rhymeai.app.data.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** How a backup run ended, for the scheduler's retry decision. */
enum class BackupRunOutcome { SUCCEEDED, RETRY, STOP }

/**
 * Automatic Drive backup timing: every change restarts one 30 s debounce, runs
 * never overlap (a change during a run queues one more), failures back off
 * 1, 2, 4 … 60 min, and leaving the app runs a pending backup at once or at most
 * every 15 minutes otherwise.
 */
class BackupScheduler(
    private val scope: CoroutineScope,
    private val clock: () -> Long,
    private val isConnected: () -> Boolean,
    private val onPending: () -> Unit,
    private val run: suspend (interactive: Boolean) -> BackupRunOutcome
) {
    companion object {
        const val BACKGROUND_MIN_INTERVAL_MILLIS = 15 * 60 * 1000L
    }

    private var job: Job? = null
    private var dirty = false
    var running = false
        private set
    var pending = false
        private set
    var failures = 0
        private set
    var retryNotBeforeMillis = 0L
        private set
    private var lastBackgroundMillis = 0L

    /** A change was saved: back up after the debounce and any backoff still in force. */
    fun schedule() {
        if (!isConnected()) return
        if (running) {
            dirty = true
            return
        }
        pending = true
        onPending()
        launchAfter(BackupSchedule.autoBackupDelayMillis(clock(), retryNotBeforeMillis))
    }

    /** "Back up now" (interactive) or a due automatic run. */
    fun runNow(interactive: Boolean) {
        if (!isConnected()) return
        job?.cancel()
        job = null
        if (running) {
            dirty = true
            return
        }
        running = true
        pending = false
        scope.launch {
            val outcome = try {
                run(interactive)
            } finally {
                running = false
            }
            when (outcome) {
                BackupRunOutcome.SUCCEEDED -> {
                    failures = 0
                    retryNotBeforeMillis = 0L
                }
                BackupRunOutcome.RETRY -> {
                    failures++
                    val wait = BackupSchedule.retryDelayMillis(failures)
                    retryNotBeforeMillis = clock() + wait
                    if (!dirty) launchAfter(wait)
                }
                BackupRunOutcome.STOP -> Unit
            }
            if (dirty) {
                dirty = false
                schedule()
            }
        }
    }

    fun onBackground() {
        if (!isConnected()) return
        val now = clock()
        if (now < retryNotBeforeMillis) return
        if (!pending && now - lastBackgroundMillis < BACKGROUND_MIN_INTERVAL_MILLIS) return
        lastBackgroundMillis = now
        runNow(interactive = false)
    }

    /** Disconnect: drop anything queued and forget the backoff. */
    fun reset() {
        job?.cancel()
        job = null
        dirty = false
        pending = false
        failures = 0
        retryNotBeforeMillis = 0L
    }

    private fun launchAfter(delayMillis: Long) {
        job?.cancel()
        job = scope.launch {
            delay(delayMillis)
            job = null
            runNow(interactive = false)
        }
    }
}

/** The action to retry once Google consent is granted; a missing one means "back up". */
internal fun <T> actionAfterAuthorization(pending: T?, fallback: T): T = pending ?: fallback

/** A consent answered after its screen closed resumes [pending] only while still connected, or when it is [connect] itself. */
internal fun <T> resumesAfterConsent(connected: Boolean, pending: T?, connect: T): Boolean = connected || pending == connect
