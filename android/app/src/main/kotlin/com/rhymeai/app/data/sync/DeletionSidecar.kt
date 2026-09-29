package com.rhymeai.app.data.sync

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.security.SecureRandom

/**
 * Per-install, encrypted deletion records in Drive's appDataFolder.
 *
 * Each install writes only its own object (`rhymeai-rt-<random id>.enc`); readers list every page,
 * read every object and take the union, so no install can overwrite another install's deletions.
 * Objects are sealed with [SyncBlobCrypto] using the current sync passphrase; the Drive file name
 * contains no project or recording names. See the reviewed design (SIDECAR_DESIGN_v3).
 */
@Serializable
data class DeletionSidecarPayload(
    val format: Int = 1,
    val writerId: String,
    val writeNonce: String,
    val entries: List<RecordingTombstone> = emptyList()
)

/** Identity of this install as a sidecar writer. Kept out of Auto Backup so a restore gets a fresh one. */
interface SidecarWriterIdentity {
    fun writerId(): String
    fun lastVerifiedNonce(): String?
    fun recordVerifiedNonce(nonce: String)
    /** Discard the identity, e.g. when another actor wrote under it. Local deletion records are kept. */
    fun rotate()
}

/** Stores the id and last verified write nonce in a directory excluded from backup (`noBackupFilesDir`). */
class FileSidecarWriterIdentity(private val dir: File) : SidecarWriterIdentity {
    private val idFile = File(dir, "sidecar-writer-id")
    private val nonceFile = File(dir, "sidecar-write-nonce")

    @Synchronized
    override fun writerId(): String {
        val existing = runCatching { idFile.readText().trim() }.getOrNull()
        if (existing != null && existing.length == 32 && existing.all { it in '0'..'9' || it in 'a'..'f' }) return existing
        val fresh = randomHex(16)
        dir.mkdirs()
        idFile.writeText(fresh)
        nonceFile.delete()
        return fresh
    }

    @Synchronized
    override fun lastVerifiedNonce(): String? = runCatching { nonceFile.readText().trim() }.getOrNull()?.takeIf { it.isNotEmpty() }

    @Synchronized
    override fun recordVerifiedNonce(nonce: String) {
        dir.mkdirs()
        nonceFile.writeText(nonce)
    }

    @Synchronized
    override fun rotate() {
        idFile.delete()
        nonceFile.delete()
    }
}

internal fun randomHex(bytes: Int): String {
    val buffer = ByteArray(bytes)
    SecureRandom().nextBytes(buffer)
    return buffer.joinToString("") { "%02x".format(it) }
}

sealed class SidecarRead {
    /** Every listed object was read. */
    data class Ok(val entries: List<RecordingTombstone>, val objectCount: Int) : SidecarRead()

    /**
     * Listing incomplete or at least one object unreadable (wrong passphrase, malformed, download
     * failure, oversize). Never treated as empty: recording restore must be paused. [entries] holds
     * whatever could be read.
     */
    data class Unavailable(
        val unreadableObjects: Int,
        val listingComplete: Boolean,
        val entries: List<RecordingTombstone>
    ) : SidecarRead()
}

sealed class SidecarWrite {
    data object Written : SidecarWrite()
    data object TooLarge : SidecarWrite()
    data object NotVerified : SidecarWrite()

    /** This install's own object exists but cannot be read; it is never overwritten. */
    data object ExistingUnreadable : SidecarWrite()
}

