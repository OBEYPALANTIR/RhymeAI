package com.rhymeai.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.rhymeai.app.ui.theme.DesignTokens

@Composable
fun EditorUndoRedoControls(
    canUndo: Boolean,
    canRedo: Boolean,
    undoContentDescription: String,
    redoContentDescription: String,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
    ) {
        HistoryButton(
            icon = Icons.AutoMirrored.Filled.Undo,
            contentDescription = undoContentDescription,
            testTag = "undoLyricsButton",
            enabled = canUndo,
            onClick = onUndo
        )
        HistoryButton(
            icon = Icons.AutoMirrored.Filled.Redo,
            contentDescription = redoContentDescription,
            testTag = "redoLyricsButton",
            enabled = canRedo,
            onClick = onRedo
        )
    }
}

@Composable
private fun HistoryButton(
    icon: ImageVector,
    contentDescription: String,
    testTag: String,
    enabled: Boolean,
    onClick: () -> Unit
) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        border = BorderStroke(
            1.dp,
            MaterialTheme.colorScheme.outlineVariant
        )
    ) {
        IconButton(
            onClick = onClick,
            enabled = enabled,
            modifier = Modifier
                .size(DesignTokens.Touch.minTarget)
                .testTag(testTag)
        ) {
            Icon(icon, contentDescription = contentDescription)
        }
    }
}
