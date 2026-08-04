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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.colorSchemeFor

@Composable
internal fun AppearanceSelector(
    currentAppearance: AppAppearance,
    onAppearanceChange: (AppAppearance) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier) {
        Text(
            text = "Appearance",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(Modifier.height(DesignTokens.Spacing.sm))
        SlidingSegmentedControl(
            labels = AppAppearance.entries.map(AppAppearance::displayName),
            selectedIndex = AppAppearance.entries.indexOf(currentAppearance),
            onSelect = { onAppearanceChange(AppAppearance.entries[it]) },
            modifier = Modifier
                .fillMaxWidth()
                .testTag("appearanceSelector")
                .semantics { stateDescription = currentAppearance.displayName }
        )
        Spacer(Modifier.height(DesignTokens.Spacing.sm))
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
        ) {
            AppAppearance.entries.forEach { appearance ->
                val preview = colorSchemeFor(appearance)
                val selected = appearance == currentAppearance
                val shape = RoundedCornerShape(DesignTokens.Radius.sm)
                Column(
                    modifier = Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(40.dp)
                            .testTag("appearancePreview${appearance.displayName}")
                            .semantics {
                                contentDescription = "${appearance.displayName} appearance preview"
                                stateDescription = if (selected) "Selected" else "Not selected"
                            }
                            .clip(shape)
                            .background(preview.background)
                            .border(
                                width = if (selected) 2.dp else 1.dp,
                                color = if (selected) preview.primary else preview.outline,
                                shape = shape
                            )
                            .padding(DesignTokens.Spacing.xs)
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                        ) {
                            Box(
                                Modifier
                                    .weight(1f)
                                    .height(28.dp)
                                    .background(
                                        preview.surface,
                                        RoundedCornerShape(DesignTokens.Radius.xs)
                                    )
                            )
                            Box(
                                Modifier
                                    .weight(0.22f)
                                    .height(28.dp)
                                    .background(
                                        preview.onSurface,
                                        RoundedCornerShape(DesignTokens.Radius.xs)
                                    )
                            )
                            Box(
                                Modifier
                                    .weight(0.55f)
                                    .height(28.dp)
                                    .background(
                                        preview.primary,
                                        RoundedCornerShape(DesignTokens.Radius.xs)
                                    )
                            )
                        }
                    }
                    Spacer(Modifier.height(DesignTokens.Spacing.xs))
                    Text(
                        text = appearance.displayName,
                        style = MaterialTheme.typography.labelSmall,
                        color = if (selected) {
                            MaterialTheme.colorScheme.onSurface
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal
                    )
                }
            }
        }
    }
}
