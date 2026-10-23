package com.rhymeai.app

import android.Manifest
import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.recording.RecordingCatalog
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.recording.RecordingTransitions
import com.rhymeai.app.data.sync.RecordingFileStore
import com.rhymeai.app.data.sync.RecordingRecord
import com.rhymeai.app.data.sync.SyncDeletion
import com.rhymeai.app.service.VoiceMemo
import com.rhymeai.app.service.VoiceMemoService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/**
 * A28: playback is authorized and started under the recording lock with a verified id;
 * Stop, release and a deletion cancel a play still being checked; a move stops playback
 * before its bytes move, and no play can start between that stop and the move.
 */
@RunWith(AndroidJUnit4::class)
class PlaybackGuardInstrumentedTest {
    companion object {
        /** Ten seconds of real audio, recorded once, so playback cannot end on its own during a test. */
        private lateinit var longTake: File

        @BeforeClass @JvmStatic fun recordOnce() {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val context = instrumentation.targetContext
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.RECORD_AUDIO)
            longTake = TestRecordings.recordFinalizedM4a(context, File(context.cacheDir, "playback-guard-take.m4a"), millis = 10_000L)
        }
    }

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val owned = File(context.filesDir, "playback-test-${UUID.randomUUID()}").apply { mkdirs() }
    private val isolated = object : ContextWrapper(context) { override fun getFilesDir(): File = owned }
    private val catalog = GatedCatalog()
    @Volatile private var deletions = emptyList<SyncDeletion>()
    private val service = VoiceMemoService(isolated).also {
        it.catalog = catalog
        it.deletionsProvider = { deletions }
    }
    private lateinit var memo: VoiceMemo
    private val id = "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b"

    /** Reads wait on [readGate] while [gateReads]; a changing write waits on [writeGate] while [gateWrites]. */
    private class GatedCatalog : RecordingCatalog {
        @Volatile var records = listOf<RecordingRecord>()
        @Volatile var gateReads = false
        /** Completed when a gated read is waiting: the play's check has begun. */
        val readEntered = CompletableDeferred<Unit>()
        val readGate = CompletableDeferred<Unit>()
        @Volatile var gateWrites = false
        val writeEntered = CompletableDeferred<Unit>()
        val writeGate = CompletableDeferred<Unit>()
        override suspend fun recordingRecords(): List<RecordingRecord> {
            if (gateReads) {
                readEntered.complete(Unit)
                readGate.await()
            }
            return records
        }
        override suspend fun updateRecordingRecords(transform: (List<RecordingRecord>) -> List<RecordingRecord>) {
            val next = transform(records)
            if (next != records && gateWrites) {
                gateWrites = false
                writeEntered.complete(Unit)
                writeGate.await()
            }
            records = next
        }
    }

    @Before fun placeTheTake() {
        // A36: on disk the take is named by its id; "take.m4a" is its display name.
        val file = File(RecordingFiles.memoDirectory(owned, "song").apply { mkdirs() }, "$id.m4a")
        longTake.copyTo(file)
        catalog.records = listOf(
            RecordingRecord(id, "song", "take.m4a", 1_000L, RecordingFileStore.sha256Hex(file), file.length(), RecordingRecord.RECORDED,
                path = RecordingTransitions.relativePath(owned, file))
        )
        memo = VoiceMemo(file, "take", 10_000L)
        RecordingTransitions.beforeBytesMove = service::stopPlayingIds
    }

    @After fun cleanUp() {
        RecordingTransitions.beforeBytesMove = null
        instrumentation.runOnMainSync { service.release() }
        owned.deleteRecursively()
    }

    private fun settle() {
        Thread.sleep(1_000)
        instrumentation.waitForIdleSync()
    }

    private fun play(target: VoiceMemo = memo) = instrumentation.runOnMainSync { service.play(target) }

    /** Plays and returns once the play's authorization is inside its gated read. */
    private fun playUntilChecking() {
        catalog.gateReads = true
        play()
        runBlocking { withTimeout(10_000) { catalog.readEntered.await() } }
    }

    @Test fun aPlayStartsWithTheRecordingsVerifiedId() {
        play()
        settle()
        assertEquals(memo.file, service.playingFile)
    }

    @Test fun anUnadoptedFileIsAdoptedBeforeItPlays() {
        catalog.records = emptyList()
        play()
        settle()
        assertEquals(memo.file, service.playingFile)
        // Adoption gave it an identity, so a later move can stop it by id.
        val adopted = catalog.records.single().id
        runBlocking { service.stopPlayingIds(setOf(adopted)) }
        assertNull(service.playingFile)
    }

    @Test fun stopWhileThePlaybackIsStillBeingCheckedWins() {
        playUntilChecking()
        instrumentation.runOnMainSync { service.stopPlayback() }
        catalog.readGate.complete(Unit)
        settle()
        assertNull(service.playingFile)
    }

    @Test fun releaseWhileThePlaybackIsStillBeingCheckedWins() {
        playUntilChecking()
        instrumentation.runOnMainSync { service.release() }
        catalog.readGate.complete(Unit)
        settle()
        assertNull(service.playingFile)
    }

    @Test fun aDeletionWhileThePlaybackIsStillBeingCheckedWins() {
        playUntilChecking()
        // The tombstone commits after the play's check began.
        deletions = listOf(SyncDeletion("song", "take.m4a", 9_000L, recordingId = id))
        catalog.gateReads = false
        runBlocking { service.onDeletionsChanged() }
        catalog.readGate.complete(Unit)
        settle()
        assertNull(service.playingFile)
        play()
        settle()
        assertNull(service.playingFile)
    }

    @Test fun anUnknownTimeSuspensionStopsActivePlaybackAndRefusesAnother() {
        // iOS third pass item 3: a tombstone whose time is unknown suspends its recording: it
        // stops a play in progress and no later play starts (its bytes stay).
        play()
        settle()
        assertEquals(memo.file, service.playingFile)

        deletions = listOf(SyncDeletion("song", "take.m4a", 0L, recordingId = id))
        runBlocking { service.onDeletionsChanged() }
        settle()
        assertNull(service.playingFile)

        val started = service.playersStarted
        play()
        runBlocking { service.awaitPlayCheck() }
        assertEquals(started, service.playersStarted)
        assertNull(service.playingFile)
        assertTrue(memo.file.exists())
    }

    @Test fun aRenameIsMetadataOnlyAndLeavesPlaybackRunning() = runBlocking<Unit> {
        play()
        settle()
        assertEquals(memo.file, service.playingFile)

        val renamed = RecordingTransitions.rename(catalog, owned, memo.file, "song", "Renamed.m4a")
        settle()

        assertEquals("Renamed.m4a", renamed?.displayName)
        assertEquals(memo.file, service.playingFile)
        assertTrue(memo.file.exists())
    }

    @Test fun aMoveToTrashStopsPlaybackAfterItsIntentAndBeforeItsBytesMoveAndNoPlayStartsMeanwhile() = runBlocking<Unit> {
        val started = System.nanoTime()
        play()
        settle()
        assertEquals(memo.file, service.playingFile)
        // At the hook: what was playing, whether the source was still in place, and what played after.
        var atHook: Triple<File?, Boolean, File?>? = null
        var hookAtMillis = 0L
        var playedMeanwhile: File? = null
        RecordingTransitions.beforeBytesMove = { ids ->
            hookAtMillis = (System.nanoTime() - started) / 1_000_000
            val before = service.playingFile
            service.stopPlayingIds(ids)
            atHook = Triple(before, memo.file.exists(), service.playingFile)
            // A play requested between the stop and the move waits for the lock: it cannot start now.
            instrumentation.runOnMainSync { service.play(memo) }
            kotlinx.coroutines.delay(500)
            playedMeanwhile = service.playingFile
        }

        catalog.gateWrites = true
        // The transition itself (not the service's own pre-trash stop) must stop playback.
        val trash = async(Dispatchers.IO) {
            RecordingTransitions.moveToTrash(catalog, owned, memo.file, "song", System.currentTimeMillis())
        }
        // The move's intent is being written (it comes first, rule a): the bytes have not moved and
        // the stop hook has not run yet, so the take still plays.
        withTimeout(10_000) { catalog.writeEntered.await() }
        assertEquals(memo.file, service.playingFile)
        assertNull(atHook)
        assertTrue(memo.file.exists())
        catalog.writeGate.complete(Unit)
        val trashed = withTimeout(10_000) { trash.await() }
        settle()
        assertEquals("$id.m4a", trashed?.name)
        assertEquals(RecordingFiles.trashDirectory(owned, "song").canonicalFile, trashed?.parentFile?.canonicalFile)
        assertNull(service.playingFile)
        // The take was still playing when the transition stopped it: the stop was the hook's, not the take's end.
        assertEquals(Triple(memo.file, true, null), atHook)
        assertNull(playedMeanwhile)
        assertTrue("hook ran at ${hookAtMillis}ms, after the take could have ended", hookAtMillis in 1 until 10_000)
    }

    @Test fun aQuarantineStopsActivePlaybackBeforeItsBytesMove() = runBlocking<Unit> {
        play()
        settle()
        assertEquals(memo.file, service.playingFile)
        // At the hook: what was playing, whether the source was still in place, and what played after.
        var atHook: Triple<File?, Boolean, File?>? = null
        RecordingTransitions.beforeBytesMove = { ids ->
            val before = service.playingFile
            service.stopPlayingIds(ids)
            atHook = Triple(before, memo.file.exists(), service.playingFile)
        }

        // The deletion reaches the quarantine directly: nothing else (the deletion observer,
        // the end of the take) can have stopped playback first.
        val moved = RecordingTransitions.quarantineDeleted(
            catalog, owned, listOf(SyncDeletion("song", "take.m4a", 9_000L, recordingId = id)), emptySet()
        )

        assertEquals(1, moved)
        assertEquals(Triple(memo.file, true, null), atHook)
        assertFalse(memo.file.exists())
        assertNull(service.playingFile)
    }
}
