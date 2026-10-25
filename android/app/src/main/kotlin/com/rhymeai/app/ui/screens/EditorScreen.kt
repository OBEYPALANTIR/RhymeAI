package com.rhymeai.app.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import com.rhymeai.app.BuildConfig
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.calculateTargetValue
import androidx.compose.animation.rememberSplineBasedDecay
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDp
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.updateTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.ripple
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.flow.collectLatest
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Alignment
import androidx.compose.ui.BiasAlignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.layout.layout
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.SemanticsPropertyReceiver
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import com.rhymeai.app.ui.components.SongRecordingsDialog
import com.rhymeai.app.R
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.ScriptedSuggestionStream
import com.rhymeai.app.SaveStatus
import com.rhymeai.app.data.model.ExportFormat
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.ui.components.AssistantPanel
import com.rhymeai.app.ui.components.ExportSheet
import com.rhymeai.app.ui.components.EditorUndoRedoControls
import com.rhymeai.app.ui.components.KeyboardSafeActionArea
import com.rhymeai.app.ui.components.RewriteChipBar
import com.rhymeai.app.ui.components.rememberAnalysisText
import com.rhymeai.app.ui.components.lyricAnalysisTransformation
import com.rhymeai.app.ui.components.WordInspectorSheet
import com.rhymeai.app.ui.components.analyzeSyllableUnderlines
import com.rhymeai.app.ui.components.colorSyllableUnderlines
import com.rhymeai.app.ui.components.bottomSafeActionPadding
import com.rhymeai.app.ui.components.keyboardAwareBottomPadding
import com.rhymeai.app.ui.components.syllableUnderlines
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.appWritingSurface
import com.rhymeai.app.ui.theme.outlineStrongColorFor
import com.rhymeai.app.ui.theme.selectionColorFor
import com.rhymeai.app.ui.theme.editorSyllableCountColor
import com.rhymeai.app.ui.theme.editorWordCountColor
import com.rhymeai.app.ui.motion.OffsetMotionState
import com.rhymeai.app.ui.motion.RewriteHighlightColors
import com.rhymeai.app.ui.motion.RewriteHighlightState
import com.rhymeai.app.ui.motion.rewriteLoadingHighlight
import com.rhymeai.app.util.LyricsExporter
import com.rhymeai.app.util.SectionMap
import com.rhymeai.app.util.SyllableCounter
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class LyricStatsSnapshot(
    val sourceText: String,
    val wordCount: Int,
    val syllableCount: Int
)

internal fun currentLyricStats(
    lyrics: String,
    snapshot: LyricStatsSnapshot?
): LyricStatsSnapshot? = snapshot?.takeIf { it.sourceText == lyrics }

private const val FAKE_RECORDING_EXTRA = "com.rhymeai.app.FAKE_RECORDING"

internal fun compactEditorStats(wordCount: Int, syllableCount: Int): String =
    "${wordCount}w · ${syllableCount}s"

internal fun historyControlsVisible(
    editorActionsVisible: Boolean,
    isRecording: Boolean
): Boolean = editorActionsVisible && !isRecording

/** Opacity of the writing column while a newly opened song settles in; 1 at rest. */
internal val EditorOpenSettleAlpha = SemanticsPropertyKey<Float>("EditorOpenSettleAlpha")
private var SemanticsPropertyReceiver.editorOpenSettleAlpha by EditorOpenSettleAlpha

/** Opacity of the Use-line insertion highlight; 0 once the ink has dried. */
internal val EditorInsertionHighlightAlpha = SemanticsPropertyKey<Float>("EditorInsertionHighlightAlpha")
private var SemanticsPropertyReceiver.editorInsertionHighlightAlpha by EditorInsertionHighlightAlpha

/**
 * Song-open settle bookkeeping. Plain fields, written in the composition that first sees a new
 * [MainViewModel.openRevision], so the first frame of the new song is already at alpha 0.
 */
private class SongOpenSettle(var revision: Int) {
    var fadeRequest = 0
    var startedRequest = 0
}

