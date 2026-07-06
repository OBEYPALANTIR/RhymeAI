package com.rhymeai.app.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDp
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.updateTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.requiredWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.BiasAlignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import com.rhymeai.app.R
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.SaveStatus
import com.rhymeai.app.data.model.ExportFormat
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.ui.components.AssistantPanel
import com.rhymeai.app.ui.components.ExportSheet
import com.rhymeai.app.ui.components.KeyboardSafeActionArea
import com.rhymeai.app.ui.components.RewriteChipBar
import com.rhymeai.app.ui.components.RhymeHighlightedText
import com.rhymeai.app.ui.components.SyllableWordColoredText
import com.rhymeai.app.ui.components.WordInspectorSheet
import com.rhymeai.app.ui.components.buildSyllableUnderlineSpans
import com.rhymeai.app.ui.components.bottomSafeActionPadding
import com.rhymeai.app.ui.components.keyboardAwareBottomPadding
import com.rhymeai.app.ui.components.syllableUnderlines
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.util.LyricsExporter
import com.rhymeai.app.util.SyllableCounter
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class LyricStats(
    val wordCount: Int,
    val syllableCount: Int
)

@Composable
private fun rememberExportDocumentLauncher(
    format: ExportFormat,
    onExportUriSelected: (android.net.Uri?) -> Unit
) = rememberLauncherForActivityResult(
    contract = ActivityResultContracts.CreateDocument(format.mimeType),
    onResult = onExportUriSelected
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditorScreen(viewModel: MainViewModel, onNavigateToStart: () -> Unit = {}) {
    var showBottomSheet by remember { mutableStateOf(false) }
    var lyricsFocused by remember { mutableStateOf(false) }
    var lyricsTextLayout by remember { mutableStateOf<TextLayoutResult?>(null) }
    var titleHeightPx by remember { mutableIntStateOf(0) }
    var analyzedLyrics by remember { mutableStateOf(viewModel.lyrics) }
    var lyricStats by remember { mutableStateOf(LyricStats(0, 0)) }

    val colorScheme = MaterialTheme.colorScheme
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val focusManager = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    var micBusy by remember { mutableStateOf(false) }
    val snackbarHostState = remember { SnackbarHostState() }
    val fullSheetHeightPx = with(density) { configuration.screenHeightDp.dp.toPx() }
    val assistantSheetHandleHeightPx = with(density) { DesignTokens.Sheet.handleArea.toPx() }
    val assistantSheetCloseThresholdPx =
        ((fullSheetHeightPx - assistantSheetHandleHeightPx).coerceAtLeast(0f)) * 0.5f
    var assistantSheetDragOffsetPx by remember { mutableFloatStateOf(0f) }
    val keyboardVisible = WindowInsets.ime.getBottom(density) > 0
    var pendingAssistantSheet by remember { mutableStateOf(false) }
    var rewriteChipBarHeightPx by remember { mutableIntStateOf(0) }
    var rewriteReviewBarHeightPx by remember { mutableIntStateOf(0) }

    LaunchedEffect(viewModel.lyrics) {
        val lyricsSnapshot = viewModel.lyrics
        delay(180)
        val stats = withContext(Dispatchers.Default) {
            LyricStats(
                wordCount = SyllableCounter.wordCount(lyricsSnapshot),
                syllableCount = SyllableCounter.countText(lyricsSnapshot)
            )
        }
        analyzedLyrics = lyricsSnapshot
        lyricStats = stats
    }

    fun beginAssistantSheetPresentation() {
        assistantSheetDragOffsetPx = fullSheetHeightPx
        showBottomSheet = true
    }

    LaunchedEffect(pendingAssistantSheet, keyboardVisible) {
        if (pendingAssistantSheet && !keyboardVisible) {
            beginAssistantSheetPresentation()
            pendingAssistantSheet = false
        }
    }

    LaunchedEffect(showBottomSheet, fullSheetHeightPx) {
        if (!showBottomSheet) return@LaunchedEffect

        val startOffset = assistantSheetDragOffsetPx
            .takeIf { it > 0f }
            ?: fullSheetHeightPx
        val animation = Animatable(startOffset)
        animation.animateTo(
            targetValue = 0f,
            animationSpec = tween(
                durationMillis = DesignTokens.Motion.sheetPresentMillis,
                easing = DesignTokens.Motion.emphasizedEasing
            )
        ) {
            assistantSheetDragOffsetPx = value
        }
    }

    suspend fun animateAssistantSheetClose() {
        val animation = Animatable(assistantSheetDragOffsetPx)
        animation.animateTo(
            targetValue = fullSheetHeightPx,
            animationSpec = tween(
                durationMillis = DesignTokens.Motion.dismissMillis,
                easing = DesignTokens.Motion.exitEasing
            )
        ) {
            assistantSheetDragOffsetPx = value
        }
        showBottomSheet = false
        assistantSheetDragOffsetPx = 0f
    }

    fun settleAssistantSheetDrag() {
        scope.launch {
            val startOffset = assistantSheetDragOffsetPx
            val shouldClose = startOffset >= assistantSheetCloseThresholdPx

            if (!shouldClose) {
                val animation = Animatable(startOffset)
                animation.animateTo(
                    targetValue = 0f,
                    animationSpec = DesignTokens.Motion.settleSpring()
                ) {
                    assistantSheetDragOffsetPx = value
                }
            } else {
                animateAssistantSheetClose()
            }
        }
    }

    fun dismissAssistantSheet() {
        pendingAssistantSheet = false
        if (!showBottomSheet) {
            assistantSheetDragOffsetPx = 0f
            return
        }

        scope.launch {
            animateAssistantSheetClose()
        }
    }

    fun openAssistantSheet() {
        if (keyboardVisible) {
            focusManager.clearFocus(force = true)
            pendingAssistantSheet = true
        } else {
            beginAssistantSheetPresentation()
        }
    }

    BackHandler(enabled = showBottomSheet || pendingAssistantSheet) {
        dismissAssistantSheet()
    }

    val context = LocalContext.current
    var pendingExport by remember { mutableStateOf<Pair<ExportFormat, SongProject>?>(null) }

    fun writeExport(format: ExportFormat, project: SongProject, uri: android.net.Uri) {
        scope.launch {
            try {
                val bytes = withContext(Dispatchers.IO) {
                    when (format) {
                        ExportFormat.TXT -> LyricsExporter.buildTxt(project)
                        ExportFormat.JSON -> LyricsExporter.buildJson(project)
                        ExportFormat.PDF -> LyricsExporter.buildPdf(project)
                        ExportFormat.LRC -> LyricsExporter.buildLrc(project)
                    }
                }
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
                        ?: throw Exception("Cannot open destination for writing")
                }
            } catch (_: Exception) {
                snackbarHostState.showSnackbar("Export failed. Try a different location.")
            }
        }
    }

    fun consumeExportUri(uri: android.net.Uri?) {
        val pending = pendingExport
        pendingExport = null
        if (uri != null && pending != null) {
            writeExport(pending.first, pending.second, uri)
        }
    }

    val txtLauncher = rememberExportDocumentLauncher(ExportFormat.TXT, ::consumeExportUri)
    val jsonLauncher = rememberExportDocumentLauncher(ExportFormat.JSON, ::consumeExportUri)
    val pdfLauncher = rememberExportDocumentLauncher(ExportFormat.PDF, ::consumeExportUri)
    val lrcLauncher = rememberExportDocumentLauncher(ExportFormat.LRC, ::consumeExportUri)

    // Runtime RECORD_AUDIO permission for the mic FAB — grants lead straight to recording start.
    val audioPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            if (!micBusy) {
                micBusy = true
                scope.launch {
                    try {
                        runCatching {
                            val projectId = viewModel.ensureProjectForRecording()
                            viewModel.voiceMemoService.startRecording(projectId)
                        }
                            .onFailure {
                                snackbarHostState.showSnackbar(
                                    context.getString(R.string.voice_memo_record_failed)
                                )
                            }
                    } finally {
                        micBusy = false
                    }
                }
            }
        } else {
            scope.launch { snackbarHostState.showSnackbar(context.getString(R.string.voice_memo_permission_denied)) }
        }
    }

    // Called when the mic FAB is tapped while not recording. Checks permission then
    // starts recording immediately — no sheet involved.
    fun onMicFabTap() {
        val hasPerm = ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (hasPerm) {
            if (micBusy) return
            micBusy = true
            scope.launch {
                try {
                    runCatching {
                        val projectId = viewModel.ensureProjectForRecording()
                        viewModel.voiceMemoService.startRecording(projectId)
                    }
                        .onFailure {
                            snackbarHostState.showSnackbar(
                                context.getString(R.string.voice_memo_record_failed)
                            )
                        }
                } finally {
                    micBusy = false
                }
            }
        } else {
            audioPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    fun launchExport(format: ExportFormat) {
        val project = viewModel.snapshotCurrentForExport()
        val safeTitle = project.title
            .replace(Regex("[^A-Za-z0-9_\\- ]"), "")
            .trim()
            .ifEmpty { "Untitled" }
        val filename = "$safeTitle.${format.extension}"
        pendingExport = format to project
        when (format) {
            ExportFormat.TXT -> txtLauncher.launch(filename)
            ExportFormat.JSON -> jsonLauncher.launch(filename)
            ExportFormat.PDF -> pdfLauncher.launch(filename)
            ExportFormat.LRC -> lrcLauncher.launch(filename)
        }
        viewModel.showExportSheet = false
    }

    val modalOpen = viewModel.showSettingsDialog ||
        viewModel.showProjectsDialog ||
        viewModel.showExportSheet ||
        viewModel.showInspector
    val rewriteReviewVisible = viewModel.hasActiveRewrite &&
        !showBottomSheet &&
        !pendingAssistantSheet &&
        !modalOpen
    val pendingRewriteRange = viewModel.pendingRewriteRange
    val selection = viewModel.lyricsFieldValue.selection
    val singleWordSelection = viewModel.singleWordSelection
    // Any selection raises the rewrite/punch-up chip. A single-word selection
    // additionally exposes a look-up button into the Word Inspector; the chip
    // itself is the same. showInspector is folded into showBottomSheet, so the
    // chip yields while the inspector sheet is open.
    val rewriteVisible = pendingRewriteRange != null &&
        !showBottomSheet &&
        !pendingAssistantSheet &&
        !modalOpen &&
        !viewModel.hasActiveRewrite
    val activeEditorText = if (viewModel.hasActiveRewrite) {
        viewModel.inlineRewriteText
    } else {
        viewModel.lyrics
    }
    val activeEditorRange = if (viewModel.hasActiveRewrite) {
        viewModel.inlineRewriteRange ?: TextRange(viewModel.cursorPosition, viewModel.cursorPosition)
    } else {
        pendingRewriteRange ?: selection
    }

    LaunchedEffect(showBottomSheet, pendingAssistantSheet, modalOpen) {
        if (showBottomSheet || pendingAssistantSheet || modalOpen) {
            viewModel.clearPendingRewriteSelection()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colorScheme.background)
    ) {
        val fabRowVisible = !showBottomSheet && !pendingAssistantSheet && !modalOpen && !viewModel.hasActiveRewrite
        val fabRowBottomOriginOffsetPx = with(density) { DesignTokens.Spacing.xxl.roundToPx() }
        Column(modifier = Modifier.fillMaxSize()) {
            // Top bar — always visible
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = { viewModel.showProjectsDialog = true }) {
                        Icon(
                            Icons.Default.Menu,
                            contentDescription = stringResource(R.string.editor_open_songs_drawer),
                            tint = colorScheme.onSurfaceVariant
                        )
                    }
                },
                title = {
                    val savingLabel = stringResource(R.string.editor_saving)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                    ) {
                        Text(
                            text = viewModel.title.ifBlank { "Untitled Song" },
                            style = MaterialTheme.typography.titleSmall,
                            color = colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier
                                .weight(1f, fill = false)
                                .testTag("editorTopBarTitle")
                        )
                        when (viewModel.saveStatus) {
                            SaveStatus.SAVING -> CircularProgressIndicator(
                                modifier = Modifier
                                    .size(DesignTokens.Indicator.spinnerSm)
                                    .semantics { contentDescription = savingLabel },
                                strokeWidth = DesignTokens.EditorChrome.saveStatusStrokeWidth,
                                color = colorScheme.onSurfaceVariant
                            )
                            SaveStatus.SAVED -> Icon(
                                Icons.Default.Check,
                                contentDescription = stringResource(R.string.editor_saved),
                                tint = colorScheme.tertiary,
                                modifier = Modifier.size(DesignTokens.Indicator.spinnerSm)
                            )
                            else -> {}
                        }
                    }
                },
                actions = {
                    Column(
                        horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.Center,
                        modifier = Modifier.padding(end = DesignTokens.EditorChrome.statsEndPadding)
                    ) {
                        Text(
                            "${lyricStats.wordCount} words",
                            style = MaterialTheme.typography.labelSmall,
                            color = colorScheme.onSurfaceVariant
                        )
                        Text(
                            "${lyricStats.syllableCount} syllables",
                            style = MaterialTheme.typography.labelSmall,
                            color = colorScheme.onSurfaceVariant
                        )
                    }
                    IconButton(
                        onClick = { viewModel.showExportSheet = true },
                        enabled = viewModel.lyrics.isNotBlank()
                    ) {
                        Icon(
                            Icons.Default.IosShare,
                            contentDescription = stringResource(R.string.editor_export),
                            tint = if (viewModel.lyrics.isNotBlank())
                                colorScheme.onSurfaceVariant
                            else
                                colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                        )
                    }
                    IconButton(onClick = { viewModel.showSettingsDialog = true }) {
                        Icon(
                            Icons.Default.Settings,
                            contentDescription = stringResource(R.string.editor_settings),
                            tint = colorScheme.onSurfaceVariant
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colorScheme.surface,
                    navigationIconContentColor = colorScheme.onSurfaceVariant,
                    titleContentColor = colorScheme.onSurface,
                    actionIconContentColor = colorScheme.onSurfaceVariant
                )
            )

            // Divider
            HorizontalDivider(color = colorScheme.outlineVariant)

            // Editor
            val scrollState = rememberScrollState()
            BoxWithConstraints(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
            ) {
                val activeRewriteSurfaceHeightPx = when {
                    rewriteReviewVisible -> rewriteReviewBarHeightPx
                    rewriteVisible -> rewriteChipBarHeightPx
                    else -> 0
                }
                val activeRewriteSurfaceHeight = with(density) {
                    activeRewriteSurfaceHeightPx.toDp()
                }
                val bottomActionPadding = keyboardAwareBottomPadding(
                    extra = DesignTokens.Spacing.lg
                )
                // Reserve the full FAB footprint so the caret never scrolls behind it.
                val fabFootprint = if (fabRowVisible) {
                    keyboardAwareBottomPadding(extra = DesignTokens.Spacing.xxl) + DesignTokens.EditorChrome.fabSize + DesignTokens.Spacing.md
                } else {
                    0.dp
                }
                // Use whichever bottom surface is taller: rewrite bar stack or FAB.
                val bottomObstruction = maxOf(
                    bottomActionPadding + activeRewriteSurfaceHeight + DesignTokens.Spacing.md,
                    fabFootprint
                )
                val keyboardScrollSpace = maxOf(
                    keyboardAwareBottomPadding(extra = DesignTokens.Spacing.golden) + DesignTokens.Touch.minTarget,
                    bottomObstruction + DesignTokens.Spacing.golden
                )
                val trailingScrollSpace = if (keyboardVisible || rewriteVisible || rewriteReviewVisible) {
                    keyboardScrollSpace
                } else {
                    DesignTokens.Editor.bottomRest
                }
                val viewportHeightPx = with(density) { maxHeight.roundToPx() }
                val editorWidthPx = with(density) {
                    (maxWidth - DesignTokens.Editor.horizontalPadding - DesignTokens.Editor.horizontalPadding).roundToPx()
                }
                val estimatedCharsPerLine = (editorWidthPx / with(density) { DesignTokens.Editor.estimatedCharacterWidth.roundToPx() })
                    .coerceAtLeast(1)
                val activeRangeStart = activeEditorRange.min.coerceIn(0, activeEditorText.length)
                val activeRangeEnd = activeEditorRange.max.coerceIn(0, activeEditorText.length)
                val cursorVisualLine = remember(
                    activeEditorText,
                    activeRangeStart,
                    estimatedCharsPerLine
                ) {
                    estimateCursorVisualLine(
                        text = activeEditorText,
                        cursor = activeRangeStart,
                        charsPerLine = estimatedCharsPerLine
                    )
                }
                val lyricsTopPx = with(density) {
                    (DesignTokens.Spacing.lg + DesignTokens.Spacing.xl).roundToPx()
                } + titleHeightPx
                val lineHeightPx = with(density) { DesignTokens.Editor.lyricMeasureLineHeight.roundToPx() }
                val activeRangeInLyricsPx = selectedTextVerticalRange(
                    textLayoutResult = lyricsTextLayout,
                    text = activeEditorText,
                    range = TextRange(activeRangeStart, activeRangeEnd),
                    fallbackTopPx = cursorVisualLine * lineHeightPx,
                    lineHeightPx = lineHeightPx
                )
                val activeRangeContentTopY = lyricsTopPx + activeRangeInLyricsPx.top
                val activeRangeContentBottomY = lyricsTopPx + activeRangeInLyricsPx.bottom
                val minSafeTopPx = with(density) {
                    (DesignTokens.Sheet.handleArea + DesignTokens.Spacing.md).roundToPx()
                }
                val bottomObstructionPx = with(density) { bottomObstruction.roundToPx() }
                val maxSafeBottomPx = (viewportHeightPx - bottomObstructionPx)
                    .coerceAtLeast(minSafeTopPx + lineHeightPx)
                val rangeSelectionActive = activeRangeStart != activeRangeEnd || viewModel.hasActiveRewrite
                val selectedRangeSafeBottomPx = if (rangeSelectionActive) {
                    val safeHeightPx = (maxSafeBottomPx - minSafeTopPx).coerceAtLeast(lineHeightPx)
                    val goldenBandBottomPx = minSafeTopPx + (safeHeightPx * DesignTokens.Phi.inverse).roundToInt()
                    minOf(maxSafeBottomPx, goldenBandBottomPx)
                } else {
                    maxSafeBottomPx
                }
                val collapseKeyboardOnScrollConnection = remember(
                    keyboardVisible,
                    lyricsFocused,
                    focusManager
                ) {
                    object : NestedScrollConnection {
                        override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                            if (source == NestedScrollSource.UserInput && keyboardVisible && lyricsFocused) {
                                focusManager.clearFocus(force = true)
                            }
                            return Offset.Zero
                        }
                    }
                }

                LaunchedEffect(
                    keyboardVisible,
                    lyricsFocused,
                    viewModel.hasActiveRewrite,
                    activeRangeStart,
                    activeRangeEnd,
                    activeRangeContentTopY,
                    activeRangeContentBottomY,
                    activeRewriteSurfaceHeightPx,
                    bottomObstructionPx,
                    scrollState.maxValue,
                    viewportHeightPx,
                    selectedRangeSafeBottomPx,
                    lineHeightPx
                ) {
                    if (!lyricsFocused) return@LaunchedEffect
                    if (!keyboardVisible && activeRangeStart == activeRangeEnd && !viewModel.hasActiveRewrite) {
                        return@LaunchedEffect
                    }

                    val rangeTopOnScreen = activeRangeContentTopY - scrollState.value
                    val rangeBottomOnScreen = activeRangeContentBottomY - scrollState.value
                    val targetScroll = when {
                        rangeBottomOnScreen > selectedRangeSafeBottomPx -> activeRangeContentBottomY - selectedRangeSafeBottomPx
                        rangeTopOnScreen < minSafeTopPx -> activeRangeContentTopY - minSafeTopPx
                        else -> null
                    }?.coerceIn(0, scrollState.maxValue)

                    if (targetScroll != null && abs(targetScroll - scrollState.value) > lineHeightPx / 2) {
                        scrollState.scrollTo(targetScroll)
                    }
                }

                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .testTag("editorScrollContainer")
                        .nestedScroll(collapseKeyboardOnScrollConnection)
                        .verticalScroll(scrollState)
                        .padding(horizontal = DesignTokens.Editor.horizontalPadding)
                ) {
                    Spacer(Modifier.height(DesignTokens.Spacing.lg))

                    // Title field
                    BasicTextField(
                        value = viewModel.title,
                        onValueChange = { viewModel.onTitleChanged(it) },
                        textStyle = MaterialTheme.typography.headlineLarge.copy(
                            color = colorScheme.onBackground
                        ),
                        cursorBrush = SolidColor(colorScheme.primary),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("songTitleEditor")
                            .onSizeChanged { titleHeightPx = it.height },
                        decorationBox = { innerTextField ->
                            Box {
                                if (viewModel.title.isEmpty()) {
                                    Text(
                                        "Song Title...",
                                        style = MaterialTheme.typography.headlineLarge,
                                        color = colorScheme.onBackground.copy(alpha = 0.2f)
                                    )
                                }
                                innerTextField()
                            }
                        }
                    )

                    Spacer(Modifier.height(DesignTokens.Spacing.xl))

                    // Expensive lyric analysis waits until typing pauses so editor redraws stay stable.
                    val lyricAnalysisReady = analyzedLyrics == viewModel.lyrics
                    // Rhyme colors need a text overlay; keep it off mid-edit so the real field remains visible.
                    val rhymeOverlayActive = viewModel.isRhymeHighlightEnabled &&
                        viewModel.lyrics.isNotEmpty() &&
                        !viewModel.hasActiveRewrite &&
                        lyricAnalysisReady
                    val syllableWordColorActive = viewModel.isSyllableColoringEnabled &&
                        !viewModel.isRhymeHighlightEnabled &&
                        viewModel.lyrics.isNotEmpty() &&
                        !viewModel.hasActiveRewrite &&
                        lyricAnalysisReady
                    // Underlines only when rhyme coloring owns the foreground; otherwise syllables tint the word itself.
                    val syllableUnderlineActive = viewModel.isSyllableColoringEnabled &&
                        viewModel.isRhymeHighlightEnabled &&
                        viewModel.lyrics.isNotEmpty() &&
                        !viewModel.hasActiveRewrite &&
                        lyricAnalysisReady
                    val wordColorOverlayActive = rhymeOverlayActive || syllableWordColorActive
                    // Center glyphs in the 28sp line box and drop legacy font padding so the
                    // cursor, placeholder, and color overlays all share one vertical metric.
                    val lyricsTextStyle = TextStyle(
                        fontSize = DesignTokens.Editor.lyricFontSize,
                        lineHeight = DesignTokens.Editor.lyricLineHeight,
                        fontFamily = FontFamily.Default,
                        lineHeightStyle = LineHeightStyle(
                            alignment = LineHeightStyle.Alignment.Center,
                            trim = LineHeightStyle.Trim.None
                        ),
                        platformStyle = PlatformTextStyle(includeFontPadding = false)
                    )
                    val syllableUnderlineGap = with(density) { DesignTokens.Editor.syllableUnderlineGap.toPx() }
                    val syllableUnderlineWidth = with(density) { DesignTokens.Editor.syllableUnderlineWidth.toPx() }
                    val syllableIsDark = isSystemInDarkTheme()
                    val syllableUnderlineSpans = remember(analyzedLyrics, syllableUnderlineActive, syllableIsDark) {
                        buildSyllableUnderlineSpans(
                            text = analyzedLyrics,
                            enabled = syllableUnderlineActive,
                            isDark = syllableIsDark
                        )
                    }
                    val inlineRewriteRange = viewModel.inlineRewriteRange
                    val rewriteHighlightRange = if (viewModel.hasActiveRewrite) {
                        inlineRewriteRange
                    } else {
                        pendingRewriteRange
                    }
                    val inlineRewriteText = viewModel.inlineRewriteText
                    val inlineRewriteValue = remember(
                        viewModel.hasActiveRewrite,
                        inlineRewriteText,
                        inlineRewriteRange
                    ) {
                        TextFieldValue(
                            text = inlineRewriteText,
                            selection = inlineRewriteRange ?: TextRange(
                                viewModel.cursorPosition.coerceIn(0, inlineRewriteText.length)
                            )
                        )
                    }
                    val animationsEnabled = LocalAnimationsEnabled.current
                    val rewriteShimmerActive = viewModel.hasActiveRewrite &&
                        viewModel.rewriteLoading &&
                        animationsEnabled
                    val rewriteShimmerProgress: () -> Float = if (rewriteShimmerActive) {
                        val shimmerState = rememberInfiniteTransition(
                            label = "rewriteShimmer"
                        ).animateFloat(
                            initialValue = 0f,
                            targetValue = 1f,
                            animationSpec = infiniteRepeatable(
                                animation = tween(
                                    durationMillis = DesignTokens.Motion.rewriteShimmerMillis,
                                    easing = LinearEasing
                                ),
                                repeatMode = RepeatMode.Restart
                            ),
                            label = "rewriteShimmerProgress"
                        )
                        val readShimmerProgress: () -> Float = { shimmerState.value }
                        readShimmerProgress
                    } else {
                        { 0f }
                    }
                    val colorOverlayAlpha by animateFloatAsState(
                        targetValue = if (wordColorOverlayActive) 1f else 0f,
                        animationSpec = if (animationsEnabled) {
                            tween(DesignTokens.Motion.standardMillis)
                        } else {
                            snap()
                        },
                        label = "lyricColorOverlayAlpha"
                    )
                    Box(modifier = Modifier.fillMaxWidth()) {
                        // Colored overlay behind the transparent field: rhyme families, or syllable-count word color when rhyme is off.
                        if (colorOverlayAlpha > 0f) {
                            if (viewModel.isRhymeHighlightEnabled) {
                                RhymeHighlightedText(
                                    text = analyzedLyrics,
                                    enabled = true,
                                    modifier = Modifier.graphicsLayer { alpha = colorOverlayAlpha },
                                    style = lyricsTextStyle
                                )
                            } else {
                                SyllableWordColoredText(
                                    text = analyzedLyrics,
                                    modifier = Modifier.graphicsLayer { alpha = colorOverlayAlpha },
                                    style = lyricsTextStyle
                                )
                            }
                        }

                        // Actual text field. Keep it visible for syllable underlines so editing does not redraw through
                        // a second text layer on every delete/backspace.
                        BasicTextField(
                            value = if (viewModel.hasActiveRewrite) inlineRewriteValue else viewModel.lyricsFieldValue,
                            onValueChange = {
                                if (!viewModel.hasActiveRewrite) {
                                    viewModel.onLyricsChanged(it)
                                }
                            },
                            onTextLayout = { lyricsTextLayout = it },
                            readOnly = viewModel.hasActiveRewrite,
                            textStyle = lyricsTextStyle.copy(
                                color = colorScheme.onBackground.copy(alpha = 1f - colorOverlayAlpha)
                            ),
                            cursorBrush = SolidColor(colorScheme.primary),
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag("lyricsEditor")
                                .inlineRewriteHighlight(
                                    textLayoutResult = lyricsTextLayout,
                                    range = rewriteHighlightRange,
                                    shimmer = rewriteShimmerActive,
                                    error = viewModel.hasActiveRewrite && viewModel.rewriteError != null,
                                    shimmerProgress = rewriteShimmerProgress,
                                    highlightColor = if (viewModel.hasActiveRewrite && viewModel.rewriteError != null) {
                                        colorScheme.error.copy(alpha = 0.22f)
                                    } else {
                                        colorScheme.primary.copy(alpha = 0.20f)
                                    },
                                    strokeColor = if (viewModel.hasActiveRewrite && viewModel.rewriteError != null) {
                                        colorScheme.error.copy(alpha = 0.70f)
                                    } else {
                                        colorScheme.tertiary.copy(alpha = 0.78f)
                                    },
                                    shimmerColor = colorScheme.primary.copy(alpha = 0.6f)
                                )
                                .syllableUnderlines(
                                    spans = syllableUnderlineSpans,
                                    textLayoutResult = lyricsTextLayout,
                                    underlineGap = syllableUnderlineGap,
                                    strokeWidth = syllableUnderlineWidth
                                )
                                .onFocusChanged { lyricsFocused = it.isFocused },
                            decorationBox = { innerTextField ->
                                Box {
                                    if (viewModel.lyrics.isEmpty()) {
                                        Text(
                                            "Start writing your lyrics here...",
                                            style = lyricsTextStyle,
                                            color = colorScheme.onBackground.copy(alpha = 0.2f)
                                        )
                                    }
                                    innerTextField()
                                }
                            }
                        )
                    }

                    // Extra space lets the last line settle around the same point while typing.
                    Spacer(Modifier.height(trailingScrollSpace))
                }
            }
        }

        // FAB row: mic FAB (left) + UnBlock FAB (right). Shared AnimatedVisibility so
        // both show/hide together under the same conditions as the old UnBlock FAB.
        AnimatedVisibility(
            visible = fabRowVisible,
            enter = fadeIn(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.assistantPresentMillis,
                    easing = DesignTokens.Motion.emphasizedEasing
                )
            ) + slideInVertically(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.assistantPresentMillis,
                    easing = DesignTokens.Motion.emphasizedEasing
                ),
                initialOffsetY = { fullHeight -> fullHeight + fabRowBottomOriginOffsetPx }
            ),
            exit = fadeOut(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.dismissMillis,
                    easing = DesignTokens.Motion.exitEasing
                )
            ) + slideOutVertically(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.dismissMillis,
                    easing = DesignTokens.Motion.exitEasing
                ),
                targetOffsetY = { fullHeight -> fullHeight + fabRowBottomOriginOffsetPx }
            ),
            modifier = Modifier.align(Alignment.BottomEnd)
        ) {
            KeyboardSafeActionArea(
                modifier = Modifier.padding(end = DesignTokens.Spacing.xl),
                extra = DesignTokens.Spacing.xxl,
                horizontalAlignment = Alignment.End
            ) {
                val memoService = viewModel.voiceMemoService
                val barCount = DesignTokens.EditorChrome.recordingBarCount
                // Amplitude + elapsed polling while recording — drives the spectralizer pill.
                var amplitudeBars by remember { mutableStateOf(FloatArray(barCount) { 0f }) }
                var smoothedBars by remember { mutableStateOf(FloatArray(barCount) { 0f }) }

                LaunchedEffect(memoService.isRecording) {
                    if (!memoService.isRecording) {
                        amplitudeBars = FloatArray(barCount) { 0f }
                        smoothedBars = FloatArray(barCount) { 0f }
                        return@LaunchedEffect
                    }
                    while (memoService.isRecording) {
                        delay(100)
                        val raw = memoService.currentAmplitude()
                        // Shift bars left and push new reading on the right side.
                        val next = FloatArray(barCount)
                        for (i in 0 until barCount - 1) next[i] = smoothedBars[i + 1]
                        // Exponential moving average smoothing so bars don't jump abruptly.
                        next[barCount - 1] = smoothedBars[barCount - 1] * 0.7f + raw * 0.3f
                        smoothedBars = next
                        amplitudeBars = next
                    }
                }

                // Single transition drives ALL animated properties — nothing desyncs.
                val micTransition = updateTransition(
                    targetState = memoService.isRecording,
                    label = "micRecording"
                )

                val micRecordingWidth = DesignTokens.EditorChrome.micRecordingWidth
                val unBlockExtendedWidth = DesignTokens.EditorChrome.unBlockExtendedWidth

                // Pill width: compact FAB size → recording pill.
                // The enclosing action area is right-aligned, so the Row grows left.
                val pillWidth by micTransition.animateDp(
                    label = "pillWidth",
                    transitionSpec = { DesignTokens.Motion.expressiveSpring() }
                ) { recording -> if (recording) micRecordingWidth else DesignTokens.EditorChrome.fabSize }

                val unBlockWidth by micTransition.animateDp(
                    label = "unBlockWidth",
                    transitionSpec = { DesignTokens.Motion.expressiveSpring() }
                ) { recording -> if (recording) DesignTokens.EditorChrome.fabSize else unBlockExtendedWidth }

                val unBlockWordmarkAlpha by micTransition.animateFloat(
                    label = "unBlockWordmarkAlpha",
                    transitionSpec = { DesignTokens.Motion.expressiveSpring() }
                ) { recording -> if (recording) 0f else 1f }

                val unBlockWordmarkWidth by micTransition.animateDp(
                    label = "unBlockWordmarkWidth",
                    transitionSpec = { DesignTokens.Motion.expressiveSpring() }
                ) { recording -> if (recording) 0.dp else DesignTokens.EditorChrome.unBlockWordmarkWidth }

                val recProgress by micTransition.animateFloat(
                    label = "recProgress",
                    transitionSpec = { DesignTokens.Motion.expressiveSpring() }
                ) { recording -> if (recording) 1f else 0f }

                val barsAlpha = ((recProgress - DesignTokens.EditorChrome.recordingBarsFadeStart) / DesignTokens.EditorChrome.recordingBarsFadeDistance).coerceIn(0f, 1f)

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                ) {
                    // Animated mic/pill — the right-aligned row makes this expand left.
                    val micPillInteractionSource = remember { MutableInteractionSource() }
                    Box(
                        modifier = Modifier
                            .width(pillWidth)
                            .height(DesignTokens.EditorChrome.fabSize)
                            .background(
                                colorScheme.surfaceContainerHigh,
                                RoundedCornerShape(DesignTokens.Radius.pill)
                            )
                            .border(
                                1.dp,
                                colorScheme.outlineVariant,
                                RoundedCornerShape(DesignTokens.Radius.pill)
                            )
                            .clip(RoundedCornerShape(DesignTokens.Radius.pill))
                            .clickable(
                                interactionSource = micPillInteractionSource,
                                indication = ripple()
                            ) {
                                if (micBusy) return@clickable
                                if (memoService.isRecording) {
                                    micBusy = true
                                    scope.launch {
                                        try {
                                            runCatching { memoService.stopRecording() }
                                        } finally {
                                            micBusy = false
                                        }
                                    }
                                } else {
                                    onMicFabTap()
                                }
                            }
                            .semantics {
                                contentDescription = if (memoService.isRecording)
                                    "Stop recording"
                                else
                                    context.getString(R.string.voice_memo_open_sheet)
                            }
                    ) {
                        // Spectralizer content fades in from the same spring progress.
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(DesignTokens.EditorChrome.recordingContentGap),
                            modifier = Modifier
                                .align(Alignment.CenterStart)
                                .fillMaxWidth()
                                .padding(start = DesignTokens.EditorChrome.recordingContentStartPadding, end = DesignTokens.EditorChrome.fabSize)
                                .alpha(barsAlpha)
                        ) {
                            Canvas(
                                modifier = Modifier
                                    .weight(1f)
                                    .height(DesignTokens.EditorChrome.recordingMeterHeight)
                            ) {
                                val pitch = size.width / amplitudeBars.size
                                val barWidthPx = pitch * 0.6f
                                amplitudeBars.forEachIndexed { i, amplitude ->
                                    val barHeight = (amplitude * size.height).coerceAtLeast(DesignTokens.EditorChrome.recordingMinBarHeight.toPx())
                                    val x = i * pitch + (pitch - barWidthPx) / 2f
                                    drawRoundRect(
                                        color = colorScheme.error,
                                        topLeft = Offset(x, (size.height - barHeight) / 2f),
                                        size = androidx.compose.ui.geometry.Size(barWidthPx, barHeight),
                                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(barWidthPx / 2f)
                                    )
                                }
                            }
                            Text(
                                text = com.rhymeai.app.service.VoiceMemoService.formatDuration(
                                    memoService.recordingElapsedMs
                                ),
                                fontSize = DesignTokens.EditorChrome.recordingElapsedFontSize,
                                fontWeight = FontWeight.Medium,
                                color = colorScheme.onSurface
                            )
                        }

                        Box(
                            modifier = Modifier
                                .align(BiasAlignment(horizontalBias = recProgress, verticalBias = 0f))
                                .padding(horizontal = DesignTokens.EditorChrome.recordingContentStartPadding)
                                .size(DesignTokens.EditorChrome.recordingIconSize),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Default.Mic,
                                contentDescription = null,
                                tint = colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(DesignTokens.EditorChrome.recordingIconSize)
                                    .alpha(1f - recProgress)
                            )
                            Icon(
                                imageVector = Icons.Default.Pause,
                                contentDescription = null,
                                tint = colorScheme.error,
                                modifier = Modifier
                                    .size(DesignTokens.EditorChrome.recordingIconSize)
                                    .alpha(recProgress)
                            )
                        }
                    }

                    // UnBlock collapses toward its fixed right edge, leaving a pencil circle.
                    val unBlockInteractionSource = remember { MutableInteractionSource() }
                    Box(
                        modifier = Modifier
                            .width(unBlockWidth)
                            .height(DesignTokens.EditorChrome.fabSize)
                            .clip(RoundedCornerShape(DesignTokens.Radius.pill))
                            .background(
                                colorScheme.primary,
                                RoundedCornerShape(DesignTokens.Radius.pill)
                            )
                            .clickable(
                                interactionSource = unBlockInteractionSource,
                                indication = ripple()
                            ) {
                                openAssistantSheet()
                            }
                            .semantics {
                                contentDescription = "Open AI suggestions"
                            },
                        contentAlignment = Alignment.Center
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center
                        ) {
                            Icon(
                                imageVector = Icons.Default.Edit,
                                contentDescription = null,
                                tint = colorScheme.onPrimary,
                                modifier = Modifier.size(DesignTokens.EditorChrome.unBlockIconSize)
                            )
                            Box(
                                modifier = Modifier
                                    .width(unBlockWordmarkWidth)
                                    .graphicsLayer { alpha = unBlockWordmarkAlpha }
                                    .clipToBounds()
                            ) {
                                Row(
                                    modifier = Modifier.requiredWidth(DesignTokens.EditorChrome.unBlockWordmarkWidth),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Spacer(Modifier.width(DesignTokens.EditorChrome.unBlockWordmarkGap))
                                    UnBlockWordmark()
                                }
                            }
                        }
                    }
                }
            }
        }

        // Rewrite chip bar — shown when text is selected and no other UI is open
        AnimatedVisibility(
            visible = rewriteVisible,
            enter = fadeIn(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.standardMillis,
                    easing = DesignTokens.Motion.emphasizedEasing
                )
            ) + slideInVertically(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.standardMillis,
                    easing = DesignTokens.Motion.emphasizedEasing
                ),
                initialOffsetY = { it }
            ),
            exit = fadeOut(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.dismissMillis,
                    easing = DesignTokens.Motion.exitEasing
                )
            ) + slideOutVertically(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.dismissMillis,
                    easing = DesignTokens.Motion.exitEasing
                ),
                targetOffsetY = { it }
            ),
            modifier = Modifier
                .align(Alignment.BottomCenter)
        ) {
            KeyboardSafeActionArea(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DesignTokens.Spacing.lg),
                extra = DesignTokens.Spacing.lg
            ) {
                RewriteChipBar(
                    onAction = { viewModel.requestRewrite(it) },
                    onInspect = singleWordSelection?.let { { viewModel.openInspectorForSelection() } },
                    modifier = Modifier.onSizeChanged { rewriteChipBarHeightPx = it.height }
                )
            }
        }

        AnimatedVisibility(
            visible = rewriteReviewVisible,
            enter = fadeIn(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.standardMillis,
                    easing = DesignTokens.Motion.emphasizedEasing
                )
            ) + slideInVertically(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.standardMillis,
                    easing = DesignTokens.Motion.emphasizedEasing
                ),
                initialOffsetY = { it }
            ),
            exit = fadeOut(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.dismissMillis,
                    easing = DesignTokens.Motion.exitEasing
                )
            ) + slideOutVertically(
                animationSpec = tween(
                    durationMillis = DesignTokens.Motion.dismissMillis,
                    easing = DesignTokens.Motion.exitEasing
                ),
                targetOffsetY = { it }
            ),
            modifier = Modifier
                .align(Alignment.BottomCenter)
        ) {
            viewModel.rewriteAction?.let { action ->
                KeyboardSafeActionArea(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DesignTokens.Spacing.lg),
                    extra = DesignTokens.Spacing.lg
                ) {
                    InlineRewriteReviewBar(
                        action = action,
                        loading = viewModel.rewriteLoading,
                        preview = viewModel.rewritePreview,
                        error = viewModel.rewriteError,
                        onApply = { viewModel.applyRewrite() },
                        onCancel = { viewModel.cancelRewriteReview() },
                        onRetry = { viewModel.retryRewrite() },
                        modifier = Modifier.onSizeChanged { rewriteReviewBarHeightPx = it.height }
                    )
                }
            }
        }

        // Export sheet
        if (viewModel.showExportSheet) {
            ExportSheet(
                onPick = { launchExport(it) },
                onDismiss = { viewModel.showExportSheet = false }
            )
        }

        // Word inspector
        if (viewModel.showInspector) {
            val inspectorWord = viewModel.inspectorWord
            if (inspectorWord != null) {
                WordInspectorSheet(
                    word = inspectorWord,
                    prosody = viewModel.inspectorProsody,
                    matches = viewModel.inspectorMatches,
                    synonyms = viewModel.inspectorSynonyms,
                    synonymsLoading = viewModel.inspectorSynonymsLoading,
                    synonymsError = viewModel.inspectorSynonymsError,
                    onReplace = { replacement -> viewModel.applyInspectorReplacement(replacement) },
                    onRetrySynonyms = { viewModel.retryInspectorSynonyms() },
                    onDismiss = { viewModel.dismissInspector() }
                )
            }
        }

        // Bottom sheet for assistant
        if (showBottomSheet) {
            val rhymeContext = remember(viewModel.lyrics, viewModel.cursorPosition, viewModel.activeRhymeScheme) {
                viewModel.computeRhymeContext()
            }
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .offset { IntOffset(x = 0, y = assistantSheetDragOffsetPx.roundToInt()) }
                    .background(colorScheme.surfaceContainerLow)
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .statusBarsPadding()
                        .height(DesignTokens.Sheet.handleArea)
                        .pointerInput(showBottomSheet, fullSheetHeightPx) {
                            detectVerticalDragGestures(
                                onVerticalDrag = { change, dragAmount ->
                                    change.consume()
                                    assistantSheetDragOffsetPx =
                                        (assistantSheetDragOffsetPx + dragAmount)
                                            .coerceIn(0f, fullSheetHeightPx)
                                },
                                onDragEnd = { settleAssistantSheetDrag() },
                                onDragCancel = { settleAssistantSheetDrag() }
                            )
                        },
                    contentAlignment = Alignment.Center
                ) {
                    Box(
                        modifier = Modifier
                            .width(DesignTokens.Sheet.handleWidth)
                            .height(DesignTokens.Sheet.handleHeight)
                            .background(colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Sheet.handleHeight / 2))
                    )
                }

                AssistantPanel(
                    viewModel = viewModel,
                    rhymeContext = rhymeContext,
                    onSuggestionInserted = { dismissAssistantSheet() },
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .bottomSafeActionPadding(extra = DesignTokens.Spacing.lg)
                )
            }
        }

        SnackbarHost(
            hostState = snackbarHostState,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .bottomSafeActionPadding()
        )
    }
}


