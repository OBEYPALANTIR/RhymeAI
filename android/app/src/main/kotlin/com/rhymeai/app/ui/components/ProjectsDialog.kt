package com.rhymeai.app.ui.components

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedIconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.R
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.service.VoiceMemo
import com.rhymeai.app.service.VoiceMemoService
import com.rhymeai.app.util.SyllableCounter
import com.rhymeai.app.service.TrashedVoiceMemo
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.motion.OffsetMotionState
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.appWritingSurface
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

private val DrawerAnimationMillis: Int get() = DesignTokens.Motion.drawerPresentMillis
private val DrawerDismissMillis: Int get() = DesignTokens.Motion.dismissMillis
private val DialogBottomActionMinClearance = 120.dp
private const val MillisPerDay = 24L * 60L * 60L * 1000L

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectsDrawer(
    projects: List<SongProject>,
    trashedProjects: List<TrashedSongProject>,
    currentProjectId: String?,
    onLoadProject: (SongProject) -> Unit,
    onNewProject: () -> Unit,
    onDeleteProject: (String, (Boolean) -> Unit) -> Unit,
    onRestoreProject: (String) -> Unit,
    onPermanentlyDeleteProject: (String) -> Unit,
    onPurgeExpiredTrash: () -> Unit,
    onRecordingPurgeIncomplete: () -> Unit,
    onImportProject: (SongProject) -> Unit,
    onDismiss: () -> Unit,
    service: VoiceMemoService? = null
) {
    val colorScheme = MaterialTheme.colorScheme
    val configuration = LocalConfiguration.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val importJson = remember { Json { ignoreUnknownKeys = true } }
    var importError by remember { mutableStateOf<String?>(null) }
    var searchQuery by remember { mutableStateOf("") }
    val drawerTransition = remember { MutableTransitionState(false).apply { targetState = true } }
    val animationsEnabled = LocalAnimationsEnabled.current
    var isClosing by remember { mutableStateOf(false) }
    var showTrashBin by remember { mutableStateOf(false) }
    val trashTransition = remember { MutableTransitionState(false) }
    var isTrashBinClosing by remember { mutableStateOf(false) }
    val snackbarHostState = remember { SnackbarHostState() }

    fun openTrashBin() {
        isTrashBinClosing = false
        showTrashBin = true
        trashTransition.targetState = true
    }

    fun closeTrashBin() {
        if (!showTrashBin || isTrashBinClosing) return
        isTrashBinClosing = true
        trashTransition.targetState = false
    }

    LaunchedEffect(trashTransition.isIdle, trashTransition.currentState, isTrashBinClosing) {
        if (isTrashBinClosing && trashTransition.isIdle && !trashTransition.currentState) {
            showTrashBin = false
            isTrashBinClosing = false
        }
    }

    BackHandler(enabled = showTrashBin) {
        closeTrashBin()
    }

    fun closeDrawer(onSelection: (() -> Unit)? = null) {
        if (isClosing) return
        isClosing = true
        if (onSelection != null) {
            onSelection()
            onDismiss()
        } else {
            drawerTransition.targetState = false
        }
    }

    BackHandler(enabled = !showTrashBin) {
        closeDrawer()
    }

    LaunchedEffect(drawerTransition.isIdle, drawerTransition.currentState, isClosing) {
        if (isClosing && drawerTransition.isIdle && !drawerTransition.currentState) {
            onDismiss()
        }
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            try {
                val text = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use(::readProjectText)
                        ?: throw Exception("Cannot read file")
                }
                val project = importJson.decodeFromString(SongProject.serializer(), text)
                importError = null
                closeDrawer { onImportProject(project) }
            } catch (e: Exception) {
                importError = e.message?.takeIf { it.startsWith("Project files must be") }
                    ?: "Could not import this file. Pick a RhymeAI project JSON."
            }
        }
    }

    val sortedProjects = remember(projects) { projects.sortedByDescending { it.updatedAt } }
    val filteredProjects = remember(sortedProjects, searchQuery) { searchProjects(sortedProjects, searchQuery) }
    val isSearching = searchQuery.isNotBlank()
    val textFieldColors = OutlinedTextFieldDefaults.colors(
        unfocusedBorderColor = colorScheme.outlineVariant,
        focusedBorderColor = colorScheme.primary,
        unfocusedContainerColor = colorScheme.surfaceContainerLow,
        focusedContainerColor = colorScheme.surfaceContainerLow,
        cursorColor = colorScheme.primary,
        unfocusedTextColor = colorScheme.onSurface,
        focusedTextColor = colorScheme.onSurface,
        unfocusedPlaceholderColor = colorScheme.onSurfaceVariant,
        focusedPlaceholderColor = colorScheme.onSurfaceVariant,
        unfocusedLeadingIconColor = colorScheme.onSurfaceVariant,
        focusedLeadingIconColor = colorScheme.primary
    )

    // Push-style reveal: while the trash screen slides in from the right, the
    // drawer slides toward the left like a navigation push, so the trash reads
    // as the next screen rather than an overlay.
    val density = LocalDensity.current
    val screenWidthPx = with(density) { configuration.screenWidthDp.dp.toPx() }
    val trashRevealProgress by animateFloatAsState(
        targetValue = if (trashTransition.targetState) 1f else 0f,
        animationSpec = if (!animationsEnabled) {
            snap()
        } else if (trashTransition.targetState) {
            tween(DrawerAnimationMillis, easing = DesignTokens.Motion.standardEasing)
        } else {
            tween(DrawerDismissMillis, easing = DesignTokens.Motion.exitEasing)
        },
        label = "trashRevealProgress"
    )

    Box(modifier = Modifier.fillMaxSize()) {
            AnimatedVisibility(
                visibleState = drawerTransition,
                enter = if (animationsEnabled) {
                    slideInHorizontally(
                        animationSpec = tween(
                            DrawerAnimationMillis,
                            easing = DesignTokens.Motion.standardEasing
                        ),
                        initialOffsetX = { -it }
                    )
                } else {
                    EnterTransition.None
                },
                exit = if (animationsEnabled) {
                    slideOutHorizontally(
                        animationSpec = tween(
                            DrawerDismissMillis,
                            easing = DesignTokens.Motion.exitEasing
                        ),
                        targetOffsetX = { -it }
                    )
                } else {
                    ExitTransition.None
                }
            ) {
                Surface(
                    modifier = Modifier
                        .graphicsLayer { translationX = -screenWidthPx * 0.3f * trashRevealProgress }
                        .fillMaxSize()
                        .appWritingSurface()
                        .imePadding()
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = {}
                    ),
                    shape = RoundedCornerShape(0.dp),
                    color = Color.Transparent,
                    contentColor = colorScheme.onSurface,
                    tonalElevation = 0.dp
                ) {
                    val bottomActionClearance = maxOf(
                        navigationBarBottomPadding(),
                        DialogBottomActionMinClearance
                    )
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .statusBarsPadding()
                            // Full-page drawer: editor-tier side padding (20dp) so the
                            // full-bleed lists keep comfortable margins.
                            .padding(horizontal = DesignTokens.Spacing.xl)
                            .padding(top = DesignTokens.Spacing.lg)
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(
                                    bottom = bottomActionClearance +
                                        DesignTokens.Touch.minTarget +
                                        DesignTokens.Spacing.lg
                                )
                        ) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = "Song Library",
                                    style = MaterialTheme.typography.headlineSmall,
                                    fontWeight = FontWeight.SemiBold,
                                    color = colorScheme.onSurface,
                                    modifier = Modifier.weight(1f)
                                )

                                IconButton(
                                    onClick = { closeDrawer() },
                                    modifier = Modifier.size(DesignTokens.Touch.minTarget)
                                ) {
                                    Icon(
                                        Icons.Default.Close,
                                        contentDescription = "Close drawer",
                                        tint = colorScheme.onSurfaceVariant,
                                        modifier = Modifier.size(18.dp)
                                    )
                                }
                            }

                            OutlinedTextField(
                                value = searchQuery,
                                onValueChange = { searchQuery = it },
                                singleLine = true,
                                leadingIcon = {
                                    Icon(
                                        Icons.Default.Search,
                                        contentDescription = null,
                                        modifier = Modifier.size(18.dp)
                                    )
                                },
                                trailingIcon = if (searchQuery.isNotEmpty()) {
                                    {
                                        IconButton(onClick = { searchQuery = "" }) {
                                            Icon(
                                                Icons.Default.Close,
                                                contentDescription = "Clear search",
                                                tint = colorScheme.onSurfaceVariant,
                                                modifier = Modifier.size(18.dp)
                                            )
                                        }
                                    }
                                } else {
                                    null
                                },
                                placeholder = {
                                    Text(
                                        text = "Search songs",
                                        fontSize = 14.sp
                                    )
                                },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(top = DesignTokens.Spacing.sm),
                                colors = textFieldColors,
                                shape = RoundedCornerShape(DesignTokens.Radius.lg)
                            )

                            Button(
                                onClick = { closeDrawer(onSelection = onNewProject) },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(top = DesignTokens.Spacing.md)
                                    .heightIn(min = DesignTokens.Rhythm.primary),
                                shape = RoundedCornerShape(DesignTokens.Radius.lg)
                            ) {
                                Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(DesignTokens.Spacing.sm))
                                Text("Create New Song", fontWeight = FontWeight.Medium)
                            }

                            Spacer(Modifier.height(DesignTokens.Spacing.md))
                            LazyColumn(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .weight(1f),
                                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
                            ) {
                                if (projects.isEmpty()) {
                                    item {
                                        EmptyDrawerState(
                                            icon = { Icon(Icons.Default.MusicNote, contentDescription = null) },
                                            text = "No saved songs yet."
                                        )
                                    }
                                } else if (filteredProjects.isEmpty()) {
                                    item {
                                        EmptyDrawerState(
                                            icon = { Icon(Icons.Default.Search, contentDescription = null) },
                                            text = if (isSearching) "No songs match your search." else "No saved songs yet."
                                        )
                                    }
                                } else {
                                    items(filteredProjects, key = { it.id }) { project ->
                                        ProjectDrawerRow(
                                            project = project,
                                            isActive = project.id == currentProjectId,
                                            onLoadProject = { selected ->
                                                closeDrawer { onLoadProject(selected) }
                                            },
                                            onDeleteProject = { project ->
                                                onDeleteProject(project.id) { committed ->
                                                    if (committed) scope.launch {
                                                        val result = snackbarHostState.showSnackbar(
                                                            message = "\"${project.title.ifEmpty { "Untitled Song" }}\" moved to Trash",
                                                            actionLabel = "Undo",
                                                            duration = SnackbarDuration.Short
                                                        )
                                                        if (result == SnackbarResult.ActionPerformed) {
                                                            onRestoreProject(project.id)
                                                        }
                                                    }
                                                }
                                            }
                                        )
                                    }
                                }
                            }

                            importError?.let {
                                Text(
                                    it,
                                    color = colorScheme.error,
                                    fontSize = 12.sp,
                                    modifier = Modifier.padding(top = DesignTokens.Spacing.sm)
                                )
                            }
                        }

                        Column(
                            modifier = Modifier
                                .fillMaxSize()
                                .align(Alignment.BottomCenter),
                            verticalArrangement = Arrangement.Bottom
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(DesignTokens.Touch.minTarget),
                                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                TextButton(
                                    onClick = {
                                        importError = null
                                        importLauncher.launch(arrayOf("application/json", "*/*"))
                                    },
                                    modifier = Modifier
                                        .weight(1f)
                                        .fillMaxHeight(),
                                ) {
                                    Icon(Icons.Default.FileOpen, contentDescription = null, modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.width(DesignTokens.Spacing.sm))
                                    Text("Import Files", fontWeight = FontWeight.Medium)
                                }

                                IconButton(
                                    onClick = {
                                        onPurgeExpiredTrash()
                                        openTrashBin()
                                    },
                                    modifier = Modifier
                                        .fillMaxHeight()
                                        .width(DesignTokens.Touch.minTarget)
                                        .semantics { contentDescription = "Open Trash Bin" },
                                ) {
                                    Icon(
                                        Icons.Default.Delete,
                                        contentDescription = null,
                                        modifier = Modifier.size(18.dp)
                                    )
                                }
                            }
                            Spacer(Modifier.height(bottomActionClearance))
                        }
                    }
                }
            }

            // No showTrashBin gate here: composing AnimatedVisibility in the
            // same frame its target flips true skips the enter transition
            // entirely (the page used to just appear). Kept in composition,
            // the slide-in runs; content is only materialized while visible.
            AnimatedVisibility(
                visibleState = trashTransition,
                enter = slideInHorizontally(
                    animationSpec = tween(if (animationsEnabled) DrawerAnimationMillis else 0, easing = DesignTokens.Motion.standardEasing),
                    initialOffsetX = { it }
                ),
                exit = slideOutHorizontally(
                    animationSpec = tween(if (animationsEnabled) DrawerDismissMillis else 0, easing = DesignTokens.Motion.exitEasing),
                    targetOffsetX = { it }
                )
            ) {
                TrashBinPage(
                    trashedProjects = trashedProjects,
                    onRestoreProject = onRestoreProject,
                    onPermanentlyDeleteProject = onPermanentlyDeleteProject,
                    onRecordingPurgeIncomplete = onRecordingPurgeIncomplete,
                    onDismiss = ::closeTrashBin,
                    service = service,
                    projects = projects
                )
            }

            SnackbarHost(
                hostState = snackbarHostState,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(
                        bottom = maxOf(
                            navigationBarBottomPadding(),
                            DialogBottomActionMinClearance
                        ) + DesignTokens.Touch.minTarget + DesignTokens.Spacing.lg
                    )
                    .padding(DesignTokens.Spacing.lg)
            )
    }

}

