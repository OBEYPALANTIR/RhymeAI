package com.rhymeai.app.service

import android.content.Context
import android.net.Uri
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import org.nehuatl.llamacpp.LlamaHelper
import java.io.File

data class LocalGenerationMetrics(
    val timeToFirstChunkMs: Long,
    val totalDurationMs: Long,
    val outputCharacters: Int,
    val chunkCount: Int
) {
    val chunksPerSecond: Double
        get() = if (totalDurationMs > 0) chunkCount * 1_000.0 / totalDurationMs else 0.0
}

class LocalModelService {
    private companion object {
        const val CONTEXT_LENGTH = 2048
        const val GENERATION_TIMEOUT_MS = 120_000L
        const val MAX_RESPONSE_CHARS = 4096
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val modelMutex = Mutex()
    // Shared hot flow for all LlamaHelper events. Hazard: events carry no call id,
    // so a collector started by one loadModel/generateResponse call can observe
    // events emitted by an earlier, aborted call. modelMutex serializes calls and
    // generateResponse stops prediction in its finally block, which keeps stale
    // events out in practice — keep both invariants if changing this.
    private val llmFlow = MutableSharedFlow<LlamaHelper.LLMEvent>(
        replay = 0,
        extraBufferCapacity = 128,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )

    private var llamaHelper: LlamaHelper? = null
    private var _loadedModelPath: String? = null

    @Volatile
    var lastGenerationMetrics: LocalGenerationMetrics? = null
        private set

    val isLoaded: Boolean get() = _loadedModelPath != null

    fun initialize(context: Context) {
        if (llamaHelper == null) {
            llamaHelper = LlamaHelper(
                contentResolver = context.contentResolver,
                scope = scope,
                sharedFlow = llmFlow
            )
        }
    }

    suspend fun loadModel(filePath: String) = withContext(Dispatchers.IO) {
        modelMutex.withLock {
            val helper = llamaHelper ?: throw IllegalStateException("Service not initialized")

            val file = File(filePath)
            if (!file.exists()) throw IllegalStateException("Model file not found")
            if (!file.canRead()) throw IllegalStateException("Model file cannot be read")
            if (!file.isGgufFile()) throw IllegalStateException("Selected file is not a GGUF model")

            val modelUri = Uri.fromFile(file).toString()

            val deferred = CompletableDeferred<Unit>()

            val job = scope.launch {
                llmFlow.collect { event ->
                    when (event) {
                        is LlamaHelper.LLMEvent.Loaded -> {
                            if (!deferred.isCompleted) deferred.complete(Unit)
                        }
                        is LlamaHelper.LLMEvent.Error -> {
                            if (!deferred.isCompleted) {
                                deferred.completeExceptionally(RuntimeException(event.message))
                            }
                        }
                        else -> {}
                    }
                }
            }

            try {
                helper.load(path = modelUri, contextLength = CONTEXT_LENGTH) {
                    if (!deferred.isCompleted) deferred.complete(Unit)
                }
                deferred.await()
                _loadedModelPath = filePath
            } finally {
                job.cancel()
            }
        }
    }

    fun streamResponse(prompt: String): Flow<String> = channelFlow {
        withContext(Dispatchers.IO) {
            modelMutex.withLock {
                val helper = llamaHelper ?: throw IllegalStateException("No model loaded")
                if (!isLoaded) {
                    throw IllegalStateException(
                        "No model loaded. Go to Settings to load a GGUF model file."
                    )
                }

                val result = StringBuilder()
                val deferred = CompletableDeferred<Unit>()
                val startedAtNs = System.nanoTime()
                var firstChunkAtNs: Long? = null
                var chunkCount = 0

                val job = launch {
                    llmFlow.collect { event ->
                        when (event) {
                            is LlamaHelper.LLMEvent.Ongoing -> {
                                val remaining = MAX_RESPONSE_CHARS - result.length
                                val chunk = event.word.take(remaining.coerceAtLeast(0))
                                if (chunk.isNotEmpty()) {
                                    if (firstChunkAtNs == null) firstChunkAtNs = System.nanoTime()
                                    result.append(chunk)
                                    chunkCount++
                                    send(chunk)
                                }
                                if (result.length >= MAX_RESPONSE_CHARS && !deferred.isCompleted) {
                                    helper.stopPrediction()
                                    deferred.complete(Unit)
                                }
                            }
                            is LlamaHelper.LLMEvent.Done -> {
                                helper.stopPrediction()
                                if (!deferred.isCompleted) {
                                    if (result.isEmpty() && event.fullText.isNotBlank()) {
                                        val chunk = event.fullText.take(MAX_RESPONSE_CHARS)
                                        firstChunkAtNs = System.nanoTime()
                                        result.append(chunk)
                                        chunkCount++
                                        send(chunk)
                                    }
                                    deferred.complete(Unit)
                                }
                            }
                            is LlamaHelper.LLMEvent.Error -> {
                                helper.stopPrediction()
                                if (!deferred.isCompleted) {
                                    deferred.completeExceptionally(RuntimeException(event.message))
                                }
                            }
                            else -> {}
                        }
                    }
                }

                try {
                    helper.predict(prompt)
                    withTimeout(GENERATION_TIMEOUT_MS) { deferred.await() }
                } catch (e: TimeoutCancellationException) {
                    throw IllegalStateException(
                        "Local model took too long to respond. Try Gemma E2B or shorten the lyric context.",
                        e
                    )
                } finally {
                    job.cancel()
                    // Always stop the native prediction: without this, caller cancellation
                    // (user taps Stop) leaves llama generating, and its late events on the
                    // shared llmFlow would leak into the next call's collector.
                    try { helper.stopPrediction() } catch (_: Exception) {}
                    val finishedAtNs = System.nanoTime()
                    firstChunkAtNs?.let { firstNs ->
                        val metrics = LocalGenerationMetrics(
                            timeToFirstChunkMs = (firstNs - startedAtNs) / 1_000_000,
                            totalDurationMs = (finishedAtNs - startedAtNs) / 1_000_000,
                            outputCharacters = result.length,
                            chunkCount = chunkCount
                        )
                        lastGenerationMetrics = metrics
                        Log.i(
                            "RhymeAI.LocalModel",
                            "generation ttfc_ms=${metrics.timeToFirstChunkMs} " +
                                "total_ms=${metrics.totalDurationMs} chunks=${metrics.chunkCount} " +
                                "chunks_per_s=${"%.2f".format(metrics.chunksPerSecond)}"
                        )
                    }
                }
            }
        }
    }.buffer(Channel.UNLIMITED)

    suspend fun generateResponse(prompt: String): String =
        streamResponse(prompt).toList().joinToString(separator = "")

    fun unload() {
        llamaHelper?.let {
            try { it.stopPrediction() } catch (_: Exception) {}
            try { it.release() } catch (_: Exception) {}
        }
        _loadedModelPath = null
    }
}

internal fun File.isGgufFile(): Boolean {
    if (length() < 24L) return false
    return inputStream().use { input ->
        val header = ByteArray(8)
        if (input.read(header) != header.size) return@use false
        val hasMagic = header.copyOfRange(0, 4).contentEquals(
            byteArrayOf('G'.code.toByte(), 'G'.code.toByte(), 'U'.code.toByte(), 'F'.code.toByte())
        )
        val version = (header[4].toInt() and 0xff) or
            ((header[5].toInt() and 0xff) shl 8) or
            ((header[6].toInt() and 0xff) shl 16) or
            ((header[7].toInt() and 0xff) shl 24)
        hasMagic && version in 2..3
    }
}
