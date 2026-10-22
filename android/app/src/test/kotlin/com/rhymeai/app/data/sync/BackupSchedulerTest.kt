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
}