private data class TextVerticalRangePx(
    val top: Int,
    val bottom: Int
)

private fun selectedTextVerticalRange(
    textLayoutResult: TextLayoutResult?,
    text: String,
    range: TextRange,
    fallbackTopPx: Int,
    lineHeightPx: Int
): TextVerticalRangePx {
    val fallbackBottomPx = fallbackTopPx + lineHeightPx
    val layout = textLayoutResult?.takeIf { it.layoutInput.text.text == text }
        ?: return TextVerticalRangePx(fallbackTopPx, fallbackBottomPx)
    if (text.isEmpty()) return TextVerticalRangePx(fallbackTopPx, fallbackBottomPx)

    val textLength = text.length
    val start = range.min.coerceIn(0, textLength)
    val end = range.max.coerceIn(0, textLength)
    if (start >= end) {
        val cursor = layout.getCursorRect(start)
        val top = cursor.top.roundToInt()
        return TextVerticalRangePx(
            top = top,
            bottom = cursor.bottom.roundToInt().coerceAtLeast(top + lineHeightPx)
        )
    }

    val startLine = layout.getLineForOffset(start)
    val endOffset = (end - 1).coerceIn(start, textLength - 1)
    val endLine = layout.getLineForOffset(endOffset)
    return TextVerticalRangePx(
        top = layout.getLineTop(startLine).roundToInt(),
        bottom = layout.getLineBottom(endLine).roundToInt()
    )
}