@Composable
private fun rememberExportDocumentLauncher(
    format: ExportFormat,
    onExportUriSelected: (android.net.Uri?) -> Unit
) = rememberLauncherForActivityResult(
    contract = ActivityResultContracts.CreateDocument(format.mimeType),
    onResult = onExportUriSelected
)

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun EditorScreen(viewModel: MainViewModel, onNavigateToStart: () -> Unit = {}) {
    var recordingsProjectId by rememberSaveable { mutableStateOf<String?>(null) }
    var showBottomSheet by remember { mutableStateOf(false) }
    var lyricsFocused by remember { mutableStateOf(false) }
    var lyricsTextLayout by remember { mutableStateOf<TextLayoutResult?>(null) }
    var titleHeightPx by remember { mutableIntStateOf(0) }
    var metadataHeightPx by remember { mutableIntStateOf(0) }
    var analyzedLyrics by remember { mutableStateOf(viewModel.lyrics) }
    var lyricStats by remember {
        mutableStateOf<LyricStatsSnapshot?>(
            if (viewModel.lyrics.isEmpty()) LyricStatsSnapshot("", 0, 0) else null
        )
    }
    var songActionsExpanded by remember { mutableStateOf(false) }
    var sectionMenuExpanded by remember { mutableStateOf(false) }
    var focusMode by rememberSaveable { mutableStateOf(false) }
    var highlightedInsertionId by remember { mutableStateOf<Long?>(null) }

    val colorScheme = MaterialTheme.colorScheme
    val animationsEnabled = LocalAnimationsEnabled.current
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val focusManager = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    var micBusy by remember { mutableStateOf(false) }
    val snackbarHostState = remember { SnackbarHostState() }
    val insertionSnackbarHostState = remember { SnackbarHostState() }

    // Song-open settle: while the view model fetches another song (openingSong) the writing column
    // fades out on the dismiss tier; when the new song's state lands (openRevision) it fades in on
    // the state tier. Opacity only; the restored cursor and scroll are already underneath.
    val songSettle = remember { SongOpenSettle(viewModel.openRevision) }
    val songColumnAlpha = remember { Animatable(1f) }
    val openingSong = viewModel.openingSong
    LaunchedEffect(openingSong) {
        if (!animationsEnabled) return@LaunchedEffect
        if (openingSong) {
            songColumnAlpha.animateTo(0f, tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing))
        } else if (songSettle.fadeRequest == songSettle.startedRequest && songColumnAlpha.value < 1f) {
            // The open ended without a new song (it failed); bring the column back.
            songColumnAlpha.animateTo(1f, tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing))
        }
    }
    val openRevision = viewModel.openRevision
    if (songSettle.revision != openRevision) {
        songSettle.revision = openRevision
        if (animationsEnabled) songSettle.fadeRequest++
    }
    LaunchedEffect(songSettle.fadeRequest) {
        if (songSettle.fadeRequest == 0) return@LaunchedEffect
        songColumnAlpha.snapTo(0f)
        songSettle.startedRequest = songSettle.fadeRequest
        songColumnAlpha.animateTo(1f, tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing))
    }

    // New Song: the caret is already in the title once the blank page is up.
    val titleFocusRequester = remember { FocusRequester() }
    val keyboardController = LocalSoftwareKeyboardController.current
    var newSongFocusedRevision by rememberSaveable { mutableIntStateOf(0) }
    val newSongRevision = viewModel.newSongRevision
    LaunchedEffect(newSongRevision, viewModel.showProjectsDialog) {
        if (newSongRevision == 0 || newSongRevision == newSongFocusedRevision || viewModel.showProjectsDialog) return@LaunchedEffect
        newSongFocusedRevision = newSongRevision
        titleFocusRequester.requestFocus()
        keyboardController?.show()
    }

    val fullSheetHeightPx = with(density) { configuration.screenHeightDp.dp.toPx() }
    val assistantSheetHandleHeightPx = with(density) { DesignTokens.Sheet.handleArea.toPx() }
    val assistantSheetCloseThresholdPx =
        ((fullSheetHeightPx - assistantSheetHandleHeightPx).coerceAtLeast(0f)) * 0.5f
    // A medium downward flick dismisses short of halfway; the half-travel projection alone needs ~1,380 dp/s (Material sheets use 125 dp/s).
    val assistantSheetDismissVelocityPx = with(density) { 450.dp.toPx() }
    val assistantSheetOffset = remember(scope) { OffsetMotionState(scope) }
    val assistantSheetDecay = rememberSplineBasedDecay<Float>()
    val keyboardVisible = WindowInsets.ime.getBottom(density) > 0
    var pendingAssistantSheet by remember { mutableStateOf(false) }
    var rewriteChipBarHeightPx by remember { mutableIntStateOf(0) }
    var rewriteReviewBarHeightPx by remember { mutableIntStateOf(0) }

    val insertion = viewModel.suggestionInsertion
    LaunchedEffect(insertion?.id, showBottomSheet, pendingAssistantSheet) {
        if (insertion == null || showBottomSheet || pendingAssistantSheet) return@LaunchedEffect
        val result = insertionSnackbarHostState.showSnackbar("Line added", actionLabel = "Undo", withDismissAction = true, duration = SnackbarDuration.Short)
        if (result == SnackbarResult.ActionPerformed) viewModel.undoSuggestionInsertion(insertion.id)
        else viewModel.dismissSuggestionInsertion(insertion.id)
    }
    val insertionHighlightAlpha = remember { Animatable(0f) }
    LaunchedEffect(insertion?.id, showBottomSheet, pendingAssistantSheet) {
        highlightedInsertionId = null
        insertionHighlightAlpha.snapTo(0f)
        if (insertion == null || showBottomSheet || pendingAssistantSheet) return@LaunchedEffect
        highlightedInsertionId = insertion.id
        insertionHighlightAlpha.snapTo(1f)
        delay(2_000)
        // The mark dries into the page on the settle spring instead of switching off.
        if (animationsEnabled) insertionHighlightAlpha.animateTo(0f, DesignTokens.Motion.settleSpring())
        else insertionHighlightAlpha.snapTo(0f)
        highlightedInsertionId = null
    }

    LaunchedEffect(viewModel.lyrics) {
        val lyricsSnapshot = viewModel.lyrics
        delay(180)
        val stats = withContext(Dispatchers.Default) {
            LyricStatsSnapshot(
                sourceText = lyricsSnapshot,
                wordCount = SyllableCounter.lyricWordCount(lyricsSnapshot),
                syllableCount = SyllableCounter.lyricSyllableCount(lyricsSnapshot)
            )
        }
        analyzedLyrics = lyricsSnapshot
        lyricStats = stats
    }

    fun beginAssistantSheetPresentation() {
        assistantSheetOffset.snapTo(if (animationsEnabled) fullSheetHeightPx else 0f)
        showBottomSheet = true
        assistantSheetOffset.animateTo(
            target = 0f,
            animationSpec = tween(
                durationMillis = DesignTokens.Motion.sheetPresentMillis,
                easing = DesignTokens.Motion.emphasizedEasing
            ),
            animationsEnabled = animationsEnabled
        )
    }

    LaunchedEffect(pendingAssistantSheet, keyboardVisible) {
        if (pendingAssistantSheet && !keyboardVisible) {
            beginAssistantSheetPresentation()
            pendingAssistantSheet = false
        }
    }

    fun dismissAssistantSheet() {
        pendingAssistantSheet = false
        if (!showBottomSheet) {
            assistantSheetOffset.snapTo(0f)
            return
        }

        assistantSheetOffset.animateTo(
            target = fullSheetHeightPx,
            animationSpec = tween(
                durationMillis = DesignTokens.Motion.dismissMillis,
                easing = DesignTokens.Motion.exitEasing
            ),
            animationsEnabled = animationsEnabled
        ) {
            showBottomSheet = false
            assistantSheetOffset.snapTo(0f)
        }
    }

    fun settleAssistantSheetDrag(velocity: Float) {
        // Like iOS predictedEndTranslation: a downward fling dismisses even when released short of the threshold.
        val projectedOffset = assistantSheetDecay.calculateTargetValue(assistantSheetOffset.value, velocity)
        val dismiss = velocity >= assistantSheetDismissVelocityPx ||
            assistantSheetOffset.value >= assistantSheetCloseThresholdPx ||
            projectedOffset >= assistantSheetCloseThresholdPx
        // Both outcomes start from the finger's velocity, so a dismissing fling does not stall at release.
        assistantSheetOffset.animateTo(
            target = if (dismiss) fullSheetHeightPx else 0f,
            animationSpec = DesignTokens.Motion.settleSpring(visibilityThreshold = 0.5f),
            animationsEnabled = animationsEnabled,
            initialVelocity = velocity,
            stopAtTarget = dismiss
        ) {
            if (dismiss) {
                showBottomSheet = false
                assistantSheetOffset.snapTo(0f)
            }
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

    // A take the recorder did not finish is never saved; a finished take whose record
    // could not be written stays in staging and Retry saves it (A22/A24).
    suspend fun reportRecordingFailure(error: Exception) {
        if (error is com.rhymeai.app.service.VoiceMemoService.RecordingNotFinishedException) {
            snackbarHostState.showSnackbar(context.getString(R.string.voice_memo_finish_failed))
            return
        }
        val retry = snackbarHostState.showSnackbar(
            context.getString(R.string.voice_memo_save_failed),
            actionLabel = context.getString(R.string.voice_memo_retry),
            withDismissAction = true,
            duration = SnackbarDuration.Long
        ) == SnackbarResult.ActionPerformed
        val projectId = (error as? com.rhymeai.app.service.VoiceMemoService.RecordingNotSavedException)?.projectId
        if (!retry || projectId == null) return
        try {
            viewModel.voiceMemoService.retryWaitingTakes(projectId)
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (again: Exception) {
            reportRecordingFailure(again)
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

    val modalOpen = recordingsProjectId != null || viewModel.showSongNotebook || viewModel.showSettingsDialog ||
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
    val rewriteVisible = !focusMode && pendingRewriteRange != null &&
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
            // The Song Notebook offers "Keep selected lyrics", so it keeps the selection it opened over.
            if (!viewModel.showSongNotebook) viewModel.clearPendingRewriteSelection()
            if (modalOpen) {
                focusManager.clearFocus(force = true)
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .appWritingSurface()
    ) {
        // The rewrite chip bar takes the floating actions' place, so they leave the screen and
        // the accessibility tree until the selection is gone.
        val fabRowVisible = !focusMode && !showBottomSheet && !pendingAssistantSheet && !modalOpen &&
            !viewModel.hasActiveRewrite && !rewriteVisible
        val memoService = viewModel.voiceMemoService
        LaunchedEffect(memoService) {
            val activity = context as? android.app.Activity
            if ((BuildConfig.DEBUG || BuildConfig.BENCHMARK) &&
                activity?.intent?.getBooleanExtra(FAKE_RECORDING_EXTRA, false) == true
            ) {
                memoService.seedRecordingForTesting()
            }
        }
        // Debug builds only: UI tests and emulator QA can answer Suggest Next
        // Line from a scripted stream (see ScriptedSuggestionStream).
        LaunchedEffect(viewModel) {
            if (!BuildConfig.DEBUG) return@LaunchedEffect
            val intent = (context as? android.app.Activity)?.intent ?: return@LaunchedEffect
            if (intent.getBooleanExtra(ScriptedSuggestionStream.EXTRA, false)) {
                viewModel.enableScriptedSuggestionsForTesting(ScriptedSuggestionStream.fromIntent(intent))
            }
        }
        Column(
            modifier = Modifier
                .fillMaxSize()
                .then(
                    if (showBottomSheet || pendingAssistantSheet) {
                        Modifier.clearAndSetSemantics { }
                    } else {
                        Modifier
                    }
                )
        ) {
            // Top bar — always visible
            TopAppBar(
                navigationIcon = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = { viewModel.showProjectsDialog = true }) {
                            Icon(
                                Icons.Default.Menu,
                                contentDescription = stringResource(R.string.editor_open_songs_drawer),
                                tint = colorScheme.onSurfaceVariant
                            )
                        }
                        if (
                            historyControlsVisible(
                                editorActionsVisible = !showBottomSheet && !pendingAssistantSheet && !modalOpen && !viewModel.hasActiveRewrite,
                                isRecording = memoService.isRecording
                            )
                        ) {
                            EditorUndoRedoControls(
                                canUndo = viewModel.canUndoLyrics,
                                canRedo = viewModel.canRedoLyrics,
                                undoContentDescription = stringResource(R.string.editor_undo),
                                redoContentDescription = stringResource(R.string.editor_redo),
                                onUndo = viewModel::undoLyrics,
                                onRedo = viewModel::redoLyrics
                            )
                        }
                    }
                },
                title = {
                    val savingLabel = stringResource(R.string.editor_saving)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                    ) {
                        when (viewModel.saveStatus) {
                            SaveStatus.SAVING -> CircularProgressIndicator(
                                modifier = Modifier
                                    .size(DesignTokens.Indicator.spinnerSm)
                                    .semantics { contentDescription = savingLabel },
                                strokeWidth = DesignTokens.EditorChrome.saveStatusStrokeWidth,
                                color = colorScheme.onSurfaceVariant
                            )
                            SaveStatus.SAVED -> if (animationsEnabled) {
                                SavedFlourish(
                                    contentDescription = stringResource(R.string.editor_saved),
                                    modifier = Modifier.size(DesignTokens.Indicator.spinnerSm)
                                )
                            } else {
                                Icon(
                                    Icons.Default.Check,
                                    contentDescription = stringResource(R.string.editor_saved),
                                    tint = colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(DesignTokens.Indicator.spinnerSm)
                                )
                            }
                            else -> {}
                        }
                    }
                },
                actions = {
                    if (!focusMode) Box {
                        IconButton(
                            onClick = { songActionsExpanded = true },
                            enabled = !viewModel.hasActiveRewrite,
                            modifier = Modifier.testTag("songActionsMenuButton")
                        ) {
                            Icon(
                                imageVector = Icons.Default.MoreVert,
                                contentDescription = stringResource(R.string.editor_song_actions),
                                tint = colorScheme.onSurfaceVariant
                            )
                        }
                        DropdownMenu(
                            expanded = songActionsExpanded,
                            onDismissRequest = { songActionsExpanded = false }
                        ) {
                            DropdownMenuItem(
                                text = { Text("Insert section") },
                                onClick = {
                                    songActionsExpanded = false
                                    sectionMenuExpanded = true
                                },
                                modifier = Modifier.testTag("sectionMenuButton")
                            )
                            DropdownMenuItem(
                                text = { Text("Song recordings") },
                                onClick = {
                                    songActionsExpanded = false
                                    focusManager.clearFocus()
                                    if (!micBusy) {
                                        micBusy = true
                                        scope.launch {
                                            try {
                                                recordingsProjectId = viewModel.ensureProjectForRecording()
                                            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                                                throw cancelled
                                            } catch (_: Exception) {
                                                snackbarHostState.showSnackbar("Could not save this song. Try opening recordings again.")
                                            } finally {
                                                micBusy = false
                                            }
                                        }
                                    }
                                },
                                enabled = !micBusy,
                                modifier = Modifier.testTag("songRecordings")
                            )
                            DropdownMenuItem(
                                text = { Text("Song Notebook") },
                                onClick = {
                                    songActionsExpanded = false
                                    focusManager.clearFocus()
                                    viewModel.showSongNotebook = true
                                }
                            )
                            if (!(viewModel.pendingRewriteRange ?: viewModel.lyricsFieldValue.selection).collapsed) {
                                DropdownMenuItem(
                                    text = { Text("Keep selection") },
                                    onClick = {
                                        songActionsExpanded = false
                                        viewModel.keepSelectedLyrics()
                                        viewModel.showSongNotebook = true
                                    }
                                )
                            }
                            DropdownMenuItem(
                                text = { Text("Export") },
                                enabled = viewModel.lyrics.isNotBlank(),
                                onClick = {
                                    songActionsExpanded = false
                                    viewModel.showExportSheet = true
                                }
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.editor_settings)) },
                                onClick = {
                                    songActionsExpanded = false
                                    viewModel.showSettingsDialog = true
                                }
                            )
                        }
                        DropdownMenu(
                            expanded = sectionMenuExpanded,
                            onDismissRequest = { sectionMenuExpanded = false }
                        ) {
                            SectionMap.standardLabels.forEach { label ->
                                DropdownMenuItem(
                                    text = { Text(label) },
                                    onClick = {
                                        sectionMenuExpanded = false
                                        viewModel.insertSection(label)
                                    },
                                    modifier = Modifier.testTag("sectionMenu${label.filter(Char::isLetter)}")
                                )
                            }
                        }
                    }
                    TextButton(
                        onClick = {
                            focusMode = !focusMode
                            songActionsExpanded = false
                            sectionMenuExpanded = false
                        },
                        enabled = !viewModel.hasActiveRewrite && !memoService.isRecording,
                        modifier = Modifier
                            .testTag("focusWritingToggle")
                            .semantics { stateDescription = if (focusMode) "On" else "Off" }
                    ) { Text(if (focusMode) "Exit Focus" else "Focus") }
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
            val scrollState = androidx.compose.runtime.key(viewModel.editorPositionRevision) {
                // The saved offset only seeds a new scroll state (keyed by revision). Reading it
                // observably would recompose the whole editor on every scroll frame, because the
                // collector below writes it back as the user scrolls.
                val savedOffset = Snapshot.withoutReadObservation { viewModel.editorScrollOffset }
                rememberScrollState(with(density) { savedOffset.dp.roundToPx() })
            }
            LaunchedEffect(scrollState, viewModel.editorPositionRevision) {
                snapshotFlow { scrollState.value }.collectLatest { offset ->
                    viewModel.rememberEditorPosition(with(density) { offset.toDp().value })
                }
            }
            val activeRewriteSurfaceHeightPx = when {
                rewriteReviewVisible -> rewriteReviewBarHeightPx
                rewriteVisible -> rewriteChipBarHeightPx
                else -> 0
            }
            val activeRewriteSurfaceHeight = with(density) {
                activeRewriteSurfaceHeightPx.toDp()
            }
            val baseViewportInset = keyboardAwareBottomPadding(extra = 0.dp)
            val fabViewportInset = if (fabRowVisible) {
                baseViewportInset +
                    DesignTokens.Rhythm.section +
                    DesignTokens.EditorChrome.fabSize +
                    DesignTokens.Rhythm.related
            } else {
                0.dp
            }
            val rewriteViewportInset = if (rewriteVisible || rewriteReviewVisible) {
                baseViewportInset +
                    DesignTokens.Rhythm.standard +
                    activeRewriteSurfaceHeight +
                    DesignTokens.Spacing.md
            } else {
                0.dp
            }
            val editorViewportBottomInset = maxOf(
                baseViewportInset,
                fabViewportInset,
                rewriteViewportInset
            )
            BoxWithConstraints(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(bottom = editorViewportBottomInset)
                    .clipToBounds()
            ) {
                val trailingScrollSpace = if (keyboardVisible || rewriteVisible || rewriteReviewVisible) {
                    maxOf(
                        DesignTokens.Editor.keyboardOffset,
                        maxHeight * (1f - DesignTokens.Phi.inverse)
                    )
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
                val resolvedMetadataHeightPx = metadataHeightPx.takeIf { it > 0 }
                    ?: with(density) { DesignTokens.Editor.metadataLineHeight.roundToPx() }
                val lyricsTopPx = with(density) {
                    (
                        DesignTokens.Rhythm.standard +
                            DesignTokens.Spacing.xs +
                            DesignTokens.Rhythm.standard
                        ).roundToPx()
                } + resolvedMetadataHeightPx + titleHeightPx
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
                val nearbyLineContextPx = if (keyboardVisible) lineHeightPx * 2 else lineHeightPx
                val maxSafeBottomPx = (viewportHeightPx - nearbyLineContextPx)
                    .coerceAtLeast(minSafeTopPx + lineHeightPx)
                val rangeSelectionActive = activeRangeStart != activeRangeEnd || viewModel.hasActiveRewrite
                val selectedRangeSafeBottomPx = if (keyboardVisible || rangeSelectionActive) {
                    val safeHeightPx = (maxSafeBottomPx - minSafeTopPx).coerceAtLeast(lineHeightPx)
                    val goldenBandBottomPx = minSafeTopPx + (safeHeightPx * DesignTokens.Phi.inverse).roundToInt()
                    minOf(maxSafeBottomPx, goldenBandBottomPx)
                } else {
                    maxSafeBottomPx
                }
                // Only a finger drag on the editor collapses the keyboard: Compose's bring-into-view, which keeps
                // the cursor or a new selection on screen, also scrolls as NestedScrollSource.UserInput.
                val editorDragged by scrollState.interactionSource.collectIsDraggedAsState()
                LaunchedEffect(editorDragged) {
                    if (editorDragged && keyboardVisible && lyricsFocused) {
                        focusManager.clearFocus(force = true)
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
                    editorViewportBottomInset,
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
                        .semantics { editorOpenSettleAlpha = songColumnAlpha.value }
                        .graphicsLayer {
                            // A fade-in that has not started yet holds the new song's first frame at 0.
                            alpha = if (songSettle.fadeRequest != songSettle.startedRequest) 0f else songColumnAlpha.value
                        }
                        .verticalScroll(scrollState)
                        .padding(horizontal = DesignTokens.Editor.horizontalPadding)
                ) {
                    Spacer(Modifier.height(DesignTokens.Rhythm.standard))

                    // Title field
                    val titleStyle = MaterialTheme.typography.headlineLarge.copy(
                        color = colorScheme.onBackground,
                        fontSize = DesignTokens.Editor.titleFontSize,
                        lineHeight = DesignTokens.Editor.titleLineHeight
                    )
                    BasicTextField(
                        value = viewModel.title,
                        onValueChange = { viewModel.onTitleChanged(it) },
                        // Not singleLine so long titles wrap; Enter (soft Next or a hardware key) moves to the lyrics.
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                        keyboardActions = KeyboardActions(onNext = { focusManager.moveFocus(FocusDirection.Down) }),
                        textStyle = titleStyle,
                        cursorBrush = SolidColor(colorScheme.primary),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("songTitleEditor")
                            .focusRequester(titleFocusRequester)
                            .onPreviewKeyEvent {
                                if (!isTitleSubmitKey(it.type, it.key, modified = it.isShiftPressed || it.isCtrlPressed || it.isAltPressed || it.isMetaPressed)) return@onPreviewKeyEvent false
                                focusManager.moveFocus(FocusDirection.Down)
                                true
                            }
                            .onSizeChanged { titleHeightPx = it.height },
                        decorationBox = { innerTextField ->
                            Box {
                                if (viewModel.title.isEmpty()) {
                                    Text(
                                        "Song Title...",
                                        style = titleStyle,
                                        color = colorScheme.onSurfaceVariant
                                    )
                                }
                                innerTextField()
                            }
                        }
                    )

                    Spacer(Modifier.height(DesignTokens.Spacing.xs))
                    val statsUseDarkPalette = LocalAppAppearance.current.isDark
                    val visibleLyricStats = currentLyricStats(viewModel.lyrics, lyricStats)
                    val measuredLyricStats = visibleLyricStats
                        ?: lyricStats
                        ?: LyricStatsSnapshot("", 0, 0)
                    val secondaryContentAlpha by animateFloatAsState(
                        targetValue = if (focusMode) 0f else 1f,
                        animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.feedbackMillis else 0),
                        label = "focusSecondaryContent"
                    )
                    Text(
                        text = buildAnnotatedString {
                            withStyle(
                                SpanStyle(
                                    color = editorWordCountColor(statsUseDarkPalette),
                                    fontWeight = FontWeight.SemiBold
                                )
                            ) {
                                append("${measuredLyricStats.wordCount}w")
                            }
                            withStyle(SpanStyle(color = colorScheme.onSurfaceVariant)) {
                                append(" · ")
                            }
                            withStyle(
                                SpanStyle(
                                    color = editorSyllableCountColor(statsUseDarkPalette),
                                    fontWeight = FontWeight.SemiBold
                                )
                            ) {
                                append("${measuredLyricStats.syllableCount}s")
                            }
                        },
                        fontSize = DesignTokens.Editor.metadataFontSize,
                        lineHeight = DesignTokens.Editor.metadataLineHeight,
                        modifier = Modifier
                            .fillMaxWidth()
                            .onSizeChanged { metadataHeightPx = it.height }
                            .graphicsLayer { alpha = secondaryContentAlpha * if (visibleLyricStats == null) 0f else 1f }
                            .then(
                                if (focusMode || visibleLyricStats == null) {
                                    Modifier.clearAndSetSemantics { }
                                } else {
                                    Modifier.testTag("editorStats")
                                }
                            )
                    )
                    Spacer(Modifier.height(DesignTokens.Rhythm.standard))

                    // Expensive lyric analysis waits until typing pauses so editor redraws stay stable.
                    // It stays on while text is selected: the field draws its selection behind the coloured words.
                    val lyricAnalysisReady = analyzedLyrics == viewModel.lyrics
                    val analysisOverlayActive = (
                        viewModel.isRhymeHighlightEnabled || viewModel.isSyllableColoringEnabled
                    ) &&
                        viewModel.lyrics.isNotEmpty() &&
                        !viewModel.hasActiveRewrite &&
                        lyricAnalysisReady
                    // Underlines only when rhyme coloring owns the foreground; otherwise syllables tint the word itself.
                    val syllableUnderlineActive = !focusMode && viewModel.isSyllableColoringEnabled &&
                        viewModel.isRhymeHighlightEnabled &&
                        viewModel.lyrics.isNotEmpty() &&
                        !viewModel.hasActiveRewrite &&
                        lyricAnalysisReady
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
                    val syllableIsDark = LocalAppAppearance.current.isDark
                    val syllableUnderlineAnalysis = remember(analyzedLyrics, syllableUnderlineActive) {
                        analyzeSyllableUnderlines(
                            text = analyzedLyrics,
                            enabled = syllableUnderlineActive
                        )
                    }
                    val syllableUnderlineSpans = remember(syllableUnderlineAnalysis, syllableIsDark) {
                        colorSyllableUnderlines(syllableUnderlineAnalysis, syllableIsDark)
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
                    val analysisTextActive = analysisOverlayActive && !focusMode
                    val analysisText = rememberAnalysisText(
                        text = analyzedLyrics,
                        enabled = analysisTextActive && viewModel.isRhymeHighlightEnabled,
                        syllablesEnabled = analysisTextActive && viewModel.isSyllableColoringEnabled
                    )
                    val analysisTransformation = remember(analysisTextActive, analysisText) {
                        lyricAnalysisTransformation(analysisTextActive, analysisText)
                    }
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .then(if (analysisTextActive) Modifier.testTag("lyricAnalysisOverlay") else Modifier)
                    ) {
                        val selectionColors = TextSelectionColors(
                            handleColor = colorScheme.primary,
                            backgroundColor = selectionColorFor(LocalAppAppearance.current)
                        )
                        CompositionLocalProvider(LocalTextSelectionColors provides selectionColors) {
                        BasicTextField(
                            value = if (viewModel.hasActiveRewrite) inlineRewriteValue else viewModel.lyricsFieldValue,
                            onValueChange = {
                                if (!viewModel.hasActiveRewrite) {
                                    viewModel.onLyricsChanged(it)
                                }
                            },
                            onTextLayout = { lyricsTextLayout = it },
                            readOnly = viewModel.hasActiveRewrite,
                            textStyle = lyricsTextStyle.copy(color = colorScheme.onBackground),
                            visualTransformation = analysisTransformation,
                            cursorBrush = SolidColor(colorScheme.primary),
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag("lyricsEditor")
                                .semantics { editorInsertionHighlightAlpha = insertionHighlightAlpha.value }
                                .drawWithCache {
                                    val range = insertion?.takeIf { it.id == highlightedInsertionId }?.range
                                    val layout = lyricsTextLayout?.takeIf { it.layoutInput.text.text == viewModel.lyrics }
                                    val path = if (range != null && layout != null && range.min < range.max) {
                                        layout.getPathForRange(range.min, range.max.coerceAtMost(viewModel.lyrics.length))
                                    } else null
                                    onDrawBehind {
                                        if (path != null) drawPath(path, colorScheme.onSurface.copy(alpha = 0.12f * insertionHighlightAlpha.value))
                                    }
                                }
                                .rewriteLoadingHighlight(
                                    textLayoutResult = lyricsTextLayout,
                                    state = RewriteHighlightState(
                                        range = if (focusMode) null else rewriteHighlightRange
                                    ),
                                    // The editor's own selection tint and strong outline: nothing on
                                    // the text moves while a rewrite is in flight, the rewrite bar
                                    // carries the loading state. Drawn behind the text, so opaque is fine.
                                    colors = if (viewModel.hasActiveRewrite && viewModel.rewriteError != null) {
                                        RewriteHighlightColors(
                                            fill = colorScheme.error.copy(alpha = 0.22f),
                                            stroke = colorScheme.error.copy(alpha = 0.70f)
                                        )
                                    } else {
                                        RewriteHighlightColors(
                                            fill = selectionColorFor(LocalAppAppearance.current),
                                            stroke = outlineStrongColorFor(LocalAppAppearance.current)
                                        )
                                    }
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
                                            color = colorScheme.onSurfaceVariant
                                        )
                                    }
                                    innerTextField()
                                }
                            }
                        )
                        }
                    }

                    // Extra space lets the last line settle around the same point while typing.
                    Spacer(Modifier.height(trailingScrollSpace))
                }
            }
        }

        if (!focusMode) {
            AnimatedVisibility(
                visible = fabRowVisible,
                enter = fadeIn(tween(if (animationsEnabled) DesignTokens.Motion.feedbackMillis else 0)),
                exit = fadeOut(tween(if (animationsEnabled) DesignTokens.Motion.feedbackMillis else 0)),
                modifier = Modifier.align(Alignment.BottomEnd)
            ) {
                KeyboardSafeActionArea(
                    modifier = Modifier.padding(end = DesignTokens.Rhythm.standard),
                    extra = DesignTokens.Rhythm.section,
                    horizontalAlignment = Alignment.End
                ) {
                val barCount = DesignTokens.EditorChrome.recordingBarCount
                // Amplitude + elapsed polling while recording — drives the spectralizer pill.
                val amplitudeBars = remember(barCount) { FloatArray(barCount) }
                var amplitudeCursor by remember(barCount) { mutableIntStateOf(0) }
                var waveformRevision by remember(barCount) { mutableIntStateOf(0) }

                LaunchedEffect(memoService.isRecording) {
                    if (!memoService.isRecording) {
                        amplitudeBars.fill(0f)
                        amplitudeCursor = 0
                        waveformRevision++
                        return@LaunchedEffect
                    }
                    while (memoService.isRecording) {
                        delay(100)
                        val raw = memoService.currentAmplitude()
                        val previousIndex = (amplitudeCursor - 1 + barCount) % barCount
                        amplitudeBars[amplitudeCursor] =
                            amplitudeBars[previousIndex] * 0.7f + raw * 0.3f
                        amplitudeCursor = (amplitudeCursor + 1) % barCount
                        waveformRevision++
                    }
                }

                // Recording drives the fade; the widths follow it on one transition of their own.
                val micTransition = updateTransition(
                    targetState = memoService.isRecording,
                    label = "micRecording"
                )

                val micRecordingWidth = DesignTokens.EditorChrome.micRecordingWidth
                val unBlockTextStyle = LocalTextStyle.current.copy(fontWeight = FontWeight.Medium)
                val unBlockTextMeasurer = rememberTextMeasurer()
                val measuredUnBlockWordmarkWidth = remember(unBlockTextMeasurer, unBlockTextStyle, density) {
                    with(density) {
                        unBlockTextMeasurer.measure(
                            text = AnnotatedString("UnBlock"),
                            style = unBlockTextStyle,
                            maxLines = 1,
                            softWrap = false
                        ).size.width.toDp()
                    }
                }
                val maxUnBlockWidth = (
                        configuration.screenWidthDp.dp -
                        DesignTokens.EditorChrome.micRecordingRestWidth -
                        DesignTokens.Spacing.sm -
                        (DesignTokens.Rhythm.standard * 2)
                    ).coerceAtLeast(DesignTokens.EditorChrome.fabSize)
                val unBlockExtendedWidth = unBlockButtonWidth(
                    measuredWordmarkWidth = measuredUnBlockWordmarkWidth,
                    maxAvailableWidth = maxUnBlockWidth
                )
                val unBlockExpandedWordmarkWidth = unBlockWordmarkWidth(measuredUnBlockWordmarkWidth)

                val unBlockWordmarkAlpha = micTransition.animateFloat(
                    label = "unBlockWordmarkAlpha",
                    // Fades out on the feedback tier before any width moves (see widthTransition).
                    transitionSpec = {
                        if (!animationsEnabled) snap()
                        else if (targetState) tween(DesignTokens.Motion.feedbackMillis, easing = DesignTokens.Motion.standardEasing)
                        else DesignTokens.Motion.expressiveSpring()
                    }
                ) { recording -> if (recording) 0f else 1f }

                // The widths and the recording content wait for the wordmark to finish
                // fading, so a collapse never clips a visible glyph; stopping expands at once.
                // With animations off there is no fade to wait for and everything snaps.
                val wordmarkFaded by remember { derivedStateOf { unBlockWordmarkAlpha.value == 0f } }
                val widthTransition = updateTransition(
                    targetState = memoService.isRecording && (!animationsEnabled || wordmarkFaded),
                    label = "micWidths"
                )

                // State references (no `by`): the values are read inside layout
                // and draw lambdas so each spring frame invalidates only those
                // phases instead of recomposing the whole action group.
                val pillWidth = widthTransition.animateDp(
                    label = "pillWidth",
                    transitionSpec = { if (animationsEnabled) DesignTokens.Motion.expressiveSpring(Dp.VisibilityThreshold) else snap() }
                ) { recording -> if (recording) micRecordingWidth else DesignTokens.EditorChrome.fabSize }

                val unBlockWidth = widthTransition.animateDp(
                    label = "unBlockWidth",
                    transitionSpec = { if (animationsEnabled) DesignTokens.Motion.expressiveSpring(Dp.VisibilityThreshold) else snap() }
                ) { recording -> if (recording) DesignTokens.EditorChrome.fabSize else unBlockExtendedWidth }

                val unBlockWordmarkWidth = widthTransition.animateDp(
                    label = "unBlockWordmarkWidth",
                    transitionSpec = { if (animationsEnabled) DesignTokens.Motion.expressiveSpring(Dp.VisibilityThreshold) else snap() }
                ) { recording -> if (recording) 0.dp else unBlockExpandedWordmarkWidth }

                val recProgress = widthTransition.animateFloat(
                    label = "recProgress",
                    transitionSpec = { if (animationsEnabled) DesignTokens.Motion.expressiveSpring() else snap() }
                ) { recording -> if (recording) 1f else 0f }

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                ) {
                    // UnBlock collapses into a pencil circle while recording.
                    val unBlockInteractionSource = remember { MutableInteractionSource() }
                    val unBlockPressScale = rememberPressScale(unBlockInteractionSource)
                    Box(
                        modifier = Modifier
                            .testTag("unBlockAction")
                            .animatedWidth(unBlockWidth)
                            .height(DesignTokens.EditorChrome.fabSize)
                            .graphicsLayer {
                                scaleX = unBlockPressScale.value
                                scaleY = unBlockPressScale.value
                            }
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
                                    .testTag("unBlockWordmark")
                                    .animatedWidth(unBlockWordmarkWidth)
                                    .graphicsLayer { alpha = unBlockWordmarkAlpha.value }
                                    .clipToBounds()
                            ) {
                                Row(
                                    modifier = Modifier.requiredWidth(unBlockExpandedWordmarkWidth),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Spacer(Modifier.width(DesignTokens.EditorChrome.unBlockWordmarkGap))
                                    UnBlockWordmark()
                                }
                            }
                        }
                    }

                    // Animated mic/pill — expands into the recording spectralizer.
                    val micPillInteractionSource = remember { MutableInteractionSource() }
                    val micPressScale = rememberPressScale(micPillInteractionSource)
                    Box(
                        modifier = Modifier
                            .testTag("micButton")
                            .animatedWidth(pillWidth)
                            .height(DesignTokens.EditorChrome.fabSize)
                            .graphicsLayer {
                                scaleX = micPressScale.value
                                scaleY = micPressScale.value
                            }
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
                                        val failure = try {
                                            memoService.stopRecording()
                                            null
                                        } catch (cancelled: kotlinx.coroutines.CancellationException) {
                                            throw cancelled
                                        } catch (error: Exception) {
                                            error
                                        } finally {
                                            micBusy = false
                                        }
                                        if (failure != null) reportRecordingFailure(failure)
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
                                .graphicsLayer {
                                    alpha = ((recProgress.value - DesignTokens.EditorChrome.recordingBarsFadeStart) /
                                        DesignTokens.EditorChrome.recordingBarsFadeDistance).coerceIn(0f, 1f)
                                }
                        ) {
                            Canvas(
                                modifier = Modifier
                                    .weight(1f)
                                    .height(DesignTokens.EditorChrome.recordingMeterHeight)
                            ) {
                                waveformRevision
                                val pitch = size.width / amplitudeBars.size
                                val barWidthPx = pitch * 0.6f
                                amplitudeBars.indices.forEach { i ->
                                    val amplitude = amplitudeBars[(amplitudeCursor + i) % amplitudeBars.size]
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
                                .align(Alignment.CenterEnd)
                                .size(DesignTokens.EditorChrome.fabSize),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Default.Mic,
                                contentDescription = null,
                                tint = colorScheme.onSurfaceVariant,
                                modifier = Modifier
                                    .size(DesignTokens.EditorChrome.recordingIconSize)
                                    .testTag("micGlyph")
                                    .graphicsLayer { alpha = 1f - recProgress.value }
                            )
                            Icon(
                                imageVector = Icons.Default.Pause,
                                contentDescription = null,
                                tint = colorScheme.error,
                                modifier = Modifier
                                    .size(DesignTokens.EditorChrome.recordingIconSize)
                                    .graphicsLayer { alpha = recProgress.value }
                            )
                        }
                    }
                }
                }
            }
        }

        AnimatedVisibility(
            visible = rewriteVisible || rewriteReviewVisible,
            enter = fadeIn(
                animationSpec = tween(
                    durationMillis = if (animationsEnabled) DesignTokens.Motion.feedbackMillis else 0,
                    easing = DesignTokens.Motion.standardEasing
                )
            ),
            exit = fadeOut(
                animationSpec = tween(
                    durationMillis = if (animationsEnabled) DesignTokens.Motion.feedbackMillis else 0,
                    easing = DesignTokens.Motion.exitEasing
                )
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
                if (rewriteVisible) {
                    RewriteChipBar(
                        onAction = { viewModel.requestRewrite(it) },
                        onInspect = singleWordSelection?.let { { viewModel.openInspectorForSelection() } },
                        modifier = Modifier.onSizeChanged { rewriteChipBarHeightPx = it.height }
                    )
                } else {
                    viewModel.rewriteAction?.let { action ->
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
        }

        // Export sheet
        recordingsProjectId?.let { projectId ->
            SongRecordingsDialog(
                projectId = projectId,
                songTitle = viewModel.title.ifBlank { "Untitled Song" },
                service = viewModel.voiceMemoService,
                onDismiss = { recordingsProjectId = null }
            )
        }

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
                    // Clamped so an upward release cannot spring the sheet past the top edge.
                    .offset { IntOffset(x = 0, y = assistantSheetOffset.value.roundToInt().coerceAtLeast(0)) }
                    .appWritingSurface()
                    .semantics {
                        paneTitle = "Assistant"
                        contentDescription = "Assistant panel"
                    }
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .statusBarsPadding()
                        .height(DesignTokens.Sheet.handleArea)
                        .pointerInput(showBottomSheet, fullSheetHeightPx, animationsEnabled) {
                            val velocityTracker = VelocityTracker()
                            detectVerticalDragGestures(
                                onDragStart = {
                                    velocityTracker.resetTracking()
                                    assistantSheetOffset.snapTo(assistantSheetOffset.value)
                                },
                                onVerticalDrag = { change, dragAmount ->
                                    change.consume()
                                    velocityTracker.addPointerInputChange(change)
                                    assistantSheetOffset.snapTo(
                                        (assistantSheetOffset.value + dragAmount)
                                            .coerceIn(0f, fullSheetHeightPx)
                                    )
                                },
                                onDragEnd = { settleAssistantSheetDrag(velocityTracker.calculateVelocity().y) },
                                onDragCancel = { settleAssistantSheetDrag(0f) }
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
                    IconButton(
                        onClick = { dismissAssistantSheet() },
                        modifier = Modifier
                            .align(Alignment.CenterEnd)
                            .padding(end = DesignTokens.Spacing.sm)
                            .size(DesignTokens.Touch.minTarget)
                    ) {
                        Icon(
                            Icons.Default.Close,
                            contentDescription = "Close assistant",
                            tint = colorScheme.onSurfaceVariant
                        )
                    }
                }

                AssistantPanel(
                    viewModel = viewModel,
                    rhymeContext = rhymeContext,
                    onSuggestionInserted = { dismissAssistantSheet() },
                    onModelSetup = { viewModel.showSettingsDialog = true },
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .bottomSafeActionPadding(extra = DesignTokens.Spacing.lg)
                )
            }
        }

        if (viewModel.showSongNotebook) {
            com.rhymeai.app.ui.components.SongNotebookSheet(viewModel) { viewModel.showSongNotebook = false }
        }

        SnackbarHost(
            hostState = insertionSnackbarHostState,
            modifier = Modifier.align(Alignment.BottomCenter)
                .padding(bottom = keyboardAwareBottomPadding(extra = if (fabRowVisible) DesignTokens.EditorChrome.fabSize + DesignTokens.Rhythm.section else DesignTokens.Rhythm.standard))
        )

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
private fun SavedFlourish(
    contentDescription: String,
    modifier: Modifier = Modifier
) {
    val color = MaterialTheme.colorScheme.onSurfaceVariant

    Canvas(
        modifier = modifier
            .semantics { this.contentDescription = contentDescription }
    ) {
        val strokeWidth = 1.8.dp.toPx()
        drawLine(
            color = color,
            start = Offset(size.width * 0.08f, size.height * 0.56f),
            end = Offset(size.width * 0.38f, size.height * 0.82f),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round
        )
        drawLine(
            color = color,
            start = Offset(size.width * 0.38f, size.height * 0.82f),
            end = Offset(size.width * 0.94f, size.height * 0.16f),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round
        )
    }
}

@Composable
private fun rememberPressScale(interactionSource: MutableInteractionSource): androidx.compose.runtime.State<Float> {
    val pressed by interactionSource.collectIsPressedAsState()
    val animationsEnabled = LocalAnimationsEnabled.current
    return animateFloatAsState(
        targetValue = if (animationsEnabled && pressed) 0.97f else 1f,
        animationSpec = if (animationsEnabled) {
            tween(
                durationMillis = DesignTokens.Motion.feedbackMillis,
                easing = DesignTokens.Motion.standardEasing
            )
        } else {
            snap()
        },
        label = "writerActionPress"
    )
}

@Composable
private fun UnBlockWordmark() {
    val color = MaterialTheme.colorScheme.onPrimary

    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = "UnBlock",
            color = color,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            softWrap = false
        )
        Canvas(
            modifier = Modifier
                .width(DesignTokens.EditorChrome.unBlockScribbleWidth)
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

/**
 * Width driven by an animated State, read in the layout phase: each animation
 * frame re-runs layout only, instead of recomposing the whole caller scope
 * the way `Modifier.width(stateReadInComposition)` does.
 */
private fun Modifier.animatedWidth(width: androidx.compose.runtime.State<androidx.compose.ui.unit.Dp>): Modifier =
    layout { measurable, constraints ->
        val w = width.value.roundToPx().coerceAtLeast(0)
        val placeable = measurable.measure(constraints.copy(minWidth = w, maxWidth = w))
        layout(w, placeable.height) { placeable.placeRelative(0, 0) }
    }

/**
 * True only for an unmodified Enter or numpad Enter key-down: the hardware equivalent of the
 * keyboard's Next action. Key-up and any modifier (Shift, Ctrl, Alt, Meta) fall through so
 * ordinary typing and shortcuts are untouched.
 */
internal fun isTitleSubmitKey(type: KeyEventType, key: Key, modified: Boolean): Boolean =
    type == KeyEventType.KeyDown && !modified && (key == Key.Enter || key == Key.NumPadEnter)
