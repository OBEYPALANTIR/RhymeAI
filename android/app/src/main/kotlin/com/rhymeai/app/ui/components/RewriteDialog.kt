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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import com.rhymeai.app.data.model.RewriteAction

@Composable
fun RewriteDialog(
    action: RewriteAction,
    original: String,
    preview: String?,
    loading: Boolean,
    error: String?,
    onApply: () -> Unit,
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
                        Icons.Default.AutoAwesome,
                        contentDescription = null,
                        tint = colorScheme.primary,
                        modifier = Modifier.size(20.dp)
                    )
                    Text(
                        text = action.label,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Medium,
                        color = colorScheme.onSurface
                    )
                }
                IconButton(onClick = onDismiss) {
                    Icon(
                        Icons.Default.Close,
                        contentDescription = "Close",
                        tint = colorScheme.onSurfaceVariant
                    )
                }
            }

            Spacer(Modifier.height(12.dp))

            Text(
                "Original",
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = colorScheme.onSurfaceVariant
            )
            Spacer(Modifier.height(4.dp))
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(colorScheme.surfaceContainer, RoundedCornerShape(8.dp))
                    .padding(12.dp)
            ) {
                Text(
                    original,
                    fontSize = 14.sp,
                    color = colorScheme.onSurface.copy(alpha = 0.8f),
                    lineHeight = 20.sp
                )
            }

            Spacer(Modifier.height(16.dp))

            Text(
                "Rewrite",
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = colorScheme.primary
            )
            Spacer(Modifier.height(4.dp))
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 80.dp)
                    .background(colorScheme.primary.copy(alpha = 0.08f), RoundedCornerShape(8.dp))
                    .border(1.dp, colorScheme.primary.copy(alpha = 0.3f), RoundedCornerShape(8.dp))
                    .padding(12.dp),
                contentAlignment = Alignment.CenterStart
            ) {
                when {
                    loading -> {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                color = colorScheme.primary,
                                strokeWidth = 2.dp
                            )
                            Text(
                                "Thinking...",
                                fontSize = 13.sp,
                                color = colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    error != null -> {
                        Text(
                            error,
                            fontSize = 13.sp,
                            color = colorScheme.error
                        )
                    }
                    preview != null -> {
                        Column(modifier = Modifier
                            .verticalScroll(rememberScrollState())
                            .heightIn(max = 240.dp)
                        ) {
                            Text(
                                preview,
                                fontSize = 14.sp,
                                color = colorScheme.onSurface,
                                lineHeight = 20.sp
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(20.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedButton(
                    onClick = onDismiss,
                    modifier = Modifier
                        .weight(1f)
                        .height(48.dp),
                    shape = RoundedCornerShape(12.dp)
                ) {
                    Text("Cancel", fontWeight = FontWeight.Medium)
                }
                Button(
                    onClick = onApply,
                    enabled = preview != null && !loading,
                    modifier = Modifier
                        .weight(1f)
                        .height(48.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = colorScheme.primary,
                        contentColor = colorScheme.onPrimary,
                        disabledContainerColor = colorScheme.surfaceContainer,
                        disabledContentColor = colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                    )
                ) {
                    Text("Apply", fontWeight = FontWeight.Medium)
                }
            }
        }
    }
}
