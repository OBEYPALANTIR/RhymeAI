package com.rhymeai.app.data.sync

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Libraries larger than one restore transaction: the plan is split into
 * bounded chunks and a failed chunk leaves
 * earlier chunks committed so the next sync resumes.
 */
class RecordingRestoreChunkingTest {
    private val fileLimit = RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES
    private val chunkLimit = DriveSyncService.MAX_SYNC_RECORDING_BATCH_BYTES

    private fun restore(index: Int, sizeBytes: Long) = RecordingRestorePlan(
        entry = RecordingManifestEntry(
            projectId = "project-$index",
            fileName = "clip.m4a",
            sizeBytes = sizeBytes,
            modifiedAt = index.toLong(),
            sha256 = "digest-$index"
        ),
        remoteFileId = "remote-$index"
    )

    private fun sizes(chunks: List<List<RecordingRestorePlan>>) =
        chunks.map { chunk -> chunk.sumOf { it.entry.sizeBytes } }

    @Test
    fun emptyPlanHasNoChunks() {
        assertEquals(emptyList(), RecordingSyncPlanner.chunkRestores(emptyList()))
    }

    @Test
    fun planExactlyAtLimitIsOneChunkAndOneByteOverStartsASecond() {
        val atLimit = List(4) { restore(it, fileLimit) }
        assertEquals(chunkLimit, atLimit.sumOf { it.entry.sizeBytes })
        assertEquals(listOf(atLimit), RecordingSyncPlanner.chunkRestores(atLimit))

        val overflow = restore(4, 1L)
        assertEquals(
            listOf(atLimit, listOf(overflow)),
            RecordingSyncPlanner.chunkRestores(atLimit + overflow)
        )
    }

    @Test
    fun maxSizeFilesFillChunksAndEveryEntryAppearsOnceInOrder() {
        val plan = List(11) { restore(it, fileLimit) }

        val chunks = RecordingSyncPlanner.chunkRestores(plan)

        assertEquals(listOf(4, 4, 3), chunks.map { it.size })
        assertEquals(plan, chunks.flatten())
        assertTrue(sizes(chunks).all { it <= chunkLimit })
    }

    @Test
    fun mixedSizesKeepPlanOrderAndNeverExceedTheChunkLimit() {
        val plan = listOf(6L, 5L, 5L, 1L, 10L, 10L, 0L, 3L).mapIndexed { index, size -> restore(index, size) }

        val chunks = RecordingSyncPlanner.chunkRestores(plan, maxChunkBytes = 10L)

        // Consecutive, not best-fit: order is the contract, not packing density.
        assertEquals(listOf(6L, 10L, 1L, 10L, 10L, 3L), sizes(chunks))
        assertEquals(plan, chunks.flatten())
        assertTrue(chunks.none { it.isEmpty() })
    }

    @Test
    fun entryLargerThanAChunkIsRejectedRatherThanStaged() {
        assertFailsWith<DriveNetworkException> {
            RecordingSyncPlanner.chunkRestores(listOf(restore(0, 11L)), maxChunkBytes = 10L)
        }
        assertFailsWith<DriveNetworkException> {
            RecordingSyncPlanner.chunkRestores(listOf(restore(0, -1L)), maxChunkBytes = 10L)
        }
    }

    @Test
    fun transferGuardHasNoAggregateCapButStillRejectsASingleOversizeEntry() {
        val entries = List(8) { restore(it, fileLimit).entry }

        assertEquals(8L * fileLimit, requireTransferableRecordings(entries))
        assertFailsWith<DriveNetworkException> {
            requireTransferableRecordings(entries + restore(8, fileLimit + 1L).entry)
        }
    }

    @Test
    fun failedChunkKeepsEarlierChunksAndNextPlanResumesWithOnlyTheRemainder() {
        val root = Files.createTempDirectory("rhymeai-chunked-restore").toFile()
        try {
            val contents = List(3) { index -> ByteArray(8) { (index * 16 + it).toByte() } }
            val remote = contents.mapIndexed { index, bytes ->
                RecordingManifestEntry(
                    projectId = "project-$index",
                    fileName = "clip.m4a",
                    sizeBytes = bytes.size.toLong(),
                    modifiedAt = (index + 1) * 1_000L,
                    sha256 = sha256Hex(bytes)
                )
            }
            val remoteFilesByName = remote.associate { BackupManifest.recordingDriveName(it.projectId, it.fileName) to "id-${it.projectId}" }
            val bytesByFileId = remote.indices.associate { "id-${remote[it].projectId}" to contents[it] }

            val plan = RecordingSyncPlanner.planRestores(emptyList(), remote, remoteFilesByName)
            val chunks = RecordingSyncPlanner.chunkRestores(plan, maxChunkBytes = 16L)
            assertEquals(listOf(2, 1), chunks.map { it.size })

            commitChunk(root, chunks[0]) { bytesByFileId.getValue(it) }
            // The second chunk's download is damaged, so it fails integrity while staging.
            assertFailsWith<DriveNetworkException> {
                commitChunk(root, chunks[1]) { ByteArray(8) }
            }

            assertContentEquals(contents[0], RecordingFileStore.targetFile(root, "project-0", "clip.m4a").readBytes())
            assertContentEquals(contents[1], RecordingFileStore.targetFile(root, "project-1", "clip.m4a").readBytes())
            assertFalse(RecordingFileStore.targetFile(root, "project-2", "clip.m4a").exists())
            assertEquals(
                emptyList(),
                root.listFiles()!!.filter { it.name.startsWith(RecordingFileStore.RESTORE_STAGE_PREFIX) }
            )

            val localAfterFailure = snapshotLocalRecordingFiles(root, emptySet()).map { it.entry }
            val resumed = RecordingSyncPlanner.planRestores(localAfterFailure, remote, remoteFilesByName)
            assertEquals(listOf(remote[2]), resumed.map { it.entry })

            RecordingSyncPlanner.chunkRestores(resumed, maxChunkBytes = 16L).forEach { chunk ->
                commitChunk(root, chunk) { bytesByFileId.getValue(it) }
            }
            val localAfterResume = snapshotLocalRecordingFiles(root, emptySet()).map { it.entry }
            assertEquals(emptyList(), RecordingSyncPlanner.planRestores(localAfterResume, remote, remoteFilesByName))
        } finally {
            root.deleteRecursively()
        }
    }

    /** Mirrors one chunk transaction of DriveSyncService.restoreRemoteRecordings without Drive or crypto. */
    private fun commitChunk(
        filesDir: File,
        chunk: List<RecordingRestorePlan>,
        download: (String) -> ByteArray
    ) {
        val stageDirectory = Files.createTempDirectory(
            filesDir.toPath(),
            RecordingFileStore.RESTORE_STAGE_PREFIX
        ).toFile()
        try {
            val staged = chunk.mapIndexed { index, restore ->
                RecordingFileStore.stageRestore(stageDirectory, index, restore.entry, download(restore.remoteFileId))
            }
            RecordingFileStore.commitStagedRestores(filesDir, staged)
        } finally {
            stageDirectory.deleteRecursively()
        }
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

}
