package com.rhymeai.app.service

import android.app.DownloadManager
import android.content.Context
import android.database.Cursor
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

class ModelDownloader(private val context: Context) {

    enum class FeaturedModel(
        val id: String,
        val displayName: String,
        val description: String,
        val repoSlug: String,
        val quant: String,
        val approxSizeMb: Int
    ) {
        GEMMA_4_E2B(
            id = "gemma-4-e2b",
            displayName = "Gemma 4 E2B",
            description = "5 B params • multimodal • ~1.7 GB",
            repoSlug = "ggml-org/gemma-4-E2B-it-GGUF",
            quant = "Q4_K_M",
            approxSizeMb = 1700
        ),
        GEMMA_4_E4B(
            id = "gemma-4-e4b",
            displayName = "Gemma 4 E4B",
            description = "8 B params • multimodal • ~3.5 GB",
            repoSlug = "ggml-org/gemma-4-E4B-it-GGUF",
            quant = "Q4_K_M",
            approxSizeMb = 3500
        );

        companion object {
            fun fromId(id: String?): FeaturedModel? = entries.find { it.id == id }
        }
    }

    sealed class State {
        data object Idle : State()
        data class Resolving(val model: FeaturedModel) : State()
        data class Running(
            val model: FeaturedModel,
            val downloadedBytes: Long,
            val totalBytes: Long
        ) : State() {
            val progress: Float
                get() = if (totalBytes > 0) (downloadedBytes.toDouble() / totalBytes).toFloat() else 0f
        }

        data class Complete(val model: FeaturedModel, val filePath: String) : State()
        data class Failed(val model: FeaturedModel, val message: String) : State()
    }

    private val json = Json { ignoreUnknownKeys = true }
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private var currentDownloadId: Long? = null
    private var pollJob: Job? = null

    fun isOnUnmeteredNetwork(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        val active = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(active) ?: return false
        // Treat Wi-Fi or Ethernet as "no cellular cost". NOT_METERED is the
        // authoritative signal but also covers tethered connections.
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    }

    fun startDownload(model: FeaturedModel, allowMetered: Boolean) {
        cancelInternal()
        scope.launch {
            try {
                _state.value = State.Resolving(model)
                val resolved = resolveDownloadUrl(model)
                val targetFile = File(modelsDir(), resolved.fileName)
                if (targetFile.exists()) targetFile.delete()

                val request = DownloadManager.Request(Uri.parse(resolved.url))
                    .setTitle("RhymeAI: ${model.displayName}")
                    .setDescription("Downloading on-device model (${model.approxSizeMb} MB)")
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    .setAllowedOverMetered(allowMetered)
                    .setAllowedOverRoaming(false)
                    .setDestinationUri(Uri.fromFile(targetFile))

                val dm = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                val id = dm.enqueue(request)
                currentDownloadId = id
                pollJob = scope.launch { pollProgress(dm, id, model, targetFile.absolutePath) }
            } catch (e: Exception) {
                _state.value = State.Failed(model, e.message ?: "Download could not start")
            }
        }
    }

    fun cancelDownload() {
        val id = currentDownloadId
        if (id != null) {
            runCatching {
                val dm = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                dm.remove(id)
            }
        }
        cancelInternal()
        _state.value = State.Idle
    }

    fun reset() {
        if (_state.value !is State.Running && _state.value !is State.Resolving) {
            _state.value = State.Idle
        }
    }

    private fun cancelInternal() {
        pollJob?.cancel()
        pollJob = null
        currentDownloadId = null
    }

    private fun modelsDir(): File {
        val dir = File(context.getExternalFilesDir(null), "models")
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    private suspend fun pollProgress(
        dm: DownloadManager,
        id: Long,
        model: FeaturedModel,
        destPath: String
    ) {
        while (true) {
            val cursor: Cursor = dm.query(DownloadManager.Query().setFilterById(id)) ?: break
            try {
                if (!cursor.moveToFirst()) {
                    _state.value = State.Failed(model, "Download was removed")
                    cancelInternal()
                    return
                }
                val statusCol = cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)
                val downloadedCol = cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)
                val totalCol = cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES)
                val reasonCol = cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)

                val status = cursor.getInt(statusCol)
                val downloaded = cursor.getLong(downloadedCol)
                val total = cursor.getLong(totalCol)

                when (status) {
                    DownloadManager.STATUS_PENDING,
                    DownloadManager.STATUS_PAUSED,
                    DownloadManager.STATUS_RUNNING -> {
                        _state.value = State.Running(model, downloaded, total)
                    }
                    DownloadManager.STATUS_SUCCESSFUL -> {
                        _state.value = State.Complete(model, destPath)
                        cancelInternal()
                        return
                    }
                    DownloadManager.STATUS_FAILED -> {
                        val reason = cursor.getInt(reasonCol)
                        _state.value = State.Failed(model, "Download failed (${reasonText(reason)})")
                        cancelInternal()
                        return
                    }
                }
            } finally {
                cursor.close()
            }
            delay(750)
        }
    }

    private fun reasonText(reason: Int): String = when (reason) {
        DownloadManager.ERROR_CANNOT_RESUME -> "cannot resume"
        DownloadManager.ERROR_DEVICE_NOT_FOUND -> "storage unavailable"
        DownloadManager.ERROR_FILE_ALREADY_EXISTS -> "file already exists"
        DownloadManager.ERROR_FILE_ERROR -> "file error"
        DownloadManager.ERROR_HTTP_DATA_ERROR -> "HTTP data error"
        DownloadManager.ERROR_INSUFFICIENT_SPACE -> "not enough storage"
        DownloadManager.ERROR_TOO_MANY_REDIRECTS -> "too many redirects"
        DownloadManager.ERROR_UNHANDLED_HTTP_CODE -> "unexpected HTTP status"
        DownloadManager.ERROR_UNKNOWN -> "unknown error"
        else -> "code $reason"
    }

    private data class Resolved(val url: String, val fileName: String)

    private suspend fun resolveDownloadUrl(model: FeaturedModel): Resolved = withContext(Dispatchers.IO) {
        // Hit the public HF model API to enumerate file siblings, then pick the
        // first .gguf whose name contains the requested quant tier (e.g. Q4_K_M).
        val apiUrl = URL("https://huggingface.co/api/models/${model.repoSlug}")
        val conn = (apiUrl.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 30_000
            setRequestProperty("Accept", "application/json")
        }
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                throw RuntimeException("HuggingFace API error ($code) for ${model.repoSlug}")
            }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val obj = json.parseToJsonElement(body).jsonObject
            val siblings = obj["siblings"]?.jsonArray
                ?: throw RuntimeException("No file list returned for ${model.repoSlug}")

            val fileNames = siblings.mapNotNull { s ->
                s.jsonObject["rfilename"]?.jsonPrimitive?.content
            }.filter { it.endsWith(".gguf", ignoreCase = true) }

            if (fileNames.isEmpty()) {
                throw RuntimeException("No GGUF files found in ${model.repoSlug}")
            }

            val match = fileNames.firstOrNull { it.contains(model.quant, ignoreCase = true) }
                ?: fileNames.first()

            Resolved(
                url = "https://huggingface.co/${model.repoSlug}/resolve/main/$match",
                fileName = "${model.id}-${match.substringAfterLast('/')}"
            )
        } finally {
            conn.disconnect()
        }
    }
}
