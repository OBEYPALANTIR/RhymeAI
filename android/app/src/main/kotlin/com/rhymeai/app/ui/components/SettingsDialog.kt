package com.rhymeai.app.ui.components

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import com.rhymeai.app.service.ModelDownloader
import java.io.File
import java.util.Locale

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
    featuredModels: List<ModelDownloader.FeaturedModel>,
    downloadState: ModelDownloader.State,
    pendingMeteredModel: ModelDownloader.FeaturedModel?,
    onSaveApiKey: (AIProvider, String) -> Unit,
    onSaveProvider: (AIProvider) -> Unit,
    onSaveModel: (AIModel) -> Unit,
    onLoadLocalModel: (String) -> Unit,
    onUnloadLocalModel: () -> Unit,
    onRequestDownload: (ModelDownloader.FeaturedModel) -> Unit,
    onConfirmMeteredDownload: () -> Unit,
    onCancelMeteredPrompt: () -> Unit,
    onCancelDownload: () -> Unit,
    onDismissDownloadResult: () -> Unit,
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
    val coroutineScope = rememberCoroutineScope()

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let {
            copyingFile = true
            copyError = null
            coroutineScope.launch {
                try {
                    val destFile = withContext(Dispatchers.IO) {
                        val inputStream = context.contentResolver.openInputStream(it)
                            ?: throw Exception("Cannot open file")
                        val out = File(context.filesDir, "local_model.gguf")
                        if (out.exists()) out.delete()
                        // 256 KB buffer: large enough for fast copies, small enough
                        // to avoid OOM on devices with constrained Java heap.
                        inputStream.use { input ->
                            out.outputStream().buffered().use { output ->
                                input.copyTo(output, bufferSize = 256 * 1024)
                            }
                        }
                        out
                    }
                    copyingFile = false
                    onLoadLocalModel(destFile.absolutePath)
                } catch (e: Exception) {
                    e.printStackTrace()
                    copyingFile = false
                    copyError = "Failed to load file: ${e.message}"
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
                        "Run AI entirely on your device. No data leaves your phone.",
                        fontSize = 12.sp,
                        color = colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                        lineHeight = 16.sp
                    )

                    Spacer(Modifier.height(12.dp))

                    if (!localModelLoaded) {
                        FeaturedModelsSection(
                            featuredModels = featuredModels,
                            downloadState = downloadState,
                            disabled = localModelLoading || copyingFile,
                            onRequestDownload = onRequestDownload,
                            onCancelDownload = onCancelDownload,
                            onDismissResult = onDismissDownloadResult
                        )

                        Spacer(Modifier.height(16.dp))
                        HorizontalDivider(color = colorScheme.outlineVariant.copy(alpha = 0.5f))
                        Spacer(Modifier.height(12.dp))
                        Text(
                            "Or load your own GGUF",
                            fontSize = 12.sp,
                            color = colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                            fontWeight = FontWeight.Medium
                        )
                        Spacer(Modifier.height(8.dp))
                    }

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
                        // Load model button
                        Button(
                            onClick = { filePicker.launch(arrayOf("*/*")) },
                            enabled = !localModelLoading && !copyingFile,
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

                    val displayError = copyError ?: localModelError
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

    if (pendingMeteredModel != null) {
        AlertDialog(
            onDismissRequest = onCancelMeteredPrompt,
            title = { Text("Use mobile data?") },
            text = {
                Text(
                    "You're not on Wi-Fi. Downloading ${pendingMeteredModel.displayName} " +
                        "will use about ${pendingMeteredModel.approxSizeMb} MB of your mobile data."
                )
            },
            confirmButton = {
                TextButton(onClick = onConfirmMeteredDownload) { Text("Use mobile data") }
            },
            dismissButton = {
                TextButton(onClick = onCancelMeteredPrompt) { Text("Cancel") }
            }
        )
    }
}

@Composable
private fun FeaturedModelsSection(
    featuredModels: List<ModelDownloader.FeaturedModel>,
    downloadState: ModelDownloader.State,
    disabled: Boolean,
    onRequestDownload: (ModelDownloader.FeaturedModel) -> Unit,
    onCancelDownload: () -> Unit,
    onDismissResult: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val activeModelId: String? = when (downloadState) {
        is ModelDownloader.State.Resolving -> downloadState.model.id
        is ModelDownloader.State.Running -> downloadState.model.id
        else -> null
    }

    Text(
        "Featured models",
        fontSize = 12.sp,
        color = colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
        fontWeight = FontWeight.Medium
    )
    Spacer(Modifier.height(8.dp))

    featuredModels.forEach { model ->
        val isActive = activeModelId == model.id
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(colorScheme.surfaceContainer, RoundedCornerShape(12.dp))
                .border(1.dp, colorScheme.outlineVariant.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
                .padding(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        model.displayName,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        color = colorScheme.onSurface
                    )
                    Text(
                        model.description,
                        fontSize = 11.sp,
                        color = colorScheme.onSurfaceVariant
                    )
                }
                if (isActive) {
                    OutlinedButton(
                        onClick = onCancelDownload,
                        shape = RoundedCornerShape(10.dp)
                    ) { Text("Cancel", fontSize = 12.sp) }
                } else {
                    Button(
                        onClick = { onRequestDownload(model) },
                        enabled = !disabled && activeModelId == null,
                        shape = RoundedCornerShape(10.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = colorScheme.primary,
                            contentColor = colorScheme.onPrimary
                        )
                    ) {
                        Icon(Icons.Default.CloudDownload, null, modifier = Modifier.size(16.dp))
                        Text("  Download", fontSize = 12.sp, fontWeight = FontWeight.Medium)
                    }
                }
            }

            if (isActive) {
                Spacer(Modifier.height(10.dp))
                when (val s = downloadState) {
                    is ModelDownloader.State.Resolving -> {
                        Text(
                            "Resolving file…",
                            fontSize = 11.sp,
                            color = colorScheme.onSurfaceVariant
                        )
                        Spacer(Modifier.height(6.dp))
                        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    }
                    is ModelDownloader.State.Running -> {
                        val pct = (s.progress * 100).coerceIn(0f, 100f)
                        Text(
                            String.format(
                                Locale.getDefault(),
                                "%.0f%%   %s / %s",
                                pct,
                                formatBytes(s.downloadedBytes),
                                if (s.totalBytes > 0) formatBytes(s.totalBytes)
                                else "${model.approxSizeMb} MB"
                            ),
                            fontSize = 11.sp,
                            color = colorScheme.onSurfaceVariant
                        )
                        Spacer(Modifier.height(6.dp))
                        if (s.totalBytes > 0) {
                            LinearProgressIndicator(
                                progress = { s.progress.coerceIn(0f, 1f) },
                                modifier = Modifier.fillMaxWidth()
                            )
                        } else {
                            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                        }
                    }
                    else -> {}
                }
            }
        }

        if (downloadState is ModelDownloader.State.Failed && downloadState.model.id == model.id) {
            Spacer(Modifier.height(6.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    downloadState.message,
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.weight(1f)
                )
                TextButton(onClick = onDismissResult) { Text("Dismiss", fontSize = 11.sp) }
            }
        }

        Spacer(Modifier.height(8.dp))
    }
}

private fun formatBytes(bytes: Long): String {
    if (bytes <= 0) return "0 B"
    val units = arrayOf("B", "KB", "MB", "GB")
    var value = bytes.toDouble()
    var idx = 0
    while (value >= 1024 && idx < units.lastIndex) {
        value /= 1024
        idx++
    }
    return String.format(Locale.getDefault(), "%.1f %s", value, units[idx])
}
