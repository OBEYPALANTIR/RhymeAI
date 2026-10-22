package com.rhymeai.app.data.sync

import com.rhymeai.app.data.recording.RecordingFiles
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import java.io.File
import java.security.MessageDigest
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith

class RecordingSyncTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun oldSyncBlobJsonDefaultsRecordingsToEmptyManifest() {
        val oldJson = """
            {
              "version": 1,
              "projects": [],
              "trashed": [],
              "savedAt": 123,
              "savedByClientId": "legacy-device"
            }
        """.trimIndent()

        val decoded = json.decodeFromString<SyncBlob>(oldJson)

        assertEquals(emptyList(), decoded.recordings)
    }

    @Test
    fun recordingManifestAcceptsAnyNonNegativeSizeAndFlagsWhatThisDeviceCanTransfer() {
        fun sized(sizeBytes: Long) =
            recording("p1", "clip.m4a", modifiedAt = 1L, sha256 = "digest", sizeBytes = sizeBytes)
        val limit = RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES

        sized(0L).validate()
        sized(limit).validate()
        sized(limit + 1L).validate()
        sized(100L * 1024L * 1024L).validate()
        assertFailsWith<IllegalArgumentException> { sized(-1L).validate() }

        assertTrue(sized(limit).isTransferable)
        assertFalse(sized(limit + 1L).isTransferable)
    }

    @Test
    fun recordingTransferGuardRejectsOversizeEntriesButNotLargeTotals() {
        val atBatchLimit = List(4) { index ->
            recording(
                "p$index",
                "clip.m4a",
                modifiedAt = index.toLong(),
                sha256 = "digest-$index",
                sizeBytes = RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES
            )
        }
        assertEquals(DriveSyncService.MAX_SYNC_RECORDING_BATCH_BYTES, requireTransferableRecordings(atBatchLimit))

        // The total is reported, not capped: restores are chunked and uploads are sequential.
        assertEquals(
            DriveSyncService.MAX_SYNC_RECORDING_BATCH_BYTES + 1L,
            requireTransferableRecordings(
                atBatchLimit + recording("overflow", "clip.m4a", 5L, "digest", 1L)
            )
        )
        assertFailsWith<DriveNetworkException> {
            requireTransferableRecordings(
                listOf(
                    recording(
                        "large", "clip.m4a", 6L, "digest",
                        RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES + 1L
                    )
                )
            )
        }
    }

    @Test
    fun recordingRemoteNamesUseInteropFormatFromProjectAndFileStem() {
        val driveName = RecordingManifestEntry.driveNameFor(
            projectId = "project-123",
            fileName = "take 1_final.m4a"
        )

        assertEquals("rec_project-123_take 1_final.m4a.enc", driveName)
    }

    @Test
    fun importedFormatsPreserveExtensionAndCannotCollideWithM4aBackupNames() {
        val wav = RecordingManifestEntry.driveNameFor("song", "take.wav")
        val m4a = RecordingManifestEntry.driveNameFor("song", "take.wav.m4a")
        assertEquals("rec_song_take.wav.enc", wav)
        assertEquals("rec_song_take.wav.m4a.enc", m4a)
        assertFalse(wav == m4a)
    }

    @Test
    fun importedFormatsPassManifestValidationWithoutRelaxingFilenameSafety() {
        listOf("m4a", "mp3", "wav", "aac").forEach { extension ->
            recording("song", "take.$extension", 1L, "digest").validate()
            assertFailsWith<IllegalArgumentException> {
                recording("song", "../take.$extension", 1L, "digest").validate()
            }
        }
        assertFailsWith<IllegalArgumentException> {
            recording("song", "take.mp4", 1L, "digest").validate()
        }
    }

    @Test
    fun syncMergerUnionsRecordingsByIdAndKeepsTheBackedUpCopy() {
        val localOnly = recording("p1", "local.m4a", modifiedAt = 100L, sha256 = "local")
        val localCopy = recording("p1", "shared.m4a", modifiedAt = 900L, sha256 = "here")
        val backedUp = localCopy.copy(uploadedAt = 50L)
        val remoteOnly = recording("p2", "remote.m4a", modifiedAt = 200L, sha256 = "remote")
        // Same name, different recording: a separate id, so both are kept.
        val sameNameOther = recording("p1", "local.m4a", modifiedAt = 300L, sha256 = "other")

        val merged = SyncMerger.merge(
            local = SyncBlob(recordings = listOf(localOnly, localCopy)),
            remote = SyncBlob(recordings = listOf(backedUp, remoteOnly, sameNameOther))
        )

        assertEquals(setOf(localOnly.id, localCopy.id, remoteOnly.id, sameNameOther.id), merged.recordings.map { it.id }.toSet())
        // Per id, Drive's entry wins.
        assertEquals(50L, merged.recordings.single { it.id == localCopy.id }.uploadedAt)
    }

    @Test
    fun uploadPlanSendsOnlyListedLocalBytesMissingFromDrive() {
        val onDrive = recording("p1", "same.m4a", sha256 = "same")
        val missingOnDrive = recording("p1", "missing.m4a", sha256 = "missing")
        val diverged = recording("p3", "diverged.m4a", sha256 = "local")
        val tombstoned = recording("p2", "deleted.m4a", sha256 = "gone")

        val plan = RecordingSyncPlanner.planUploads(
            local = listOf(onDrive, missingOnDrive, diverged, tombstoned),
            manifest = listOf(onDrive, missingOnDrive, diverged.copy(sha256 = "remote")),
            remoteDriveNames = setOf(BackupManifest.recordingDriveName(onDrive.id))
        )

        assertEquals(listOf(missingOnDrive), plan)
    }

    @Test
    fun restorePlanOnlyFillsRecordingsMissingHere() {
        val localOnly = recording("p1", "local-only.m4a", sha256 = "keep")
        val localDiverged = recording("p1", "diverged.m4a", sha256 = "local")
        val remoteDiverged = localDiverged.copy(sha256 = "remote")
        val remoteOnly = recording("p2", "remote-only.m4a", sha256 = "remote")
        val remoteWithoutFile = recording("p2", "never-uploaded.m4a", sha256 = "lost")

        val plan = RecordingSyncPlanner.planRestores(
            local = listOf(localOnly, localDiverged),
            remoteManifest = listOf(remoteDiverged, remoteOnly, remoteWithoutFile),
            remoteFilesByName = mapOf(
                BackupManifest.recordingDriveName(remoteDiverged.id) to "drive-diverged",
                BackupManifest.recordingDriveName(remoteOnly.id) to "drive-only"
            )
        )

        assertEquals(listOf("drive-only"), plan.map { it.remoteFileId })
        assertFalse(plan.any { it.entry.identityKey == localDiverged.identityKey }, "a local recording is never replaced")
    }

    @Test
    fun restorePlanSkipsRecordingsSittingInLocalTrash() {
        val trashedHere = recording("p1", "trashed.m4a", modifiedAt = 500L, sha256 = "remote")
        val remoteOnly = recording("p1", "remote-only.m4a", modifiedAt = 200L, sha256 = "remote")

        val plan = RecordingSyncPlanner.planRestores(
            local = emptyList(),
            remoteManifest = listOf(trashedHere, remoteOnly),
            remoteFilesByName = listOf(trashedHere to "drive-trashed", remoteOnly to "drive-only")
                .associate { (entry, id) -> BackupManifest.recordingDriveName(entry.id) to id },
            locallyTrashed = setOf(trashedHere.identityKey)
        )

        assertEquals(listOf("drive-only"), plan.map { it.remoteFileId })
    }

    @Test
    fun trashedRecordingIdentitiesComeFromTrashFolderNamesOnly() {
        val filesDir = Files.createTempDirectory("rhymeai-trash-identities").toFile()
        try {
            fun trashed() = kotlinx.coroutines.runBlocking {
                com.rhymeai.app.data.recording.RecordingTransitions.snapshot(MemoryCatalog(), filesDir, emptySet())
            }.filter { it.inTrash }.mapTo(HashSet()) { it.entry.nameKey }
            assertEquals(emptySet(), trashed())
            val trash = RecordingFiles.trashDirectory(filesDir, "p1").also { it.mkdirs() }
            File(trash, "1700000000000__take.m4a").writeBytes(byteArrayOf(1))
            File(trash, "1700000000001__Take two.m4a").writeBytes(byteArrayOf(1))
            File(trash, "not-a-trash-name.m4a").writeBytes(byteArrayOf(1))
            File(trash, "1700000000002__notes.txt").writeBytes(byteArrayOf(1))
            // Live memos never count as trashed.
            RecordingFiles.memoDirectory(filesDir, "p1").also { it.mkdirs() }.let { File(it, "live.m4a").writeBytes(byteArrayOf(1)) }

            assertEquals(setOf("p1/take.m4a", "p1/Take two.m4a"), trashed())
        } finally {
            filesDir.deleteRecursively()
        }
    }

    @Test
    fun importPublishesWithItsRecordAndNeverReplacesAnotherRecording() = kotlinx.coroutines.runBlocking<Unit> {
        val root = Files.createTempDirectory("rhymeai-recording-store").toFile()
        try {
            val catalog = MemoryCatalog()
            val existing = RecordingFileStore.targetFile(root, "p1", "clip.m4a")
            existing.parentFile?.mkdirs()
            existing.writeText("local stays")

            val remoteBytes = "remote copy".toByteArray()
            val entry = recording(
                projectId = "p1",
                fileName = "clip.m4a",
                modifiedAt = 700_123L,
                sha256 = sha256Hex(remoteBytes),
                sizeBytes = remoteBytes.size.toLong()
            )

            assertFailsWith<DriveNetworkException> {
                RecordingFileStore.importVerified(catalog, root, entry.copy(sizeBytes = remoteBytes.size + 1L), remoteBytes, RecordingRecord.IMPORTED)
            }
            // A different recording holds the name: the import gets a free variant, the original stays.
            assertTrue(RecordingFileStore.importVerified(catalog, root, entry, remoteBytes, RecordingRecord.IMPORTED))
            assertEquals("local stays", existing.readText())
            val record = catalog.records.single()
            assertEquals(entry.id, record.id)
            assertEquals(700_123L, record.uploadedAt)
            assertEquals("clip 2.m4a", record.fileName)
            assertEquals("remote copy", File(root, record.path!!).readText())
            // The same recording id is never imported twice.
            assertFalse(RecordingFileStore.importVerified(catalog, root, entry, remoteBytes, RecordingRecord.IMPORTED))
            assertFalse(existing.parentFile?.listFiles()?.any { it.name.endsWith(".tmp") } ?: false)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun aMetadataWriteFailureFailsTheImportAndPublishesNothing() = kotlinx.coroutines.runBlocking<Unit> {
        val root = Files.createTempDirectory("rhymeai-recording-fail").toFile()
        try {
            val catalog = MemoryCatalog().apply { failWrites = true }
            val bytes = "remote copy".toByteArray()
            val entry = recording("p1", "clip.m4a", 1_000L, sha256Hex(bytes), bytes.size.toLong())

            assertFailsWith<java.io.IOException> {
                RecordingFileStore.importVerified(catalog, root, entry, bytes, RecordingRecord.IMPORTED)
            }

            assertFalse(RecordingFileStore.targetFile(root, "p1", "clip.m4a").exists())
            assertTrue(catalog.records.isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun restoreCommitKeepsADestinationThatAppearedAfterPlanning() = kotlinx.coroutines.runBlocking<Unit> {
        val root = Files.createTempDirectory("rhymeai-recording-late").toFile()
        val stage = Files.createTempDirectory(root.toPath(), RecordingFileStore.RESTORE_STAGE_PREFIX).toFile()
        try {
            val catalog = MemoryCatalog()
            val bytes = "downloaded".toByteArray()
            val planned = recording("p1", "take.m4a", 2L, sha256Hex(bytes), bytes.size.toLong())
            val other = recording("p1", "other.m4a", 2L, sha256Hex(bytes), bytes.size.toLong())
            val staged = listOf(
                RecordingFileStore.stageRestore(stage, 0, planned, bytes),
                RecordingFileStore.stageRestore(stage, 1, other, bytes)
            )
            // The user renames a memo onto the planned name while the download runs.
            val target = RecordingFileStore.targetFile(root, "p1", "take.m4a").also { it.parentFile?.mkdirs() }
            target.writeText("renamed memo")

            assertEquals(listOf(planned, other), RecordingFileStore.commitStagedRestores(catalog, root, staged))

            // Both recordings are kept: the download takes a free name.
            assertEquals("renamed memo", target.readText())
            assertEquals("downloaded", RecordingFileStore.targetFile(root, "p1", "take 2.m4a").readText())
            assertEquals("downloaded", RecordingFileStore.targetFile(root, "p1", "other.m4a").readText())
            assertEquals(setOf(planned.id, other.id), catalog.records.mapTo(HashSet()) { it.id })
            assertFalse(stage.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun aFailedCommitKeepsEverythingAlreadyInPlace() = kotlinx.coroutines.runBlocking<Unit> {
        val root = Files.createTempDirectory("rhymeai-recording-batch").toFile()
        val stage = Files.createTempDirectory(root.toPath(), RecordingFileStore.RESTORE_STAGE_PREFIX).toFile()
        try {
            val firstTarget = RecordingFileStore.targetFile(root, "p1", "first.m4a")
            firstTarget.parentFile?.mkdirs()
            firstTarget.writeText("original")
            val bytes = "download".toByteArray()
            val stagedNew = RecordingFileStore.stageRestore(stage, 1, recording("p1", "new.m4a", 2L, sha256Hex(bytes), bytes.size.toLong()), bytes)
            val missingThird = RecordingFileStore.StagedRecording(
                recording("p2", "third.m4a", 3L, sha256Hex("third".toByteArray()), 5L),
                File(stage, "missing.tmp")
            )

            assertFailsWith<java.io.IOException> {
                RecordingFileStore.commitStagedRestores(MemoryCatalog(), root, listOf(stagedNew, missingThird))
            }

            // Nothing is replaced or removed: the original stays and the complete new take stays.
            assertEquals("original", firstTarget.readText())
            assertEquals("download", RecordingFileStore.targetFile(root, "p1", "new.m4a").readText())
            assertFalse(RecordingFileStore.targetFile(root, "p2", "third.m4a").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun recoveryRemovesOnlyTheStagingFolder() {
        val root = Files.createTempDirectory("rhymeai-recording-recovery").toFile()
        val stage = Files.createTempDirectory(root.toPath(), RecordingFileStore.RESTORE_STAGE_PREFIX).toFile()
        try {
            val bytes = "download".toByteArray()
            RecordingFileStore.stageRestore(stage, 0, recording("p1", "take.m4a", 2L, sha256Hex(bytes), bytes.size.toLong()), bytes)
            // A memo the user renamed onto the planned name while the restore was interrupted.
            val target = RecordingFileStore.targetFile(root, "p1", "take.m4a").also { it.parentFile?.mkdirs() }
            target.writeText("user memo")

            RecordingFileStore.recoverInterruptedRestores(root)

            assertEquals("user memo", target.readText())
            assertFalse(stage.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun uploadReadRejectsGrowthShrinkAndSameSizeReplacement() {
        val root = Files.createTempDirectory("rhymeai-recording-upload").toFile()
        try {
            val file = File(root, "clip.m4a")
            val original = "original".toByteArray()
            val entry = recording("p1", "clip.m4a", 1L, sha256Hex(original), original.size.toLong())

            file.writeBytes(original)
            assertTrue(RecordingFileStore.readForUpload(file, entry).contentEquals(original))

            file.appendText("growth")
            assertFailsWith<DriveNetworkException> { RecordingFileStore.readForUpload(file, entry) }

            file.writeText("short")
            assertFailsWith<DriveNetworkException> { RecordingFileStore.readForUpload(file, entry) }

            file.writeText("replaced")
            assertFailsWith<DriveNetworkException> { RecordingFileStore.readForUpload(file, entry) }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun recordingFileStoreRejectsTraversalBeforeCreatingDirectories() {
        val root = Files.createTempDirectory("rhymeai-recording-traversal").toFile()
        try {
            assertFailsWith<IllegalArgumentException> {
                RecordingFileStore.targetFile(root, "../escape", "clip.m4a")
            }
            assertFailsWith<IllegalArgumentException> {
                RecordingFileStore.targetFile(root, "safe", "../clip.m4a")
            }
            assertFalse(File(root.parentFile, "escape").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun recordingFileStoreRejectsSymlinkedProjectDirectory() {
        val root = Files.createTempDirectory("rhymeai-recording-symlink").toFile()
        val external = Files.createTempDirectory("rhymeai-recording-external").toFile()
        try {
            val memosRoot = RecordingFiles.memosRoot(root).apply { mkdirs() }
            Files.createSymbolicLink(File(memosRoot, "safe").toPath(), external.toPath())

            assertFailsWith<IllegalArgumentException> {
                RecordingFileStore.targetFile(root, "safe", "clip.m4a")
            }
        } finally {
            root.deleteRecursively()
            external.deleteRecursively()
        }
    }

    private fun recording(
        projectId: String,
        fileName: String,
        modifiedAt: Long = 100L,
        sha256: String,
        sizeBytes: Long = 12L
    ): RecordingManifestEntry = RecordingManifestEntry(
        projectId = projectId,
        fileName = fileName,
        driveName = RecordingManifestEntry.driveNameFor(projectId, fileName),
        sizeBytes = sizeBytes,
        modifiedAt = modifiedAt,
        sha256 = sha256
    )

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }
}
