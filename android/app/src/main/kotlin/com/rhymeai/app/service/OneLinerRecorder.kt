package com.rhymeai.app.service

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Records one take for the capture sheet: 16 kHz mono PCM written to a WAV file, and (on
 * Android 13+, when a recognizer is available, the on-device one first) the same audio fed to
 * [SpeechRecognizer] for a live transcript. The microphone is opened once, by this recorder;
 * without speech the take still records and the writer types the words.
 */
class OneLinerRecorder {
    var isRecording by mutableStateOf(false)
        private set
    var startedAt by mutableStateOf<Long?>(null)
        private set
    /** What the recognizer heard in this take; the sheet puts it after the words already typed. */
    var transcript by mutableStateOf("")
        private set
    var levels by mutableStateOf(List(LEVEL_COUNT) { 0f })
        private set
    /** The take's file once recorded; null when there is none or it could not be written. */
    var takeFile by mutableStateOf<File?>(null)
        private set
    var takeDurationMs by mutableStateOf(0L)
        private set
    var notice by mutableStateOf<String?>(null)

    private val main by lazy { Handler(Looper.getMainLooper()) }
    private var audioRecord: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var writeFailed = false
    @Volatile private var inputFailed = false
    /** The pump wrote the WAV header and closed the file. */
    @Volatile private var finalized = false
    @Volatile private var bytesWritten = 0L
    private var recognizer: SpeechRecognizer? = null
    /** The end the recording thread writes to; closing it ends the recognition session. */
    private var feed: ParcelFileDescriptor? = null
    /** The end the recognizer reads. Android parcels it after startListening returns, so it stays open until teardown. */
    private var feedSource: ParcelFileDescriptor? = null
    private var heard = ""

    companion object {
        const val LEVEL_COUNT = 12
        const val SAMPLE_RATE = 16_000
        private const val WAV_HEADER_BYTES = 44
        const val WRITE_FAILURE_NOTICE = "Recording stopped because the audio couldn't be saved. The words so far are kept."
        const val INPUT_FAILURE_NOTICE = "Recording stopped because the microphone stopped sending audio. The words so far are kept."
        const val NO_SPEECH_NOTICE = "Live transcription isn't available here. The take is kept; type the words."
        const val MEMO_RECORDING_NOTICE = "A voice memo is recording. Stop it to record here, or type the line."
        private const val MIC_FAILED_NOTICE = "The microphone couldn't start. Type the line instead."
    }

    /** Starts a take writing to [file]. The caller holds RECORD_AUDIO. False when the mic could not open. */
    fun start(file: File, context: Context): Boolean {
        if (isRecording) return true
        val opened = MicrophoneOwner.claimWhileStarting(this) { open(file, context) }
        if (opened == null) notice = MEMO_RECORDING_NOTICE
        if (opened != true) MicrophoneOwner.release(this)
        return opened == true
    }

