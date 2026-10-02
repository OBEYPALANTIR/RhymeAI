package com.rhymeai.app.data.sync

import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.data.repository.SecureKeyStore
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.int
import java.io.ByteArrayInputStream
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Pure JVM tests for [decideSyncAction] — the core sync orchestration logic.
 * No network, no Android context, no mocking library. All boundaries
 * (DriveClient, ProjectRepository) are tested via their pure-function
 * equivalents only.
 *
 * Test structure mirrors the four decision paths:
 *   - Upload-only (first sync, no remote file)
 *   - Merge-and-upload (remote exists, correct passphrase)
 *   - BadPassphrase (remote exists, wrong passphrase → do nothing)
 *   - CorruptRemote (remote decrypts but cannot be decoded → do nothing)
 */
class DriveSyncServiceTest {

    private val passphrase = "test correct horse battery".toCharArray()
    private val wrongPassphrase = "definitely wrong key".toCharArray()
    private val clientId = "device-001"
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun boundedDriveReadAcceptsExactLimitAndRejectsUnknownLengthOverflow() {
        val exact = ByteArray(8) { it.toByte() }

        assertTrue(ByteArrayInputStream(exact).readBytesBounded(exact.size.toLong()).contentEquals(exact))
        assertFailsWith<DriveNetworkException> {
            ByteArrayInputStream(exact).readBytesBounded(exact.size - 1L)
        }
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    private fun project(id: String, lyrics: String, updatedAt: Long = 100L) =
        SongProject(id = id, title = id, lyrics = lyrics, theme = "", updatedAt = updatedAt)

    private fun trashed(id: String, deletedAt: Long = 200L) = TrashedSongProject(
        project = project(id, "deleted", updatedAt = deletedAt - 1),
        deletedAt = deletedAt
    )

    private fun sealBlob(blob: SyncBlob, pp: CharArray = passphrase): ByteArray {
        val bytes = json.encodeToString(blob).toByteArray(Charsets.UTF_8)
        return SyncBlobCrypto.seal(bytes, pp)
    }

    private fun openDecisionMergeBlob(decision: SyncDecision.MergeAndUpload): SyncBlob {
        val plain = SyncBlobCrypto.open(decision.sealedBytes, passphrase)
        return json.decodeFromString(plain.toString(Charsets.UTF_8))
    }

    private fun openDecisionUploadBlob(decision: SyncDecision.UploadOnly): SyncBlob {
        val plain = SyncBlobCrypto.open(decision.sealedBytes, passphrase)
        return json.decodeFromString(plain.toString(Charsets.UTF_8))
    }

    // -----------------------------------------------------------------------
    // Upload-only path (first sync)
    // -----------------------------------------------------------------------

    @Test
    fun uploadOnlyWhenNoRemoteExists() {
        val local = SyncBlob(projects = listOf(project("a", "lyrics A")))
        val input = SyncDecisionInput(local, remoteBytes = null, passphrase, clientId)

        val decision = decideSyncAction(input)

        assertIs<SyncDecision.UploadOnly>(decision)
    }

    @Test
    fun uploadOnlyRejectsLocalRecordingOutsideRestorePolicy() {
        val oversized = RecordingManifestEntry(
            projectId = "project",
            fileName = "clip.m4a",
            sizeBytes = RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES + 1L,
            modifiedAt = 1L,
            sha256 = "digest"
        )

        assertFailsWith<DriveNetworkException> {
            decideSyncAction(
                SyncDecisionInput(
                    local = SyncBlob(recordings = listOf(oversized)),
                    remoteBytes = null,
                    passphrase = passphrase,
                    clientId = clientId
                )
            )
        }
    }

    @Test
    fun uploadOnlyRejectsManifestWhoseAggregateRecordingsExceedRestorePolicy() {
        val recordings = List(5) { index ->
            RecordingManifestEntry(
                projectId = "project-$index",
                fileName = "clip.m4a",
                sizeBytes = RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES,
                modifiedAt = index.toLong(),
                sha256 = "digest-$index"
            )
        }

        assertFailsWith<DriveNetworkException> {
            decideSyncAction(
                SyncDecisionInput(
                    local = SyncBlob(recordings = recordings),
                    remoteBytes = null,
                    passphrase = passphrase,
                    clientId = clientId
                )
            )
        }
    }

    @Test
    fun uploadOnlyEnvelopeRoundTripsCorrectly() {
        val local = SyncBlob(projects = listOf(project("a", "lyrics A")))
        val input = SyncDecisionInput(local, remoteBytes = null, passphrase, clientId)

        val decision = decideSyncAction(input) as SyncDecision.UploadOnly

        val recovered = openDecisionUploadBlob(decision)
        assertEquals(listOf("a"), recovered.projects.map { it.id })
        assertEquals("lyrics A", recovered.projects.first().lyrics)
    }

    @Test
    fun uploadOnlyStampsClientId() {
        val local = SyncBlob(projects = listOf(project("x", "X")), savedByClientId = "")
        val input = SyncDecisionInput(local, remoteBytes = null, passphrase, clientId)

        val decision = decideSyncAction(input) as SyncDecision.UploadOnly

        val recovered = openDecisionUploadBlob(decision)
        assertEquals(clientId, recovered.savedByClientId)
    }

    // -----------------------------------------------------------------------
    // Merge-and-upload path
    // -----------------------------------------------------------------------

    @Test
    fun mergeAndUploadWhenRemoteExists() {
        val local = SyncBlob(projects = listOf(project("a", "local lyrics", updatedAt = 300L)))
        val remote = SyncBlob(projects = listOf(project("b", "remote lyrics", updatedAt = 100L)))
        val input = SyncDecisionInput(local, sealBlob(remote), passphrase, clientId)

        val decision = decideSyncAction(input)

        assertIs<SyncDecision.MergeAndUpload>(decision)
    }

    @Test
    fun mergeRejectsAggregateRecordingManifestThatCannotBeRestoredFresh() {
        fun recording(index: Int) = RecordingManifestEntry(
            projectId = "project-$index",
            fileName = "clip.m4a",
            sizeBytes = RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES,
            modifiedAt = index.toLong(),
            sha256 = "digest-$index"
        )
        val local = SyncBlob(recordings = (0 until 4).map(::recording))
        val remote = SyncBlob(recordings = listOf(recording(4)))

        assertFailsWith<DriveNetworkException> {
            decideSyncAction(SyncDecisionInput(local, sealBlob(remote), passphrase, clientId))
        }
    }

    @Test
    fun mergeUsesLastWriterWins() {
        val local = SyncBlob(projects = listOf(project("a", "local", updatedAt = 300L)))
        val remote = SyncBlob(projects = listOf(project("a", "remote", updatedAt = 100L)))
        val input = SyncDecisionInput(local, sealBlob(remote), passphrase, clientId)

        val decision = decideSyncAction(input) as SyncDecision.MergeAndUpload

        assertEquals("local", decision.merged.projects.first { it.id == "a" }.lyrics)
    }

    @Test
    fun mergeUnionsDistinctProjects() {
        val local = SyncBlob(projects = listOf(project("a", "A", updatedAt = 100L)))
        val remote = SyncBlob(projects = listOf(project("b", "B", updatedAt = 100L)))
        val input = SyncDecisionInput(local, sealBlob(remote), passphrase, clientId)

        val decision = decideSyncAction(input) as SyncDecision.MergeAndUpload

        assertEquals(setOf("a", "b"), decision.merged.projects.map { it.id }.toSet())
    }

    @Test
    fun mergeEnvelopeDecryptsWithSamePassphrase() {
        val local = SyncBlob(projects = listOf(project("a", "hello", updatedAt = 100L)))
        val remote = SyncBlob(projects = listOf(project("b", "world", updatedAt = 200L)))
        val input = SyncDecisionInput(local, sealBlob(remote), passphrase, clientId)

        val decision = decideSyncAction(input) as SyncDecision.MergeAndUpload

        // The sealed bytes in the decision should round-trip back to the merged blob.
        val recovered = openDecisionMergeBlob(decision)
        assertEquals(decision.merged.projects.map { it.id }.toSet(), recovered.projects.map { it.id }.toSet())
    }

    @Test
    fun trashedRemoteProjectIsRemovedFromLocalAfterMerge() {
        val local = SyncBlob(projects = listOf(project("a", "active", updatedAt = 100L)))
        // Remote has 'a' in trash with a later timestamp.
        val remote = SyncBlob(trashed = listOf(trashed("a", deletedAt = 300L)))
        val input = SyncDecisionInput(local, sealBlob(remote), passphrase, clientId)

        val decision = decideSyncAction(input) as SyncDecision.MergeAndUpload

        assertTrue(decision.merged.projects.none { it.id == "a" })
        assertTrue(decision.merged.trashed.any { it.project.id == "a" })
    }

    // -----------------------------------------------------------------------
    // BadPassphrase path
    // -----------------------------------------------------------------------

    @Test
    fun badPassphraseWhenRemoteHasDifferentKey() {
        val local = SyncBlob(projects = listOf(project("a", "A")))
        // Remote was sealed with the WRONG passphrase (simulating a different device's key)
        val remote = SyncBlob(projects = listOf(project("a", "A")))
        val input = SyncDecisionInput(local, sealBlob(remote, wrongPassphrase), passphrase, clientId)

        val decision = decideSyncAction(input)

        assertIs<SyncDecision.BadPassphrase>(decision)
    }

    @Test
    fun corruptRemoteWhenEnvelopeDecryptsButJsonDecodeFails() {
        val local = SyncBlob(projects = listOf(project("a", "A")))
        val decryptableButInvalidJson = SyncBlobCrypto.seal(
            "not a sync blob".toByteArray(Charsets.UTF_8),
            passphrase
        )
        val input = SyncDecisionInput(local, decryptableButInvalidJson, passphrase, clientId)

        val decision = decideSyncAction(input)

        assertIs<SyncDecision.CorruptRemote>(decision)
        when (decision) {
            is SyncDecision.CorruptRemote -> { /* expected */ }
            is SyncDecision.BadPassphrase -> error("unexpected")
            is SyncDecision.UploadOnly -> error("unexpected")
            is SyncDecision.MergeAndUpload -> error("unexpected")
        }
    }

    @Test
    fun corruptRemoteWhenAuthenticatedProjectIdEscapesRecordingRoot() {
        val remoteJson = """{"version":2,"projects":[{"id":"../escape","title":"remote"}],"deletions":[]}"""
        val sealed = SyncBlobCrypto.seal(remoteJson.toByteArray(Charsets.UTF_8), passphrase)
        val decision = decideSyncAction(
            SyncDecisionInput(SyncBlob(), sealed, passphrase, clientId)
        )

        assertIs<SyncDecision.CorruptRemote>(decision)
    }

    @Test
    fun corruptRemoteWhenAuthenticatedRecordingDriveNameIsForged() {
        val remoteJson = """
            {
              "version": 2,
              "recordings": [{
                "projectId": "legacy opaque:é id",
                "fileName": "take 1.m4a",
                "driveName": "rec_other_take 1.m4a.enc",
                "sizeBytes": 12,
                "modifiedAt": 100,
                "sha256": "digest"
              }],
              "deletions": []
            }
        """.trimIndent()
        val sealed = SyncBlobCrypto.seal(remoteJson.toByteArray(Charsets.UTF_8), passphrase)
        val decision = decideSyncAction(
            SyncDecisionInput(SyncBlob(), sealed, passphrase, clientId)
        )

        assertIs<SyncDecision.CorruptRemote>(decision)
    }

    @Test
    fun syncMergerRejectsInvalidInMemoryRecordingIdentity() {
        val invalid = RecordingManifestEntry(
            projectId = "safe",
            fileName = "../clip.m4a",
            sizeBytes = 12L,
            modifiedAt = 100L,
            sha256 = "digest"
        )

        assertFailsWith<IllegalArgumentException> {
            SyncMerger.merge(SyncBlob(), SyncBlob(recordings = listOf(invalid)))
        }
    }

    @Test
    fun authenticatedLegacyUnicodeIdentityStillMerges() {
        val remote = SyncBlob(
            recordings = listOf(
                RecordingManifestEntry(
                    projectId = "legacy opaque:é id",
                    fileName = "take 1.m4a",
                    sizeBytes = 12L,
                    modifiedAt = 100L,
                    sha256 = "digest"
                )
            )
        )

        val decision = decideSyncAction(
            SyncDecisionInput(SyncBlob(), sealBlob(remote), passphrase, clientId)
        )

        assertIs<SyncDecision.MergeAndUpload>(decision)
    }

    @Test
    fun badPassphraseNeverModifiesRemote() {
        // This is a property of the sealed type system: BadPassphrase has no
        // sealedBytes field, so there is nothing for a caller to upload.
        val local = SyncBlob()
        val remote = SyncBlob()
        val input = SyncDecisionInput(local, sealBlob(remote, wrongPassphrase), passphrase, clientId)

        val decision = decideSyncAction(input)

        assertIs<SyncDecision.BadPassphrase>(decision)
        // Verify by exhaustive when: the compiler ensures no other variant carries bytes.
        when (decision) {
            is SyncDecision.BadPassphrase -> { /* expected */ }
            is SyncDecision.CorruptRemote -> error("unexpected")
            is SyncDecision.UploadOnly -> error("unexpected")
            is SyncDecision.MergeAndUpload -> error("unexpected")
        }
    }

    // -----------------------------------------------------------------------
    // Envelope integrity: seal → decide → can reopen
    // -----------------------------------------------------------------------

    @Test
    fun sealedBytesInUploadOnlyCanBeReopenedByService() {
        val local = SyncBlob(projects = listOf(project("z", "zzz")))
        val input = SyncDecisionInput(local, null, passphrase, clientId)
        val decision = decideSyncAction(input) as SyncDecision.UploadOnly

        // Simulate what a second device would do: download the sealed bytes and open them.
        val plain = SyncBlobCrypto.open(decision.sealedBytes, passphrase)
        val recovered = json.decodeFromString<SyncBlob>(plain.toString(Charsets.UTF_8))

        assertEquals("zzz", recovered.projects.first { it.id == "z" }.lyrics)
    }

    @Test
    fun sealedBytesInMergeAndUploadCanBeReopenedByService() {
        val local = SyncBlob(projects = listOf(project("p", "P", updatedAt = 50L)))
        val remote = SyncBlob(projects = listOf(project("q", "Q", updatedAt = 50L)))
        val input = SyncDecisionInput(local, sealBlob(remote), passphrase, clientId)
        val decision = decideSyncAction(input) as SyncDecision.MergeAndUpload

        val plain = SyncBlobCrypto.open(decision.sealedBytes, passphrase)
        val recovered = json.decodeFromString<SyncBlob>(plain.toString(Charsets.UTF_8))

        assertEquals(setOf("p", "q"), recovered.projects.map { it.id }.toSet())
    }

    @Test
    fun supportedV1AndV2RemoteShapesMergeIntoV2WithoutRestoringDeletedSong() {
        // Same v1 JSON used by the pinned iOS SyncRepairContractChecks fixture.
        val v1 = """{"version":1,"projects":[],"trashed":[],"recordings":[],"savedAt":1700000000000,"savedByClientId":"android-fixture"}"""
        val fromV1 = decideSyncAction(
            SyncDecisionInput(SyncBlob(), SyncBlobCrypto.seal(v1.toByteArray(), passphrase), passphrase, clientId)
        ) as SyncDecision.MergeAndUpload
        assertEquals(1, fromV1.remote.version)
        assertEquals(emptyList(), fromV1.remote.deletions)
        assertEquals(2, fromV1.merged.version)

        val v2 = """{"version":2,"deletions":[{"projectId":"gone","fileName":null,"deletedAt":1}]}"""
        val local = SyncBlob(projects = listOf(project("gone", "later edit", updatedAt = 1000L)))
        val fromV2 = decideSyncAction(
            SyncDecisionInput(local, SyncBlobCrypto.seal(v2.toByteArray(), passphrase), passphrase, clientId)
        ) as SyncDecision.MergeAndUpload
        assertEquals(emptyList(), fromV2.merged.projects)
        assertEquals(listOf(SyncDeletion("gone", deletedAt = 1L)), fromV2.merged.deletions)
        assertEquals(listOf(SyncDeletion("gone", deletedAt = 1L)), openDecisionMergeBlob(fromV2).deletions)
    }

    @Test
    fun unsupportedVersionShapesNeverBecomeRemoteOrReplaceLocalData() {
        for (raw in listOf(
            """{"version":1,"deletions":[]}""",
            """{"version":2}""",
            """{"version":2,"deletions":null}""",
            """{"version":3,"deletions":[]}""",
            """{"version":0}""",
            """{"deletions":[]}"""
        )) {
            assertFailsWith<Exception> { json.decodeFromString<SyncBlob>(raw) }
            val decision = decideSyncAction(
                SyncDecisionInput(SyncBlob(), SyncBlobCrypto.seal(raw.toByteArray(), passphrase), passphrase, clientId)
            )
            assertIs<SyncDecision.CorruptRemote>(decision)
        }
        assertFailsWith<DriveNetworkException> {
            decideSyncAction(SyncDecisionInput(
                SyncBlob(version = 1, deletions = listOf(SyncDeletion("gone", deletedAt = 1L))),
                null, passphrase, clientId
            ))
        }
    }

    @Test
    fun uploadOnlyWritesV2AndExplicitEmptyDeletionArrayEvenFromLegacyLocalBlob() {
        val upload = decideSyncAction(
            SyncDecisionInput(SyncBlob(version = 1), null, passphrase, clientId)
        ) as SyncDecision.UploadOnly
        val outgoing = json.parseToJsonElement(
            SyncBlobCrypto.open(upload.sealedBytes, passphrase).toString(Charsets.UTF_8)
        ).jsonObject
        assertEquals(2, outgoing.getValue("version").jsonPrimitive.int)
        assertEquals(emptyList(), outgoing.getValue("deletions").jsonArray)
        val deletionUpload = decideSyncAction(
            SyncDecisionInput(SyncBlob(deletions = listOf(SyncDeletion("gone", deletedAt = 7L))),
                null, passphrase, clientId)
        ) as SyncDecision.UploadOnly
        val encodedDeletion = json.parseToJsonElement(
            SyncBlobCrypto.open(deletionUpload.sealedBytes, passphrase).toString(Charsets.UTF_8)
        ).jsonObject.getValue("deletions").jsonArray.single().jsonObject
        assertEquals(JsonNull, encodedDeletion.getValue("fileName"))
        assertEquals(7L, encodedDeletion.getValue("deletedAt").jsonPrimitive.content.toLong())

        val v1Passthrough = json.parseToJsonElement(json.encodeToString(SyncBlob(version = 1))).jsonObject
        assertEquals(1, v1Passthrough.getValue("version").jsonPrimitive.int)
        assertTrue("deletions" !in v1Passthrough)
    }

    // -----------------------------------------------------------------------
    // SecureKeyStore in-memory fake (for wiring tests)
    // -----------------------------------------------------------------------

    @Test
    fun inMemoryKeyStoreStoresAndReturnsPassphrase() {
        val store = FakeSecureKeyStore()
        store.setKey(DriveSyncService.PASSPHRASE_KEY, "my secret passphrase")
        assertEquals("my secret passphrase", store.getKey(DriveSyncService.PASSPHRASE_KEY))
    }

    @Test
    fun inMemoryKeyStoreEmptyByDefault() {
        val store = FakeSecureKeyStore()
        assertEquals("", store.getKey(DriveSyncService.PASSPHRASE_KEY))
    }

    @Test
    fun driveSyncPassphraseRequiresAtLeastEightPrintableAsciiCharacters() {
        assertEquals(null, normalizedDriveSyncPassphraseOrNull("short7"))
        // Only 7 printable chars remain after trimming the trailing newline → rejected.
        assertEquals(null, normalizedDriveSyncPassphraseOrNull("short7\n"))
    }

    @Test
    fun driveSyncPassphraseTrimsAndAcceptsPrintableAscii() {
        assertEquals("correct horse", normalizedDriveSyncPassphraseOrNull("  correct horse  "))
    }

    @Test
    fun driveSyncPassphraseTrimsTabAndNewlinePadding() {
        // Matches iOS: strip the ASCII whitespace set " \t\r\n" from both ends.
        assertEquals("correct horse", normalizedDriveSyncPassphraseOrNull("\t correct horse \r\n"))
    }

    @Test
    fun driveSyncPassphraseRejectsInteriorTab() {
        // Interior whitespace is not trimmed; a tab is outside 0x20..0x7E → rejected.
        assertEquals(null, normalizedDriveSyncPassphraseOrNull("correct\thorse"))
    }
}

/**
 * In-memory [SecureKeyStore] for unit tests — same fake used (or reusable)
 * by any test that needs to inject credentials without Android Keystore.
 */
class FakeSecureKeyStore : SecureKeyStore {
    private val map = mutableMapOf<String, String>()

    override fun getKey(provider: String): String = map[provider] ?: ""
    override fun setKey(provider: String, key: String) { map[provider] = key }
    override fun allKeys(): Map<String, String> = map.toMap()
    override fun clear() { map.clear() }
}