private fun Modifier.inlineRewriteHighlight(
    textLayoutResult: TextLayoutResult?,
    range: TextRange?,
    shimmer: Boolean,
    error: Boolean,
    shimmerProgress: () -> Float,
    highlightColor: Color,
    strokeColor: Color,
    shimmerColor: Color
): Modifier {
    if (range == null) return this

    return drawWithContent {
        val layout = textLayoutResult
        val textLength = layout?.layoutInput?.text?.text?.length ?: 0
        val start = range.min.coerceIn(0, textLength)
        val end = range.max.coerceIn(0, textLength)

        if (layout != null && start < end) {
            val path = layout.getPathForRange(start, end)
            // Highlight fill + stroke render behind the text.
            drawPath(path = path, color = highlightColor)
            drawPath(path = path, color = strokeColor, style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.dp.toPx()))

            // The lyric text itself.
            drawContent()

            // Shimmer glint sweeps over the text, like the iOS overlay.
            if (shimmer && !error) {
                val progress = shimmerProgress()
                val startLine = layout.getLineForOffset(start)
                val endLine = layout.getLineForOffset(end)
                clipPath(path) {
                    for (line in startLine..endLine) {
                        val top = layout.getLineTop(line)
                        val bottom = layout.getLineBottom(line)
                        val left = if (line == startLine) {
                            layout.getHorizontalPosition(start, usePrimaryDirection = true)
                        } else {
                            layout.getLineLeft(line)
                        }
                        val right = if (line == endLine) {
                            layout.getHorizontalPosition(end, usePrimaryDirection = true)
                        } else {
                            layout.getLineRight(line)
                        }
                        val lineWidth = right - left
                        if (lineWidth <= 0f) continue
                        val bandWidth = (lineWidth * 0.45f).coerceAtLeast(24.dp.toPx())
                        val travel = lineWidth + bandWidth * 2f
                        val centerX = left - bandWidth + travel * progress
                        val brush = Brush.horizontalGradient(
                            0f to Color.Transparent,
                            0.5f to shimmerColor,
                            1f to Color.Transparent,
                            startX = centerX - bandWidth,
                            endX = centerX + bandWidth
                        )
                        drawRect(
                            brush = brush,
                            topLeft = Offset(left, top),
                            size = Size(lineWidth, bottom - top)
                        )
                    }
                }
            }
        } else {
            drawContent()
        }
    }
}

