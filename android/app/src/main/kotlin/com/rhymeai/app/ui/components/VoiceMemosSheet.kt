package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.R
import com.rhymeai.app.service.VoiceMemo
import com.rhymeai.app.service.VoiceMemoService
import com.rhymeai.app.ui.theme.DesignTokens
import kotlinx.coroutines.delay

/**
 * Bottom sheet listing voice memos for the currently open project.
 *
 * [projectId] must be non-null — callers should only show this sheet when a project
 * is loaded. [service] is the VoiceMemoService owned by MainViewModel; we read its
 * observable state directly (isRecording, playingFile, recordingElapsedMs).
 */
@Composable
fun VoiceMemosSheet(
    projectId: String,
    service: VoiceMemoService,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    var visible by remember { mutableStateOf(false) }
    var hasEntered by remember { mutableStateOf(false) }

    // Re-load the memo list every time a recording stops or a delete happens.
    // We snapshot into local state so the list is stable while recomposing.
    var memos by remember(projectId) { mutableStateOf(service.memosForProject(projectId)) }

    // Refresh list when recording finishes (isRecording flips false→true is not interesting;
    // but false after true means a new file may exist).
    val isRecording = service.isRecording
    LaunchedEffect(isRecording) {
        if (!isRecording) {
            // Give the file system a moment to flush before listing.
            delay(80)
            memos = service.memosForProject(projectId)
        }
    }

    // Stop any active playback when this sheet closes.
    DisposableEffect(Unit) {
        onDispose {
            // Only stop if the file being played belongs to this project; another
            // sheet may be open for a different project in theory.
            val playing = service.playingFile
            if (playing != null) service.stopPlayback()
        }
    }

    fun requestDismiss() {
        if (!visible) return
        visible = false
    }

    LaunchedEffect(Unit) {
        visible = true
        hasEntered = true
    }

    LaunchedEffect(visible) {
        if (hasEntered && !visible) {
            delay(DesignTokens.Motion.dismissMillis.toLong())
            onDismiss()
        }
    }

    Dialog(
        onDismissRequest = { requestDismiss() },
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false
        )
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = DesignTokens.Spacing.lg)
        ) {
            AnimatedVisibility(
                visible = visible,
                enter = fadeIn(
                    animationSpec = tween(
                        durationMillis = DesignTokens.Motion.standardMillis,
                        easing = DesignTokens.Motion.emphasizedEasing
                    )
                ) + slideInVertically(
                    animationSpec = tween(
                        durationMillis = DesignTokens.Motion.standardMillis,
                        easing = DesignTokens.Motion.emphasizedEasing
                    ),
                    initialOffsetY = { it }
                ),
                exit = fadeOut(
                    animationSpec = tween(
                        durationMillis = DesignTokens.Motion.dismissMillis,
                        easing = DesignTokens.Motion.exitEasing
                    )
                ) + slideOutVertically(
                    animationSpec = tween(
                        durationMillis = DesignTokens.Motion.dismissMillis,
                        easing = DesignTokens.Motion.exitEasing
                    ),
                    targetOffsetY = { it }
                ),
                modifier = Modifier.align(Alignment.BottomCenter)
            ) {
                BottomSafeActionArea(
                    modifier = Modifier.fillMaxWidth(),
                    extra = DesignTokens.Spacing.xl
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(
                                colorScheme.surfaceContainerLow,
                                RoundedCornerShape(DesignTokens.Radius.xxl)
                            )
                            .border(
                                1.dp,
                                colorScheme.outlineVariant,
                                RoundedCornerShape(DesignTokens.Radius.xxl)
                            )
                            .padding(DesignTokens.Spacing.lg)
                    ) {
                        // Header row
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                            ) {
                                Icon(
                                    Icons.Default.Mic,
                                    contentDescription = null,
                                    tint = colorScheme.primary,
                                    modifier = Modifier.size(20.dp)
                                )
                                Text(
                                    stringResource(R.string.voice_memo_sheet_title),
                                    fontSize = 18.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = colorScheme.onSurface
                                )
                            }
                            IconButton(onClick = { requestDismiss() }) {
                                Icon(
                                    Icons.Default.Close,
                                    contentDescription = stringResource(R.string.rewrite_close_a11y),
                                    tint = colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        Spacer(Modifier.height(DesignTokens.Spacing.md))

                        // Record / stop-recording button
                        RecordButton(
                            isRecording = isRecording,
                            elapsedMs = service.recordingElapsedMs,
                            onStartRecord = { service.startRecording(projectId) },
                            onStopRecord = {
                                service.stopRecording()
                                memos = service.memosForProject(projectId)
                            }
                        )

                        Spacer(Modifier.height(DesignTokens.Spacing.md))

                        // Memo list
                        if (memos.isEmpty()) {
                            Text(
                                stringResource(R.string.voice_memo_empty),
                                fontSize = 13.sp,
                                color = colorScheme.onSurfaceVariant.copy(alpha = 0.65f),
                                lineHeight = 20.sp,
                                modifier = Modifier.padding(vertical = DesignTokens.Spacing.md)
                            )
                        } else {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    // Cap the list height so the sheet doesn't grow taller than ~40% of
                                    // a typical screen; the extra memos are scrollable.
                                    .height(240.dp)
                                    .verticalScroll(rememberScrollState()),
                                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                            ) {
                                memos.forEach { memo ->
                                    MemoRow(
                                        memo = memo,
                                        isPlaying = service.playingFile == memo.file,
                                        onPlay = { service.play(memo) },
                                        onStop = { service.stopPlayback() },
                                        onDelete = {
                                            service.deleteMemo(memo)
                                            memos = service.memosForProject(projectId)
                                        }
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

@Composable
private fun RecordButton(
    isRecording: Boolean,
    elapsedMs: Long,
    onStartRecord: () -> Unit,
    onStopRecord: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                colorScheme.surfaceContainerHigh,
                RoundedCornerShape(DesignTokens.Radius.lg)
            )
            .padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.sm),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
    ) {
        // Red pulsing dot during recording
        if (isRecording) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(colorScheme.error)
            )
        }

        Text(
            text = if (isRecording) {
                VoiceMemoService.formatDuration(elapsedMs)
            } else {
                "New voice memo"
            },
            fontSize = 14.sp,
            fontWeight = if (isRecording) FontWeight.Medium else FontWeight.Normal,
            color = if (isRecording) colorScheme.error else colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f)
        )

        IconButton(
            onClick = if (isRecording) onStopRecord else onStartRecord,
            modifier = Modifier
                .size(40.dp)
                .background(
                    color = if (isRecording) colorScheme.error else colorScheme.primary,
                    shape = CircleShape
                )
        ) {
            Icon(
                imageVector = if (isRecording) Icons.Default.Stop else Icons.Default.Mic,
                contentDescription = stringResource(
                    if (isRecording) R.string.voice_memo_stop_recording
                    else R.string.voice_memo_record
                ),
                tint = colorScheme.onPrimary,
                modifier = Modifier.size(20.dp)
            )
        }
    }
}

@Composable
private fun MemoRow(
    memo: VoiceMemo,
    isPlaying: Boolean,
    onPlay: () -> Unit,
    onStop: () -> Unit,
    onDelete: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                colorScheme.surfaceContainerHigh,
                RoundedCornerShape(DesignTokens.Radius.md)
            )
            .padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.xs),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Play/pause toggle
        IconButton(
            onClick = if (isPlaying) onStop else onPlay,
            modifier = Modifier.size(40.dp)
        ) {
            Icon(
                imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                contentDescription = stringResource(
                    if (isPlaying) R.string.voice_memo_pause else R.string.voice_memo_play
                ),
                tint = colorScheme.primary,
                modifier = Modifier.size(22.dp)
            )
        }

        Spacer(Modifier.width(DesignTokens.Spacing.xs))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = memo.label,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = colorScheme.onSurface,
                maxLines = 1
            )
            if (memo.durationMs > 0L) {
                Text(
                    text = VoiceMemoService.formatDuration(memo.durationMs),
                    fontSize = 11.sp,
                    color = colorScheme.onSurfaceVariant
                )
            }
        }

        IconButton(
            onClick = onDelete,
            modifier = Modifier.size(40.dp)
        ) {
            Icon(
                Icons.Default.Delete,
                contentDescription = stringResource(R.string.voice_memo_delete),
                tint = colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                modifier = Modifier.size(18.dp)
            )
        }
    }
}
