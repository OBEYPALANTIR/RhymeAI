package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.data.model.ExportFormat
import com.rhymeai.app.ui.theme.DesignTokens
import kotlinx.coroutines.delay

@Composable
fun ExportSheet(
    onPick: (ExportFormat) -> Unit,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    var visible by remember { mutableStateOf(false) }
    var hasEntered by remember { mutableStateOf(false) }
    var pendingPick by remember { mutableStateOf<ExportFormat?>(null) }

    fun requestDismiss(format: ExportFormat? = null) {
        if (!visible) return
        pendingPick = format
        visible = false
    }

    LaunchedEffect(Unit) {
        visible = true
        hasEntered = true
    }

    LaunchedEffect(visible) {
        if (hasEntered && !visible) {
            delay(DesignTokens.Motion.dismissMillis.toLong())
            pendingPick?.let(onPick) ?: onDismiss()
        }
    }

    Dialog(
        onDismissRequest = { requestDismiss() },
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false
        )
    ) {
        EdgeToEdgeDialogEffect()
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
                modifier = Modifier
                    .align(Alignment.BottomCenter)
            ) {
                BottomSafeActionArea(
                    modifier = Modifier.fillMaxWidth(),
                    extra = DesignTokens.Spacing.xxl
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(colorScheme.surfaceContainerLow, RoundedCornerShape(DesignTokens.Radius.xxl))
                            .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.xxl))
                            .padding(DesignTokens.Spacing.lg)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                            ) {
                                Icon(
                                    Icons.Default.IosShare,
                                    contentDescription = null,
                                    tint = colorScheme.primary,
                                    modifier = Modifier.size(20.dp)
                                )
                                Text(
                                    "Export Song",
                                    fontSize = 18.sp,
                                    fontWeight = FontWeight.Medium,
                                    color = colorScheme.onSurface
                                )
                            }
                            IconButton(onClick = { requestDismiss() }) {
                                Icon(Icons.Default.Close, contentDescription = "Close", tint = colorScheme.onSurfaceVariant)
                            }
                        }

                        Spacer(Modifier.height(DesignTokens.Spacing.sm))
                        Text(
                            "Pick a format. Save anywhere — Drive, Files, local — via the system picker.",
                            fontSize = 12.sp,
                            color = colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                            lineHeight = 16.sp
                        )

                        Spacer(Modifier.height(DesignTokens.Spacing.lg))

                        ExportFormat.entries.forEach { format ->
                            FormatRow(
                                format = format,
                                icon = iconFor(format),
                                onClick = { requestDismiss(format) }
                            )
                            Spacer(Modifier.height(DesignTokens.Spacing.sm))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FormatRow(
    format: ExportFormat,
    icon: ImageVector,
    onClick: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    OutlinedButton(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 64.dp),
        shape = RoundedCornerShape(DesignTokens.Radius.lg)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .background(colorScheme.primary.copy(alpha = 0.12f), RoundedCornerShape(DesignTokens.Radius.sm)),
                contentAlignment = Alignment.Center
            ) {
                Icon(icon, contentDescription = null, tint = colorScheme.primary, modifier = Modifier.size(20.dp))
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(format.label, fontWeight = FontWeight.Medium, fontSize = 14.sp, color = colorScheme.onSurface)
                Text(
                    format.description,
                    fontSize = 12.sp,
                    color = colorScheme.onSurfaceVariant,
                    lineHeight = 14.sp
                )
            }
        }
    }
}

private fun iconFor(format: ExportFormat): ImageVector = when (format) {
    ExportFormat.TXT -> Icons.Default.Description
    ExportFormat.JSON -> Icons.Default.Description
    ExportFormat.PDF -> Icons.Default.PictureAsPdf
    ExportFormat.LRC -> Icons.Default.MusicNote
}