@Composable
fun ProjectsDialog(
    projects: List<SongProject>,
    trashedProjects: List<TrashedSongProject> = emptyList(),
    currentProjectId: String?,
    onLoadProject: (SongProject) -> Unit,
    onNewProject: () -> Unit,
    onDeleteProject: (String, (Boolean) -> Unit) -> Unit,
    onRestoreProject: (String) -> Unit,
    onPermanentlyDeleteProject: (String) -> Unit,
    onPurgeExpiredTrash: () -> Unit,
    onRecordingPurgeIncomplete: () -> Unit,
    onImportProject: (SongProject) -> Unit,
    onDismiss: () -> Unit
) {
    ProjectsDrawer(
        projects = projects,
        trashedProjects = trashedProjects,
        currentProjectId = currentProjectId,
        onLoadProject = onLoadProject,
        onNewProject = onNewProject,
        onDeleteProject = onDeleteProject,
        onRestoreProject = onRestoreProject,
        onPermanentlyDeleteProject = onPermanentlyDeleteProject,
        onPurgeExpiredTrash = onPurgeExpiredTrash,
        onImportProject = onImportProject,
        onRecordingPurgeIncomplete = onRecordingPurgeIncomplete,
        onDismiss = onDismiss
    )
}

@Composable
private fun SwipeToRevealDelete(
    onDelete: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val colorScheme = MaterialTheme.colorScheme
    val rowShape = RoundedCornerShape(DesignTokens.Radius.lg)
    val density = LocalDensity.current
    val revealWidth = 64.dp
    val revealPx = with(density) { revealWidth.toPx() }
    val revealPxInt = revealPx.roundToInt()
    val scope = rememberCoroutineScope()
    val offsetX = remember(scope) { OffsetMotionState(scope) }
    val animationsEnabled = LocalAnimationsEnabled.current

    fun settleOffset(target: Float) {
        offsetX.animateTo(target, DesignTokens.Motion.settleSpring(visibilityThreshold = 0.5f), animationsEnabled)
    }
    // Only compose the red reveal layer when the rendered row offset is visibly open.
    // At rest the stationary container and moving foreground both paint the row surface,
    // so anti-aliased rounded edges cannot blend with red and leave a halo.
    val displayOffsetPx by remember(revealPxInt) {
        derivedStateOf { offsetX.value.roundToInt().coerceIn(-revealPxInt, 0) }
    }
    val revealVisible by remember { derivedStateOf { displayOffsetPx < 0 } }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(rowShape)
            .background(colorScheme.surfaceContainerLow)
    ) {
        if (revealVisible) {
            Box(
                modifier = Modifier
                    .matchParentSize()
                    .background(colorScheme.errorContainer),
                contentAlignment = Alignment.CenterEnd
            ) {
                IconButton(
                    onClick = {
                        settleOffset(0f)
                        onDelete()
                    },
                    modifier = Modifier.width(revealWidth)
                ) {
                    Icon(
                        Icons.Default.Delete,
                        contentDescription = "Delete recording",
                        tint = colorScheme.onErrorContainer,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .offset { IntOffset(displayOffsetPx, 0) }
                .background(colorScheme.surfaceContainerLow)
                .pointerInput(revealPx, animationsEnabled) {
                    detectHorizontalDragGestures(
                        onDragStart = { offsetX.snapTo(offsetX.value) },
                        onHorizontalDrag = { change, dragAmount ->
                            change.consume()
                            offsetX.snapTo((offsetX.value + dragAmount).coerceIn(-revealPx, 0f))
                        },
                        onDragEnd = {
                            val target = if (offsetX.value < -revealPx / 2f) -revealPx else 0f
                            settleOffset(target)
                        },
                        onDragCancel = {
                            val target = if (offsetX.value < -revealPx / 2f) -revealPx else 0f
                            settleOffset(target)
                        }
                    )
                }
        ) {
            content()
        }
    }
}

@Composable
internal fun RecordingMemoRow(
    memo: VoiceMemo,
    service: VoiceMemoService,
    isSelecting: Boolean,
    isSelected: Boolean,
    snackbarHostState: SnackbarHostState,
    onSelectionChanged: (Boolean) -> Unit,
    onTrashRequest: (VoiceMemo) -> Unit,
    onMemoListChanged: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val isPlaying = service.playingFile == memo.file
    var pendingRename by remember { mutableStateOf(false) }
    var renameText by remember(memo.file.absolutePath) {
        mutableStateOf(VoiceMemoService.displayName(memo.file))
    }

    if (pendingRename) {
        AlertDialog(
            onDismissRequest = { pendingRename = false },
            title = { Text("Rename recording") },
            text = {
                OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it },
                    label = { Text("Name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        val renamed = service.renameMemo(memo, renameText)
                        pendingRename = false
                        if (renamed != null) {
                            onMemoListChanged()
                        } else {
                            snackbarHostState.showSnackbar(context.getString(R.string.voice_memo_rename_failed))
                        }
                    }
                }) { Text("OK") }
            },
            dismissButton = {
                TextButton(onClick = { pendingRename = false }) { Text("Cancel") }
            }
        )
    }

    SwipeToRevealDelete(onDelete = { onTrashRequest(memo) }) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .then(if (isSelecting) Modifier.clickable { onSelectionChanged(!isSelected) } else Modifier),
            color = colorScheme.surfaceContainerLow,
            contentColor = colorScheme.onSurface
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                if (isSelecting) {
                    Checkbox(
                        checked = isSelected,
                        onCheckedChange = onSelectionChanged
                    )
                }
                IconButton(
                    onClick = {
                        if (isPlaying) service.stopPlayback() else service.play(memo)
                    },
                    modifier = Modifier.size(DesignTokens.Touch.minTarget)
                ) {
                    Icon(
                        if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                        contentDescription = if (isPlaying) "Pause" else "Play",
                        tint = colorScheme.primary
                    )
                }

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = VoiceMemoService.displayName(memo.file),
                        fontSize = DesignTokens.Typography.caption,
                        fontWeight = FontWeight.Medium,
                        color = colorScheme.onSurface
                    )
                    Text(
                        text = VoiceMemoService.formatDuration(memo.durationMs),
                        fontSize = 12.sp,
                        color = colorScheme.onSurfaceVariant
                    )
                }

                IconButton(
                    onClick = {
                        renameText = VoiceMemoService.displayName(memo.file)
                        pendingRename = true
                    },
                    modifier = Modifier.size(DesignTokens.Touch.minTarget)
                ) {
                    Icon(
                        Icons.Default.Edit,
                        contentDescription = "Rename recording",
                        tint = colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun EmptyDrawerState(icon: @Composable () -> Unit, text: String) {
    val colorScheme = MaterialTheme.colorScheme

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = DesignTokens.Spacing.golden),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            modifier = Modifier.size(DesignTokens.Touch.minTarget),
            contentAlignment = Alignment.Center
        ) {
            androidx.compose.runtime.CompositionLocalProvider(
                androidx.compose.material3.LocalContentColor provides colorScheme.onSurfaceVariant.copy(alpha = 0.6f)
            ) {
                icon()
            }
        }
        Spacer(Modifier.height(DesignTokens.Spacing.md))
        Text(text, color = colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ProjectDrawerRow(
    project: SongProject,
    isActive: Boolean,
    onLoadProject: (SongProject) -> Unit,
    onDeleteProject: (SongProject) -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val dateStr = remember(project.updatedAt) {
        SimpleDateFormat("MMM d, yyyy", Locale.getDefault()).format(Date(project.updatedAt))
    }
    val wordCount = remember(project.lyrics) { SyllableCounter.lyricWordCount(project.lyrics) }

    Card(
        onClick = { onLoadProject(project) },
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = DesignTokens.Touch.minTarget),
        shape = RoundedCornerShape(DesignTokens.Radius.xl),
        colors = CardDefaults.cardColors(
            containerColor = if (isActive) {
                colorScheme.primaryContainer
            } else {
                colorScheme.surfaceContainer
            },
            contentColor = if (isActive) {
                colorScheme.onPrimaryContainer
            } else {
                colorScheme.onSurface
            }
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DesignTokens.Spacing.md),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    project.title.ifEmpty { "Untitled Song" },
                    fontWeight = FontWeight.Medium,
                    color = if (isActive) colorScheme.onPrimaryContainer else colorScheme.onSurface,
                    maxLines = 1
                )
                com.rhymeai.app.util.SectionMap.lyricContent(project.lyrics).lineSequence().firstOrNull { it.isNotBlank() }?.let { preview ->
                    Text(preview.trim(), style = MaterialTheme.typography.bodyMedium, color = colorScheme.onSurfaceVariant, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                }
                Text(
                    "$dateStr \u2022 $wordCount words",
                    fontSize = DesignTokens.Typography.caption,
                    color = if (isActive) {
                        colorScheme.onPrimaryContainer.copy(alpha = 0.75f)
                    } else {
                        colorScheme.onSurfaceVariant
                    }
                )
            }
            IconButton(
                onClick = { onDeleteProject(project) },
                modifier = Modifier.size(DesignTokens.Touch.minTarget)
            ) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = "Delete ${project.title.ifEmpty { "Untitled Song" }}",
                    tint = colorScheme.error.copy(alpha = 0.75f),
                    modifier = Modifier.size(18.dp)
                )
            }
        }
    }
}

