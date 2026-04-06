package com.rhymeai.app.service

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import androidx.core.content.FileProvider
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.nehuatl.llamacpp.LlamaHelper
import java.io.File

class LocalModelService {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val llmFlow = MutableSharedFlow<LlamaHelper.LLMEvent>(
        replay = 0,
        extraBufferCapacity = 128,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )

    private var llamaHelper: LlamaHelper? = null
    private var _loadedModelPath: String? = null
    private var appContext: Context? = null

    val isLoaded: Boolean get() = _loadedModelPath != null
    val currentModelPath: String? get() = _loadedModelPath

    fun initialize(context: Context) {
        appContext = context
        if (llamaHelper == null) {
            llamaHelper = LlamaHelper(
                contentResolver = context.contentResolver,
                scope = scope,
                sharedFlow = llmFlow
            )
        }
    }

    suspend fun loadModel(filePath: String) = withContext(Dispatchers.IO) {
        val helper = llamaHelper ?: throw IllegalStateException("Service not initialized")
        val context = appContext ?: throw IllegalStateException("Service not initialized")

        // Convert file path to content:// URI via FileProvider
        val file = File(filePath)
        if (!file.exists()) throw IllegalStateException("Model file not found")

        val contentUri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file
        )

        val deferred = CompletableDeferred<Unit>()

        val job = scope.launch {
            llmFlow.collect { event ->
                when (event) {
                    is LlamaHelper.LLMEvent.Loaded -> deferred.complete(Unit)
                    is LlamaHelper.LLMEvent.Error -> deferred.completeExceptionally(
                        RuntimeException("Failed to load model")
                    )
                    else -> {}
                }
            }
        }

        helper.load(path = contentUri.toString(), contextLength = 2048) {}
        deferred.await()
        job.cancel()
        _loadedModelPath = filePath
    }

    suspend fun generateResponse(prompt: String): String = withContext(Dispatchers.IO) {
        val helper = llamaHelper ?: throw IllegalStateException("No model loaded")
        if (!isLoaded) throw IllegalStateException("No model loaded. Go to Settings to load a GGUF model file.")

        val result = StringBuilder()
        val deferred = CompletableDeferred<String>()

        val job = scope.launch {
            llmFlow.collect { event ->
                when (event) {
                    is LlamaHelper.LLMEvent.Ongoing -> result.append(event.word)
                    is LlamaHelper.LLMEvent.Done -> {
                        helper.stopPrediction()
                        deferred.complete(result.toString())
                    }
                    is LlamaHelper.LLMEvent.Error -> {
                        helper.stopPrediction()
                        deferred.completeExceptionally(RuntimeException("Model inference error"))
                    }
                    else -> {}
                }
            }
        }

        helper.predict(prompt)
        val response = deferred.await()
        job.cancel()
        response
    }

    fun unload() {
        llamaHelper?.let {
            try { it.stopPrediction() } catch (_: Exception) {}
        }
        _loadedModelPath = null
    }
}
