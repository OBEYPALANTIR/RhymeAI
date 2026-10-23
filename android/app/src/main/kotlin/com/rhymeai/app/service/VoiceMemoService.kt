package com.rhymeai.app.service

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.provider.OpenableColumns
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.rhymeai.app.BuildConfig
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.withContext
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.data.recording.RecordingCatalog
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.recording.RecordingTransitions
import com.rhymeai.app.data.sync.RecordingManifestEntry
import com.rhymeai.app.data.sync.RecordingRecord
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.log10

data class VoiceMemo(
    val file: File,
    /** Display label derived from the file's last-modified timestamp. */
    val label: String,
    val durationMs: Long
)

/**
 * A recording sitting in the Trash Bin. The trash filename encodes the deletion
 * timestamp as "<deletedAt>__<originalName>" so trash state survives restarts
 * without a separate metadata store.
 */
data class TrashedVoiceMemo(
    val file: File,
    val projectId: String,
    /** Original filename (with extension) the memo had before it was trashed. */
    val originalName: String,
    val deletedAt: Long,
    val durationMs: Long
) {
    val deleteAfter: Long get() = deletedAt + TRASH_RETENTION_MILLIS
}

/**
 * Handles recording, playback, and deletion of per-song voice memos.
 *
 * Files live at: context.filesDir/voice-memos/<projectId>/<name>.<audio extension>
 *
 * Resource discipline: every MediaRecorder and MediaPlayer is stop()ed and
 * release()d in all exit paths — including cancellation and error — mirroring
 * the fix applied to LocalModelService's llama handle.
 */
class VoiceMemoService(private val context: Context) {

    // Recording Trash lives on disk, not in the preferences store, so nothing re-emits
    // when a recording is trashed, restored or deleted. The purge scheduler used to be
    // woken by unrelated preference writes re-emitting the trashed-songs flow; since that
    // flow only emits on real changes, trash changes announce themselves here.
    private val trashChangeEvents = MutableSharedFlow<Unit>(
        extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** Emits after a recording is moved to Trash, restored or permanently deleted. */
    val trashChanges: SharedFlow<Unit> = trashChangeEvents.asSharedFlow()

    private val memoChangeEvents = MutableSharedFlow<Unit>(
        extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** Emits after a recording is saved, imported, renamed, deleted, trashed or restored (drives backup). */
    val memoChanges: SharedFlow<Unit> = memoChangeEvents.asSharedFlow()

    // --- Recording state (exposed to Compose as observable properties) ---

    var isRecording by mutableStateOf(false)
        private set

    /** Elapsed recording time in milliseconds; updated every second while recording. */
    var recordingElapsedMs by mutableLongStateOf(0L)
        private set

    // --- Playback state ---

    /** File currently playing (null when idle). */
    var playingFile by mutableStateOf<File?>(null)
        private set

    // --- Private resource handles ---

    private var recorder: MediaRecorder? = null
    private var recordingFile: File? = null
    private var recordingStartMs = 0L

    private var player: MediaPlayer? = null
    /** The pending playback check, owned so Stop, release and deletions cancel it. */
    private var playJob: Job? = null
    /** The id of the recording playing, so it is found again after its path changes. */
    @Volatile private var playingRecordingId: String? = null

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private var tickJob: Job? = null
    private val durationCache = java.util.concurrent.ConcurrentHashMap<String, Long>()

    // ---------------------------------------------------------------------------
    // Amplitude (for spectralizer UI)
    // ---------------------------------------------------------------------------

    /**
     * Return the peak amplitude since the last call, normalized perceptually to 0..1.
     *
     * MediaRecorder exposes a linear peak in 0..32767; mapping it through decibels
     * over a -60..0 dB range makes normal speech visibly move the spectralizer.
     * Calling when not recording returns 0f.
     */
    fun currentAmplitude(): Float {
        val raw = recorder?.maxAmplitude ?: 0
        if (raw <= 0) return 0f

        val amplitude = raw / 32767f
        val db = 20.0 * log10(amplitude.toDouble())
        return (((db + 60.0) / 60.0).toFloat()).coerceIn(0f, 1f)
    }

    /** Shows the recording UI without a recorder; [take] stands in for a finished staged take. */
    internal fun seedRecordingForTesting(take: File? = null) {
        check(BuildConfig.DEBUG || BuildConfig.BENCHMARK) {
            "Recording test seeding requires a debug or benchmark build"
        }
        recordingFile = take
        recordingElapsedMs = 3_000L
        isRecording = true
    }

    /**
     * A take in staging that is not saved yet (A27). A marker beside it, written before
     * recording starts, holds its id and state, so it survives process death and later
     * recordings. [finished] means its finish was recorded (it waits to be saved);
     * otherwise its finish was never recorded and it "could not be saved": Retry saves
     * it only if the recorder finalized the file, which is checked first.
     */
    class WaitingTake internal constructor(
        val file: File,
        val projectId: String,
        /** Null while the take's marker cannot be read; it is never replaced by a new id. */
        val id: String?,
        val recordedAt: Long,
        val finished: Boolean
    )

    /** What a take's marker says; a marker that cannot be read is never treated as missing. */
    private sealed interface Marker {
        data object Absent : Marker
        data object Unreadable : Marker
        data class Read(val id: String, val state: String, val recordedAt: Long) : Marker
    }

    /** Whether a take whose finish was never recorded was finalized by the recorder. */
    internal enum class Inspection { FINALIZED, INVALID, CANNOT_INSPECT }

    /** Finished takes whose marker could not be updated; known to this process only. */
    private val finishedInSession = java.util.concurrent.ConcurrentHashMap<String, Long>()

    /** The recorder did not finish the take, so it was not published (A22). */
    class RecordingNotFinishedException(cause: Throwable) : java.io.IOException("Recording could not be finished", cause)

    /** The finished take could not be saved; it waits in staging and [retryWaitingTakes] saves it. */
    class RecordingNotSavedException(val projectId: String, cause: Throwable) : java.io.IOException("Recording could not be saved", cause)

    // ---------------------------------------------------------------------------
    // Recording
    // ---------------------------------------------------------------------------

    /**
     * Start recording a memo for [projectId]. The file is placed under
     * filesDir/voice-memos/<projectId>/<timestamp>.m4a.
     *
     * Returns the File being recorded to, so the caller can display a progress
     * indicator before stopRecording() is called. Throws if already recording.
     */
    suspend fun startRecording(projectId: String): File = withContext(Dispatchers.IO) {
        check(!isRecording) { "Already recording — call stopRecording() first" }

        // Ensure the directory exists; surface storage failures to the caller.
        val dir = RecordingFiles.memoDirectory(context.filesDir, projectId)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("Could not create voice memo directory: ${dir.absolutePath}")
        }
        // A22: the take is written in staging, outside the published memo folder, and
        // published with its record only when recording finishes successfully.
        val staging = RecordingFiles.stagingDirectory(context.filesDir, projectId)
        if (!staging.exists() && !staging.mkdirs()) {
            throw IllegalStateException("Could not create voice memo staging directory")
        }
        var timestamp = System.currentTimeMillis()
        var file = File(staging, "$timestamp.m4a")
        while (!file.createNewFile()) file = File(staging, "${++timestamp}.m4a")
        // A27: the take's id is on disk before a single sample is accepted.
        try {
            writeMarker(file, RecordingManifestEntry.newRecordingId(), STATE_RECORDING, 0L)
        } catch (e: Exception) {
            file.delete()
            throw e
        }

        val rec = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(context)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }

        try {
            rec.setAudioSource(MediaRecorder.AudioSource.MIC)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            rec.setAudioEncodingBitRate(128_000)
            rec.setAudioSamplingRate(44_100)
            rec.setOutputFile(file.absolutePath)
            rec.prepare()
            rec.start()
        } catch (e: Exception) {
            // Release immediately on failure — never leave an orphaned handle.
            runCatching { rec.stop() }
            rec.release()
            if (file.exists()) file.delete()
            throw e
        }

        recorder = rec
        recordingFile = file
        recordingStartMs = System.currentTimeMillis()
        isRecording = true
        recordingElapsedMs = 0L

        tickJob = scope.launch {
            while (true) {
                delay(1_000L)
                recordingElapsedMs = System.currentTimeMillis() - recordingStartMs
            }
        }

        file
    }

