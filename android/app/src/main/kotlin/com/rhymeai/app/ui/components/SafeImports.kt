package com.rhymeai.app.ui.components

import com.rhymeai.app.service.MAX_LOCAL_MODEL_BYTES
import com.rhymeai.app.service.isGgufFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.currentCoroutineContext

internal const val MAX_PROJECT_IMPORT_BYTES = 10 * 1024 * 1024

internal fun readProjectText(input: InputStream): String {
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
    var copied = 0
    while (true) {
        val read = input.read(buffer)
        if (read == -1) break
        copied += read
        require(copied <= MAX_PROJECT_IMPORT_BYTES) { "Project files must be 10 MB or smaller." }
        output.write(buffer, 0, read)
    }
    return output.toString(Charsets.UTF_8.name())
}

internal fun maxLocalModelImportBytes(destinationDirectory: File): Long =
    minOf(
        MAX_LOCAL_MODEL_BYTES,
        (destinationDirectory.usableSpace - MIN_FREE_SPACE_AFTER_DOWNLOAD_BYTES).coerceAtLeast(0L)
    )

internal suspend fun copyLocalModelAtomically(
    input: InputStream,
    destination: File,
    maxBytes: Long = maxLocalModelImportBytes(requireNotNull(destination.parentFile))
) {
    require(maxBytes > 0L) { "Not enough free storage to import this model." }
    val directory = requireNotNull(destination.parentFile)
    directory.mkdirs()
    val staging = Files.createTempFile(directory.toPath(), ".model-import-", ".tmp").toFile()
    try {
        staging.outputStream().buffered().use { output ->
            input.buffered().use { source ->
                val buffer = ByteArray(DOWNLOAD_BUFFER_BYTES)
                var copied = 0L
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = source.read(buffer)
                    if (read == -1) break
                    copied += read
                    require(copied <= maxBytes) {
                        "Model file is too large for this device."
                    }
                    output.write(buffer, 0, read)
                }
            }
        }
        require(staging.isGgufFile()) { "Selected file is not a supported GGUF model." }
        Files.move(
            staging.toPath(),
            destination.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE
        )
    } finally {
        staging.delete()
    }
}
