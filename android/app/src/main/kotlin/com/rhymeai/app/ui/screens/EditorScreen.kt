package com.rhymeai.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoFixHigh
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.SaveStatus
import com.rhymeai.app.ui.components.AssistantPanel
import com.rhymeai.app.ui.components.SyllableColoredText
import com.rhymeai.app.util.SyllableCounter
import kotlin.math.ceil
import kotlin.math.roundToInt

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
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    val colorScheme = MaterialTheme.colorScheme
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val focusManager = LocalFocusManager.current
    val fullSheetHeight = configuration.screenHeightDp.dp
    val keyboardVisible = WindowInsets.ime.getBottom(density) > 0
    var pendingAssistantSheet by remember { mutableStateOf(false) }

    LaunchedEffect(pendingAssistantSheet, keyboardVisible) {
        if (pendingAssistantSheet && !keyboardVisible) {
            showBottomSheet = true
            pendingAssistantSheet = false
        }
    }

    fun openAssistantSheet() {
        if (keyboardVisible) {
            focusManager.clearFocus(force = true)
            pendingAssistantSheet = true
        } else {
            showBottomSheet = true
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colorScheme.background)
            .statusBarsPadding()
            .imePadding()
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Top bar — always visible
            run {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(colorScheme.surface)
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier.weight(1f, fill = false)
                    ) {
                        TextButton(onClick = { onNavigateToStart() }) {
                            Icon(Icons.Default.Menu, null, tint = colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Menu", color = colorScheme.onSurfaceVariant, style = MaterialTheme.typography.labelLarge)
                        }

                        Box(Modifier.width(1.dp).height(16.dp).background(colorScheme.outlineVariant))

                        val projectsColor = if (viewModel.saveStatus == SaveStatus.SAVED)
                            Color(0xFF6EE7B7) else colorScheme.onSurfaceVariant

                        TextButton(onClick = { viewModel.showProjectsDialog = true }) {
                            Icon(Icons.Default.FolderOpen, null, tint = projectsColor, modifier = Modifier.size(14.dp))
                            Text(" Projects", color = projectsColor, fontSize = 11.sp)
                        }

                        TextButton(onClick = { viewModel.showSettingsDialog = true }) {
                            Icon(Icons.Default.Settings, null, tint = colorScheme.onSurfaceVariant, modifier = Modifier.size(14.dp))
                        }
                    }

                    val wordCount = remember(viewModel.lyrics) { SyllableCounter.wordCount(viewModel.lyrics) }
                    val syllableCount = remember(viewModel.lyrics) { SyllableCounter.countText(viewModel.lyrics) }

                    Column(horizontalAlignment = Alignment.End) {
                        Text(
                            "$wordCount words",
                            fontSize = 10.sp,
                            color = colorScheme.onSurfaceVariant
                        )
                        Text(
                            "$syllableCount syllables",
                            fontSize = 10.sp,
                            color = colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // Divider
            Box(Modifier.fillMaxWidth().height(1.dp).background(colorScheme.outlineVariant))

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

                    // Lyrics editor with syllable coloring overlay
                    Box(modifier = Modifier.fillMaxWidth()) {
                        // Colored overlay (behind)
                        if (viewModel.isSyllableColoringEnabled && viewModel.lyrics.isNotEmpty()) {
                            SyllableColoredText(
                                text = viewModel.lyrics,
                                enabled = true,
                                style = TextStyle(
                                    fontSize = 16.sp,
                                    lineHeight = 28.sp,
                                    fontFamily = FontFamily.Default
                                )
                            )
                        }

                        // Actual text field (on top, transparent if coloring is on)
                        BasicTextField(
                            value = viewModel.lyricsFieldValue,
                            onValueChange = { viewModel.onLyricsChanged(it) },
                            onTextLayout = { lyricsTextLayout = it },
                            textStyle = TextStyle(
                                fontSize = 16.sp,
                                lineHeight = 28.sp,
                                fontFamily = FontFamily.Default,
                                color = if (viewModel.isSyllableColoringEnabled)
                                    Color.Transparent
                                else
                                    colorScheme.onBackground.copy(alpha = 0.9f)
                            ),
                            cursorBrush = SolidColor(colorScheme.primary),
                            modifier = Modifier
                                .fillMaxWidth()
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

        // UnBlock FAB — always visible when sheet is closed
        AnimatedVisibility(
            visible = !showBottomSheet && !pendingAssistantSheet,
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
                Icon(Icons.Default.AutoFixHigh, null, modifier = Modifier.size(18.dp))
                Text("  UnBlock", fontWeight = FontWeight.Medium)
            }
        }

        // Bottom sheet for assistant
        if (showBottomSheet) {
            ModalBottomSheet(
                onDismissRequest = { showBottomSheet = false },
                sheetState = sheetState,
                modifier = Modifier.fillMaxSize(),
                shape = RoundedCornerShape(topStart = 0.dp, topEnd = 0.dp),
                containerColor = colorScheme.surfaceContainerLow,
                contentColor = colorScheme.onSurface,
                contentWindowInsets = { WindowInsets.statusBars },
                dragHandle = {
                    Box(
                        modifier = Modifier
                            .padding(vertical = 12.dp)
                            .width(40.dp)
                            .height(4.dp)
                            .background(colorScheme.outlineVariant, RoundedCornerShape(2.dp))
                    )
                }
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(fullSheetHeight)
                ) {
                    AssistantPanel(
                        viewModel = viewModel,
                        rhymeContext = rhymeContext,
                        modifier = Modifier
                            .fillMaxSize()
                            .navigationBarsPadding()
                            .padding(bottom = 16.dp)
                    )
                }
            }
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
