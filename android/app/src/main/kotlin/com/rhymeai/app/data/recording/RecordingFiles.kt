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
    private const val MEMOS_QUARANTINE_ROOT_DIR = "voice-memos-quarantine"
    private const val MEMOS_JOURNAL_ROOT_DIR = "voice-memos-journal"
    private const val MEMOS_PARKING_ROOT_DIR = "voice-memos-parking"
    private const val RESTORE_STAGE_PREFIX = ".recording-restore-"

    fun isMemoFile(file: File): Boolean =
        file.isFile && file.extension.lowercase(Locale.ROOT) in SUPPORTED_AUDIO_EXTENSIONS

    /**
     * The file at [path] (relative to the files folder, as records store it). Every
     * recording [File] is built on the canonical files folder, so files from listings,
     * records and playback compare equal even where the files folder is reached through
     * a symlink (Android's /data/user/0 → /data/data).
     */
    fun fileAt(filesDir: File, path: String): File = File(filesDir.canonicalFile, path)

    fun memosRoot(filesDir: File): File =
        File(filesDir.canonicalFile, MEMOS_ROOT_DIR)

    fun trashRoot(filesDir: File): File =
        File(filesDir.canonicalFile, MEMOS_TRASH_ROOT_DIR)

    /** Unfinished recordings and pending imports; never listed or backed up (A22). */
    fun stagingRoot(filesDir: File): File =
        File(filesDir.canonicalFile, MEMOS_STAGING_ROOT_DIR)

    fun stagingDirectory(filesDir: File, projectId: String): File =
        safeProjectDirectory(stagingRoot(filesDir), projectId)

    /**
     * Bytes kept for recovery only (A26/A28): duplicate copies of a pre-v4 recording and
     * recordings whose deletion won a merge. Never listed, adopted, backed up or deleted.
     */
    fun quarantineRoot(filesDir: File): File =
        File(filesDir.canonicalFile, MEMOS_QUARANTINE_ROOT_DIR)

    fun quarantineDirectory(filesDir: File, projectId: String): File =
        safeProjectDirectory(quarantineRoot(filesDir), projectId)

    /** Journals of moves that have no recording record (quarantine, staging, historical recovery). */
    fun journalRoot(filesDir: File): File =
        File(filesDir.canonicalFile, MEMOS_JOURNAL_ROOT_DIR)

    /** Where builds before A36 parked a recording while names swapped (`<projectId>/<id>.<ext>`); recovered at launch. */
    fun parkingRoot(filesDir: File): File =
        File(filesDir.canonicalFile, MEMOS_PARKING_ROOT_DIR)

    /**
     * [path], relative to the files folder, when it names a file inside one of the recording
     * roots (live, Trash, staging, quarantine, parking) without leaving it; null otherwise.
     */
    fun containedRecordingFile(filesDir: File, path: String): File? {
        if (path.isEmpty() || path.startsWith("/") || path.split('/').any { it == ".." || it.isEmpty() }) return null
        val file = fileAt(filesDir, path)
        val stageRoot = path.substringBefore('/').takeIf { it.startsWith(RESTORE_STAGE_PREFIX) }?.let { File(filesDir.canonicalFile, it) }
        val roots = listOfNotNull(memosRoot(filesDir), trashRoot(filesDir), stagingRoot(filesDir), quarantineRoot(filesDir), parkingRoot(filesDir), stageRoot)
        val canonical = runCatching { file.canonicalFile.toPath() }.getOrNull() ?: return null
        return file.takeIf { roots.any { root -> canonical.startsWith(root.canonicalFile.toPath()) && canonical != root.canonicalFile.toPath() } }
    }


    fun memoDirectory(filesDir: File, projectId: String): File =
        safeProjectDirectory(memosRoot(filesDir), projectId)

    fun trashDirectory(filesDir: File, projectId: String): File =
        safeProjectDirectory(trashRoot(filesDir), projectId)

    private val ID_FILE_NAME = Regex("^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\.([a-z0-9]+)$")

    /**
     * A36: every recording file is named by its id. The extension is the audio's own
     * (`m4a` for the app's takes); anything that is not a supported audio extension is m4a.
     */
    fun idFileName(id: String, displayName: String): String {
        SyncIdentity.validateRecordingId(id)
        val extension = displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        return "$id.${extension.takeIf { it in SUPPORTED_AUDIO_EXTENSIONS } ?: "m4a"}"
    }

    /** The recording id a file is named by, or null for any other name (a pre-A36 file). */
    fun idOf(file: File): String? =
        ID_FILE_NAME.matchEntire(file.name)?.takeIf { it.groupValues[2] in SUPPORTED_AUDIO_EXTENSIONS }?.groupValues?.get(1)

    /** A pre-A36 file named [name] in [projectId]'s live folder (historical recovery), never outside it. */
    fun legacyMemoFile(filesDir: File, projectId: String, name: String): File {
        SyncIdentity.validateDisplayName(name)
        require('/' !in name && '\\' !in name && name != "." && name != "..") { "Invalid recording file name" }
        return requireDescendant(memosRoot(filesDir), File(memoDirectory(filesDir, projectId), name))
    }

    /** The live file of recording [id] in [projectId]. */
    fun memoFile(filesDir: File, projectId: String, id: String, displayName: String): File =
        requireDescendant(memosRoot(filesDir), File(memoDirectory(filesDir, projectId), idFileName(id, displayName)))

    /** The Trash file of recording [id] in [projectId]. */
    fun trashFile(filesDir: File, projectId: String, id: String, displayName: String): File =
        requireDescendant(trashRoot(filesDir), File(trashDirectory(filesDir, projectId), idFileName(id, displayName)))

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
}