@Composable
private fun InlineRewriteReviewBar(
    action: RewriteAction,
    loading: Boolean,
    preview: String?,
    error: String?,
    onApply: () -> Unit,
    onCancel: () -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    Row(
        modifier = modifier
            .fillMaxWidth()
            .testTag("inlineRewriteReviewBar")
            .background(colorScheme.surfaceContainerHigh, RoundedCornerShape(DesignTokens.Radius.sheet))
            .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.sheet))
            .padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
    ) {
        if (loading) {
            CircularProgressIndicator(
                modifier = Modifier.size(16.dp),
                color = colorScheme.primary,
                strokeWidth = 2.dp
            )
        } else {
            Icon(
                if (error == null) Icons.Default.AutoAwesome else Icons.Default.ErrorOutline,
                contentDescription = null,
                tint = if (error == null) colorScheme.primary else colorScheme.error,
                modifier = Modifier.size(18.dp)
            )
        }

        Text(
            text = inlineRewriteStatusText(action, loading, preview, error),
            color = if (error == null) colorScheme.onSurface else colorScheme.error,
            fontSize = DesignTokens.Typography.caption,
            fontWeight = FontWeight.Medium,
            maxLines = if (error == null) 1 else 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )

        if (error != null) {
            Button(
                onClick = onRetry,
                colors = ButtonDefaults.buttonColors(
                    containerColor = colorScheme.primary,
                    contentColor = colorScheme.onPrimary
                ),
                shape = RoundedCornerShape(DesignTokens.Radius.pill)
            ) {
                Text("Retry", fontSize = 12.sp)
            }
        } else if (preview != null && !loading) {
            Button(
                onClick = onApply,
                colors = ButtonDefaults.buttonColors(
                    containerColor = colorScheme.primary,
                    contentColor = colorScheme.onPrimary
                ),
                shape = RoundedCornerShape(DesignTokens.Radius.pill)
            ) {
                Text("Apply", fontSize = 12.sp)
            }
            IconButton(
                onClick = onRetry,
                modifier = Modifier.semantics { contentDescription = "Regenerate rewrite" }
            ) {
                Icon(
                    Icons.Default.Refresh,
                    contentDescription = null,
                    tint = colorScheme.primary,
                    modifier = Modifier.size(20.dp)
                )
            }
        }

        Button(
            onClick = onCancel,
            colors = ButtonDefaults.buttonColors(
                containerColor = colorScheme.surfaceContainer,
                contentColor = colorScheme.onSurfaceVariant
            ),
            shape = RoundedCornerShape(DesignTokens.Radius.pill)
        ) {
            Text("Cancel", fontSize = 12.sp)
        }
    }
}

