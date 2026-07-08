package com.rhymeai.app.ui.components

import com.rhymeai.app.service.isGgufFile
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

internal const val DOWNLOAD_BUFFER_BYTES = 8 * 1024 * 1024
private const val MIN_FREE_SPACE_AFTER_DOWNLOAD_BYTES = 750L * 1024L * 1024L

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
    val expectedBytes: Long
)

// RhymeAI's own fine-tunes of Gemma 4 (LoRA-trained on the app's exact prompt
// format; see finetune/SCORECARD.md). Hosted on the project's HF repo.
internal val GEMMA_DOWNLOADS = listOf(
    GemmaDownload(
        label = "RhymeAI Gemma E2B",
        description = "Tuned for RhymeAI — best default for phones, 3.43 GB.",
        fileName = "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf",
        url = "https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/main/gemma-4-E2B-it-rhymeai-Q4_K_M.gguf?download=true",
        expectedBytes = 3_427_878_784L
    ),
    GemmaDownload(
        label = "RhymeAI Gemma E4B",
        description = "Tuned for RhymeAI — higher quality, slower, 5.34 GB.",
        fileName = "gemma-4-E4B-it-rhymeai-Q4_K_M.gguf",
        url = "https://huggingface.co/Shayde182/rhymeai-gemma-4-gguf/resolve/main/gemma-4-E4B-it-rhymeai-Q4_K_M.gguf?download=true",
        expectedBytes = 5_335_290_784L
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
    if (!file.isGgufFile()) return "${model.label} download did not produce a GGUF file"
    return null
}

internal suspend fun downloadGemmaToTemp(
    model: GemmaDownload,
    tempFile: File,
    onProgress: suspend (Float) -> Unit
) {
    val resumeBytes = tempFile.length().takeIf { it > 0L && it < model.expectedBytes } ?: 0L
    val connection = openGemmaConnection(model, resumeBytes)
    try {
        val code = connection.responseCode
        if (code !in 200..299) {
            throw IllegalStateException("Hugging Face returned HTTP $code")
        }

        val append = resumeBytes > 0L && code == HttpURLConnection.HTTP_PARTIAL
        var copiedBytes = if (append) resumeBytes else 0L
        if (resumeBytes > 0L && !append) tempFile.delete()
        onProgress((copiedBytes.toFloat() / model.expectedBytes.toFloat()).coerceIn(0f, 1f))

        connection.inputStream.use { input ->
            FileOutputStream(tempFile, append).buffered().use { output ->
                val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                while (true) {
                    val read = input.read(buffer)
                    if (read == -1) break
                    output.write(buffer, 0, read)
                    copiedBytes += read
                    onProgress((copiedBytes.toFloat() / model.expectedBytes.toFloat()).coerceIn(0f, 1f))
                }
            }
        }
    } finally {
        connection.disconnect()
    }
}

private fun openGemmaConnection(model: GemmaDownload, resumeBytes: Long): HttpURLConnection =
    (URL(model.url).openConnection() as HttpURLConnection).apply {
        connectTimeout = 30_000
        readTimeout = 60_000
        instanceFollowRedirects = true
        setRequestProperty("User-Agent", "RhymeAI-Android")
        if (resumeBytes > 0L) {
            setRequestProperty("Range", "bytes=$resumeBytes-")
        }
    }

internal fun ensureEnoughSpaceForGemma(model: GemmaDownload, destFile: File, tempFile: File) {
    val reclaimableBytes = listOf(destFile, tempFile)
        .filter { it.exists() }
        .sumOf { it.length() }
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
