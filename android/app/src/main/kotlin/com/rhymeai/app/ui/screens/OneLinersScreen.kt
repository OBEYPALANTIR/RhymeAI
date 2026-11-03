package com.rhymeai.app.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import android.text.format.DateUtils
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.data.model.OneLiner
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.repository.OneLinersStore
import com.rhymeai.app.service.MicrophoneOwner
import com.rhymeai.app.service.OneLinerCaptureSession
import com.rhymeai.app.service.OneLinerCaptureSession.Mode as CaptureMode
import com.rhymeai.app.service.OneLinerPlayer
import com.rhymeai.app.service.OneLinerRecorder
import com.rhymeai.app.service.VoiceMemoService
import com.rhymeai.app.ui.navigation.OneLinerAction
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.appWritingSurface
import com.rhymeai.app.ui.theme.recordingAccentColor
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch


/** The One Liners pool: newest first, search, send to a song, trash, and Record / Type capture. */
@Composable
fun OneLinersScreen(viewModel: MainViewModel, onBack: () -> Unit) {
    val colorScheme = MaterialTheme.colorScheme
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }
    val player = remember { OneLinerPlayer() }
    DisposableEffect(player) { onDispose { player.stop() } }
    var query by remember { mutableStateOf("") }
    val focusManager = LocalFocusManager.current
    var searchFocused by remember { mutableStateOf(false) }
    val captures = viewModel.oneLinerCaptures
    var sendingLine by remember { mutableStateOf<OneLiner?>(null) }
    val lines = viewModel.oneLiners
    val filtered = remember(lines, query) { OneLinersStore.filter(lines, query) }
    val titles = remember(viewModel.projects) { viewModel.projects.associate { it.id to it.title.ifEmpty { "Untitled Song" } } }

    fun showMessage(message: String) {
        scope.launch { snackbarHostState.showSnackbar(message, duration = SnackbarDuration.Short) }
    }

    /** A take playing would reach the microphone, so playback stops before any capture opens. */
    fun openCapture(mode: CaptureMode) {
        // Nothing opens on a screen that is already on its way out.
        if (!viewModel.showOneLiners) return
        player.stop()
        viewModel.voiceMemoService.stopPlayback()
        captures.open(mode)
    }

    // A widget, tile or link: an open capture is never replaced, it says so instead.
    LaunchedEffect(viewModel.pendingOneLinerAction) {
        val action = viewModel.pendingOneLinerAction ?: return@LaunchedEffect
        viewModel.pendingOneLinerAction = null
        when (action) {
            OneLinerAction.RECORD -> if (captures.current == null) openCapture(CaptureMode.Record) else captures.open(CaptureMode.Record)
            OneLinerAction.TYPE -> if (captures.current == null) openCapture(CaptureMode.Type) else captures.open(CaptureMode.Type)
            OneLinerAction.OPEN -> Unit
        }
    }

    fun trash(line: OneLiner) {
        line.audioFileName?.let { if (player.playingFile == viewModel.oneLinersStore.audioFile(it)) player.stop() }
        scope.launch {
            val trashed = runCatching { viewModel.trashOneLiner(line.id) }.getOrDefault(false)
            if (!trashed) {
                snackbarHostState.showSnackbar("Couldn't move this line to Trash.", duration = SnackbarDuration.Short)
                return@launch
            }
            val result = snackbarHostState.showSnackbar("Line moved to Trash", actionLabel = "Undo", duration = SnackbarDuration.Short)
            if (result == SnackbarResult.ActionPerformed) runCatching { viewModel.restoreOneLiner(line.id) }
        }
    }

    BackHandler(enabled = captures.current == null && sendingLine == null, onBack = onBack)

    Surface(
        // The capture sheet is in this window now, so the screen under it leaves the accessibility tree itself.
        modifier = Modifier.fillMaxSize().appWritingSurface().testTag("oneLinersScreen")
            .then(if (captures.current != null) Modifier.clearAndSetSemantics {} else Modifier),
        color = Color.Transparent,
        contentColor = colorScheme.onSurface
    ) {
        Box(Modifier.fillMaxSize().statusBarsPadding().imePadding()) {
            Column(Modifier.fillMaxSize().padding(horizontal = DesignTokens.Rhythm.standard)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onBack, modifier = Modifier.size(DesignTokens.Touch.minTarget)) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to songs")
                    }
                    Text("One Liners", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                }
                Text(
                    "${if (lines.size == 1) "1 line" else "${lines.size} lines"}, newest first. Nothing here belongs to a song until you send it.",
                    fontSize = DesignTokens.Typography.caption,
                    color = colorScheme.onSurfaceVariant
                )
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Default.Search, contentDescription = null, modifier = Modifier.size(18.dp)) },
                    trailingIcon = if (query.isNotEmpty()) {
                        {
                            IconButton(onClick = { query = "" }) {
                                Icon(Icons.Default.Close, contentDescription = "Clear search", modifier = Modifier.size(18.dp))
                            }
                        }
                    } else null,
                    placeholder = { Text("Search one liners") },
                    shape = RoundedCornerShape(DesignTokens.Radius.lg),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = DesignTokens.Rhythm.related)
                        .onFocusChanged { searchFocused = it.isFocused }
                )
                if (lines.isNotEmpty()) {
                    Text(
                        "Swipe right to send to a song, left to trash. Used lines stay.",
                        fontSize = DesignTokens.Typography.caption,
                        color = colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = DesignTokens.Spacing.sm)
                    )
                }
                LazyColumn(
                    modifier = Modifier.fillMaxWidth().weight(1f),
                    // Room under the last row for the floating Record and Type actions.
                    contentPadding = PaddingValues(
                        top = DesignTokens.Rhythm.related,
                        bottom = DesignTokens.Rhythm.primary + DesignTokens.Rhythm.section * 2
                    ),
                    verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                ) {
                    when {
                        lines.isEmpty() -> item(key = "empty") {
                            EmptyLines("No one liners yet.", "Tap Record or Type to catch a line before it slips away.")
                        }
                        filtered.isEmpty() -> item(key = "none") { EmptyLines("No one liners match your search.", null) }
                        else -> items(filtered, key = { it.id }) { line ->
                            SwipeableLineRow(
                                line = line,
                                usedTitle = line.usedInProjectId?.let(titles::get),
                                playing = line.audioFileName?.let { player.playingFile == viewModel.oneLinersStore.audioFile(it) } == true,
                                onEdit = { openCapture(CaptureMode.Edit(line)) },
                                onPlay = {
                                    val file = viewModel.oneLinersStore.audioFile(line.audioFileName!!)
                                    if (viewModel.voiceMemoService.isRecording) {
                                        showMessage("Finish recording first")
                                    } else {
                                        if (player.playingFile != file) viewModel.voiceMemoService.stopPlayback()
                                        if (!player.toggle(file)) showMessage("Couldn't play this take.")
                                    }
                                },
                                onSend = {
                                    if (line.text.isBlank()) showMessage("Transcribe or type the words first.") else sendingLine = line
                                },
                                onTrash = { trash(line) }
                            )
                        }
                    }
                }
            }

            Column(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth().navigationBarsPadding(),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                SnackbarHost(snackbarHostState, Modifier.padding(horizontal = DesignTokens.Spacing.lg))
                CaptureButtons(
                    onType = { openCapture(CaptureMode.Type) },
                    onRecord = { openCapture(CaptureMode.Record) },
                    modifier = Modifier.padding(bottom = DesignTokens.Rhythm.standard)
                )
            }
        }
    }

    captures.current?.let { session ->
        OneLinerCaptureSheet(
            session = session,
            // Busy when any other recorder holds the microphone (a song memo, starting or recording).
            microphoneBusy = viewModel.voiceMemoService.isRecording ||
                MicrophoneOwner.current.let { it != null && it !== session.recorder },
            pendingRoot = viewModel.oneLinersStore.pendingRoot,
            onSave = viewModel::saveOneLinerCapture,
            onDismiss = captures::dismiss
        )
    }

    sendingLine?.let { line ->
        SongPickerSheet(
            projects = remember(viewModel.projects) { viewModel.projects.sortedByDescending { it.updatedAt } },
            isOpenInEditor = { !viewModel.showStartMenu && viewModel.currentProjectId == it.id },
            onPick = { project ->
                sendingLine = null
                viewModel.sendOneLinerToSong(line, project) { message ->
                    scope.launch {
                        // The closing picker hands focus back to the search field; a finished send
                        // leaves none. On this screen's scope, so a send finishing after it left does nothing.
                        if (searchFocused) focusManager.clearFocus()
                        snackbarHostState.showSnackbar(message, duration = SnackbarDuration.Short)
                    }
                }
            },
            onDismiss = { sendingLine = null }
        )
    }
}

