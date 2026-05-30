package com.rhymeai.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.ui.theme.DesignTokens

@Composable
fun RewriteChipBar(
    onAction: (RewriteAction) -> Unit,
    onInspect: (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    Row(
        modifier = modifier
            .fillMaxWidth()
            .testTag("rewriteChipBar")
            .background(colorScheme.surfaceContainerHigh, RoundedCornerShape(DesignTokens.Radius.sheet))
            .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.sheet))
            .padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.sm)
            .heightIn(min = DesignTokens.Touch.minTarget + DesignTokens.Spacing.lg),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
    ) {
        if (onInspect != null) {
            // Single-word selection: the leading affordance is a look-up button
            // into the Word Inspector. Multi-word selections omit it (look-up is
            // per-word), letting the rewrite actions fill the bar.
            Surface(
                modifier = Modifier
                    .size(DesignTokens.Touch.minTarget)
                    .testTag("inspectAction")
                    .clickable(onClick = onInspect),
                shape = RoundedCornerShape(DesignTokens.Radius.pill),
                color = colorScheme.primary.copy(alpha = 0.12f),
                contentColor = colorScheme.primary,
                border = BorderStroke(1.dp, colorScheme.primary.copy(alpha = 0.3f))
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        Icons.Default.Search,
                        contentDescription = "Look up word",
                        modifier = Modifier.size(18.dp)
                    )
                }
            }
        }

        RewriteAction.entries.forEach { action ->
            RewriteActionButton(
                action = action,
                onClick = { onAction(action) },
                modifier = Modifier.weight(1f)
            )
        }
    }
}

@Composable
private fun RewriteActionButton(
    action: RewriteAction,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    Surface(
        modifier = modifier
            .height(DesignTokens.Touch.minTarget)
            .clickable(onClick = onClick),
        shape = RoundedCornerShape(DesignTokens.Radius.pill),
        color = colorScheme.primary.copy(alpha = 0.12f),
        contentColor = colorScheme.primary,
        border = BorderStroke(1.dp, colorScheme.primary.copy(alpha = 0.3f))
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.xs),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = action.label,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}
