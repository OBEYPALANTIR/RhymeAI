package com.rhymeai.app.ui.components

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
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
import androidx.compose.foundation.layout.widthIn
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
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
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
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.service.VoiceMemo
import com.rhymeai.app.service.VoiceMemoService
import com.rhymeai.app.util.SyllableCounter
import com.rhymeai.app.ui.theme.DesignTokens
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

private val DrawerAnimationMillis: Int get() = DesignTokens.Motion.drawerPresentMillis
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
    onDeleteProject: (String) -> Unit,
    onRestoreProject: (String) -> Unit,
    onPermanentlyDeleteProject: (String) -> Unit,
    onPurgeExpiredTrash: () -> Unit,
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
    var drawerVisible by remember { mutableStateOf(false) }
    var isClosing by remember { mutableStateOf(false) }
    var projectPendingDelete by remember { mutableStateOf<SongProject?>(null) }
    var showTrashBin by remember { mutableStateOf(false) }
    // 0 = Songs, 1 = Recordings
    var selectedTab by remember { mutableStateOf(0) }

    BackHandler(enabled = showTrashBin) {
        showTrashBin = false
    }

    fun closeDrawer(afterClose: () -> Unit = {}) {
        if (isClosing) return
        isClosing = true
        drawerVisible = false
        scope.launch {
            delay(DrawerAnimationMillis.toLong())
            afterClose()
            onDismiss()
        }
    }

    LaunchedEffect(Unit) {
        drawerVisible = true
    }

    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            try {
                val text = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
                        ?: throw Exception("Cannot read file")
                }
                val project = importJson.decodeFromString(SongProject.serializer(), text)
                importError = null
                closeDrawer { onImportProject(project) }
            } catch (e: Exception) {
                importError = "Could not import this file. Pick a RhymeAI project JSON."
            }
        }
    }

    val sortedProjects = remember(projects) { projects.sortedByDescending { it.updatedAt } }
    val filteredProjects = remember(sortedProjects, searchQuery) { searchProjects(sortedProjects, searchQuery) }
    val isSearching = searchQuery.isNotBlank()
    val drawerWidth = (configuration.screenWidthDp.dp - DesignTokens.Spacing.xxl)
        .coerceAtLeast(DesignTokens.Drawer.compactWidth)
        .coerceAtMost(DesignTokens.Drawer.width)
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

    Dialog(
        onDismissRequest = {
            if (showTrashBin) showTrashBin = false else closeDrawer()
        },
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false
        )
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            AnimatedVisibility(
                visible = drawerVisible,
                enter = fadeIn(animationSpec = tween(DrawerAnimationMillis)),
                exit = fadeOut(animationSpec = tween(DrawerAnimationMillis))
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(colorScheme.scrim.copy(alpha = 0.42f))
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = { closeDrawer() }
                        )
                )
            }

            AnimatedVisibility(
                visible = drawerVisible,
                enter = slideInHorizontally(
                    animationSpec = tween(DrawerAnimationMillis),
                    initialOffsetX = { -it }
                ) + fadeIn(animationSpec = tween(DrawerAnimationMillis)),
                exit = slideOutHorizontally(
                    animationSpec = tween(DrawerAnimationMillis),
                    targetOffsetX = { -it }
                ) + fadeOut(animationSpec = tween(DrawerAnimationMillis))
            ) {
                Surface(
                    modifier = Modifier
                        .fillMaxHeight()
                        .width(drawerWidth)
                        .widthIn(max = DesignTokens.Drawer.width)
                        .imePadding()
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            onClick = {}
                        ),
                    shape = RoundedCornerShape(0.dp),
                    color = colorScheme.surfaceContainerLow,
                    contentColor = colorScheme.onSurface,
                    tonalElevation = 8.dp
                ) {
                    val bottomActionClearance = maxOf(
                        navigationBarBottomPadding(),
                        DialogBottomActionMinClearance
                    )
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .statusBarsPadding()
                            .padding(horizontal = DesignTokens.Spacing.lg)
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
                                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
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
                                    trailingIcon = {
                                        if (searchQuery.isNotEmpty()) {
                                            IconButton(onClick = { searchQuery = "" }) {
                                                Icon(
                                                    Icons.Default.Close,
                                                    contentDescription = "Clear search",
                                                    modifier = Modifier.size(18.dp)
                                                )
                                            }
                                        }
                                    },
                                    placeholder = {
                                        Text(
                                            text = if (selectedTab == 0) {
                                                "Search songs"
                                            } else {
                                                "Search recordings"
                                            },
                                            fontSize = 14.sp
                                        )
                                    },
                                    modifier = Modifier.weight(1f),
                                    colors = textFieldColors,
                                    shape = RoundedCornerShape(DesignTokens.Radius.xl)
                                )

                                IconButton(onClick = { closeDrawer() }) {
                                    Icon(
                                        Icons.Default.Close,
                                        contentDescription = "Close drawer",
                                        tint = colorScheme.onSurfaceVariant
                                    )
                                }
                            }

                            OutlinedButton(
                                onClick = { closeDrawer(afterClose = onNewProject) },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(top = DesignTokens.Spacing.md)
                                    .heightIn(min = 56.dp),
                                shape = RoundedCornerShape(DesignTokens.Radius.xl),
                                border = BorderStroke(1.dp, colorScheme.outline)
                            ) {
                                Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.width(DesignTokens.Spacing.sm))
                                Text("Create New Song", fontWeight = FontWeight.Medium)
                            }

                            // Songs | Recordings tab switcher
                            Spacer(Modifier.height(DesignTokens.Spacing.md))
                            SingleChoiceSegmentedButtonRow(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(bottom = DesignTokens.Spacing.sm)
                            ) {
                                listOf("Songs", "Recordings").forEachIndexed { index, label ->
                                    SegmentedButton(
                                        selected = selectedTab == index,
                                        onClick = { selectedTab = index },
                                        shape = SegmentedButtonDefaults.itemShape(index, 2),
                                        colors = SegmentedButtonDefaults.colors(
                                            activeContainerColor = colorScheme.primary,
                                            activeContentColor = colorScheme.onPrimary,
                                            inactiveContainerColor = colorScheme.surfaceContainerLow,
                                            inactiveContentColor = colorScheme.onSurfaceVariant,
                                            activeBorderColor = colorScheme.primary,
                                            inactiveBorderColor = colorScheme.outlineVariant
                                        )
                                    ) {
                                        Text(label, fontSize = 13.sp)
                                    }
                                }
                            }

                            if (selectedTab == 0) {
                                // ── Songs tab ──
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
                                                onDeleteProject = { projectPendingDelete = it }
                                            )
                                        }
                                    }
                                }
                            } else {
                                // ── Recordings tab ──
                                RecordingsTab(
                                    service = service,
                                    projects = projects,
                                    searchQuery = searchQuery,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .weight(1f)
                                )
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
                                OutlinedButton(
                                    onClick = {
                                        importError = null
                                        importLauncher.launch(arrayOf("application/json", "*/*"))
                                    },
                                    modifier = Modifier
                                        .weight(1f)
                                        .fillMaxHeight(),
                                    shape = RoundedCornerShape(DesignTokens.Radius.xl),
                                    border = BorderStroke(1.dp, colorScheme.outlineVariant)
                                ) {
                                    Icon(Icons.Default.FileOpen, contentDescription = null, modifier = Modifier.size(18.dp))
                                    Spacer(Modifier.width(DesignTokens.Spacing.sm))
                                    Text("Import Files", fontWeight = FontWeight.Medium)
                                }

                                OutlinedIconButton(
                                    onClick = {
                                        onPurgeExpiredTrash()
                                        showTrashBin = true
                                    },
                                    modifier = Modifier
                                        .fillMaxHeight()
                                        .width(DesignTokens.Touch.minTarget)
                                        .semantics { contentDescription = "Open Trash Bin" },
                                    shape = RoundedCornerShape(DesignTokens.Radius.xl),
                                    border = BorderStroke(1.dp, colorScheme.outlineVariant)
                                ) {
                                    Icon(
                                        Icons.Default.Delete,
                                        contentDescription = "Open Trash Bin",
                                        modifier = Modifier.size(18.dp)
                                    )
                                }
                            }
                            Spacer(Modifier.height(bottomActionClearance))
                        }
                    }
                }
            }

            AnimatedVisibility(
                visible = showTrashBin,
                enter = slideInHorizontally(
                    animationSpec = tween(DrawerAnimationMillis),
                    initialOffsetX = { it }
                ) + fadeIn(animationSpec = tween(DrawerAnimationMillis)),
                exit = slideOutHorizontally(
                    animationSpec = tween(DrawerAnimationMillis),
                    targetOffsetX = { it }
                ) + fadeOut(animationSpec = tween(DrawerAnimationMillis))
            ) {
                TrashBinPage(
                    trashedProjects = trashedProjects,
                    onRestoreProject = onRestoreProject,
                    onPermanentlyDeleteProject = onPermanentlyDeleteProject,
                    onDismiss = { showTrashBin = false }
                )
            }
        }
    }

    projectPendingDelete?.let { project ->
        AlertDialog(
            onDismissRequest = { projectPendingDelete = null },
            title = { Text("Delete this song?") },
            text = {
                Text("\"${project.title.ifEmpty { "Untitled Song" }}\" will move to Trash Bin and be fully deleted after 30 days.")
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onDeleteProject(project.id)
                        projectPendingDelete = null
                    }
                ) {
                    Text("Move to Trash", color = colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { projectPendingDelete = null }) {
                    Text("Cancel")
                }
            }
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
    onDeleteProject: (String) -> Unit,
    onRestoreProject: (String) -> Unit,
    onPermanentlyDeleteProject: (String) -> Unit,
    onPurgeExpiredTrash: () -> Unit,
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
        onDismiss = onDismiss
    )
}

