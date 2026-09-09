package org.nehuatl.llamacpp

import android.content.ContentResolver
import android.net.Uri
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch

class LlamaHelper(
    val contentResolver: ContentResolver,
    val scope: CoroutineScope = CoroutineScope(Dispatchers.IO),
    val sharedFlow: MutableSharedFlow<LLMEvent>
) {

    private val llama by lazy { LlamaAndroid(contentResolver) }
    private var loadJob: Job? = null
    private var completionJob: Job? = null
    private var currentContext: Int? = null
    private var tokenCount = 0
    private var allText = ""

    fun load(
        path: String,
        contextLength: Int,
        mmprojPath: String? = null,
        loaded: (Long) -> Unit
    ) {
        currentContext?.let { id -> llama.releaseContext(id) }

        loadJob = scope.launch {
            try {
                val modelUri = Uri.parse(path)
                val result = contentResolver.openFileDescriptor(modelUri, "r")?.use { model ->
                    val config = mutableMapOf<String, Any>(
                        "model" to path,
                        "model_fd" to model.fd,
                        "use_mmap" to false,
                        "use_mlock" to false,
                        "n_ctx" to contextLength,
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
                    val startEngine = {
                        llama.startEngine(config) {
                            allText += it
                            tokenCount++
                            sharedFlow.tryEmit(LLMEvent.Ongoing(it, tokenCount))
                        }
                    }
                    if (mmprojPath == null) {
                        startEngine()
                    } else {
                        contentResolver.openFileDescriptor(Uri.parse(mmprojPath), "r")?.use { mmproj ->
                            config["mmproj_fd"] = mmproj.fd
                            startEngine()
                        } ?: throw IllegalArgumentException("Cannot open mmproj URI")
                    }
                } ?: throw IllegalArgumentException("Cannot open model URI")

                val id = result["contextId"] ?: throw Exception("contextId not found in result map")
                currentContext = (id as Number).toInt()
                sharedFlow.tryEmit(LLMEvent.Loaded(path))
                loaded(currentContext!!.toLong())
            } catch (e: Exception) {
                Log.e("LlamaHelper", "Model initialization failed (${e.javaClass.simpleName})")
                sharedFlow.tryEmit(LLMEvent.Error("Model initialization failed"))
            }
        }
    }

    fun predict(prompt: String, imagePath: String? = null, partialCompletion: Boolean = true) {
        val context = currentContext ?: throw Exception("Model was not loaded yet")
        val startTime = System.currentTimeMillis()
        tokenCount = 0
        allText = ""
        
        val params = mutableMapOf<String, Any>(
            "prompt" to prompt,
            "emit_partial_completion" to partialCompletion,
        )
        
        completionJob = scope.launch {
            sharedFlow.tryEmit(LLMEvent.Started(prompt))
            if (imagePath == null) {
                llama.launchCompletion(id = context, params = params)
            } else {
                contentResolver.openFileDescriptor(Uri.parse(imagePath), "r")?.use { image ->
                    params["image_fds"] = listOf(image.fd)
                    llama.launchCompletion(id = context, params = params)
                } ?: throw IllegalArgumentException("Cannot open image URI")
            }
            val duration = System.currentTimeMillis() - startTime
            sharedFlow.tryEmit(LLMEvent.Done(allText, tokenCount, duration))
        }
    }

    fun stopPrediction() {
        val id = currentContext ?: return
        scope.launch {
            llama.stopCompletion(id)
        }
        completionJob?.cancel()
    }

    fun release() {
        currentContext?.let { id ->
            llama.releaseContext(id)
        }
        currentContext = null
    }

    fun abort() {
        loadJob?.cancel()
        stopPrediction()
    }

    sealed class LLMEvent {
        data class Loaded(val path: String) : LLMEvent()
        data class Started(val prompt: String) : LLMEvent()
        data class Ongoing(val word: String, val tokenCount: Int) : LLMEvent()
        data class Done(val fullText: String, val tokenCount: Int, val duration: Long) : LLMEvent()
        data class Error(val message: String) : LLMEvent()
    }
}