private fun inlineRewriteStatusText(
    action: RewriteAction,
    loading: Boolean,
    preview: String?,
    error: String?
): String {
    if (!error.isNullOrBlank()) {
        return if (error.contains("No API key", ignoreCase = true)) {
            "API key missing"
        } else {
            error
        }
    }
    if (loading) return "${action.label}..."
    if (preview != null) return "Previewing ${action.label}"
    return action.label
}

@Composable
private fun UnBlockWordmark() {
    val color = MaterialTheme.colorScheme.onPrimary

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("UnBlock", fontWeight = FontWeight.Medium, maxLines = 1, softWrap = false)
        Canvas(
            modifier = Modifier
                .width(68.dp)
                .height(DesignTokens.Spacing.xs)
        ) {
            val strokeWidth = 1.6.dp.toPx()
            drawLine(
                color = color.copy(alpha = 0.9f),
                start = Offset(0f, size.height * 0.55f),
                end = Offset(size.width * 0.18f, size.height * 0.25f),
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round
            )
            drawLine(
                color = color.copy(alpha = 0.9f),
                start = Offset(size.width * 0.18f, size.height * 0.25f),
                end = Offset(size.width * 0.42f, size.height * 0.78f),
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round
            )
            drawLine(
                color = color.copy(alpha = 0.9f),
                start = Offset(size.width * 0.42f, size.height * 0.78f),
                end = Offset(size.width * 0.68f, size.height * 0.28f),
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round
            )
            drawLine(
                color = color.copy(alpha = 0.9f),
                start = Offset(size.width * 0.68f, size.height * 0.28f),
                end = Offset(size.width, size.height * 0.58f),
                strokeWidth = strokeWidth,
                cap = StrokeCap.Round
            )
        }
    }
}

private fun estimateCursorVisualLine(text: String, cursor: Int, charsPerLine: Int): Int {
    val beforeCursor = text.take(cursor.coerceIn(0, text.length))
    val lines = beforeCursor.split('\n')

    val completedLines = lines.dropLast(1).sumOf { line ->
        ceil(line.length.coerceAtLeast(1) / charsPerLine.toFloat()).toInt()
    }
    val currentLineOffset = (lines.lastOrNull()?.length ?: 0) / charsPerLine

    return completedLines + currentLineOffset
}