    /**
     * Stop an in-progress recording and return the saved [VoiceMemo], or null if
     * nothing was being recorded or the take is empty. Throws
     * [RecordingNotFinishedException] when the recorder fails to finish (the take stays
     * unpublished in staging) and [RecordingNotSavedException] when its record cannot be
     * written (the take waits in staging for [retryWaitingTakes]).
     */
    suspend fun stopRecording(): VoiceMemo? = withContext(Dispatchers.IO) {
        if (!isRecording) return@withContext null

        tickJob?.cancel()
        tickJob = null

        val rec = recorder
        val file = recordingFile
        recorder = null
        recordingFile = null
        isRecording = false
        recordingElapsedMs = 0L

        var stopError: Exception? = null
        if (rec != null) {
            try {
                rec.stop()
            } catch (e: Exception) {
                // stop() can throw if recording was too short; still must release.
                stopError = e
            } finally {
                rec.release()
            }
        }
        finishTake(file, stopError)
    }

    /** Publishes a stopped take only when the recorder finished it (A22). */
    internal suspend fun finishTake(file: File?, stopError: Exception?): VoiceMemo? {
        if (file == null || !file.exists() || file.length() == 0L) {
            file?.let { markerFor(it).delete() }
            file?.delete()
            if (stopError != null) throw RecordingNotFinishedException(stopError)
            return null
        }
        val projectId = file.parentFile?.name ?: return null
        val marker = readMarker(file)
        // Bytes without a finished container are not a recording; keep them out of the library.
        if (stopError != null) {
            (marker as? Marker.Read)?.let { runCatching { writeMarker(file, it.id, STATE_FAILED, 0L) } }
            throw RecordingNotFinishedException(stopError)
        }
        // A31: the finish and its time are known; this process keeps them whatever happens next.
        val finishedAt = System.currentTimeMillis()
        finishedInSession[file.path] = finishedAt
        // The id written before recording started is the take's id; it is never replaced.
        val id = (marker as? Marker.Read)?.id
            ?: throw RecordingNotSavedException(projectId, java.io.IOException("The take's marker could not be read"))
        try {
            writeMarker(file, id, STATE_FINISHED, finishedAt)
        } catch (e: Exception) {
            throw RecordingNotSavedException(projectId, e)
        }
        return publishTake(WaitingTake(file, projectId, id, finishedAt, finished = true), id)
    }

