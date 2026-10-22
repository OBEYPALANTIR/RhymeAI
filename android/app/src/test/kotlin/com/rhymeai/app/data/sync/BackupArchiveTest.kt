package com.rhymeai.app.data.sync

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.repository.ProjectRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import java.io.File
import java.time.ZoneOffset
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import java.util.zip.ZipEntry
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BackupArchiveTest {
    private val root = kotlin.io.path.createTempDirectory("rhymeai-archive").toFile()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @AfterTest
    fun tearDown() {
        scope.cancel()
        root.deleteRecursively()
    }

    private fun repository(name: String) = ProjectRepository(
        PreferenceDataStoreFactory.create(scope = scope) { File(root, "$name.preferences_pb") },
        BackupServiceTest.MemoryKeyStore()
    )

    private fun memo(filesDir: File, projectId: String, fileName: String, bytes: ByteArray): LocalRecordingFile {
        val file = RecordingFileStore.targetFile(filesDir, projectId, fileName).also { it.parentFile!!.mkdirs() }
        file.writeBytes(bytes)
        return LocalRecordingFile(
            RecordingManifestEntry(projectId, fileName, sizeBytes = bytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes)),
            file
        )
    }

    private val library = SyncBlob(
        projects = listOf(
            SongProject(id = "a", title = "Same/Name", lyrics = "one \"quoted\"\nline é", theme = "t", updatedAt = 10L),
            SongProject(id = "b", title = "Same/Name", lyrics = "two", theme = "", updatedAt = 20L)
        ),
        trashed = listOf(TrashedSongProject(SongProject(id = "c", title = "Bin", updatedAt = 5L), deletedAt = 7L)),
        deletions = listOf(SyncDeletion("d", deletedAt = 3L))
    )

    @Test
    fun exportThenImportYieldsTheSameManifest() {
        val filesDir = File(root, "export-files")
        val take = memo(filesDir, "a", "take.m4a", "audio".toByteArray())
        val zipFile = File(root, "backup.zip")

        val summary = zipFile.outputStream().use { BackupArchive.write(it, library, listOf(take), 1_000L, "device") }
        val contents = BackupArchive.read(zipFile)

        assertEquals(BackupArchive.ExportSummary(songs = 2, recordings = 1, skippedLargeRecordings = 0), summary)
        assertContentEquals(
            BackupManifest.encode(library.copy(recordings = listOf(take.entry)), 1_000L, "device"),
            BackupManifest.encode(contents.manifest, contents.manifest.savedAt, contents.manifest.savedByClientId)
        )
        assertContentEquals("audio".toByteArray(), contents.recordings.getValue(take.entry.id))
        val names = ZipFile(zipFile).use { zip -> zip.entries().toList().map { it.name } }
        assertEquals(
            listOf("manifest.json", "songs/Same_Name.txt", "songs/a.json", "songs/Same_Name (2).txt", "songs/b.json", "recordings/a/take.m4a"),
            names
        )
    }

    @Test
    fun importMergesIntoTheLibraryAndAddsOnlyMissingRecordings() = runBlocking {
        val sourceDir = File(root, "source")
        val zipFile = File(root, "backup.zip")
        val take = memo(sourceDir, "a", "take.m4a", "audio".toByteArray())
        zipFile.outputStream().use { BackupArchive.write(it, library, listOf(take), 1_000L, "device") }

        val targetDir = File(root, "target").also { it.mkdirs() }
        val repo = repository("target")
        repo.saveProjects(listOf(SongProject(id = "a", title = "Newer here", updatedAt = 99L), SongProject(id = "local")))

        val summary = BackupArchive.import(BackupArchive.read(zipFile), repo, targetDir)

        val projects = repo.projectsFlow.first().associateBy { it.id }
        assertEquals(setOf("a", "b", "local"), projects.keys)
        assertEquals("Newer here", projects.getValue("a").title)
        assertEquals(listOf("c"), repo.trashedProjectsFlow.first().map { it.project.id })
        assertContentEquals("audio".toByteArray(), RecordingFileStore.targetFile(targetDir, "a", "take.m4a").readBytes())
        assertEquals(1, summary.recordingsAdded)
    }

    @Test
    fun bareManifestImportsAndDamagedArchivesAreRefused() {
        val bare = File(root, "manifest.json").apply { writeBytes(BackupManifest.encode(library, 0L, "device")) }
        assertEquals(listOf("a", "b"), BackupArchive.read(bare).manifest.projects.map { it.id })

        val tampered = File(root, "tampered.json").apply {
            writeText(bare.readText().replace("two", "TWO"))
        }
        assertFailsWith<DamagedBackupException> { BackupArchive.read(tampered) }

        val noManifest = File(root, "empty.zip")
        ZipOutputStream(noManifest.outputStream()).use { it.putNextEntry(ZipEntry("songs/x.txt")); it.closeEntry() }
        assertFailsWith<DamagedBackupException> { BackupArchive.read(noManifest) }
    }

    @Test
    fun recordingBytesThatDoNotMatchTheManifestAreCountedAndDropped() {
        val sourceDir = File(root, "source")
        val take = memo(sourceDir, "a", "take.m4a", "audio".toByteArray())
        val good = File(root, "good.zip").apply { outputStream().use { BackupArchive.write(it, library, listOf(take), 0L, "d") } }
        val bad = File(root, "bad.zip")
        ZipFile(good).use { source ->
            ZipOutputStream(bad.outputStream()).use { out ->
                source.entries().toList().forEach { entry ->
                    out.putNextEntry(ZipEntry(entry.name))
                    out.write(if (entry.name.startsWith("recordings/")) "AUDIO".toByteArray() else source.getInputStream(entry).readBytes())
                    out.closeEntry()
                }
            }
        }
        val contents = BackupArchive.read(bad)
        assertEquals(1, contents.damagedRecordings)
        assertTrue(contents.recordings.isEmpty())
    }

    @Test
    fun archivesWithUnsafeOrForeignEntriesAreRejected() {
        val manifest = BackupManifest.encode(library, 0L, "device")
        for (bad in listOf("../escape.m4a", "recordings/a/../../escape.m4a", "/abs/path.txt", "C:/windows.txt", "songs\\win.txt", "notes/extra.txt")) {
            val zip = File(root, "bad.zip")
            ZipOutputStream(zip.outputStream()).use { out ->
                out.putNextEntry(ZipEntry(BackupArchive.MANIFEST_ENTRY))
                out.write(manifest)
                out.closeEntry()
                out.putNextEntry(ZipEntry(bad))
                out.write(byteArrayOf(1))
                out.closeEntry()
            }
            assertFailsWith<DamagedBackupException>(bad) { BackupArchive.read(zip) }
        }
        for (good in listOf("manifest.json", "songs/", "songs/My Song.txt", "recordings/a/take.m4a")) {
            assertTrue(BackupArchive.isAllowedEntryName(good), good)
        }
    }

    @Test
    fun importRevivesANewerSongButKeepsItsDeletedAudioDeleted() = runBlocking<Unit> {
        val audio = "old take".toByteArray()
        val sourceDir = File(root, "archive-source")
        val take = memo(sourceDir, "x", "take.m4a", audio).let { it.copy(entry = it.entry.copy(modifiedAt = 1_000L, uploadedAt = 1_000L)) }
        val zipFile = File(root, "revive.zip")
        zipFile.outputStream().use {
            BackupArchive.write(it, SyncBlob(projects = listOf(SongProject(id = "x", title = "Revived", updatedAt = 9_000L))), listOf(take), 0L, "other")
        }

        // With the recording known here (restored earlier, so its tombstone is written at
        // deletion) and without it (song tombstone only; the merge derives the recording's).
        for (knowsTheRecording in listOf(true, false)) {
            val filesDir = File(root, "device-$knowsTheRecording").also { it.mkdirs() }
            val repo = repository("device-$knowsTheRecording")
            if (knowsTheRecording) {
                val earlier = File(root, "earlier.zip")
                earlier.outputStream().use {
                    BackupArchive.write(it, SyncBlob(projects = listOf(SongProject(id = "x", updatedAt = 100L))), listOf(take), 0L, "other")
                }
                BackupArchive.import(BackupArchive.read(earlier), repo, filesDir)
                repo.moveProjectToTrash("x", 200L)
            } else {
                repo.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "x", updatedAt = 100L), deletedAt = 200L)))
            }
            repo.permanentlyDeleteTrashedProject("x", now = 5_000L)
            RecordingFiles.memoDirectory(filesDir, "x").deleteRecursively()

            val summary = BackupArchive.import(BackupArchive.read(zipFile), repo, filesDir)

            assertEquals(listOf("x"), repo.projectsFlow.first().map { it.id }, "knows=$knowsTheRecording")
            assertEquals(0, summary.recordingsAdded, "knows=$knowsTheRecording")
            assertTrue(RecordingFiles.memoDirectory(filesDir, "x").listFiles().isNullOrEmpty(), "knows=$knowsTheRecording")
            assertEquals(
                listOf(SyncDeletion("x", "take.m4a", 5_000L, recordingId = take.entry.id)),
                repo.snapshotLocalSyncBase().blob.deletions,
                "knows=$knowsTheRecording"
            )
        }
    }

    @Test
    fun aTakeKeepsItsTimeThroughImportAndReExportSoItsDeletionStillHolds() = runBlocking<Unit> {
        val audio = "old take".toByteArray()
        // Device 0 recorded the take at 1000 and exports it.
        val firstDir = File(root, "device-0").also { it.mkdirs() }
        val first = repository("device-0")
        memo(firstDir, "x", "take.m4a", audio).file.setLastModified(1_000L)
        first.saveProjects(listOf(SongProject(id = "x", updatedAt = 100L)))
        val archive1 = File(root, "archive-1.zip")
        archive1.outputStream().use {
            BackupArchive.write(it, first.snapshotLocalSyncBase().blob, snapshotLocalRecordings(first, firstDir, emptySet()), 0L, "d0")
        }

        // Device B imports it later, edits the song at 9000 and exports again.
        val secondDir = File(root, "device-b").also { it.mkdirs() }
        val second = repository("device-b")
        BackupArchive.import(BackupArchive.read(archive1), second, secondDir)
        second.saveProjects(listOf(SongProject(id = "x", title = "Edited", updatedAt = 9_000L)))
        val archive2 = File(root, "archive-2.zip")
        archive2.outputStream().use {
            BackupArchive.write(it, second.snapshotLocalSyncBase().blob, snapshotLocalRecordings(second, secondDir, emptySet()), 0L, "b")
        }
        assertEquals(1_000L, BackupArchive.read(archive2).manifest.recordings.single().uploadedAt)

        // Device A deleted the song at 5000; importing B's archive revives it but not the take.
        val thirdDir = File(root, "device-a").also { it.mkdirs() }
        val third = repository("device-a")
        third.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "x", updatedAt = 100L), deletedAt = 200L)))
        third.permanentlyDeleteTrashedProject("x", now = 5_000L)
        val summary = BackupArchive.import(BackupArchive.read(archive2), third, thirdDir)

        assertEquals(listOf("Edited"), third.projectsFlow.first().map { it.title })
        assertEquals(0, summary.recordingsAdded)
        assertFalse(RecordingFileStore.targetFile(thirdDir, "x", "take.m4a").exists())
    }

    @Test
    fun exportFileNameUsesTheLocalDate() {
        assertEquals("WritersBlock-backup-2026-10-22.zip", BackupArchive.fileName(1_792_702_991_000L, ZoneOffset.UTC))
    }
}
