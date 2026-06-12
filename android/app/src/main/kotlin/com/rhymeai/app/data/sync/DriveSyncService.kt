package com.rhymeai.app.data.sync

import android.app.PendingIntent
import android.content.Context
import android.util.Log
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.SecureKeyStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Typed result hierarchy for a sync attempt. Callers never see partial state;
 * they get exactly one of these and can render accordingly. DriveNotConfigured
 * is distinct from errors so the UI can prompt for setup rather than showing
 * a red "failed" state.
 */
sealed class SyncResult {
    /** Both push and pull completed; `merged` is the snapshot now in the repository. */
    data class Success(val merged: SyncBlob) : SyncResult()

    /**
     * Authorization is required before we can talk to Drive. The [pendingIntent]
     * must be launched via `startIntentSenderForResult` (or an ActivityResult
     * launcher) so the user can grant the Drive appData scope. After the user
     * approves, call [sync] again.
     */
    data class AuthorizationRequired(val pendingIntent: PendingIntent) : SyncResult()

    /** The sync passphrase stored in SecureKeyStore was wrong for the remote blob. */
    data object WrongPassphrase : SyncResult()

    /** The `driveOauthClientId` property is absent from local.properties. */
    data object NotConfigured : SyncResult()

    /** Any recoverable network / HTTP failure. */
    data class NetworkError(val message: String) : SyncResult()

    /** Unexpected error (programming fault, crypto engine problem, etc.). */
    data class UnknownError(val cause: Throwable) : SyncResult()
}

/**
 * Abstracts the two HTTP boundaries so the orchestration logic is testable
 * without a real network. Implementations use Drive REST v3 via Bearer token.
 *
 * `findFile`        — list appDataFolder for a file named [SyncBlob.DRIVE_FILE_NAME];
 *                     returns the Drive file id string or null if not found.
 * `downloadFile`    — GET the raw bytes of the given Drive file id.
 * `uploadNewFile`   — multipart create in appDataFolder; returns the new Drive file id.
 * `updateFile`      — multipart update of an existing Drive file id.
 */
interface DriveClient {
    suspend fun findFile(accessToken: String): String?
    suspend fun downloadFile(accessToken: String, fileId: String): ByteArray
    suspend fun uploadNewFile(accessToken: String, content: ByteArray): String
    suspend fun updateFile(accessToken: String, fileId: String, content: ByteArray)
}

/**
 * Production implementation of [DriveClient] that talks to
 * https://www.googleapis.com/drive/v3 using plain HttpURLConnection so we
 * do not need the heavy Google API Client library — the app already uses this
 * idiom in AIService for all its provider calls.
 *
 * We only ever touch the single `rhymeai-projects.json` file in appDataFolder,
 * so simple multipart/related upload and a name-filter list query are enough.
 */
class RealDriveClient : DriveClient {

    private companion object {
        private const val DRIVE_V3 = "https://www.googleapis.com/drive/v3"
        private const val UPLOAD_V3 = "https://www.googleapis.com/upload/drive/v3"
        private const val CONNECT_TIMEOUT_MS = 20_000
        private const val READ_TIMEOUT_MS = 30_000
        private const val MULTIPART_BOUNDARY = "rhymeai_boundary_g91hf"
    }