@Composable
private fun TrashBinPage(
    trashedProjects: List<TrashedSongProject>,
    onRestoreProject: (String) -> Unit,
    onPermanentlyDeleteProject: (String) -> Unit,
    onRecordingPurgeIncomplete: () -> Unit,
    onDismiss: () -> Unit,
    service: VoiceMemoService?,
    projects: List<SongProject>
) {
    val colorScheme = MaterialTheme.colorScheme
    val scope = rememberCoroutineScope()
    // 0 = Projects, 1 = Recordings
    var selectedTrashTab by remember { mutableStateOf(0) }
    val isProjectsTab = selectedTrashTab == 0

    val sortedTrashedProjects = remember(trashedProjects) {
        trashedProjects.sortedByDescending { it.deletedAt }
    }
    val trashIds = remember(sortedTrashedProjects) {
        sortedTrashedProjects.map { it.project.id }
    }
    val trashIdSet = remember(trashIds) { trashIds.toSet() }
    var selectedIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var confirmPermanentDelete by remember { mutableStateOf(false) }

    // Trashed recordings are scanned from disk; bump the version to re-scan
    // after any restore/delete mutation.
    var trashedMemoVersion by remember { mutableIntStateOf(0) }
    val trashedMemos: List<TrashedVoiceMemo>? by produceState<List<TrashedVoiceMemo>?>(
        initialValue = null,
        service,
        trashedMemoVersion
    ) {
        val complete = try {
            service?.purgeExpiredTrashedMemos() ?: true
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            false
        }
        if (!complete) onRecordingPurgeIncomplete()
        value = service?.trashedMemos() ?: emptyList()
    }
    val memoPaths = remember(trashedMemos) {
        trashedMemos.orEmpty().map { it.file.absolutePath }
    }
    val memoPathSet = remember(memoPaths) { memoPaths.toSet() }
    var selectedMemoPaths by remember { mutableStateOf<Set<String>>(emptySet()) }
    // Song titles for recording subtitles: live projects and trashed projects both
    // count; anything else was permanently deleted.
    val projectTitleById = remember(projects, trashedProjects) {
        buildMap {
            trashedProjects.forEach { put(it.project.id, it.project.title.ifEmpty { "Untitled Song" }) }
            projects.forEach { put(it.id, it.title.ifEmpty { "Untitled Song" }) }
        }
    }

    val selectedCount = if (isProjectsTab) selectedIds.size else selectedMemoPaths.size
    val hasSelection = selectedCount > 0
    val allSelected = if (isProjectsTab) {
        sortedTrashedProjects.isNotEmpty() && selectedIds.containsAll(trashIds)
    } else {
        memoPaths.isNotEmpty() && selectedMemoPaths.containsAll(memoPaths)
    }
    val bottomActionClearance = maxOf(
        navigationBarBottomPadding(),
        DialogBottomActionMinClearance
    )
    val bottomActionBarHeight = DesignTokens.Touch.minTarget + DesignTokens.Spacing.md + DesignTokens.Spacing.md
    val contentBottomPadding = bottomActionClearance + bottomActionBarHeight + DesignTokens.Spacing.xl

    LaunchedEffect(trashIdSet) {
        selectedIds = selectedIds.intersect(trashIdSet)
    }
    LaunchedEffect(memoPathSet) {
        selectedMemoPaths = selectedMemoPaths.intersect(memoPathSet)
    }

    fun toggleSelection(id: String) {
        selectedIds = if (id in selectedIds) selectedIds - id else selectedIds + id
    }

    fun toggleMemoSelection(path: String) {
        selectedMemoPaths = if (path in selectedMemoPaths) selectedMemoPaths - path else selectedMemoPaths + path
    }

    fun restoreSelected() {
        if (isProjectsTab) {
            val idsToRestore = selectedIds.toList()
            idsToRestore.forEach(onRestoreProject)
            selectedIds = emptySet()
        } else {
            val memosToRestore = trashedMemos.orEmpty().filter { it.file.absolutePath in selectedMemoPaths }
            scope.launch {
                memosToRestore.forEach { service?.restoreTrashedMemo(it) }
                selectedMemoPaths = emptySet()
                trashedMemoVersion++
            }
        }
    }

    fun deleteSelectedForever() {
        if (isProjectsTab) {
            val idsToDelete = selectedIds.toList()
            idsToDelete.forEach(onPermanentlyDeleteProject)
            selectedIds = emptySet()
        } else {
            val memosToDelete = trashedMemos.orEmpty().filter { it.file.absolutePath in selectedMemoPaths }
            scope.launch {
                memosToDelete.forEach { service?.permanentlyDeleteTrashedMemo(it) }
                selectedMemoPaths = emptySet()
                trashedMemoVersion++
            }
        }
    }

    Surface(
        modifier = Modifier
            .fillMaxSize()
            .appWritingSurface(),
        color = Color.Transparent,
        contentColor = colorScheme.onSurface
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.fillMaxSize().statusBarsPadding()) {
                TrashTopBar(onDismiss = onDismiss)

                SlidingSegmentedControl(
                    labels = listOf("Projects", "Recordings"),
                    selectedIndex = selectedTrashTab,
                    onSelect = { selectedTrashTab = it },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(
                            start = DesignTokens.Spacing.lg,
                            end = DesignTokens.Spacing.lg,
                            bottom = DesignTokens.Spacing.sm
                        )
                )

                if (isProjectsTab) {
                    if (sortedTrashedProjects.isEmpty()) {
                        EmptyDrawerState(
                            icon = { Icon(Icons.Default.Delete, contentDescription = null) },
                            text = "No songs in the Trash Bin."
                        )
                    } else {
                        LazyColumn(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f),
                            contentPadding = PaddingValues(
                                start = DesignTokens.Spacing.lg,
                                top = DesignTokens.Spacing.md,
                                end = DesignTokens.Spacing.lg,
                                bottom = contentBottomPadding
                            )
                        ) {
                            item {
                                TrashSelectionHeaderRow(
                                    selected = allSelected,
                                    onToggle = {
                                        selectedIds = if (allSelected) emptySet() else trashIds.toSet()
                                    }
                                )
                            }

                            item {
                                Text(
                                    "Deleted songs stay here for 30 days.",
                                    fontSize = 15.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = colorScheme.onSurface,
                                    modifier = Modifier.padding(
                                        top = DesignTokens.Spacing.xl,
                                        bottom = DesignTokens.Spacing.sm
                                    )
                                )
                            }

                            items(sortedTrashedProjects, key = { it.project.id }) { trashedProject ->
                                TrashProjectSelectableRow(
                                    trashedProject = trashedProject,
                                    selected = trashedProject.project.id in selectedIds,
                                    onToggle = { toggleSelection(trashedProject.project.id) }
                                )
                            }
                        }
                    }
                } else {
                    when {
                        trashedMemos == null -> {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .weight(1f),
                                contentAlignment = Alignment.Center
                            ) {
                                CircularProgressIndicator()
                            }
                        }
                        trashedMemos.orEmpty().isEmpty() -> {
                            EmptyDrawerState(
                                icon = { Icon(Icons.Default.Mic, contentDescription = null) },
                                text = "No recordings in the Trash Bin."
                            )
                        }
                        else -> {
                            LazyColumn(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .weight(1f),
                                contentPadding = PaddingValues(
                                    start = DesignTokens.Spacing.lg,
                                    top = DesignTokens.Spacing.md,
                                    end = DesignTokens.Spacing.lg,
                                    bottom = contentBottomPadding
                                )
                            ) {
                                item {
                                    TrashSelectionHeaderRow(
                                        selected = allSelected,
                                        onToggle = {
                                            selectedMemoPaths = if (allSelected) emptySet() else memoPathSet
                                        }
                                    )
                                }

                                item {
                                    Text(
                                        "Deleted recordings stay here for 30 days.",
                                        fontSize = 15.sp,
                                        fontWeight = FontWeight.Medium,
                                        color = colorScheme.onSurface,
                                        modifier = Modifier.padding(
                                            top = DesignTokens.Spacing.xl,
                                            bottom = DesignTokens.Spacing.sm
                                        )
                                    )
                                }

                                items(trashedMemos.orEmpty(), key = { it.file.absolutePath }) { trashedMemo ->
                                    TrashRecordingSelectableRow(
                                        trashedMemo = trashedMemo,
                                        projectTitle = projectTitleById[trashedMemo.projectId] ?: "Deleted song",
                                        selected = trashedMemo.file.absolutePath in selectedMemoPaths,
                                        onToggle = { toggleMemoSelection(trashedMemo.file.absolutePath) }
                                    )
                                }
                            }
                        }
                    }
                }
            }

            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
            ) {
                TrashBottomActionBar(
                    selectedCount = selectedCount,
                    onRestoreSelected = ::restoreSelected,
                    onRequestDeleteSelected = { confirmPermanentDelete = true }
                )
                Spacer(Modifier.height(bottomActionClearance))
            }
        }
    }

    if (confirmPermanentDelete) {
        val itemNoun = if (isProjectsTab) "song" else "recording"
        AlertDialog(
            onDismissRequest = { confirmPermanentDelete = false },
            title = { Text("Delete forever?") },
            text = {
                Text("$selectedCount selected $itemNoun${if (selectedCount == 1) "" else "s"} will be permanently deleted. This cannot be undone.")
            },
            confirmButton = {
                TextButton(
                    enabled = hasSelection,
                    onClick = {
                        deleteSelectedForever()
                        confirmPermanentDelete = false
                    }
                ) {
                    Text("Delete Forever", color = colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmPermanentDelete = false }) {
                    Text("Cancel")
                }
            },
            containerColor = colorScheme.surfaceContainerHigh
        )
    }
}

