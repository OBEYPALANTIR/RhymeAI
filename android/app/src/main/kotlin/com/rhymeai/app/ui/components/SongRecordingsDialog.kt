package com.rhymeai.app.ui.components

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.service.VoiceMemo
import com.rhymeai.app.service.VoiceMemoService
import com.rhymeai.app.ui.theme.DesignTokens
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** A library bound to the song that opened it, including while the picker is away. */
@Composable
fun SongRecordingsDialog(
    projectId: String,
    songTitle: String,
    service: VoiceMemoService,
    onRecord: () -> Unit,
    onDismiss: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    var revision by remember(projectId) { mutableIntStateOf(0) }
    var importing by remember { mutableStateOf(false) }
    var search by rememberSaveable(projectId) { mutableStateOf("") }
    var selecting by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(emptySet<String>()) }
    var confirmBulkTrash by remember { mutableStateOf(false) }
    val memos by produceState<List<VoiceMemo>?>(null, projectId, revision, service.isRecording) {
        value = service.memosForProject(projectId)
    }
    DisposableEffect(service) { onDispose { service.stopPlayback() } }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            importing = true
            scope.launch {
                try {
                    service.importRecording(projectId, uri)
                    revision++
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    snackbar.showSnackbar("Could not import recording. Choose a playable M4A, MP3, WAV, or AAC file up to 100 MB.")
                } finally {
                    importing = false
                }
            }
        }
    }
    if (confirmBulkTrash) {
        AlertDialog(
            onDismissRequest = { confirmBulkTrash = false },
            title = { Text("Move recordings to Trash?") },
            text = { Text("${selected.size} recordings will stay in Trash Bin for 30 days.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmBulkTrash = false
                    scope.launch {
                        val results = memos.orEmpty().filter { it.file.absolutePath in selected }
                            .map { service.trashMemo(it) }
                        selected = emptySet()
                        selecting = false
                        revision++
                        if (results.any { it == null }) snackbar.showSnackbar("Some recordings could not be moved to Trash.")
                    }
                }) { Text("Move to Trash") }
            },
            dismissButton = { TextButton(onClick = { confirmBulkTrash = false }) { Text("Cancel") } }
        )
    }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(
            modifier = Modifier.widthIn(max = 640.dp).fillMaxWidth().fillMaxHeight(0.9f)
                .padding(DesignTokens.Spacing.lg),
            shape = MaterialTheme.shapes.extraLarge,
            color = MaterialTheme.colorScheme.surface
        ) {
            Column(Modifier.padding(DesignTokens.Spacing.lg).imePadding()) {
                Text("Recordings", style = MaterialTheme.typography.headlineSmall)
                Text(songTitle, style = MaterialTheme.typography.titleMedium)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton(onClick = { picker.launch(arrayOf("audio/*")) }, enabled = !importing) {
                        Text(if (importing) "Importing…" else "Import recording")
                    }
                    TextButton(onClick = onRecord, enabled = !service.isRecording && !importing) { Text("Record") }
                }
                OutlinedTextField(
                    value = search, onValueChange = { search = it },
                    label = { Text("Search recordings") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    if (selecting) {
                        TextButton(onClick = { confirmBulkTrash = true }, enabled = selected.isNotEmpty()) {
                            Text("Delete (${selected.size})")
                        }
                    }
                    TextButton(onClick = { selecting = !selecting; selected = emptySet() }, enabled = !memos.isNullOrEmpty()) {
                        Text(if (selecting) "Cancel selection" else "Select")
                    }
                }
                LazyColumn(Modifier.weight(1f).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                    val visible = memos.orEmpty().filter { VoiceMemoService.displayName(it.file).contains(search.trim(), ignoreCase = true) }
                    if (memos == null) item { CircularProgressIndicator() }
                    else if (visible.isEmpty()) item {
                        Text(if (search.isBlank()) "No recordings yet. Record or import audio for this song." else "No recordings match your search.")
                    }
                    items(visible, key = { it.file.absolutePath }) { memo ->
                        RecordingMemoRow(
                            memo = memo, service = service, isSelecting = selecting,
                            isSelected = memo.file.absolutePath in selected, snackbarHostState = snackbar,
                            onSelectionChanged = { checked ->
                                selected = if (checked) selected + memo.file.absolutePath else selected - memo.file.absolutePath
                            },
                            onMemoListChanged = { revision++ },
                            onTrashRequest = { target ->
                                scope.launch {
                                    val trashed = service.trashMemo(target)
                                    revision++
                                    if (trashed == null) snackbar.showSnackbar("Could not move recording to Trash.")
                                    else if (snackbar.showSnackbar("Recording moved to Trash", "Undo", duration = SnackbarDuration.Short) == SnackbarResult.ActionPerformed) {
                                        val restored = service.restoreTrashedMemo(trashed)
                                        revision++
                                        if (!restored) snackbar.showSnackbar("Could not restore recording.")
                                    }
                                }
                            }
                        )
                    }
                }
                SnackbarHost(snackbar)
                TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) { Text("Done") }
            }
        }
    }
}