/**
 * Recordings tab — scans all voice-memo dirs across every project and groups
 * recordings by their owning project folder. Orphaned memos (project no longer
 * in [projects]) are labeled "Deleted song" so they can still be played or
 * cleaned up.
 */
private data class RecordingFolder(
    val projectId: String,
    val title: String,
    val memos: List<VoiceMemo>,
)

@Composable
private fun RecordingsTab(
    service: VoiceMemoService?,
    projects: List<SongProject>,
    searchQuery: String,
    modifier: Modifier = Modifier
) {
    if (service == null) {
        // Service unavailable — show a graceful empty state.
        EmptyDrawerState(
            icon = { Icon(Icons.Default.Mic, contentDescription = null) },
            text = "Recordings not available."
        )
        return
    }

    // Version counter: incremented after any mutation (delete, rename) so the
    // async loader below is restarted and the list is re-scanned from disk.
    var memoListVersion by remember { mutableIntStateOf(0) }

    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val projectById = remember(projects) { projects.associateBy { it.id } }
    val folders: List<RecordingFolder>? by produceState<List<RecordingFolder>?>(
        initialValue = null,
        projects,
        memoListVersion
    ) {
        value = withContext(Dispatchers.IO) {
            val memosRoot = File(context.filesDir, "voice-memos")
            if (!memosRoot.exists()) {
                emptyList()
            } else {
                memosRoot.listFiles()
                    ?.filter { it.isDirectory }
                    ?.mapNotNull { dir ->
                        val memos = service.memosForProject(dir.name)
                        if (memos.isEmpty()) return@mapNotNull null
                        val title = projectById[dir.name]?.title?.ifEmpty { "Untitled" }
                            ?: "Deleted song"
                        RecordingFolder(
                            projectId = dir.name,
                            title = title,
                            memos = memos,
                        )
                    }
                    ?.sortedByDescending { it.memos.first().file.lastModified() }
                    ?: emptyList()
            }
        }
    }
    val query = remember(searchQuery) { searchQuery.trim() }
    val visibleFolders = remember(folders, query) {
        if (query.isEmpty()) {
            folders.orEmpty()
        } else {
            folders.orEmpty().mapNotNull { folder ->
                if (folder.title.contains(query, ignoreCase = true)) {
                    folder
                } else {
                    val matches = folder.memos.filter { memo ->
                        VoiceMemoService.displayName(memo.file).contains(query, ignoreCase = true)
                    }
                    if (matches.isEmpty()) {
                        null
                    } else {
                        RecordingFolder(
                            projectId = folder.projectId,
                            title = folder.title,
                            memos = matches,
                        )
                    }
                }
            }
        }
    }
    val expanded = remember { mutableStateMapOf<String, Boolean>() }
    var isSelecting by remember { mutableStateOf(false) }
    var selectedMemoPaths by remember { mutableStateOf<Set<String>>(emptySet()) }
    var pendingBulkDelete by remember { mutableStateOf(false) }

    if (pendingBulkDelete) {
        AlertDialog(
            onDismissRequest = { pendingBulkDelete = false },
            title = { Text("Delete recordings?") },
            text = { Text("${selectedMemoPaths.size} recordings will be permanently deleted.") },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        folders.orEmpty()
                            .flatMap { it.memos }
                            .filter { it.file.absolutePath in selectedMemoPaths }
                            .forEach { service.deleteMemo(it) }
                        pendingBulkDelete = false
                        isSelecting = false
                        selectedMemoPaths = emptySet()
                        memoListVersion++
                    }
                }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pendingBulkDelete = false }) { Text("Cancel") }
            }
        )
    }

    if (folders == null) {
        Box(
            modifier = modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            CircularProgressIndicator()
        }
        return
    }

    if (visibleFolders.isEmpty()) {
        EmptyDrawerState(
            icon = {
                val icon = if (query.isNotEmpty()) {
                    Icons.Default.Search
                } else {
                    Icons.Default.Mic
                }
                Icon(icon, contentDescription = null)
            },
            text = if (query.isNotEmpty()) {
                "No recordings match your search."
            } else {
                "No recordings yet. Tap the mic to start."
            }
        )
        return
    }

    Column(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = DesignTokens.Spacing.xs),
            horizontalArrangement = Arrangement.End,
            verticalAlignment = Alignment.CenterVertically
        ) {
            if (isSelecting) {
                TextButton(onClick = {
                    isSelecting = false
                    selectedMemoPaths = emptySet()
                }) {
                    Text("Cancel")
                }
                TextButton(
                    onClick = { pendingBulkDelete = true },
                    enabled = selectedMemoPaths.isNotEmpty()
                ) {
                    Text("Delete (${selectedMemoPaths.size})", color = MaterialTheme.colorScheme.error)
                }
            } else {
                TextButton(onClick = { isSelecting = true }) {
                    Text("Select")
                }
            }
        }

        LazyColumn(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
            contentPadding = PaddingValues(vertical = DesignTokens.Spacing.sm)
        ) {
            visibleFolders.forEach { folder ->
                item(key = "folder-${folder.projectId}") {
                    FolderHeaderRow(
                        folder = folder,
                        isExpanded = expanded[folder.projectId] == true || query.isNotEmpty(),
                        onToggle = {
                            expanded[folder.projectId] = !(expanded[folder.projectId] ?: false)
                        }
                    )
                }
                if (expanded[folder.projectId] == true || query.isNotEmpty()) {
                    items(folder.memos, key = { it.file.absolutePath }) { memo ->
                        val memoPath = memo.file.absolutePath
                        Box(modifier = Modifier.padding(start = DesignTokens.Spacing.md)) {
                            RecordingMemoRow(
                                memo = memo,
                                service = service,
                                isSelecting = isSelecting,
                                isSelected = memoPath in selectedMemoPaths,
                                onSelectionChanged = { selected ->
                                    selectedMemoPaths = if (selected) {
                                        selectedMemoPaths + memoPath
                                    } else {
                                        selectedMemoPaths - memoPath
                                    }
                                },
                                onMemoListChanged = { memoListVersion++ }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FolderHeaderRow(
    folder: RecordingFolder,
    isExpanded: Boolean,
    onToggle: () -> Unit,
) {
    val colorScheme = MaterialTheme.colorScheme
    OutlinedCard(
        onClick = onToggle,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = DesignTokens.Touch.minTarget),
        shape = RoundedCornerShape(DesignTokens.Radius.xl),
        colors = CardDefaults.outlinedCardColors(
            containerColor = colorScheme.surfaceContainer,
            contentColor = colorScheme.onSurface
        ),
        border = BorderStroke(1.dp, colorScheme.outlineVariant)
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
                    text = folder.title,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    color = if (folder.title == "Deleted song") {
                        colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                    } else {
                        colorScheme.onSurface
                    }
                )
                Text(
                    text = "${folder.memos.size} ${if (folder.memos.size == 1) "recording" else "recordings"}",
                    fontSize = 13.sp,
                    color = colorScheme.onSurfaceVariant
                )
            }
            Icon(
                Icons.Default.KeyboardArrowDown,
                contentDescription = if (isExpanded) "Collapse" else "Expand",
                tint = colorScheme.onSurfaceVariant,
                modifier = Modifier.rotate(if (isExpanded) 180f else 0f)
            )
        }
    }
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
    val offsetX = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    // Only compose the red reveal layer when the rendered row offset is visibly open.
    // At rest the stationary container and moving foreground both paint the row surface,
    // so anti-aliased rounded edges cannot blend with red and leave a halo.
    val displayOffsetPx by remember {
        derivedStateOf { offsetX.value.roundToInt().coerceIn(-revealPxInt, 0) }
    }
    val revealVisible by remember { derivedStateOf { displayOffsetPx < 0 } }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .clip(rowShape)
            .background(colorScheme.surfaceContainerLow)
            .border(1.dp, colorScheme.outlineVariant, rowShape)
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
                        scope.launch { offsetX.animateTo(0f, tween(DesignTokens.Motion.standardMillis)) }
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
                .pointerInput(Unit) {
                    detectHorizontalDragGestures(
                        onHorizontalDrag = { _, dragAmount ->
                            scope.launch {
                                offsetX.snapTo((offsetX.value + dragAmount).coerceIn(-revealPx, 0f))
                            }
                        },
                        onDragEnd = {
                            val target = if (offsetX.value < -revealPx / 2f) -revealPx else 0f
                            scope.launch {
                                offsetX.animateTo(target, tween(DesignTokens.Motion.standardMillis))
                            }
                        },
                        onDragCancel = {
                            val target = if (offsetX.value < -revealPx / 2f) -revealPx else 0f
                            scope.launch {
                                offsetX.animateTo(target, tween(DesignTokens.Motion.standardMillis))
                            }
                        }
                    )
                }
        ) {
            content()
        }
    }
}

