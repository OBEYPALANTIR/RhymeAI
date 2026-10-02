package com.rhymeai.app.ui.components

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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.data.model.AnalysisPresentation
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
    currentAnalysisPresentation: AnalysisPresentation,
    onAnalysisPresentationChange: (AnalysisPresentation) -> Unit,
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

    // Sync passphrase field — write-only like API key fields; empty = do not change stored value.
    // Progressive disclosure: Drive sync collapses to a single header row
    // until the user opens it — General stays scannable.
    var syncSectionExpanded by remember { mutableStateOf(false) }
    var syncPassphraseField by remember { mutableStateOf("") }
    var showSyncPassphrase by remember { mutableStateOf(false) }

    // File picker for local models
    var copyingFile by remember { mutableStateOf(false) }
    var copyError by remember { mutableStateOf<String?>(null) }
    val coroutineScope = rememberCoroutineScope()

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
                    AnalysisStyleSelector(
                        current = currentAnalysisPresentation,
                        onChange = onAnalysisPresentationChange,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(Modifier.height(DesignTokens.Rhythm.section))
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
                                "Load a GGUF model to run AI entirely on your device. No data leaves your phone. You can choose your own file or download a recommended Gemma model from Hugging Face.",
                                fontSize = 12.sp,
                                color = subtleColor,
                                lineHeight = 16.sp
                            )

                            Spacer(Modifier.height(12.dp))

                            if (savedLocalModels.isNotEmpty()) {
                                Text(
                                    "Saved Models",
                                    fontSize = DesignTokens.Typography.caption,
                                    fontWeight = FontWeight.Medium,
                                    color = colorScheme.onSurfaceVariant
                                )
                                Spacer(Modifier.height(8.dp))
                                savedLocalModels.forEach { model ->
                                    key(model.id) {
                                        val isSelected = model.id == selectedLocalModelId
                                        val selectionFill by animateColorAsState(
                                            targetValue = if (isSelected) colorScheme.primary.copy(alpha = 0.08f) else Color.Transparent,
                                            animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.feedbackMillis else 0),
                                            label = "savedModelSelectionFill"
                                        )
                                        val selectionBorder by animateColorAsState(
                                            targetValue = if (isSelected) colorScheme.primary else colorScheme.outlineVariant,
                                            animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.feedbackMillis else 0),
                                            label = "savedModelSelectionBorder"
                                        )
                                        OutlinedButton(
                                            onClick = { onSelectSavedLocalModel(model.id) },
                                            enabled = !localModelLoading && !copyingFile && gemmaDownloadingModel == null,
                                            modifier = Modifier.fillMaxWidth(),
                                            shape = RoundedCornerShape(DesignTokens.Radius.lg),
                                            colors = ButtonDefaults.outlinedButtonColors(
                                                containerColor = selectionFill,
                                                disabledContainerColor = selectionFill
                                            ),
                                            border = BorderStroke(1.dp, selectionBorder)
                                        ) {
                                            Icon(
                                                if (isSelected) Icons.Default.CheckCircle else Icons.Default.FileOpen,
                                                null,
                                                modifier = Modifier.size(18.dp)
                                            )
                                            Text(
                                                model.displayName,
                                                modifier = Modifier.weight(1f).padding(start = 8.dp),
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                            Text(if (isSelected) "Selected" else "Select", fontSize = 12.sp)
                                        }
                                        Spacer(Modifier.height(8.dp))
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
                                                    ?.displayName ?: localModelPath.orEmpty().substringAfterLast("/"),
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
                                        modifier = Modifier.fillMaxWidth(),
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
                                // Recommended model downloads
                                Text("Recommended Downloads", fontSize = DesignTokens.Typography.caption, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                                Spacer(Modifier.height(8.dp))

                                GEMMA_DOWNLOADS.forEach { model ->
                                    val installedFile = File(context.filesDir, model.fileName)
                                    val installedError = remember(gemmaDownloadRevision, model.fileName) {
                                        validateDownloadedGemma(model, installedFile)
                                    }
                                    val isInstalled = installedError == null &&
                                        model.fileName in verifiedGemmaFileNames
                                    val installedLabel = if (isInstalled) {
                                        "Downloaded - ${formatFileSize(installedFile.length())}"
                                    } else {
                                        model.description
                                    }
                                    val isDownloadingThis = gemmaDownloadingModel?.fileName == model.fileName
                                    val downloadFill by animateColorAsState(
                                        targetValue = if (isDownloadingThis) colorScheme.primary.copy(alpha = 0.08f) else Color.Transparent,
                                        animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.feedbackMillis else 0),
                                        label = "modelDownloadFill"
                                    )
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
                                        shape = RoundedCornerShape(DesignTokens.Radius.lg),
                                        colors = ButtonDefaults.outlinedButtonColors(
                                            containerColor = downloadFill,
                                            disabledContainerColor = downloadFill
                                        )
                                    ) {
                                        // The model name and icon slot stay put as progress changes.
                                        Box(Modifier.size(18.dp), contentAlignment = Alignment.Center) {
                                            if (isDownloadingThis) {
                                                CircularProgressIndicator(
                                                    modifier = Modifier.size(16.dp),
                                                    color = colorScheme.primary,
                                                    strokeWidth = 2.dp
                                                )
                                            } else {
                                                Icon(
                                                    if (isInstalled) Icons.Default.CheckCircle else Icons.Default.Download,
                                                    null,
                                                    modifier = Modifier.size(18.dp)
                                                )
                                            }
                                        }
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
                                                        "Recommended",
                                                        fontSize = 12.sp,
                                                        fontWeight = FontWeight.Medium,
                                                        color = colorScheme.onSurfaceVariant,
                                                        modifier = Modifier
                                                            .background(
                                                                colorScheme.surfaceVariant,
                                                                RoundedCornerShape(4.dp)
                                                            )
                                                            .padding(horizontal = DesignTokens.Spacing.xs, vertical = 2.dp)
                                                    )
                                                }
                                            }
                                            Text(
                                                when {
                                                    isDownloadingThis && gemmaDownloadVerifying -> "Verifying download..."
                                                    isDownloadingThis -> formatDownloadProgress(gemmaDownloadProgress)
                                                    else -> installedLabel
                                                },
                                                fontSize = 12.sp,
                                                color = colorScheme.onSurfaceVariant
                                            )
                                            if (exceedsRam) {
                                                Text(
                                                    "May be slow on this device — needs more memory",
                                                    fontSize = 12.sp,
                                                    color = colorScheme.error
                                                )
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
                // Drive Sync section
                // ---------------------------------------------------------------
                Spacer(Modifier.height(DesignTokens.Spacing.xxl))
                androidx.compose.material3.HorizontalDivider(
                    color = colorScheme.outlineVariant.copy(alpha = 0.4f),
                    thickness = 0.5.dp
                )
                Spacer(Modifier.height(DesignTokens.Spacing.lg))

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { syncSectionExpanded = !syncSectionExpanded }
                        .heightIn(min = 44.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "Cloud Sync (Google Drive)",
                            fontSize = 14.sp,
                            fontWeight = FontWeight.Medium,
                            color = colorScheme.onSurfaceVariant
                        )
                        Text(
                            when {
                                syncInProgress -> syncProgressLabel
                                syncPassphraseStored -> "On — encrypted with your passphrase"
                                else -> "Not set up"
                            },
                            fontSize = 12.sp,
                            color = subtleColor
                        )
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
                        contentDescription = if (syncSectionExpanded) "Collapse cloud sync" else "Expand cloud sync",
                        tint = colorScheme.onSurfaceVariant,
                        modifier = Modifier.rotate(chevronRotation)
                    )
                }

                AnimatedVisibility(
                    visible = syncSectionExpanded,
                    enter = expandVertically(animationSpec = DesignTokens.Motion.standardSpring(), expandFrom = Alignment.Top),
                    exit = shrinkVertically(animationSpec = tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing), shrinkTowards = Alignment.Top)
                ) {
                Column {
                Spacer(Modifier.height(DesignTokens.Spacing.sm))
                Text(
                    "Backs up projects, trash, and recordings to Google Drive. A later sync may restore previously synced recordings of a deleted song to this device. API keys stay on this device. Backup is encrypted with your passphrase.",
                    fontSize = 12.sp,
                    color = subtleColor,
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
                        Icon(Icons.Default.Key, null, tint = placeholderColor, modifier = Modifier.size(18.dp))
                    },
                    trailingIcon = {
                        IconButton(onClick = { showSyncPassphrase = !showSyncPassphrase }) {
                            Icon(
                                if (showSyncPassphrase) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                contentDescription = if (showSyncPassphrase) "Hide" else "Show",
                                tint = placeholderColor,
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
                    "Your songs and recordings are included in Android's automatic backup. Only the optional Google Drive backup is encrypted with your passphrase. API keys are stored encrypted on this device and sent directly to the selected provider to authenticate requests.",
                    fontSize = 12.sp,
                    color = subtleColor,
                    lineHeight = 16.sp
                )

                syncLastResult?.let { result ->
                    Spacer(Modifier.height(6.dp))
                    Text(
                        result,
                        fontSize = 12.sp,
                        color = if (result.startsWith("Sync complete") || result.startsWith("Restore complete")) colorScheme.tertiary
                        else subtleColor,
                        lineHeight = 15.sp
                    )
                }
                } // end sync collapsible column
                } // end sync AnimatedVisibility

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
