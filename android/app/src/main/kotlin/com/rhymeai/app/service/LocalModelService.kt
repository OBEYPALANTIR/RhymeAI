package com.rhymeai.app.service

import android.content.Context
import android.net.Uri
import android.util.Log
import com.rhymeai.app.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import org.nehuatl.llamacpp.LlamaAndroid
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

internal const val MAX_LOCAL_MODEL_BYTES = 8L * 1024L * 1024L * 1024L
internal const val LOCAL_MODEL_ENGINE_VERSION = "0.4.0+c292c068bdd258203dd41fc6d0f08578eddd59f3"

internal enum class GGUFPromptFormat(val envelopeName: String, val stopSequence: String) {
    GEMMA_LEGACY("gemmaLegacy", "<end_of_turn>"),
    GEMMA4("gemma4", "<turn|>");

    companion object {
        fun resolve(architecture: String, chatTemplate: String): GGUFPromptFormat? {
            val hasLegacyTurns = "<start_of_turn>" in chatTemplate && "<end_of_turn>" in chatTemplate
            val hasGemma4Turns = "<|turn>" in chatTemplate && "<turn|>" in chatTemplate
            return when {
                architecture == "gemma4" && hasGemma4Turns && !hasLegacyTurns -> GEMMA4
                architecture in setOf("gemma", "gemma2", "gemma3", "gemma3n") &&
                    hasLegacyTurns && !hasGemma4Turns -> GEMMA_LEGACY
                else -> null
            }
        }
    }
}

