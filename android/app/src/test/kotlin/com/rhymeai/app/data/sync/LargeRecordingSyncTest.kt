package com.rhymeai.app.data.sync

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * A recording over the per-device transfer limit is a valid manifest entry
 * that this device neither uploads nor downloads. It must not break sync and
 * must not disappear from the shared manifest.
 */
class LargeRecordingSyncTest {
    private val limit = RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES

    private fun recording(
        projectId: String,
        fileName: String,
        sizeBytes: Long = 12L,
        modifiedAt: Long = 100L,
        sha256: String = BackupManifest.sha256Hex("$projectId/$fileName".toByteArray())
    ) = RecordingManifestEntry(
        projectId = projectId,
        fileName = fileName,
        sizeBytes = sizeBytes,
        modifiedAt = modifiedAt,
        sha256 = sha256
    )

    private class Merged(val merged: SyncBlob)

    /** The backup's merge: this device only advertises recordings it can upload. */
    private fun decide(local: SyncBlob, remote: SyncBlob) =
        Merged(SyncMerger.merge(local.copy(recordings = local.recordings.filter { it.isTransferable }), remote))

    /** Recording identity, size and hash as they travel in a v4 manifest. */
    private fun wire(entries: Collection<RecordingManifestEntry>) =
        entries.map { Triple(it.identityKey, it.sizeBytes, it.sha256) }.toSet()

    private fun uploadedManifest(decision: Merged): Set<Triple<String, Long, String>> =
        wire(BackupManifest.decode(BackupManifest.encode(decision.merged, 0L, "device")).recordings)

    private fun v4Names(vararg pairs: Pair<RecordingManifestEntry, String>) =
        pairs.associate { (entry, id) -> BackupManifest.recordingDriveName(entry.id) to id }

    @Test
    fun remoteManifestWithOversizeEntryMergesRetainsItAndPlansNoDownload() {
        val large = recording("p1", "session.wav", sizeBytes = 100L * 1024L * 1024L)
        val small = recording("p1", "take.m4a")
        val localOnly = recording("p2", "local.m4a")

        val decision = decide(
            local = SyncBlob(recordings = listOf(localOnly)),
            remote = SyncBlob(recordings = listOf(large, small))
        )

        assertEquals(setOf(large, small, localOnly), decision.merged.recordings.toSet())
        assertEquals(wire(setOf(large, small, localOnly)), uploadedManifest(decision))
        val restores = RecordingSyncPlanner.planRestores(
            local = listOf(localOnly),
            remoteManifest = decision.merged.recordings,
            remoteFilesByName = v4Names(large to "drive-large", small to "drive-small")
        )
        assertEquals(listOf(small), restores.map { it.entry })
        assertEquals(1, skippedLargeRecordingCount(listOf(localOnly), decision.merged))
    }

    @Test
    fun oversizeRemoteEntriesDoNotConsumeThisDevicesRestoreBudget() {
        val large = recording("big", "session.wav", sizeBytes = 100L * 1024L * 1024L)
        val full = List(4) { recording("p$it", "take.m4a", sizeBytes = limit) }

        val decision = decide(local = SyncBlob(), remote = SyncBlob(recordings = full + large))

        assertEquals((full + large).toSet(), decision.merged.recordings.toSet())
    }

    @Test
    fun oversizeLocalEntryIsAdvertisedOnlyThroughAnExistingRemoteEntry() {
        val localLarge = recording("p1", "session.wav", sizeBytes = limit + 1L, modifiedAt = 500L, sha256 = BackupManifest.sha256Hex("local".toByteArray()))
        val remoteLarge = localLarge.copy(modifiedAt = 100L, sha256 = BackupManifest.sha256Hex("remote".toByteArray()))
        val local = SyncBlob(recordings = listOf(localLarge))

        val unlisted = decide(local, remote = SyncBlob())
        assertEquals(emptyList(), unlisted.merged.recordings)
        assertEquals(emptyList(), unlisted.merged.deletions)
        assertEquals(1, skippedLargeRecordingCount(local.recordings, unlisted.merged))

        val listed = decide(local, remote = SyncBlob(recordings = listOf(remoteLarge)))
        assertEquals(listOf(remoteLarge), listed.merged.recordings)
        assertEquals(wire(listOf(remoteLarge)), uploadedManifest(listed))
        assertEquals(emptyList(), listed.merged.deletions)
    }

