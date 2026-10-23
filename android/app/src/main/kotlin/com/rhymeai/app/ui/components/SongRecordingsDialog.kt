package com.rhymeai.app.ui.components

import android.content.Context
import android.provider.DocumentsContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.testTag
import com.rhymeai.app.service.VoiceMemo
import com.rhymeai.app.service.VoiceMemoService
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.appWritingSurface
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * The system picker opens on Recent, which skips the media Audio root (it has no FLAG_SUPPORTS_RECENTS),
 * so a first import showed an empty "No items" screen on devices full of audio. Start on Audio instead.
 */
internal object OpenAudioDocument : ActivityResultContracts.OpenDocument() {
    val audioRoot = DocumentsContract.buildRootUri("com.android.providers.media.documents", "audio_root")
    override fun createIntent(context: Context, input: Array<String>) =
        super.createIntent(context, input).putExtra(DocumentsContract.EXTRA_INITIAL_URI, audioRoot)
}

/** A library bound to the song that opened it, including while the picker is away. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SongRecordingsDialog(
    projectId: String,
    songTitle: String,
    service: VoiceMemoService,
    onDismiss: () -> Unit
) {
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var isClosing by remember { mutableStateOf(false) }
    var didFinish by remember { mutableStateOf(false) }

    fun finishClose() {
        if (didFinish) return
        didFinish = true
        onDismiss()
    }

    fun closeSheet() {
        if (isClosing || didFinish) return
        isClosing = true
        scope.launch {
            try {
                sheetState.hide()
            } finally {
                if (!sheetState.isVisible) finishClose()
                else isClosing = false
            }
        }
    }

    var revision by remember(projectId) { mutableIntStateOf(0) }
    var importing by remember { mutableStateOf(false) }
    var search by rememberSaveable(projectId) { mutableStateOf("") }
    var selecting by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(emptySet<String>()) }
    var confirmBulkTrash by remember { mutableStateOf(false) }
    var listFailed by remember { mutableStateOf(false) }
    val memos by produceState<List<VoiceMemo>?>(null, projectId, revision, service.isRecording) {
        // Fails closed: if what is deleted cannot be read, nothing is listed (A28/A31).
        value = try {
            service.memosForProject(projectId).also { listFailed = false }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            listFailed = true
            emptyList()
        }
    }
    LaunchedEffect(service) { service.deletionChanges.collect { revision++ } }
    // A27: finished takes whose save failed stay listed here until Retry saves them.
    val waitingTakes by produceState(emptyList<VoiceMemoService.WaitingTake>(), projectId, revision, service.isRecording) {
        value = try {
            service.waitingTakes(projectId)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // A staging folder that cannot be read is reported, never shown as no waiting takes.
            listFailed = true
            value
        }
    }
    val waiting = waitingTakes.count { it.finished }
    val unsaved = waitingTakes.size - waiting
    DisposableEffect(service) { onDispose { service.stopPlayback() } }
    val picker = rememberLauncherForActivityResult(OpenAudioDocument) { uri ->
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
                        if (results.any { it == null }) snackbar.showSnackbar("Some recordings could not be moved to Trash. Check free storage, then try again.")
                    }
                }) { Text("Move to Trash") }
            },
            dismissButton = { TextButton(onClick = { confirmBulkTrash = false }) { Text("Cancel") } }
        )
    }
    ModalBottomSheet(
        onDismissRequest = ::finishClose,
        sheetState = sheetState,
        sheetMaxWidth = DesignTokens.Drawer.expandedWidth,
        shape = RoundedCornerShape(topStart = DesignTokens.Radius.sheet, topEnd = DesignTokens.Radius.sheet),
        containerColor = MaterialTheme.colorScheme.background
    ) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(0.9f).appWritingSurface().padding(DesignTokens.Spacing.lg)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Recordings", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                TextButton(onClick = { closeSheet() }, modifier = Modifier.testTag("recordingsDone")) { Text("Done") }
            }
            Spacer(Modifier.height(DesignTokens.Spacing.sm))
            OutlinedTextField(
                value = search, onValueChange = { search = it },
                label = { Text("Search recordings") }, singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            if (waitingTakes.isNotEmpty()) Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    listOfNotNull(
                        waiting.takeIf { it > 0 }?.let { if (it == 1) "1 recording waiting to be saved" else "$it recordings waiting to be saved" },
                        unsaved.takeIf { it > 0 }?.let { if (it == 1) "1 recording could not be saved" else "$it recordings could not be saved" }
                    ).joinToString(" · "),
                    style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.weight(1f)
                )
                TextButton(
                    onClick = {
                        scope.launch {
                            try {
                                service.retryWaitingTakes(projectId)
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (_: Exception) {
                                snackbar.showSnackbar("Couldn't save the recording. Free up storage, then tap Retry.")
                            } finally {
                                revision++
                            }
                        }
                    },
                    modifier = Modifier.testTag("retryWaitingTakes")
                ) { Text("Retry") }
            }
            TextButton(
                onClick = { picker.launch(arrayOf("audio/*")) },
                enabled = !importing && !isClosing,
                modifier = Modifier.fillMaxWidth().testTag("importRecording")
            ) { Text(if (importing) "Importing…" else "Import Recording") }
            if (!memos.isNullOrEmpty()) FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
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
                val visible = memos.orEmpty().filter { VoiceMemoService.displayLabel(it.displayName).contains(search.trim(), ignoreCase = true) }
                if (memos == null) item { CircularProgressIndicator() }
                else if (visible.isEmpty()) item {
                    Text(when {
                        listFailed -> "Recordings could not be read. Close and reopen this sheet to try again."
                        search.isBlank() -> "No recordings yet. Record or import audio for this song."
                        else -> "No recordings match your search."
                    })
                }
                if (visible.isNotEmpty()) item {
                    Column(Modifier.padding(vertical = DesignTokens.Spacing.sm)) {
                        Text(songTitle, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(
                            "${visible.size} ${if (visible.size == 1) "recording" else "recordings"}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
                items(visible, key = { it.file.absolutePath }) { memo ->
                    RecordingMemoRow(
                        memo = memo, service = service, isSelecting = selecting,
                        isSelected = memo.file.absolutePath in selected, snackbarHostState = snackbar, actionScope = scope,
                        onSelectionChanged = { checked ->
                            selected = if (checked) selected + memo.file.absolutePath else selected - memo.file.absolutePath
                        },
                        onMemoListChanged = { revision++ },
                        onTrashRequest = { target ->
                            scope.launch {
                                val trashed = service.trashMemo(target)
                                revision++
                                if (trashed == null) snackbar.showSnackbar("Could not move recording to Trash. Check free storage, then try again.")
                                else if (snackbar.showSnackbar("Recording moved to Trash", "Undo", duration = SnackbarDuration.Short) == SnackbarResult.ActionPerformed) {
                                    val restored = service.restoreTrashedMemo(trashed)
                                    revision++
                                    if (!restored) snackbar.showSnackbar("Could not restore recording; it is still in Trash. Check free storage, then try again.")
                                }
                            }
                        }
                    )
                }
            }
            SnackbarHost(snackbar)
        }
    }
}
