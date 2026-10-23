package com.rhymeai.app.data.sync

import android.app.PendingIntent
import android.content.Context
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.SecureKeyStore
import com.rhymeai.app.data.recording.RecordingCatalog
import com.rhymeai.app.data.recording.RecordingFiles
import com.rhymeai.app.data.recording.RecordingTransitions
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
import java.io.InputStream
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
        val migratedLegacyBackup: Boolean = false,
        val unmovedLegacySongs: Int = 0,
        val unmovedLegacyRecordings: Int = 0
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
    val version: String? = null,
    val appProperties: Map<String, String> = emptyMap()
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
    suspend fun updateFile(
        accessToken: String,
        fileId: String,
        mimeType: String,
        content: ByteArray,
        appProperties: Map<String, String> = emptyMap()
    )
    suspend fun deleteFile(accessToken: String, fileId: String)

    /** Revokes the grant behind [token] at Google (`oauth2.googleapis.com/revoke`). */
    suspend fun revokeToken(token: String)
}

/**
 * Production [DriveClient] over plain HttpURLConnection, the idiom AIService
 * already uses, so the app needs no Google API client library.
 */
class RealDriveClient internal constructor(
    private val driveBase: String,
    private val uploadBase: String,
    private val revokeUrl: String
) : DriveClient {
    constructor() : this(
        "https://www.googleapis.com/drive/v3",
        "https://www.googleapis.com/upload/drive/v3",
        "https://oauth2.googleapis.com/revoke"
    )


    private companion object {
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
                val conn = openRequest("$driveBase/files/$fileId?alt=media", "GET", accessToken)
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
            val conn = openMultipart("$uploadBase/files?uploadType=multipart&fields=id", "POST", accessToken)
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
        content: ByteArray,
        appProperties: Map<String, String>
    ) = withContext(Dispatchers.IO) {
        mapIoFailure("Drive update") {
            val metadata = buildJsonObject {
                put("mimeType", mimeType)
                if (appProperties.isNotEmpty()) {
                    putJsonObject("appProperties") { appProperties.forEach { (key, value) -> put(key, value) } }
                }
            }.toString()
            val body = buildMultipart(metadata.toByteArray(Charsets.UTF_8), mimeType, content)
            val conn = openMultipart("$uploadBase/files/$fileId?uploadType=multipart", "PATCH", accessToken)
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
            val conn = openRequest("$driveBase/files/$fileId", "DELETE", accessToken)
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
            val conn = URL(revokeUrl).openConnection() as HttpURLConnection
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
            val url = "$driveBase/files?spaces=appDataFolder&pageSize=1000" +
                "&fields=nextPageToken,files(id,name,modifiedTime,version,appProperties)&q=$encodedQuery$page"
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
                version = obj["version"]?.jsonPrimitive?.content,
                appProperties = (obj["appProperties"] as? kotlinx.serialization.json.JsonObject)
                    ?.mapValues { it.value.jsonPrimitive.content }
                    .orEmpty()
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
    // Tombstones apply by timestamp precedence, as in SyncMerger.
    val tombstones = SyncMerger.Tombstones(SyncMerger.mergeDeletions(localDeletions + remoteDeletions))
    return recordings.filterNot(tombstones::removes)
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
                BackupManifest.recordingDriveName(entry.id) !in remoteDriveNames
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
            val remoteFileId = remoteFilesByName[BackupManifest.recordingDriveName(remoteEntry.id)] ?: return@mapNotNull null
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

    internal data class StagedRecording(
        val entry: RecordingManifestEntry,
        val file: File
    )

    fun targetFile(filesDir: File, projectId: String, fileName: String): File =
        RecordingFiles.memoFile(filesDir, projectId, fileName)

    /**
     * Stages a verified recording from an archive or backup and publishes it under its
     * id with its own precedence time; a name taken by another recording gets a free
     * variant, and nothing in place is replaced. Returns false when this device already
     * holds that recording id.
     */
    internal suspend fun importVerified(
        catalog: RecordingCatalog?,
        filesDir: File,
        entry: RecordingManifestEntry,
        bytes: ByteArray,
        origin: String
    ): Boolean {
        val stage = Files.createTempDirectory(filesDir.toPath(), RESTORE_STAGE_PREFIX).toFile()
        try {
            val staged = stageRestore(stage, 0, entry, bytes)
            syncFile(staged.file)
            return RecordingTransitions.publish(
                catalog, filesDir, staged.file, entry.projectId, entry.fileName, entry.id, entry.precedenceTime, origin,
                skipIfPresent = true
            ) != null
        } finally {
            stage.deleteRecursively()
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

    /**
     * A staging folder left by an interrupted restore holds only downloaded temp
     * files; every recording already moved into place is complete and verified, so
     * recovery just removes the folder and never touches a memo.
     */
    internal fun recoverInterruptedRestores(filesDir: File) {
        filesDir.listFiles()
            ?.filter { it.isDirectory && it.name.startsWith(RESTORE_STAGE_PREFIX) }
            ?.forEach { stageDirectory ->
                if (!stageDirectory.deleteRecursively()) {
                    throw DriveNetworkException("Interrupted recording restore could not be cleaned up")
                }
            }
    }

    /**
     * Publishes each verified download with its record (the backup entry's id and
     * time). A recording this device already holds is skipped; a name taken by a
     * different recording gets a free variant, so nothing in place is ever replaced
     * and a failure part-way leaves only complete recordings. Returns those placed.
     */
    internal suspend fun commitStagedRestores(
        catalog: RecordingCatalog?,
        filesDir: File,
        staged: List<StagedRecording>,
        origin: String = RecordingRecord.RESTORED
    ): List<RecordingManifestEntry> {
        if (staged.isEmpty()) return emptyList()
        val placed = mutableListOf<RecordingManifestEntry>()
        for (item in staged) {
            if (item.entry.modifiedAt > 0L) item.file.setLastModified(item.entry.modifiedAt)
            syncFile(item.file)
            val target = RecordingTransitions.publish(
                catalog, filesDir, item.file, item.entry.projectId, item.entry.fileName, item.entry.id,
                item.entry.precedenceTime, origin, skipIfPresent = true
            ) ?: continue
            target.parentFile?.let(::syncDirectory)
            placed += item.entry
        }
        staged.first().file.parentFile?.deleteRecursively()
        return placed
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

/**
 * A28: after Restore or Import commits, a recording whose winning tombstone is now
 * known here leaves the library: its bytes move to quarantine and its record goes.
 */
internal suspend fun quarantineDeletedRecordings(repository: ProjectRepository, filesDir: File) {
    val base = repository.snapshotLocalSyncBase()
    RecordingTransitions.quarantineDeleted(repository, filesDir, base.blob.deletions, base.pendingIds)
}

internal data class LocalRecordingFile(val entry: RecordingManifestEntry, val file: File, val inTrash: Boolean = false)


/**
 * Live and Trash recordings with their records (A20/A21): ids, display names and
 * stored precedence times. See [RecordingTransitions.snapshot].
 */
internal suspend fun snapshotLocalRecordings(
    catalog: RecordingCatalog,
    filesDir: File,
    pendingDeletionIds: Set<String>
): List<LocalRecordingFile> = RecordingTransitions.snapshot(catalog, filesDir, pendingDeletionIds)



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
        "id" to entry.id,
        "projectId" to entry.projectId,
        "fileName" to entry.fileName,
        "sha256" to entry.sha256,
        "bytes" to entry.sizeBytes.toString()
    ).filter { (key, value) -> (key + value).toByteArray(Charsets.UTF_8).size <= 124 }

/**
 * Google Drive backup of the library: plain v4 manifest `rhymeai-manifest.json`
 * plus raw `rec_<projectId>_<fileName>` recordings in `appDataFolder`.
 *
 * - [backUp] merges this device into Drive and never changes local data.
 * - [restore] merges both ways, uploads local-only items, then fills missing recordings.
 * - The older passphrase-encrypted backup is merged into Drive (never into this
 *   device) and removed only once every song and recording in it is verified there.
 *
 * Every manifest write is read back and its hash compared; a mismatch means another
 * device wrote in between, so the run merges again (up to three times).
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
        const val CONFLICT_MESSAGE = "Backup conflict, will retry"

        internal const val MAX_SYNC_BLOB_BYTES = 16L * 1024L * 1024L
        internal const val MAX_SYNC_RECORDING_BATCH_BYTES = 64L * 1024L * 1024L
        internal const val MIN_FREE_AFTER_RECORDING_RESTORE_BYTES = 128L * 1024L * 1024L
        private const val MAX_MANIFEST_WRITE_ATTEMPTS = 3
        private val legacyJson = Json { ignoreUnknownKeys = true }
    }

    private enum class Mode { BACKUP, RESTORE, MIGRATE }

    private class PushOutcome(
        val written: SyncBlob,
        val committed: SyncBlob,
        val skippedLarge: Int,
        val damaged: Int
    )

    /** All manifests named [BackupManifest.FILE_NAME]: the newest is kept, the rest merged in and removed. */
    private class RemoteState(
        val primary: DriveFileMetadata?,
        val duplicates: List<DriveFileMetadata>,
        val blob: SyncBlob?
    ) {
        val versions: Set<Triple<String, String?, String?>>
            get() = (listOfNotNull(primary) + duplicates).mapTo(HashSet()) { Triple(it.id, it.version, it.modifiedTime) }
    }

    private suspend fun manifestVersions(token: String): Set<Triple<String, String?, String?>> =
        driveClient.listFilesByNamePrefix(token, BackupManifest.FILE_NAME)
            .filter { it.name == BackupManifest.FILE_NAME }
            .mapTo(HashSet()) { Triple(it.id, it.version, it.modifiedTime) }

    private class LegacyMove(val moved: Set<String>, val damaged: Int)

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
            val remote = readRemote(token).blob?.let(SyncMerger::resolve)
            val legacy = driveClient.findFileByName(token, SyncBlob.DRIVE_FILE_NAME) != null
            ProbeResult.Ready(BackupProbe(remote?.projects?.size ?: 0, remote?.recordings?.size ?: 0, legacy))
        }
    }

    /**
     * Revokes the Drive grant at Google with the current access token, then drops
     * the cached token. True only when the revoke call succeeded; without a token
     * or when Google could not be reached it is false. The caller clears local
     * state either way.
     */
    suspend fun disconnect(): Boolean = withContext(Dispatchers.IO) {
        val token = try {
            (authorizer.authorize() as? DriveAuthorization.Granted)?.accessToken
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        } ?: return@withContext false
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
                // Only Restore may touch local recordings, so only it finishes an interrupted restore.
                if (mode == Mode.RESTORE) RecordingFileStore.recoverInterruptedRestores(filesDir)
                val legacyFile = driveClient.findFileByName(token, SyncBlob.DRIVE_FILE_NAME)
                val storedPassphrase = secureKeyStore.getKey(LEGACY_PASSPHRASE_KEY)
                val passphrase = typedPassphrase ?: storedPassphrase.takeIf { it.isNotEmpty() }?.toCharArray()
                var legacy: SyncBlob? = null
                var move: LegacyMove? = null
                when (decideLegacyBackupAction(legacyFile != null, passphrase != null)) {
                    LegacyBackupAction.MIGRATE -> {
                        legacy = openLegacyManifest(token, legacyFile!!, passphrase!!)
                        if (legacy == null && typedPassphrase != null) return@guarded SyncResult.WrongPassphrase
                        if (legacy != null) move = moveLegacyRecordings(token, legacy, passphrase)
                    }
                    LegacyBackupAction.FORGET_PASSPHRASE -> if (storedPassphrase.isNotEmpty()) {
                        secureKeyStore.removeKey(LEGACY_PASSPHRASE_KEY)
                    }
                    LegacyBackupAction.OFFER_MIGRATION, LegacyBackupAction.NONE -> Unit
                }

                // Migration merges into Drive only; this device changes only on Restore.
                val outcome = pushMerge(
                    token = token,
                    repository = repository,
                    applyLocally = mode == Mode.RESTORE,
                    // Every older recording, with its original time, joins the gathered inputs so
                    // tombstones resolve against all of them at once.
                    extraRemote = legacy?.let(::legacyInputs),
                    requireRemote = mode == Mode.RESTORE,
                    unlistable = legacy?.recordings.orEmpty().map { it.identityKey }.filterNot { it in move?.moved.orEmpty() }.toSet()
                ) ?: return@guarded SyncResult.NoBackup

                var migrated = false
                var unmovedSongs = 0
                var unmovedRecordings = 0
                if (legacy != null && move != null) {
                    unmovedSongs = unpreservedLegacySongs(legacy, outcome.written)
                    unmovedRecordings = unverifiedLegacyRecordings(token, legacy, outcome.written)
                    if (unmovedSongs == 0 && unmovedRecordings == 0) {
                        removeLegacyBackup(token, legacyFile!!, legacy)
                        secureKeyStore.removeKey(LEGACY_PASSPHRASE_KEY)
                        migrated = true
                    }
                }
                SyncResult.Success(
                    merged = outcome.committed,
                    skippedLargeRecordings = outcome.skippedLarge,
                    damagedRecordings = outcome.damaged + (move?.damaged ?: 0),
                    legacyBackupPresent = legacyFile != null && !migrated,
                    migratedLegacyBackup = migrated,
                    unmovedLegacySongs = unmovedSongs,
                    unmovedLegacyRecordings = unmovedRecordings
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

    private suspend fun readRemote(token: String): RemoteState {
        val files = driveClient.listFilesByNamePrefix(token, BackupManifest.FILE_NAME)
            .filter { it.name == BackupManifest.FILE_NAME }
            .sortedBy { it.modifiedTime ?: "" }
        if (files.isEmpty()) return RemoteState(null, emptyList(), null)
        // Gathered, not resolved: oldest first, so the newest manifest's recording entries win.
        val blob = SyncMerger.gather(
            *files.map { BackupManifest.decode(driveClient.downloadFile(token, it.id, MAX_SYNC_BLOB_BYTES)) }.toTypedArray()
        )
        return RemoteState(files.last(), files.dropLast(1), blob)
    }

    /**
     * Merge local into the Drive manifest, write it, and read it back. With
     * [applyLocally] the merged library is also committed here and missing
     * recordings downloaded. Returns null only when [requireRemote] and Drive
     * holds no backup.
     */
    private suspend fun pushMerge(
        token: String,
        repository: ProjectRepository,
        applyLocally: Boolean,
        extraRemote: SyncBlob?,
        requireRemote: Boolean,
        unlistable: Set<String> = emptySet()
    ): PushOutcome? {
        // Every input seen by an earlier attempt (its local, remote and any conflicting
        // read-back) is carried forward unresolved, so nothing seen once is dropped.
        var seen: SyncBlob? = null
        repeat(MAX_MANIFEST_WRITE_ATTEMPTS) {
            val base = repository.snapshotLocalSyncBase()
            val localFiles = snapshotLocalRecordings(repository, filesDir, base.pendingIds)
            val liveFiles = localFiles.filterNot { it.inTrash }
            // Live, Trash and oversized recordings all join the inputs (unfiltered by
            // tombstones); resolution decides once, with every input present.
            val local = base.blob.copy(recordings = localFiles.map { it.entry }, savedByClientId = clientId())
            val remote = readRemote(token)
            if (requireRemote && remote.blob == null && extraRemote == null) return null

            val gathered = SyncMerger.gather(*listOfNotNull(seen, local, extraRemote, remote.blob).toTypedArray())
            var merged = SyncMerger.resolve(gathered).copy(savedByClientId = clientId())
            // Evidence that is not uploadable here (Trash, too large, older recordings that
            // could not move) shapes tombstones but is listed only if Drive already lists it.
            val listedRemotely = remote.blob?.recordings.orEmpty().mapTo(HashSet()) { it.id }
            val liveById = liveFiles.associateBy { it.entry.id }
            val uploadableIds = liveFiles.filter { it.entry.isTransferable }.mapTo(HashSet()) { it.entry.id }
            val evidenceOnly = localFiles.filterNot { it.entry.id in uploadableIds }.mapTo(HashSet()) { it.entry.id } +
                (unlistable - uploadableIds)
            merged = merged.copy(
                recordings = merged.recordings
                    .filterNot { it.id in evidenceOnly && it.id !in listedRemotely }
                    // The device holding a recording names it: a rename here travels with the id.
                    .map { entry ->
                        val name = liveById[entry.id]?.entry?.fileName ?: return@map entry
                        entry.copy(fileName = name, driveName = RecordingManifestEntry.driveNameFor(entry.projectId, name))
                    }
            )
            val driveFiles = driveClient.listFilesByNamePrefix(token, BackupManifest.RECORDING_PREFIX)
                .associateBy { it.name }
            // A raw file counts only when its appProperties carry the listed id, hash and size.
            fun onDrive(entry: RecordingManifestEntry): Boolean {
                val file = driveFiles[BackupManifest.recordingDriveName(entry.id)] ?: return false
                return file.appProperties["sha256"] == entry.sha256 && file.appProperties["bytes"] == entry.sizeBytes.toString()
            }

            // Only this device's own bytes for the same id are ever uploaded: no other
            // recording, time or name is substituted for a listed entry.
            val uploaded = HashMap<String, String>()
            val presentNames = merged.recordings.filter(::onDrive).mapTo(HashSet()) { BackupManifest.recordingDriveName(it.id) }
            val uploadable = liveFiles.map { it.entry }.filter { it.isTransferable }
            for (entry in RecordingSyncPlanner.planUploads(uploadable, merged.recordings, presentNames)) {
                val file = liveById.getValue(entry.id).file
                val name = BackupManifest.recordingDriveName(entry.id)
                val bytes = RecordingFileStore.readForUpload(file, entry)
                val stale = driveFiles[name]
                uploaded[name] = if (stale != null) {
                    driveClient.updateFile(token, stale.id, BackupManifest.RECORDING_MIME_TYPE, bytes, recordingAppProperties(entry))
                    stale.id
                } else {
                    driveClient.uploadNewFile(token, name, BackupManifest.RECORDING_MIME_TYPE, bytes, recordingAppProperties(entry))
                }
            }

            val writtenAt = now()
            // Every entry keeps its own precedence time (the stored record, Drive's entry or
            // the older backup's); only an entry with none is stamped with this upload.
            merged = merged.copy(
                recordings = merged.recordings.map { if (it.uploadedAt > 0L) it else it.copy(uploadedAt = writtenAt) }
            )
            val bytes = BackupManifest.encode(merged, writtenAt, clientId())
            if (bytes.size > MAX_SYNC_BLOB_BYTES) throw DriveNetworkException("Drive backup exceeds the allowed size")
            // Another device wrote while recordings uploaded: merge its manifest before writing ours.
            if (manifestVersions(token) != remote.versions) {
                seen = gathered
                return@repeat
            }
            val manifestId = remote.primary?.id?.also {
                driveClient.updateFile(token, it, BackupManifest.MIME_TYPE, bytes)
            } ?: driveClient.uploadNewFile(token, BackupManifest.FILE_NAME, BackupManifest.MIME_TYPE, bytes)

            // Read back: another device may have written between our read and our write.
            val readBack = driveClient.downloadFile(token, manifestId, MAX_SYNC_BLOB_BYTES)
            if (BackupManifest.hashOf(readBack) != BackupManifest.hashOf(bytes)) {
                seen = SyncMerger.gather(gathered, BackupManifest.decode(readBack))
                return@repeat
            }
            remote.duplicates.forEach { driveClient.deleteFile(token, it.id) }

            var damaged = 0
            var committed = merged
            if (applyLocally) {
                damaged = restoreRemoteRecordings(
                    token, repository, merged.recordings, driveFiles.mapValues { it.value.id } + uploaded, localFiles
                )
                // The unresolved inputs go to the transactional apply, which resolves them
                // once more together with what this device holds at commit time.
                committed = repository.applySyncResult(gathered, base)
                quarantineDeletedRecordings(repository, filesDir)
            }
            // A29: a recording too large to move counts as backed up only when its raw Drive
            // object is there with this hash and size; otherwise it is reported as skipped.
            val allowed = recordingsAllowedForUpload(liveFiles.map { it.entry }, emptyList(), merged.deletions)
            // Held here, live or in Trash: not a remote recording this device lacks.
            val heldIds = localFiles.mapTo(HashSet()) { it.entry.id }
            val skipped = allowed.count { !it.isTransferable && !onDrive(it) } +
                merged.recordings.count { !it.isTransferable && it.id !in heldIds }
            return PushOutcome(merged, committed, skipped, damaged)
        }
        throw DriveNetworkException(CONFLICT_MESSAGE)
    }

    /**
     * The older backup as merge input: each recording keeps its derived id and its
     * original time, and each pre-v4 name-only recording tombstone also becomes an id
     * tombstone for the older recordings it names.
     */
    private fun legacyInputs(legacy: SyncBlob): SyncBlob {
        val converted = legacy.recordings.flatMap { entry ->
            legacy.deletions
                .filter { it.recordingId == null && it.fileName == entry.fileName && it.projectId == entry.projectId }
                .map { it to it.copy(recordingId = entry.id) }
        }
        // A name tombstone that names an older recording becomes that recording's id
        // tombstone only; one that names none stays and can match only pre-v4 ids.
        val replaced = converted.mapTo(HashSet()) { it.first }
        return legacy.copy(
            recordings = legacy.recordings.map { it.copy(uploadedAt = it.precedenceTime) },
            deletions = legacy.deletions.filterNot { it in replaced } + converted.map { it.second }
        )
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
     * Decrypts every RAI1 recording of the older backup in memory and uploads it raw,
     * deleted ones included, so nothing in it is lost when it is removed. Nothing is
     * written to this device. Returns the moved recordings that are still live (to
     * list in the manifest) and how many failed decryption or their hash.
     */
    private suspend fun moveLegacyRecordings(
        token: String,
        legacy: SyncBlob,
        passphrase: CharArray
    ): LegacyMove {
        val driveFiles = driveClient.listFilesByNamePrefix(token, RecordingManifestEntry.DRIVE_PREFIX)
            .associateBy { it.name }
        val moved = HashSet<String>()
        var damaged = 0
        for (entry in legacy.recordings) {
            if (!entry.isTransferable) continue
            val name = BackupManifest.recordingDriveName(entry.id)
            val existing = driveFiles[name]
            if (existing == null) {
                val legacyId = driveFiles[entry.driveName]?.id ?: continue
                val envelope = driveClient.downloadFile(token, legacyId, SyncBlobCrypto.envelopeSizeForPlaintext(entry.sizeBytes))
                val plaintext = try {
                    SyncBlobCrypto.open(envelope, passphrase)
                } catch (_: SyncBlobSealException) {
                    null
                }
                if (plaintext == null || plaintext.size.toLong() != entry.sizeBytes || BackupManifest.sha256Hex(plaintext) != entry.sha256) {
                    damaged++
                    continue
                }
                driveClient.uploadNewFile(token, name, BackupManifest.RECORDING_MIME_TYPE, plaintext, recordingAppProperties(entry))
            } else if (existing.appProperties["sha256"] != entry.sha256 || existing.appProperties["bytes"] != entry.sizeBytes.toString()) {
                continue // A different recording holds that name; verification counts it as unmoved.
            }
            moved += entry.identityKey
        }
        return LegacyMove(moved, damaged)
    }

    /**
     * Older songs not carried by the verified manifest: each must be there with the
     * same content, or superseded by a newer edit of the same song (the merge rule),
     * or removed by a newer tombstone.
     */
    private fun unpreservedLegacySongs(legacy: SyncBlob, written: SyncBlob): Int {
        val writtenById = written.projects.associateBy { it.id } + written.trashed.associate { it.project.id to it.project }
        val tombstones = SyncMerger.mergeDeletions(written.deletions + legacy.deletions)
            .filter { it.fileName == null }.associateBy { it.projectId }
        return (legacy.projects + legacy.trashed.map { it.project }).count { old ->
            if (tombstones[old.id]?.let { it.deletedAt > old.updatedAt } == true) return@count false
            val kept = writtenById[old.id] ?: return@count true
            !(kept.updatedAt > old.updatedAt ||
                (kept.updatedAt == old.updatedAt && kept.title == old.title && kept.lyrics == old.lyrics && kept.theme == old.theme))
        }
    }

    /**
     * Every recording of the older backup, deleted ones included, must be a raw file in
     * Drive whose appProperties hash and size match; a live one must also be listed in
     * the written manifest with that hash. Returns how many are not.
     */
    private suspend fun unverifiedLegacyRecordings(token: String, legacy: SyncBlob, written: SyncBlob): Int {
        if (legacy.recordings.isEmpty()) return 0
        val listed = written.recordings.associateBy { it.identityKey }
        val raw = driveClient.listFilesByNamePrefix(token, BackupManifest.RECORDING_PREFIX).associateBy { it.name }
        val live = recordingsAllowedForUpload(legacy.recordings, written.deletions, legacy.deletions)
            .mapTo(HashSet()) { it.identityKey }
        return legacy.recordings.count { entry ->
            val file = raw[BackupManifest.recordingDriveName(entry.id)]
            val rawMatches = file != null && file.appProperties["sha256"] == entry.sha256 &&
                file.appProperties["bytes"] == entry.sizeBytes.toString()
            !rawMatches || (entry.identityKey in live && listed[entry.identityKey]?.sha256 != entry.sha256)
        }
    }

    /** Deletes only encrypted recordings whose raw copy is verified in Drive, then the old manifest. */
    private suspend fun removeLegacyBackup(token: String, legacyFile: DriveFileMetadata, legacy: SyncBlob) {
        val files = driveClient.listFilesByNamePrefix(token, RecordingManifestEntry.DRIVE_PREFIX).associateBy { it.name }
        val moved = legacy.recordings.filter { entry ->
            val raw = files[BackupManifest.recordingDriveName(entry.id)]
            raw != null && raw.appProperties["sha256"] == entry.sha256 && raw.appProperties["bytes"] == entry.sizeBytes.toString()
        }
        if (moved.size != legacy.recordings.size) throw DriveNetworkException("The older backup changed during migration; it was kept.")
        moved.mapNotNull { files[it.driveName] }.forEach { driveClient.deleteFile(token, it.id) }
        driveClient.deleteFile(token, legacyFile.id)
    }

    /** Returns how many downloads were discarded because their bytes did not match the manifest. */
    private suspend fun restoreRemoteRecordings(
        token: String,
        repository: ProjectRepository,
        remoteManifest: List<RecordingManifestEntry>,
        remoteFilesByName: Map<String, String>,
        local: List<LocalRecordingFile>
    ): Int {
        // A recording held here, live or in Trash, is never downloaded again.
        val plan = RecordingSyncPlanner.planRestores(
            local = local.map { it.entry },
            remoteManifest = remoteManifest,
            remoteFilesByName = remoteFilesByName
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
            damaged += restoreRecordingChunk(token, repository, chunk)
        }
        return damaged
    }

    private suspend fun restoreRecordingChunk(token: String, repository: ProjectRepository, chunk: List<RecordingRestorePlan>): Int {
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
            // Published with the entry's id and time; a taken name gets a free variant.
            RecordingFileStore.commitStagedRestores(repository, filesDir, staged)
        } finally {
            stageDirectory.deleteRecursively()
        }
        return damaged
    }
}