    @Test
    fun aLargeLocalRecordingIsNeverDownloadedOverButADifferentRecordingWithItsNameIs() {
        val localLarge = recording("p1", "session.wav", sizeBytes = limit + 1L, modifiedAt = 1L, sha256 = BackupManifest.sha256Hex("local".toByteArray()))
        val sameRecordingRemote = localLarge.copy(sizeBytes = 12L)
        val differentRecording = recording("p1", "session.wav", modifiedAt = 2L, sha256 = BackupManifest.sha256Hex("remote".toByteArray()))

        // Same id: held here, never downloaded. Different id: a separate recording, restored beside it.
        assertEquals(
            listOf(differentRecording),
            RecordingSyncPlanner.planRestores(
                local = listOf(localLarge),
                remoteManifest = listOf(sameRecordingRemote, differentRecording),
                remoteFilesByName = v4Names(sameRecordingRemote to "same", differentRecording to "remote-file")
            ).map { it.entry }
        )
    }

    @Test
    fun plannerNeverTransfersOversizeRecordingsAndLeavesNormalOnesUnchanged() {
        val localLarge = recording("p1", "session.wav", sizeBytes = limit + 1L)
        val localAtLimit = recording("p1", "limit.m4a", sizeBytes = limit)
        val localSmall = recording("p1", "take.m4a")
        val remoteLarge = recording("p2", "remote.wav", sizeBytes = limit + 1L)
        val remoteAtLimit = recording("p2", "limit.m4a", sizeBytes = limit)

        assertEquals(
            listOf(localAtLimit, localSmall),
            RecordingSyncPlanner.planUploads(
                local = listOf(localLarge, localAtLimit, localSmall),
                manifest = listOf(localLarge, localAtLimit, localSmall),
                remoteDriveNames = emptySet()
            )
        )
        assertEquals(
            listOf(remoteAtLimit),
            RecordingSyncPlanner.planRestores(
                local = emptyList(),
                remoteManifest = listOf(remoteLarge, remoteAtLimit),
                remoteFilesByName = v4Names(remoteLarge to "large", remoteAtLimit to "limit")
            ).map { it.entry }
        )
    }

    @Test
    fun tombstonesStillRemoveOversizeEntriesAndAreNotCountedAsSizeSkips() {
        val remoteLarge = recording("gone", "session.wav", sizeBytes = limit + 1L)
        val localLarge = recording("gone", "local.wav", sizeBytes = limit + 1L)
        val keptLarge = recording("kept", "session.wav", sizeBytes = limit + 1L)

        val decision = decide(
            local = SyncBlob(recordings = listOf(localLarge)),
            remote = SyncBlob(
                recordings = listOf(remoteLarge, keptLarge),
                deletions = listOf(SyncDeletion("gone", deletedAt = 1_000L))
            )
        )

        assertEquals(listOf(keptLarge), decision.merged.recordings)
        assertEquals(1, skippedLargeRecordingCount(listOf(localLarge), decision.merged))
    }

    @Test
    fun skippedCountIsPerIdentityAndIgnoresRecordingsAlreadyIdenticalOnBothSides() {
        val same = recording("p1", "same.wav", sizeBytes = limit + 1L)
        val localOnly = recording("p1", "local.wav", sizeBytes = limit + 1L)
        val remoteOnly = recording("p1", "remote.wav", sizeBytes = limit + 1L)
        val localDiverged = recording("p1", "both.wav", sizeBytes = limit + 1L, sha256 = BackupManifest.sha256Hex("local".toByteArray()))
        val remoteDiverged = localDiverged.copy(sizeBytes = 12L, sha256 = BackupManifest.sha256Hex("remote".toByteArray()))
        val smallMissingLocally = recording("p1", "take.m4a")

        assertEquals(
            3,
            RecordingSyncPlanner.countSkippedAsTooLarge(
                local = listOf(same, localOnly, localDiverged),
                manifest = listOf(same, remoteOnly, remoteDiverged, smallMissingLocally)
            )
        )
        assertEquals(0, RecordingSyncPlanner.countSkippedAsTooLarge(listOf(smallMissingLocally), emptyList()))
    }
}
