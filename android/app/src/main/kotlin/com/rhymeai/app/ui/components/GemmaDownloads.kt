package com.rhymeai.app.ui.components

import com.rhymeai.app.service.isGgufFile
import com.rhymeai.app.service.GGUFPromptFormat
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.atomic.AtomicLongArray
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal const val DOWNLOAD_BUFFER_BYTES = 8 * 1024 * 1024
internal const val GEMMA_HUGGING_FACE_REVISION = "27492c6696f2f868bbbe3aeafb633009ef932598"
internal const val GEMMA4_CHAT_TEMPLATE_SHA256 = "33204f1acb5bd0002713e16a593847f24ceeafe711ed88bda2a352dc996a3373"
internal const val GEMMA_DOWNLOAD_CONNECTIONS = 4
internal const val MIN_FREE_SPACE_AFTER_DOWNLOAD_BYTES = 750L * 1024L * 1024L
private const val DOWNLOAD_PROGRESS_UPDATE_BYTES = 32L * 1024L * 1024L
private const val DOWNLOAD_PROGRESS_UPDATE_NANOS = 250_000_000L
private const val DOWNLOAD_STATE_MAGIC = 0x52484D44
private const val DOWNLOAD_STATE_VERSION = 1

// E4B needs roughly 7 GB of RAM headroom to run without thrashing. On a real 8 GB device
// the kernel and OS reserve ~1–2 GB, leaving ~6 GB usable, which causes heavy swap pressure
// under sustained generation. 10 GB total gives a safe margin for E4B; below that, steer
// users toward E2B which fits comfortably on phones with 4–6 GB total RAM.
internal const val RAM_THRESHOLD_E4B_BYTES = 10L * 1024L * 1024L * 1024L  // 10 GB

/** Returns the model index in [GEMMA_DOWNLOADS] that best fits the device's total RAM. */
internal fun recommendedGemmaModel(totalRamBytes: Long): GemmaDownload {
    return if (totalRamBytes >= RAM_THRESHOLD_E4B_BYTES) {
        GEMMA_DOWNLOADS[1] // E4B
    } else {
        GEMMA_DOWNLOADS[0] // E2B — safe on 4–8 GB phones
    }
}

internal data class GemmaDownload(
    val label: String,
    val description: String,
    val fileName: String,
    val url: String,
    val expectedBytes: Long,
    val sha256: String,
    val architecture: String = "gemma4",
    val promptFormat: GGUFPromptFormat = GGUFPromptFormat.GEMMA4,
    val chatTemplateSha256: String = GEMMA4_CHAT_TEMPLATE_SHA256
)

// RhymeAI's own fine-tunes of Gemma 4 (LoRA-trained on the app's exact prompt
// format; see finetune/SCORECARD.md). Hosted on the project's HF repo.
internal val GEMMA_DOWNLOADS = listOf(
    GemmaDownload(
        label = "RhymeAI Gemma E2B",
        description = "Tuned for RhymeAI — best default for phones, 3.43 GB.",
        fileName = "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf",
        url = "https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/$GEMMA_HUGGING_FACE_REVISION/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf?download=true",
        expectedBytes = 3_427_878_784L,
        sha256 = "059e73281d764ba0d541470aabdbd89de84878263b67d50c6c3afbc292933626"
    ),
    GemmaDownload(
        label = "RhymeAI Gemma E4B",
        description = "Tuned for RhymeAI — higher quality, slower, 5.34 GB.",
        fileName = "gemma-4-E4B-it-rhymeai-Q4_K_M.gguf",
        url = "https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/$GEMMA_HUGGING_FACE_REVISION/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf?download=true",
        expectedBytes = 5_335_290_784L,
        sha256 = "e39b2475a5c8d86d1b376babe16ffce32993c96ab650b6fed7c4e14f5d0d11a3"
    )
)

internal fun formatDownloadProgress(progress: Float?): String {
    if (progress == null || progress <= 0f) return "downloading..."
    return "${String.format(Locale.US, "%.0f", progress * 100f)}%"
}