@Composable
private fun TrashRecordingSelectableRow(
    trashedMemo: TrashedVoiceMemo,
    projectTitle: String,
    selected: Boolean,
    onToggle: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val displayName = remember(trashedMemo.originalName) {
        VoiceMemoService.displayName(File(trashedMemo.originalName))
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 76.dp)
            .toggleable(
                value = selected,
                role = Role.Checkbox,
                onValueChange = { onToggle() }
            )
            .padding(vertical = DesignTokens.Spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
    ) {
        Box(
            modifier = Modifier
                .size(56.dp)
                .background(colorScheme.surfaceContainerHigh, RoundedCornerShape(DesignTokens.Radius.lg)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Default.Mic,
                contentDescription = null,
                tint = colorScheme.onSurfaceVariant,
                modifier = Modifier.size(24.dp)
            )
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
        ) {
            Text(
                displayName,
                fontWeight = FontWeight.Medium,
                fontSize = 17.sp,
                color = colorScheme.onSurface,
                maxLines = 1
            )
            Text(
                "$projectTitle • ${VoiceMemoService.formatDuration(trashedMemo.durationMs)} • ${trashRemainingLabel(trashedMemo.deleteAfter)}",
                fontSize = DesignTokens.Typography.caption,
                color = colorScheme.onSurfaceVariant,
                maxLines = 1
            )
        }

        SelectionCircle(selected = selected)
    }
}

