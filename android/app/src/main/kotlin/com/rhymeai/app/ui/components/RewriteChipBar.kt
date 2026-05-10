package com.rhymeai.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.data.model.RewriteAction

@Composable
fun RewriteChipBar(
    onAction: (RewriteAction) -> Unit,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(colorScheme.surfaceContainerHigh, RoundedCornerShape(20.dp))
            .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(20.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .horizontalScroll(rememberScrollState()),
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Icon(
            Icons.Default.AutoAwesome,
            contentDescription = null,
            tint = colorScheme.primary,
            modifier = Modifier.size(16.dp)
        )
        Text(
            text = "Rewrite:",
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            color = colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.width(4.dp))
        RewriteAction.entries.forEach { action ->
            AssistChip(
                onClick = { onAction(action) },
                label = { Text(action.label, fontSize = 12.sp) },
                colors = AssistChipDefaults.assistChipColors(
                    containerColor = colorScheme.primary.copy(alpha = 0.12f),
                    labelColor = colorScheme.primary
                ),
                border = AssistChipDefaults.assistChipBorder(
                    enabled = true,
                    borderColor = colorScheme.primary.copy(alpha = 0.3f)
                ),
                modifier = Modifier.height(32.dp)
            )
        }
    }
}
