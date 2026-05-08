package com.rhymeai.app.service

import android.content.Context
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import org.nehuatl.llamacpp.LlamaAndroid
import java.io.File

/**
 * Wraps the lower-level [LlamaAndroid] (from llamacpp-kotlin 0.4.0) so the rest
 * of the app can call simple suspending functions. We bypass the older
 * `LlamaHelper` convenience class because it doesn't expose sampling
 * parameters or KV-cache session save/restore — the things we actually need to
 * make Gemma 4 E2B/E4B produce decent songwriting output.
 */
class LocalModelService {
    private companion object {
        // KV cache scales linearly with context length. 1024 gives the
        // few-shot songwriting prompt (~600 tokens with a typical lyrics
        // input) room to breathe alongside a 200-token JSON completion,
        // while staying ~half the memory footprint of llama.cpp's stock
        // 2048 default — keeps multi-GB GGUFs loadable on ~4 GB-RAM phones.
        const val DEFAULT_CONTEXT_LENGTH = 1024
    }

    private var llama: LlamaAndroid? = null
    private var contextId: Int? = null
    private var _loadedModelPath: String? = null
    private var appContext: Context? = null

    // Set by [generateResponse] to capture streamed tokens for the current
    // request. The token callback installed at startEngine time fires for the
    // lifetime of the loaded model, so we route per-request output through
    // this volatile sink. @Volatile because the callback is invoked from a
    // native worker thread.
    @Volatile private var streamSink: ((String) -> Unit)? = null

    val isLoaded: Boolean get() = contextId != null

    fun initialize(context: Context) {
        appContext = context.applicationContext
        if (llama == null) {
            llama = LlamaAndroid(appContext!!.contentResolver)
        }
    }

    suspend fun loadModel(filePath: String): Unit = withContext(Dispatchers.IO) {
        val client = llama ?: throw IllegalStateException("Service not initialized")
        val ctx = appContext ?: throw IllegalStateException("Service not initialized")

        val file = File(filePath)
        if (!file.exists()) throw IllegalStateException("Model file not found")

        val contentUri = FileProvider.getUriForFile(
            ctx,
            "${ctx.packageName}.fileprovider",
            file
        )

        val pfd = ctx.contentResolver.openFileDescriptor(contentUri, "r")
            ?: throw IllegalStateException("Cannot open model file")
        // detachFd() unhooks the underlying fd from the ParcelFileDescriptor;
        // ownership transfers to the native side at startEngine. We close the
        // wrapper but the detached fd survives.
        val fd = try {
            pfd.detachFd()
        } catch (t: Throwable) {
            pfd.close()
            throw t
        }
        pfd.close()

        val params = mapOf<String, Any>(
            "model" to contentUri.toString(),
            "model_fd" to fd,
            "n_ctx" to DEFAULT_CONTEXT_LENGTH,
            "n_batch" to 256,
            "n_threads" to 0,        // 0 = auto-detect cores
            "use_mlock" to false,    // Android RLIMIT_MEMLOCK is too tight for multi-GB models
            "use_mmap" to true,
            "embedding" to false,
            "n_gpu_layers" to 0      // GPU is disabled in this build of the native lib
        )

        val tokenCallback: (String) -> Unit = { word -> streamSink?.invoke(word) }

        val result = client.startEngine(params, tokenCallback)
            ?: throw RuntimeException(
                "Model load failed (the model may be too large for this device, " +
                    "incompatible, or the architecture isn't supported by this build)"
            )

        val newContextId = (result["contextId"] as? Number)?.toInt()
            ?: throw RuntimeException("startEngine returned no contextId")

        contextId = newContextId
        _loadedModelPath = filePath
    }

    suspend fun generateResponse(
        prompt: String,
        params: GenerationParams = GenerationParams.DEFAULT
    ): String = withContext(Dispatchers.IO) {
        val client = llama ?: throw IllegalStateException("No model loaded")
        val id = contextId
            ?: throw IllegalStateException("No model loaded. Go to Settings to load a GGUF model file.")

        val sb = StringBuilder()
        streamSink = { word -> sb.append(word) }
        try {
            val pred = mapOf<String, Any>(
                "prompt" to prompt,
                "temperature" to params.temperature,
                "top_p" to params.topP,
                "top_k" to params.topK,
                "min_p" to params.minP,
                "penalty_repeat" to params.repeatPenalty,
                "penalty_last_n" to params.repeatLastN,
                "seed" to params.seed,
                "n_predict" to params.maxTokens,
                "stop" to params.stop,
                "emit_partial_completion" to true
            )
            val result = client.launchCompletion(id, pred)
                ?: throw RuntimeException(
                    "Model inference failed (context may be busy or out of memory)"
                )
            // Prefer the engine's aggregated text if present; fall back to
            // whatever streamed through the per-token callback.
            (result["text"] as? String).takeUnless { it.isNullOrEmpty() } ?: sb.toString()
        } finally {
            streamSink = null
        }
    }

    suspend fun stop() {
        val client = llama ?: return
        val id = contextId ?: return
        client.stopCompletion(id)
    }

    fun unload() {
        val client = llama
        val id = contextId
        if (client != null && id != null) {
            runCatching { client.releaseContext(id) }
        }
        contextId = null
        _loadedModelPath = null
    }

    /**
     * Persist the current KV cache to disk so a future [loadSession] can skip
     * reprocessing the prompt prefix. Returns the number of tokens written, or
     * -1 on error. See follow-up note in the PR description — we're not yet
     * calling this from anywhere because prefix-detection between calls hasn't
     * been wired into [AIService] yet, but the plumbing is here so the next
     * step is mechanical.
     */
    suspend fun saveSession(path: String, tokens: Int = -1): Int = withContext(Dispatchers.IO) {
        val client = llama ?: return@withContext -1
        val id = contextId ?: return@withContext -1
        runCatching { client.saveSession(id, path, tokens).first() }.getOrDefault(-1)
    }

    suspend fun loadSession(path: String): Boolean = withContext(Dispatchers.IO) {
        val client = llama ?: return@withContext false
        val id = contextId ?: return@withContext false
        runCatching { client.loadSession(id, path).first() }.isSuccess
    }

    /**
     * Sampling knobs for [generateResponse]. Defaults match llama.cpp's stock
     * values; [SONGWRITING] is tuned for short, structured JSON-array output
     * with poetic phrasing — a hint of randomness for variety, top-p / top-k
     * disciplined enough to stay coherent, repeat-penalty just high enough to
     * stop the model from rhyming the same word with itself six times.
     */
    data class GenerationParams(
        val temperature: Double = 0.7,
        val topP: Double = 0.95,
        val topK: Int = 40,
        val minP: Double = 0.05,
        val repeatPenalty: Double = 1.0,
        val repeatLastN: Int = 64,
        val seed: Int = -1,
        val maxTokens: Int = 256,
        val stop: List<String> = listOf("</s>", "<end_of_turn>", "<|im_end|>")
    ) {
        companion object {
            val DEFAULT = GenerationParams()
            val SONGWRITING = GenerationParams(
                temperature = 0.85,
                topP = 0.92,
                topK = 60,
                minP = 0.04,
                repeatPenalty = 1.12,
                repeatLastN = 128,
                maxTokens = 200
            )
        }
    }
}