@Composable
private fun TrashTopBar(onDismiss: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 80.dp)
            .padding(horizontal = DesignTokens.Spacing.sm),
        verticalAlignment = Alignment.CenterVertically
    ) {
        IconButton(onClick = onDismiss) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to songs drawer")
        }
        Text(
            "Trash",
            fontSize = 26.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(start = DesignTokens.Spacing.sm)
        )
    }
}

@Composable
private fun TrashSelectionHeaderRow(
    selected: Boolean,
    onToggle: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(DesignTokens.Touch.minTarget)
            .toggleable(
                value = selected,
                role = Role.Checkbox,
                onValueChange = { onToggle() }
            ),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            "All items",
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            color = colorScheme.onSurface,
            modifier = Modifier.weight(1f)
        )
        SelectionCircle(selected = selected)
    }
}

@Composable
private fun TrashProjectSelectableRow(
    trashedProject: TrashedSongProject,
    selected: Boolean,
    onToggle: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val project = trashedProject.project
    val wordCount = remember(project.lyrics) { SyllableCounter.lyricWordCount(project.lyrics) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 76.dp)
            .toggleable(
                value = selected,
                role = Role.Checkbox,
                onValueChange = { onToggle() }
            )
            .padding(vertical = DesignTokens.Spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
    ) {
        Box(
            modifier = Modifier
                .size(56.dp)
                .background(colorScheme.surfaceContainerHigh, RoundedCornerShape(DesignTokens.Radius.lg)),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                Icons.Default.MusicNote,
                contentDescription = null,
                tint = colorScheme.onSurfaceVariant,
                modifier = Modifier.size(24.dp)
            )
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
        ) {
            Text(
                project.title.ifEmpty { "Untitled Song" },
                fontWeight = FontWeight.Medium,
                fontSize = 17.sp,
                color = colorScheme.onSurface,
                maxLines = 1
            )
            Text(
                "$wordCount words • ${trashRemainingLabel(trashedProject.deleteAfter)}",
                fontSize = DesignTokens.Typography.caption,
                color = colorScheme.onSurfaceVariant,
                maxLines = 1
            )
        }

        SelectionCircle(selected = selected)
    }
}