    /** Takes in staging that are not saved yet, for one song or all; the take being recorded is not one. */
    suspend fun waitingTakes(projectId: String? = null): List<WaitingTake> = withContext(Dispatchers.IO) {
        // Strict: a staging folder that cannot be read throws instead of hiding its takes.
        val root = RecordingFiles.stagingRoot(context.filesDir)
        RecordingTransitions.listStrictly(root)
            .filter { (projectId == null || it.name == projectId) && RecordingTransitions.isDirectoryStrictly(it) }
            .flatMap { dir ->
                RecordingTransitions.listStrictly(dir).filter { it.name.endsWith(MARKER_SUFFIX) }.mapNotNull { markerFile ->
                    val take = File(dir, markerFile.name.removeSuffix(MARKER_SUFFIX))
                    if (take == recordingFile) return@mapNotNull null
                    val sessionFinish = finishedInSession[take.path]
                    when (val marker = readMarker(take)) {
                        Marker.Absent -> null
                        Marker.Unreadable -> WaitingTake(take, dir.name, null, sessionFinish ?: take.lastModified(), finished = false)
                        is Marker.Read -> when {
                            marker.state == STATE_FINISHED -> WaitingTake(take, dir.name, marker.id, marker.recordedAt, finished = true)
                            sessionFinish != null && marker.state != STATE_FAILED ->
                                WaitingTake(take, dir.name, marker.id, sessionFinish, finished = true)
                            marker.state == STATE_RECORDING && take.exists() ->
                                WaitingTake(take, dir.name, marker.id, take.lastModified(), finished = false)
                            else -> null
                        }
                    }
                }
            }
            .sortedBy { it.recordedAt }
    }

    /**
     * Saves every waiting take (of [projectId], or all), each under the id from its
     * marker and the finish time it recorded (A31). A take whose record already holds
     * its id was saved before and counts as saved. A take whose finish was never
     * recorded is saved only if [inspectFinalized] confirms the recorder finalized it;
     * definitively invalid bytes are marked failed and never offered again, while a file
     * that cannot be inspected now stays waiting. Throws [RecordingNotSavedException] if
     * any take still cannot be saved.
     */
    suspend fun retryWaitingTakes(projectId: String? = null): Int = withContext(Dispatchers.IO) {
        var saved = 0
        var failure: RecordingNotSavedException? = null
        for (listed in waitingTakes(projectId)) {
            val id = listed.id
            if (id == null) {
                failure = RecordingNotSavedException(listed.projectId, java.io.IOException("The take's marker could not be read"))
                continue
            }
            try {
                val take = if (listed.finished) listed else when (inspectFinalized(listed.file)) {
                    Inspection.FINALIZED -> {
                        try {
                            writeMarker(listed.file, id, STATE_FINISHED, listed.recordedAt)
                        } catch (e: Exception) {
                            throw RecordingNotSavedException(listed.projectId, e)
                        }
                        WaitingTake(listed.file, listed.projectId, id, listed.recordedAt, finished = true)
                    }
                    Inspection.INVALID -> {
                        runCatching { writeMarker(listed.file, id, STATE_FAILED, 0L) }
                        throw RecordingNotSavedException(listed.projectId, java.io.IOException("The recording did not finish"))
                    }
                    Inspection.CANNOT_INSPECT ->
                        throw RecordingNotSavedException(listed.projectId, java.io.IOException("The recording could not be read"))
                }
                publishTake(take, id)
                saved++
            } catch (e: RecordingNotSavedException) {
                failure = e
            }
        }
        failure?.let { throw it }
        saved
    }

