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
import kotlinx.coroutines.flow.onSubscription
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.nehuatl.llamacpp.LlamaHelper
import java.io.File

class LocalModelService {
    private companion object {
        // KV cache scales linearly with context length; 512 keeps native memory
        // small enough for ~2-4 GB-RAM phones to load multi-GB GGUF weights
        // without the OS killing the process.
        const val DEFAULT_CONTEXT_LENGTH = 512
    }

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

        val file = File(filePath)
        if (!file.exists()) throw IllegalStateException("Model file not found")

        val contentUri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file
        )

        val deferred = CompletableDeferred<Unit>()

        // onSubscription guarantees load() is called only after the collector is
        // attached, so an immediate Loaded/Error event from the helper isn't lost.
        val job = scope.launch {
            llmFlow
                .onSubscription {
                    helper.load(
                        path = contentUri.toString(),
                        contextLength = DEFAULT_CONTEXT_LENGTH
                    ) {}
                }
                .collect { event ->
                    when (event) {
                        is LlamaHelper.LLMEvent.Loaded -> deferred.complete(Unit)
                        is LlamaHelper.LLMEvent.Error -> deferred.completeExceptionally(
                            RuntimeException("Model load failed (the model may be too large for this device or incompatible): $event")
                        )
                        else -> {}
                    }
                }
        }

        try {
            deferred.await()
            _loadedModelPath = filePath
        } finally {
            job.cancel()
        }
    }

    suspend fun generateResponse(prompt: String): String = withContext(Dispatchers.IO) {
        val helper = llamaHelper ?: throw IllegalStateException("No model loaded")
        if (!isLoaded) throw IllegalStateException("No model loaded. Go to Settings to load a GGUF model file.")

        val result = StringBuilder()
        val deferred = CompletableDeferred<String>()

        val job = scope.launch {
            llmFlow
                .onSubscription { helper.predict(prompt) }
                .collect { event ->
                    when (event) {
                        is LlamaHelper.LLMEvent.Ongoing -> result.append(event.word)
                        is LlamaHelper.LLMEvent.Done -> {
                            helper.stopPrediction()
                            deferred.complete(result.toString())
                        }
                        is LlamaHelper.LLMEvent.Error -> {
                            helper.stopPrediction()
                            deferred.completeExceptionally(
                                RuntimeException("Model inference error: $event")
                            )
                        }
                        else -> {}
                    }
                }
        }

        try {
            deferred.await()
        } finally {
            job.cancel()
        }
    }

    fun unload() {
        llamaHelper?.let {
            try { it.stopPrediction() } catch (_: Exception) {}
        }
        _loadedModelPath = null
    }
}