@Composable
private fun SelectionCircle(selected: Boolean) {
    val colorScheme = MaterialTheme.colorScheme
    val fillColor by animateColorAsState(
        targetValue = if (selected) colorScheme.primary else colorScheme.surfaceContainerLow,
        animationSpec = tween(DesignTokens.Motion.feedbackMillis)
    )
    val borderColor by animateColorAsState(
        targetValue = if (selected) colorScheme.primary else colorScheme.outline,
        animationSpec = tween(DesignTokens.Motion.feedbackMillis)
    )
    Box(
        modifier = Modifier.size(DesignTokens.Touch.minTarget),
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .size(26.dp)
                .background(
                    color = fillColor,
                    shape = CircleShape
                )
                .border(
                    width = 2.dp,
                    color = borderColor,
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            AnimatedVisibility(
                visible = selected,
                enter = fadeIn(animationSpec = tween(DesignTokens.Motion.feedbackMillis)),
                exit = fadeOut(animationSpec = tween(DesignTokens.Motion.feedbackMillis))
            ) {
                Icon(
                    Icons.Default.Check,
                    contentDescription = null,
                    tint = colorScheme.onPrimary,
                    modifier = Modifier.size(16.dp)
                )
            }
        }
    }
}

@Composable
private fun TrashBottomActionBar(
    selectedCount: Int,
    onRestoreSelected: () -> Unit,
    onRequestDeleteSelected: () -> Unit,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val hasSelection = selectedCount > 0

    Surface(
        modifier = modifier.fillMaxWidth(),
        color = colorScheme.surfaceContainer,
        tonalElevation = 3.dp
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(
                    start = DesignTokens.Spacing.lg,
                    top = DesignTokens.Spacing.md,
                    end = DesignTokens.Spacing.lg,
                    bottom = DesignTokens.Spacing.md
                )
                .height(DesignTokens.Touch.minTarget),
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedButton(
                enabled = hasSelection,
                onClick = onRestoreSelected,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
                shape = RoundedCornerShape(DesignTokens.Radius.pill)
            ) {
                Icon(Icons.Default.Restore, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(DesignTokens.Spacing.sm))
                Text("Restore")
            }

            Button(
                enabled = hasSelection,
                onClick = onRequestDeleteSelected,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(),
                shape = RoundedCornerShape(DesignTokens.Radius.pill)
            ) {
                Icon(Icons.Default.Delete, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(DesignTokens.Spacing.sm))
                Text("Delete")
            }
        }
    }
}

private fun trashRemainingLabel(deleteAfter: Long): String {
    val remainingMillis = (deleteAfter - System.currentTimeMillis()).coerceAtLeast(0L)
    val remainingDays = ((remainingMillis + MillisPerDay - 1L) / MillisPerDay).coerceAtLeast(0L)
    return when (remainingDays) {
        0L -> "Deletes today"
        1L -> "Deletes in 1 day"
        else -> "Deletes in $remainingDays days"
    }
}

private fun searchProjects(projects: List<SongProject>, query: String): List<SongProject> {
    val normalizedQuery = query.trim()
    if (normalizedQuery.isEmpty()) return projects

    return projects.filter { project ->
        val title = project.title.ifEmpty { "Untitled Song" }
        title.contains(normalizedQuery, ignoreCase = true) ||
            project.lyrics.contains(normalizedQuery, ignoreCase = true) ||
            project.theme.contains(normalizedQuery, ignoreCase = true)
    }
}