    /**
     * Whether the recorder finalized [file]. Structure first ([Mp4Integrity]): an intact
     * index whose every sample lies inside the media data. Then content, on the audio
     * track the index validated: the extractor must see that same track and return every
     * sample at its declared size, no AAC access unit may be all zeros (a valid one always
     * ends with an END element), and the decoder must decode to the end of the stream
     * with a frame count within 2048 frames (encoder delay) of the declared duration.
     * A file or decoder that cannot be used right now is [Inspection.CANNOT_INSPECT].
     */
    internal fun inspectFinalized(file: File): Inspection {
        val tracks = try {
            Mp4Integrity.check(file)
        } catch (_: Mp4Integrity.InvalidMp4) {
            return Inspection.INVALID
        } catch (_: java.io.IOException) {
            return Inspection.CANNOT_INSPECT
        }
        val trackIndex = tracks.indexOfFirst { it.handler == "soun" && it.sampleCount > 0 }
        val audio = tracks[trackIndex]
        val extractor = MediaExtractor()
        var codec: android.media.MediaCodec? = null
        try {
            extractor.setDataSource(file.absolutePath)
            // Bind to the validated track: the extractor lists the same tracks in index order.
            if (extractor.trackCount != tracks.size) return Inspection.INVALID
            val format = extractor.getTrackFormat(trackIndex)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return Inspection.INVALID
            if (!mime.startsWith("audio/")) return Inspection.INVALID
            extractor.selectTrack(trackIndex)
            val decoder = try {
                android.media.MediaCodec.createDecoderByType(mime)
            } catch (_: Exception) {
                return Inspection.CANNOT_INSPECT
            }
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            val info = android.media.MediaCodec.BufferInfo()
            var sample = 0
            var inputDone = false
            var frames = 0L
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var bytesPerSample = 2
            val sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val deadline = System.currentTimeMillis() + 60_000L
            while (true) {
                if (System.currentTimeMillis() > deadline) return Inspection.CANNOT_INSPECT
                if (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(10_000L)
                    if (inIndex >= 0) {
                        val buffer = decoder.getInputBuffer(inIndex)!!
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            if (sample != audio.sampleCount) return Inspection.INVALID
                            decoder.queueInputBuffer(inIndex, 0, 0, 0L, android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            if (sample >= audio.sampleCount || size.toLong() != audio.sampleSizes[sample]) return Inspection.INVALID
                            if (mime == MediaFormat.MIMETYPE_AUDIO_AAC && (0 until size).all { buffer.get(it) == 0.toByte() }) {
                                return Inspection.INVALID
                            }
                            decoder.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            sample++
                            extractor.advance()
                        }
                    }
                }
                val outIndex = decoder.dequeueOutputBuffer(info, 10_000L)
                when {
                    outIndex >= 0 -> {
                        frames += info.size / (channels * bytesPerSample)
                        decoder.releaseOutputBuffer(outIndex, false)
                        if (info.flags and android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                    }
                    outIndex == android.media.MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val output = decoder.outputFormat
                        channels = output.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        if (output.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                            output.getInteger(MediaFormat.KEY_PCM_ENCODING) == android.media.AudioFormat.ENCODING_PCM_FLOAT
                        ) bytesPerSample = 4
                    }
                }
            }
            val declared = audio.duration * sampleRate / audio.timescale
            return if (kotlin.math.abs(frames - declared) <= 2_048L) Inspection.FINALIZED else Inspection.INVALID
        } catch (_: Exception) {
            // A decoder or extractor error is not proof of a malformed take; it stays retryable.
            return Inspection.CANNOT_INSPECT
        } finally {
            codec?.let { runCatching { it.stop() }; it.release() }
            extractor.release()
        }
    }

    private fun markerFor(take: File) = File(take.parentFile, take.name + MARKER_SUFFIX)

    private fun writeMarker(take: File, id: String, state: String, recordedAt: Long) {
        val marker = markerFor(take)
        val temp = File(take.parentFile, marker.name + ".tmp")
        temp.writeText("$id\n$state\n$recordedAt\n")
        java.nio.file.Files.move(temp.toPath(), marker.toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE, java.nio.file.StandardCopyOption.REPLACE_EXISTING)
    }

    private fun readMarker(take: File): Marker {
        val lines = try {
            java.nio.file.Files.readAllLines(markerFor(take).toPath())
        } catch (_: java.nio.file.NoSuchFileException) {
            return Marker.Absent
        } catch (_: Exception) {
            return Marker.Unreadable
        }
        val id = lines.getOrNull(0)?.takeIf { runCatching { com.rhymeai.app.data.sync.SyncIdentity.validateRecordingId(it) }.isSuccess }
            ?: return Marker.Unreadable
        val state = lines.getOrNull(1)?.takeIf { it in setOf(STATE_RECORDING, STATE_FINISHED, STATE_FAILED) } ?: return Marker.Unreadable
        val recordedAt = lines.getOrNull(2)?.toLongOrNull() ?: return Marker.Unreadable
        return Marker.Read(id, state, recordedAt)
    }

    private suspend fun publishTake(take: WaitingTake, id: String): VoiceMemo? {
        val published = try {
            RecordingTransitions.publish(
                catalog, context.filesDir, take.file, take.projectId, take.file.name,
                id, take.recordedAt, RecordingRecord.RECORDED, skipIfPresent = true
            ) ?: catalog?.recordingRecords()?.firstOrNull { it.id == id }?.path?.let { File(context.filesDir, it) }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            val intentKept = runCatching { catalog?.recordingRecords()?.any { it.id == id } }.getOrNull() != false
            if (!take.file.exists() && !intentKept) {
                // Nothing left to save: the bytes are gone and no record holds the id.
                markerFor(take.file).delete()
                finishedInSession.remove(take.file.path)
                return null
            }
            // The take is still staged, or moved with its save unfinished; Retry finishes it.
            throw RecordingNotSavedException(take.projectId, e)
        }
        markerFor(take.file).delete()
        finishedInSession.remove(take.file.path)
        return published?.let { memoFromFile(it) }?.also { memoChangeEvents.tryEmit(Unit) }
    }

    /**
     * Cancel a recording in progress. The partially written file is deleted.
     */
    fun cancelRecording() {
        if (!isRecording) return

        tickJob?.cancel()
        tickJob = null

        val rec = recorder
        val file = recordingFile
        recorder = null
        recordingFile = null
        isRecording = false
        recordingElapsedMs = 0L

        if (rec != null) {
            runCatching { rec.stop() }
            rec.release()
        }
        file?.let { markerFor(it).delete() }
        file?.delete()
    }

    // ---------------------------------------------------------------------------
    // Playback
    // ---------------------------------------------------------------------------

