package com.rhymeai.app.service

import android.content.Context
import android.net.Uri
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import org.nehuatl.llamacpp.LlamaAndroid
import java.io.File

data class LocalGenerationMetrics(
    val timeToFirstChunkMs: Long?,
    val totalDurationMs: Long,
    val outputCharacters: Int,
    val chunkCount: Int,
    val terminationReason: String
)

class LocalModelService : AutoCloseable {
    internal companion object {
        const val CONTEXT_LENGTH = 2048
        const val GENERATION_TIMEOUT_MS = 120_000L
        const val STOP_TIMEOUT_MS = 5_000L
        const val MAX_RESPONSE_CHARS = 4096
        const val TEMPERATURE = 0.7
        const val TOP_K = 40
        const val TOP_P = 0.95
        const val N_PREDICT = -1
        const val IGNORE_EOS = false
        const val SEED = -1
    }

    private val modelMutex = Mutex()
    private var llamaAndroid: LlamaAndroid? = null
    private var contextId: Int? = null

    @Volatile
    private var activeTokenChannel: Channel<String>? = null

    @Volatile
    private var _loadedModelPath: String? = null

    @Volatile
    var lastGenerationMetrics: LocalGenerationMetrics? = null
        private set

    val isLoaded: Boolean get() = _loadedModelPath != null

    fun initialize(context: Context) {
        if (llamaAndroid == null) {
            llamaAndroid = LlamaAndroid(context.contentResolver)
        }
    }

    suspend fun loadModel(filePath: String) = withContext(Dispatchers.IO) {
        modelMutex.withLock {
            val engine = llamaAndroid ?: throw IllegalStateException("Service not initialized")

            val file = File(filePath)
            if (!file.exists()) throw IllegalStateException("Model file not found")
            if (!file.canRead()) throw IllegalStateException("Model file cannot be read")
            if (!file.isGgufFile()) throw IllegalStateException("Selected file is not a GGUF model")

            val modelUri = Uri.fromFile(file).toString()
            val previousContext = contextId
            contextId = null
            _loadedModelPath = null
            previousContext?.let(engine::releaseContext)
            val loaded = engine.resolver.openFileDescriptor(Uri.parse(modelUri), "r")?.use { model ->
                engine.startEngine(
                    mapOf(
                        "model" to modelUri,
                        "model_fd" to model.fd,
                        "use_mmap" to true,
                        "use_mlock" to false,
                        "n_ctx" to CONTEXT_LENGTH,
                        "embedding" to false,
                        "n_batch" to 512,
                        "n_threads" to 0,
                        "n_gpu_layers" to 0,
                        "vocab_only" to false,
                        "lora" to "",
                        "lora_scaled" to 1.0,
                        "rope_freq_base" to 0.0,
                        "rope_freq_scale" to 0.0
                    )
                ) { token -> activeTokenChannel?.trySend(token) }
            } ?: throw IllegalStateException("Model initialization failed")
            contextId = (loaded["contextId"] as? Number)?.toInt()
                ?: throw IllegalStateException("Model initialization returned no context")
            _loadedModelPath = filePath
        }
    }

