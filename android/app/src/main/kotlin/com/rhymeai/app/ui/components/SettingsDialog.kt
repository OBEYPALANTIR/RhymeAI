package com.rhymeai.app.ui.components

import android.app.ActivityManager
import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.launch
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.statusBarsPadding
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
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Surface
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
import com.rhymeai.app.service.isGgufFile
import com.rhymeai.app.ui.theme.DesignTokens
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsDialog(
    apiKeyPresence: Map<String, Boolean>,
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
    // Gemma download state lives in MainViewModel so it survives leaving this
    // screen; the dialog only renders it and forwards intents.
    gemmaDownloadingModel: GemmaDownload? = null,
    gemmaDownloadProgress: Float? = null,
    gemmaDownloadError: String? = null,
    gemmaLastDownloadAttempt: GemmaDownload? = null,
    gemmaDownloadRevision: Int = 0,
    onStartGemmaDownload: (GemmaDownload) -> Unit = {},
    onUseDownloadedGemma: (GemmaDownload) -> Boolean = { false },
    // Drive sync
    syncPassphraseStored: Boolean = false,
    syncInProgress: Boolean = false,
    syncLastResult: String? = null,
    syncProgressLabel: String = "Syncing backup...",
    onSaveSyncPassphrase: (String) -> Unit = {},
    onSyncNow: () -> Unit = {},
    onRestoreNow: (() -> Unit)? = null,
    // Editor toggles — moved from AssistantPanel to Settings so the panel stays clean.
    useWholeSongContext: Boolean = false,
    onWholeSongContextChange: (Boolean) -> Unit = {},
    isStressPreviewEnabled: Boolean = false,
    onStressPreviewChange: (Boolean) -> Unit = {},
    isHighlightEnabled: Boolean = true,
    onHighlightChange: (Boolean) -> Unit = {},
    isSyllableColoringEnabled: Boolean = true,
    onSyllableColoringChange: (Boolean) -> Unit = {},
    isRhymeHighlightEnabled: Boolean = false,
    onRhymeHighlightChange: (Boolean) -> Unit = {},
    isBeatGridEnabled: Boolean = false,
    onBeatGridChange: (Boolean) -> Unit = {},
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val context = LocalContext.current
    val animationsEnabled = com.rhymeai.app.ui.theme.LocalAnimationsEnabled.current

    // Read total RAM once — used to show which Gemma model fits this device.
    val deviceTotalRamBytes = remember(context) {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        info.totalMem
    }
    val recommendedModel = remember(deviceTotalRamBytes) {
        recommendedGemmaModel(deviceTotalRamBytes)
    }

    // "General" = 0, "Editor" = 1 — which tab of the settings dialog is shown.
    var settingsTab by remember { mutableStateOf(0) }
    var activeHelp by remember { mutableStateOf<FeatureHelp?>(null) }

    activeHelp?.let { help ->
        FeatureHelpDialog(help = help, onDismiss = { activeHelp = null })
    }

    var selectedProvider by remember { mutableStateOf(currentProvider) }
    var selectedModel by remember { mutableStateOf(currentModel) }
    // Saved key values never enter Compose state: fields are write-only and start
    // empty; an empty field on save leaves the stored key untouched.
    var geminiKey by remember { mutableStateOf("") }
    var openaiKey by remember { mutableStateOf("") }
    var claudeKey by remember { mutableStateOf("") }
    var showKey by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(false) }
    var modelExpanded by remember { mutableStateOf(false) }

    // Sync passphrase field — write-only like API key fields; empty = do not change stored value.
    var syncPassphraseField by remember { mutableStateOf("") }
    var showSyncPassphrase by remember { mutableStateOf(false) }

    // File picker for local models
    var copyingFile by remember { mutableStateOf(false) }
    var copyError by remember { mutableStateOf<String?>(null) }
    val coroutineScope = rememberCoroutineScope()

    fun useDownloadedModel(model: GemmaDownload) {
        if (onUseDownloadedGemma(model)) {
            selectedProvider = AIProvider.LOCAL
            selectedModel = AIModel.LOCAL_MODEL
            saved = true
        }
    }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let {
            copyingFile = true
            copyError = null
            coroutineScope.launch(Dispatchers.IO) {
                try {
                    val inputStream = context.contentResolver.openInputStream(it)
                        ?: throw Exception("Cannot open file")
                    val fileName = "local_model.gguf"
                    val destFile = File(context.filesDir, fileName)
                    // Delete old model file if exists
                    if (destFile.exists()) destFile.delete()
                    inputStream.use { input ->
                        destFile.outputStream().buffered().use { output ->
                            input.copyTo(output, bufferSize = DOWNLOAD_BUFFER_BYTES)
                        }
                    }
                    if (!destFile.isGgufFile()) {
                        destFile.delete()
                        throw Exception("Selected file is not a GGUF model")
                    }
                    withContext(Dispatchers.Main) {
                        copyingFile = false
                        selectedProvider = AIProvider.LOCAL
                        selectedModel = AIModel.LOCAL_MODEL
                        onSaveProvider(AIProvider.LOCAL)
                        onSaveModel(AIModel.LOCAL_MODEL)
                        onLoadLocalModel(destFile.absolutePath)
                        saved = true
                    }
                } catch (e: Exception) {
                    Log.w("RhymeAI", "Local model file copy failed", e)
                    withContext(Dispatchers.Main) {
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

    // Full-screen page slide-in/out lifecycle (mirrors ProjectsDrawer). pageVisible
    // drives the enter/exit animation; closePage() plays the exit before the host
    // (MainActivity's `if (showSettingsDialog)`) removes us via onDismiss().
    var pageVisible by remember { mutableStateOf(false) }
    var isClosing by remember { mutableStateOf(false) }
    fun closePage() {
        if (isClosing) return
        isClosing = true
        pageVisible = false
        coroutineScope.launch {
            delay(DesignTokens.Motion.dismissMillis.toLong())
            onDismiss()
        }
    }
    LaunchedEffect(Unit) { pageVisible = true }

    Dialog(
        onDismissRequest = { closePage() },
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false
        )
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            AnimatedVisibility(
                visible = pageVisible,
                // Pure slide with an accelerate-curve exit on the faster dismiss
                // tier — matches the drawer/trash pages (exit-faster-than-enter).
                enter = slideInHorizontally(
                    animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.drawerPresentMillis else 0, easing = DesignTokens.Motion.standardEasing),
                    initialOffsetX = { it }
                ),
                exit = slideOutHorizontally(
                    animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.dismissMillis else 0, easing = DesignTokens.Motion.exitEasing),
                    targetOffsetX = { it }
                )
            ) {
                Surface(
                    modifier = Modifier
                        .fillMaxSize()
                        .imePadding(),
                    shape = RoundedCornerShape(0.dp),
                    color = colorScheme.surfaceContainerLow,
                    contentColor = colorScheme.onSurface,
                    tonalElevation = 8.dp
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .statusBarsPadding()
                            .padding(horizontal = DesignTokens.Spacing.lg)
                            .padding(top = DesignTokens.Spacing.lg)
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
                    IconButton(onClick = { closePage() }) {
                        Icon(Icons.Default.Close, contentDescription = "Close", tint = colorScheme.onSurfaceVariant)
                    }
                }

                Spacer(Modifier.height(DesignTokens.Spacing.lg))

                // General | Editor tab switcher
                SlidingSegmentedControl(
                    labels = listOf("General", "Editor"),
                    selectedIndex = settingsTab,
                    onSelect = { settingsTab = it },
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(Modifier.height(DesignTokens.Spacing.lg))

                // Only the tab content scrolls; header, tabs, and Save stay pinned.
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .padding(bottom = DesignTokens.Spacing.xxl)
                ) {

                if (settingsTab == 1) {
                    // ── Editor tab ────────────────────────────────────────────
                    // The six toggles previously living in the assistant panel,
                    // now here so the panel stays focused on generation controls.
                    EditorTogglesSection(
                        useWholeSongContext = useWholeSongContext,
                        onWholeSongContextChange = onWholeSongContextChange,
                        isStressPreviewEnabled = isStressPreviewEnabled,
                        onStressPreviewChange = onStressPreviewChange,
                        isHighlightEnabled = isHighlightEnabled,
                        onHighlightChange = onHighlightChange,
                        isSyllableColoringEnabled = isSyllableColoringEnabled,
                        onSyllableColoringChange = onSyllableColoringChange,
                        isRhymeHighlightEnabled = isRhymeHighlightEnabled,
                        onRhymeHighlightChange = onRhymeHighlightChange,
                        isBeatGridEnabled = isBeatGridEnabled,
                        onBeatGridChange = onBeatGridChange,
                        onHelp = { activeHelp = it },
                        colorScheme = colorScheme
                    )
                } else {
                // ── General tab (existing content) ────────────────────────────

                // Provider selector
                Text("AI Provider", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(8.dp))

                SlidingSegmentedControl(
                    labels = AIProvider.entries.map { it.displayName },
                    selectedIndex = AIProvider.entries.indexOf(selectedProvider),
                    onSelect = { index ->
                        val provider = AIProvider.entries[index]
                        selectedProvider = provider
                        saved = false
                        val models = AIModel.modelsForProvider(provider)
                        if (selectedModel.provider != provider && models.isNotEmpty()) {
                            selectedModel = models.first()
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    fontSize = 11.sp
                )

                Spacer(Modifier.height(DesignTokens.Spacing.lg))

                AnimatedContent(
                    targetState = selectedProvider,
                    contentAlignment = Alignment.TopStart,
                    transitionSpec = {
                        ContentTransform(
                            targetContentEnter = fadeIn(
                                animationSpec = tween(
                                    durationMillis = DesignTokens.Motion.standardMillis,
                                    easing = DesignTokens.Motion.standardEasing
                                )
                            ),
                            initialContentExit = fadeOut(
                                animationSpec = tween(
                                    durationMillis = DesignTokens.Motion.standardMillis,
                                    easing = DesignTokens.Motion.standardEasing
                                )
                            ),
                            sizeTransform = SizeTransform(clip = false) { _, _ ->
                                tween(
                                    durationMillis = DesignTokens.Motion.standardMillis,
                                    easing = DesignTokens.Motion.standardEasing
                                )
                            }
                        )
                    },
                    label = "settingsProviderContent"
                ) { providerForContent ->
                    Column(modifier = Modifier.fillMaxWidth()) {
                        if (providerForContent == AIProvider.LOCAL) {
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
                                        .background(colorScheme.tertiaryContainer, RoundedCornerShape(DesignTokens.Radius.lg))
                                        .border(1.dp, colorScheme.tertiary, RoundedCornerShape(DesignTokens.Radius.lg))
                                        .padding(12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Icon(Icons.Default.CheckCircle, null, tint = colorScheme.onTertiaryContainer, modifier = Modifier.size(18.dp))
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text("Model loaded", fontSize = DesignTokens.Typography.caption, fontWeight = FontWeight.Medium, color = colorScheme.onTertiaryContainer)
                                        Text(
                                            localModelPath.substringAfterLast("/"),
                                            fontSize = 11.sp,
                                            color = colorScheme.onTertiaryContainer.copy(alpha = 0.8f),
                                            maxLines = 1,
                                            overflow = TextOverflow.Ellipsis
                                        )
                                    }
                                }

                                Spacer(Modifier.height(8.dp))

                                OutlinedButton(
                                    onClick = onUnloadLocalModel,
                                    modifier = Modifier.fillMaxWidth(),
                                    shape = RoundedCornerShape(DesignTokens.Radius.lg)
                                ) {
                                    Text("Unload Model")
                                }
                            } else {
                                // Recommended model downloads
                                Text("Recommended Downloads", fontSize = DesignTokens.Typography.caption, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                                Spacer(Modifier.height(8.dp))

                                GEMMA_DOWNLOADS.forEach { model ->
                                    val installedFile = File(context.filesDir, model.fileName)
                                    val installedError = remember(gemmaDownloadRevision, model.fileName) {
                                        validateDownloadedGemma(model, installedFile)
                                    }
                                    val isInstalled = installedError == null
                                    val installedLabel = if (isInstalled) {
                                        "Downloaded - ${formatFileSize(installedFile.length())}"
                                    } else {
                                        model.description
                                    }
                                    val isDownloadingThis = gemmaDownloadingModel?.fileName == model.fileName
                                    val isRecommended = model.fileName == recommendedModel.fileName
                                    // Warn on the non-recommended model so users know it may thrash;
                                    // downloading is still allowed — just not the best fit for this device.
                                    val exceedsRam = !isRecommended
                                    OutlinedButton(
                                        onClick = {
                                            if (isInstalled) {
                                                useDownloadedModel(model)
                                            } else {
                                                onStartGemmaDownload(model)
                                            }
                                        },
                                        enabled = !localModelLoading && !copyingFile && gemmaDownloadingModel == null,
                                        modifier = Modifier.fillMaxWidth(),
                                        shape = RoundedCornerShape(DesignTokens.Radius.lg)
                                    ) {
                                        if (isDownloadingThis) {
                                            CircularProgressIndicator(
                                                modifier = Modifier.size(16.dp),
                                                color = colorScheme.primary,
                                                strokeWidth = 2.dp
                                            )
                                            Text(
                                                "  ${model.label} ${formatDownloadProgress(gemmaDownloadProgress)}",
                                                fontWeight = FontWeight.Medium
                                            )
                                        } else {
                                            Icon(
                                                if (isInstalled) Icons.Default.CheckCircle else Icons.Default.Download,
                                                null,
                                                modifier = Modifier.size(18.dp)
                                            )
                                            Column(
                                                modifier = Modifier
                                                    .weight(1f)
                                                    .padding(start = 8.dp),
                                                verticalArrangement = Arrangement.spacedBy(2.dp)
                                            ) {
                                                Row(
                                                    verticalAlignment = Alignment.CenterVertically,
                                                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                                                ) {
                                                    Text(model.label, fontWeight = FontWeight.Medium)
                                                    if (isRecommended) {
                                                        Text(
                                                            "Recommended for this device",
                                                            fontSize = 10.sp,
                                                            fontWeight = FontWeight.Medium,
                                                            color = colorScheme.onTertiaryContainer,
                                                            modifier = Modifier
                                                                .background(
                                                                    colorScheme.tertiaryContainer,
                                                                    RoundedCornerShape(4.dp)
                                                                )
                                                                .padding(horizontal = DesignTokens.Spacing.xs, vertical = 2.dp)
                                                        )
                                                    }
                                                }
                                                Text(
                                                    installedLabel,
                                                    fontSize = 11.sp,
                                                    color = colorScheme.onSurfaceVariant
                                                )
                                                if (exceedsRam) {
                                                    Text(
                                                        "May be slow on this device — needs more memory",
                                                        fontSize = 11.sp,
                                                        color = colorScheme.error.copy(alpha = 0.75f)
                                                    )
                                                }
                                            }
                                        }
                                    }
                                    Spacer(Modifier.height(8.dp))
                                }

                                // Load model button
                                Button(
                                    onClick = { filePicker.launch(arrayOf("*/*")) },
                                    enabled = !localModelLoading && !copyingFile && gemmaDownloadingModel == null,
                                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                                    shape = RoundedCornerShape(DesignTokens.Radius.lg),
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
                                        Spacer(Modifier.width(8.dp))
                                        Text("Copying file...", fontWeight = FontWeight.Medium)
                                    } else if (localModelLoading) {
                                        CircularProgressIndicator(
                                            modifier = Modifier.size(16.dp),
                                            color = colorScheme.onPrimary,
                                            strokeWidth = 2.dp
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        Text("Loading model...", fontWeight = FontWeight.Medium)
                                    } else {
                                        Icon(Icons.Default.FileOpen, null, modifier = Modifier.size(18.dp))
                                        Spacer(Modifier.width(8.dp))
                                        Text("Choose Model File", fontWeight = FontWeight.Medium)
                                    }
                                }
                            }

                            val displayError = copyError ?: gemmaDownloadError ?: localModelError
                            displayError?.let { errorText ->
                                Spacer(Modifier.height(8.dp))
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    Text(
                                        errorText,
                                        fontSize = 12.sp,
                                        color = MaterialTheme.colorScheme.error,
                                        lineHeight = 16.sp,
                                        modifier = Modifier.weight(1f)
                                    )
                                    val retryTarget = gemmaLastDownloadAttempt
                                    when {
                                        gemmaDownloadError != null && retryTarget != null -> {
                                            TextButton(onClick = { onStartGemmaDownload(retryTarget) }) {
                                                Text("Retry")
                                            }
                                        }
                                        copyError != null -> {
                                            TextButton(onClick = {
                                                copyError = null
                                                filePicker.launch(arrayOf("*/*"))
                                            }) {
                                                Text("Try again")
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            val keyForContent = when (providerForContent) {
                                AIProvider.GEMINI -> geminiKey
                                AIProvider.OPENAI -> openaiKey
                                AIProvider.CLAUDE -> claudeKey
                                AIProvider.LOCAL -> ""
                            }
                            val providerHasSavedKey = apiKeyPresence[providerForContent.name] == true

                            // Cloud API key section
                            Text(
                                "${providerForContent.displayName} API Key",
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                                color = colorScheme.onSurfaceVariant
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                when (providerForContent) {
                                    AIProvider.GEMINI -> "Get a key at aistudio.google.com"
                                    AIProvider.OPENAI -> "Get a key at platform.openai.com"
                                    AIProvider.CLAUDE -> "Get a key at console.anthropic.com"
                                    AIProvider.LOCAL -> ""
                                },
                                fontSize = 12.sp,
                                color = colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
                            )

                            Spacer(Modifier.height(8.dp))

                            OutlinedTextField(
                                value = keyForContent,
                                onValueChange = { newKey ->
                                    when (providerForContent) {
                                        AIProvider.GEMINI -> geminiKey = newKey
                                        AIProvider.OPENAI -> openaiKey = newKey
                                        AIProvider.CLAUDE -> claudeKey = newKey
                                    }
                                    saved = false
                                },
                                placeholder = {
                                    Text(
                                        if (providerHasSavedKey) "Key saved — type to replace" else "Paste your API key here...",
                                        fontSize = 14.sp
                                    )
                                },
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
                                shape = RoundedCornerShape(DesignTokens.Radius.lg),
                                singleLine = true,
                                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 14.sp)
                            )

                            if (providerHasSavedKey && keyForContent.isEmpty()) {
                                TextButton(onClick = {
                                    onSaveApiKey(providerForContent, "")
                                    saved = false
                                }) {
                                    Text("Remove saved key", fontSize = 12.sp)
                                }
                            }

                            Spacer(Modifier.height(DesignTokens.Spacing.lg))

                            // Model selection
                            Text("Model", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                            Spacer(Modifier.height(8.dp))

                            val availableModels = AIModel.modelsForProvider(providerForContent)
                            val displayedModel = if (selectedModel.provider == providerForContent) {
                                selectedModel
                            } else {
                                availableModels.firstOrNull() ?: selectedModel
                            }

                            ExposedDropdownMenuBox(
                                expanded = modelExpanded,
                                onExpandedChange = { modelExpanded = !modelExpanded }
                            ) {
                                OutlinedTextField(
                                    value = displayedModel.displayName,
                                    onValueChange = {},
                                    readOnly = true,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .menuAnchor(MenuAnchorType.PrimaryNotEditable),
                                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 14.sp, color = colorScheme.onSurface),
                                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = modelExpanded) },
                                    colors = textFieldColors,
                                    shape = RoundedCornerShape(DesignTokens.Radius.lg),
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
                    }
                }

                // ---------------------------------------------------------------
                // Drive Sync section
                // ---------------------------------------------------------------
                Spacer(Modifier.height(DesignTokens.Spacing.xxl))
                androidx.compose.material3.HorizontalDivider(
                    color = colorScheme.outlineVariant.copy(alpha = 0.4f),
                    thickness = 0.5.dp
                )
                Spacer(Modifier.height(DesignTokens.Spacing.lg))

                Text(
                    "Cloud Sync (Google Drive)",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "Backs up projects, trash, and recordings to Google Drive. API keys stay on this device. Backup is encrypted with your passphrase.",
                    fontSize = 12.sp,
                    color = colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    lineHeight = 16.sp
                )
                Spacer(Modifier.height(8.dp))

                OutlinedTextField(
                    value = syncPassphraseField,
                    onValueChange = { syncPassphraseField = it },
                    placeholder = {
                        Text(
                            if (syncPassphraseStored) "Passphrase saved — type to replace" else "Set sync passphrase...",
                            fontSize = 14.sp
                        )
                    },
                    leadingIcon = {
                        Icon(Icons.Default.Key, null, tint = colorScheme.onSurfaceVariant.copy(alpha = 0.5f), modifier = Modifier.size(18.dp))
                    },
                    trailingIcon = {
                        IconButton(onClick = { showSyncPassphrase = !showSyncPassphrase }) {
                            Icon(
                                if (showSyncPassphrase) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                contentDescription = if (showSyncPassphrase) "Hide" else "Show",
                                tint = colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    },
                    visualTransformation = if (showSyncPassphrase) VisualTransformation.None else PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                    colors = textFieldColors,
                    shape = RoundedCornerShape(DesignTokens.Radius.lg),
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 14.sp)
                )

                Spacer(Modifier.height(8.dp))

                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedButton(
                        onClick = {
                            if (syncPassphraseField.isNotBlank()) {
                                onSaveSyncPassphrase(syncPassphraseField.trim())
                                syncPassphraseField = ""
                            }
                            onSyncNow()
                        },
                        enabled = !syncInProgress && (syncPassphraseStored || syncPassphraseField.isNotBlank()),
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(DesignTokens.Radius.lg)
                    ) {
                        if (syncInProgress) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(14.dp),
                                color = colorScheme.primary,
                                strokeWidth = 2.dp
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(syncProgressLabel, fontSize = DesignTokens.Typography.caption)
                        } else {
                            Text("Back up / sync now", fontSize = DesignTokens.Typography.caption)
                        }
                    }

                    onRestoreNow?.let { restore ->
                        OutlinedButton(
                            onClick = {
                                if (syncPassphraseField.isNotBlank()) {
                                    onSaveSyncPassphrase(syncPassphraseField.trim())
                                    syncPassphraseField = ""
                                }
                                restore()
                            },
                            enabled = !syncInProgress && (syncPassphraseStored || syncPassphraseField.isNotBlank()),
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(DesignTokens.Radius.lg)
                        ) {
                            Text("Restore from Drive", fontSize = DesignTokens.Typography.caption)
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    "Your songs and recordings are included in Android's automatic backup. Only the optional Google Drive backup is encrypted with your passphrase. API keys never leave this device.",
                    fontSize = 12.sp,
                    color = colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    lineHeight = 16.sp
                )

                syncLastResult?.let { result ->
                    Spacer(Modifier.height(6.dp))
                    Text(
                        result,
                        fontSize = 11.sp,
                        color = if (result.startsWith("Sync complete") || result.startsWith("Restore complete")) colorScheme.tertiary
                        else colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                        lineHeight = 15.sp
                    )
                }

                } // end else (General tab)

                } // end scrollable content

                // Pinned save bar — always reachable regardless of content height.
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = DesignTokens.Spacing.sm)
                        .bottomSafeActionPadding(extra = DesignTokens.Spacing.sm)
                ) {
                    Button(
                        onClick = {
                            // Empty fields mean "keep the stored key" — only save typed values.
                            if (geminiKey.isNotBlank()) onSaveApiKey(AIProvider.GEMINI, geminiKey.trim())
                            if (openaiKey.isNotBlank()) onSaveApiKey(AIProvider.OPENAI, openaiKey.trim())
                            if (claudeKey.isNotBlank()) onSaveApiKey(AIProvider.CLAUDE, claudeKey.trim())
                            onSaveProvider(selectedProvider)
                            if (selectedProvider != AIProvider.LOCAL) {
                                onSaveModel(selectedModel)
                            }
                            saved = true
                        },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                        shape = RoundedCornerShape(DesignTokens.Radius.lg),
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
                }
            }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Editor toggles section — shown inside the "Editor" tab of SettingsDialog
// ---------------------------------------------------------------------------

@Composable
private fun EditorTogglesSection(
    useWholeSongContext: Boolean,
    onWholeSongContextChange: (Boolean) -> Unit,
    isStressPreviewEnabled: Boolean,
    onStressPreviewChange: (Boolean) -> Unit,
    isHighlightEnabled: Boolean,
    onHighlightChange: (Boolean) -> Unit,
    isSyllableColoringEnabled: Boolean,
    onSyllableColoringChange: (Boolean) -> Unit,
    isRhymeHighlightEnabled: Boolean,
    onRhymeHighlightChange: (Boolean) -> Unit,
    isBeatGridEnabled: Boolean,
    onBeatGridChange: (Boolean) -> Unit,
    onHelp: (FeatureHelp) -> Unit,
    colorScheme: androidx.compose.material3.ColorScheme
) {
    val switchColors = SwitchDefaults.colors(
        checkedThumbColor = colorScheme.onPrimary,
        checkedTrackColor = colorScheme.primary,
        uncheckedThumbColor = colorScheme.onSurfaceVariant,
        uncheckedTrackColor = colorScheme.surfaceContainerHighest
    )

    Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)) {
        EditorToggleRow(
            label = "Whole Song Context",
            help = FeatureHelp.WHOLE_SONG_CONTEXT,
            checked = useWholeSongContext,
            onCheckedChange = onWholeSongContextChange,
            onHelp = onHelp,
            switchColors = switchColors,
            colorScheme = colorScheme
        )
        EditorToggleRow(
            label = "Stress + IPA",
            help = FeatureHelp.STRESS_IPA,
            checked = isStressPreviewEnabled,
            onCheckedChange = onStressPreviewChange,
            onHelp = onHelp,
            switchColors = switchColors,
            colorScheme = colorScheme,
            contentDescription = "Toggle Stress + IPA"
        )
        EditorToggleRow(
            label = "Highlight Rhymes",
            help = FeatureHelp.HIGHLIGHT_RHYMES,
            checked = isHighlightEnabled,
            onCheckedChange = onHighlightChange,
            onHelp = onHelp,
            switchColors = switchColors,
            colorScheme = colorScheme
        )
        EditorToggleRow(
            label = "Underline Syllables",
            help = FeatureHelp.UNDERLINE_SYLLABLES,
            checked = isSyllableColoringEnabled,
            onCheckedChange = onSyllableColoringChange,
            onHelp = onHelp,
            switchColors = switchColors,
            colorScheme = colorScheme
        )
        EditorToggleRow(
            label = "Color Rhymes",
            help = FeatureHelp.COLOR_RHYMES,
            checked = isRhymeHighlightEnabled,
            onCheckedChange = onRhymeHighlightChange,
            onHelp = onHelp,
            switchColors = switchColors,
            colorScheme = colorScheme
        )
        EditorToggleRow(
            label = "Beat Grid",
            help = FeatureHelp.BEAT_GRID,
            checked = isBeatGridEnabled,
            onCheckedChange = onBeatGridChange,
            onHelp = onHelp,
            switchColors = switchColors,
            colorScheme = colorScheme,
            contentDescription = "Toggle Beat Grid"
        )
    }
}

@Composable
private fun EditorToggleRow(
    label: String,
    help: FeatureHelp,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    onHelp: (FeatureHelp) -> Unit,
    switchColors: androidx.compose.material3.SwitchColors,
    colorScheme: androidx.compose.material3.ColorScheme,
    contentDescription: String? = null
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        FeatureHelpLabel(
            text = label,
            help = help,
            onHelp = onHelp,
            color = colorScheme.onSurfaceVariant
        )
        val switchModifier = if (contentDescription != null) {
            Modifier.semantics { this.contentDescription = contentDescription }
        } else {
            Modifier
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            modifier = switchModifier,
            colors = switchColors
        )
    }
}
