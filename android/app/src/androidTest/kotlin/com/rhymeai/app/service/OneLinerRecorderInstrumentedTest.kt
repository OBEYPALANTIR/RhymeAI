package com.rhymeai.app.service

import android.Manifest
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** The microphone opens off the main thread; the take begins on it, and a stop before then cancels it. */
@RunWith(AndroidJUnit4::class)
class OneLinerRecorderInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val dir = File(context.cacheDir, "one-liner-recorder-test")
    private val recorder = OneLinerRecorder()

    @Before fun grant() {
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.RECORD_AUDIO)
        dir.deleteRecursively()
    }

    @After fun cleanUp() {
        instrumentation.runOnMainSync { recorder.discard() }
        dir.deleteRecursively()
    }

    @Test fun startOpensTheMicOffTheMainThreadThenRecordsTheTake() {
        val file = File(dir, "take.wav")
        val started = CountDownLatch(1)
        var result: Boolean? = null
        var answeredOnMain = false
        var openingAfterStart = false
        var recordingAfterStart = true
        instrumentation.runOnMainSync {
            recorder.start(file, context) {
                result = it
                answeredOnMain = android.os.Looper.myLooper() == android.os.Looper.getMainLooper()
                started.countDown()
            }
            openingAfterStart = recorder.isStarting
            recordingAfterStart = recorder.isRecording
        }
        assertTrue(openingAfterStart)
        assertFalse(recordingAfterStart)
        assertTrue(started.await(10, TimeUnit.SECONDS))
        assertEquals(true, result)
        assertTrue(answeredOnMain)
        SystemClock.sleep(300)
        var kept = false
        var recording = false
        instrumentation.runOnMainSync {
            recording = recorder.isRecording
            kept = recorder.stop()
        }
        assertTrue(recording)
        assertTrue(kept)
        assertEquals(file, recorder.takeFile)
        assertTrue(file.length() > 44)
        assertNull(MicrophoneOwner.current)
    }

    @Test fun stopWhileTheMicOpensCancelsTheStartAndReleasesIt() {
        val file = File(dir, "cancelled.wav")
        var answered = false
        var stopped = false
        var stillOpening = true
        instrumentation.runOnMainSync {
            recorder.start(file, context) { answered = true }
            stopped = recorder.stop()
            stillOpening = recorder.isStarting
        }
        assertTrue(stopped)
        assertFalse(stillOpening)
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (MicrophoneOwner.current != null && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(25)
        instrumentation.waitForIdleSync()
        assertNull(MicrophoneOwner.current)
        assertFalse(answered)
        assertFalse(recorder.isRecording)
        assertNull(recorder.takeFile)
        assertFalse(file.exists())
    }
}
