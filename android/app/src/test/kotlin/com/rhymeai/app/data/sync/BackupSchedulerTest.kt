package com.rhymeai.app.data.sync

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Debounce, coalescing, backoff and the leave-app trigger, on virtual time. */
@OptIn(ExperimentalCoroutinesApi::class)
class BackupSchedulerTest {
    private val minute = 60_000L

    private class Harness(scope: TestScope, var connected: Boolean = true) {
        val runs = mutableListOf<Long>()
        var outcome = BackupRunOutcome.SUCCEEDED
        var gate: CompletableDeferred<Unit>? = null
        var pendingSignals = 0
        val scheduler = BackupScheduler(
            scope = scope.backgroundScope,
            clock = { scope.testScheduler.currentTime },
            isConnected = { connected },
            onPending = { pendingSignals++ }
        ) {
            runs += scope.testScheduler.currentTime
            gate?.await()
            outcome
        }
    }

    @Test
    fun changesInsideTheDebounceCollapseIntoOneRunThirtySecondsAfterTheLast() = runTest {
        val h = Harness(this)
        h.scheduler.schedule()
        advanceTimeBy(20_000)
        h.scheduler.schedule()
        advanceTimeBy(20_000)
        h.scheduler.schedule()
        advanceTimeBy(29_999)
        runCurrent()
        assertEquals(emptyList(), h.runs)
        advanceTimeBy(2)
        runCurrent()
        assertEquals(listOf(70_000L), h.runs)
        assertEquals(3, h.pendingSignals)
    }

    @Test
    fun aChangeDuringARunQueuesExactlyOneMoreRun() = runTest {
        val h = Harness(this)
        h.gate = CompletableDeferred()
        h.scheduler.runNow(interactive = true)
        runCurrent()
        assertTrue(h.scheduler.running)
        h.scheduler.schedule()
        h.scheduler.schedule()
        h.scheduler.runNow(interactive = false)
        h.gate!!.complete(Unit)
        runCurrent()
        assertEquals(1, h.runs.size)
        advanceTimeBy(30_001)
        runCurrent()
        assertEquals(2, h.runs.size)
        advanceTimeBy(10 * minute)
        assertEquals(2, h.runs.size)
    }

    @Test
    fun failuresBackOffAndASuccessResetsTheSchedule() = runTest {
        val h = Harness(this)
        h.outcome = BackupRunOutcome.RETRY
        h.scheduler.runNow(interactive = false)
        runCurrent()
        repeat(3) {
            advanceTimeBy(BackupSchedule.retryDelayMillis(h.scheduler.failures) + 1)
            runCurrent()
        }
        // Retries at +1, +2 and +4 minutes after each failure.
        assertEquals(listOf(0L, 1 * minute, 3 * minute, 7 * minute), h.runs)
        assertEquals(4, h.scheduler.failures)

        // A change during backoff waits for the backoff, not just the debounce.
        h.scheduler.schedule()
        advanceTimeBy(5 * minute)
        runCurrent()
        assertEquals(4, h.runs.size)

        h.outcome = BackupRunOutcome.SUCCEEDED
        advanceTimeBy(3 * minute + 1)
        runCurrent()
        assertEquals(5, h.runs.size)
        assertEquals(0, h.scheduler.failures)
        assertEquals(0L, h.scheduler.retryNotBeforeMillis)
    }

    @Test
    fun aStopOutcomeDoesNotRetry() = runTest {
        val h = Harness(this)
        h.outcome = BackupRunOutcome.STOP
        h.scheduler.runNow(interactive = false)
        advanceTimeBy(2 * 60 * minute)
        assertEquals(1, h.runs.size)
    }

    @Test
    fun leavingTheAppRunsAPendingBackupAtOnceOtherwiseAtMostEveryFifteenMinutes() = runTest {
        val h = Harness(this)
        advanceTimeBy(BackupScheduler.BACKGROUND_MIN_INTERVAL_MILLIS)
        h.scheduler.onBackground()
        runCurrent()
        assertEquals(1, h.runs.size)
        advanceTimeBy(minute)
        h.scheduler.onBackground()
        runCurrent()
        assertEquals(1, h.runs.size)
        h.scheduler.schedule()
        h.scheduler.onBackground()
        runCurrent()
        assertEquals(2, h.runs.size)
        advanceTimeBy(BackupScheduler.BACKGROUND_MIN_INTERVAL_MILLIS)
        h.scheduler.onBackground()
        runCurrent()
        assertEquals(3, h.runs.size)
    }

    @Test
    fun disconnectedSchedulesNothingAndResetDropsAQueuedRun() = runTest {
        val h = Harness(this, connected = false)
        h.scheduler.schedule()
        h.scheduler.onBackground()
        h.scheduler.runNow(interactive = true)
        advanceTimeBy(60 * minute)
        assertEquals(emptyList(), h.runs)

        h.connected = true
        h.scheduler.schedule()
        h.scheduler.reset()
        assertFalse(h.scheduler.pending)
        advanceTimeBy(60 * minute)
        assertEquals(emptyList(), h.runs)
    }

    @Test
    fun consentRetriesThePendingActionOrBacksUp() {
        assertEquals("restore", actionAfterAuthorization("restore", "backup"))
        assertEquals("backup", actionAfterAuthorization(null, "backup"))
    }

