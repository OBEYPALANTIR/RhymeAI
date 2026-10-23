package com.rhymeai.app.data.recording

import com.rhymeai.app.data.sync.SyncIdentity
import java.io.File
import java.util.Locale

/** Shared local recording paths and filename policy for media, imports, and sync. */
internal object RecordingFiles {
    private const val MEMOS_ROOT_DIR = "voice-memos"
    private const val MEMOS_TRASH_ROOT_DIR = "voice-memos-trash"
    val SUPPORTED_AUDIO_EXTENSIONS = setOf("m4a", "mp3", "wav", "aac")

    private const val MEMOS_STAGING_ROOT_DIR = "voice-memos-staging"

    fun isMemoFile(file: File): Boolean =
        file.isFile && file.extension.lowercase(Locale.ROOT) in SUPPORTED_AUDIO_EXTENSIONS

    fun memosRoot(filesDir: File): File =
        File(filesDir, MEMOS_ROOT_DIR)

    fun trashRoot(filesDir: File): File =
        File(filesDir, MEMOS_TRASH_ROOT_DIR)

    /** Unfinished recordings and pending imports; never listed or backed up (A22). */
    fun stagingRoot(filesDir: File): File =
        File(filesDir, MEMOS_STAGING_ROOT_DIR)

    fun stagingDirectory(filesDir: File, projectId: String): File =
        safeProjectDirectory(stagingRoot(filesDir), projectId)

    fun memoDirectory(filesDir: File, projectId: String): File =
        safeProjectDirectory(memosRoot(filesDir), projectId)

    fun trashDirectory(filesDir: File, projectId: String): File =
        safeProjectDirectory(trashRoot(filesDir), projectId)

    fun memoFile(filesDir: File, projectId: String, fileName: String): File {
        SyncIdentity.validateFileName(fileName)
        return requireDescendant(memosRoot(filesDir), File(memoDirectory(filesDir, projectId), fileName))
    }

    private fun safeProjectDirectory(root: File, projectId: String): File {
        SyncIdentity.validateProjectId(projectId)
        return requireDescendant(root, File(root, projectId))
    }

    private fun requireDescendant(root: File, candidate: File): File {
        val canonicalRoot = root.canonicalFile.toPath()
        val canonicalCandidate = candidate.canonicalFile.toPath()
        require(canonicalCandidate != canonicalRoot && canonicalCandidate.startsWith(canonicalRoot)) {
            "Recording path is outside its storage root"
        }
        return canonicalCandidate.toFile()
    }

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
        // on both platforms.
        return truncateUtf8(cleaned, 200).trim()
    }

    /** The longest prefix of [value] within [maxBytes] UTF-8 bytes, never splitting a code point. */
    private fun truncateUtf8(value: String, maxBytes: Int): String {
        val bounded = StringBuilder()
        var byteCount = 0
        val points = value.codePoints().iterator()
        while (points.hasNext()) {
            val character = String(Character.toChars(points.nextInt()))
            val bytes = character.toByteArray(Charsets.UTF_8).size
            if (byteCount + bytes > maxBytes) break
            bounded.append(character)
            byteCount += bytes
        }
        return bounded.toString()
    }

    /**
     * Find a free filename for [base] with [extension] inside [dir]. If that name already
     * exists (and is not the source file being renamed), append " 2", " 3", … until
     * a free slot is found. The base is shortened so a variant stays within the
     * recording filename limit.
     */
    fun resolveCollision(dir: File, base: String, extension: String = "m4a"): File {
        var candidate = File(dir, "$base.$extension")
        var suffix = 2
        while (candidate.exists()) {
            val tail = " $suffix.$extension"
            val room = SyncIdentity.MAX_RECORDING_FILE_NAME_BYTES - tail.toByteArray(Charsets.UTF_8).size
            candidate = File(dir, truncateUtf8(base, room).trimEnd() + tail)
            suffix++
        }
        return candidate
    }
}
