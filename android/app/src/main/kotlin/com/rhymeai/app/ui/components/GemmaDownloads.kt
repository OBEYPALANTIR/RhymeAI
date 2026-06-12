package com.rhymeai.app.ui.components

import com.rhymeai.app.service.isGgufFile
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

internal const val DOWNLOAD_BUFFER_BYTES = 8 * 1024 * 1024
private const val MIN_FREE_SPACE_AFTER_DOWNLOAD_BYTES = 750L * 1024L * 1024L

internal data class GemmaDownload(
    val label: String,
    val description: String,
    val fileName: String,
    val url: String,
    val expectedBytes: Long
)

internal val GEMMA_DOWNLOADS = listOf(
    GemmaDownload(
        label = "Gemma 4 E2B",
        description = "Best default for phones, 3.18 GB.",
        fileName = "gemma-4-E2B-it-UD-Q4_K_XL.gguf",
        url = "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-UD-Q4_K_XL.gguf?download=true",
        expectedBytes = 3_184_494_720L
    ),
    GemmaDownload(
        label = "Gemma 4 E4B",
        description = "Higher quality, slower, 5.13 GB.",
        fileName = "gemma-4-E4B-it-UD-Q4_K_XL.gguf",
        url = "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-UD-Q4_K_XL.gguf?download=true",
        expectedBytes = 5_126_304_928L
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
