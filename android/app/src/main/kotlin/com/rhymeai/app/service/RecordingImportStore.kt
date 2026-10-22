package com.rhymeai.app.service

import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.recording.RecordingTransitions
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.util.Locale

/** Stages imports outside the live audio list until validation has succeeded. */
internal object RecordingImportStore {
    const val MAX_IMPORT_BYTES = 100L * 1024 * 1024

    class Staged(val file: File, val desiredName: String)

    /**
     * Copies and validates the audio into a `.pending` file in [directory] (outside the
     * published list). The caller publishes it with its record, or deletes it.
     */
    fun stage(
        input: InputStream,
        directory: File,
        displayName: String,
        checkCancellation: () -> Unit,
        validate: (File) -> Unit
    ): Staged {
        var staged: File? = null
        try {
            val (candidate, basename, extension) = input.use { source ->
                val extension = displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
                require(extension in RecordingFiles.SUPPORTED_AUDIO_EXTENSIONS) { "Unsupported audio format" }
                val basename = RecordingFiles.sanitizeBasename(displayName.substringBeforeLast('.'))
                    .takeUnless { it.startsWith(".") }.orEmpty().ifBlank { "Imported recording" }
                if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create recording folder")
                val temporary = File.createTempFile("import-", ".pending", directory)
                staged = temporary
                temporary.outputStream().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var bytesCopied = 0L
                    while (true) {
                        checkCancellation()
                        val count = source.read(buffer)
                        if (count < 0) break
                        bytesCopied += count
                        require(bytesCopied <= MAX_IMPORT_BYTES) { "Recording exceeds 100 MiB" }
                        output.write(buffer, 0, count)
                    }
                }
                Triple(temporary, basename, extension)
            }
            // A provider close failure is still an import failure, before publication.
            require(candidate.length() > 0) { "Empty audio file" }
            validate(candidate)
            checkCancellation()
            staged = null
            return Staged(candidate, "$basename.$extension")
        } finally {
            staged?.delete()
        }
    }

    /** Stages into [directory] and publishes there under a free name, without a record. */
    fun copy(
        input: InputStream,
        directory: File,
        displayName: String,
        checkCancellation: () -> Unit,
        validate: (File) -> Unit
    ): File {
        val staged = stage(input, directory, displayName, checkCancellation, validate)
        try {
            // No REPLACE_EXISTING: a concurrent import must never overwrite another take.
            return runBlocking {
                RecordingTransitions.namespace.withLock {
                    val base = staged.desiredName.substringBeforeLast('.')
                    RecordingFiles.resolveCollision(directory, base, staged.desiredName.substringAfterLast('.')).also {
                        Files.move(staged.file.toPath(), it.toPath())
                    }
                }
            }
        } finally {
            staged.file.delete()
        }
    }
}
