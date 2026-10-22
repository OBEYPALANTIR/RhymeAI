package com.rhymeai.app.data.sync

import android.app.PendingIntent
import android.content.Context
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.SecureKeyStore
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.service.VoiceMemoService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.io.IOException
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.io.File
import java.net.URLEncoder
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import kotlin.coroutines.resume

/**
 * Typed result of one backup, restore or migration. Callers never see partial
 * state; they get exactly one of these and render it.
 */
sealed class SyncResult {
    /**
     * Drive holds the merged library. `merged` is the snapshot written there (and,
     * for a restore or migration, applied locally). `skippedLargeRecordings` counts
     * recordings over [RecordingManifestEntry.MAX_SYNC_RECORDING_BYTES];
     * `damagedRecordings` counts downloads whose bytes did not match the manifest.
     */
    data class Success(
        val merged: SyncBlob,
        val skippedLargeRecordings: Int = 0,
        val damagedRecordings: Int = 0,
        val legacyBackupPresent: Boolean = false,
        val migratedLegacyBackup: Boolean = false
    ) : SyncResult()

    /** The user must approve Drive access; launch [pendingIntent], then retry. */
    data class AuthorizationRequired(val pendingIntent: PendingIntent) : SyncResult()

    /** The passphrase did not open the older encrypted backup; nothing changed. */
    data object WrongPassphrase : SyncResult()

    /** Drive authorization is unavailable on this device. */
    data object NotConfigured : SyncResult()

    /** A restore found no backup in Drive. */
    data object NoBackup : SyncResult()

    /** Any recoverable network / HTTP failure. */
    data class NetworkError(val message: String) : SyncResult()

    /** The manifest failed its hash or shape checks; it was neither merged nor overwritten. */
    data object CorruptRemote : SyncResult()

    /** The manifest comes from a newer app version; it was neither merged nor overwritten. */
    data object UnsupportedVersion : SyncResult()

    /** Unexpected error (programming fault, storage failure, etc.). */
    data class UnknownError(val cause: Throwable) : SyncResult()
}

/** What a connected Drive holds, read without changing anything. */
data class BackupProbe(
    val projectCount: Int,
    val recordingCount: Int,
    val legacyBackupPresent: Boolean
)

sealed class ProbeResult {
    data class Ready(val probe: BackupProbe) : ProbeResult()
    data class Failed(val result: SyncResult) : ProbeResult()
}

sealed class DriveAuthorization {
    data class Granted(val accessToken: String) : DriveAuthorization()
    data class NeedsConsent(val pendingIntent: PendingIntent) : DriveAuthorization()
    data object Unavailable : DriveAuthorization()
}

/** Supplies a `drive.appdata` access token; the Play Services one is [PlayServicesDriveAuthorizer]. */
interface DriveAuthorizer {
    suspend fun authorize(): DriveAuthorization

    /** Drops a token this device may still cache after it was revoked. */
    suspend fun forget(accessToken: String) {}
}

/**
 * Play Services authorization for the Drive appData scope. No token is stored by
 * the app; Play Services identifies the caller by its signing certificate, which
 * must be registered as an Android OAuth client (see docs/CLOUD_BACKUP_SETUP.md).
 */
class PlayServicesDriveAuthorizer(
    private val context: Context,
    private val driveClientId: String = ""
) : DriveAuthorizer {
    override suspend fun authorize(): DriveAuthorization = suspendCancellableCoroutine { cont ->
        val request = AuthorizationRequest.Builder()
            .setRequestedScopes(listOf(DRIVE_APPDATA_SCOPE))
            .apply { if (driveClientId.isNotBlank()) requestOfflineAccess(driveClientId) }
            .build()
        Identity.getAuthorizationClient(context)
            .authorize(request)
            .addOnSuccessListener { result ->
                val pendingIntent = result.pendingIntent
                val token = result.accessToken
                cont.resume(
                    when {
                        result.hasResolution() && pendingIntent != null -> DriveAuthorization.NeedsConsent(pendingIntent)
                        token != null -> DriveAuthorization.Granted(token)
                        else -> DriveAuthorization.Unavailable
                    }
                )
            }
            .addOnFailureListener { cont.resume(DriveAuthorization.Unavailable) }
    }

    override suspend fun forget(accessToken: String) {
        withContext(Dispatchers.IO) {
            runCatching { GoogleAuthUtil.clearToken(context, accessToken) }
        }
    }

    private companion object {
        val DRIVE_APPDATA_SCOPE = Scope("https://www.googleapis.com/auth/drive.appdata")
    }
}

data class DriveFileMetadata(
    val id: String,
    val name: String,
    val modifiedTime: String? = null,
    val version: String? = null
)

/**
 * The HTTP boundary, so backup orchestration is testable without a network.
 * Implementations use Drive REST v3 in `appDataFolder` via a Bearer token.
 */
interface DriveClient {
    suspend fun findFileByName(accessToken: String, name: String): DriveFileMetadata?
    suspend fun listFilesByNamePrefix(accessToken: String, namePrefix: String): List<DriveFileMetadata>
    suspend fun downloadFile(accessToken: String, fileId: String, maxBytes: Long): ByteArray
    suspend fun uploadNewFile(
        accessToken: String,
        name: String,
        mimeType: String,
        content: ByteArray,
        appProperties: Map<String, String> = emptyMap()
    ): String
    suspend fun updateFile(accessToken: String, fileId: String, mimeType: String, content: ByteArray)
    suspend fun deleteFile(accessToken: String, fileId: String)

    /** Revokes the grant behind [token] at Google (`oauth2.googleapis.com/revoke`). */
    suspend fun revokeToken(token: String)
}

/**
 * Production [DriveClient] over plain HttpURLConnection, the idiom AIService
 * already uses, so the app needs no Google API client library.
 */
class RealDriveClient : DriveClient {

    private companion object {
        private const val DRIVE_V3 = "https://www.googleapis.com/drive/v3"
        private const val UPLOAD_V3 = "https://www.googleapis.com/upload/drive/v3"
        private const val REVOKE_URL = "https://oauth2.googleapis.com/revoke"
        private const val CONNECT_TIMEOUT_MS = 20_000
        private const val READ_TIMEOUT_MS = 30_000
        private const val MULTIPART_BOUNDARY = "rhymeai_boundary_g91hf"
        private val driveJson = Json { ignoreUnknownKeys = true }
    }

    override suspend fun findFileByName(accessToken: String, name: String): DriveFileMetadata? = withContext(Dispatchers.IO) {
        listFiles(accessToken, exactName = name, namePrefix = null).firstOrNull()
    }

    override suspend fun listFilesByNamePrefix(
        accessToken: String,
        namePrefix: String
    ): List<DriveFileMetadata> = withContext(Dispatchers.IO) {
        listFiles(accessToken, exactName = null, namePrefix = namePrefix)
            .filter { it.name.startsWith(namePrefix) }
    }

