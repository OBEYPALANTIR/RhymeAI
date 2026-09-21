package com.rhymeai.app.service

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.util.Locale

/** Stages imports outside the live audio list until validation has succeeded. */
internal object RecordingImportStore {
    const val MAX_IMPORT_BYTES = 100L * 1024 * 1024

    fun copy(
        input: InputStream,
        directory: File,
        displayName: String,
        checkCancellation: () -> Unit,
        validate: (File) -> Unit
    ): File {
        val extension = displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        require(extension in VoiceMemoService.SUPPORTED_AUDIO_EXTENSIONS) { "Unsupported audio format" }
        val basename = VoiceMemoService.sanitizeBasename(displayName.substringBeforeLast('.'))
            .take(120).ifBlank { "Imported recording" }
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create recording folder")
        val staged = File.createTempFile("import-", ".pending", directory)
        try {
            staged.outputStream().use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var bytesCopied = 0L
                while (true) {
                    checkCancellation()
                    val count = input.read(buffer)
                    if (count < 0) break
                    bytesCopied += count
                    require(bytesCopied <= MAX_IMPORT_BYTES) { "Recording exceeds 100 MiB" }
                    output.write(buffer, 0, count)
                }
            }
            require(staged.length() > 0) { "Empty audio file" }
            validate(staged)
            checkCancellation()
            val destination = VoiceMemoService.resolveCollision(directory, basename, extension)
            // No REPLACE_EXISTING: a concurrent import must never overwrite another take.
            Files.move(staged.toPath(), destination.toPath())
            return destination
        } finally {
            staged.delete()
        }
    }
}
