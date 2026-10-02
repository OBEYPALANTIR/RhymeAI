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
import kotlinx.coroutines.withContext
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.data.recording.RecordingFiles
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

    internal fun seedRecordingForTesting() {
        check(BuildConfig.DEBUG || BuildConfig.BENCHMARK) {
            "Recording test seeding requires a debug or benchmark build"
        }
        recordingElapsedMs = 3_000L
        isRecording = true
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
        val dir = RecordingFiles.memoDirectory(context.filesDir, projectId)
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
        val dir = RecordingFiles.memoDirectory(context.filesDir, projectId)
        if (!dir.exists()) return@withContext emptyList()
        dir.listFiles()
            ?.filter { RecordingFiles.isMemoFile(it) && it != recordingFile }
            ?.sortedByDescending { it.lastModified() }
            ?.map { memoFromFile(it) }
            ?: emptyList()
    }

    /** Copy a selected document into this song; no microphone permission is needed. */
    suspend fun importRecording(projectId: String, uri: Uri): VoiceMemo {
        var imported: File? = null
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
                val file = RecordingImportStore.copy(
                        input = source,
                        directory = RecordingFiles.memoDirectory(context.filesDir, projectId),
                        displayName = name,
                        checkCancellation = { coroutineContext.ensureActive() },
                        validate = { candidate ->
                            val extractor = MediaExtractor()
                            try {
                                extractor.setDataSource(candidate.absolutePath)
                                require((0 until extractor.trackCount).any { index ->
                                    extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
                                        ?.startsWith("audio/") == true
                                }) { "No audio track" }
                            } finally {
                                extractor.release()
                            }
                            require(probeAudioDurationMs(candidate) > 0) { "Audio cannot be played" }
                        }
                    )
                imported = file
                memoFromFile(file)
            }
        } catch (error: Exception) {
            imported?.delete()
            throw error
        }
    }

    /** Delete a single memo. Stops playback of that file if it is currently playing. */
    suspend fun deleteMemo(memo: VoiceMemo): Boolean {
        if (playingFile == memo.file) stopPlayback()
        return withContext(Dispatchers.IO) {
            deleteMemoFile(memo.file)
        }
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
            var deletedAt = System.currentTimeMillis()
            var target = File(dir, "$deletedAt$TRASH_NAME_SEPARATOR${memo.file.name}")
            while (target.exists()) {
                deletedAt++
                target = File(dir, "$deletedAt$TRASH_NAME_SEPARATOR${memo.file.name}")
            }
            if (memo.file.renameTo(target)) trashedMemoFromFile(target, projectId) else null
        }
    }

    /** All trashed recordings across every project, newest deletion first. */
    suspend fun trashedMemos(): List<TrashedVoiceMemo> = withContext(Dispatchers.IO) {
        val root = RecordingFiles.trashRoot(context.filesDir)
        if (!root.exists()) return@withContext emptyList()
        root.listFiles()
            ?.filter { it.isDirectory }
            ?.flatMap { dir ->
                dir.listFiles()
                    ?.filter { RecordingFiles.isMemoFile(it) }
                    ?.mapNotNull { file -> trashedMemoFromFile(file, dir.name) }
                    ?: emptyList()
            }
            ?.sortedByDescending { it.deletedAt }
            ?: emptyList()
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
        val target = RecordingFiles.resolveCollision(dir, original.nameWithoutExtension, original.extension)
        trashed.file.renameTo(target).also { cleanUpEmptyTrashDir(trashed.file.parentFile) }
    }

    /** Permanently delete a trashed recording. */
    suspend fun permanentlyDeleteTrashedMemo(trashed: TrashedVoiceMemo): Boolean {
        if (playingFile == trashed.file) stopPlayback()
        return withContext(Dispatchers.IO) {
            deleteMemoFile(trashed.file).also { cleanUpEmptyTrashDir(trashed.file.parentFile) }
        }
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
            val targetFile = RecordingFiles.resolveCollision(dir, sanitized, memo.file.extension)

            if (memo.file.renameTo(targetFile)) {
                memoFromFile(targetFile)
            } else {
                null
            }
        }
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
            val liveRemoved = !dir.exists() || dir.deleteRecursively()
            val trashRemoved = !trash.exists() || trash.deleteRecursively()
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
        val separatorIndex = file.name.indexOf(TRASH_NAME_SEPARATOR)
        if (separatorIndex <= 0) return null
        val deletedAt = file.name.substring(0, separatorIndex).toLongOrNull() ?: return null
        val originalName = file.name.substring(separatorIndex + TRASH_NAME_SEPARATOR.length)
        if (originalName.isEmpty()) return null
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
