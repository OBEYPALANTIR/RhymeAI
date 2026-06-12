package com.rhymeai.app.data.sync

import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.data.repository.SecureKeyStore
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Pure JVM tests for [decideSyncAction] — the core sync orchestration logic.
 * No network, no Android context, no mocking library. All boundaries
 * (DriveClient, ProjectRepository) are tested via their pure-function
 * equivalents only.
 *
 * Test structure mirrors the three decision paths:
 *   - Upload-only (first sync, no remote file)
 *   - Merge-and-upload (remote exists, correct passphrase)
 *   - BadPassphrase (remote exists, wrong passphrase → do nothing)
 */
class DriveSyncServiceTest {

    private val passphrase = "test correct horse battery".toCharArray()
    private val wrongPassphrase = "definitely wrong key".toCharArray()
    private val clientId = "device-001"
    private val json = Json { ignoreUnknownKeys = true }

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
