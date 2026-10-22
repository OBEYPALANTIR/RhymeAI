package com.rhymeai.app.data.sync

import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.util.LyricsExporter
import java.io.File
import java.io.OutputStream
import java.time.Instant
import java.time.ZoneId
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

/**
 * "Export all songs…" / "Import from file…": one zip that any storage provider can
 * hold. Layout: `manifest.json` (v4), `songs/<title or id>.txt`, `songs/<id>.json`,
 * `recordings/<projectId>/<fileName>`. Import reads only paths the verified
 * manifest names, so zip entry names never become file paths, and rejects any
 * archive holding an entry outside that layout.
 */
object BackupArchive {
    const val MANIFEST_ENTRY = "manifest.json"
    const val MIME_TYPE = "application/zip"
    private val unsafeFileNameCharacters = Regex("""[\\/:*?"<>|\p{Cntrl}]""")

    class Contents(val manifest: SyncBlob, val recordings: Map<String, ByteArray>, val damagedRecordings: Int)

    data class ExportSummary(val songs: Int, val recordings: Int, val skippedLargeRecordings: Int)

    data class ImportSummary(
        val songs: Int,
        val recordingsAdded: Int,
        val damagedRecordings: Int,
        val skippedLargeRecordings: Int
    )

    /**
     * Every entry must be `manifest.json` or sit under `songs/` or `recordings/`, with no
     * `..` segment, absolute path, drive letter or backslash; anything else rejects the archive.
     */
    internal fun isAllowedEntryName(name: String): Boolean {
        if (name.isEmpty() || name.startsWith("/") || '\\' in name || Regex("^[A-Za-z]:").containsMatchIn(name)) return false
        if (name.split('/').any { it == ".." || it == "." }) return false
        return name == MANIFEST_ENTRY || name.startsWith("songs/") || name.startsWith("recordings/")
    }

    fun fileName(nowMillis: Long, zone: ZoneId = ZoneId.systemDefault()): String =
        "WritersBlock-backup-${Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()}.zip"

    internal fun write(
        output: OutputStream,
        blob: SyncBlob,
        files: List<LocalRecordingFile>,
        savedAtMillis: Long,
        clientId: String
    ): ExportSummary {
        val included = files.filter { it.entry.isTransferable }
        // A recording not yet in a backup carries its file time as its upload time.
        val manifest = blob.copy(
            recordings = included.map { it.entry.let { e -> if (e.uploadedAt > 0L) e else e.copy(uploadedAt = e.modifiedAt) } }
        )
        ZipOutputStream(output).use { zip ->
            zip.putNextEntry(ZipEntry(MANIFEST_ENTRY))
            zip.write(BackupManifest.encode(manifest, savedAtMillis, clientId))
            zip.closeEntry()
            val usedNames = HashSet<String>()
            for (project in blob.projects) {
                val base = project.title.replace(unsafeFileNameCharacters, "_").trim().take(80).ifBlank { project.id }
                val name = generateSequence(1) { it + 1 }
                    .map { if (it == 1) base else "$base ($it)" }
                    .first { usedNames.add(it.lowercase()) }
                zip.putNextEntry(ZipEntry("songs/$name.txt"))
                zip.write(LyricsExporter.buildTxt(project))
                zip.closeEntry()
                zip.putNextEntry(ZipEntry("songs/${project.id}.json"))
                zip.write(LyricsExporter.buildJson(project))
                zip.closeEntry()
            }
            for (recording in included) {
                zip.putNextEntry(ZipEntry("recordings/${recording.entry.projectId}/${recording.entry.fileName}"))
                zip.write(RecordingFileStore.readForUpload(recording.file, recording.entry))
                zip.closeEntry()
            }
        }
        return ExportSummary(blob.projects.size, included.size, files.size - included.size)
    }

    /** Accepts an exported zip or a bare v4 `manifest.json`; throws [DamagedBackupException] otherwise. */
    fun read(file: File): Contents {
        val isZip = file.inputStream().use { input ->
            val magic = ByteArray(2)
            input.read(magic) == 2 && magic[0] == 'P'.code.toByte() && magic[1] == 'K'.code.toByte()
        }
        if (!isZip) {
            if (file.length() > DriveSyncService.MAX_SYNC_BLOB_BYTES) throw DamagedBackupException()
            return Contents(BackupManifest.decode(file.readBytes()), emptyMap(), 0)
        }
        return try {
            ZipFile(file).use { zip ->
                zip.entries().asSequence().forEach { if (!isAllowedEntryName(it.name)) throw DamagedBackupException() }
                val manifestEntry = zip.getEntry(MANIFEST_ENTRY) ?: throw DamagedBackupException()
                val manifest = BackupManifest.decode(
                    zip.getInputStream(manifestEntry).use { it.readBytesBounded(DriveSyncService.MAX_SYNC_BLOB_BYTES) }
                )
                var damaged = 0
                val recordings = HashMap<String, ByteArray>()
                for (entry in manifest.recordings.filter { it.isTransferable }) {
                    val zipEntry = zip.getEntry("recordings/${entry.projectId}/${entry.fileName}") ?: continue
                    val bytes = try {
                        zip.getInputStream(zipEntry).use { it.readBytesBounded(entry.sizeBytes) }
                    } catch (_: DriveNetworkException) {
                        null
                    }
                    if (bytes == null || bytes.size.toLong() != entry.sizeBytes ||
                        BackupManifest.sha256Hex(bytes) != entry.sha256
                    ) {
                        damaged++
                        continue
                    }
                    recordings[entry.identityKey] = bytes
                }
                Contents(manifest, recordings, damaged)
            }
        } catch (e: DamagedBackupException) {
            throw e
        } catch (e: UnsupportedBackupVersionException) {
            throw e
        } catch (e: Exception) {
            throw DamagedBackupException(e)
        }
    }

    /** Merges imported songs, trash and tombstones; adds recordings this device lacks and never replaces one. */
    internal suspend fun import(contents: Contents, repository: ProjectRepository, filesDir: File): ImportSummary {
        // Finish or roll back an interrupted restore before reading what is on disk.
        RecordingFileStore.recoverInterruptedRestores(filesDir)
        val base = repository.snapshotLocalSyncBase()
        val localFiles = snapshotLocalRecordingFiles(filesDir, base.pendingIds)
        // Gather this device and the archive, recordings included, then resolve once.
        val merged = SyncMerger.resolve(
            SyncMerger.gather(base.blob.copy(recordings = localFiles.map { it.entry }), contents.manifest)
        )
        val local = localFiles.mapTo(HashSet()) { it.entry.identityKey }
        val trashed = snapshotTrashedRecordingIdentities(filesDir)
        val imported = contents.manifest.recordings.associateBy { it.identityKey }
        val wanted = merged.recordings
            .filter { it.identityKey in imported && it.identityKey !in local && it.identityKey !in trashed }
            .map { imported.getValue(it.identityKey) }
        var added = 0
        for (entry in wanted) {
            val bytes = contents.recordings[entry.identityKey] ?: continue
            if (RecordingFileStore.writeIfAbsent(filesDir, entry, bytes)) added++
        }
        repository.applySyncResult(merged, base)
        return ImportSummary(
            songs = contents.manifest.projects.size,
            recordingsAdded = added,
            damagedRecordings = contents.damagedRecordings,
            skippedLargeRecordings = contents.manifest.recordings.count { !it.isTransferable }
        )
    }
}
