package com.rhymeai.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.ui.theme.DesignTokens

@Composable
fun RewriteChipBar(
    onAction: (RewriteAction) -> Unit,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(colorScheme.surfaceContainerHigh, RoundedCornerShape(DesignTokens.Radius.sheet))
            .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.sheet))
            .padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.sm)
            .horizontalScroll(rememberScrollState()),
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
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
        Spacer(Modifier.width(DesignTokens.Spacing.xs))
        RewriteAction.entries.forEach { action ->
            AssistChip(
                onClick = { onAction(action) },
                label = {
                    Text(
                        text = action.label,
                        fontSize = 12.sp,
                        maxLines = 1,
                        textAlign = TextAlign.Center
                    )
                },
                colors = AssistChipDefaults.assistChipColors(
                    containerColor = colorScheme.primary.copy(alpha = 0.12f),
                    labelColor = colorScheme.primary
                ),
                border = AssistChipDefaults.assistChipBorder(
                    enabled = true,
                    borderColor = colorScheme.primary.copy(alpha = 0.3f)
                ),
                modifier = Modifier
                    .heightIn(min = DesignTokens.Touch.minTarget)
                    .widthIn(min = 96.dp)
            )
        }
    }
}