    override suspend fun downloadFile(accessToken: String, fileId: String, maxBytes: Long): ByteArray =
        withContext(Dispatchers.IO) {
            mapIoFailure("Drive download") {
                require(maxBytes in 0..Int.MAX_VALUE.toLong()) { "Invalid Drive download limit" }
                val conn = openRequest("$DRIVE_V3/files/$fileId?alt=media", "GET", accessToken)
                try {
                    val code = conn.responseCode
                    if (code !in 200..299) {
                        throwHttpFailure("Drive download", code, conn.errorBody())
                    }
                    val contentLength = conn.contentLengthLong
                    if (contentLength > maxBytes) {
                        throw DriveNetworkException("Drive download exceeds the allowed size")
                    }
                    conn.inputStream.readBytesBounded(maxBytes)
                } finally {
                    conn.disconnect()
                }
            }
        }

    override suspend fun uploadNewFile(
        accessToken: String,
        name: String,
        mimeType: String,
        content: ByteArray,
        appProperties: Map<String, String>
    ): String = withContext(Dispatchers.IO) {
        mapIoFailure("Drive upload") {
            val metadata = buildJsonObject {
                put("name", name)
                putJsonArray("parents") { add(kotlinx.serialization.json.JsonPrimitive("appDataFolder")) }
                put("mimeType", mimeType)
                if (appProperties.isNotEmpty()) {
                    putJsonObject("appProperties") { appProperties.forEach { (key, value) -> put(key, value) } }
                }
            }.toString()
            val body = buildMultipart(metadata.toByteArray(Charsets.UTF_8), mimeType, content)
            val conn = openMultipart("$UPLOAD_V3/files?uploadType=multipart&fields=id", "POST", accessToken)
            conn.doOutput = true
            conn.outputStream.use { it.write(body) }
            try {
                val code = conn.responseCode
                if (code !in 200..299) {
                    throwHttpFailure("Drive upload", code, conn.errorBody())
                }
                val respBody = conn.inputStream.bufferedReader().use { it.readText() }
                driveJson.parseToJsonElement(respBody).jsonObject["id"]?.jsonPrimitive?.content
                    ?: throw DriveNetworkException("Drive upload response missing file id")
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun updateFile(
        accessToken: String,
        fileId: String,
        mimeType: String,
        content: ByteArray
    ) = withContext(Dispatchers.IO) {
        mapIoFailure("Drive update") {
            val metadata = buildJsonObject { put("mimeType", mimeType) }.toString()
            val body = buildMultipart(metadata.toByteArray(Charsets.UTF_8), mimeType, content)
            val conn = openMultipart("$UPLOAD_V3/files/$fileId?uploadType=multipart", "PATCH", accessToken)
            conn.doOutput = true
            conn.outputStream.use { it.write(body) }
            try {
                val code = conn.responseCode
                if (code !in 200..299) {
                    throwHttpFailure("Drive update", code, conn.errorBody())
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun deleteFile(accessToken: String, fileId: String) = withContext(Dispatchers.IO) {
        mapIoFailure("Drive delete") {
            val conn = openRequest("$DRIVE_V3/files/$fileId", "DELETE", accessToken)
            try {
                val code = conn.responseCode
                if (code !in 200..299 && code != 404) {
                    throwHttpFailure("Drive delete", code, conn.errorBody())
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    override suspend fun revokeToken(token: String) = withContext(Dispatchers.IO) {
        mapIoFailure("Google revoke") {
            val conn = URL(REVOKE_URL).openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.connectTimeout = CONNECT_TIMEOUT_MS
            conn.readTimeout = READ_TIMEOUT_MS
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            conn.outputStream.use { it.write("token=${URLEncoder.encode(token, "UTF-8")}".toByteArray(Charsets.UTF_8)) }
            try {
                val code = conn.responseCode
                if (code !in 200..299) {
                    throw DriveHttpException(code, "Google could not revoke access ($code)")
                }
            } finally {
                conn.disconnect()
            }
        }
    }

    private fun listFiles(
        accessToken: String,
        exactName: String?,
        namePrefix: String?
    ): List<DriveFileMetadata> {
        val query = when {
            exactName != null -> "name = '${driveQueryLiteral(exactName)}' and trashed = false"
            namePrefix != null -> "name contains '${driveQueryLiteral(namePrefix)}' and trashed = false"
            else -> "trashed = false"
        }
        val files = mutableListOf<DriveFileMetadata>()
        var pageToken: String? = null
        do {
            val encodedQuery = URLEncoder.encode(query, "UTF-8")
            val page = pageToken?.let { "&pageToken=${URLEncoder.encode(it, "UTF-8")}" } ?: ""
            val url = "$DRIVE_V3/files?spaces=appDataFolder&pageSize=1000" +
                "&fields=nextPageToken,files(id,name,modifiedTime,version)&q=$encodedQuery$page"
            pageToken = mapIoFailure("Drive list") {
                val conn = openRequest(url, "GET", accessToken)
                try {
                    val code = conn.responseCode
                    if (code !in 200..299) {
                        throwHttpFailure("Drive list", code, conn.errorBody())
                    }
                    val body = driveJson.parseToJsonElement(conn.inputStream.bufferedReader().use { it.readText() }).jsonObject
                    files += parseDriveFiles(body)
                    body["nextPageToken"]?.jsonPrimitive?.content
                } finally {
                    conn.disconnect()
                }
            }
        } while (pageToken != null)
        return files
    }

    private inline fun <T> mapIoFailure(operation: String, block: () -> T): T =
        try {
            block()
        } catch (e: java.net.SocketTimeoutException) {
            throw DriveNetworkException("$operation timed out — check your connection.", e)
        } catch (e: IOException) {
            throw DriveNetworkException("$operation failed — check your connection.", e)
        }

    private fun throwHttpFailure(operation: String, code: Int, body: String): Nothing {
        when (code) {
            401 -> throw DriveAuthException("Drive authorization expired (401)")
            403, 429 -> throw DriveHttpException(code, "Drive quota or rate limit reached — try again later.")
            in 500..599 -> throw DriveHttpException(code, "Drive server error ($code) — try again later.")
            else -> throw DriveHttpException(code, "$operation failed ($code): $body")
        }
    }

    private fun HttpURLConnection.errorBody(): String =
        errorStream?.bufferedReader()?.use { it.readText() } ?: ""

    private fun openRequest(url: String, method: String, accessToken: String): HttpURLConnection {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = CONNECT_TIMEOUT_MS
        conn.readTimeout = READ_TIMEOUT_MS
        conn.setRequestProperty("Authorization", "Bearer $accessToken")
        return conn
    }

    private fun openMultipart(url: String, method: String, accessToken: String): HttpURLConnection {
        val conn = openRequest(url, method, accessToken)
        conn.setRequestProperty("Content-Type", "multipart/related; boundary=$MULTIPART_BOUNDARY")
        return conn
    }

    private fun buildMultipart(metadataBytes: ByteArray, mimeType: String, contentBytes: ByteArray): ByteArray {
        val nl = "\r\n"
        val prefix = "--$MULTIPART_BOUNDARY${nl}Content-Type: application/json; charset=UTF-8$nl$nl".toByteArray(Charsets.UTF_8)
        val middle = "$nl--$MULTIPART_BOUNDARY$nl".toByteArray(Charsets.UTF_8)
        val contentHeader = "Content-Type: $mimeType$nl$nl".toByteArray(Charsets.UTF_8)
        val suffix = "$nl--$MULTIPART_BOUNDARY--$nl".toByteArray(Charsets.UTF_8)
        return prefix + metadataBytes + middle + contentHeader + contentBytes + suffix
    }

    private fun parseDriveFiles(body: kotlinx.serialization.json.JsonObject): List<DriveFileMetadata> {
        val files = body["files"]?.jsonArray ?: return emptyList()
        return files.mapNotNull { element ->
            val obj = element.jsonObject
            val id = obj["id"]?.jsonPrimitive?.content ?: return@mapNotNull null
            val name = obj["name"]?.jsonPrimitive?.content ?: return@mapNotNull null
            DriveFileMetadata(
                id = id,
                name = name,
                modifiedTime = obj["modifiedTime"]?.jsonPrimitive?.content,
                version = obj["version"]?.jsonPrimitive?.content
            )
        }
    }

    private fun driveQueryLiteral(value: String): String =
        value.replace("\\", "\\\\").replace("'", "\\'")
}

/** Thrown when the Drive access token is rejected (401) — triggers re-auth. */
class DriveAuthException(message: String) : Exception(message)

/** Thrown for any non-auth HTTP or IO failure from Drive. */
open class DriveNetworkException(message: String, cause: Throwable? = null) : Exception(message, cause)

class DriveHttpException(val statusCode: Int, message: String) : DriveNetworkException(message)

internal fun InputStream.readBytesBounded(maxBytes: Long): ByteArray {
    require(maxBytes in 0..Int.MAX_VALUE.toLong()) { "Invalid Drive download limit" }
    val output = ByteArrayOutputStream(minOf(DEFAULT_BUFFER_SIZE.toLong(), maxBytes).toInt())
    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
    var total = 0L
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        if (count == 0) continue
        total = Math.addExact(total, count.toLong())
        if (total > maxBytes) {
            throw DriveNetworkException("Drive download exceeds the allowed size")
        }
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

data class RecordingRestorePlan(
    val entry: RecordingManifestEntry,
    val remoteFileId: String
)

/**
 * Per-entry guard for anything this device is about to hold in memory: every
 * entry must be valid and within the per-file transfer limit. Returns the total
 * size. There is deliberately no aggregate cap: uploads hold one file at a time
 * and restores are bounded per transaction by [RecordingSyncPlanner.chunkRestores].
 */
internal fun requireTransferableRecordings(entries: List<RecordingManifestEntry>): Long {
    var totalBytes = 0L
    for (entry in entries) {
        try {
            entry.validate()
            if (!entry.isTransferable) {
                throw DriveNetworkException("Recording transfer exceeds the allowed size")
            }
            totalBytes = Math.addExact(totalBytes, entry.sizeBytes)
        } catch (e: ArithmeticException) {
            throw DriveNetworkException("Recording transfer exceeds the allowed size", e)
        } catch (e: IllegalArgumentException) {
            throw DriveNetworkException("Recording transfer contains unsupported data", e)
        }
    }
    return totalBytes
}

/** Remote tombstones must be applied before local files are considered for upload. */
internal fun recordingsAllowedForUpload(
    recordings: List<RecordingManifestEntry>,
    localDeletions: List<SyncDeletion>,
    remoteDeletions: List<SyncDeletion>
): List<RecordingManifestEntry> {
    if (localDeletions.isEmpty() && remoteDeletions.isEmpty()) return recordings
    val projects = HashSet<String>()
    val files = HashSet<Pair<String, String>>()
    for (deletion in localDeletions + remoteDeletions) {
        if (deletion.fileName == null) projects.add(deletion.projectId)
        else files.add(deletion.projectId to deletion.fileName)
    }
    return recordings.filterNot {
        it.projectId in projects || (it.projectId to it.fileName) in files
    }
}

object RecordingSyncPlanner {
    /**
     * Local recordings the merged manifest lists with this device's bytes whose
     * raw Drive file does not exist yet. Recordings are immutable, so a file
     * already on Drive is never uploaded again.
     */
    fun planUploads(
        local: List<RecordingManifestEntry>,
        manifest: List<RecordingManifestEntry>,
        remoteDriveNames: Set<String>
    ): List<RecordingManifestEntry> {
        val manifestByIdentity = manifest.associateBy { it.identityKey }
        return local.filter { entry ->
            entry.isTransferable &&
                manifestByIdentity[entry.identityKey]?.sha256 == entry.sha256 &&
                BackupManifest.recordingDriveName(entry.projectId, entry.fileName) !in remoteDriveNames
        }
    }

    /**
     * Identities this device left out of sync because of the transfer limit:
     * a local file too large to upload, or a manifest entry too large to
     * download, whose content is not already the same on both sides.
     */
    fun countSkippedAsTooLarge(
        local: List<RecordingManifestEntry>,
        manifest: List<RecordingManifestEntry>
    ): Int {
        val localByIdentity = local.associateBy { it.identityKey }
        val manifestByIdentity = manifest.associateBy { it.identityKey }
        return (localByIdentity.keys + manifestByIdentity.keys).count { identity ->
            val localEntry = localByIdentity[identity]
            val manifestEntry = manifestByIdentity[identity]
            val tooLarge = localEntry?.isTransferable == false || manifestEntry?.isTransferable == false
            tooLarge && localEntry?.sha256 != manifestEntry?.sha256
        }
    }

    /** Downloads only fill gaps: a local file is never replaced by a remote one. */
    fun planRestores(
        local: List<RecordingManifestEntry>,
        remoteManifest: List<RecordingManifestEntry>,
        remoteFilesByName: Map<String, String>,
        locallyTrashed: Set<String> = emptySet()
    ): List<RecordingRestorePlan> {
        val localIdentities = local.mapTo(HashSet()) { it.identityKey }
        return remoteManifest.mapNotNull { remoteEntry ->
            if (!remoteEntry.isTransferable) return@mapNotNull null
            // A recording the user moved to Trash here is absent from the live list
            // but not deleted; downloading it again would undo the trash action.
            if (remoteEntry.identityKey in locallyTrashed) return@mapNotNull null
            if (remoteEntry.identityKey in localIdentities) return@mapNotNull null
            val remoteFileId = remoteFilesByName[
                BackupManifest.recordingDriveName(remoteEntry.projectId, remoteEntry.fileName)
            ] ?: return@mapNotNull null
            RecordingRestorePlan(remoteEntry, remoteFileId)
        }
    }

    /**
     * Splits a restore plan into consecutive chunks of at most [maxChunkBytes],
     * preserving order. Each chunk is staged and committed as its own restore
     * transaction, which bounds temporary disk use however large the library is.
     */
    internal fun chunkRestores(
        plan: List<RecordingRestorePlan>,
        maxChunkBytes: Long = DriveSyncService.MAX_SYNC_RECORDING_BATCH_BYTES
    ): List<List<RecordingRestorePlan>> {
        val chunks = mutableListOf<List<RecordingRestorePlan>>()
        var current = mutableListOf<RecordingRestorePlan>()
        var currentBytes = 0L
        for (restore in plan) {
            val size = restore.entry.sizeBytes
            if (size < 0L || size > maxChunkBytes) {
                throw DriveNetworkException("Recording transfer exceeds the allowed size")
            }
            if (current.isNotEmpty() && size > maxChunkBytes - currentBytes) {
                chunks.add(current)
                current = mutableListOf()
                currentBytes = 0L
            }
            current.add(restore)
            currentBytes += size
        }
        if (current.isNotEmpty()) chunks.add(current)
        return chunks
    }
}

object RecordingFileStore {
    internal const val RESTORE_STAGE_PREFIX = ".recording-restore-"
    private const val JOURNAL_FILE = "restore-journal"
    private const val COMPLETE_FILE = "restore-complete"
    private const val JOURNAL_MAGIC = 0x5248594D
    private const val JOURNAL_VERSION = 1
    private const val MAX_JOURNAL_ENTRIES = 10_000

    internal data class StagedRecording(
        val entry: RecordingManifestEntry,
        val file: File
    )

    fun targetFile(filesDir: File, projectId: String, fileName: String): File =
        RecordingFiles.memoFile(filesDir, projectId, fileName)

    fun writeAtomically(filesDir: File, entry: RecordingManifestEntry, bytes: ByteArray) {
        val target = targetFile(filesDir, entry.projectId, entry.fileName)
        val dir = target.parentFile
            ?: throw DriveNetworkException("Recording ${entry.fileName} has no parent directory")
        if (!dir.exists() && !dir.mkdirs()) {
            throw DriveNetworkException("Could not create memo directory for ${entry.projectId}")
        }

        val temp = Files.createTempFile(dir.toPath(), ".sync-", ".tmp").toFile()
        try {
            temp.writeBytes(bytes)
            if (temp.length() != entry.sizeBytes || sha256Hex(temp) != entry.sha256) {
                throw DriveNetworkException("Recording ${entry.fileName} failed integrity verification")
            }
            Files.move(
                temp.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE
            )
            if (entry.modifiedAt > 0L) target.setLastModified(entry.modifiedAt)
        } finally {
            if (temp.exists()) temp.delete()
        }
    }

    internal fun stageRestore(
        stageDirectory: File,
        index: Int,
        entry: RecordingManifestEntry,
        bytes: ByteArray
    ): StagedRecording {
        val staged = File(stageDirectory, "recording-$index.tmp")
        staged.writeBytes(bytes)
        if (staged.length() != entry.sizeBytes || sha256Hex(staged) != entry.sha256) {
            throw DriveNetworkException("Recording ${entry.fileName} failed integrity verification")
        }
        return StagedRecording(entry, staged)
    }

    internal fun recoverInterruptedRestores(filesDir: File) {
        filesDir.listFiles()
            ?.filter { it.isDirectory && it.name.startsWith(RESTORE_STAGE_PREFIX) }
            ?.forEach { stageDirectory ->
                val journal = File(stageDirectory, JOURNAL_FILE)
                val complete = File(stageDirectory, COMPLETE_FILE)
                when {
                    complete.exists() -> stageDirectory.deleteRecursively()
                    journal.exists() -> rollbackRestoreTransaction(filesDir, stageDirectory)
                    else -> stageDirectory.deleteRecursively()
                }
                if (stageDirectory.exists()) {
                    throw DriveNetworkException("Interrupted recording restore could not be cleaned up")
                }
            }
    }

    internal fun prepareRestoreTransaction(
        filesDir: File,
        stageDirectory: File,
        staged: List<StagedRecording>
    ) {
        syncDirectory(filesDir)
        val journalEntries = staged.mapIndexed { index, item ->
            val target = targetFile(filesDir, item.entry.projectId, item.entry.fileName)
            val directory = target.parentFile
                ?: throw DriveNetworkException("Recording ${item.entry.fileName} has no parent directory")
            if (!directory.exists() && !directory.mkdirs()) {
                throw DriveNetworkException("Could not create memo directory for ${item.entry.projectId}")
            }
            val hadOriginal = target.exists()
            if (hadOriginal) {
                val backup = File(stageDirectory, "backup-$index.tmp")
                Files.copy(
                    target.toPath(),
                    backup.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.COPY_ATTRIBUTES
                )
                syncFile(backup)
            }
            RestoreJournalEntry(index, item.entry.projectId, item.entry.fileName, hadOriginal)
        }
        syncDirectory(stageDirectory)
        writeJournal(stageDirectory, journalEntries)
    }

    internal fun commitStagedRestores(filesDir: File, staged: List<StagedRecording>) {
        if (staged.isEmpty()) return
        val stageDirectory = staged.first().file.parentFile
            ?: throw DriveNetworkException("Recording restore staging directory is missing")
        if (staged.any { it.file.parentFile != stageDirectory }) {
            throw DriveNetworkException("Recording restore staging files do not share one transaction")
        }
        prepareRestoreTransaction(filesDir, stageDirectory, staged)
        val touchedDirectories = linkedSetOf<File>()
        try {
            for (item in staged) {
                val target = targetFile(filesDir, item.entry.projectId, item.entry.fileName)
                Files.move(
                    item.file.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE
                )
                if (item.entry.modifiedAt > 0L) target.setLastModified(item.entry.modifiedAt)
                syncFile(target)
                target.parentFile?.let(touchedDirectories::add)
            }
            touchedDirectories.forEach(::syncDirectory)
            writeCompletionMarker(stageDirectory)
        } catch (e: Exception) {
            rollbackRestoreTransaction(filesDir, stageDirectory)
            throw DriveNetworkException("Recording restore could not be committed", e)
        }
        stageDirectory.deleteRecursively()
    }

    internal fun hasPreparedRestore(stageDirectory: File): Boolean =
        File(stageDirectory, JOURNAL_FILE).exists()

    private data class RestoreJournalEntry(
        val index: Int,
        val projectId: String,
        val fileName: String,
        val hadOriginal: Boolean
    )

    private fun writeJournal(stageDirectory: File, entries: List<RestoreJournalEntry>) {
        val temp = File(stageDirectory, "$JOURNAL_FILE.tmp")
        val output = FileOutputStream(temp)
        DataOutputStream(output).use { data ->
            data.writeInt(JOURNAL_MAGIC)
            data.writeInt(JOURNAL_VERSION)
            data.writeInt(entries.size)
            entries.forEach { entry ->
                data.writeInt(entry.index)
                data.writeUTF(entry.projectId)
                data.writeUTF(entry.fileName)
                data.writeBoolean(entry.hadOriginal)
            }
            data.flush()
            output.fd.sync()
        }
        Files.move(
            temp.toPath(),
            File(stageDirectory, JOURNAL_FILE).toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE
        )
        syncDirectory(stageDirectory)
    }

    private fun readJournal(stageDirectory: File): List<RestoreJournalEntry> {
        DataInputStream(FileInputStream(File(stageDirectory, JOURNAL_FILE))).use { data ->
            require(data.readInt() == JOURNAL_MAGIC) { "Invalid recording restore journal" }
            require(data.readInt() == JOURNAL_VERSION) { "Unsupported recording restore journal" }
            val count = data.readInt()
            require(count in 0..MAX_JOURNAL_ENTRIES) { "Invalid recording restore journal size" }
            return List(count) {
                RestoreJournalEntry(
                    index = data.readInt(),
                    projectId = data.readUTF(),
                    fileName = data.readUTF(),
                    hadOriginal = data.readBoolean()
                )
            }
        }
    }

    private fun rollbackRestoreTransaction(filesDir: File, stageDirectory: File) {
        try {
            val touchedDirectories = linkedSetOf<File>()
            readJournal(stageDirectory).asReversed().forEach { entry ->
                val target = targetFile(filesDir, entry.projectId, entry.fileName)
                if (entry.hadOriginal) {
                    val backup = File(stageDirectory, "backup-${entry.index}.tmp")
                    if (!backup.isFile) throw IOException("Recording restore backup is missing")
                    Files.copy(
                        backup.toPath(),
                        target.toPath(),
                        StandardCopyOption.REPLACE_EXISTING,
                        StandardCopyOption.COPY_ATTRIBUTES
                    )
                    syncFile(target)
                } else {
                    Files.deleteIfExists(target.toPath())
                }
                target.parentFile?.let(touchedDirectories::add)
            }
            touchedDirectories.forEach(::syncDirectory)
            stageDirectory.deleteRecursively()
        } catch (e: Exception) {
            throw DriveNetworkException("Interrupted recording restore could not be recovered", e)
        }
    }

    private fun writeCompletionMarker(stageDirectory: File) {
        val temp = File(stageDirectory, "$COMPLETE_FILE.tmp")
        FileOutputStream(temp).use { output ->
            output.write(1)
            output.fd.sync()
        }
        Files.move(
            temp.toPath(),
            File(stageDirectory, COMPLETE_FILE).toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE
        )
        syncDirectory(stageDirectory)
    }

    private fun syncFile(file: File) {
        FileChannel.open(file.toPath(), StandardOpenOption.WRITE).use { channel ->
            channel.force(true)
        }
    }

    private fun syncDirectory(directory: File) {
        FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { channel ->
            channel.force(true)
        }
    }

    fun sha256Hex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString(separator = "") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
    }

    internal fun readForUpload(file: File, entry: RecordingManifestEntry): ByteArray {
        val bytes = file.inputStream().use { input -> input.readBytesBounded(entry.sizeBytes) }
        if (bytes.size.toLong() != entry.sizeBytes) {
            throw DriveNetworkException("Recording ${entry.fileName} changed before upload")
        }
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }
        if (digest != entry.sha256) {
            throw DriveNetworkException("Recording ${entry.fileName} changed before upload")
        }
        return bytes
    }
}

/** Tombstoned recordings are deletions, not size skips. */
internal fun skippedLargeRecordingCount(
    localRecordings: List<RecordingManifestEntry>,
    merged: SyncBlob
): Int = RecordingSyncPlanner.countSkippedAsTooLarge(
    local = recordingsAllowedForUpload(localRecordings, emptyList(), merged.deletions),
    manifest = merged.recordings
)

internal data class LocalRecordingFile(val entry: RecordingManifestEntry, val file: File)

/** Identity keys (projectId/originalName) of recordings sitting in the local Trash. */
internal fun snapshotTrashedRecordingIdentities(filesDir: File): Set<String> {
    val root = RecordingFiles.trashRoot(filesDir)
    if (!root.exists()) return emptySet()
    return root.listFiles()
        ?.filter { it.isDirectory }
        ?.flatMap { projectDir ->
            projectDir.listFiles()
                ?.filter { RecordingFiles.isMemoFile(it) }
                ?.mapNotNull { file -> VoiceMemoService.parseTrashedName(file.name)?.let { "${projectDir.name}/${it.second}" } }
                ?: emptyList()
        }
        ?.toSet()
        ?: emptySet()
}

/** Never turn a pending local deletion into a durable remote recording. */
internal fun snapshotLocalRecordingFiles(
    filesDir: File,
    pendingDeletionIds: Set<String>
): List<LocalRecordingFile> {
    RecordingFileStore.recoverInterruptedRestores(filesDir)
    val root = RecordingFiles.memosRoot(filesDir)
    if (!root.exists()) return emptyList()
    return root.listFiles()
        ?.asSequence()
        ?.filter { it.isDirectory && it.name !in pendingDeletionIds }
        ?.flatMap { projectDir ->
            projectDir.listFiles()
                ?.asSequence()
                ?.filter { RecordingFiles.isMemoFile(it) }
                ?.map { file ->
                    val entry = RecordingManifestEntry(
                        projectId = projectDir.name,
                        fileName = file.name,
                        driveName = RecordingManifestEntry.driveNameFor(projectDir.name, file.name),
                        sizeBytes = file.length(),
                        modifiedAt = file.lastModified(),
                        sha256 = RecordingFileStore.sha256Hex(file)
                    )
                    LocalRecordingFile(entry, file)
                }
                ?: emptySequence()
        }
        ?.sortedWith(compareBy<LocalRecordingFile> { it.entry.projectId }.thenBy { it.entry.fileName })
        ?.toList()
        ?: emptyList()
}


/** Normalizes a pre-v4 passphrase the way it was stored, so it derives the same key. */
internal fun normalizedLegacyPassphraseOrNull(passphrase: String): String? {
    // Trim the same ASCII whitespace set iOS strips (space, tab, CR, LF).
    val trimmed = passphrase.trim { it == ' ' || it == '\t' || it == '\r' || it == '\n' }
    return trimmed.takeIf { it.length >= 8 && it.all { ch -> ch.code in 0x20..0x7E } }
}

/** What a sync does about the older encrypted backup. */
enum class LegacyBackupAction {
    /** Decrypt it, merge it, write v4, verify, then delete it and the passphrase. */
    MIGRATE,

    /** Leave it untouched and offer "Migrate older encrypted backup…". */
    OFFER_MIGRATION,

    /** Nothing to migrate: drop the stored passphrase. */
    FORGET_PASSPHRASE,
    NONE
}

fun decideLegacyBackupAction(legacyBackupExists: Boolean, passphraseAvailable: Boolean): LegacyBackupAction =
    when {
        legacyBackupExists && passphraseAvailable -> LegacyBackupAction.MIGRATE
        legacyBackupExists -> LegacyBackupAction.OFFER_MIGRATION
        passphraseAvailable -> LegacyBackupAction.FORGET_PASSPHRASE
        else -> LegacyBackupAction.NONE
    }

/** Drive appProperties are capped at 124 bytes per key plus value; the manifest stays authoritative. */
internal fun recordingAppProperties(entry: RecordingManifestEntry): Map<String, String> =
    mapOf(
        "projectId" to entry.projectId,
        "fileName" to entry.fileName,
        "sha256" to entry.sha256,
        "bytes" to entry.sizeBytes.toString()
    ).filter { (key, value) -> (key + value).toByteArray(Charsets.UTF_8).size <= 124 }

/**
 * Google Drive backup of the library: plain v4 manifest `rhymeai-manifest.json`
 * plus raw `rec_<projectId>_<fileName>` recordings in `appDataFolder`.
 *
 * - [backUp] merges this device into Drive and leaves local data untouched.
 * - [restore] merges both ways, uploads local-only items, then downloads missing recordings.
 * - [migrateLegacyBackup] moves the older passphrase-encrypted backup into v4.
 *
 * Every call reads the remote manifest first and refuses one that fails its hash
 * ([SyncResult.CorruptRemote]) or comes from a newer version; neither is overwritten.
 */
class DriveSyncService(
    private val filesDir: File,
    private val secureKeyStore: SecureKeyStore,
    private val driveClient: DriveClient,
    private val authorizer: DriveAuthorizer,
    private val clientId: () -> String,
    private val now: () -> Long = System::currentTimeMillis
) {
    companion object {
        /** SecureKeyStore entry of the pre-v4 passphrase; only read to migrate, then removed. */
        const val LEGACY_PASSPHRASE_KEY = "DRIVE_SYNC_PASSPHRASE"

        internal const val MAX_SYNC_BLOB_BYTES = 16L * 1024L * 1024L
        internal const val MAX_SYNC_RECORDING_BATCH_BYTES = 64L * 1024L * 1024L
        internal const val MIN_FREE_AFTER_RECORDING_RESTORE_BYTES = 128L * 1024L * 1024L
        private const val MAX_MANIFEST_WRITE_ATTEMPTS = 3
        private val legacyJson = Json { ignoreUnknownKeys = true }
    }

    private enum class Mode { BACKUP, RESTORE, MIGRATE }

    private class PushOutcome(val committed: SyncBlob, val skippedLarge: Int, val damaged: Int)

    suspend fun backUp(repository: ProjectRepository): SyncResult = run(repository, Mode.BACKUP, null)

    suspend fun restore(repository: ProjectRepository): SyncResult = run(repository, Mode.RESTORE, null)

    /** Runs the migration with a passphrase the user typed once; it is never stored. */
    suspend fun migrateLegacyBackup(repository: ProjectRepository, passphrase: String): SyncResult {
        val normalized = normalizedLegacyPassphraseOrNull(passphrase) ?: return SyncResult.WrongPassphrase
        return run(repository, Mode.MIGRATE, normalized.toCharArray())
    }

    fun hasLegacyPassphrase(): Boolean = secureKeyStore.getKey(LEGACY_PASSPHRASE_KEY).isNotEmpty()

    /** Reads what Drive holds without changing anything (first-run restore offer). */
    suspend fun probe(): ProbeResult = withContext(Dispatchers.IO) {
        guarded({ ProbeResult.Failed(it) }) {
            val token = when (val auth = authorizer.authorize()) {
                is DriveAuthorization.Granted -> auth.accessToken
                is DriveAuthorization.NeedsConsent -> return@guarded ProbeResult.Failed(SyncResult.AuthorizationRequired(auth.pendingIntent))
                DriveAuthorization.Unavailable -> return@guarded ProbeResult.Failed(SyncResult.NotConfigured)
            }
            val remote = driveClient.findFileByName(token, BackupManifest.FILE_NAME)?.let {
                BackupManifest.decode(driveClient.downloadFile(token, it.id, MAX_SYNC_BLOB_BYTES))
            }
            val legacy = driveClient.findFileByName(token, SyncBlob.DRIVE_FILE_NAME) != null
            ProbeResult.Ready(BackupProbe(remote?.projects?.size ?: 0, remote?.recordings?.size ?: 0, legacy))
        }
    }

    /**
     * Revokes the Drive grant at Google with the current access token, then drops
     * the cached token. Returns false when Google could not be reached; the caller
     * clears local state either way.
     */
    suspend fun disconnect(): Boolean = withContext(Dispatchers.IO) {
        val token = (authorizer.authorize() as? DriveAuthorization.Granted)?.accessToken
            ?: return@withContext true
        val revoked = try {
            driveClient.revokeToken(token)
            true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            false
        }
        authorizer.forget(token)
        revoked
    }

    private suspend fun run(repository: ProjectRepository, mode: Mode, typedPassphrase: CharArray?): SyncResult =
        withContext(Dispatchers.IO) {
            guarded({ it }) {
                val token = when (val auth = authorizer.authorize()) {
                    is DriveAuthorization.Granted -> auth.accessToken
                    is DriveAuthorization.NeedsConsent -> return@guarded SyncResult.AuthorizationRequired(auth.pendingIntent)
                    DriveAuthorization.Unavailable -> return@guarded SyncResult.NotConfigured
                }
                val legacyFile = driveClient.findFileByName(token, SyncBlob.DRIVE_FILE_NAME)
                val storedPassphrase = secureKeyStore.getKey(LEGACY_PASSPHRASE_KEY)
                val passphrase = typedPassphrase ?: storedPassphrase.takeIf { it.isNotEmpty() }?.toCharArray()
                var legacy: SyncBlob? = null
                var legacyDamaged = 0
                when (decideLegacyBackupAction(legacyFile != null, passphrase != null)) {
                    LegacyBackupAction.MIGRATE -> {
                        legacy = openLegacyManifest(token, legacyFile!!, passphrase!!)
                        if (legacy == null && typedPassphrase != null) return@guarded SyncResult.WrongPassphrase
                        if (legacy != null) legacyDamaged = restoreLegacyRecordings(token, repository, legacy, passphrase)
                    }
                    LegacyBackupAction.FORGET_PASSPHRASE -> if (storedPassphrase.isNotEmpty()) {
                        secureKeyStore.removeKey(LEGACY_PASSPHRASE_KEY)
                    }
                    LegacyBackupAction.OFFER_MIGRATION, LegacyBackupAction.NONE -> Unit
                }

                val outcome = pushMerge(
                    token = token,
                    repository = repository,
                    applyLocally = mode == Mode.RESTORE || legacy != null,
                    extraRemote = legacy?.copy(recordings = emptyList()),
                    requireRemote = mode == Mode.RESTORE
                ) ?: return@guarded SyncResult.NoBackup

                var migrated = false
                if (legacy != null) {
                    verifyAndRemoveLegacy(token, legacyFile!!, legacy, outcome.committed)
                    secureKeyStore.removeKey(LEGACY_PASSPHRASE_KEY)
                    migrated = true
                }
                SyncResult.Success(
                    merged = outcome.committed,
                    skippedLargeRecordings = outcome.skippedLarge,
                    damagedRecordings = outcome.damaged + legacyDamaged,
                    legacyBackupPresent = legacyFile != null && !migrated,
                    migratedLegacyBackup = migrated
                )
            }
        }

    private suspend fun <T> guarded(onFailure: (SyncResult) -> T, block: suspend () -> T): T =
        try {
            block()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: DamagedBackupException) {
            onFailure(SyncResult.CorruptRemote)
        } catch (_: UnsupportedBackupVersionException) {
            onFailure(SyncResult.UnsupportedVersion)
        } catch (_: DriveAuthException) {
            onFailure(SyncResult.NetworkError("Drive authorization expired — tap Back up now to sign in again."))
        } catch (e: DriveNetworkException) {
            onFailure(SyncResult.NetworkError(e.message ?: "Drive request failed — check your connection."))
        } catch (_: IOException) {
            onFailure(SyncResult.NetworkError("Drive backup failed — check your connection."))
        } catch (e: Exception) {
            onFailure(SyncResult.UnknownError(e))
        }

    /**
     * Merge local into the Drive manifest and write it. With [applyLocally] the
     * merged library is also committed here and missing recordings downloaded.
     * Returns null only when [requireRemote] and Drive holds no backup.
     */
    private suspend fun pushMerge(
        token: String,
        repository: ProjectRepository,
        applyLocally: Boolean,
        extraRemote: SyncBlob?,
        requireRemote: Boolean
    ): PushOutcome? {
        repeat(MAX_MANIFEST_WRITE_ATTEMPTS) {
            val base = repository.snapshotLocalSyncBase()
            val localFiles = snapshotLocalRecordingFiles(filesDir, base.pendingIds)
            val localRecordings = localFiles.map { it.entry }
            val local = base.blob.copy(
                recordings = recordingsAllowedForUpload(localRecordings, base.blob.deletions, emptyList())
                    .filter { it.isTransferable },
                savedByClientId = clientId()
            )
            val metadata = driveClient.findFileByName(token, BackupManifest.FILE_NAME)
            val remote = metadata?.let {
                BackupManifest.decode(driveClient.downloadFile(token, it.id, MAX_SYNC_BLOB_BYTES))
            }
            if (requireRemote && remote == null && extraRemote == null) return null

            var merged = SyncMerger.merge(local, remote ?: SyncBlob())
            if (extraRemote != null) merged = SyncMerger.merge(merged, extraRemote)
            val driveFiles = driveClient.listFilesByNamePrefix(token, BackupManifest.RECORDING_PREFIX)
                .associate { it.name to it.id }
            // A listed recording whose raw file never reached Drive takes this device's copy.
            val localByIdentity = local.recordings.associateBy { it.identityKey }
            merged = merged.copy(
                recordings = merged.recordings.map { entry ->
                    val mine = localByIdentity[entry.identityKey]
                    val missing = BackupManifest.recordingDriveName(entry.projectId, entry.fileName) !in driveFiles
                    if (mine != null && missing) mine else entry
                }
            )

            val uploaded = HashMap<String, String>()
            val filesByIdentity = localFiles.associateBy { it.entry.identityKey }
            for (entry in RecordingSyncPlanner.planUploads(local.recordings, merged.recordings, driveFiles.keys)) {
                val file = filesByIdentity.getValue(entry.identityKey).file
                val name = BackupManifest.recordingDriveName(entry.projectId, entry.fileName)
                uploaded[name] = driveClient.uploadNewFile(
                    token, name, BackupManifest.RECORDING_MIME_TYPE,
                    RecordingFileStore.readForUpload(file, entry), recordingAppProperties(entry)
                )
            }

            // Another device wrote the manifest meanwhile: merge again rather than overwrite it.
            if (!sameDriveVersion(metadata, driveClient.findFileByName(token, BackupManifest.FILE_NAME))) {
                return@repeat
            }
            val bytes = BackupManifest.encode(merged, now(), clientId())
            if (bytes.size > MAX_SYNC_BLOB_BYTES) throw DriveNetworkException("Drive backup exceeds the allowed size")
            if (metadata != null) {
                driveClient.updateFile(token, metadata.id, BackupManifest.MIME_TYPE, bytes)
            } else {
                driveClient.uploadNewFile(token, BackupManifest.FILE_NAME, BackupManifest.MIME_TYPE, bytes)
            }

            var damaged = 0
            var committed = merged
            if (applyLocally) {
                damaged = restoreRemoteRecordings(token, merged.recordings, driveFiles + uploaded, localRecordings)
                committed = repository.applySyncResult(merged, base)
            }
            return PushOutcome(committed, skippedLargeRecordingCount(localRecordings, merged), damaged)
        }
        throw DriveNetworkException("Drive backup kept changing during upload — try again.")
    }

    /** Null when the passphrase does not open it; throws [DamagedBackupException] when it opens but cannot be read. */
    private suspend fun openLegacyManifest(token: String, file: DriveFileMetadata, passphrase: CharArray): SyncBlob? {
        val envelope = driveClient.downloadFile(token, file.id, MAX_SYNC_BLOB_BYTES)
        val opened = try {
            SyncBlobCrypto.openManifest(envelope, passphrase)
        } catch (e: SyncBlobFormatException) {
            throw DamagedBackupException(e)
        } catch (_: SyncBlobSealException) {
            return null
        }
        val blob = try {
            legacyJson.decodeFromString<SyncBlob>(opened.plaintext.toString(Charsets.UTF_8))
        } catch (e: Exception) {
            throw DamagedBackupException(e)
        }
        if (blob.version != opened.version) throw DamagedBackupException()
        return blob
    }

    /**
     * Decrypts the RAI1 recordings this device lacks into local storage so the v4
     * upload carries them. Returns how many failed decryption or their hash.
     */
    private suspend fun restoreLegacyRecordings(
        token: String,
        repository: ProjectRepository,
        legacy: SyncBlob,
        passphrase: CharArray
    ): Int {
        val base = repository.snapshotLocalSyncBase()
        val local = snapshotLocalRecordingFiles(filesDir, base.pendingIds).mapTo(HashSet()) { it.entry.identityKey }
        val trashed = snapshotTrashedRecordingIdentities(filesDir)
        val driveFiles = driveClient.listFilesByNamePrefix(token, RecordingManifestEntry.DRIVE_PREFIX)
            .associate { it.name to it.id }
        var damaged = 0
        val wanted = recordingsAllowedForUpload(legacy.recordings, base.blob.deletions, legacy.deletions)
            .filter { it.isTransferable && it.identityKey !in local && it.identityKey !in trashed }
        for (entry in wanted) {
            val fileId = driveFiles[entry.driveName] ?: continue
            val envelope = driveClient.downloadFile(token, fileId, SyncBlobCrypto.envelopeSizeForPlaintext(entry.sizeBytes))
            val plaintext = try {
                SyncBlobCrypto.open(envelope, passphrase)
            } catch (_: SyncBlobSealException) {
                damaged++
                continue
            }
            if (plaintext.size.toLong() != entry.sizeBytes || BackupManifest.sha256Hex(plaintext) != entry.sha256) {
                damaged++
                continue
            }
            RecordingFileStore.writeAtomically(filesDir, entry, plaintext)
        }
        return damaged
    }

    /**
     * Download the new manifest and check its hash and contents before deleting
     * the older backup. Encrypted recordings that did not reach the new backup
     * (too large or unreadable here) are left in Drive rather than destroyed.
     */
    private suspend fun verifyAndRemoveLegacy(
        token: String,
        legacyFile: DriveFileMetadata,
        legacy: SyncBlob,
        expected: SyncBlob
    ) {
        val written = driveClient.findFileByName(token, BackupManifest.FILE_NAME)
            ?.let { BackupManifest.decode(driveClient.downloadFile(token, it.id, MAX_SYNC_BLOB_BYTES)) }
            ?: throw DriveNetworkException("The new backup could not be verified; the older backup was kept.")
        val writtenIds = (written.projects.map { it.id } + written.trashed.map { it.project.id }).toSet()
        val expectedIds = (expected.projects.map { it.id } + expected.trashed.map { it.project.id }).toSet()
        if (!writtenIds.containsAll(expectedIds)) {
            throw DriveNetworkException("The new backup could not be verified; the older backup was kept.")
        }
        val v4Names = driveClient.listFilesByNamePrefix(token, BackupManifest.RECORDING_PREFIX).mapTo(HashSet()) { it.name }
        val writtenRecordings = written.recordings.filter {
            BackupManifest.recordingDriveName(it.projectId, it.fileName) in v4Names
        }.mapTo(HashSet()) { it.identityKey }
        val deletedProjects = written.deletions.filter { it.fileName == null }.mapTo(HashSet()) { it.projectId }
        val deletedFiles = written.deletions.filter { it.fileName != null }.mapTo(HashSet()) { "${it.projectId}/${it.fileName}" }
        val migratedLegacyNames = legacy.recordings.filter {
            it.identityKey in writtenRecordings || it.projectId in deletedProjects || it.identityKey in deletedFiles
        }.mapTo(HashSet()) { it.driveName }
        driveClient.listFilesByNamePrefix(token, RecordingManifestEntry.DRIVE_PREFIX)
            .filter { it.name in migratedLegacyNames }
            .forEach { driveClient.deleteFile(token, it.id) }
        driveClient.deleteFile(token, legacyFile.id)
    }

    private fun sameDriveVersion(left: DriveFileMetadata?, right: DriveFileMetadata?): Boolean =
        left?.id == right?.id &&
            left?.modifiedTime == right?.modifiedTime &&
            left?.version == right?.version

    /** Returns how many downloads were discarded because their bytes did not match the manifest. */
    private suspend fun restoreRemoteRecordings(
        token: String,
        remoteManifest: List<RecordingManifestEntry>,
        remoteFilesByName: Map<String, String>,
        localManifest: List<RecordingManifestEntry>
    ): Int {
        val plan = RecordingSyncPlanner.planRestores(
            local = localManifest,
            remoteManifest = remoteManifest,
            remoteFilesByName = remoteFilesByName,
            locallyTrashed = snapshotTrashedRecordingIdentities(filesDir)
        )
        if (plan.isEmpty()) return 0
        val restoreBytes = requireTransferableRecordings(plan.map { it.entry })
        val requiredFreeBytes = try {
            Math.addExact(restoreBytes, MIN_FREE_AFTER_RECORDING_RESTORE_BYTES)
        } catch (e: ArithmeticException) {
            throw DriveNetworkException("Recording transfer exceeds the allowed size", e)
        }
        if (filesDir.usableSpace < requiredFreeBytes) {
            throw DriveNetworkException("Not enough storage to restore recordings safely")
        }

        // Each chunk is its own transaction. A failure leaves earlier chunks
        // committed; the next restore plans only what is still missing.
        var damaged = 0
        for (chunk in RecordingSyncPlanner.chunkRestores(plan)) {
            damaged += restoreRecordingChunk(token, chunk)
        }
        return damaged
    }

    private suspend fun restoreRecordingChunk(token: String, chunk: List<RecordingRestorePlan>): Int {
        val stageDirectory = Files.createTempDirectory(filesDir.toPath(), RecordingFileStore.RESTORE_STAGE_PREFIX).toFile()
        var damaged = 0
        try {
            val staged = chunk.mapIndexedNotNull { index, restore ->
                val bytes = driveClient.downloadFile(token, restore.remoteFileId, restore.entry.sizeBytes)
                if (bytes.size.toLong() != restore.entry.sizeBytes || BackupManifest.sha256Hex(bytes) != restore.entry.sha256) {
                    damaged++
                    return@mapIndexedNotNull null
                }
                RecordingFileStore.stageRestore(stageDirectory, index, restore.entry, bytes)
            }
            RecordingFileStore.commitStagedRestores(filesDir, staged)
        } catch (e: Exception) {
            if (!RecordingFileStore.hasPreparedRestore(stageDirectory)) stageDirectory.deleteRecursively()
            throw e
        }
        if (stageDirectory.exists() && !RecordingFileStore.hasPreparedRestore(stageDirectory)) stageDirectory.deleteRecursively()
        return damaged
    }
}