    /**
     * Start playing [memo]. If another memo is already playing it is stopped first.
     * When playback completes naturally, [playingFile] is cleared automatically.
     */
    fun play(memo: VoiceMemo) {
        stopPlayback()
        // A28: checked off the main thread first; Stop, release and a deletion cancel the check.
        playJob = scope.launch {
            val id = withContext(Dispatchers.IO) { playableRecordingId(memo.file) } ?: return@launch
            startPlayer(memo, id.ifEmpty { null })
        }
    }

    /**
     * The id of the recording at [file] ("" when it has no record yet), or null when a
     * known tombstone removes it or that cannot be read (fails closed).
     */
    private suspend fun playableRecordingId(file: File): String? = try {
        val path = RecordingTransitions.relativePath(context.filesDir, file)
        val records = catalog?.recordingRecords().orEmpty()
        when {
            path in deletedPaths() -> null
            // A move or save not yet reconciled (for example after a failed reconcile) is not playable yet.
            records.any { it.pendingOp != null && (it.path == path || it.pendingFrom == path) } -> null
            else -> records.firstOrNull { it.path == path }?.id ?: ""
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private fun startPlayer(memo: VoiceMemo, recordingId: String?) {
        releasePlayer()
        val mp = MediaPlayer()
        try {
            mp.setDataSource(memo.file.absolutePath)
            mp.setOnPreparedListener { prepared ->
                if (player === prepared) prepared.start()
            }
            mp.setOnCompletionListener { completed ->
                if (player === completed) stopPlayback()
            }
            mp.setOnErrorListener { errored, _, _ ->
                if (player === errored) stopPlayback()
                true
            }
            mp.prepareAsync()
        } catch (e: Exception) {
            mp.release()
            return
        }

        player = mp
        playingRecordingId = recordingId
        playingFile = memo.file
    }

    /** Stop playback, and any playback still being checked. Idempotent. */
    fun stopPlayback() {
        playJob?.cancel()
        playJob = null
        releasePlayer()
    }

    private fun releasePlayer() {
        val mp = player
        player = null
        playingFile = null
        playingRecordingId = null

        if (mp != null) {
            runCatching { mp.stop() }
            mp.release()
        }
    }

    /**
     * Called before the bytes of recordings [ids] move (quarantine, A30 rename): playback
     * of them stops first, and a playback still being checked is cancelled.
     */
    suspend fun stopPlayingIds(ids: Set<String>) = withContext(Dispatchers.Main) {
        playJob?.takeIf { it.isActive }?.cancel()
        if (playingRecordingId in ids) stopPlayback()
    }

    // ---------------------------------------------------------------------------
    // Listing and deletion
    // ---------------------------------------------------------------------------

    /** Return all memos for [projectId], sorted newest-first. */
    suspend fun memosForProject(projectId: String): List<VoiceMemo> = withContext(Dispatchers.IO) {
        val dir = RecordingFiles.memoDirectory(context.filesDir, projectId)
        if (!dir.exists()) return@withContext emptyList()
        val hidden = deletedPaths()
        dir.listFiles()
            ?.filter { RecordingFiles.isMemoFile(it) && it != recordingFile && RecordingTransitions.relativePath(context.filesDir, it) !in hidden }
            ?.sortedByDescending { it.lastModified() }
            ?.map { memoFromFile(it) }
            ?: emptyList()
    }

    /** Copy a selected document into this song; no microphone permission is needed. */
    suspend fun importRecording(projectId: String, uri: Uri): VoiceMemo {
        var staged: File? = null
        try {
            return withContext(Dispatchers.IO) {
                val resolver = context.contentResolver
                val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    } ?: throw IllegalArgumentException("Missing audio filename")
                val coroutineContext = currentCoroutineContext()
                val source = resolver.openInputStream(uri)
                    ?: throw java.io.IOException("Cannot open audio")
                val pending = RecordingImportStore.stage(
                        input = source,
                        directory = RecordingFiles.stagingDirectory(context.filesDir, projectId),
                        displayName = name,
                        checkCancellation = { coroutineContext.ensureActive() },
                        validate = { candidate -> requirePlayableAudio(candidate) }
                    )
                staged = pending.file
                // A new recording with its own id and time, even if identical bytes were deleted before (A21).
                val file = RecordingTransitions.publish(
                    catalog, context.filesDir, pending.file, projectId, pending.desiredName,
                    RecordingManifestEntry.newRecordingId(), System.currentTimeMillis(), RecordingRecord.RECORDED
                ) ?: throw java.io.IOException("Recording could not be published")
                memoFromFile(file)
            }.also { memoChangeEvents.tryEmit(Unit) }
        } finally {
            staged?.takeIf { it.exists() }?.delete()
        }
    }

    /** Delete a single memo. Stops playback of that file if it is currently playing. */
    suspend fun deleteMemo(memo: VoiceMemo): Boolean {
        if (playingFile == memo.file) stopPlayback()
        return withContext(Dispatchers.IO) {
            deleteMemoFile(memo.file).also { deleted ->
                if (deleted) forgetRecord(memo.file)
            }
        }.also { if (it) memoChangeEvents.tryEmit(Unit) }
    }

    // ---------------------------------------------------------------------------
    // Recordings trash
    // ---------------------------------------------------------------------------

    /**
     * Move [memo] to the Trash Bin instead of deleting it. The file is relocated
     * to voice-memos-trash/<projectId>/<deletedAt>__<original filename> and kept for
     * [TRASH_RETENTION_MILLIS] before purge. Returns false on I/O failure.
     */
    /** Returns the trashed record on success (usable for undo), null on failure. */
    suspend fun trashMemo(memo: VoiceMemo): TrashedVoiceMemo? {
        if (playingFile == memo.file) stopPlayback()
        return withContext(Dispatchers.IO) {
            val projectId = memo.file.parentFile?.name ?: return@withContext null
            if (!memo.file.exists()) return@withContext null
            val dir = RecordingFiles.trashDirectory(context.filesDir, projectId)
            if (!dir.exists() && !dir.mkdirs()) return@withContext null
            // Bump the timestamp on collision so renameTo never overwrites an
            // existing trashed file (same name trashed twice in one millisecond).
            val moved = moveOrNull(
                memo.file, projectId, memo.file.name,
                pick = {
                    var deletedAt = System.currentTimeMillis()
                    var target = File(dir, "$deletedAt$TRASH_NAME_SEPARATOR${memo.file.name}")
                    while (target.exists()) {
                        deletedAt++
                        target = File(dir, "$deletedAt$TRASH_NAME_SEPARATOR${memo.file.name}")
                    }
                    target
                },
                renamesTo = { null }
            )
            moved?.let { trashedMemoFromFile(it, projectId) }
        }.also { if (it != null) run { trashChangeEvents.tryEmit(Unit); memoChangeEvents.tryEmit(Unit) } }
    }

    /** All trashed recordings across every project, newest deletion first. */
    suspend fun trashedMemos(): List<TrashedVoiceMemo> = withContext(Dispatchers.IO) {
        // Strict: a Trash folder that cannot be read throws, so expiry reports it unfinished.
        val root = RecordingFiles.trashRoot(context.filesDir)
        val hidden = deletedPaths()
        RecordingTransitions.listStrictly(root)
            .filter { RecordingTransitions.isDirectoryStrictly(it) }
            .flatMap { dir ->
                RecordingTransitions.listStrictly(dir)
                    .filter {
                        RecordingTransitions.isRegularFileStrictly(it) &&
                            it.extension.lowercase(Locale.ROOT) in RecordingFiles.SUPPORTED_AUDIO_EXTENSIONS &&
                            RecordingTransitions.relativePath(context.filesDir, it) !in hidden
                    }
                    .mapNotNull { file -> trashedMemoFromFile(file, dir.name) }
            }
            .sortedByDescending { it.deletedAt }
    }

    /**
     * Move a trashed recording back into its project's live memo folder under
     * its original name (suffixed if that name is now taken).
     */
    suspend fun restoreTrashedMemo(trashed: TrashedVoiceMemo): Boolean = withContext(Dispatchers.IO) {
        if (!trashed.file.exists()) return@withContext false
        val dir = RecordingFiles.memoDirectory(context.filesDir, trashed.projectId)
        if (!dir.exists() && !dir.mkdirs()) return@withContext false
        val original = File(trashed.originalName)
        val restoredAs = moveOrNull(
            trashed.file, trashed.projectId, trashed.originalName,
            pick = { RecordingFiles.resolveCollision(dir, original.nameWithoutExtension, original.extension) },
            renamesTo = { it.name }
        )
        (restoredAs != null).also {
            cleanUpEmptyTrashDir(trashed.file.parentFile)
            if (it) run { trashChangeEvents.tryEmit(Unit); memoChangeEvents.tryEmit(Unit) }
        }
    }

    /**
     * Records a permanent recording deletion for Drive sync (projectId, original file
     * name, deletedAt). Runs before the file is removed; a throw keeps the file in Trash.
     */
    var recordingDeletionRecorder: (suspend (projectId: String, fileName: String, recordingId: String, deletedAt: Long) -> Unit)? = null

    /**
     * Where recording records live (A20/A21); every file transition writes its record
     * intent first and fails if that write fails (A24). Null only in tests.
     */
    var catalog: RecordingCatalog? = null

    /**
     * A rename, Trash or restore from Trash; a failed metadata write or invalid name
     * leaves the file where it was and reads as a failed move (null) for the caller.
     */
    private suspend fun moveOrNull(
        from: File,
        projectId: String,
        displayName: String,
        pick: () -> File,
        renamesTo: (File) -> String?
    ): File? = try {
        RecordingTransitions.move(catalog, context.filesDir, from, projectId, displayName, pick, renamesTo)
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    /** The sync tombstones known here (A28); null only in tests. */
    var deletionsProvider: (suspend () -> List<com.rhymeai.app.data.sync.SyncDeletion>)? = null

    private val deletionChangeEvents = MutableSharedFlow<Unit>(
        extraBufferCapacity = 1, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** Emits when the known tombstones change, so recordings lists re-read what is visible (A28). */
    val deletionChanges: SharedFlow<Unit> = deletionChangeEvents.asSharedFlow()

    /** Call when the sync tombstones change: lists refresh and a removed recording stops playing. */
    suspend fun onDeletionsChanged() {
        deletionChangeEvents.tryEmit(Unit)
        // A playback still being checked may have read the tombstones before this change.
        withContext(Dispatchers.Main) { playJob?.takeIf { it.isActive }?.cancel() }
        val playing = playingFile ?: return
        val id = playingRecordingId
        val removed = withContext(Dispatchers.IO) {
            try {
                val deletions = deletionsProvider?.invoke() ?: emptyList()
                val records = catalog?.recordingRecords().orEmpty()
                if (id != null) {
                    // By id: a record that is gone (quarantined) or that a tombstone removes.
                    val record = records.firstOrNull { it.id == id }
                    record == null || com.rhymeai.app.data.sync.SyncMerger.Tombstones(deletions).removes(record.toEntry())
                } else {
                    RecordingTransitions.relativePath(context.filesDir, playing) in RecordingTransitions.deletedPaths(records, deletions)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                true
            }
        }
        if (removed) withContext(Dispatchers.Main) { if (playingFile == playing) stopPlayback() }
    }

    /**
     * Recordings a known winning tombstone removes, hidden while their quarantine is
     * pending. Throws when the tombstones or records cannot be read, so callers fail
     * closed (A31).
     */
    private suspend fun deletedPaths(): Set<String> {
        val catalog = catalog ?: return emptySet()
        val deletions = deletionsProvider?.invoke() ?: return emptySet()
        return RecordingTransitions.deletedPaths(catalog.recordingRecords(), deletions)
    }

    /** Drops the record of a file that is gone; a failed write is cleaned up by the next snapshot. */
    private suspend fun forgetRecord(file: File) {
        val path = RecordingTransitions.relativePath(context.filesDir, file)
        runCatching { catalog?.updateRecordingRecords { records -> records.filterNot { it.path == path } } }
    }

    /** Permanently delete a trashed recording. */
    suspend fun permanentlyDeleteTrashedMemo(trashed: TrashedVoiceMemo): Boolean {
        if (playingFile == trashed.file) stopPlayback()
        try {
            val catalog = catalog
            if (catalog != null) {
                // Null: the file was a duplicate copy of a pre-v4 recording and now sits in
                // quarantine (A26); it has left the Trash and its deletion must not tombstone the live copy.
                val record = RecordingTransitions.recordFor(catalog, context.filesDir, trashed.file, trashed.projectId)
                    ?: return true.also { trashChangeEvents.tryEmit(Unit); memoChangeEvents.tryEmit(Unit) }
                recordingDeletionRecorder?.invoke(trashed.projectId, trashed.originalName, record.id, System.currentTimeMillis())
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            return false
        }
        return withContext(Dispatchers.IO) {
            deleteMemoFile(trashed.file).also {
                if (it) forgetRecord(trashed.file)
                cleanUpEmptyTrashDir(trashed.file.parentFile)
            }
        }.also { if (it) run { trashChangeEvents.tryEmit(Unit); memoChangeEvents.tryEmit(Unit) } }
    }

    /** Delete expired trashed recordings on their own clock, reporting partial failures. */
    suspend fun purgeExpiredTrashedMemos(now: Long = System.currentTimeMillis()): Boolean {
        var complete = true
        for (memo in trashedMemos().filter { it.deleteAfter <= now }) {
            if (!permanentlyDeleteTrashedMemo(memo)) complete = false
        }
        return complete
    }

    /** Earliest deleteAfter among trashed recordings, or null when trash is empty. */
    suspend fun nextTrashedMemoExpiry(): Long? =
        trashedMemos().minOfOrNull { it.deleteAfter }

    /**
     * Rename [memo] to [newBasename] (without extension). The basename is sanitized:
     * leading/trailing whitespace is stripped, characters illegal on FAT32/ext4 paths
     * (`/ \ : * ? " < > |`) are removed, and runs of whitespace collapsed to a single
     * space. If the sanitized string is empty the rename is rejected (returns null).
     *
     * Collision: if the sanitized name with the original extension already exists, suffixes
     * " 2", " 3", … are tried until a free name is found (mirrors iOS behavior).
     *
     * Returns the renamed [VoiceMemo] on success, null on failure (bad name or
     * rename I/O error).
     */
    suspend fun renameMemo(memo: VoiceMemo, newBasename: String): VoiceMemo? {
        val sanitized = RecordingFiles.sanitizeBasename(newBasename)
        if (sanitized.isEmpty()) return null

        if (playingFile == memo.file) stopPlayback()

        return withContext(Dispatchers.IO) {
            val dir = memo.file.parentFile ?: return@withContext null
            // A rename changes only the file name; the recording keeps its id and time (A21).
            val targetFile = moveOrNull(
                memo.file, dir.name, memo.file.name,
                pick = { RecordingFiles.resolveCollision(dir, sanitized, memo.file.extension) },
                renamesTo = { it.name }
            )

            if (targetFile != null) {
                memoFromFile(targetFile)
            } else {
                null
            }
        }.also { if (it != null) memoChangeEvents.tryEmit(Unit) }
    }

    /**
     * Delete the entire memo directory for [projectId] — live and trashed. Called
     * when a project is permanently deleted so orphaned audio files do not accumulate.
     */
    suspend fun deleteMemoDirectory(projectId: String): Boolean {
        val (dir, trash) = runCatching {
            RecordingFiles.memoDirectory(context.filesDir, projectId) to RecordingFiles.trashDirectory(context.filesDir, projectId)
        }.getOrNull() ?: return false
        val playing = playingFile
        val playingPath = playing?.let { runCatching { it.canonicalFile.toPath() }.getOrNull() }
        if (playingPath != null && (playingPath.startsWith(dir.toPath()) || playingPath.startsWith(trash.toPath()))) {
            stopPlayback()
        }

        return withContext(Dispatchers.IO) {
            // Only confirmed absence counts as removed; a folder that cannot be read is retried.
            val liveRemoved = RecordingTransitions.isConfirmedAbsent(dir) || dir.deleteRecursively()
            val trashRemoved = RecordingTransitions.isConfirmedAbsent(trash) || trash.deleteRecursively()
            liveRemoved && trashRemoved
        }
    }

    // ---------------------------------------------------------------------------
    // Release
    // ---------------------------------------------------------------------------

    /**
     * Release all resources. Call from the component that owns this service when
     * it is permanently torn down (e.g. ViewModel.onCleared).
     */
    fun release() {
        cancelRecording()
        stopPlayback()
    }

    // ---------------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------------

    private fun trashedMemoFromFile(file: File, projectId: String): TrashedVoiceMemo? {
        val (deletedAt, originalName) = parseTrashedName(file.name) ?: return null
        return TrashedVoiceMemo(
            file = file,
            projectId = projectId,
            originalName = originalName,
            deletedAt = deletedAt,
            durationMs = probeAudioDurationMs(file)
        )
    }

    /** Remove a project's trash folder once its last recording leaves it. */
    private fun cleanUpEmptyTrashDir(dir: File?) {
        if (dir != null && dir.isDirectory && dir.listFiles()?.isEmpty() == true) {
            dir.delete()
        }
    }

    /**
     * Throws unless [file] holds a playable audio track. A recorder writes the MPEG-4
     * index only when it finishes, so an unfinished take fails this check.
     */
    private fun requirePlayableAudio(file: File) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            require((0 until extractor.trackCount).any { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            }) { "No audio track" }
        } finally {
            extractor.release()
        }
        require(probeAudioDurationMs(file) > 0) { "Audio cannot be played" }
    }

    private fun memoFromFile(file: File): VoiceMemo {
        val durationMs = probeAudioDurationMs(file)
        val ts = file.nameWithoutExtension.toLongOrNull() ?: file.lastModified()
        val label = formatMemoLabel(ts)
        return VoiceMemo(file = file, label = label, durationMs = durationMs)
    }

    private fun probeAudioDurationMs(file: File): Long {
        val key = "${file.absolutePath}:${file.lastModified()}"
        durationCache[key]?.let { return it }

        // MediaMetadataRetriever would work but requires android.permission.INTERNET in some
        // paths and adds latency. For display purposes, probing via a temporary MediaPlayer
        // is reliable, cheap, and available at API 21+.
        // MediaPlayer doesn't implement AutoCloseable, so use try/finally to release it.
        val mp = MediaPlayer()
        val duration = try {
            mp.setDataSource(file.absolutePath)
            mp.prepare()
            mp.duration.toLong().coerceAtLeast(0L)
        } catch (_: Exception) {
            0L
        } finally {
            mp.release()
        }
        durationCache[key] = duration
        return duration
    }

    companion object {
        private val LABEL_FORMAT = SimpleDateFormat("MMM d, h:mm a", Locale.getDefault())
        /** Separates the deletion timestamp from the original name in trash filenames. */
        const val TRASH_NAME_SEPARATOR = "__"

        /** Beside each staged take: its id, state and finish time (A27). */
        private const val MARKER_SUFFIX = ".take"
        private const val STATE_RECORDING = "recording"
        private const val STATE_FINISHED = "finished"
        private const val STATE_FAILED = "failed"

        /** Splits a trashed file name `<deletedAt>__<original>`; null when it is not one. */
        internal fun parseTrashedName(name: String): Pair<Long, String>? {
            val separatorIndex = name.indexOf(TRASH_NAME_SEPARATOR)
            if (separatorIndex <= 0) return null
            val deletedAt = name.substring(0, separatorIndex).toLongOrNull() ?: return null
            val originalName = name.substring(separatorIndex + TRASH_NAME_SEPARATOR.length)
            return if (originalName.isEmpty()) null else deletedAt to originalName
        }

        fun formatMemoLabel(timestampMs: Long): String =
            LABEL_FORMAT.format(Date(timestampMs))

        fun formatDuration(ms: Long): String {
            val totalSecs = (ms / 1_000).coerceAtLeast(0)
            val mins = totalSecs / 60
            val secs = totalSecs % 60
            return "%d:%02d".format(mins, secs)
        }

        /**
         * Human-readable display name for a memo file.
         *
         * If the filename (without `.m4a`) is a raw millisecond timestamp (all digits),
         * return the formatted date label. Otherwise return the custom basename — this is
         * what the user named it via [renameMemo].
         */
        fun displayName(file: File): String {
            val base = file.nameWithoutExtension
            return if (base.toLongOrNull() != null) {
                formatMemoLabel(base.toLong())
            } else {
                base
            }
        }

        /**
         * Delete [file], reporting success for UI surfacing. An already-absent file
         * counts as success — there is nothing left to fail to remove, so callers
         * should not show a delete-failed error for it.
         */
        internal fun deleteMemoFile(file: File): Boolean =
            !file.exists() || file.delete()

    }
}