@Composable
private fun RecordingMemoRow(
    memo: VoiceMemo,
    service: VoiceMemoService,
    isSelecting: Boolean,
    isSelected: Boolean,
    onSelectionChanged: (Boolean) -> Unit,
    onMemoListChanged: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val scope = rememberCoroutineScope()
    val isPlaying = service.playingFile == memo.file
    var pendingDelete by remember { mutableStateOf(false) }
    var pendingRename by remember { mutableStateOf(false) }
    var renameText by remember(memo.file.absolutePath) {
        mutableStateOf(VoiceMemoService.displayName(memo.file))
    }

    if (pendingDelete) {
        AlertDialog(
            onDismissRequest = { pendingDelete = false },
            title = { Text("Delete recording?") },
            text = { Text("This recording will be permanently deleted.") },
            confirmButton = {
                TextButton(onClick = {
                    scope.launch {
                        service.deleteMemo(memo)
                        pendingDelete = false
                        onMemoListChanged()
                    }
                }) { Text("Delete", color = colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = false }) { Text("Cancel") }
            }
        )
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
                        if (renamed != null) onMemoListChanged()
                    }
                }) { Text("OK") }
            },
            dismissButton = {
                TextButton(onClick = { pendingRename = false }) { Text("Cancel") }
            }
        )
    }

    SwipeToRevealDelete(onDelete = { pendingDelete = true }) {
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
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium,
                        color = colorScheme.onSurface
                    )
                    Text(
                        text = VoiceMemoService.formatDuration(memo.durationMs),
                        fontSize = 11.sp,
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
                androidx.compose.material3.LocalContentColor provides colorScheme.onSurfaceVariant.copy(alpha = 0.45f)
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
    val wordCount = remember(project.lyrics) { SyllableCounter.wordCount(project.lyrics) }

    OutlinedCard(
        onClick = { onLoadProject(project) },
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = DesignTokens.Touch.minTarget),
        shape = RoundedCornerShape(DesignTokens.Radius.xl),
        colors = CardDefaults.outlinedCardColors(
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
        ),
        border = BorderStroke(
            1.dp,
            if (isActive) colorScheme.primary else colorScheme.outlineVariant
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
                Text(
                    "$dateStr \u2022 $wordCount words",
                    fontSize = 13.sp,
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
                    Icons.Default.Close,
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
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val sortedTrashedProjects = remember(trashedProjects) {
        trashedProjects.sortedByDescending { it.deletedAt }
    }
    val trashIds = remember(sortedTrashedProjects) {
        sortedTrashedProjects.map { it.project.id }
    }
    val trashIdSet = remember(trashIds) { trashIds.toSet() }
    var selectedIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var confirmPermanentDelete by remember { mutableStateOf(false) }
    val selectedCount = selectedIds.size
    val hasSelection = selectedCount > 0
    val allSelected = sortedTrashedProjects.isNotEmpty() && selectedIds.containsAll(trashIds)
    val bottomActionClearance = maxOf(
        navigationBarBottomPadding(),
        DialogBottomActionMinClearance
    )
    val bottomActionBarHeight = DesignTokens.Touch.minTarget + DesignTokens.Spacing.md + DesignTokens.Spacing.md
    val contentBottomPadding = bottomActionClearance + bottomActionBarHeight + DesignTokens.Spacing.xl

    LaunchedEffect(trashIdSet) {
        selectedIds = selectedIds.intersect(trashIdSet)
    }

    fun toggleSelection(id: String) {
        selectedIds = if (id in selectedIds) selectedIds - id else selectedIds + id
    }

    fun restoreSelected() {
        val idsToRestore = selectedIds.toList()
        idsToRestore.forEach(onRestoreProject)
        selectedIds = emptySet()
    }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = colorScheme.surfaceContainerLow,
        contentColor = colorScheme.onSurface
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            Column(modifier = Modifier.fillMaxSize().statusBarsPadding()) {
                TrashTopBar(onDismiss = onDismiss)

                if (sortedTrashedProjects.isEmpty()) {
                    EmptyDrawerState(
                        icon = { Icon(Icons.Default.Delete, contentDescription = null) },
                        text = "Trash Bin is empty."
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
                                "30 days left",
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
        AlertDialog(
            onDismissRequest = { confirmPermanentDelete = false },
            title = { Text("Delete forever?") },
            text = {
                Text("$selectedCount selected song${if (selectedCount == 1) "" else "s"} will be permanently deleted. This cannot be undone.")
            },
            confirmButton = {
                TextButton(
                    enabled = hasSelection,
                    onClick = {
                        val idsToDelete = selectedIds.toList()
                        idsToDelete.forEach(onPermanentlyDeleteProject)
                        selectedIds = emptySet()
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
            .clickable(onClick = onToggle),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            "All items",
            fontSize = 15.sp,
            fontWeight = FontWeight.Medium,
            color = colorScheme.onSurface,
            modifier = Modifier.weight(1f)
        )
        SelectionCircle(selected = selected, onToggle = onToggle)
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
    val wordCount = remember(project.lyrics) { SyllableCounter.wordCount(project.lyrics) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 76.dp)
            .clickable(onClick = onToggle)
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
                fontSize = 13.sp,
                color = colorScheme.onSurfaceVariant,
                maxLines = 1
            )
        }

        SelectionCircle(selected = selected, onToggle = onToggle)
    }
}

@Composable
private fun SelectionCircle(selected: Boolean, onToggle: () -> Unit) {
    val colorScheme = MaterialTheme.colorScheme
    Box(
        modifier = Modifier
            .size(DesignTokens.Touch.minTarget)
            .clickable(onClick = onToggle),
        contentAlignment = Alignment.Center
    ) {
        Box(
            modifier = Modifier
                .size(26.dp)
                .background(
                    color = if (selected) colorScheme.primary else colorScheme.surfaceContainerLow,
                    shape = CircleShape
                )
                .border(
                    width = 2.dp,
                    color = if (selected) colorScheme.primary else colorScheme.outline,
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            if (selected) {
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