    fun streamResponse(prompt: String): Flow<String> = channelFlow {
        withContext(Dispatchers.IO) {
            modelMutex.withLock {
                val engine = llamaAndroid ?: throw IllegalStateException("No model loaded")
                val loadedContext = contextId
                if (!isLoaded || loadedContext == null) {
                    throw IllegalStateException("No model loaded. Go to Settings to load a GGUF model file.")
                }

                val result = StringBuilder()
                val tokenChannel = Channel<String>(Channel.UNLIMITED)
                val startedAtNs = System.nanoTime()
                var firstChunkAtNs: Long? = null
                var chunkCount = 0
                var terminationReason = "eog"

                activeTokenChannel = tokenChannel
                val relayJob = launch {
                    for (rawChunk in tokenChannel) {
                        val remaining = MAX_RESPONSE_CHARS - result.length
                        val chunk = rawChunk.takeUtf16CodeUnits(remaining.coerceAtLeast(0))
                        if (chunk.isNotEmpty()) {
                            if (firstChunkAtNs == null) firstChunkAtNs = System.nanoTime()
                            result.append(chunk)
                            chunkCount++
                            send(chunk)
                        }
                        if (rawChunk.length > chunk.length || result.length >= MAX_RESPONSE_CHARS) {
                            terminationReason = "maximumResponseLength"
                            engine.stopCompletion(loadedContext)
                            break
                        }
                    }
                }
                val completionJob = async(Dispatchers.IO) {
                    engine.launchCompletion(
                        loadedContext,
                        mapOf(
                            "prompt" to prompt,
                            "temperature" to TEMPERATURE,
                            "top_k" to TOP_K,
                            "top_p" to TOP_P,
                            "n_predict" to N_PREDICT,
                            "ignore_eos" to IGNORE_EOS,
                            "seed" to SEED,
                            "emit_partial_completion" to true
                        )
                    ) ?: throw IllegalStateException("Local model generation failed")
                }

                try {
                    withTimeout(GENERATION_TIMEOUT_MS) { completionJob.await() }
                    tokenChannel.close()
                    relayJob.join()
                } catch (error: TimeoutCancellationException) {
                    terminationReason = "deadline"
                    throw IllegalStateException(
                        "Local model took too long to respond. Try Gemma E2B or shorten the lyric context.",
                        error
                    )
                } catch (error: CancellationException) {
                    terminationReason = "cancelled"
                    throw error
                } catch (error: Throwable) {
                    terminationReason = "error"
                    throw error
                } finally {
                    withContext(NonCancellable) {
                        activeTokenChannel = null
                        tokenChannel.close()
                        val stopFailure = runCatching {
                            withTimeout(STOP_TIMEOUT_MS) { engine.stopCompletion(loadedContext) }
                        }.exceptionOrNull()
                        completionJob.cancelAndJoin()
                        relayJob.cancelAndJoin()
                        if (stopFailure != null) {
                            terminationReason = "error"
                        }
                        val finishedAtNs = System.nanoTime()
                        val metrics = LocalGenerationMetrics(
                            timeToFirstChunkMs = firstChunkAtNs?.let { (it - startedAtNs) / 1_000_000 },
                            totalDurationMs = (finishedAtNs - startedAtNs) / 1_000_000,
                            outputCharacters = result.length,
                            chunkCount = chunkCount,
                            terminationReason = terminationReason
                        )
                        lastGenerationMetrics = metrics
                        Log.i(
                            "RhymeAI.LocalModel",
                            "generation ttfc_ms=${metrics.timeToFirstChunkMs ?: -1} " +
                                "total_ms=${metrics.totalDurationMs} chars=${metrics.outputCharacters} " +
                                "chunks=${metrics.chunkCount} reason=$terminationReason"
                        )
                        if (stopFailure != null) {
                            throw IllegalStateException("Local model did not stop cleanly", stopFailure)
                        }
                    }
                }
            }
        }
    }.buffer(Channel.UNLIMITED)

    suspend fun generateResponse(prompt: String): String =
        streamResponse(prompt).toList().joinToString(separator = "")

    suspend fun unload() = withContext(Dispatchers.IO) {
        modelMutex.withLock {
            val loadedContext = contextId
            activeTokenChannel?.close()
            activeTokenChannel = null
            contextId = null
            _loadedModelPath = null
            loadedContext?.let { id -> llamaAndroid?.releaseContext(id) }
        }
    }

    override fun close() {
        runBlocking { unload() }
    }
}

internal fun String.takeUtf16CodeUnits(limit: Int): String {
    if (limit <= 0) return ""
    if (length <= limit) return this
    val safeEnd = if (
        limit < length &&
        this[limit - 1].isHighSurrogate() &&
        this[limit].isLowSurrogate()
    ) {
        limit - 1
    } else {
        limit
    }
    return substring(0, safeEnd)
}

internal fun File.isGgufFile(): Boolean {
    if (length() < 4L) return false
    return inputStream().use { input ->
        val header = ByteArray(4)
        input.read(header) == header.size && header.contentEquals(byteArrayOf('G'.code.toByte(), 'G'.code.toByte(), 'U'.code.toByte(), 'F'.code.toByte()))
    }
}
