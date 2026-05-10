package com.rhymeai.app.ui.components

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.FolderOpen
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.util.SyllableCounter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

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
    val colorScheme = MaterialTheme.colorScheme
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val importJson = remember { Json { ignoreUnknownKeys = true } }
    var importError by remember { mutableStateOf<String?>(null) }

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
                onImportProject(project)
            } catch (e: Exception) {
                importError = "Could not import this file. Pick a RhymeAI project JSON."
            }
        }
    }

    var searchQuery by remember { mutableStateOf("") }
    val sortedProjects = projects.sortedByDescending { it.updatedAt }
    val filteredProjects = searchProjects(sortedProjects, searchQuery)
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

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .imePadding()
                .padding(24.dp),
            contentAlignment = Alignment.Center
        ) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                color = colorScheme.surfaceContainerLow,
                contentColor = colorScheme.onSurface,
                tonalElevation = 6.dp,
                border = BorderStroke(1.dp, colorScheme.outlineVariant)
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth()
                ) {
                // Header
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(20.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(Icons.Default.FolderOpen, null, tint = colorScheme.primary, modifier = Modifier.size(20.dp))
                        Text("Song Projects", fontWeight = FontWeight.Medium, fontSize = 18.sp, color = colorScheme.onSurface)
                    }
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, contentDescription = "Close", tint = colorScheme.onSurfaceVariant)
                    }
                }

                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f, false)
                        .padding(horizontal = 20.dp)
                        .padding(bottom = 20.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    item {
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
                            modifier = Modifier.fillMaxWidth(),
                            colors = textFieldColors,
                            shape = RoundedCornerShape(12.dp)
                        )
                    }

                    // New song button
                    item {
                        OutlinedButton(
                            onClick = onNewProject,
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(56.dp),
                            shape = RoundedCornerShape(12.dp),
                            border = BorderStroke(1.dp, colorScheme.outline)
                        ) {
                            Icon(Icons.Default.Add, null, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Create New Song", fontWeight = FontWeight.Medium)
                        }
                    }

                    // Import from file button
                    item {
                        OutlinedButton(
                            onClick = {
                                importError = null
                                importLauncher.launch(arrayOf("application/json", "*/*"))
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(56.dp),
                            shape = RoundedCornerShape(12.dp),
                            border = BorderStroke(1.dp, colorScheme.outlineVariant)
                        ) {
                            Icon(Icons.Default.FileOpen, null, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Import From File", fontWeight = FontWeight.Medium)
                        }
                        importError?.let {
                            Spacer(Modifier.height(8.dp))
                            Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
                        }
                    }

                    if (projects.isEmpty()) {
                        item {
                            Column(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Icon(Icons.Default.MusicNote, null, tint = colorScheme.onSurfaceVariant.copy(alpha = 0.45f), modifier = Modifier.size(48.dp))
                                Spacer(Modifier.height(16.dp))
                                Text("No saved songs yet.", color = colorScheme.onSurfaceVariant)
                            }
                        }
                    } else if (filteredProjects.isEmpty()) {
                        item {
                            Column(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Icon(Icons.Default.Search, null, tint = colorScheme.onSurfaceVariant.copy(alpha = 0.45f), modifier = Modifier.size(48.dp))
                                Spacer(Modifier.height(16.dp))
                                Text(
                                    if (isSearching) "No songs match your search." else "No saved songs yet.",
                                    color = colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    } else {
                        items(filteredProjects, key = { it.id }) { project ->
                            val isActive = project.id == currentProjectId
                            val dateStr = SimpleDateFormat("MMM d, yyyy", Locale.getDefault())
                                .format(Date(project.updatedAt))
                            val wordCount = SyllableCounter.wordCount(project.lyrics)

                            OutlinedCard(
                                onClick = { onLoadProject(project) },
                                modifier = Modifier
                                    .fillMaxWidth(),
                                shape = RoundedCornerShape(12.dp),
                                colors = CardDefaults.outlinedCardColors(
                                    containerColor = if (isActive) colorScheme.primaryContainer else colorScheme.surfaceContainer,
                                    contentColor = if (isActive) colorScheme.onPrimaryContainer else colorScheme.onSurface
                                ),
                                border = BorderStroke(
                                    1.dp,
                                    if (isActive) colorScheme.primary else colorScheme.outlineVariant
                                )
                            ) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(16.dp),
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
                                        modifier = Modifier.size(36.dp)
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
                    }
                }
                }
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
