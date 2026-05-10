package com.rhymeai.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.rhymeai.app.data.model.ExportFormat

@Composable
fun ExportSheet(
    onPick: (ExportFormat) -> Unit,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme

    Dialog(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(colorScheme.surfaceContainerLow, RoundedCornerShape(16.dp))
                .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(16.dp))
                .padding(20.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
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
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = colorScheme.onSurfaceVariant)
                }
            }

            Spacer(Modifier.height(8.dp))
            Text(
                "Pick a format. Save anywhere — Drive, Files, local — via the system picker.",
                fontSize = 12.sp,
                color = colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                lineHeight = 16.sp
            )

            Spacer(Modifier.height(16.dp))

            ExportFormat.entries.forEach { format ->
                FormatRow(
                    format = format,
                    icon = iconFor(format),
                    onClick = { onPick(format) }
                )
                Spacer(Modifier.height(8.dp))
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
            .height(64.dp),
        shape = RoundedCornerShape(12.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .background(colorScheme.primary.copy(alpha = 0.12f), RoundedCornerShape(8.dp)),
                contentAlignment = Alignment.Center
            ) {
                Icon(icon, contentDescription = null, tint = colorScheme.primary, modifier = Modifier.size(20.dp))
            }
            Column(modifier = Modifier.weight(1f)) {
                Text(format.label, fontWeight = FontWeight.Medium, fontSize = 14.sp, color = colorScheme.onSurface)
                Text(
                    format.description,
                    fontSize = 11.sp,
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
