package com.rhymeai.app.ui.components

import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.util.SyllableCounter
import com.rhymeai.app.ui.theme.DesignTokens
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

private val DrawerAnimationMillis: Int get() = DesignTokens.Motion.drawerPresentMillis

@Composable
fun ProjectsDrawer(
    projects: List<SongProject>,
    currentProjectId: String?,
    onLoadProject: (SongProject) -> Unit,
    onNewProject: () -> Unit,
    onDeleteProject: (String) -> Unit,
    onImportProject: (SongProject) -> Unit,
    onDismiss: () -> Unit
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
                Log.e("ProjectsDialog", "Import failed", e)
                importError = "Could not import this file. Pick a RhymeAI project JSON."
            }
        }
    }

    val sortedProjects = projects.sortedByDescending { it.updatedAt }
    val filteredProjects = searchProjects(sortedProjects, searchQuery)
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
        onDismissRequest = { closeDrawer() },
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
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .statusBarsPadding()
                            .navigationBarsPadding()
                            .padding(horizontal = DesignTokens.Spacing.lg)
                            .padding(top = DesignTokens.Spacing.lg, bottom = DesignTokens.Spacing.lg)
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
                                placeholder = { Text("Search songs", fontSize = 14.sp) },
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
                                .height(56.dp),
                            shape = RoundedCornerShape(DesignTokens.Radius.xl),
                            border = BorderStroke(1.dp, colorScheme.outline)
                        ) {
                            Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(DesignTokens.Spacing.sm))
                            Text("Create New Song", fontWeight = FontWeight.Medium)
                        }

                        Text(
                            "Recent Songs",
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 13.sp,
                            color = colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(top = DesignTokens.Spacing.lg, bottom = DesignTokens.Spacing.sm)
                        )

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
                                        onDeleteProject = onDeleteProject
                                    )
                                }
                            }
                        }

                        OutlinedButton(
                            onClick = {
                                importError = null
                                importLauncher.launch(arrayOf("application/json", "*/*"))
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(DesignTokens.Touch.minTarget),
                            shape = RoundedCornerShape(DesignTokens.Radius.xl),
                            border = BorderStroke(1.dp, colorScheme.outlineVariant)
                        ) {
                            Icon(Icons.Default.FileOpen, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(DesignTokens.Spacing.sm))
                            Text("Import From File", fontWeight = FontWeight.Medium)
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
                }
            }
        }
    }
}

@Composable
fun ProjectsDialog(
    projects: List<SongProject>,
    currentProjectId: String?,
    onLoadProject: (SongProject) -> Unit,
    onNewProject: () -> Unit,
    onDeleteProject: (String) -> Unit,
    onImportProject: (SongProject) -> Unit,
    onDismiss: () -> Unit
) {
    ProjectsDrawer(
        projects = projects,
        currentProjectId = currentProjectId,
        onLoadProject = onLoadProject,
        onNewProject = onNewProject,
        onDeleteProject = onDeleteProject,
        onImportProject = onImportProject,
        onDismiss = onDismiss
    )
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
    onDeleteProject: (String) -> Unit
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
                onClick = { onDeleteProject(project.id) },
                modifier = Modifier.size(DesignTokens.Touch.minTarget)
            ) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = "Delete",
                    tint = colorScheme.error.copy(alpha = 0.75f),
                    modifier = Modifier.size(18.dp)
                )
            }
        }
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
