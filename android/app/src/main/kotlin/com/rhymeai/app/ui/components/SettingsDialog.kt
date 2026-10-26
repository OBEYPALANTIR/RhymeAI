package com.rhymeai.app.ui.components

import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.ui.unit.IntSize
import com.rhymeai.app.data.sync.backupStatusLine
import android.app.ActivityManager
import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.KeyboardArrowDown
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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import android.os.SystemClock
import kotlinx.coroutines.delay
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.data.model.SavedLocalModel
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.appWritingSurface
import com.rhymeai.app.ui.theme.outlineStrongColorFor
import com.rhymeai.app.ui.theme.placeholderColorFor
import com.rhymeai.app.ui.theme.subtleColorFor
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsDialog(
    currentAppearance: AppAppearance,
    onAppearanceChange: (AppAppearance) -> Unit,
    apiKeyPresence: Map<String, Boolean>,
    currentProvider: AIProvider,
    currentModel: AIModel,
    localModelLoading: Boolean,
    localModelLoaded: Boolean,
    localModelPath: String?,
    localModelError: String?,
    savedLocalModels: List<SavedLocalModel>,
    selectedLocalModelId: String?,
    onApplyAISettings: suspend (AIProvider, AIModel, Map<AIProvider, String>) -> Result<Unit>,
    hasCloudAISharingConsent: (AIProvider, com.rhymeai.app.CloudAISharingScope) -> Boolean = { _, _ -> false },
    onCloudAISharingConsentChange: (AIProvider, com.rhymeai.app.CloudAISharingScope, Boolean) -> Unit = { _, _, _ -> },
    onSaveProvider: (AIProvider) -> Unit,
    onSaveModel: (AIModel) -> Unit,
    onRegisterLocalModel: (String, String) -> Unit,
    onSelectSavedLocalModel: (String) -> Unit,
    onUnloadLocalModel: () -> Unit,
    // Gemma download state lives in MainViewModel so it survives leaving this
    // screen; the dialog only renders it and forwards intents.
    gemmaDownloadingModel: GemmaDownload? = null,
    gemmaDownloadProgress: Float? = null,
    gemmaDownloadVerifying: Boolean = false,
    gemmaDownloadError: String? = null,
    gemmaLastDownloadAttempt: GemmaDownload? = null,
    gemmaDownloadRevision: Int = 0,
    verifiedGemmaFileNames: Set<String> = emptySet(),
    onStartGemmaDownload: (GemmaDownload) -> Unit = {},
    onUseDownloadedGemma: suspend (GemmaDownload) -> Boolean = { false },
    onDeleteDownloadedGemma: (GemmaDownload) -> Unit = {},
    gemmaDeletingModel: GemmaDownload? = null,
    onPauseGemmaDownload: () -> Unit = {},
    onCancelGemmaDownload: (GemmaDownload) -> Unit = {},
    onDeleteCustomLocalModel: (String) -> Unit = {},
    deletingCustomModelId: String? = null,
    localModelFreed: com.rhymeai.app.LocalModelFreed? = null,
    // True while a suggestion, rewrite or synonym request is running on the local model.
    localModelGenerating: Boolean = false,
    // Backup
    backup: BackupSectionState = BackupSectionState(),
    backupActions: BackupSectionActions = BackupSectionActions(),
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
    val appearance = LocalAppAppearance.current
    val placeholderColor = placeholderColorFor(appearance)
    val subtleColor = subtleColorFor(appearance)
    val outlineStrongColor = outlineStrongColorFor(appearance)
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
    var keysToRemove by remember { mutableStateOf(emptySet<AIProvider>()) }
    var showKey by remember { mutableStateOf(false) }
    var saved by remember { mutableStateOf(false) }
    var applyingAISettings by remember { mutableStateOf(false) }
    var applyAIError by remember { mutableStateOf<String?>(null) }
    var aiSetupExpanded by remember { mutableStateOf(false) }
    var aboutExpanded by remember { mutableStateOf(false) }
    var modelExpanded by remember { mutableStateOf(false) }

    // Progressive disclosure: Backup collapses to a single header row
    // until the user opens it — General stays scannable.
    var syncSectionExpanded by remember { mutableStateOf(false) }

    // File picker for local models
    var copyingFile by remember { mutableStateOf(false) }
    var copyError by remember { mutableStateOf<String?>(null) }
    val coroutineScope = rememberCoroutineScope()

    var deleteRequest by remember { mutableStateOf<ModelDeleteRequest?>(null) }
    deleteRequest?.let { request ->
        AlertDialog(
            onDismissRequest = { deleteRequest = null },
            containerColor = colorScheme.surfaceContainerHigh,
            title = { Text("Delete ${request.title}?", style = MaterialTheme.typography.headlineSmall) },
            text = {
                Text(
                    modelDeleteMessage(request.bytes, request.custom, request.inUse),
                    style = MaterialTheme.typography.bodyMedium,
                    color = colorScheme.onSurfaceVariant
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    deleteRequest = null
                    copyError = null // an older import error must not hide a delete failure
                    request.confirm()
                }) {
                    Text("Delete", color = colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteRequest = null }) { Text("Cancel") }
            }
        )
    }

    // The freed line holds for the toast lifetime from the moment the delete finished.
    var visibleFreed by remember { mutableStateOf<com.rhymeai.app.LocalModelFreed?>(null) }
    val view = LocalView.current
    LaunchedEffect(localModelFreed) {
        val freed = localModelFreed
        visibleFreed = null
        if (freed == null) return@LaunchedEffect
        val shownMillis = SystemClock.uptimeMillis() - freed.atUptimeMillis
        if (shownMillis >= MODEL_FREED_LINE_MILLIS) return@LaunchedEffect
        if (shownMillis < 1_000L) {
            @Suppress("DEPRECATION") // still delivered on API 36; the row has no other node to announce from
            view.announceForAccessibility("${freed.label} deleted. ${formatFileSize(freed.bytes)} back for your songs.")
        }
        visibleFreed = freed
        delay(MODEL_FREED_LINE_MILLIS - shownMillis)
        visibleFreed = null
    }

    fun useDownloadedModel(model: GemmaDownload) {
        copyingFile = true
        coroutineScope.launch {
            try {
                if (onUseDownloadedGemma(model)) {
                    selectedProvider = AIProvider.LOCAL
                    selectedModel = AIModel.LOCAL_MODEL
                    saved = true
                }
            } finally {
                copyingFile = false
            }
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
                    val sourceName = context.contentResolver.query(
                        it,
                        arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                        null,
                        null,
                        null
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getString(0) else null
                    } ?: "Custom Model.gguf"
                    val fileName = "custom-${java.util.UUID.randomUUID()}.gguf"
                    val destFile = File(context.filesDir, fileName)
                    val maxBytes = maxLocalModelImportBytes(context.filesDir)
                    val declaredBytes = context.contentResolver
                        .openAssetFileDescriptor(it, "r")
                        ?.use { descriptor -> descriptor.length }
                        ?: -1L
                    if (declaredBytes > maxBytes) {
                        throw IllegalArgumentException("Model file is too large for this device.")
                    }
                    copyLocalModelAtomically(inputStream, destFile, maxBytes)
                    withContext(Dispatchers.Main) {
                        copyingFile = false
                        selectedProvider = AIProvider.LOCAL
                        selectedModel = AIModel.LOCAL_MODEL
                        onSaveProvider(AIProvider.LOCAL)
                        onSaveModel(AIModel.LOCAL_MODEL)
                        onRegisterLocalModel(
                            destFile.absolutePath,
                            sourceName.substringBeforeLast('.').ifBlank { "Custom Model" }
                        )
                        saved = true
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
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
        unfocusedBorderColor = outlineStrongColor,
        focusedBorderColor = colorScheme.primary,
        unfocusedContainerColor = colorScheme.surfaceContainerLow,
        focusedContainerColor = colorScheme.surfaceContainerLow,
        cursorColor = colorScheme.primary,
        unfocusedTextColor = colorScheme.onSurface,
        focusedTextColor = colorScheme.onSurface,
        unfocusedPlaceholderColor = placeholderColor,
        focusedPlaceholderColor = placeholderColor
    )

    val pageTransition = remember { MutableTransitionState(false).apply { targetState = true } }
    var isClosing by remember { mutableStateOf(false) }
    fun closePage() {
        if (isClosing) return
        isClosing = true
        pageTransition.targetState = false
    }
    LaunchedEffect(pageTransition.isIdle, pageTransition.currentState, isClosing) {
        if (isClosing && pageTransition.isIdle && !pageTransition.currentState) {
            onDismiss()
        }
    }

    BackHandler(onBack = ::closePage)

        Box(modifier = Modifier.fillMaxSize()) {
            AnimatedVisibility(
                visibleState = pageTransition,
                enter = fadeIn(animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.pageFadeMillis else 0, easing = DesignTokens.Motion.standardEasing)),
                exit = fadeOut(animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.pageFadeMillis else 0, easing = DesignTokens.Motion.exitEasing))
            ) {
                Surface(
                    modifier = Modifier
                        .fillMaxSize()
                        .appWritingSurface()
                        .imePadding()
                        .pointerInput(Unit) { detectTapGestures(onTap = {}) }
                        .semantics {
                            paneTitle = "Settings"
                            contentDescription = "Settings page"
                        },
                    shape = RoundedCornerShape(0.dp),
                    color = Color.Transparent,
                    contentColor = colorScheme.onSurface,
                    tonalElevation = 0.dp
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .statusBarsPadding()
                            .padding(horizontal = DesignTokens.Rhythm.standard)
                            .padding(top = DesignTokens.Rhythm.standard)
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
                        Icon(
                            Icons.Default.Settings,
                            null,
                            tint = colorScheme.primary,
                            modifier = Modifier.size(DesignTokens.Rhythm.standard)
                        )
                        Text(
                            "Settings",
                            fontWeight = FontWeight.Medium,
                            fontSize = 21.sp,
                            color = colorScheme.onSurface
                        )
                    }
                    IconButton(onClick = { closePage() }) {
                        Icon(Icons.Default.Close, contentDescription = "Close", tint = colorScheme.onSurfaceVariant)
                    }
                }

                Spacer(Modifier.height(DesignTokens.Rhythm.standard))

                // General | Editor tab switcher
                SlidingSegmentedControl(
                    labels = listOf("General", "Editor"),
                    selectedIndex = settingsTab,
                    onSelect = { settingsTab = it },
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(Modifier.height(DesignTokens.Rhythm.standard))

                // Only the tab content scrolls; header, tabs, and Save stay pinned.
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .padding(bottom = DesignTokens.Rhythm.section)
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

                AppearanceSelector(
                    currentAppearance = currentAppearance,
                    onAppearanceChange = onAppearanceChange,
                    modifier = Modifier.fillMaxWidth()
                )

                Spacer(Modifier.height(DesignTokens.Rhythm.section))

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { aiSetupExpanded = !aiSetupExpanded }
                        .heightIn(min = DesignTokens.Touch.minTarget),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("AI setup", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                        Text(
                            "${selectedProvider.displayName} · ${if (selectedProvider == AIProvider.LOCAL) "On-device model" else selectedModel.displayName}",
                            fontSize = 12.sp,
                            color = subtleColor,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    Icon(
                        Icons.Default.KeyboardArrowDown,
                        contentDescription = if (aiSetupExpanded) "Collapse AI setup" else "Expand AI setup",
                        tint = colorScheme.onSurfaceVariant,
                        modifier = Modifier.rotate(if (aiSetupExpanded) 180f else 0f)
                    )
                }

                AnimatedVisibility(
                    visible = aiSetupExpanded,
                    enter = if (animationsEnabled) expandVertically(tween(DesignTokens.Motion.feedbackMillis, easing = DesignTokens.Motion.standardEasing), expandFrom = Alignment.Top) else androidx.compose.animation.EnterTransition.None,
                    exit = if (animationsEnabled) shrinkVertically(tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing), shrinkTowards = Alignment.Top) else androidx.compose.animation.ExitTransition.None
                ) {
                Column(Modifier.fillMaxWidth()) {
                Spacer(Modifier.height(DesignTokens.Spacing.sm))
                if (selectedProvider != AIProvider.LOCAL) {
                    Text("Sharing with ${selectedProvider.displayName}", fontWeight = FontWeight.Medium, color = colorScheme.onSurface)
                    Text(
                        "Suggestions send your target line, theme and rhyme settings. Rewrites send the selected passage. Synonyms send the selected word and its current line. Whole Song Context also sends the full lyric for suggestions and rewrites. API keys are stored encrypted on this device and sent to the selected provider for authentication. You can revoke sharing below.",
                        color = colorScheme.onSurfaceVariant,
                        fontSize = DesignTokens.Typography.caption
                    )
                    com.rhymeai.app.CloudAISharingScope.entries.forEach { scope ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("Allow ${scope.label.lowercase()}", modifier = Modifier.weight(1f), color = colorScheme.onSurface)
                            Switch(
                                checked = hasCloudAISharingConsent(selectedProvider, scope),
                                onCheckedChange = { onCloudAISharingConsentChange(selectedProvider, scope, it) },
                                modifier = Modifier.semantics { contentDescription = "Allow ${scope.label.lowercase()} with ${selectedProvider.displayName}" }
                            )
                        }
                    }
                    Spacer(Modifier.height(DesignTokens.Spacing.md))
                }
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
                    fontSize = 12.sp
                )

                Spacer(Modifier.height(DesignTokens.Rhythm.section))

                AnimatedContent(
                    targetState = selectedProvider,
                    contentAlignment = Alignment.TopStart,
                    transitionSpec = {
                        ContentTransform(
                            targetContentEnter = fadeIn(
                                animationSpec = tween(
                                    durationMillis = if (animationsEnabled) DesignTokens.Motion.standardMillis else 0,
                                    easing = DesignTokens.Motion.standardEasing
                                )
                            ),
                            initialContentExit = fadeOut(
                                animationSpec = tween(
                                    durationMillis = if (animationsEnabled) DesignTokens.Motion.standardMillis else 0,
                                    easing = DesignTokens.Motion.standardEasing
                                )
                            ),
                            sizeTransform = SizeTransform(clip = false) { _, _ ->
                                tween(
                                    durationMillis = if (animationsEnabled) DesignTokens.Motion.standardMillis else 0,
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
                                "Load a Gemma GGUF model to run AI entirely on your device. No data leaves your phone. You can choose your own Gemma file or download a recommended one from Hugging Face; other model families are not supported.",
                                fontSize = 12.sp,
                                color = subtleColor,
                                lineHeight = 16.sp
                            )

                            Spacer(Modifier.height(12.dp))

                            val anyDeleting = gemmaDeletingModel != null || deletingCustomModelId != null
                            // The rule every row action shared before: nothing loads, copies or deletes.
                            val rowsIdle = !localModelLoading && !copyingFile && !anyDeleting
                            val customModels = savedLocalModels.filter { it.isCustom }
                            if (customModels.isNotEmpty()) {
                                Text(
                                    "Custom Models",
                                    fontSize = DesignTokens.Typography.caption,
                                    fontWeight = FontWeight.Medium,
                                    color = colorScheme.onSurfaceVariant
                                )
                                Spacer(Modifier.height(DesignTokens.Rhythm.tight))
                                customModels.forEach { model ->
                                    key(model.id) {
                                        val bytes = remember(model.fileName, gemmaDownloadRevision) {
                                            File(context.filesDir, model.fileName).length()
                                        }
                                        val isSelected = model.id == selectedLocalModelId
                                        ModelRow(
                                            state = customModelRowState(
                                                name = model.displayName,
                                                fileBytes = bytes,
                                                selected = isSelected,
                                                deleting = deletingCustomModelId == model.id
                                            ),
                                            chipEnabled = rowsIdle && gemmaDownloadingModel == null,
                                            columnEnabled = rowsIdle && !localModelGenerating,
                                            onChip = { if (!isSelected) onSelectSavedLocalModel(model.id) },
                                            onColumn = {
                                                deleteRequest = ModelDeleteRequest(model.displayName, bytes, custom = true, inUse = isSelected) {
                                                    onDeleteCustomLocalModel(model.id)
                                                }
                                            },
                                            mainTag = "customGGUF.${model.id}",
                                            deleteTag = "customGGUFDelete.${model.id}"
                                        )
                                        Spacer(Modifier.height(DesignTokens.Rhythm.tight))
                                    }
                                }
                            }

                            // Model status
                            val loadedModelVisible = localModelLoaded && localModelPath != null
                            val loadedStatusContent: @Composable () -> Unit = {
                                Column {
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
                                                savedLocalModels.firstOrNull { it.id == selectedLocalModelId }
                                                    ?.let { saved -> GEMMA_DOWNLOADS.firstOrNull { it.fileName == saved.fileName }?.label ?: saved.displayName }
                                                    ?: localModelPath.orEmpty().substringAfterLast("/"),
                                                fontSize = 12.sp,
                                                color = colorScheme.onTertiaryContainer.copy(alpha = 0.8f),
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                        }
                                    }

                                    Spacer(Modifier.height(8.dp))

                                    OutlinedButton(
                                        onClick = onUnloadLocalModel,
                                        enabled = loadedModelVisible,
                                        modifier = Modifier.fillMaxWidth().heightIn(min = DesignTokens.Touch.minTarget),
                                        shape = RoundedCornerShape(DesignTokens.Radius.lg)
                                    ) {
                                        Text("Unload Model")
                                    }
                                }
                            }
                            if (animationsEnabled) {
                                AnimatedVisibility(
                                    visible = loadedModelVisible,
                                    enter = expandVertically(
                                        tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing),
                                        expandFrom = Alignment.Top
                                    ),
                                    exit = shrinkVertically(
                                        tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing),
                                        shrinkTowards = Alignment.Top
                                    ) + fadeOut(tween(0))
                                ) {
                                    loadedStatusContent()
                                }
                            } else if (loadedModelVisible) {
                                loadedStatusContent()
                            }

                            run {
                                Spacer(Modifier.height(DesignTokens.Rhythm.related))
                                Text("RhymeAI Gemma Downloads", fontSize = DesignTokens.Typography.caption, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                                val noModelOnDevice = remember(gemmaDownloadRevision, customModels) {
                                    customModels.isEmpty() && GEMMA_DOWNLOADS.none { File(context.filesDir, it.fileName).isFile }
                                }
                                if (noModelOnDevice) {
                                    Spacer(Modifier.height(DesignTokens.Spacing.xs))
                                    Text(MODEL_ROW_EMPTY_NUDGE, fontSize = DesignTokens.Typography.caption, lineHeight = 16.sp, color = colorScheme.onSurfaceVariant)
                                }
                                Spacer(Modifier.height(DesignTokens.Rhythm.tight))

                                GEMMA_DOWNLOADS.forEach { model ->
                                    key(model.fileName) {
                                        val installedFile = File(context.filesDir, model.fileName)
                                        // Any file under the catalog name counts, a stale version included, so it can be reclaimed.
                                        val fileBytes = remember(gemmaDownloadRevision, model.fileName) {
                                            installedFile.takeIf { it.isFile }?.length()
                                        }
                                        val installedError = remember(gemmaDownloadRevision, model.fileName) {
                                            validateDownloadedGemma(model, installedFile)
                                        }
                                        val isDownloadingThis = gemmaDownloadingModel?.fileName == model.fileName
                                        // A paused or failed run keeps its resume state; the row offers Resume from it.
                                        val pausedBytes = remember(gemmaDownloadRevision, model.fileName, isDownloadingThis) {
                                            if (isDownloadingThis) null else gemmaPartialBytes(model, context.cacheDir)
                                        }
                                        val state = catalogModelRowState(
                                            model = model,
                                            fileBytes = fileBytes,
                                            verified = installedError == null && model.fileName in verifiedGemmaFileNames,
                                            selected = selectedLocalModelId == model.fileName,
                                            recommended = model.fileName == recommendedModel.fileName,
                                            needsMoreMemory = gemmaModelNeedsMoreMemory(model, deviceTotalRamBytes),
                                            downloading = isDownloadingThis,
                                            downloadProgress = gemmaDownloadProgress,
                                            verifying = gemmaDownloadVerifying,
                                            pausedBytes = pausedBytes,
                                            deleting = gemmaDeletingModel?.fileName == model.fileName,
                                            freedBytes = visibleFreed?.takeIf { it.fileName == model.fileName }?.bytes
                                        )
                                        ModelRow(
                                            state = state,
                                            chipEnabled = when (state.kind) {
                                                ModelRowKind.Starting, ModelRowKind.Downloading -> true
                                                else -> rowsIdle && gemmaDownloadingModel == null
                                            },
                                            columnEnabled = when (state.column) {
                                                ModelRowColumn.Cancel -> !anyDeleting
                                                // Disabled, not hidden, while the local model is loading or generating.
                                                ModelRowColumn.Trash -> rowsIdle && !localModelGenerating
                                                else -> false
                                            },
                                            onChip = {
                                                when (state.chip) {
                                                    ModelRowChip.Download, ModelRowChip.Resume, ModelRowChip.Update -> onStartGemmaDownload(model)
                                                    ModelRowChip.Pause -> onPauseGemmaDownload()
                                                    ModelRowChip.Use -> useDownloadedModel(model)
                                                    ModelRowChip.Selected, null -> Unit
                                                }
                                            },
                                            onColumn = {
                                                when (state.column) {
                                                    ModelRowColumn.Cancel -> onCancelGemmaDownload(model)
                                                    ModelRowColumn.Trash -> deleteRequest = ModelDeleteRequest(
                                                        model.label,
                                                        fileBytes ?: 0L,
                                                        custom = false,
                                                        inUse = selectedLocalModelId == model.fileName
                                                    ) { onDeleteDownloadedGemma(model) }
                                                    else -> Unit
                                                }
                                            },
                                            mainTag = "gemmaDownload.${model.fileName}",
                                            deleteTag = "gemmaDelete.${model.fileName}",
                                            cancelTag = "gemmaCancel.${model.fileName}"
                                        )
                                        Spacer(Modifier.height(DesignTokens.Rhythm.tight))
                                    }
                                }

                                // Load model button
                                Button(
                                    onClick = { filePicker.launch(arrayOf("*/*")) },
                                    enabled = rowsIdle && gemmaDownloadingModel == null,
                                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                                    shape = RoundedCornerShape(DesignTokens.Radius.lg),
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = colorScheme.primary,
                                        contentColor = colorScheme.onPrimary
                                    )
                                ) {
                                    Box(Modifier.size(18.dp), contentAlignment = Alignment.Center) {
                                        if (copyingFile || localModelLoading) {
                                            CircularProgressIndicator(
                                                modifier = Modifier.size(16.dp),
                                                color = colorScheme.onPrimary,
                                                strokeWidth = 2.dp
                                            )
                                        } else {
                                            Icon(Icons.Default.FileOpen, null, modifier = Modifier.size(18.dp))
                                        }
                                    }
                                    Spacer(Modifier.width(8.dp))
                                    Text(
                                        when {
                                            copyingFile -> "Copying file..."
                                            localModelLoading -> "Loading model..."
                                            else -> "Choose Model File"
                                        },
                                        fontWeight = FontWeight.Medium
                                    )
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
                            val providerHasSavedKey = apiKeyPresence[providerForContent.name] == true && providerForContent !in keysToRemove

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
                                color = subtleColor
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
                                    keysToRemove = keysToRemove - providerForContent
                                    saved = false
                                },
                                placeholder = {
                                    Text(
                                        if (providerHasSavedKey) "Key saved — type to replace" else "Paste your API key here...",
                                        fontSize = 14.sp
                                    )
                                },
                                leadingIcon = {
                                    Icon(Icons.Default.Key, null, tint = placeholderColor, modifier = Modifier.size(18.dp))
                                },
                                trailingIcon = {
                                    IconButton(onClick = { showKey = !showKey }) {
                                        Icon(
                                            if (showKey) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                            contentDescription = if (showKey) "Hide" else "Show",
                                            tint = placeholderColor,
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
                                    keysToRemove = keysToRemove + providerForContent
                                    saved = false
                                }) {
                                    Text("Remove saved key", fontSize = 12.sp)
                                }
                            } else if (providerForContent in keysToRemove) {
                                Text("Saved key will be removed when applied", fontSize = 12.sp, color = colorScheme.error)
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
                                                    Text(model.id, color = subtleColor, fontSize = 12.sp)
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

                Spacer(Modifier.height(DesignTokens.Spacing.lg))
                Button(
                    onClick = {
                        applyingAISettings = true
                        applyAIError = null
                        saved = false
                        val keyUpdates = buildMap {
                            if (geminiKey.isNotBlank()) put(AIProvider.GEMINI, geminiKey.trim())
                            if (openaiKey.isNotBlank()) put(AIProvider.OPENAI, openaiKey.trim())
                            if (claudeKey.isNotBlank()) put(AIProvider.CLAUDE, claudeKey.trim())
                            keysToRemove.forEach { put(it, "") }
                        }
                        val submittedProvider = selectedProvider
                        val submittedModel = if (submittedProvider == AIProvider.LOCAL) {
                            AIModel.LOCAL_MODEL
                        } else {
                            selectedModel.takeIf { it.provider == submittedProvider }
                                ?: AIModel.modelsForProvider(submittedProvider).first()
                        }
                        val submittedGeminiKey = geminiKey
                        val submittedOpenAIKey = openaiKey
                        val submittedClaudeKey = claudeKey
                        val submittedRemovals = keysToRemove
                        coroutineScope.launch {
                            onApplyAISettings(submittedProvider, submittedModel, keyUpdates)
                                .onSuccess {
                                    val inputUnchanged = selectedProvider == submittedProvider &&
                                        selectedModel == submittedModel &&
                                        geminiKey == submittedGeminiKey &&
                                        openaiKey == submittedOpenAIKey &&
                                        claudeKey == submittedClaudeKey &&
                                        keysToRemove == submittedRemovals
                                    if (inputUnchanged) {
                                        geminiKey = ""
                                        openaiKey = ""
                                        claudeKey = ""
                                        keysToRemove = emptySet()
                                        saved = true
                                    }
                                }.onFailure {
                                    applyAIError = "AI settings could not be applied. Your changes are still here."
                                }
                            applyingAISettings = false
                        }
                    },
                    enabled = !applyingAISettings,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(DesignTokens.Rhythm.primary)
                        .testTag("applyAISettings"),
                    shape = RoundedCornerShape(DesignTokens.Radius.lg)
                ) {
                    if (applyingAISettings) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(DesignTokens.Indicator.spinnerSm),
                            color = colorScheme.onPrimary,
                            strokeWidth = 2.dp
                        )
                        Spacer(Modifier.width(DesignTokens.Spacing.sm))
                    }
                    Text(if (saved) "AI settings applied" else "Apply AI settings", fontWeight = FontWeight.Medium)
                }
                applyAIError?.let { error ->
                    Spacer(Modifier.height(DesignTokens.Spacing.sm))
                    Text(error, color = colorScheme.error, fontSize = 12.sp)
                }
                }
                }

                // ---------------------------------------------------------------
                // Backup section
                // ---------------------------------------------------------------
                Spacer(Modifier.height(DesignTokens.Spacing.xxl))
                androidx.compose.material3.HorizontalDivider(
                    color = colorScheme.outlineVariant.copy(alpha = 0.4f),
                    thickness = 0.5.dp
                )
                Spacer(Modifier.height(DesignTokens.Spacing.lg))

                var backupNow by remember { androidx.compose.runtime.mutableLongStateOf(System.currentTimeMillis()) }
                LaunchedEffect(Unit) {
                    // Keeps "Last backed up 2 min ago" current while Settings is open.
                    while (true) {
                        kotlinx.coroutines.delay(30_000)
                        backupNow = System.currentTimeMillis()
                    }
                }
                val backupLine = backupStatusLine(backup.status, backupNow)

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { syncSectionExpanded = !syncSectionExpanded }
                        .heightIn(min = 44.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Backup",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            color = colorScheme.onSurfaceVariant,
                            modifier = Modifier.semantics { heading() }
                        )
                        // Expanded, the status line leads the rows instead.
                        if (!syncSectionExpanded) {
                            Text(backupLine, fontSize = 12.sp, color = subtleColor, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    val chevronRotation by animateFloatAsState(
                        targetValue = if (syncSectionExpanded) 180f else 0f,
                        animationSpec = if (animationsEnabled) {
                            tween(DesignTokens.Motion.feedbackMillis, easing = DesignTokens.Motion.standardEasing)
                        } else {
                            androidx.compose.animation.core.snap()
                        },
                        label = "syncChevron"
                    )
                    Icon(
                        Icons.Default.KeyboardArrowDown,
                        contentDescription = if (syncSectionExpanded) "Collapse Backup" else "Expand Backup",
                        tint = colorScheme.onSurfaceVariant,
                        modifier = Modifier.graphicsLayer { rotationZ = chevronRotation }
                    )
                }

                AnimatedVisibility(
                    visible = syncSectionExpanded,
                    enter = expandVertically(animationSpec = DesignTokens.Motion.standardSpring(IntSize.VisibilityThreshold), expandFrom = Alignment.Top),
                    exit = shrinkVertically(animationSpec = tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing), shrinkTowards = Alignment.Top)
                ) {
                    BackupSection(
                        state = backup,
                        actions = backupActions,
                        statusLine = backupLine,
                        subtleColor = subtleColor,
                        textFieldColors = textFieldColors
                    )
                }

                Spacer(Modifier.height(DesignTokens.Spacing.xl))
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { aboutExpanded = !aboutExpanded }
                        .heightIn(min = DesignTokens.Touch.minTarget),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        "About",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        color = colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f)
                    )
                    Icon(
                        Icons.Default.KeyboardArrowDown,
                        contentDescription = if (aboutExpanded) "Collapse About" else "Expand About",
                        tint = colorScheme.onSurfaceVariant,
                        modifier = Modifier.rotate(if (aboutExpanded) 180f else 0f)
                    )
                }
                AnimatedVisibility(
                    visible = aboutExpanded,
                    enter = if (animationsEnabled) expandVertically(tween(DesignTokens.Motion.feedbackMillis, easing = DesignTokens.Motion.standardEasing), expandFrom = Alignment.Top) else androidx.compose.animation.EnterTransition.None,
                    exit = if (animationsEnabled) shrinkVertically(tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing), shrinkTowards = Alignment.Top) else androidx.compose.animation.ExitTransition.None
                ) {
                    Text(
                        "Writers Block ${com.rhymeai.app.BuildConfig.VERSION_NAME} (${com.rhymeai.app.BuildConfig.VERSION_CODE}) · Product of Tyler Manring",
                        fontSize = 12.sp,
                        color = subtleColor,
                        modifier = Modifier.padding(top = DesignTokens.Spacing.sm)
                    )
                }

                } // end else (General tab)

                } // end scrollable content

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
        Text(
            "Lyrics",
            fontSize = DesignTokens.Typography.caption,
            fontWeight = FontWeight.SemiBold,
            color = colorScheme.onSurface,
            modifier = Modifier.semantics { heading() }
        )
        EditorToggleRow(
            label = "Syllable Guide",
            help = FeatureHelp.UNDERLINE_SYLLABLES,
            checked = isSyllableColoringEnabled,
            onCheckedChange = onSyllableColoringChange,
            onHelp = onHelp,
            switchColors = switchColors,
            colorScheme = colorScheme
        )
        EditorToggleRow(
            label = "Rhyme Families",
            help = FeatureHelp.RHYME_FAMILIES,
            checked = isRhymeHighlightEnabled,
            onCheckedChange = onRhymeHighlightChange,
            onHelp = onHelp,
            switchColors = switchColors,
            colorScheme = colorScheme
        )

        Spacer(Modifier.height(DesignTokens.Spacing.sm))
        Text(
            "Assistant",
            fontSize = DesignTokens.Typography.caption,
            fontWeight = FontWeight.SemiBold,
            color = colorScheme.onSurface,
            modifier = Modifier.semantics { heading() }
        )
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
            colorScheme = colorScheme
        )
        EditorToggleRow(
            label = "Highlight Suggestion Rhymes",
            help = FeatureHelp.HIGHLIGHT_RHYMES,
            checked = isHighlightEnabled,
            onCheckedChange = onHighlightChange,
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
            colorScheme = colorScheme
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
    colorScheme: androidx.compose.material3.ColorScheme
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = DesignTokens.Touch.minTarget)
            .toggleable(
                value = checked,
                role = Role.Switch,
                onValueChange = onCheckedChange
            )
            .semantics(mergeDescendants = true) { },
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        FeatureHelpLabel(
            text = label,
            help = help,
            onHelp = onHelp,
            color = colorScheme.onSurfaceVariant
        )
        Switch(
            checked = checked,
            onCheckedChange = null,
            modifier = Modifier.clearAndSetSemantics { },
            colors = switchColors
        )
    }
}

/** How long a finished delete's "back for your songs" line stays, the toast lifetime. */
private const val MODEL_FREED_LINE_MILLIS = 4_000L

/** A confirmed Delete waiting on the dialog: what it frees and whether the model is in use. */
private data class ModelDeleteRequest(
    val title: String,
    val bytes: Long,
    val custom: Boolean,
    val inUse: Boolean,
    val confirm: () -> Unit
)

/** The delete confirmation's message, its size in medium weight; the in-use sentence only for the selected model. */
internal fun modelDeleteMessage(bytes: Long, custom: Boolean, inUse: Boolean) = buildAnnotatedString {
    append("Frees ")
    withStyle(SpanStyle(fontWeight = FontWeight.Medium)) { append(formatFileSize(bytes)) }
    append(" on this device. You can ${if (custom) "import" else "download"} it again later.")
    if (inUse) append(" It's in use now; on-device suggestions stop until you choose another model.")
}
