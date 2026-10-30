package com.rhymeai.app.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.data.model.DraftVersion
import com.rhymeai.app.data.model.LyricAlternate
import com.rhymeai.app.ui.theme.DesignTokens
import java.text.DateFormat
import java.util.Date

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SongNotebookSheet(viewModel: MainViewModel, onDismiss: () -> Unit) {
    var versionsSelected by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<DraftVersion?>(null) }
    var removing by remember { mutableStateOf<LyricAlternate?>(null) }
    val clipboard = LocalClipboardManager.current
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        modifier = Modifier.statusBarsPadding(),
        contentWindowInsets = {
            WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)
        }
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.72f)
                .padding(horizontal = DesignTokens.Spacing.xl)
                .testTag("songNotebookSheetContent")
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Song Notebook", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("Close") }
            }
            Text("Saved on this device for this song.", style = MaterialTheme.typography.bodySmall)
            TabRow(selectedTabIndex = if (versionsSelected) 1 else 0) {
                Tab(selected = !versionsSelected, onClick = { versionsSelected = false }, text = { Text("Alternates") })
                Tab(selected = versionsSelected, onClick = { versionsSelected = true }, text = { Text("Draft History") })
            }
            viewModel.notebookError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (versionsSelected) {
                TextButton(onClick = viewModel::saveDraftVersion, enabled = viewModel.notebookError == null && !viewModel.restoringDraft) { Text("Save version") }
            } else {
                TextButton(onClick = viewModel::keepSelectedLyrics, enabled = viewModel.notebookError == null && !(viewModel.pendingRewriteRange ?: viewModel.lyricsFieldValue.selection).collapsed) { Text("Keep selected lyrics") }
            }
            LazyColumn(
                Modifier
                    .fillMaxWidth()
                    .weight(1f),
                contentPadding = PaddingValues(bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                if (versionsSelected) {
                    if (viewModel.songWorkspace.versions.isEmpty()) item { Text("Save a version to keep a draft you can return to. Earlier drafts are also kept as you write and leave a song.") }
                    items(viewModel.songWorkspace.versions, key = { it.id }) { version ->
                        OutlinedCard(onClick = { preview = version }, modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(version.createdAt)), style = MaterialTheme.typography.labelLarge)
                                Text(version.title.ifBlank { "Untitled Song" }, style = MaterialTheme.typography.titleMedium)
                                Text(version.lyrics.ifBlank { "No lyrics" }, maxLines = 3, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                                Text("Preview version", style = MaterialTheme.typography.labelLarge)
                            }
                        }
                    }
                } else {
                    if (viewModel.songWorkspace.alternates.isEmpty()) item { Text("Keep suggestions or selected lyrics here without changing your draft.") }
                    items(viewModel.songWorkspace.alternates, key = { it.id }) { alternate ->
                        OutlinedCard(Modifier.fillMaxWidth()) {
                            Column(Modifier.padding(16.dp)) {
                                Text(alternate.text)
                                FlowRow {
                                    TextButton(onClick = { clipboard.setText(AnnotatedString(alternate.text)) }) { Text("Copy") }
                                    TextButton(onClick = { if (viewModel.insertSuggestion(alternate.text)) onDismiss() }) { Text("Insert at cursor") }
                                    TextButton(onClick = { removing = alternate }) { Text("Remove") }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    preview?.let { version ->
        AlertDialog(onDismissRequest = { preview = null }, title = { Text("Draft preview") }, text = {
            androidx.compose.foundation.rememberScrollState().let { scroll ->
                Column(Modifier.heightIn(max = 360.dp).then(Modifier.verticalScroll(scroll))) {
                    viewModel.notebookError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    Text(version.title.ifBlank { "Untitled Song" }, style = MaterialTheme.typography.titleMedium)
                    Text(version.lyrics.ifBlank { "No lyrics" })
                    Text("Restoring keeps your current draft as another version.", style = MaterialTheme.typography.bodySmall)
                }
            }
        }, confirmButton = { TextButton(enabled = viewModel.notebookError == null && !viewModel.restoringDraft, onClick = { viewModel.restoreDraftVersion(version) { preview = null; onDismiss() } }) { Text("Restore version") } }, dismissButton = { TextButton(onClick = { preview = null }) { Text("Cancel") } })
    }
    removing?.let { alternate ->
        AlertDialog(onDismissRequest = { removing = null }, title = { Text("Remove alternate?") }, text = { Text("This removes the saved alternate from this song.") }, confirmButton = { TextButton(onClick = { viewModel.removeAlternate(alternate.id); removing = null }) { Text("Remove") } }, dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } })
    }
}