@Composable
private fun EmptyLines(title: String, caption: String?) {
    Column(Modifier.fillMaxWidth().padding(vertical = DesignTokens.Rhythm.section), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, fontWeight = FontWeight.Medium)
        caption?.let { Text(it, fontSize = DesignTokens.Typography.caption, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeableLineRow(
    line: OneLiner,
    usedTitle: String?,
    playing: Boolean,
    onEdit: () -> Unit,
    onPlay: () -> Unit,
    onSend: () -> Unit,
    onTrash: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    // Both swipes act and spring back: a trashed row leaves when the pool changes.
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { value ->
        when (value) {
            SwipeToDismissBoxValue.StartToEnd -> onSend()
            SwipeToDismissBoxValue.EndToStart -> onTrash()
            SwipeToDismissBoxValue.Settled -> Unit
        }
        false
    })
    SwipeToDismissBox(
        state = state,
        backgroundContent = {
            val toSong = state.dismissDirection == SwipeToDismissBoxValue.StartToEnd
            val toTrash = state.dismissDirection == SwipeToDismissBoxValue.EndToStart
            Row(
                Modifier.fillMaxSize().background(
                    when {
                        toSong -> colorScheme.primary
                        toTrash -> colorScheme.error
                        else -> Color.Transparent
                    },
                    RoundedCornerShape(DesignTokens.Radius.lg)
                ).padding(horizontal = DesignTokens.Rhythm.standard),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = if (toTrash) Arrangement.End else Arrangement.Start
            ) {
                if (toSong) Text("Send to song", color = colorScheme.onPrimary, fontWeight = FontWeight.Medium)
                if (toTrash) Icon(Icons.Default.Delete, contentDescription = null, tint = colorScheme.onError)
            }
        }
    ) {
        LineRow(line, usedTitle, playing, onEdit, onPlay, onSend, onTrash)
    }
}

@Composable
private fun LineRow(
    line: OneLiner,
    usedTitle: String?,
    playing: Boolean,
    onEdit: () -> Unit,
    onPlay: () -> Unit,
    onSend: () -> Unit,
    onTrash: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val voiceOnly = line.text.isEmpty()
    Surface(
        shape = RoundedCornerShape(DesignTokens.Radius.lg),
        color = colorScheme.surfaceContainerLow,
        border = BorderStroke(1.dp, colorScheme.outlineVariant)
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = DesignTokens.Rhythm.related, vertical = DesignTokens.Spacing.sm),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(
                Modifier.weight(1f)
                    .clickable(onClickLabel = "Edit the words", onClick = onEdit)
                    .semantics {
                        customActions = listOf(
                            androidx.compose.ui.semantics.CustomAccessibilityAction("Send to song") { onSend(); true },
                            androidx.compose.ui.semantics.CustomAccessibilityAction("Move to Trash") { onTrash(); true }
                        )
                    },
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
            ) {
                Text(
                    if (voiceOnly) "Voice line" else line.text,
                    style = MaterialTheme.typography.bodyLarge,
                    fontStyle = if (voiceOnly) FontStyle.Italic else FontStyle.Normal,
                    color = if (line.usedInProjectId == null && !voiceOnly) colorScheme.onSurface else colorScheme.onSurfaceVariant
                )
                if (voiceOnly) {
                    Text("Transcribe or type the words first. Tap to add them.", fontSize = DesignTokens.Typography.caption, color = colorScheme.onSurfaceVariant)
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                    val meta = MaterialTheme.typography.labelMedium
                    Text(relativeDateText(line.createdAt), style = meta, color = colorScheme.onSurfaceVariant)
                    if (line.audioFileName != null) {
                        Icon(Icons.Default.Mic, contentDescription = null, tint = colorScheme.onSurfaceVariant, modifier = Modifier.size(14.dp))
                        Text(VoiceMemoService.formatDuration(line.audioDurationMs), style = meta, color = colorScheme.onSurfaceVariant)
                    }
                    if (usedTitle != null) {
                        Text(
                            "In $usedTitle",
                            style = meta,
                            color = colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false)
                                .background(colorScheme.surfaceContainerHigh, CircleShape)
                                .padding(horizontal = DesignTokens.Spacing.sm, vertical = 1.dp)
                        )
                    }
                    Spacer(Modifier.weight(1f))
                    if (!voiceOnly) Text(line.prosodyBadge, style = meta, color = colorScheme.onSurfaceVariant, maxLines = 1)
                }
            }
            if (line.audioFileName != null) {
                IconButton(
                    onClick = onPlay,
                    modifier = Modifier.size(DesignTokens.Touch.minTarget).border(1.dp, colorScheme.outline, CircleShape)
                ) {
                    Icon(
                        if (playing) Icons.Default.Stop else Icons.Default.PlayArrow,
                        contentDescription = if (playing) "Stop take" else "Play take",
                        tint = if (playing) recordingAccentColor(MaterialTheme.colorScheme.isDarkScheme()) else colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun CaptureButtons(onType: () -> Unit, onRecord: () -> Unit, modifier: Modifier = Modifier) {
    val colorScheme = MaterialTheme.colorScheme
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.related)) {
        Surface(
            onClick = onType,
            shape = CircleShape,
            color = colorScheme.surface,
            border = BorderStroke(1.dp, colorScheme.outline),
            modifier = Modifier.size(DesignTokens.Rhythm.primary).semantics { contentDescription = "Type a one liner" }
        ) {
            Box(contentAlignment = Alignment.Center) { Icon(Icons.Default.Keyboard, contentDescription = null) }
        }
        Surface(
            onClick = onRecord,
            shape = RoundedCornerShape(DesignTokens.Radius.pill),
            color = recordingAccentColor(colorScheme.isDarkScheme()),
            contentColor = colorScheme.background,
            modifier = Modifier.heightIn(min = DesignTokens.Rhythm.primary).semantics { contentDescription = "Record a one liner" }
        ) {
            Row(
                Modifier.padding(horizontal = DesignTokens.Rhythm.section),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
            ) {
                Icon(Icons.Default.Mic, contentDescription = null)
                Text("Record", fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun OneLinerCaptureSheet(
    session: OneLinerCaptureSession,
    microphoneBusy: Boolean,
    pendingRoot: File,
    onSave: () -> Unit,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val colorScheme = MaterialTheme.colorScheme
    val scope = rememberCoroutineScope()
    val mode = session.mode
    val recorder = session.recorder
    val focusRequester = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    var fieldFocused by remember { mutableStateOf(false) }
    val keyboard = LocalSoftwareKeyboardController.current
    val windowInfo = LocalWindowInfo.current
    val imeVisible = rememberUpdatedState(WindowInsets.isImeVisible)
    // Words, take and errors live in the session (the ViewModel's), so a recreated activity keeps them.
    var text by session::text
    var saveError by session::saveError
    val saving = session.saving
    val isEdit = mode is CaptureMode.Edit
    val canRecord = !isEdit && !microphoneBusy
    val canSave = !saving && (text.isNotBlank() || (!isEdit && (recorder.takeFile != null || recorder.isRecording)))

    fun startTake() {
        if (recorder.start(File(pendingRoot, "${java.util.UUID.randomUUID()}.wav"), context.applicationContext)) session.takeStarted()
        else focusRequester.requestFocus()
    }

    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startTake() else {
            recorder.notice = "Microphone access is off. Type the line instead, or allow it in Settings."
            focusRequester.requestFocus()
        }
    }

    fun requestTake() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) startTake()
        else permission.launch(Manifest.permission.RECORD_AUDIO)
    }

    // The save runs in the ViewModel (see OneLinerCaptures.save): the sheet only shows its state.
    fun save() = onSave()

    // Keyed by the take too, so a new take's first words land even when they match the last take's.
    LaunchedEffect(recorder.startedAt, recorder.transcript) { session.applyTranscript(recorder.transcript) }
    LaunchedEffect(session) {
        // Once per capture: a sheet recreated with the activity keeps its take and does not reopen the mic.
        if (session.opened) return@LaunchedEffect
        session.opened = true
        when {
            mode is CaptureMode.Record && !microphoneBusy && recorder.takeFile == null -> requestTake()
            else -> {
                if (mode is CaptureMode.Record && microphoneBusy) recorder.notice = OneLinerRecorder.MEMO_RECORDING_NOTICE
                // Type opens ready to write, even on a cold start from the widget: the IME only
                // attaches to a focused window, and a show() during the sheet's entrance can be dropped.
                snapshotFlow { windowInfo.isWindowFocused }.first { it }
                focusRequester.requestFocus()
                repeat(3) {
                    if (imeVisible.value) return@LaunchedEffect
                    keyboard?.show()
                    delay(100)
                }
            }
        }
    }
    // Leaving the app ends the take where it is, so the microphone never runs on in the background.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP && recorder.isRecording && recorder.stop()) {
                recorder.notice = "Recording stopped when Writers Block went to the background. The take so far is kept."
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        // Only an explicit close discards the take (see OneLinerCaptures), never a disposal.
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // Drawn in the activity window, not ModalBottomSheet's dialog window: there the IME inset
    // jumps after the keyboard settles, here adjustResize + edge-to-edge move it with the keyboard frame by frame.
    BackHandler(onBack = onDismiss)
    val sheetMillis = if (LocalAnimationsEnabled.current) DesignTokens.Motion.sheetPresentMillis else 0
    val presented = remember { MutableTransitionState(false).apply { targetState = true } }
    AnimatedVisibility(visibleState = presented, enter = EnterTransition.None, exit = ExitTransition.None) {
        Box(Modifier.fillMaxSize()) {
            Box(
                Modifier.fillMaxSize()
                    .animateEnterExit(enter = fadeIn(tween(sheetMillis)))
                    .background(BottomSheetDefaults.ScrimColor)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        onClickLabel = "Close",
                        onClick = onDismiss
                    )
                    .semantics { contentDescription = "Close one liner sheet" }
            )
            Surface(
                modifier = Modifier.align(Alignment.BottomCenter).statusBarsPadding()
                    .animateEnterExit(enter = slideInVertically(tween(sheetMillis, easing = DesignTokens.Motion.emphasizedEasing)) { it })
                    .widthIn(max = BottomSheetDefaults.SheetMaxWidth).fillMaxWidth()
                    .semantics { paneTitle = if (isEdit) "Edit one liner" else "New one liner" },
                shape = BottomSheetDefaults.ExpandedShape,
                color = BottomSheetDefaults.ContainerColor
            ) {
                Column(
                    Modifier.fillMaxWidth()
                        .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom))
                        .padding(top = DesignTokens.Rhythm.standard)
                        .padding(horizontal = DesignTokens.Rhythm.standard)
                        .padding(bottom = DesignTokens.Rhythm.related)
                        .testTag("oneLinerCaptureSheet"),
                    verticalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.related)
                ) {
                    Row(verticalAlignment = Alignment.Top) {
                        Column(Modifier.weight(1f)) {
                            Text(if (isEdit) "Edit one liner" else "New one liner", fontWeight = FontWeight.SemiBold, fontSize = DesignTokens.Typography.caption, color = colorScheme.onSurfaceVariant)
                            Text(
                                if (isEdit) "Change the words. A recorded take stays as it was." else "Lands in One Liners. Pick a song later, or never.",
                                fontSize = DesignTokens.Typography.caption,
                                color = colorScheme.onSurfaceVariant
                            )
                        }
                        // The sheet has no drag handle, so closing is a visible 48 dp control too.
                        IconButton(onClick = onDismiss, modifier = Modifier.size(DesignTokens.Touch.minTarget)) {
                            Icon(Icons.Default.Close, contentDescription = "Close")
                        }
                    }
                    TextField(
                        value = text,
                        onValueChange = { text = it; saveError = null },
                        placeholder = { Text("Say it or type it") },
                        textStyle = MaterialTheme.typography.headlineSmall,
                        minLines = 2,
                        maxLines = 6,
                        colors = TextFieldDefaults.colors(
                            focusedContainerColor = Color.Transparent,
                            unfocusedContainerColor = Color.Transparent,
                            focusedIndicatorColor = colorScheme.outline,
                            unfocusedIndicatorColor = colorScheme.outlineVariant
                        ),
                        modifier = Modifier.fillMaxWidth().focusRequester(focusRequester)
                            .onFocusChanged { fieldFocused = it.isFocused }
                            .testTag("oneLinerField")
                    )
                    if (recorder.isRecording) RecordingRow(recorder)
                    if (showsStoppedTake(isEdit, recorder.isRecording, recorder.takeFile != null)) {
                        TakeRow(recorder.takeDurationMs, enabled = !saving, onDiscard = session::discardTake)
                    }
                    (saveError ?: recorder.notice)?.let { notice ->
                        Text(
                            notice,
                            fontSize = DesignTokens.Typography.caption,
                            color = if (saveError != null) colorScheme.error else colorScheme.onSurfaceVariant
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.related)) {
                        RoundButton(if (fieldFocused) "Hide keyboard" else "Switch to keyboard", onClick = {
                            if (fieldFocused) focusManager.clearFocus() else focusRequester.requestFocus()
                        }) { Icon(Icons.Default.Keyboard, contentDescription = null) }
                        val accent = recordingAccentColor(colorScheme.isDarkScheme())
                        if (recorder.isRecording) {
                            RoundButton("Stop recording", border = accent, onClick = { recorder.stop() }) {
                                Box(Modifier.size(18.dp).background(accent, RoundedCornerShape(4.dp)))
                            }
                        } else if (recorder.takeFile == null && canRecord) {
                            RoundButton("Record", onClick = ::requestTake) { Icon(Icons.Default.Mic, contentDescription = null) }
                        }
                        Spacer(Modifier.weight(1f))
                        Surface(
                            onClick = ::save,
                            enabled = canSave,
                            shape = RoundedCornerShape(DesignTokens.Radius.pill),
                            color = colorScheme.primary.copy(alpha = if (canSave) 1f else 0.4f),
                            contentColor = colorScheme.onPrimary,
                            modifier = Modifier.heightIn(min = DesignTokens.Touch.minTarget)
                        ) {
                            Box(Modifier.padding(horizontal = DesignTokens.Rhythm.section, vertical = DesignTokens.Rhythm.related), contentAlignment = Alignment.Center) {
                                Text("Save", fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RoundButton(label: String, onClick: () -> Unit, border: Color = MaterialTheme.colorScheme.outline, content: @Composable () -> Unit) {
    Surface(
        onClick = onClick,
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, border),
        modifier = Modifier.size(DesignTokens.Touch.minTarget).semantics { contentDescription = label }
    ) {
        Box(contentAlignment = Alignment.Center) { content() }
    }
}

@Composable
private fun RecordingRow(recorder: OneLinerRecorder) {
    val colorScheme = MaterialTheme.colorScheme
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(recorder.startedAt) {
        while (true) { now = System.currentTimeMillis(); delay(1_000) }
    }
    val elapsed = now - (recorder.startedAt ?: now)
    Row(
        Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = "Recording, listening" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.related)
    ) {
        Box(Modifier.size(8.dp).background(recordingAccentColor(colorScheme.isDarkScheme()), CircleShape))
        Text(VoiceMemoService.formatDuration(elapsed), style = MaterialTheme.typography.labelMedium, color = colorScheme.onSurfaceVariant)
        Row(Modifier.weight(1f).height(34.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            recorder.levels.forEach { level ->
                Box(Modifier.width(3.dp).height((level * 34).coerceAtLeast(5f).dp).background(colorScheme.outline, CircleShape))
            }
        }
        Text("Listening", fontSize = DesignTokens.Typography.caption, color = colorScheme.onSurfaceVariant)
    }
}

/** A new capture's stopped take: its length and a way to drop it. Edit keeps its take as it was. */
internal fun showsStoppedTake(isEdit: Boolean, isRecording: Boolean, hasTake: Boolean): Boolean =
    !isEdit && !isRecording && hasTake

@Composable
private fun TakeRow(durationMs: Long, enabled: Boolean, onDiscard: () -> Unit) {
    val colorScheme = MaterialTheme.colorScheme
    val duration = VoiceMemoService.formatDuration(durationMs)
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.related)
    ) {
        Row(
            Modifier.weight(1f).clearAndSetSemantics { contentDescription = "Take recorded, $duration" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.related)
        ) {
            Icon(Icons.Default.GraphicEq, contentDescription = null, tint = colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
            Text(duration, style = MaterialTheme.typography.labelMedium, color = colorScheme.onSurfaceVariant)
            Text("Take", fontSize = DesignTokens.Typography.caption, color = colorScheme.onSurfaceVariant)
        }
        TextButton(onClick = onDiscard, enabled = enabled, modifier = Modifier.heightIn(min = DesignTokens.Touch.minTarget)) {
            Text("Discard take")
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SongPickerSheet(
    projects: List<SongProject>,
    isOpenInEditor: (SongProject) -> Boolean,
    onPick: (SongProject) -> Unit,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    ModalBottomSheet(onDismissRequest = onDismiss, modifier = Modifier.statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = DesignTokens.Rhythm.standard), verticalAlignment = Alignment.CenterVertically) {
            Text("Send to song", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            TextButton(onClick = onDismiss) { Text("Cancel") }
        }
        LazyColumn(Modifier.fillMaxWidth(), contentPadding = PaddingValues(horizontal = DesignTokens.Rhythm.standard, vertical = DesignTokens.Spacing.sm)) {
            if (projects.isEmpty()) item {
                Text("No songs yet. Create one from the songs drawer first.", color = colorScheme.onSurfaceVariant)
            }
            items(projects, key = { it.id }) { project ->
                Column(
                    Modifier.fillMaxWidth().heightIn(min = DesignTokens.Touch.minTarget)
                        .clickable { onPick(project) }
                        .padding(vertical = DesignTokens.Spacing.sm)
                ) {
                    Text(project.title.ifEmpty { "Untitled Song" }, style = MaterialTheme.typography.titleMedium)
                    Text(
                        if (isOpenInEditor(project)) "Open now · goes in at the cursor" else "Goes in as the last line",
                        fontSize = DesignTokens.Typography.caption,
                        color = colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

/** "Just now", "5 min. ago", "Yesterday", "Oct 14". */
private fun relativeDateText(createdAt: Long, now: Long = System.currentTimeMillis()): String =
    if (now - createdAt < DateUtils.MINUTE_IN_MILLIS) "Just now"
    else DateUtils.getRelativeTimeSpanString(createdAt, now, DateUtils.MINUTE_IN_MILLIS, DateUtils.FORMAT_ABBREV_RELATIVE).toString()

private fun androidx.compose.material3.ColorScheme.isDarkScheme(): Boolean = background.luminance() < 0.5f
