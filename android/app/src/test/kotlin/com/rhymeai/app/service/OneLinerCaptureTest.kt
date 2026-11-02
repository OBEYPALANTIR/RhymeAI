package com.rhymeai.app.service

import com.rhymeai.app.data.model.OneLiner
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class OneLinerCaptureTest {
    private val directory = kotlin.io.path.createTempDirectory("rhymeai-capture").toFile()
    private val leftover = File(directory, "left.wav").apply { writeText("take") }

    @AfterTest
    fun cleanUp() {
        directory.deleteRecursively()
        MicrophoneOwner.release(MicrophoneOwner.Owner.ONE_LINER)
        MicrophoneOwner.release(MicrophoneOwner.Owner.SONG_MEMO)
    }

    @Test
    fun anOpenCaptureIsNeverReplacedAndSaysSo() {
        val captures = OneLinerCaptures()
        assertTrue(captures.open(OneLinerCaptureSession.Mode.Type))
        val open = captures.current!!
        open.text = "half a line"

        assertFalse(captures.open(OneLinerCaptureSession.Mode.Record))
        assertSame(open, captures.current)
        assertEquals("half a line", captures.current!!.text)
        assertEquals(FINISH_ONE_LINER_FIRST, open.recorder.notice)
    }

    @Test
    fun onlyAnExplicitCloseDiscardsTheTake() {
        val captures = OneLinerCaptures { leftover }
        captures.open(OneLinerCaptureSession.Mode.Record)
        val session = captures.current!!
        assertEquals(leftover, session.recorder.takeFile)
        assertEquals(RECOVERED_TAKE_NOTICE, session.recorder.notice)

        // A recreated sheet reads the same session: the take and words are still there.
        assertSame(session, captures.current)
        assertTrue(leftover.exists())

        captures.dismiss()
        assertNull(captures.current)
        assertFalse(leftover.exists())
    }

    @Test
    fun aSavedCaptureKeepsItsTakeAndEditsAreNotOfferedOne() {
        val captures = OneLinerCaptures { leftover }
        captures.open(OneLinerCaptureSession.Mode.Type)
        captures.saved()
        assertNull(captures.current)
        assertTrue(leftover.exists())

        captures.open(OneLinerCaptureSession.Mode.Edit(OneLiner(text = "Coffee gone cold")))
        assertNull(captures.current!!.recorder.takeFile)
        assertEquals("Coffee gone cold", captures.current!!.text)
    }

    @Test
    fun theMicrophoneHasOneOwnerAtATime() {
        assertTrue(MicrophoneOwner.claim(MicrophoneOwner.Owner.SONG_MEMO))
        assertFalse(MicrophoneOwner.claim(MicrophoneOwner.Owner.ONE_LINER))
        MicrophoneOwner.release(MicrophoneOwner.Owner.ONE_LINER) // not the owner: no effect
        assertEquals(MicrophoneOwner.Owner.SONG_MEMO, MicrophoneOwner.current)
        MicrophoneOwner.release(MicrophoneOwner.Owner.SONG_MEMO)
        assertTrue(MicrophoneOwner.claim(MicrophoneOwner.Owner.ONE_LINER))
        assertFalse(MicrophoneOwner.claim(MicrophoneOwner.Owner.SONG_MEMO))
    }
}
