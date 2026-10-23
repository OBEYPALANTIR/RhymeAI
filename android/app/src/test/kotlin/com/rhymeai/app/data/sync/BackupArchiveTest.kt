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
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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
        val entry = RecordingManifestEntry(projectId, fileName, sizeBytes = bytes.size.toLong(), modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes))
        val file = RecordingFileStore.targetFile(filesDir, projectId, entry.id, fileName).also { it.parentFile!!.mkdirs() }
        file.writeBytes(bytes)
        return LocalRecordingFile(entry, file)
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
        assertContentEquals("audio".toByteArray(), RecordingFileStore.targetFile(targetDir, "a", take.entry.id, "take.m4a").readBytes())
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
        assertFalse(RecordingFiles.memoDirectory(thirdDir, "x").exists())
    }

    @Test
    fun exportFileNameUsesTheLocalDate() {
        assertEquals("WritersBlock-backup-2026-10-22.zip", BackupArchive.fileName(1_792_702_991_000L, ZoneOffset.UTC))
    }

    @Test
    fun eachDamagedMissingOrOversizedRecordingIsCountedOnceFromReadToImport() = runBlocking<Unit> {
        fun listed(name: String, bytes: ByteArray, size: Long = bytes.size.toLong()) =
            RecordingManifestEntry("a", name, sizeBytes = size, modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = 5L)
        val good = listed("good.m4a", "good".toByteArray())
        val corrupt = listed("corrupt.m4a", "expected".toByteArray())
        val missing = listed("missing.m4a", "missing".toByteArray())
        val oversized = listed("long.m4a", "long".toByteArray(), RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES + 1)
        val manifest = SyncBlob(projects = listOf(SongProject(id = "a", updatedAt = 1L)), recordings = listOf(good, corrupt, missing, oversized))
        val zipFile = File(root, "damaged.zip")
        ZipOutputStream(zipFile.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("manifest.json")); zip.write(BackupManifest.encode(manifest, 1L, "device")); zip.closeEntry()
            zip.putNextEntry(ZipEntry("recordings/a/good.m4a")); zip.write("good".toByteArray()); zip.closeEntry()
            zip.putNextEntry(ZipEntry("recordings/a/corrupt.m4a")); zip.write("tampered".toByteArray()); zip.closeEntry()
        }

        val contents = BackupArchive.read(zipFile)
        assertEquals(setOf(corrupt.id), contents.damagedIds)
        val summary = BackupArchive.import(contents, repository("counts"), File(root, "counts").also { it.mkdirs() })

        assertEquals(1, summary.recordingsAdded)
        // corrupt + missing, each once; the oversized one only as a size skip.
        assertEquals(2, summary.damagedRecordings)
        assertEquals(1, summary.skippedLargeRecordings)
    }

    private fun repoFileOrNull(path: String): File? =
        sequenceOf("../../$path", "../$path", path).map(::File).firstOrNull(File::isFile)

    @Test
    fun archiveNamesMatchTheSharedFixture() {
        val fixture = kotlinx.serialization.json.Json.parseToJsonElement(
            requireNotNull(repoFileOrNull("shared/fixtures/archive-names-v1.json")).readText()
        ).jsonObject
        val cases = fixture.getValue("cases").jsonArray.map { it.jsonObject }
        fun field(case: kotlinx.serialization.json.JsonObject, key: String) = case.getValue(key).jsonPrimitive.content
        val entries = cases.map { case ->
            RecordingManifestEntry(field(case, "projectId"), field(case, "displayName"), driveName = "unused", sizeBytes = 1L,
                modifiedAt = 0L, sha256 = "a".repeat(64), uploadedAt = field(case, "precedenceTime").toLong(), id = field(case, "id"))
        }
        val names = BackupArchive.exportNames(entries)
        assertEquals(
            cases.associate { field(it, "id") to field(it, "archivePath") },
            entries.associate { it.id to "recordings/${it.projectId}/${names.getValue(it.id)}" }
        )
        // Any order of arrival gives the same names.
        assertEquals(names, BackupArchive.exportNames(entries.reversed()))
    }

    @Test
    fun archiveNameFixtureCasesRoundTripThroughARealArchive() {
        val fixture = kotlinx.serialization.json.Json.parseToJsonElement(
            requireNotNull(repoFileOrNull("shared/fixtures/archive-names-v1.json")).readText()
        ).jsonObject
        val cases = fixture.getValue("cases").jsonArray.map { it.jsonObject }
        fun field(case: kotlinx.serialization.json.JsonObject, key: String) = case.getValue(key).jsonPrimitive.content
        val filesDir = File(root, "fixture-files")
        val files = cases.map { case ->
            val bytes = "audio of ${field(case, "id")}".toByteArray()
            val entry = RecordingManifestEntry(field(case, "projectId"), field(case, "displayName"), sizeBytes = bytes.size.toLong(),
                modifiedAt = 0L, sha256 = BackupManifest.sha256Hex(bytes), uploadedAt = field(case, "precedenceTime").toLong(), id = field(case, "id"))
            val file = RecordingFileStore.targetFile(filesDir, entry.projectId, entry.id, entry.fileName).apply { parentFile!!.mkdirs(); writeBytes(bytes) }
            LocalRecordingFile(entry, file)
        }
        val zipFile = File(root, "fixture.zip")
        zipFile.outputStream().use { BackupArchive.write(it, SyncBlob(), files, 1_000L, "device") }

        val entryNames = ZipFile(zipFile).use { zip -> zip.entries().toList().map { it.name }.toSet() }
        assertTrue(entryNames.containsAll(cases.map { field(it, "archivePath") }), entryNames.toString())
        val read = BackupArchive.read(zipFile)
        assertEquals(cases.associate { field(it, "id") to field(it, "displayName") }, read.manifest.recordings.associate { it.id to it.fileName })
        for (local in files) assertContentEquals(local.file.readBytes(), read.recordings.getValue(local.entry.id))
        assertTrue(read.damagedIds.isEmpty())
    }

    @Test
    fun theIosCopyOfTheArchiveNamesFixtureMatches() {
        val iosCopy = repoFileOrNull("Writers Block/Writers BlockTests/archive-names-v1.json")
        org.junit.Assume.assumeTrue("iOS copy of archive-names-v1.json is not in this checkout yet; drift check skipped.", iosCopy != null)
        assertContentEquals(requireNotNull(repoFileOrNull("shared/fixtures/archive-names-v1.json")).readBytes(), iosCopy!!.readBytes())
    }
    @Test
    fun importKeepsAndReportsAnArchiveSongWhoseRepairedTimeLosesToATombstoneHere() = runBlocking<Unit> {
        // A41: the archive holds "r" with a repaired time; this device deleted it at 200.
        val zipFile = File(root, "repaired.zip")
        val repaired = SongProject(id = "r", title = "Only here", lyrics = "only copy", updatedAt = 300L, precedenceRepaired = true)
        zipFile.outputStream().use { BackupArchive.write(it, SyncBlob(projects = listOf(repaired)), emptyList(), 1_000L, "device") }
        val filesDir = File(root, "import-files").also { it.mkdirs() }
        val repo = repository("repaired")
        repo.saveTrashedProjects(listOf(TrashedSongProject(SongProject(id = "r", updatedAt = 10L), deletedAt = 20L)))
        repo.permanentlyDeleteTrashedProject("r", now = 200L)

        val summary = BackupArchive.import(BackupArchive.read(zipFile), repo, filesDir)

        assertEquals(1, summary.songsSetAside)
        assertTrue(repo.projectsFlow.first().none { it.id == "r" })
        assertEquals("only copy", repo.recoveredSongs().single().project.lyrics)
    }
}
