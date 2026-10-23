package com.rhymeai.app

import android.Manifest
import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.recording.RecordingCatalog
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.sync.RecordingRecord
import com.rhymeai.app.service.VoiceMemoService
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** A27/A31: takes waiting in staging, recovered by their start-marker id with real MPEG-4 audio. */
@RunWith(AndroidJUnit4::class)
class WaitingTakeInstrumentedTest {
    @org.junit.Before fun grantMicrophone() {
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.RECORD_AUDIO)
    }

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val owned = File(context.filesDir, "recording-test-${UUID.randomUUID()}").apply { mkdirs() }
    private val isolated = object : ContextWrapper(context) { override fun getFilesDir(): File = owned }
    private val catalog = Catalog()
    private val service = VoiceMemoService(isolated).also { it.catalog = catalog }
    private val staging = RecordingFiles.stagingDirectory(owned, "song").apply { mkdirs() }

    /** In-memory records; [failWrites] or [failOnWrite] (1-based, changing writes) inject a write failure. */
    private class Catalog : RecordingCatalog {
        var records = listOf<RecordingRecord>()
        var failWrites = false
        var failOnWrite: Int? = null
        private var writes = 0
        override suspend fun recordingRecords() = records
        override suspend fun updateRecordingRecords(transform: (List<RecordingRecord>) -> List<RecordingRecord>) {
            val next = transform(records)
            if (next == records) return
            if (failWrites || ++writes == failOnWrite) throw java.io.IOException("injected metadata write failure")
            records = next
        }
    }

    @After fun cleanUp() {
        service.release()
        owned.deleteRecursively()
    }

    private fun restarted() = VoiceMemoService(isolated).also { it.catalog = catalog }

    private fun take(name: String, id: String): File =
        TestRecordings.recordFinalizedM4a(context, File(staging, name)).also { TestRecordings.startMarker(it, id) }

    @Test fun onlyAFinalizedTakePassesAndTruncatedCopiesDoNot() {
        val full = TestRecordings.recordFinalizedM4a(context, File(owned, "full.m4a"))
        assertEquals(VoiceMemoService.Inspection.FINALIZED, service.inspectFinalized(full))
        assertEquals(VoiceMemoService.Inspection.INVALID, service.inspectFinalized(TestRecordings.cutInsideMediaData(full, File(owned, "cut.m4a"))))
        assertEquals(
            VoiceMemoService.Inspection.INVALID,
            service.inspectFinalized(TestRecordings.mediaDataShortenedKeepingIndex(full, File(owned, "short.m4a")))
        )
        // Same length, intact index, every audio byte zeroed: rejected by content.
        assertEquals(VoiceMemoService.Inspection.INVALID, service.inspectFinalized(TestRecordings.zeroedMediaData(full, File(owned, "zeroed.m4a"))))
    }

    @Test fun aFinishedTakeWhoseSaveFailedWaitsAcrossARestartAndALaterTakeUntilRetrySavesIt() = runBlocking {
        val first = take("1700000000000.m4a", "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b")
        catalog.failWrites = true
        assertTrue(runCatching { service.finishTake(first, null) }.exceptionOrNull() is VoiceMemoService.RecordingNotSavedException)
        assertTrue(first.exists())

        val after = restarted()
        val waiting = after.waitingTakes("song").single()
        assertTrue(waiting.finished)
        catalog.failWrites = false
        after.finishTake(take("1700000005000.m4a", "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2"), null)
        assertEquals(listOf(waiting.id), after.waitingTakes("song").map { it.id })

        assertEquals(1, after.retryWaitingTakes("song"))
        assertTrue(after.waitingTakes("song").isEmpty())
        assertEquals(2, after.memosForProject("song").size)
        // A31: the save uses the finish time the marker recorded, not the retry time.
        assertEquals(waiting.recordedAt, catalog.records.single { it.id == "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b" }.uploadedAt)
        after.release()
    }

    @Test fun aRetryAfterTheTakeMovedButItsFinalRecordFailedCountsAsSaved() = runBlocking {
        val file = take("1700000000000.m4a", "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b")
        // Write 1 is the intent; write 2, the final record, fails after the file moved.
        catalog.failOnWrite = 2
        assertTrue(runCatching { service.finishTake(file, null) }.exceptionOrNull() is VoiceMemoService.RecordingNotSavedException)
        assertFalse(file.exists())
        // The committed intent is kept.
        assertEquals("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", catalog.records.single().id)

        assertEquals(1, service.retryWaitingTakes("song"))
        assertTrue(service.waitingTakes("song").isEmpty())
        assertEquals(listOf("1700000000000.m4a"), service.memosForProject("song").map { it.file.name })
        assertNull(catalog.records.single().pendingOp)
    }

    @Test fun anUnreadableStartMarkerIsNeverReplacedAndTheTakeIsSavedUnderItOnceReadable() = runBlocking {
        val file = take("1700000000000.m4a", "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b")
        val marker = File(staging, "1700000000000.m4a.take")
        marker.setReadable(false)
        org.junit.Assume.assumeFalse("permissions are not enforced here", marker.canRead())
        try {
            assertTrue(runCatching { service.finishTake(file, null) }.exceptionOrNull() is VoiceMemoService.RecordingNotSavedException)
            assertTrue(catalog.records.isEmpty())
            assertNull(service.waitingTakes("song").single().id)
        } finally {
            marker.setReadable(true)
        }
        assertEquals(1, service.retryWaitingTakes("song"))
        assertEquals("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", catalog.records.single().id)
    }

    @Test fun aTakeWhoseFinishWasNeverRecordedIsSavedOnlyIfFinalizedAndAnUnreadableOneStaysRetryable() = runBlocking {
        // As after a crash: start markers only; one take finalized, one cut short.
        val complete = take("1700000000000.m4a", "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b")
        val cut = TestRecordings.cutInsideMediaData(complete, File(staging, "1700000009000.m4a"))
        TestRecordings.startMarker(cut, "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2")
        val after = restarted()
        assertTrue(after.memosForProject("song").isEmpty())
        assertEquals(listOf(false, false), after.waitingTakes("song").map { it.finished })

        // The finalized take cannot be read for now: it stays waiting, not failed.
        complete.setReadable(false)
        val blocked = !complete.canRead()
        try {
            if (blocked) {
                assertTrue(runCatching { after.retryWaitingTakes("song") }.exceptionOrNull() is VoiceMemoService.RecordingNotSavedException)
                assertTrue(after.waitingTakes("song").any { it.id == "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b" })
                assertTrue(catalog.records.isEmpty())
            }
        } finally {
            complete.setReadable(true)
        }

        // Readable again: it is saved under its own id; the cut take never is (it is marked failed).
        runCatching { after.retryWaitingTakes("song") }
        assertEquals(listOf("1700000000000.m4a"), after.memosForProject("song").map { it.file.name })
        assertEquals("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", catalog.records.single().id)
        assertTrue(cut.exists())
        assertTrue(after.waitingTakes("song").isEmpty())
        after.release()
    }

    @Test fun aTakeInterruptedBetweenItsJournalAndItsMoveIsSavedByRetry() = runBlocking<Unit> {
        // Any size goes through the same journal: the finish (marker) and the publish intent
        // (record) are written, then the process died before the move.
        val take = File(staging, "1700000000000.m4a").apply { writeBytes(ByteArray(64) { it.toByte() }) }
        File(staging, "1700000000000.m4a.take").writeText("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b\nfinished\n1700000000500\n")
        val target = File(RecordingFiles.memoDirectory(owned, "song").apply { mkdirs() }, take.name)
        catalog.records = listOf(RecordingRecord("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", "song", take.name, 1_700_000_000_500L,
            com.rhymeai.app.data.sync.RecordingFileStore.sha256Hex(take), take.length(), RecordingRecord.RECORDED,
            path = com.rhymeai.app.data.recording.RecordingTransitions.relativePath(owned, target),
            pendingFrom = com.rhymeai.app.data.recording.RecordingTransitions.relativePath(owned, take),
            pendingOp = RecordingRecord.OP_PUBLISH))

        val after = restarted()
        assertEquals(1, after.retryWaitingTakes("song"))

        // Saved only once its file is really in place, with its id and finish time.
        assertTrue(target.exists())
        assertFalse(take.exists())
        assertEquals("0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", catalog.records.single().id)
        assertEquals(1_700_000_000_500L, catalog.records.single().uploadedAt)
        assertNull(catalog.records.single().pendingOp)
        after.release()
    }
}