internal fun validateDownloadedGemma(model: GemmaDownload, file: File): String? {
    if (!file.exists()) return "${model.label} is not downloaded yet"
    if (file.length() < model.expectedBytes) {
        return "${model.label} download is incomplete: ${formatFileSize(file.length())} of ${formatFileSize(model.expectedBytes)}"
    }
    if (file.length() > model.expectedBytes) {
        return "${model.label} download has an unexpected size: ${formatFileSize(file.length())} instead of ${formatFileSize(model.expectedBytes)}"
    }
    if (!file.isGgufFile()) return "${model.label} download did not produce a GGUF file"
    return null
}

internal fun validateDownloadedGemmaIntegrity(model: GemmaDownload, file: File): String? {
    validateDownloadedGemma(model, file)?.let { return it }

    val digest = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
        while (true) {
            val read = input.read(buffer)
            if (read == -1) break
            digest.update(buffer, 0, read)
        }
    }
    val actualSha256 = digest.digest().joinToString("") {
        String.format(Locale.US, "%02x", it.toInt() and 0xff)
    }
    if (!actualSha256.equals(model.sha256, ignoreCase = true)) {
        return "${model.label} download failed its integrity check"
    }
    return null
}

internal data class GemmaDownloadSegment(
    val start: Long,
    val endInclusive: Long
) {
    val length: Long
        get() = endInclusive - start + 1
}

internal fun gemmaDownloadSegments(
    expectedBytes: Long,
    connectionCount: Int = GEMMA_DOWNLOAD_CONNECTIONS
): List<GemmaDownloadSegment> {
    require(expectedBytes > 0L)
    val count = minOf(connectionCount.coerceAtLeast(1).toLong(), expectedBytes).toInt()
    val segmentBytes = (expectedBytes + count - 1L) / count
    return List(count) { index ->
        val start = index * segmentBytes
        GemmaDownloadSegment(
            start = start,
            endInclusive = minOf(expectedBytes - 1L, start + segmentBytes - 1L)
        )
    }
}

internal fun gemmaDownloadStateFile(tempFile: File): File =
    File(tempFile.parentFile, "${tempFile.name}.segments")

internal fun hasGemmaDownloadState(tempFile: File): Boolean =
    gemmaDownloadStateFile(tempFile).isFile

internal suspend fun downloadGemmaToTemp(
    model: GemmaDownload,
    tempFile: File,
    onProgress: suspend (Float) -> Unit,
    onVerifying: suspend () -> Unit = {},
    connectionCount: Int = GEMMA_DOWNLOAD_CONNECTIONS
) = coroutineScope {
    val segments = gemmaDownloadSegments(model.expectedBytes, connectionCount)
    val stateFile = gemmaDownloadStateFile(tempFile)
    tempFile.parentFile?.mkdirs()
    val downloadedBytes = loadDownloadState(stateFile, segments)
        ?: legacyDownloadState(tempFile, segments)

    RandomAccessFile(tempFile, "rw").use { output ->
        output.setLength(model.expectedBytes)
    }

    val reporter = GemmaProgressReporter(
        model = model,
        stateFile = stateFile,
        segments = segments,
        initialBytes = downloadedBytes,
        onProgress = onProgress
    )
    reporter.checkpoint(force = true)

    try {
        segments.mapIndexed { index, segment ->
            async {
                downloadGemmaSegment(
                    model = model,
                    tempFile = tempFile,
                    segment = segment,
                    segmentIndex = index,
                    resumeBytes = downloadedBytes[index],
                    reporter = reporter
                )
            }
        }.awaitAll()
        reporter.checkpoint(force = true)
    } catch (error: Exception) {
        reporter.checkpoint(force = true)
        throw error
    }

    onVerifying()
    validateDownloadedGemmaIntegrity(model, tempFile)?.let { validationError ->
        tempFile.delete()
        stateFile.delete()
        throw IllegalStateException(validationError)
    }
    stateFile.delete()
}

