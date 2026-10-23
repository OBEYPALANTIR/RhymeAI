package com.rhymeai.app

import android.Manifest
import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.recording.RecordingCatalog
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.recording.RecordingTransitions
import com.rhymeai.app.data.sync.RecordingRecord
import com.rhymeai.app.data.sync.SyncDeletion
import com.rhymeai.app.service.VoiceMemo
import com.rhymeai.app.service.VoiceMemoService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** A28: a playback still being checked is cancelled by Stop, release and a deletion; delayed reads are controlled. */
@RunWith(AndroidJUnit4::class)
class PlaybackGuardInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val owned = File(context.filesDir, "playback-test-${UUID.randomUUID()}").apply { mkdirs() }
    private val isolated = object : ContextWrapper(context) { override fun getFilesDir(): File = owned }
    private val catalog = GatedCatalog()
    private var deletions = emptyList<SyncDeletion>()
    private val service = VoiceMemoService(isolated).also {
        it.catalog = catalog
        it.deletionsProvider = { deletions }
    }
    private lateinit var memo: VoiceMemo
    private val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"

    /** Records whose reads wait on [gate] while [gated]. */
    private class GatedCatalog : RecordingCatalog {
        var records = listOf<RecordingRecord>()
        @Volatile var gated = false
        var gate = CompletableDeferred<Unit>()
        override suspend fun recordingRecords(): List<RecordingRecord> {
            if (gated) gate.await()
            return records
        }
        override suspend fun updateRecordingRecords(transform: (List<RecordingRecord>) -> List<RecordingRecord>) {
            records = transform(records)
        }
    }

    @Before fun recordATake() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.RECORD_AUDIO)
        val file = TestRecordings.recordFinalizedM4a(context, File(RecordingFiles.memoDirectory(owned, "song"), "take.m4a"))
        catalog.records = listOf(
            RecordingRecord(id, "song", "take.m4a", 1_000L, "a".repeat(64), file.length(), RecordingRecord.RECORDED,
                path = RecordingTransitions.relativePath(owned, file))
        )
        memo = VoiceMemo(file, "take", 1_500L)
    }

    @After fun cleanUp() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync { service.release() }
        owned.deleteRecursively()
    }

    private fun settle() {
        Thread.sleep(1_000)
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    @Test fun anUngatedPlayStarts() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync { service.play(memo) }
        settle()
        assertEquals(memo.file, service.playingFile)
    }

    @Test fun stopWhileThePlaybackIsStillBeingCheckedWins() {
        catalog.gated = true
        InstrumentationRegistry.getInstrumentation().runOnMainSync { service.play(memo) }
        InstrumentationRegistry.getInstrumentation().runOnMainSync { service.stopPlayback() }
        catalog.gate.complete(Unit)
        settle()
        assertNull(service.playingFile)
    }

    @Test fun releaseWhileThePlaybackIsStillBeingCheckedWins() {
        catalog.gated = true
        InstrumentationRegistry.getInstrumentation().runOnMainSync { service.play(memo) }
        InstrumentationRegistry.getInstrumentation().runOnMainSync { service.release() }
        catalog.gate.complete(Unit)
        settle()
        assertNull(service.playingFile)
    }

    @Test fun aDeletionWhileThePlaybackIsStillBeingCheckedWins() {
        catalog.gated = true
        InstrumentationRegistry.getInstrumentation().runOnMainSync { service.play(memo) }
        // The tombstone commits after the play's check began.
        deletions = listOf(SyncDeletion("song", "take.m4a", 9_000L, recordingId = id))
        catalog.gated = false
        runBlocking { service.onDeletionsChanged() }
        catalog.gate.complete(Unit)
        settle()
        assertNull(service.playingFile)
        // And a new play refuses it.
        InstrumentationRegistry.getInstrumentation().runOnMainSync { service.play(memo) }
        settle()
        assertNull(service.playingFile)
    }

    @Test fun playbackStopsBeforeItsBytesMoveEvenAfterItsPathChanged() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync { service.play(memo) }
        settle()
        assertEquals(memo.file, service.playingFile)
        runBlocking { service.stopPlayingIds(setOf(id)) }
        assertNull(service.playingFile)
    }
}
