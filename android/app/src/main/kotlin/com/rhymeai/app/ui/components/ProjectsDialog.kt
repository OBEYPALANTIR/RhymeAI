package com.rhymeai.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.ui.theme.Indigo400
import com.rhymeai.app.ui.theme.Indigo500
import com.rhymeai.app.util.SyllableCounter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun ProjectsDialog(
    projects: List<SongProject>,
    currentProjectId: String?,
    onLoadProject: (SongProject) -> Unit,
    onNewProject: () -> Unit,
    onDeleteProject: (String) -> Unit,
    onDismiss: () -> Unit
) {
    var searchQuery by remember { mutableStateOf("") }
    val sortedProjects = projects.sortedByDescending { it.updatedAt }
    val filteredProjects = searchProjects(sortedProjects, searchQuery)
    val isSearching = searchQuery.isNotBlank()
    val textFieldColors = OutlinedTextFieldDefaults.colors(
        unfocusedBorderColor = Color.White.copy(alpha = 0.14f),
        focusedBorderColor = Indigo400.copy(alpha = 0.7f),
        unfocusedContainerColor = Color.White.copy(alpha = 0.05f),
        focusedContainerColor = Color.White.copy(alpha = 0.06f),
        cursorColor = Indigo400,
        unfocusedTextColor = Color.White,
        focusedTextColor = Color.White,
        unfocusedPlaceholderColor = Color.White.copy(alpha = 0.35f),
        focusedPlaceholderColor = Color.White.copy(alpha = 0.35f),
        unfocusedLeadingIconColor = Color.White.copy(alpha = 0.35f),
        focusedLeadingIconColor = Indigo400
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
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color(0xFF111111), RoundedCornerShape(16.dp))
                    .border(1.dp, Color.White.copy(alpha = 0.1f), RoundedCornerShape(16.dp))
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
                        Icon(Icons.Default.FolderOpen, null, tint = Indigo400, modifier = Modifier.size(20.dp))
                        Text("Song Projects", fontWeight = FontWeight.Medium, fontSize = 18.sp, color = Color.White)
                    }
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, null, tint = Color.White.copy(alpha = 0.5f))
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
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .border(
                                    2.dp,
                                    Color.White.copy(alpha = 0.2f),
                                    RoundedCornerShape(12.dp)
                                )
                                .clickable(onClick = onNewProject)
                                .padding(16.dp),
                            horizontalArrangement = Arrangement.Center,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(Icons.Default.Add, null, tint = Color.White.copy(alpha = 0.7f), modifier = Modifier.size(20.dp))
                            Text("  Create New Song", color = Color.White.copy(alpha = 0.7f), fontWeight = FontWeight.Medium)
                        }
                    }

                    if (projects.isEmpty()) {
                        item {
                            Column(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Icon(Icons.Default.MusicNote, null, tint = Color.White.copy(alpha = 0.2f), modifier = Modifier.size(48.dp))
                                Spacer(Modifier.height(16.dp))
                                Text("No saved songs yet.", color = Color.White.copy(alpha = 0.3f))
                            }
                        }
                    } else if (filteredProjects.isEmpty()) {
                        item {
                            Column(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Icon(Icons.Default.Search, null, tint = Color.White.copy(alpha = 0.2f), modifier = Modifier.size(48.dp))
                                Spacer(Modifier.height(16.dp))
                                Text(
                                    if (isSearching) "No songs match your search." else "No saved songs yet.",
                                    color = Color.White.copy(alpha = 0.3f)
                                )
                            }
                        }
                    } else {
                        items(filteredProjects, key = { it.id }) { project ->
                            val isActive = project.id == currentProjectId
                            val dateStr = SimpleDateFormat("MMM d, yyyy", Locale.getDefault())
                                .format(Date(project.updatedAt))
                            val wordCount = SyllableCounter.wordCount(project.lyrics)

                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .background(
                                        if (isActive) Indigo500.copy(alpha = 0.1f)
                                        else Color.White.copy(alpha = 0.05f),
                                        RoundedCornerShape(12.dp)
                                    )
                                    .border(
                                        1.dp,
                                        if (isActive) Indigo500.copy(alpha = 0.5f)
                                        else Color.White.copy(alpha = 0.05f),
                                        RoundedCornerShape(12.dp)
                                    )
                                    .clickable { onLoadProject(project) }
                                    .padding(16.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        project.title.ifEmpty { "Untitled Song" },
                                        fontWeight = FontWeight.Medium,
                                        color = Color.White,
                                        maxLines = 1
                                    )
                                    Text(
                                        "$dateStr \u2022 $wordCount words",
                                        fontSize = 13.sp,
                                        color = Color.White.copy(alpha = 0.4f)
                                    )
                                }
                                IconButton(
                                    onClick = { onDeleteProject(project.id) },
                                    modifier = Modifier
                                        .size(36.dp)
                                        .background(Color.Transparent, CircleShape)
                                ) {
                                    Icon(
                                        Icons.Default.Delete,
                                        contentDescription = "Delete",
                                        tint = Color.White.copy(alpha = 0.3f),
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
