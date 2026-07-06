package com.rhymeai.app.service

import android.content.Context
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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
 * Handles recording, playback, and deletion of per-song voice memos.
 *
 * Files live at: context.filesDir/voice-memos/<projectId>/<timestamp>.m4a
 *
 * Resource discipline: every MediaRecorder and MediaPlayer is stop()ed and
 * release()d in all exit paths — including cancellation and error — mirroring
 * the fix applied to LocalModelService's llama handle.
 */
class VoiceMemoService(private val context: Context) {

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
        val dir = memoDir(projectId)
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("Could not create voice memo directory: ${dir.absolutePath}")
        }
        val timestamp = System.currentTimeMillis()
        val file = File(dir, "$timestamp.m4a")

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
     * nothing was being recorded. The memo file is only kept if recording produced
     * a non-empty file; otherwise it is deleted and null is returned.
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

        if (rec != null) {
            try {
                rec.stop()
            } catch (_: Exception) {
                // stop() can throw if recording was too short; still must release.
            } finally {
                rec.release()
            }
        }

        if (file == null || !file.exists() || file.length() == 0L) {
            file?.delete()
            return@withContext null
        }

        memoFromFile(file)
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
        playingFile = memo.file
    }

    /** Stop playback if it is in progress. Idempotent. */
    fun stopPlayback() {
        val mp = player
        player = null
        playingFile = null

        if (mp != null) {
            runCatching { mp.stop() }
            mp.release()
        }
    }

    // ---------------------------------------------------------------------------
    // Listing and deletion
    // ---------------------------------------------------------------------------

    /** Return all memos for [projectId], sorted newest-first. */
    suspend fun memosForProject(projectId: String): List<VoiceMemo> = withContext(Dispatchers.IO) {
        val dir = memoDir(projectId)
        if (!dir.exists()) return@withContext emptyList()
        dir.listFiles()
            ?.filter { it.isFile && it.name.endsWith(".m4a") }
            ?.sortedByDescending { it.lastModified() }
            ?.map { memoFromFile(it) }
            ?: emptyList()
    }

    /** Delete a single memo. Stops playback of that file if it is currently playing. */
    suspend fun deleteMemo(memo: VoiceMemo): Boolean {
        if (playingFile == memo.file) stopPlayback()
        return withContext(Dispatchers.IO) {
            deleteMemoFile(memo.file)
        }
    }

    /**
     * Rename [memo] to [newBasename] (without extension). The basename is sanitized:
     * leading/trailing whitespace is stripped, characters illegal on FAT32/ext4 paths
     * (`/ \ : * ? " < > |`) are removed, and runs of whitespace collapsed to a single
     * space. If the sanitized string is empty the rename is rejected (returns null).
     *
     * Collision: if `<sanitized>.m4a` already exists in the same directory, suffixes
     * " 2", " 3", … are tried until a free name is found (mirrors iOS behavior).
     *
     * Returns the renamed [VoiceMemo] on success, null on failure (bad name or
     * rename I/O error).
     */
    suspend fun renameMemo(memo: VoiceMemo, newBasename: String): VoiceMemo? {
        val sanitized = sanitizeBasename(newBasename)
        if (sanitized.isEmpty()) return null

        if (playingFile == memo.file) stopPlayback()

        return withContext(Dispatchers.IO) {
            val dir = memo.file.parentFile ?: return@withContext null
            val targetFile = resolveCollision(dir, sanitized)

            if (memo.file.renameTo(targetFile)) {
                memoFromFile(targetFile)
            } else {
                null
            }
        }
    }

    /**
     * Delete the entire memo directory for [projectId]. Called when a project is
     * permanently deleted so orphaned audio files do not accumulate.
     */
    suspend fun deleteMemoDirectory(projectId: String) {
        val dir = memoDir(projectId)
        val playing = playingFile
        if (playing != null && playing.path.startsWith(dir.path)) stopPlayback()

        withContext(Dispatchers.IO) {
            dir.deleteRecursively()
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

    private fun memoDir(projectId: String): File =
        memoDirectory(context.filesDir, projectId)

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
        const val MEMOS_ROOT_DIR = "voice-memos"
        const val MEMO_EXTENSION = ".m4a"

        fun memosRoot(filesDir: File): File =
            File(filesDir, MEMOS_ROOT_DIR)

        fun memoDirectory(filesDir: File, projectId: String): File =
            File(memosRoot(filesDir), projectId)


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

        /**
         * Strip characters that are illegal in file paths on Android (FAT32 + ext4),
         * collapse whitespace, and trim. Returns an empty string if nothing remains
         * after sanitization — the caller must reject empty results.
         */
        internal fun sanitizeBasename(raw: String): String =
            raw
                .replace(Regex("""[/\\:*?"<>|]"""), "")
                .replace(Regex("""\s+"""), " ")
                .trim()

        /**
         * Find a free filename for [base].m4a inside [dir]. If [base].m4a already
         * exists (and is not the source file being renamed), append " 2", " 3", … until
         * a free slot is found. The loop is capped at 999 to avoid an infinite cycle in
         * degenerate cases.
         */
        internal fun resolveCollision(dir: File, base: String): File {
            var candidate = File(dir, "$base.m4a")
            var suffix = 2
            while (candidate.exists() && suffix < 1000) {
                candidate = File(dir, "$base $suffix.m4a")
                suffix++
            }
            return candidate
        }
    }
}