    @Test
    fun aLateConsentResumesOnlyWhileConnectedOrWhenConnecting() {
        assertTrue(resumesAfterConsent(connected = true, pending = "restore", connect = "connect"))
        assertTrue(resumesAfterConsent(connected = false, pending = "connect", connect = "connect"))
        assertFalse(resumesAfterConsent(connected = false, pending = "restore", connect = "connect"))
        assertFalse(resumesAfterConsent(connected = false, pending = null, connect = "connect"))
    }

    /** The real scheduler driving the real gated run, with Drive and the library faked. */
    private class GatedHarness(scope: TestScope) {
        var localSongs: Int? = 0
        var driveSongs = 7
        var probeFailure: SyncResult? = null
        var backupResult: SyncResult = SyncResult.Success(SyncBlob())
        var probes = 0
        val backups = mutableListOf<Long>()
        val gated = mutableListOf<Pair<BackupGate.Decision, Int>>()
        val run = GatedBackupRun(
            localSongCount = { localSongs },
            probe = {
                probes++
                probeFailure?.let { ProbeResult.Failed(it) } ?: ProbeResult.Ready(BackupProbe(driveSongs, 0, legacyBackupPresent = false))
            },
            backUp = { backups += scope.testScheduler.currentTime; backupResult },
            onGated = { decision, remote -> gated += decision to remote },
            onResult = { result, _ ->
                when (result) {
                    is SyncResult.Success -> BackupRunOutcome.SUCCEEDED
                    is SyncResult.NetworkError -> BackupRunOutcome.RETRY
                    else -> BackupRunOutcome.STOP
                }
            }
        )
        val scheduler = BackupScheduler(
            scope = scope.backgroundScope,
            clock = { scope.testScheduler.currentTime },
            isConnected = { true },
            onPending = {}
        ) { interactive -> run(interactive) }
    }

    @Test
    fun aScheduledRunOnAnEmptyPhoneOverADriveWithSongsUploadsNothing() = runTest {
        val h = GatedHarness(this)
        h.scheduler.schedule()
        advanceTimeBy(31_000)
        runCurrent()
        assertEquals(1, h.probes)
        assertEquals(emptyList(), h.backups)
        assertEquals(listOf(BackupGate.Decision.PAUSE to 7), h.gated)
    }

    @Test
    fun aRetryAfterAFailedProbeIsGatedAgain() = runTest {
        val h = GatedHarness(this)
        h.probeFailure = SyncResult.NetworkError("offline")
        h.scheduler.schedule()
        advanceTimeBy(31_000)
        runCurrent()
        assertEquals(1, h.scheduler.failures)
        h.probeFailure = null
        advanceTimeBy(61_000)
        runCurrent()
        assertEquals(2, h.probes)
        assertEquals(emptyList(), h.backups)
        assertEquals(listOf(BackupGate.Decision.PAUSE to 7), h.gated)
    }

    @Test
    fun leavingTheAppOnAnEmptyPhoneUploadsNothing() = runTest {
        val h = GatedHarness(this)
        advanceTimeBy(BackupScheduler.BACKGROUND_MIN_INTERVAL_MILLIS + 1)
        h.scheduler.onBackground()
        runCurrent()
        assertEquals(emptyList(), h.backups)
        assertEquals(listOf(BackupGate.Decision.PAUSE to 7), h.gated)
    }

    @Test
    fun backUpNowAsksFirstAndRunsOnceOnlyAfterTheExplicitConfirmation() = runTest {
        val h = GatedHarness(this)
        h.scheduler.runNow(interactive = true)
        runCurrent()
        assertEquals(listOf(BackupGate.Decision.CONFIRM to 7), h.gated)
        assertEquals(emptyList(), h.backups)

        h.run.confirmOnce()
        h.scheduler.runNow(interactive = true)
        runCurrent()
        assertEquals(1, h.backups.size)
        // The confirmation covered that run only: the next automatic one is paused again.
        h.scheduler.schedule()
        advanceTimeBy(31_000)
        runCurrent()
        assertEquals(1, h.backups.size)
        assertEquals(BackupGate.Decision.PAUSE to 7, h.gated.last())
    }

    @Test
    fun songsHereOrInTrashResumeBackupWithoutAskingDrive() = runTest {
        val h = GatedHarness(this)
        advanceTimeBy(BackupScheduler.BACKGROUND_MIN_INTERVAL_MILLIS + 1)
        h.scheduler.onBackground()
        runCurrent()
        assertEquals(emptyList(), h.backups)
        // After Restore (or a song kept only in Trash) the library is not empty: backups resume.
        h.localSongs = 1
        h.scheduler.schedule()
        advanceTimeBy(31_000)
        runCurrent()
        assertEquals(1, h.backups.size)
        assertEquals(1, h.probes)
    }

    @Test
    fun aLibraryNotReadYetNeverUploadsOrAsksDrive() = runTest {
        val h = GatedHarness(this)
        h.localSongs = null
        advanceTimeBy(BackupScheduler.BACKGROUND_MIN_INTERVAL_MILLIS + 1)
        h.scheduler.onBackground()
        runCurrent()
        h.scheduler.runNow(interactive = true)
        runCurrent()
        assertEquals(0, h.probes)
        assertEquals(emptyList(), h.backups)
        assertEquals(emptyList(), h.gated)
    }
}
