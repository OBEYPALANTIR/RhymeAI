package com.rhymeai.app.ui.components

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.launch
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

private data class GemmaDownload(
    val label: String,
    val description: String,
    val fileName: String,
    val url: String
)

private val GEMMA_DOWNLOADS = listOf(
    GemmaDownload(
        label = "Gemma 4 E2B",
        description = "Smaller phone-first model, about 3.17 GB.",
        fileName = "gemma-4-E2B-it-UD-Q4_K_XL.gguf",
        url = "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-UD-Q4_K_XL.gguf?download=true"
    ),
    GemmaDownload(
        label = "Gemma 4 E4B",
        description = "Higher quality local model, about 5.1 GB.",
        fileName = "gemma-4-E4B-it-UD-Q4_K_XL.gguf",
        url = "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-UD-Q4_K_XL.gguf?download=true"
    )
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsDialog(
    apiKeys: Map<String, String>,
    currentProvider: AIProvider,
    currentModel: AIModel,
    localModelLoading: Boolean,
    localModelLoaded: Boolean,
    localModelPath: String?,
    localModelError: String?,
    onSaveApiKey: (AIProvider, String) -> Unit,
    onSaveProvider: (AIProvider) -> Unit,
    onSaveModel: (AIModel) -> Unit,
    onLoadLocalModel: (String) -> Unit,
    onUnloadLocalModel: () -> Unit,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val context = LocalContext.current
    var selectedProvider by remember { mutableStateOf(currentProvider) }
    var selectedModel by remember { mutableStateOf(currentModel) }
    var geminiKey by remember { mutableStateOf(apiKeys["GEMINI"] ?: "") }
    var openaiKey by remember { mutableStateOf(apiKeys["OPENAI"] ?: "") }
    var claudeKey by remember { mutableStateOf(apiKeys["CLAUDE"] ?: "") }
    var showKey by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(false) }
    var modelExpanded by remember { mutableStateOf(false) }

    val currentKeyForProvider = when (selectedProvider) {
        AIProvider.GEMINI -> geminiKey
        AIProvider.OPENAI -> openaiKey
        AIProvider.CLAUDE -> claudeKey
        AIProvider.LOCAL -> ""
    }

    // File picker for local models
    var copyingFile by remember { mutableStateOf(false) }
    var copyError by remember { mutableStateOf<String?>(null) }
    var downloadingModel by remember { mutableStateOf<GemmaDownload?>(null) }
    var downloadProgress by remember { mutableStateOf<Float?>(null) }
    var downloadError by remember { mutableStateOf<String?>(null) }
    val coroutineScope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO)

    fun startGemmaDownload(model: GemmaDownload) {
        downloadingModel = model
        downloadProgress = 0f
        downloadError = null
        copyError = null

        coroutineScope.launch {
            val destFile = File(context.filesDir, model.fileName)
            val tempFile = File(context.cacheDir, "${model.fileName}.download")

            try {
                if (tempFile.exists()) tempFile.delete()

                val connection = (URL(model.url).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 30000
                    readTimeout = 30000
                    instanceFollowRedirects = true
                    setRequestProperty("User-Agent", "RhymeAI-Android")
                }

                try {
                    val code = connection.responseCode
                    if (code !in 200..299) {
                        throw IllegalStateException("Hugging Face returned HTTP $code")
                    }

                    val totalBytes = connection.contentLengthLong
                    var copiedBytes = 0L
                    connection.inputStream.use { input ->
                        tempFile.outputStream().buffered().use { output ->
                            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                            while (true) {
                                val read = input.read(buffer)
                                if (read == -1) break
                                output.write(buffer, 0, read)
                                copiedBytes += read
                                if (totalBytes > 0L) {
                                    val progress = copiedBytes.toFloat() / totalBytes.toFloat()
                                    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                                        downloadProgress = progress.coerceIn(0f, 1f)
                                    }
                                }
                            }
                        }
                    }
                } finally {
                    connection.disconnect()
                }

                if (destFile.exists()) destFile.delete()
                if (!tempFile.renameTo(destFile)) {
                    tempFile.copyTo(destFile, overwrite = true)
                    tempFile.delete()
                }

                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                    downloadingModel = null
                    downloadProgress = null
                    selectedProvider = AIProvider.LOCAL
                    selectedModel = AIModel.LOCAL_MODEL
                    onSaveProvider(AIProvider.LOCAL)
                    onSaveModel(AIModel.LOCAL_MODEL)
                    onLoadLocalModel(destFile.absolutePath)
                    saved = true
                }
            } catch (e: Exception) {
                e.printStackTrace()
                tempFile.delete()
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                    downloadingModel = null
                    downloadProgress = null
                    downloadError = "Failed to download ${model.label}: ${e.message}"
                }
            }
        }
    }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let {
            copyingFile = true
            copyError = null
            coroutineScope.launch {
                try {
                    val inputStream = context.contentResolver.openInputStream(it)
                        ?: throw Exception("Cannot open file")
                    val fileName = "local_model.gguf"
                    val destFile = File(context.filesDir, fileName)
                    // Delete old model file if exists
                    if (destFile.exists()) destFile.delete()
                    inputStream.use { input ->
                        destFile.outputStream().buffered().use { output ->
                            input.copyTo(output, bufferSize = 8192 * 1024) // 8MB buffer
                        }
                    }
                    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                        copyingFile = false
                        selectedProvider = AIProvider.LOCAL
                        selectedModel = AIModel.LOCAL_MODEL
                        onSaveProvider(AIProvider.LOCAL)
                        onSaveModel(AIModel.LOCAL_MODEL)
                        onLoadLocalModel(destFile.absolutePath)
                        saved = true
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                        copyingFile = false
                        copyError = "Failed to load file: ${e.message}"
                    }
                }
            }
        }
    }

    val textFieldColors = OutlinedTextFieldDefaults.colors(
        unfocusedBorderColor = colorScheme.outlineVariant,
        focusedBorderColor = colorScheme.primary.copy(alpha = 0.5f),
        unfocusedContainerColor = colorScheme.surfaceContainerLow,
        focusedContainerColor = colorScheme.surfaceContainerLow,
        cursorColor = colorScheme.primary,
        unfocusedTextColor = colorScheme.onSurface,
        focusedTextColor = colorScheme.onSurface,
        unfocusedPlaceholderColor = colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
        focusedPlaceholderColor = colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
    )

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp),
            contentAlignment = Alignment.Center
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(colorScheme.surfaceContainerLow, RoundedCornerShape(16.dp))
                    .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(16.dp))
                    .padding(20.dp)
                    .verticalScroll(rememberScrollState())
            ) {
                // Header
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(Icons.Default.Settings, null, tint = colorScheme.primary, modifier = Modifier.size(20.dp))
                        Text("Settings", fontWeight = FontWeight.Medium, fontSize = 18.sp, color = colorScheme.onSurface)
                    }
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, null, tint = colorScheme.onSurfaceVariant)
                    }
                }

                Spacer(Modifier.height(16.dp))

                // Provider selector
                Text("AI Provider", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(8.dp))

                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    AIProvider.entries.forEachIndexed { index, provider ->
                        SegmentedButton(
                            selected = selectedProvider == provider,
                            onClick = {
                                selectedProvider = provider
                                saved = false
                                val models = AIModel.modelsForProvider(provider)
                                if (selectedModel.provider != provider && models.isNotEmpty()) {
                                    selectedModel = models.first()
                                }
                            },
                            shape = SegmentedButtonDefaults.itemShape(index, AIProvider.entries.size),
                            colors = SegmentedButtonDefaults.colors(
                                activeContainerColor = colorScheme.primary,
                                activeContentColor = colorScheme.onPrimary,
                                inactiveContainerColor = colorScheme.surfaceContainerLow,
                                inactiveContentColor = colorScheme.onSurfaceVariant,
                                activeBorderColor = colorScheme.primary,
                                inactiveBorderColor = colorScheme.outlineVariant
                            )
                        ) {
                            Text(provider.displayName, fontSize = 11.sp)
                        }
                    }
                }

                Spacer(Modifier.height(20.dp))

                if (selectedProvider == AIProvider.LOCAL) {
                    // Local model section
                    Text("On-Device Model", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Load a GGUF model to run AI entirely on your device. No data leaves your phone. You can choose your own file or download a recommended Gemma model from Hugging Face.",
                        fontSize = 12.sp,
                        color = colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                        lineHeight = 16.sp
                    )

                    Spacer(Modifier.height(12.dp))

                    // Model status
                    if (localModelLoaded && localModelPath != null) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(Color(0xFF6EE7B7).copy(alpha = 0.1f), RoundedCornerShape(12.dp))
                                .border(1.dp, Color(0xFF6EE7B7).copy(alpha = 0.3f), RoundedCornerShape(12.dp))
                                .padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Icon(Icons.Default.CheckCircle, null, tint = Color(0xFF6EE7B7), modifier = Modifier.size(18.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Model loaded", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = Color(0xFF6EE7B7))
                                Text(
                                    localModelPath.substringAfterLast("/"),
                                    fontSize = 11.sp,
                                    color = colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }

                        Spacer(Modifier.height(8.dp))

                        OutlinedButton(
                            onClick = onUnloadLocalModel,
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Text("Unload Model")
                        }
                    } else {
                        // Recommended model downloads
                        Text("Recommended Downloads", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                        Spacer(Modifier.height(8.dp))

                        GEMMA_DOWNLOADS.forEach { model ->
                            val isDownloadingThis = downloadingModel?.fileName == model.fileName
                            OutlinedButton(
                                onClick = { startGemmaDownload(model) },
                                enabled = !localModelLoading && !copyingFile && downloadingModel == null,
                                modifier = Modifier.fillMaxWidth(),
                                shape = RoundedCornerShape(12.dp)
                            ) {
                                if (isDownloadingThis) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(16.dp),
                                        color = colorScheme.primary,
                                        strokeWidth = 2.dp
                                    )
                                    Text(
                                        "  ${model.label} ${formatDownloadProgress(downloadProgress)}",
                                        fontWeight = FontWeight.Medium
                                    )
                                } else {
                                    Icon(Icons.Default.Download, null, modifier = Modifier.size(18.dp))
                                    Column(
                                        modifier = Modifier
                                            .weight(1f)
                                            .padding(start = 8.dp),
                                        verticalArrangement = Arrangement.spacedBy(2.dp)
                                    ) {
                                        Text(model.label, fontWeight = FontWeight.Medium)
                                        Text(
                                            model.description,
                                            fontSize = 11.sp,
                                            color = colorScheme.onSurfaceVariant
                                        )
                                    }
                                }
                            }
                            Spacer(Modifier.height(8.dp))
                        }

                        // Load model button
                        Button(
                            onClick = { filePicker.launch(arrayOf("*/*")) },
                            enabled = !localModelLoading && !copyingFile && downloadingModel == null,
                            modifier = Modifier.fillMaxWidth().height(48.dp),
                            shape = RoundedCornerShape(12.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = colorScheme.primary,
                                contentColor = colorScheme.onPrimary
                            )
                        ) {
                            if (copyingFile) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    color = colorScheme.onPrimary,
                                    strokeWidth = 2.dp
                                )
                                Text("  Copying file...", fontWeight = FontWeight.Medium)
                            } else if (localModelLoading) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    color = colorScheme.onPrimary,
                                    strokeWidth = 2.dp
                                )
                                Text("  Loading model...", fontWeight = FontWeight.Medium)
                            } else {
                                Icon(Icons.Default.FileOpen, null, modifier = Modifier.size(18.dp))
                                Text("  Choose Model File", fontWeight = FontWeight.Medium)
                            }
                        }
                    }

                    val displayError = copyError ?: downloadError ?: localModelError
                    displayError?.let {
                        Spacer(Modifier.height(8.dp))
                        Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.error, lineHeight = 16.sp)
                    }
                } else {
                    // Cloud API key section
                    Text(
                        "${selectedProvider.displayName} API Key",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        color = colorScheme.onSurfaceVariant
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        when (selectedProvider) {
                            AIProvider.GEMINI -> "Get a key at aistudio.google.com"
                            AIProvider.OPENAI -> "Get a key at platform.openai.com"
                            AIProvider.CLAUDE -> "Get a key at console.anthropic.com"
                            else -> ""
                        },
                        fontSize = 12.sp,
                        color = colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                    )

                    Spacer(Modifier.height(8.dp))

                    OutlinedTextField(
                        value = currentKeyForProvider,
                        onValueChange = { newKey ->
                            when (selectedProvider) {
                                AIProvider.GEMINI -> geminiKey = newKey
                                AIProvider.OPENAI -> openaiKey = newKey
                                AIProvider.CLAUDE -> claudeKey = newKey
                                else -> {}
                            }
                            saved = false
                        },
                        placeholder = { Text("Paste your API key here...", fontSize = 14.sp) },
                        leadingIcon = {
                            Icon(Icons.Default.Key, null, tint = colorScheme.onSurfaceVariant.copy(alpha = 0.5f), modifier = Modifier.size(18.dp))
                        },
                        trailingIcon = {
                            IconButton(onClick = { showKey = !showKey }) {
                                Icon(
                                    if (showKey) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                    contentDescription = if (showKey) "Hide" else "Show",
                                    tint = colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                        },
                        visualTransformation = if (showKey) VisualTransformation.None else PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth(),
                        colors = textFieldColors,
                        shape = RoundedCornerShape(12.dp),
                        singleLine = true,
                        textStyle = androidx.compose.ui.text.TextStyle(fontSize = 14.sp)
                    )

                    Spacer(Modifier.height(20.dp))

                    // Model selection
                    Text("Model", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(8.dp))

                    val availableModels = AIModel.modelsForProvider(selectedProvider)

                    ExposedDropdownMenuBox(
                        expanded = modelExpanded,
                        onExpandedChange = { modelExpanded = !modelExpanded }
                    ) {
                        OutlinedTextField(
                            value = selectedModel.displayName,
                            onValueChange = {},
                            readOnly = true,
                            modifier = Modifier
                                .fillMaxWidth()
                                .menuAnchor(MenuAnchorType.PrimaryNotEditable),
                            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 14.sp, color = colorScheme.onSurface),
                            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = modelExpanded) },
                            colors = textFieldColors,
                            shape = RoundedCornerShape(12.dp),
                            singleLine = true
                        )
                        ExposedDropdownMenu(
                            expanded = modelExpanded,
                            onDismissRequest = { modelExpanded = false },
                            containerColor = colorScheme.surfaceContainer
                        ) {
                            availableModels.forEach { model ->
                                DropdownMenuItem(
                                    text = {
                                        Column {
                                            Text(model.displayName, color = colorScheme.onSurface, fontSize = 14.sp)
                                            Text(model.id, color = colorScheme.onSurfaceVariant.copy(alpha = 0.5f), fontSize = 11.sp)
                                        }
                                    },
                                    onClick = {
                                        selectedModel = model
                                        saved = false
                                        modelExpanded = false
                                    }
                                )
                            }
                        }
                    }
                }

                Spacer(Modifier.height(20.dp))

                Button(
                    onClick = {
                        onSaveApiKey(AIProvider.GEMINI, geminiKey.trim())
                        onSaveApiKey(AIProvider.OPENAI, openaiKey.trim())
                        onSaveApiKey(AIProvider.CLAUDE, claudeKey.trim())
                        onSaveProvider(selectedProvider)
                        if (selectedProvider != AIProvider.LOCAL) {
                            onSaveModel(selectedModel)
                        }
                        saved = true
                    },
                    modifier = Modifier.fillMaxWidth().height(48.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = colorScheme.primary,
                        contentColor = colorScheme.onPrimary
                    )
                ) {
                    Text(
                        if (saved) "Saved!" else "Save Settings",
                        fontWeight = FontWeight.Medium
                    )
                }

                if (saved) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Settings saved successfully.",
                        fontSize = 12.sp,
                        color = Color(0xFF6EE7B7).copy(alpha = 0.8f)
                    )
                }
            }
        }
    }
}

private fun formatDownloadProgress(progress: Float?): String {
    if (progress == null || progress <= 0f) return "downloading..."
    return "${String.format(Locale.US, "%.0f", progress * 100f)}%"
}
