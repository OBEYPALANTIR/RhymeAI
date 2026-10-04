package com.rhymeai.app.data.sync

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

/**
 * A recording over the per-device transfer limit is a valid manifest entry
 * that this device neither uploads nor downloads. It must not break sync and
 * must not disappear from the shared manifest.
 */
class LargeRecordingSyncTest {
    private val passphrase = "synthetic sync passphrase".toCharArray()
    private val json = Json { ignoreUnknownKeys = true }
    private val limit = RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES

    private fun recording(
        projectId: String,
        fileName: String,
        sizeBytes: Long = 12L,
        modifiedAt: Long = 100L,
        sha256: String = "digest-$projectId-$fileName"
    ) = RecordingManifestEntry(
        projectId = projectId,
        fileName = fileName,
        sizeBytes = sizeBytes,
        modifiedAt = modifiedAt,
        sha256 = sha256
    )

    private fun seal(blob: SyncBlob): ByteArray =
        SyncBlobCrypto.sealManifest(json.encodeToString(blob).toByteArray(Charsets.UTF_8), passphrase)

    private fun decide(local: SyncBlob, remote: SyncBlob): SyncDecision.MergeAndUpload =
        assertIs<SyncDecision.MergeAndUpload>(
            decideSyncAction(SyncDecisionInput(local, seal(remote), passphrase, "device"))
        )

    private fun uploadedManifest(decision: SyncDecision.MergeAndUpload): SyncBlob = json.decodeFromString(
        SyncBlobCrypto.openManifest(decision.sealedBytes, passphrase).plaintext.toString(Charsets.UTF_8)
    )

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
        assertEquals(setOf(large, small, localOnly), uploadedManifest(decision).recordings.toSet())
        val restores = RecordingSyncPlanner.planRestores(
            local = listOf(localOnly),
            remoteManifest = decision.merged.recordings,
            remoteFilesByName = mapOf(large.driveName to "drive-large", small.driveName to "drive-small")
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
        val localLarge = recording("p1", "session.wav", sizeBytes = limit + 1L, modifiedAt = 500L, sha256 = "local")
        val remoteLarge = localLarge.copy(modifiedAt = 100L, sha256 = "remote")
        val local = SyncBlob(recordings = listOf(localLarge))

        val unlisted = decide(local, remote = SyncBlob())
        assertEquals(emptyList(), unlisted.merged.recordings)
        assertEquals(emptyList(), unlisted.merged.deletions)
        assertEquals(1, skippedLargeRecordingCount(local.recordings, unlisted.merged))

        val listed = decide(local, remote = SyncBlob(recordings = listOf(remoteLarge)))
        assertEquals(listOf(remoteLarge), listed.merged.recordings)
        assertEquals(listOf(remoteLarge), uploadedManifest(listed).recordings)
        assertEquals(emptyList(), listed.merged.deletions)
    }

    @Test
    fun newerRemoteRecordingDoesNotReplaceLocalFileThatWasTooLargeToUpload() {
        val localLarge = recording("p1", "session.wav", sizeBytes = limit + 1L, modifiedAt = 1L, sha256 = "local")
        val remoteNewer = recording("p1", "session.wav", modifiedAt = 2L, sha256 = "remote")

        assertEquals(
            emptyList<RecordingRestorePlan>(),
            RecordingSyncPlanner.planRestores(
                local = listOf(localLarge),
                remoteManifest = listOf(remoteNewer),
                remoteFilesByName = mapOf(remoteNewer.driveName to "remote-file")
            )
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
                remoteManifest = emptyList(),
                remoteDriveNames = emptySet()
            )
        )
        assertEquals(
            listOf(remoteAtLimit),
            RecordingSyncPlanner.planRestores(
                local = emptyList(),
                remoteManifest = listOf(remoteLarge, remoteAtLimit),
                remoteFilesByName = mapOf(remoteLarge.driveName to "large", remoteAtLimit.driveName to "limit")
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
                deletions = listOf(SyncDeletion("gone", deletedAt = 1L))
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
        val localDiverged = recording("p1", "both.wav", sizeBytes = limit + 1L, sha256 = "local")
        val remoteDiverged = localDiverged.copy(sizeBytes = 12L, sha256 = "remote")
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