internal data class LocalModelPromptMetadata(
    val architecture: String,
    val chatTemplateBytes: Int,
    val chatTemplateSha256: String,
    val promptFormat: GGUFPromptFormat
)

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
        const val MAX_FORMATTED_PROMPT_BYTES = 512 * 1024
        const val TEMPERATURE = 0.7
        const val TOP_K = 40
        const val TOP_P = 0.95
        const val N_PREDICT = -1
        const val IGNORE_EOS = false
        const val SEED = -1
    }

    private val modelMutex = Mutex()
    private val shutdownScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val closed = AtomicBoolean(false)
    private val pendingSyntheticCapture = AtomicReference<SyntheticGenerationCapture?>(null)
    private val nativeCapture = SyntheticNativeCaptureGate()
    private var llamaAndroid: LlamaAndroid? = null

    @Volatile
    private var contextId: Int? = null

    @Volatile
    private var activeTokenChannel: Channel<String>? = null

    @Volatile
    private var _loadedModelPath: String? = null

    @Volatile
    private var promptFormat: GGUFPromptFormat? = null

    @Volatile
    private var loadedChatTemplate: String? = null

    @Volatile
    internal var loadedPromptMetadata: LocalModelPromptMetadata? = null
        private set

    @Volatile
    var lastGenerationMetrics: LocalGenerationMetrics? = null
        private set

    val isLoaded: Boolean get() = _loadedModelPath != null

    internal fun captureNextSyntheticRequestForTesting(capture: SyntheticGenerationCapture) {
        check(BuildConfig.DEBUG) { "Synthetic capture is only available in debug builds" }
        require(capture.runId.matches(Regex("[A-Za-z0-9_-]{1,80}")))
        require(capture.expectedPromptSha256.matches(Regex("[0-9a-f]{64}")))
        require(capture.seed >= 0)
        check(pendingSyntheticCapture.compareAndSet(null, capture)) { "Synthetic capture already armed" }
    }

    fun initialize(context: Context) {
        check(!closed.get()) { "Service is closed" }
        if (llamaAndroid == null) {
            llamaAndroid = LlamaAndroid(context.contentResolver)
        }
    }

    suspend fun loadModel(filePath: String) = withContext(Dispatchers.IO) {
        stopActiveGeneration()
        modelMutex.withLock {
            check(!closed.get()) { "Service is closed" }
            val engine = llamaAndroid ?: throw IllegalStateException("Service not initialized")

            val file = File(filePath)
            if (!file.exists()) throw IllegalStateException("Model file not found")
            if (!file.canRead()) throw IllegalStateException("Model file cannot be read")
            if (file.length() > MAX_LOCAL_MODEL_BYTES) {
                throw IllegalStateException("Model file is too large for this app")
            }
            if (!file.isGgufFile()) throw IllegalStateException("Selected file is not a GGUF model")

            val modelUri = Uri.fromFile(file).toString()
            val previousContext = contextId
            contextId = null
            promptFormat = null
            loadedChatTemplate = null
            loadedPromptMetadata = null
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
                ) { token ->
                    nativeCapture.recordNativeCallback(token, System.nanoTime())
                    activeTokenChannel?.trySend(token)
                }
            } ?: throw IllegalStateException("Model initialization failed")
            val loadedContext = (loaded["contextId"] as? Number)?.toInt()
                ?: throw IllegalStateException("Model initialization returned no context")
            val metadata = ((loaded["model"] as? Map<*, *>)?.get("metadata") as? Map<*, *>)
                ?: emptyMap<Any?, Any?>()
            val architecture = metadata["general.architecture"] as? String
            val chatTemplate = metadata["tokenizer.chat_template"] as? String
            if (architecture == null || chatTemplate == null) {
                engine.releaseContext(loadedContext)
                throw IllegalStateException(
                    "The selected GGUF is missing required chat-format metadata."
                )
            }
            val resolvedPromptFormat = GGUFPromptFormat.resolve(architecture, chatTemplate)
            if (resolvedPromptFormat == null) {
                engine.releaseContext(loadedContext)
                throw IllegalStateException(
                    "The selected GGUF chat format is not supported. Choose a Gemma model with its original chat template."
                )
            }
            contextId = loadedContext
            promptFormat = resolvedPromptFormat
            loadedChatTemplate = chatTemplate
            loadedPromptMetadata = LocalModelPromptMetadata(
                architecture = architecture,
                chatTemplateBytes = chatTemplate.toByteArray(Charsets.UTF_8).size,
                chatTemplateSha256 = MessageDigest.getInstance("SHA-256")
                    .digest(chatTemplate.toByteArray(Charsets.UTF_8))
                    .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) },
                promptFormat = resolvedPromptFormat
            )
            _loadedModelPath = filePath
        }
    }

    fun streamResponse(prompt: String): Flow<String> = channelFlow {
        withContext(Dispatchers.IO) {
            modelMutex.withLock {
                check(!closed.get()) { "Service is closed" }
                val engine = llamaAndroid ?: throw IllegalStateException("No model loaded")
                val loadedContext = contextId
                val chatTemplate = loadedChatTemplate
                val format = promptFormat
                if (!isLoaded || loadedContext == null || format == null || chatTemplate == null) {
                    throw IllegalStateException("No model loaded. Go to Settings to load a GGUF model file.")
                }
                val capture = pendingSyntheticCapture.getAndSet(null)
                if (capture != null) {
                    check(BuildConfig.DEBUG)
                    val promptSha256 = MessageDigest.getInstance("SHA-256")
                        .digest(prompt.toByteArray(Charsets.UTF_8))
                        .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
                    check(promptSha256 == capture.expectedPromptSha256) {
                        "Synthetic capture prompt did not match the armed fixture"
                    }
                }
                val renderedPrompt = formatPrompt(engine, loadedContext, prompt, chatTemplate)

                val result = StringBuilder()
                val tokenChannel = Channel<String>(Channel.UNLIMITED)
                val startedAtNs = System.nanoTime()
                var firstChunkAtNs: Long? = null
                var chunkCount = 0
                var terminationReason = "eog"
                val generationBoundary = GenerationBoundary(
                    GGUFPromptFormat.entries.map { it.stopSequence }, MAX_RESPONSE_CHARS
                )

                engine.prepareCompletion(loadedContext)
                if (capture != null) {
                    capture.onGenerationStarted(startedAtNs)
                    nativeCapture.begin(capture, startedAtNs)
                }
                activeTokenChannel = tokenChannel
                val relayJob = launch {
                    for (rawChunk in tokenChannel) {
                        val boundedChunk = generationBoundary.accept(rawChunk)
                        val chunk = boundedChunk.text
                        if (chunk.isNotEmpty()) {
                            if (firstChunkAtNs == null) firstChunkAtNs = System.nanoTime()
                            result.append(chunk)
                            chunkCount++
                            val emittedAtNs = System.nanoTime()
                            send(chunk)
                            capture?.onParserChunk?.invoke(chunk, emittedAtNs - startedAtNs)
                        }
                        if (boundedChunk.terminationReason != null) {
                            terminationReason = boundedChunk.terminationReason
                            engine.stopCompletion(loadedContext)
                            break
                        }
                    }
                    if (!generationBoundary.isTerminated) {
                        val tail = generationBoundary.finish()
                        if (tail.text.isNotEmpty()) {
                            if (firstChunkAtNs == null) firstChunkAtNs = System.nanoTime()
                            result.append(tail.text)
                            chunkCount++
                            val emittedAtNs = System.nanoTime()
                            send(tail.text)
                            capture?.onParserChunk?.invoke(tail.text, emittedAtNs - startedAtNs)
                        }
                        tail.terminationReason?.let { terminationReason = it }
                    }
                }
                val completionJob = async(Dispatchers.IO) {
                    engine.launchCompletion(
                        loadedContext,
                        mapOf(
                            "prompt" to renderedPrompt,
                            "temperature" to TEMPERATURE,
                            "top_k" to TOP_K,
                            "top_p" to TOP_P,
                            "n_predict" to N_PREDICT,
                            "ignore_eos" to IGNORE_EOS,
                            "seed" to (capture?.seed ?: SEED),
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
                        try {
                            completionJob.cancelAndJoin()
                            relayJob.cancelAndJoin()
                        } finally {
                            nativeCapture.finish()
                        }
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

    internal suspend fun formatLoadedPromptForContract(
        prompt: String,
        chatTemplateOverride: String? = null
    ): String = withContext(Dispatchers.IO) {
        modelMutex.withLock {
            val engine = llamaAndroid ?: throw IllegalStateException("No model loaded")
            val loadedContext = contextId ?: throw IllegalStateException("No model loaded")
            val chatTemplate = chatTemplateOverride ?: loadedChatTemplate
                ?: throw IllegalStateException("No model chat template loaded")
            formatPrompt(engine, loadedContext, prompt, chatTemplate)
        }
    }

    private fun formatPrompt(
        engine: LlamaAndroid,
        loadedContext: Int,
        prompt: String,
        chatTemplate: String
    ): String {
        val renderedPrompt = engine.formatChat(
            loadedContext,
            listOf(mapOf("role" to "user", "content" to prompt)),
            chatTemplate
        )
        if (renderedPrompt.toByteArray(Charsets.UTF_8).size >= MAX_FORMATTED_PROMPT_BYTES) {
            throw IllegalStateException("Formatted local-model prompt is too large")
        }
        return renderedPrompt
    }

    suspend fun unload() = withContext(Dispatchers.IO) {
        stopActiveGeneration()
        modelMutex.withLock {
            val loadedContext = contextId
            activeTokenChannel?.close()
            activeTokenChannel = null
            contextId = null
            promptFormat = null
            loadedChatTemplate = null
            loadedPromptMetadata = null
            _loadedModelPath = null
            loadedContext?.let { id -> llamaAndroid?.releaseContext(id) }
        }
    }

    private suspend fun stopActiveGeneration() {
        val channel = activeTokenChannel ?: return
        val engine = llamaAndroid ?: return
        val activeContext = contextId ?: return
        channel.close()
        withTimeout(STOP_TIMEOUT_MS) { engine.stopCompletion(activeContext) }
    }

    internal fun closeAsync(): Job? {
        if (!closed.compareAndSet(false, true)) return null
        activeTokenChannel?.close()
        val engine = llamaAndroid
        val activeContext = contextId
        val shutdownJob = shutdownScope.launchLocalModelShutdown(
            stopActiveGeneration = {
                if (engine != null && activeContext != null) {
                    engine.stopCompletion(activeContext)
                }
            },
            releaseModel = { unload() },
            onStopFailure = { error ->
                Log.w("RhymeAI.LocalModel", "Local model did not stop before teardown", error)
            }
        )
        shutdownJob.invokeOnCompletion { shutdownScope.cancel() }
        return shutdownJob
    }

    override fun close() {
        closeAsync()
    }
}

internal data class BoundedGenerationChunk(val text: String, val terminationReason: String?)

internal class GenerationBoundary(private val stopSequences: List<String>, private val maximumOutputCharacters: Int) {
    private val pending = StringBuilder()
    private var outputCharacters = 0
    private var terminationReason: String? = null

    val isTerminated: Boolean get() = terminationReason != null

    init {
        require(stopSequences.isNotEmpty() && stopSequences.all { it.isNotEmpty() })
        require(maximumOutputCharacters > 0)
    }

    fun accept(chunk: String): BoundedGenerationChunk {
        terminationReason?.let { return BoundedGenerationChunk("", it) }
        pending.append(chunk)
        val stopIndex = stopSequences.map { pending.indexOf(it) }.filter { it >= 0 }.minOrNull() ?: -1
        if (stopIndex >= 0) {
            val text = pending.substring(0, stopIndex)
            pending.clear()
            return bound(text, "stopSequence")
        }
        val retainedLength = longestStopPrefixSuffixLength()
        val emittedLength = pending.length - retainedLength
        val text = pending.substring(0, emittedLength)
        pending.delete(0, emittedLength)
        return bound(text, null)
    }

    fun finish(): BoundedGenerationChunk {
        terminationReason?.let { return BoundedGenerationChunk("", it) }
        // A trailing partial control marker is not a complete lyric fragment.
        pending.clear()
        return BoundedGenerationChunk("", null)
    }

    private fun bound(text: String, boundaryReason: String?): BoundedGenerationChunk {
        val remaining = maximumOutputCharacters - outputCharacters
        val boundedText = text.takeUtf16CodeUnits(remaining.coerceAtLeast(0))
        outputCharacters += boundedText.length
        val resolvedReason = when {
            text.length > boundedText.length || outputCharacters >= maximumOutputCharacters ->
                "maximumResponseLength"
            else -> boundaryReason
        }
        if (resolvedReason != null) {
            terminationReason = resolvedReason
            pending.clear()
        }
        return BoundedGenerationChunk(boundedText, resolvedReason)
    }

    private fun longestStopPrefixSuffixLength(): Int {
        val maximum = minOf(pending.length, stopSequences.maxOf { it.length } - 1)
        for (length in maximum downTo 1) {
            val suffix = pending.substring(pending.length - length)
            if (stopSequences.any { it.startsWith(suffix) }) return length
        }
        return 0
    }
}

internal fun CoroutineScope.launchLocalModelShutdown(
    stopActiveGeneration: suspend () -> Unit,
    releaseModel: suspend () -> Unit,
    stopTimeoutMs: Long = LocalModelService.STOP_TIMEOUT_MS,
    onStopFailure: (Throwable) -> Unit = {}
): Job = launch {
    val stopFailure = runCatching {
        withTimeout(stopTimeoutMs) { stopActiveGeneration() }
    }.exceptionOrNull()
    withContext(NonCancellable) { releaseModel() }
    stopFailure?.let(onStopFailure)
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
    if (length() < 24L) return false
    return inputStream().use { input ->
        val header = ByteArray(8)
        if (input.read(header) != header.size) return@use false
        val magic = header.copyOfRange(0, 4)
        val version = ByteBuffer.wrap(header, 4, 4)
            .order(ByteOrder.LITTLE_ENDIAN)
            .int
        magic.contentEquals(byteArrayOf('G'.code.toByte(), 'G'.code.toByte(), 'U'.code.toByte(), 'F'.code.toByte())) &&
            version in 2..3
    }
}
