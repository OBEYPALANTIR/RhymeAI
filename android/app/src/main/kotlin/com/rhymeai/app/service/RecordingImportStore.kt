package com.rhymeai.app.service

import com.rhymeai.app.data.recording.RecordingFiles
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.Locale

/** Stages imports outside the live audio list until validation has succeeded. */
internal object RecordingImportStore {
    const val MAX_IMPORT_BYTES = 100L * 1024 * 1024

    class Staged(val file: File, val desiredName: String)

    /**
     * The ownership marker of a staged import (`<file>.import`, holding its id), written before
     * the first byte is copied and removed with the staged file. A launch check that finds a
     * staged file with this marker and no import in progress sets it aside, kept.
     */
    fun markerFor(staged: File) = File(staged.parentFile, staged.name + ".import")

    /**
     * Copies and validates the audio into `<id>.<ext>` in [directory] (staging, outside the
     * published list). The caller publishes it with its record, or deletes it.
     */
    fun stage(
        input: InputStream,
        directory: File,
        id: String,
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
                // A36: named by the recording's id from the start, never by its display name.
                val temporary = File(directory, RecordingFiles.idFileName(id, "x.$extension"))
                if (!temporary.createNewFile()) throw IOException("Cannot stage the recording")
                staged = temporary
                markerFor(temporary).writeText("$id\n")
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
            staged?.let { it.delete(); markerFor(it).delete() }
        }
    }
}