class DeletionSidecar(
    private val driveClient: DriveClient,
    private val identity: SidecarWriterIdentity,
    private val maxObjectBytes: Long = DriveSyncService.MAX_SYNC_BLOB_BYTES,
    private val newNonce: () -> String = { randomHex(16) }
) {
    companion object {
        const val NAME_PREFIX = "rhymeai-rt-"
        const val NAME_SUFFIX = ".enc"
        const val MIME_TYPE = "application/octet-stream"

        fun objectName(writerId: String): String = "$NAME_PREFIX$writerId$NAME_SUFFIX"
    }

    private val json = Json { ignoreUnknownKeys = true }

    private fun isSidecarName(name: String): Boolean = name.startsWith(NAME_PREFIX) && name.endsWith(NAME_SUFFIX)

    /** Lists every page (fails closed inside the client) and reads every object. Never throws on Drive errors. */
    suspend fun readAll(accessToken: String, passphrase: CharArray): SidecarRead {
        val listed = try {
            driveClient.listAllByNamePrefix(accessToken, NAME_PREFIX).filter { isSidecarName(it.name) }
        } catch (e: DriveNetworkException) {
            return SidecarRead.Unavailable(0, false, emptyList())
        }
        val ownName = objectName(identity.writerId())
        val readable = mutableListOf<RecordingTombstone>()
        var unreadable = 0
        var ownNonceMismatch = false
        for (meta in listed) {
            val payload = readObject(accessToken, meta.id, passphrase)
            if (payload == null) {
                unreadable++
                continue
            }
            readable += payload.entries
            if (meta.name == ownName) {
                val expected = identity.lastVerifiedNonce()
                if (expected != null && payload.writeNonce != expected) ownNonceMismatch = true
            }
        }
        // Another actor wrote under our id (clone): move to a new id, keep local records, and
        // treat the old object as a foreign one that is still read and unioned.
        if (ownNonceMismatch) identity.rotate()
        val merged = RecordingTombstone.merge(readable)
        return if (unreadable > 0) SidecarRead.Unavailable(unreadable, true, merged) else SidecarRead.Ok(merged, listed.size)
    }

    /**
     * Writes only this install's object (existing records are merged in, never dropped), then
     * re-reads only that object to verify it. Throws
     * [DriveNetworkException] on listing or transfer failure; callers must not write the library
     * blob unless this returns [SidecarWrite.Written].
     */
    suspend fun writeOwn(accessToken: String, passphrase: CharArray, ownEntries: List<RecordingTombstone>): SidecarWrite {
        val ownName = objectName(identity.writerId())
        val existing = findOwn(accessToken, ownName)
        // Preserve what this install already published: local state can be damaged or missing, and
        // replacing the object with only the local list would erase an older verified deletion. An
        // existing own object that cannot be read is never overwritten.
        val existingEntries = if (existing == null) {
            emptyList()
        } else {
            readObject(accessToken, existing.id, passphrase)?.entries ?: return SidecarWrite.ExistingUnreadable
        }
        val nonce = newNonce()
        val payload = DeletionSidecarPayload(
            writerId = identity.writerId(),
            writeNonce = nonce,
            entries = RecordingTombstone.merge(existingEntries + ownEntries)
        )
        val plaintext = json.encodeToString(payload).toByteArray(Charsets.UTF_8)
        if (SyncBlobCrypto.envelopeSizeForPlaintext(plaintext.size.toLong()) > maxObjectBytes) return SidecarWrite.TooLarge
        val sealed = SyncBlobCrypto.seal(plaintext, passphrase)
        if (existing == null) {
            driveClient.uploadNewFile(accessToken, ownName, MIME_TYPE, sealed)
        } else {
            driveClient.updateFile(accessToken, existing.id, MIME_TYPE, sealed)
        }
        val written = findOwn(accessToken, ownName) ?: return SidecarWrite.NotVerified
        val readBack = readObject(accessToken, written.id, passphrase) ?: return SidecarWrite.NotVerified
        if (readBack.writeNonce != nonce || !readBack.entries.containsAll(payload.entries)) return SidecarWrite.NotVerified
        identity.recordVerifiedNonce(nonce)
        return SidecarWrite.Written
    }

    private suspend fun findOwn(accessToken: String, ownName: String): DriveFileMetadata? =
        driveClient.listAllByNamePrefix(accessToken, NAME_PREFIX)
            .filter { it.name == ownName }
            .minByOrNull { it.id }

    private suspend fun readObject(accessToken: String, fileId: String, passphrase: CharArray): DeletionSidecarPayload? =
        try {
            val plaintext = SyncBlobCrypto.open(driveClient.downloadFile(accessToken, fileId, maxObjectBytes), passphrase)
            val payload = json.decodeFromString<DeletionSidecarPayload>(String(plaintext, Charsets.UTF_8))
            require(payload.format == 1) { "Unsupported deletion record format" }
            payload.entries.forEach(RecordingTombstone::validate)
            payload
        } catch (e: DriveNetworkException) {
            null
        } catch (e: SyncBlobSealException) {
            null
        } catch (e: SerializationException) {
            null
        } catch (e: IllegalArgumentException) {
            null
        }
}

/** Runs one block at a time; every Drive-writing path of the service goes through one instance. */
internal class SyncSerializer {
    private val mutex = Mutex()
    suspend fun <T> run(block: suspend () -> T): T = mutex.withLock { block() }
}

/**
 * Follows `nextPageToken` until it is absent. Fails closed: a repeated token or more than
 * [maxPages] pages throws instead of returning a partial list.
 */
internal fun <T> collectAllPages(maxPages: Int, fetchPage: (pageToken: String?) -> Pair<List<T>, String?>): List<T> {
    val results = mutableListOf<T>()
    val seen = HashSet<String>()
    var token: String? = null
    var pages = 0
    do {
        pages++
        if (pages > maxPages) throw DriveNetworkException("Drive list exceeded $maxPages pages")
        val (items, next) = fetchPage(token)
        results += items
        token = next
        if (token != null && !seen.add(token)) throw DriveNetworkException("Drive list returned a repeated page token")
    } while (token != null)
    return results
}
