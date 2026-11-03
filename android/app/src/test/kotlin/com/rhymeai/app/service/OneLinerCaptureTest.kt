package com.rhymeai.app.service

import com.rhymeai.app.data.model.OneLiner
import com.rhymeai.app.data.repository.OneLinerSaveFailure
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class OneLinerCaptureTest {
    private val directory = kotlin.io.path.createTempDirectory("rhymeai-capture").toFile()
    private val take = File(directory, "take.wav").apply { writeText("the only copy") }

    @AfterTest
    fun cleanUp() {
        directory.deleteRecursively()
    }

    private fun capturesWithTake(scope: CoroutineScope, mode: OneLinerCaptureSession.Mode = OneLinerCaptureSession.Mode.Record): OneLinerCaptures =
        OneLinerCaptures(scope).apply {
            open(mode)
            current!!.recorder.takeMoved(take)
            current!!.recorder.takeDurationMs = 7_000
            current!!.text = "half a line"
        }

    @Test
    fun anOpenCaptureIsNeverReplacedAndSaysSo() = runBlocking {
        val captures = capturesWithTake(this)
        val open = captures.current!!

        assertFalse(captures.open(OneLinerCaptureSession.Mode.Type))
        assertSame(open, captures.current)
        assertEquals("half a line", captures.current!!.text)
        assertEquals(FINISH_ONE_LINER_FIRST, open.recorder.notice)
    }

    @Test
    fun aRecreatedSheetPicksUpTheSameWordsAndTake() = runBlocking {
        val captures = capturesWithTake(this)
        // The first sheet holds the session, then goes away with its activity (nothing runs on its disposal).
        var sheet: OneLinerCaptureSession? = captures.current
        val recorder = sheet!!.recorder
        sheet = null
        assertNull(sheet)

        val recreated = captures.current!!
        assertSame(recorder, recreated.recorder)
        assertEquals("half a line", recreated.text)
        assertEquals(take, recreated.recorder.takeFile)
        assertTrue(take.exists())
    }

    @Test
    fun aSaveFinishesWhenTheScreenThatAskedForItIsGone() = runBlocking {
        val captures = capturesWithTake(this)
        val screen = CoroutineScope(Job() + coroutineContext[kotlin.coroutines.ContinuationInterceptor]!!)
        val gate = CompletableDeferred<Unit>()
        var persisted: Triple<String, File?, Long>? = null
        // The sheet asks for the save from its own scope and stays there until it goes away.
        val sheet = screen.launch {
            captures.save { text, file, durationMs -> gate.await(); persisted = Triple(text, file, durationMs) }
            awaitCancellation()
        }
        yield()
        assertTrue(captures.current!!.saving)
        screen.cancel() // the activity is recreated mid-save
        sheet.join()
        assertTrue(sheet.isCancelled)

        gate.complete(Unit)
        yield()
        assertEquals("half a line", persisted!!.first)
        assertEquals(take, persisted!!.second)
        assertNull(captures.current)
    }

    @Test
    fun aFailedSaveKeepsTheWordsAndTheTakeWhereItIsNow() = runBlocking {
        val captures = capturesWithTake(this)
        val putBack = File(directory, "put-back.wav")
        // The store moved the take, then could not move it home: it says where the take is now.
        captures.save { _, file, _ -> file!!.renameTo(putBack); throw OneLinerSaveFailure(IOException("disk full"), putBack) }
        yield()

        val session = captures.current!!
        assertFalse(session.saving)
        assertEquals(SAVE_FAILED_NOTICE, session.saveError)
        assertEquals(putBack, session.recorder.takeFile)
        assertEquals("the only copy", session.recorder.takeFile!!.readText())
        assertEquals("half a line", session.text)
    }

    @Test
    fun onlyAnExplicitCloseDiscardsTheTakeAndNeverMidSave() = runBlocking {
        val captures = capturesWithTake(this)
        val gate = CompletableDeferred<Unit>()
        captures.save { _, _, _ -> gate.await(); throw IOException("disk full") }
        yield()
        captures.dismiss()
        assertTrue(take.exists())
        gate.complete(Unit)
        yield()

        captures.dismiss()
        assertNull(captures.current)
        assertFalse(take.exists())
    }

    @Test
    fun discardingATakeKeepsTheWordsAndTheSheetButNeverMidSave() = runBlocking {
        val captures = capturesWithTake(this)
        val session = captures.current!!
        val gate = CompletableDeferred<Unit>()
        captures.save { _, _, _ -> gate.await(); throw IOException("disk full") }
        yield()
        session.discardTake()
        assertTrue(take.exists())
        assertEquals(take, session.recorder.takeFile)
        gate.complete(Unit)
        yield()

        session.discardTake()
        assertFalse(take.exists())
        assertNull(session.recorder.takeFile)
        assertEquals(0L, session.recorder.takeDurationMs)
        assertSame(session, captures.current)
        assertEquals("half a line", session.text)
    }

    @Test
    fun aDiscardedTakesLateWordsNeverReachTheNextTake() {
        val recorder = OneLinerRecorder()
        recorder.beginTake()
        val first = recorder.currentTake
        recorder.recognized(first, "Midnight", commit = true)
        assertEquals("Midnight", recorder.transcript)

        recorder.discard()
        recorder.recognized(first, "train", commit = true) // the stopped recognizer's last result, after the discard
        assertEquals("Midnight", recorder.transcript)

        recorder.beginTake()
        recorder.recognized(first, "train", commit = true)
        assertEquals("", recorder.transcript)
        recorder.recognized(recorder.currentTake, "Coffee", commit = true)
        assertEquals("Coffee", recorder.transcript)
    }

    @Test
    fun aNewTakeAppliesATranscriptEqualToTheLastTakes() {
        val session = OneLinerCaptureSession(OneLinerCaptureSession.Mode.Record)
        session.takeStarted()
        session.applyTranscript("Midnight")
        session.applyTranscript("Midnight") // a recreated sheet sees the same transcript again
        assertEquals("Midnight", session.text)

        session.discardTake()
        assertEquals("Midnight", session.text) // the words stay; only the audio goes
        session.text = ""
        session.takeStarted()
        session.applyTranscript("Midnight")
        assertEquals("Midnight", session.text)
    }

    @Test
    fun anEditNeverDiscardsATake() {
        val session = OneLinerCaptureSession(OneLinerCaptureSession.Mode.Edit(OneLiner(text = "Coffee gone cold")))
        session.recorder.takeMoved(take)
        session.discardTake()
        assertTrue(take.exists())
        assertEquals(take, session.recorder.takeFile)
    }

    @Test
    fun anEditSavesItsWordsWithoutATake() = runBlocking {
        val captures = OneLinerCaptures(this)
        captures.open(OneLinerCaptureSession.Mode.Edit(OneLiner(text = "Coffee gone cold")))
        assertEquals("Coffee gone cold", captures.current!!.text)
        var saved: String? = null
        captures.save { text, file, _ -> assertNull(file); saved = text }
        yield()
        assertEquals("Coffee gone cold", saved)
        assertNull(captures.current)
    }

    @Test
    fun theMicrophoneBelongsToOneRecorderInstance() {
        val firstMemo = Any()
        val secondMemo = Any()
        val line = Any()
        try {
            assertTrue(MicrophoneOwner.claim(firstMemo))
            assertTrue(MicrophoneOwner.claim(firstMemo))
            assertFalse(MicrophoneOwner.claim(secondMemo))
            assertFalse(MicrophoneOwner.claim(line))
            MicrophoneOwner.release(secondMemo) // not the owner: no effect
            assertSame(firstMemo, MicrophoneOwner.current)
            MicrophoneOwner.release(firstMemo)
            assertTrue(MicrophoneOwner.claim(line))
        } finally {
            listOf(firstMemo, secondMemo, line).forEach(MicrophoneOwner::release)
        }
    }

    @Test
    fun aStartThatFailsAfterClaimingLeavesTheMicrophoneFree() {
        val memo = Any()
        val other = Any()
        try {
            kotlin.test.assertFailsWith<IllegalStateException> {
                MicrophoneOwner.claimWhileStarting(memo) { error("MediaRecorder could not be created") }
            }
            assertNull(MicrophoneOwner.current)
            assertEquals("started", MicrophoneOwner.claimWhileStarting(other) { "started" })
            var ran = false
            assertNull(MicrophoneOwner.claimWhileStarting(memo) { ran = true; "never" })
            assertFalse(ran)
            assertSame(other, MicrophoneOwner.current)
        } finally {
            listOf(memo, other).forEach(MicrophoneOwner::release)
        }
    }
}