internal suspend fun downloadGemmaAndInstall(
    model: GemmaDownload,
    tempFile: File,
    destinationFile: File,
    onProgress: suspend (Float) -> Unit,
    onVerifying: suspend () -> Unit = {},
    connectionCount: Int = GEMMA_DOWNLOAD_CONNECTIONS
) {
    if (hasGemmaDownloadState(tempFile) ||
        validateDownloadedGemmaIntegrity(model, tempFile) != null
    ) {
        downloadGemmaToTemp(
            model = model,
            tempFile = tempFile,
            onProgress = onProgress,
            onVerifying = onVerifying,
            connectionCount = connectionCount
        )
    }
    validateDownloadedGemmaIntegrity(model, tempFile)?.let { validationError ->
        throw IllegalStateException(validationError)
    }
    Files.move(
        tempFile.toPath(),
        destinationFile.toPath(),
        StandardCopyOption.REPLACE_EXISTING,
        StandardCopyOption.ATOMIC_MOVE
    )
}

private suspend fun downloadGemmaSegment(
    model: GemmaDownload,
    tempFile: File,
    segment: GemmaDownloadSegment,
    segmentIndex: Int,
    resumeBytes: Long,
    reporter: GemmaProgressReporter
) {
    if (resumeBytes >= segment.length) return
    val rangeStart = segment.start + resumeBytes
    val connection = openGemmaConnection(model, rangeStart, segment.endInclusive)
    try {
        val code = connection.responseCode
        if (code !in 200..299) {
            throw IllegalStateException("Hugging Face returned HTTP $code")
        }
        if (code != HttpURLConnection.HTTP_PARTIAL) {
            throw IllegalStateException(
                "Hugging Face did not honor a ranged download request (HTTP $code)"
            )
        }
        val contentRange = connection.getHeaderField("Content-Range").orEmpty()
        if (!contentRange.startsWith("bytes $rangeStart-")) {
            throw IllegalStateException("Hugging Face returned an unexpected byte range")
        }

        var copiedBytes = resumeBytes
        RandomAccessFile(tempFile, "rw").use { output ->
            output.seek(rangeStart)
            connection.inputStream.use { input ->
                val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                while (copiedBytes < segment.length) {
                    val remaining = minOf(buffer.size.toLong(), segment.length - copiedBytes).toInt()
                    val read = input.read(buffer, 0, remaining)
                    if (read == -1) break
                    output.write(buffer, 0, read)
                    copiedBytes += read
                    reporter.update(segmentIndex, copiedBytes)
                }
            }
        }
        if (copiedBytes != segment.length) {
            throw IllegalStateException(
                "${model.label} range was incomplete: $copiedBytes of ${segment.length} bytes"
            )
        }
    } finally {
        connection.disconnect()
    }
}

private fun openGemmaConnection(
    model: GemmaDownload,
    rangeStart: Long,
    rangeEndInclusive: Long
): HttpURLConnection =
    (URL(model.url).openConnection() as HttpURLConnection).apply {
        connectTimeout = 30_000
        readTimeout = 60_000
        instanceFollowRedirects = true
        setRequestProperty("User-Agent", "RhymeAI-Android")
        setRequestProperty("Accept-Encoding", "identity")
        setRequestProperty("Range", "bytes=$rangeStart-$rangeEndInclusive")
    }

private fun legacyDownloadState(
    tempFile: File,
    segments: List<GemmaDownloadSegment>
): LongArray {
    val legacyBytes = tempFile.length()
        .takeIf { it in 1 until segments.sumOf(GemmaDownloadSegment::length) }
        ?: 0L
    return LongArray(segments.size) { index ->
        val segment = segments[index]
        (legacyBytes - segment.start).coerceIn(0L, segment.length)
    }
}

private fun loadDownloadState(
    stateFile: File,
    segments: List<GemmaDownloadSegment>
): LongArray? = runCatching {
    DataInputStream(stateFile.inputStream().buffered()).use { input ->
        if (input.readInt() != DOWNLOAD_STATE_MAGIC) return null
        if (input.readInt() != DOWNLOAD_STATE_VERSION) return null
        if (input.readInt() != segments.size) return null
        LongArray(segments.size) { index ->
            input.readLong().coerceIn(0L, segments[index].length)
        }
    }
}.getOrNull()