    @SuppressLint("MissingPermission")
    private fun open(file: File, context: Context): Boolean {
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val record = runCatching {
            AudioRecord(MediaRecorder.AudioSource.MIC, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuffer, SAMPLE_RATE / 5 * 2))
        }.getOrNull()
        if (record == null || record.state != AudioRecord.STATE_INITIALIZED) {
            record?.release()
            notice = MIC_FAILED_NOTICE
            return false
        }
        val output = try {
            file.parentFile?.mkdirs()
            RandomAccessFile(file, "rw").apply { setLength(0); write(ByteArray(WAV_HEADER_BYTES)) }
        } catch (_: Exception) {
            record.release()
            notice = WRITE_FAILURE_NOTICE
            return false
        }
        try {
            record.startRecording()
        } catch (_: Exception) {
            record.release()
            runCatching { output.close() }
            file.delete()
            notice = MIC_FAILED_NOTICE
            return false
        }
        audioRecord = record
        takeFile = file
        transcript = ""
        heard = ""
        bytesWritten = 0L
        writeFailed = false
        inputFailed = false
        finalized = false
        running = true
        isRecording = true
        startedAt = System.currentTimeMillis()
        val pipe = startRecognizer(context)
        thread = Thread({ pump(record, output, pipe) }, "one-liner-take").apply { start() }
        return true
    }

    /**
     * Ends the take and keeps it once its WAV is finished. False when the audio failed to
     * write, the input died, or the file could not be finished: that take is dropped and
     * never offered for saving.
     */
    fun stop(): Boolean {
        if (!isRecording) return true
        running = false
        // Stopping the input first ends a read in progress, so the pump can finish the file.
        audioRecord?.let { runCatching { it.stop() } }
        val pump = thread
        pump?.join(2_000)
        val finished = pump == null || (!pump.isAlive && finalized)
        thread = null
        audioRecord?.release()
        audioRecord = null
        // Closing the feed ends the recognizer's session; it delivers its last words first.
        runCatching { feed?.close() }
        feed = null
        val ending = recognizer to feedSource
        recognizer = null
        feedSource = null
        main.postDelayed({ releaseRecognizer(ending.first, ending.second) }, 1_500)
        isRecording = false
        MicrophoneOwner.release(this)
        levels = List(LEVEL_COUNT) { 0f }
        takeDurationMs = bytesWritten * 1000L / (SAMPLE_RATE * 2)
        if (writeFailed || inputFailed || !finished) {
            takeFile?.delete()
            takeFile = null
            notice = if (inputFailed) INPUT_FAILURE_NOTICE else WRITE_FAILURE_NOTICE
            return false
        }
        return true
    }


    /** A save moved the take (adopted, or put back after a failed save). */
    fun takeMoved(to: File) {
        takeFile = to
    }

    /** Closed without saving: the take is not kept. */
    fun discard() {
        stop()
        takeFile?.delete()
        takeFile = null
    }

    private fun pump(record: AudioRecord, output: RandomAccessFile, pipe: ParcelFileDescriptor?) {
        val buffer = ByteArray(SAMPLE_RATE / 10 * 2) // 100 ms
        var feeding = pipe != null
        try {
            while (running) {
                val read = record.read(buffer, 0, buffer.size)
                if (read < 0) {
                    // A dead or invalid input while still recording ends the take; after stop it is expected.
                    if (running) {
                        inputFailed = true
                        main.post { if (isRecording) stop() }
                    }
                    break
                }
                if (read == 0) continue
                try {
                    output.write(buffer, 0, read)
                    bytesWritten += read
                } catch (_: Exception) {
                    writeFailed = true
                    main.post { if (isRecording) stop() }
                    break
                }
                if (feeding) feeding = feedRecognizer(pipe!!, buffer, read)
                val level = normalizedLevel(buffer, read)
                main.post { levels = levels.drop(1) + level }
            }
        } finally {
            val headed = runCatching { writeWavHeader(output, bytesWritten) }.isSuccess
            val closed = runCatching { output.close() }.isSuccess
            if (headed && closed) finalized = true else writeFailed = true
        }
    }

    /** The recognizer never holds up the take: a full or closed pipe drops audio for it only. */
    private fun feedRecognizer(pipe: ParcelFileDescriptor, buffer: ByteArray, length: Int): Boolean = try {
        Os.write(pipe.fileDescriptor, buffer, 0, length)
        true
    } catch (error: ErrnoException) {
        error.errno == OsConstants.EAGAIN
    } catch (_: Exception) {
        false
    }

    /** Returns the pipe end the recording thread writes to, or null without live speech. */
    private fun startRecognizer(context: Context): ParcelFileDescriptor? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            notice = NO_SPEECH_NOTICE
            return null
        }
        val created = runCatching {
            when {
                SpeechRecognizer.isOnDeviceRecognitionAvailable(context) -> SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
                SpeechRecognizer.isRecognitionAvailable(context) -> SpeechRecognizer.createSpeechRecognizer(context)
                else -> null
            }
        }.getOrNull()
        if (created == null) {
            notice = NO_SPEECH_NOTICE
            return null
        }
        val (read, write) = runCatching { ParcelFileDescriptor.createPipe() }.getOrNull() ?: run {
            created.destroy()
            notice = NO_SPEECH_NOTICE
            return null
        }
        runCatching { Os.fcntlInt(write.fileDescriptor, OsConstants.F_SETFL, OsConstants.O_NONBLOCK) }
        created.setRecognitionListener(object : RecognitionListener {
            override fun onPartialResults(partialResults: Bundle?) = show(partialResults, commit = false)
            override fun onSegmentResults(segmentResults: Bundle) = show(segmentResults, commit = true)
            override fun onResults(results: Bundle?) = show(results, commit = true)
            override fun onError(error: Int) {
                if (isRecording) notice = "Transcription stopped. The take is still recording; type the words after."
            }
            override fun onEndOfSegmentedSession() {}
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, read)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, SAMPLE_RATE)
            // One session for the whole take: it ends when the feed closes.
            putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
        }
        return try {
            created.startListening(intent)
            recognizer = created
            feed = write
            feedSource = read
            // Android 13 parcels the queued intent later on the main thread: the read end must still be open.
            check(read.fileDescriptor.valid()) { "Recognizer audio source closed before it was sent" }
            write
        } catch (_: Exception) {
            recognizer = null
            feed = null
            feedSource = null
            releaseRecognizer(created, read)
            runCatching { write.close() }
            notice = NO_SPEECH_NOTICE
            null
        }
    }

    private fun show(results: Bundle?, commit: Boolean) {
        val words = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.trim().orEmpty()
        if (words.isEmpty()) return
        val joined = listOf(heard, words).filter { it.isNotEmpty() }.joinToString(" ")
        if (commit) heard = joined
        transcript = joined
    }

    /** Teardown: the recognizer goes first, then the audio source it was reading. */
    private fun releaseRecognizer(ending: SpeechRecognizer?, source: ParcelFileDescriptor?) {
        ending?.let { runCatching { it.destroy() } }
        source?.let { runCatching { it.close() } }
    }

    private fun normalizedLevel(buffer: ByteArray, length: Int): Float {
        var sum = 0.0
        val samples = length / 2
        for (i in 0 until samples) {
            val sample = (buffer[i * 2].toInt() and 0xFF) or (buffer[i * 2 + 1].toInt() shl 8)
            sum += sample.toDouble() * sample
        }
        val rms = sqrt(sum / maxOf(samples, 1)) / Short.MAX_VALUE
        val decibels = 20 * log10(maxOf(rms, 0.000_001))
        return ((decibels + 50) / 50).toFloat().coerceIn(0f, 1f)
    }

    private fun writeWavHeader(file: RandomAccessFile, dataBytes: Long) {
        val header = java.nio.ByteBuffer.allocate(WAV_HEADER_BYTES).order(java.nio.ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt((36 + dataBytes).toInt()); put("WAVE".toByteArray())
            put("fmt ".toByteArray()); putInt(16); putShort(1); putShort(1)
            putInt(SAMPLE_RATE); putInt(SAMPLE_RATE * 2); putShort(2); putShort(16)
            put("data".toByteArray()); putInt(dataBytes.toInt())
        }
        file.seek(0)
        file.write(header.array())
    }
}

/** Plays one take at a time; a song memo playing is stopped by the caller first. */
class OneLinerPlayer {
    var playingFile by mutableStateOf<File?>(null)
        private set
    private var player: MediaPlayer? = null

    /** False when the take could not be played. */
    fun toggle(file: File): Boolean {
        if (playingFile == file) { stop(); return true }
        stop()
        val mp = MediaPlayer()
        return try {
            mp.setDataSource(file.absolutePath)
            mp.setOnCompletionListener { stop() }
            mp.prepare()
            mp.start()
            player = mp
            playingFile = file
            true
        } catch (_: Exception) {
            mp.release()
            false
        }
    }

    fun stop() {
        player?.let { runCatching { it.stop() }; it.release() }
        player = null
        playingFile = null
    }
}
