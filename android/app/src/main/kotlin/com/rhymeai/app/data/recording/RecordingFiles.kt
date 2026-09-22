package com.rhymeai.app.data.recording

import java.io.File
import java.util.Locale

/** Shared local recording paths and filename policy for media, imports, and sync. */
internal object RecordingFiles {
    private const val MEMOS_ROOT_DIR = "voice-memos"
    private const val MEMOS_TRASH_ROOT_DIR = "voice-memos-trash"
    val SUPPORTED_AUDIO_EXTENSIONS = setOf("m4a", "mp3", "wav", "aac")

    fun isMemoFile(file: File): Boolean =
        file.isFile && file.extension.lowercase(Locale.ROOT) in SUPPORTED_AUDIO_EXTENSIONS

    fun memosRoot(filesDir: File): File =
        File(filesDir, MEMOS_ROOT_DIR)

    fun trashRoot(filesDir: File): File =
        File(filesDir, MEMOS_TRASH_ROOT_DIR)

    fun memoDirectory(filesDir: File, projectId: String): File =
        File(memosRoot(filesDir), projectId)

    fun trashDirectory(filesDir: File, projectId: String): File =
        File(trashRoot(filesDir), projectId)

    /**
     * Strip characters that are illegal in file paths on Android (FAT32 + ext4),
     * collapse whitespace, and trim. Returns an empty string if nothing remains
     * after sanitization — the caller must reject empty results.
     */
    fun sanitizeBasename(raw: String): String {
        val cleaned = raw
            .replace(Regex("""[/\\:*?"<>|]"""), "")
            .replace(Regex("""\s+"""), " ")
            .replace(Regex("""[\p{Cc}\p{Cf}]"""), "")
            .trim()
        // Leave room for the audio extension, duplicate suffix and trash timestamp
        // on both platforms. Count UTF-8 bytes without splitting a code point.
        val bounded = StringBuilder()
        var byteCount = 0
        val points = cleaned.codePoints().iterator()
        while (points.hasNext()) {
            val point = points.nextInt()
            val character = String(Character.toChars(point))
            val bytes = character.toByteArray(Charsets.UTF_8).size
            if (byteCount + bytes > 200) break
            bounded.append(character)
            byteCount += bytes
        }
        return bounded.toString().trim()
    }

    /**
     * Find a free filename for [base] with [extension] inside [dir]. If that name already
     * exists (and is not the source file being renamed), append " 2", " 3", … until
     * a free slot is found.
     */
    fun resolveCollision(dir: File, base: String, extension: String = "m4a"): File {
        var candidate = File(dir, "$base.$extension")
        var suffix = 2
        while (candidate.exists()) {
            candidate = File(dir, "$base $suffix.$extension")
            suffix++
        }
        return candidate
    }
}