    override suspend fun findFile(accessToken: String): String? = withContext(Dispatchers.IO) {
        // List appDataFolder for a file with our exact name; return its id if found.
        val encodedName = java.net.URLEncoder.encode(SyncBlob.DRIVE_FILE_NAME, "UTF-8")
        val url = "$DRIVE_V3/files?spaces=appDataFolder&fields=files(id)&q=name%3D%27${encodedName}%27"
        val conn = openGet(url, accessToken)
        try {
            val code = conn.responseCode
            if (code == 401) throw DriveAuthException("Access token rejected by Drive (401)")
            if (code !in 200..299) {
                val body = conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                throw DriveNetworkException("Drive list failed ($code): $body")
            }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            // Parse just the first file id — we never create duplicates so there
            // can be at most one. Uses simple string extraction to avoid a JSON lib dep.
            val match = Regex(""""id"\s*:\s*"([^"]+)"""").find(body)
            match?.groupValues?.get(1)
        } finally {
            conn.disconnect()
        }
    }

    override suspend fun downloadFile(accessToken: String, fileId: String): ByteArray =
        withContext(Dispatchers.IO) {
            val conn = openGet("$DRIVE_V3/files/$fileId?alt=media", accessToken)
            try {
                val code = conn.responseCode
                if (code == 401) throw DriveAuthException("Access token rejected by Drive (401)")
                if (code !in 200..299) {
                    val body = conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                    throw DriveNetworkException("Drive download failed ($code): $body")
                }
                conn.inputStream.readBytes()
            } finally {
                conn.disconnect()
            }
        }

    override suspend fun uploadNewFile(accessToken: String, content: ByteArray): String =
        withContext(Dispatchers.IO) {
            // Multipart create with appDataFolder parent and our file name.
            val metadataJson = """{"name":"${SyncBlob.DRIVE_FILE_NAME}","parents":["appDataFolder"],"mimeType":"${SyncBlob.DRIVE_MIME_TYPE}"}"""
            val body = buildMultipart(metadataJson.toByteArray(Charsets.UTF_8), content)
            val conn = openMultipart("$UPLOAD_V3/files?uploadType=multipart", "POST", accessToken)
            conn.doOutput = true
            conn.outputStream.use { it.write(body) }
            try {
                val code = conn.responseCode
                if (code == 401) throw DriveAuthException("Access token rejected by Drive (401)")
                if (code !in 200..299) {
                    val errBody = conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                    throw DriveNetworkException("Drive upload failed ($code): $errBody")
                }
                val respBody = conn.inputStream.bufferedReader().use { it.readText() }
                Regex(""""id"\s*:\s*"([^"]+)"""").find(respBody)?.groupValues?.get(1)
                    ?: throw DriveNetworkException("Drive upload response missing file id")
            } finally {
                conn.disconnect()
            }
        }

    override suspend fun updateFile(accessToken: String, fileId: String, content: ByteArray) =
        withContext(Dispatchers.IO) {
            // Multipart update — no parent or name change needed, just replace content.
            val metadataJson = """{"mimeType":"${SyncBlob.DRIVE_MIME_TYPE}"}"""
            val body = buildMultipart(metadataJson.toByteArray(Charsets.UTF_8), content)
            val conn = openMultipart("$UPLOAD_V3/files/$fileId?uploadType=multipart", "PATCH", accessToken)
            conn.doOutput = true
            conn.outputStream.use { it.write(body) }
            try {
                val code = conn.responseCode
                if (code == 401) throw DriveAuthException("Access token rejected by Drive (401)")
                if (code !in 200..299) {
                    val errBody = conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                    throw DriveNetworkException("Drive update failed ($code): $errBody")
                }
            } finally {
                conn.disconnect()
            }
        }

    private fun openGet(url: String, accessToken: String): HttpURLConnection {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = "GET"
        conn.connectTimeout = CONNECT_TIMEOUT_MS
        conn.readTimeout = READ_TIMEOUT_MS
        conn.setRequestProperty("Authorization", "Bearer $accessToken")
        return conn
    }

    private fun openMultipart(url: String, method: String, accessToken: String): HttpURLConnection {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.connectTimeout = CONNECT_TIMEOUT_MS
        conn.readTimeout = READ_TIMEOUT_MS
        conn.setRequestProperty("Authorization", "Bearer $accessToken")
        conn.setRequestProperty("Content-Type", "multipart/related; boundary=$MULTIPART_BOUNDARY")
        return conn
    }

    private fun buildMultipart(metadataBytes: ByteArray, contentBytes: ByteArray): ByteArray {
        val nl = "\r\n"
        val sb = StringBuilder()
        sb.append("--$MULTIPART_BOUNDARY$nl")
        sb.append("Content-Type: application/json; charset=UTF-8$nl$nl")
        val prefix = sb.toString().toByteArray(Charsets.UTF_8)

        val middle = "$nl--$MULTIPART_BOUNDARY$nl".toByteArray(Charsets.UTF_8)
        val contentHeader = "Content-Type: ${SyncBlob.DRIVE_MIME_TYPE}$nl$nl".toByteArray(Charsets.UTF_8)
        val suffix = "$nl--$MULTIPART_BOUNDARY--$nl".toByteArray(Charsets.UTF_8)

        return prefix + metadataBytes + middle + contentHeader + contentBytes + suffix
    }
}

/** Thrown when the Drive access token is rejected (401) — triggers re-auth. */
class DriveAuthException(message: String) : Exception(message)

/** Thrown for any non-auth HTTP or IO failure from Drive. */
class DriveNetworkException(message: String) : Exception(message)

/**
 * Sync decision inputs. Pure data class so the unit tests can exercise all
 * paths without touching the real Drive client or Android Keystore.
 *
 * `remoteBytes`  — null means the remote file does not exist yet (first sync).
 * `passphrase`   — caller fills this from SecureKeyStore; service never touches storage.
 */
data class SyncDecisionInput(
    val local: SyncBlob,
    val remoteBytes: ByteArray?,
    val passphrase: CharArray,
    val clientId: String
)

/**
 * Pure decision output. Produced by [decideSyncAction] and consumed by
 * [DriveSyncService.executeDecision] which calls DriveClient.
 */
sealed class SyncDecision {
    /** No remote; upload the local blob. */
    data class UploadOnly(val sealedBytes: ByteArray) : SyncDecision()

    /** Remote exists; merge, then upload merged. */
    data class MergeAndUpload(val merged: SyncBlob, val sealedBytes: ByteArray) : SyncDecision()

    /** Wrong passphrase; do not touch the remote. */
    data object BadPassphrase : SyncDecision()
}

/**
 * Decides what to do given local state and optionally a remote blob.
 * Pure function: no IO, no side effects — fully testable on the JVM.
 *
 * If `remoteBytes` is null → upload-only.
 * If passphrase is wrong for the remote → BadPassphrase (never clobber).
 * Otherwise → merge + upload.
 */
fun decideSyncAction(input: SyncDecisionInput): SyncDecision {
    val json = Json { ignoreUnknownKeys = true }
    val localWithId = if (input.local.savedByClientId.isBlank()) {
        input.local.copy(savedByClientId = input.clientId)
    } else {
        input.local
    }

    val sealLocal = { blob: SyncBlob ->
        val plaintext = json.encodeToString(blob).toByteArray(Charsets.UTF_8)
        SyncBlobCrypto.seal(plaintext, input.passphrase)
    }

    if (input.remoteBytes == null) {
        return SyncDecision.UploadOnly(sealLocal(localWithId))
    }

    val remotePlaintext = try {
        SyncBlobCrypto.open(input.remoteBytes, input.passphrase)
    } catch (e: SyncBlobSealException) {
        return SyncDecision.BadPassphrase
    }

    val remoteBlob = try {
        json.decodeFromString<SyncBlob>(remotePlaintext.toString(Charsets.UTF_8))
    } catch (e: Exception) {
        // Remote is corrupt / unreadable — treat as empty so we overwrite it.
        SyncBlob()
    }

    val merged = SyncMerger.merge(localWithId, remoteBlob)
    return SyncDecision.MergeAndUpload(merged, sealLocal(merged))
}

/**
 * Orchestrates Google Drive sync for the RhymeAI projects library.
 *
 * Auth flow:
 *   1. Request an AuthorizationResult for the appData scope via Identity SDK.
 *   2. If the result carries a pending intent the user must approve, surface it
 *      via [SyncResult.AuthorizationRequired].
 *   3. Once we have an access token, proceed with Drive REST v3 calls.
 *
 * The passphrase is read from [SecureKeyStore] (key SYNC_PASSPHRASE) every
 * time sync runs — it is never cached in memory beyond the scope of one call.
 * If no passphrase is stored, sync returns [SyncResult.NotConfigured].
 *
 * NOTE on OAuth client id:
 *   For the same-package installed-app flow (the user auth happens in Google
 *   Play Services, not via a redirect URI) the AuthorizationRequest does not
 *   require an explicit OAuth client id configured in the code — Play Services
 *   identifies the caller by the app's signing certificate. However, you MUST
 *   have an OAuth 2.0 client of type "Android" registered in Google Cloud
 *   Console for the package `com.rhymeai.app` with the correct SHA-1 signing
 *   fingerprint. Without it the authorization request will fail at runtime with
 *   a "developer error" or similar from Play Services.
 *
 *   Steps in Google Cloud Console (one-time, for Tyler):
 *     1. Open the project that owns the RhymeAI app (or create one).
 *     2. APIs & Services → Enable → "Google Drive API".
 *     3. APIs & Services → Credentials → "+ Create Credentials" → "OAuth client ID".
 *     4. Application type: Android.
 *     5. Package name: com.rhymeai.app
 *     6. SHA-1 fingerprint: from `keytool -list -v -keystore your.keystore`
 *        (or `./gradlew signingReport` for the debug key).
 *     7. Save. No client-id constant is needed in code for the Android installed-app flow.
 *     8. Optionally set `driveOauthClientId=<web_client_id>` in android/local.properties
 *        if you need a web-type client for server-side validation — not required here.
 *
 *   The [driveClientId] constructor parameter is optional. If it is blank the
 *   service runs without a server-side web client id (Android flow only). If it
 *   is provided (via BuildConfig fed from local.properties) it is included in
 *   the AuthorizationRequest.
 *
 * @param context         Application context — used for Drive auth only.
 * @param secureKeyStore  Injected store; defaults to [EncryptedPrefsKeyStore].
 * @param driveClient     Injected HTTP client; defaults to [RealDriveClient].
 * @param driveClientId   Optional OAuth web client id from local.properties.
 */
class DriveSyncService(
    private val context: Context,
    private val secureKeyStore: SecureKeyStore,
    private val driveClient: DriveClient = RealDriveClient(),
    private val driveClientId: String = ""
) {
    companion object {
        /** Key used in SecureKeyStore for the sync passphrase. */
        const val PASSPHRASE_KEY = "DRIVE_SYNC_PASSPHRASE"

        private const val TAG = "DriveSyncService"

        /** Drive appData scope — the only scope we request. */
        private val DRIVE_APPDATA_SCOPE = Scope("https://www.googleapis.com/auth/drive.appdata")
    }

    /**
     * Run a full sync cycle:
     *   authorize → find remote file → download (if exists) → decide → upload merged → apply to repo.
     *
     * Returns a typed [SyncResult] covering every outcome; never throws.
     *
     * IMPORTANT: the repository is only mutated when the full upload has
     * succeeded. If any step between download and upload fails, the local
     * state is left unchanged.
     */
    suspend fun sync(repository: ProjectRepository): SyncResult = withContext(Dispatchers.IO) {
        try {
            // 1. Check passphrase is stored.
            val passphrase = secureKeyStore.getKey(PASSPHRASE_KEY).toCharArray()
            if (passphrase.isEmpty()) {
                return@withContext SyncResult.NotConfigured
            }

            // 2. Authorize — get an access token for the appData scope.
            val authResult = authorize()
                ?: return@withContext SyncResult.NotConfigured

            if (authResult.hasResolution()) {
                // User needs to approve; surface the intent and stop here.
                return@withContext SyncResult.AuthorizationRequired(
                    authResult.pendingIntent
                        ?: return@withContext SyncResult.NetworkError("Authorization pending intent missing")
                )
            }

            val accessToken = authResult.accessToken
                ?: return@withContext SyncResult.NetworkError("No access token received from authorization")

            Log.d(TAG, "Authorized; token length=${accessToken.length}")

            // 3. Snapshot local state from the repository.
            val localBlob = repository.snapshotForSync()

            // 4. Find and optionally download the remote blob.
            val remoteFileId: String? = try {
                driveClient.findFile(accessToken)
            } catch (e: DriveNetworkException) {
                return@withContext SyncResult.NetworkError("Could not list Drive files: ${e.message}")
            }

            val remoteBytes: ByteArray? = if (remoteFileId != null) {
                try {
                    driveClient.downloadFile(accessToken, remoteFileId)
                } catch (e: DriveNetworkException) {
                    return@withContext SyncResult.NetworkError("Could not download sync file: ${e.message}")
                }
            } else {
                null
            }

            // 5. Pure decision: merge or upload-only, or refuse if passphrase is wrong.
            val clientId = android.provider.Settings.Secure.getString(
                context.contentResolver,
                android.provider.Settings.Secure.ANDROID_ID
            ) ?: "unknown"

            val decision = decideSyncAction(
                SyncDecisionInput(
                    local = localBlob,
                    remoteBytes = remoteBytes,
                    passphrase = passphrase,
                    clientId = clientId
                )
            )

            when (decision) {
                is SyncDecision.BadPassphrase -> {
                    Log.w(TAG, "Wrong passphrase — aborting, remote file untouched")
                    return@withContext SyncResult.WrongPassphrase
                }

                is SyncDecision.UploadOnly -> {
                    // No remote; just push local.
                    try {
                        driveClient.uploadNewFile(accessToken, decision.sealedBytes)
                        Log.d(TAG, "Upload-only sync complete (first sync)")
                    } catch (e: DriveNetworkException) {
                        return@withContext SyncResult.NetworkError("Upload failed: ${e.message}")
                    }
                    return@withContext SyncResult.Success(localBlob)
                }

                is SyncDecision.MergeAndUpload -> {
                    // Push merged blob; only apply to repo after successful upload.
                    try {
                        if (remoteFileId != null) {
                            driveClient.updateFile(accessToken, remoteFileId, decision.sealedBytes)
                        } else {
                            driveClient.uploadNewFile(accessToken, decision.sealedBytes)
                        }
                        Log.d(TAG, "Merge-and-upload sync complete")
                    } catch (e: DriveNetworkException) {
                        return@withContext SyncResult.NetworkError("Upload failed after merge: ${e.message}")
                    }

                    // 6. Apply merged snapshot to the repository (after the upload succeeds).
                    repository.applySnapshot(decision.merged)
                    return@withContext SyncResult.Success(decision.merged)
                }
            }
        } catch (e: DriveAuthException) {
            SyncResult.NetworkError("Drive auth failed: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "Unexpected sync error", e)
            SyncResult.UnknownError(e)
        }
    }

    /**
     * Request authorization from Google Identity Services. Returns null only
     * if the Identity SDK is unavailable (which should not happen on any device
     * with Play Services). The [AuthorizationResult] either contains an access
     * token directly or a pending intent the user must launch to grant access.
     */
    private suspend fun authorize(): AuthorizationResult? =
        suspendCancellableCoroutine { cont ->
            val requestBuilder = AuthorizationRequest.Builder()
                .setRequestedScopes(listOf(DRIVE_APPDATA_SCOPE))

            if (driveClientId.isNotBlank()) {
                // Server-client-id is only needed if the app also accesses a backend
                // that validates Drive tokens. Include it when configured.
                requestBuilder.requestOfflineAccess(driveClientId)
            }

            Identity.getAuthorizationClient(context)
                .authorize(requestBuilder.build())
                .addOnSuccessListener { result -> cont.resume(result) }
                .addOnFailureListener { e ->
                    Log.w(TAG, "Authorization failed", e)
                    cont.resumeWithException(e)
                }
        }

    /** Store the sync passphrase. Called from the Settings UI. */
    fun setPassphrase(passphrase: String) {
        secureKeyStore.setKey(PASSPHRASE_KEY, passphrase)
    }

    /** True if a passphrase has been stored. */
    fun hasPassphrase(): Boolean = secureKeyStore.getKey(PASSPHRASE_KEY).isNotEmpty()
}

// ---------------------------------------------------------------------------
// ProjectRepository extensions: snapshot and apply, kept here so they stay
// co-located with the sync logic and do not pollute the repo's public surface.
// ---------------------------------------------------------------------------

/**
 * Produce a [SyncBlob] from the repository's current persisted state.
 * Reads the DataStore on IO; must be called from a coroutine.
 */
suspend fun ProjectRepository.snapshotForSync(): SyncBlob {
    val projects = projectsFlow.first()
    val trashed = trashedProjectsFlow.first()
    return SyncBlob(
        projects = projects,
        trashed = trashed,
        savedAt = System.currentTimeMillis()
    )
}

/**
 * Write the merged [SyncBlob] back to the repository. Called only after
 * the upload to Drive has confirmed success, so local state never diverges
 * from what Drive holds.
 */
suspend fun ProjectRepository.applySnapshot(blob: SyncBlob) {
    saveProjects(blob.projects)
    saveTrashedProjects(blob.trashed)
}