private fun saveDownloadState(stateFile: File, downloadedBytes: LongArray) {
    val stagingFile = File(stateFile.parentFile, "${stateFile.name}.tmp")
    DataOutputStream(FileOutputStream(stagingFile).buffered()).use { output ->
        output.writeInt(DOWNLOAD_STATE_MAGIC)
        output.writeInt(DOWNLOAD_STATE_VERSION)
        output.writeInt(downloadedBytes.size)
        downloadedBytes.forEach(output::writeLong)
    }
    if (!stagingFile.renameTo(stateFile)) {
        stagingFile.copyTo(stateFile, overwrite = true)
        stagingFile.delete()
    }
}

private class GemmaProgressReporter(
    private val model: GemmaDownload,
    private val stateFile: File,
    segments: List<GemmaDownloadSegment>,
    initialBytes: LongArray,
    private val onProgress: suspend (Float) -> Unit
) {
    private val downloaded = AtomicLongArray(initialBytes)
    private val segmentLengths = segments.map(GemmaDownloadSegment::length).toLongArray()
    private val checkpointMutex = Mutex()
    private var lastCheckpointBytes = -1L
    private var lastCheckpointNanos = 0L

    suspend fun update(segmentIndex: Int, bytes: Long) {
        downloaded.set(segmentIndex, bytes.coerceIn(0L, segmentLengths[segmentIndex]))
        checkpoint(force = false)
    }

    suspend fun checkpoint(force: Boolean) {
        val now = System.nanoTime()
        val currentTotal = totalBytes()
        if (!force &&
            currentTotal - lastCheckpointBytes < DOWNLOAD_PROGRESS_UPDATE_BYTES &&
            now - lastCheckpointNanos < DOWNLOAD_PROGRESS_UPDATE_NANOS
        ) {
            return
        }

        checkpointMutex.withLock {
            val lockedNow = System.nanoTime()
            val lockedTotal = totalBytes()
            if (!force &&
                lockedTotal - lastCheckpointBytes < DOWNLOAD_PROGRESS_UPDATE_BYTES &&
                lockedNow - lastCheckpointNanos < DOWNLOAD_PROGRESS_UPDATE_NANOS
            ) {
                return
            }
            val snapshot = LongArray(downloaded.length()) { downloaded.get(it) }
            saveDownloadState(stateFile, snapshot)
            lastCheckpointBytes = lockedTotal
            lastCheckpointNanos = lockedNow
            onProgress(
                (lockedTotal.toFloat() / model.expectedBytes.toFloat()).coerceIn(0f, 1f)
            )
        }
    }

    private fun totalBytes(): Long =
        (0 until downloaded.length()).sumOf(downloaded::get)
}

internal fun ensureEnoughSpaceForGemma(model: GemmaDownload, destFile: File, tempFile: File) {
    val segments = gemmaDownloadSegments(model.expectedBytes)
    val stateFile = gemmaDownloadStateFile(tempFile)
    val downloadedTempBytes = if (stateFile.isFile) {
        loadDownloadState(stateFile, segments)?.sum() ?: 0L
    } else {
        tempFile.length().coerceAtMost(model.expectedBytes)
    }
    val reclaimableBytes = destFile.length() + downloadedTempBytes
    val availableBytes = (tempFile.parentFile ?: tempFile).usableSpace + reclaimableBytes
    val requiredBytes = model.expectedBytes + MIN_FREE_SPACE_AFTER_DOWNLOAD_BYTES
    if (availableBytes < requiredBytes) {
        throw IllegalStateException(
            "Need ${formatFileSize(requiredBytes)} free for ${model.label}; only ${formatFileSize(availableBytes)} available."
        )
    }
}

internal fun formatFileSize(bytes: Long): String {
    return "${String.format(Locale.US, "%.2f", bytes / 1_000_000_000.0)} GB"
}
