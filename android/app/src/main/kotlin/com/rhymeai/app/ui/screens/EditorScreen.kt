package com.rhymeai.app.ui.screens

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.SaveStatus
import com.rhymeai.app.data.model.ExportFormat
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.ui.components.AssistantPanel
import com.rhymeai.app.ui.components.ExportSheet
import com.rhymeai.app.ui.components.RewriteChipBar
import com.rhymeai.app.ui.components.RewriteDialog
import com.rhymeai.app.ui.components.RhymeHighlightedText
import com.rhymeai.app.ui.components.syllableUnderlines
import com.rhymeai.app.util.LyricsExporter
import com.rhymeai.app.util.SyllableCounter
import kotlin.math.ceil
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditorScreen(viewModel: MainViewModel, onNavigateToStart: () -> Unit = {}) {
    val rhymeContext = remember(viewModel.lyrics, viewModel.cursorPosition, viewModel.activeRhymeScheme) {
        viewModel.computeRhymeContext()
    }
    var showBottomSheet by remember { mutableStateOf(false) }
    var lyricsFocused by remember { mutableStateOf(false) }
    var lyricsTextLayout by remember { mutableStateOf<TextLayoutResult?>(null) }
    var titleHeightPx by remember { mutableIntStateOf(0) }

    val colorScheme = MaterialTheme.colorScheme
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val focusManager = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    val fullSheetHeightPx = with(density) { configuration.screenHeightDp.dp.toPx() }
    val assistantSheetHandleHeightPx = with(density) { 64.dp.toPx() }
    val assistantSheetCloseThresholdPx =
        ((fullSheetHeightPx - assistantSheetHandleHeightPx).coerceAtLeast(0f)) * 0.5f
    var assistantSheetDragOffsetPx by remember { mutableFloatStateOf(0f) }
    val keyboardVisible = WindowInsets.ime.getBottom(density) > 0
    var pendingAssistantSheet by remember { mutableStateOf(false) }

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
            animationSpec = tween(durationMillis = 260)
        ) {
            assistantSheetDragOffsetPx = value
        }
    }

    fun settleAssistantSheetDrag() {
        scope.launch {
            val startOffset = assistantSheetDragOffsetPx
            val targetOffset = if (startOffset >= assistantSheetCloseThresholdPx) fullSheetHeightPx else 0f
            val animation = Animatable(startOffset)

            if (targetOffset == 0f) {
                animation.animateTo(
                    targetValue = 0f,
                    animationSpec = spring(
                        dampingRatio = Spring.DampingRatioMediumBouncy,
                        stiffness = Spring.StiffnessMediumLow
                    )
                ) {
                    assistantSheetDragOffsetPx = value
                }
            } else {
                animation.animateTo(
                    targetValue = targetOffset,
                    animationSpec = tween(durationMillis = 180)
                ) {
                    assistantSheetDragOffsetPx = value
                }
                showBottomSheet = false
                assistantSheetDragOffsetPx = 0f
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
            val animation = Animatable(assistantSheetDragOffsetPx)
            animation.animateTo(
                targetValue = fullSheetHeightPx,
                animationSpec = tween(durationMillis = 180)
            ) {
                assistantSheetDragOffsetPx = value
            }
            showBottomSheet = false
            assistantSheetDragOffsetPx = 0f
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
                // Surface via existing errorMessage channel
                viewModel.errorMessage = "Export failed. Try a different location."
            }
        }
    }

    val txtLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(ExportFormat.TXT.mimeType)
    ) { uri ->
        val pending = pendingExport
        pendingExport = null
        if (uri != null && pending != null) writeExport(pending.first, pending.second, uri)
    }
    val jsonLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(ExportFormat.JSON.mimeType)
    ) { uri ->
        val pending = pendingExport
        pendingExport = null
        if (uri != null && pending != null) writeExport(pending.first, pending.second, uri)
    }
    val pdfLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(ExportFormat.PDF.mimeType)
    ) { uri ->
        val pending = pendingExport
        pendingExport = null
        if (uri != null && pending != null) writeExport(pending.first, pending.second, uri)
    }
    val lrcLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(ExportFormat.LRC.mimeType)
    ) { uri ->
        val pending = pendingExport
        pendingExport = null
        if (uri != null && pending != null) writeExport(pending.first, pending.second, uri)
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

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colorScheme.background)
            .imePadding()
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Top bar — always visible
            val wordCount = remember(viewModel.lyrics) { SyllableCounter.wordCount(viewModel.lyrics) }
            val syllableCount = remember(viewModel.lyrics) { SyllableCounter.countText(viewModel.lyrics) }
            TopAppBar(
                navigationIcon = {
                    IconButton(onClick = { viewModel.showProjectsDialog = true }) {
                        Icon(
                            Icons.Default.Menu,
                            contentDescription = "Open songs drawer",
                            tint = colorScheme.onSurfaceVariant
                        )
                    }
                },
                title = {
                    Column {
                        Text(
                            viewModel.title.ifBlank { "Writers Block" },
                            style = MaterialTheme.typography.titleMedium,
                            color = colorScheme.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            "$wordCount words • $syllableCount syllables",
                            style = MaterialTheme.typography.labelSmall,
                            color = colorScheme.onSurfaceVariant
                        )
                    }
                },
                actions = {
                    IconButton(
                        onClick = { viewModel.showExportSheet = true },
                        enabled = viewModel.lyrics.isNotBlank()
                    ) {
                        Icon(
                            Icons.Default.IosShare,
                            contentDescription = "Export",
                            tint = if (viewModel.lyrics.isNotBlank())
                                colorScheme.onSurfaceVariant
                            else
                                colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                        )
                    }
                    IconButton(onClick = { viewModel.showSettingsDialog = true }) {
                        Icon(
                            Icons.Default.Settings,
                            contentDescription = "Settings",
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
                val trailingScrollSpace = if (keyboardVisible) {
                    72.dp
                } else {
                    300.dp
                }
                val viewportHeightPx = with(density) { maxHeight.roundToPx() }
                val editorWidthPx = with(density) { (maxWidth - 48.dp).roundToPx() }
                val estimatedCharsPerLine = (editorWidthPx / with(density) { 8.5.dp.roundToPx() })
                    .coerceAtLeast(1)
                val cursorVisualLine = remember(
                    viewModel.lyrics,
                    viewModel.cursorPosition,
                    estimatedCharsPerLine
                ) {
                    estimateCursorVisualLine(
                        text = viewModel.lyrics,
                        cursor = viewModel.cursorPosition,
                        charsPerLine = estimatedCharsPerLine
                    )
                }
                val lyricsTopPx = with(density) { (16.dp + 24.dp).roundToPx() } + titleHeightPx
                val lineHeightPx = with(density) { 28.dp.roundToPx() }
                val cursorOffset = viewModel.cursorPosition.coerceIn(0, viewModel.lyrics.length)
                val cursorTopInLyricsPx = lyricsTextLayout
                    ?.takeIf { it.layoutInput.text.text == viewModel.lyrics }
                    ?.getCursorRect(cursorOffset)
                    ?.top
                    ?.roundToInt()
                    ?: cursorVisualLine * lineHeightPx
                val cursorContentY = lyricsTopPx + cursorTopInLyricsPx
                val minCursorTopPx = with(density) { 64.dp.roundToPx() }
                val maxCursorTopPx = (viewportHeightPx * 0.45f)
                    .roundToInt()
                    .coerceAtLeast(minCursorTopPx + lineHeightPx)

                LaunchedEffect(
                    keyboardVisible,
                    lyricsFocused,
                    cursorContentY,
                    viewportHeightPx,
                    maxCursorTopPx
                ) {
                    if (!keyboardVisible || !lyricsFocused) return@LaunchedEffect

                    val minScroll = (cursorContentY - maxCursorTopPx).coerceAtLeast(0)
                    val maxScroll = (cursorContentY - minCursorTopPx).coerceAtLeast(0)
                    val initialClampedScroll = scrollState.value.coerceIn(minScroll, maxScroll)
                    if (initialClampedScroll != scrollState.value) {
                        scrollState.scrollTo(initialClampedScroll)
                    }

                    snapshotFlow { scrollState.value }.collect { currentScroll ->
                        val clampedScroll = currentScroll.coerceIn(minScroll, maxScroll)
                        if (clampedScroll != currentScroll) {
                            scrollState.scrollTo(clampedScroll)
                        }
                    }
                }

                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(scrollState)
                        .padding(horizontal = 24.dp)
                ) {
                    Spacer(Modifier.height(16.dp))

                    // Title field
                    BasicTextField(
                        value = viewModel.title,
                        onValueChange = { viewModel.onTitleChanged(it) },
                        textStyle = TextStyle(
                            fontFamily = FontFamily.Serif,
                            fontWeight = FontWeight.Bold,
                            fontSize = 32.sp,
                            color = colorScheme.onBackground
                        ),
                        cursorBrush = SolidColor(colorScheme.primary),
                        modifier = Modifier
                            .fillMaxWidth()
                            .onSizeChanged { titleHeightPx = it.height },
                        decorationBox = { innerTextField ->
                            Box {
                                if (viewModel.title.isEmpty()) {
                                    Text(
                                        "Song Title...",
                                        fontFamily = FontFamily.Serif,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 32.sp,
                                        color = colorScheme.onBackground.copy(alpha = 0.2f)
                                    )
                                }
                                innerTextField()
                            }
                        }
                    )

                    Spacer(Modifier.height(24.dp))

                    // Lyrics editor with overlay (syllable or rhyme coloring)
                    val overlayActive = (viewModel.isSyllableColoringEnabled ||
                        viewModel.isRhymeHighlightEnabled) && viewModel.lyrics.isNotEmpty()
                    val lyricsTextStyle = TextStyle(
                        fontSize = 16.sp,
                        lineHeight = 28.sp,
                        fontFamily = FontFamily.Default
                    )
                    val syllableUnderlineGap = with(density) { 2.dp.toPx() }
                    val syllableUnderlineWidth = with(density) { 3.dp.toPx() }
                    Box(modifier = Modifier.fillMaxWidth()) {
                        // Colored overlay (behind)
                        if (overlayActive) {
                            if (viewModel.isRhymeHighlightEnabled) {
                                RhymeHighlightedText(
                                    text = viewModel.lyrics,
                                    enabled = true,
                                    style = lyricsTextStyle
                                )
                            } else {
                                Text(
                                    text = viewModel.lyrics,
                                    style = lyricsTextStyle,
                                    color = colorScheme.onBackground.copy(alpha = 0.9f)
                                )
                            }
                        }

                        // Actual text field (on top, transparent if coloring is on)
                        BasicTextField(
                            value = viewModel.lyricsFieldValue,
                            onValueChange = { viewModel.onLyricsChanged(it) },
                            onTextLayout = { lyricsTextLayout = it },
                            textStyle = lyricsTextStyle.copy(
                                color = if (overlayActive)
                                    Color.Transparent
                                else
                                    colorScheme.onBackground.copy(alpha = 0.9f)
                            ),
                            cursorBrush = SolidColor(colorScheme.primary),
                            modifier = Modifier
                                .fillMaxWidth()
                                .syllableUnderlines(
                                    text = viewModel.lyrics,
                                    enabled = overlayActive && viewModel.isSyllableColoringEnabled,
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
                                            fontSize = 16.sp,
                                            lineHeight = 28.sp,
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

        val modalOpen = viewModel.showSettingsDialog ||
            viewModel.showProjectsDialog ||
            viewModel.showExportSheet ||
            viewModel.rewriteAction != null

        // UnBlock FAB — visible only when the editor is unobstructed.
        AnimatedVisibility(
            visible = !showBottomSheet && !pendingAssistantSheet && !modalOpen,
            enter = fadeIn() + slideInVertically(initialOffsetY = { it }),
            exit = fadeOut() + slideOutVertically(targetOffsetY = { it }),
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .navigationBarsPadding()
                .padding(24.dp)
        ) {
            ExtendedFloatingActionButton(
                onClick = { openAssistantSheet() },
                containerColor = colorScheme.primary,
                contentColor = colorScheme.onPrimary,
                shape = RoundedCornerShape(28.dp)
            ) {
                Icon(Icons.Default.Edit, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                UnBlockWordmark()
            }
        }

        // Rewrite chip bar — shown when text is selected and no other UI is open
        val selection = viewModel.lyricsFieldValue.selection
        val rewriteVisible = !selection.collapsed &&
            !showBottomSheet &&
            !pendingAssistantSheet &&
            !modalOpen &&
            viewModel.rewriteAction == null
        AnimatedVisibility(
            visible = rewriteVisible,
            enter = fadeIn() + slideInVertically(initialOffsetY = { it }),
            exit = fadeOut() + slideOutVertically(targetOffsetY = { it }),
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 12.dp)
        ) {
            RewriteChipBar(
                onAction = { viewModel.requestRewrite(it) }
            )
        }

        // Export sheet
        if (viewModel.showExportSheet) {
            ExportSheet(
                onPick = { launchExport(it) },
                onDismiss = { viewModel.showExportSheet = false }
            )
        }

        // Rewrite preview dialog
        viewModel.rewriteAction?.let { action ->
            RewriteDialog(
                action = action,
                original = viewModel.rewriteOriginal.orEmpty(),
                preview = viewModel.rewritePreview,
                loading = viewModel.rewriteLoading,
                error = viewModel.rewriteError,
                onApply = { viewModel.applyRewrite() },
                onDismiss = { viewModel.dismissRewrite() }
            )
        }

        // Bottom sheet for assistant
        if (showBottomSheet) {
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
                        .height(64.dp)
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
                            .width(44.dp)
                            .height(5.dp)
                            .background(colorScheme.outlineVariant, RoundedCornerShape(2.5.dp))
                    )
                }

                AssistantPanel(
                    viewModel = viewModel,
                    rhymeContext = rhymeContext,
                    onSuggestionInserted = { showBottomSheet = false },
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .navigationBarsPadding()
                        .padding(bottom = 16.dp)
                )
            }
        }
    }
}

@Composable
private fun UnBlockWordmark() {
    val color = MaterialTheme.colorScheme.onPrimary

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("UnBlock", fontWeight = FontWeight.Medium)
        Canvas(
            modifier = Modifier
                .width(68.dp)
                .height(5.dp)
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
