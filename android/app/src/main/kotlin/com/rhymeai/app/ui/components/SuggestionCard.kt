package com.rhymeai.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.util.SyllableCounter
import com.rhymeai.app.ui.theme.DesignTokens

private val lastWordPattern = Regex("(.*?)(\\b\\w+\\b)([^\\w]*)\$")

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SuggestionCard(
    suggestion: String,
    highlightRhyme: Boolean,
    showProsody: Boolean,
    onUse: () -> Unit,
    modifier: Modifier = Modifier,
    /** 2 = perfect/multi, 1 = near, 0 = unverified. Drives the tier pill badge. */
    rhymeTier: Int = 0,
    /** True when this line repeats a first-chorus end-word; badge reads "hook". */
    isHook: Boolean = false,
    onKeep: (() -> Unit)? = null,
    isKept: Boolean = false
) {
    val colorScheme = MaterialTheme.colorScheme

    OutlinedCard(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = DesignTokens.Touch.minTarget),
        shape = RoundedCornerShape(DesignTokens.Radius.lg),
        colors = CardDefaults.outlinedCardColors(
            containerColor = colorScheme.surfaceContainer,
            contentColor = colorScheme.onSurface
        ),
        border = BorderStroke(1.dp, colorScheme.outlineVariant)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DesignTokens.Spacing.lg),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
        // Suggestion text with optional rhyme highlight
        val annotated = if (highlightRhyme) {
            val match = lastWordPattern.find(suggestion)
            if (match != null) {
                buildAnnotatedString {
                    withStyle(SpanStyle(color = colorScheme.onSurface)) {
                        append(match.groupValues[1])
                    }
                    withStyle(SpanStyle(
                        color = colorScheme.primary,
                        fontWeight = FontWeight.Medium,
                        textDecoration = TextDecoration.Underline
                    )) {
                        append(match.groupValues[2])
                    }
                    withStyle(SpanStyle(color = colorScheme.onSurface)) {
                        append(match.groupValues[3])
                    }
                }
            } else {
                buildAnnotatedString {
                    withStyle(SpanStyle(color = colorScheme.onSurface)) {
                        append(suggestion)
                    }
                }
            }
        } else {
            buildAnnotatedString {
                withStyle(SpanStyle(color = colorScheme.onSurface)) {
                    append(suggestion)
                }
            }
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
        ) {
            Text(
                text = annotated,
                fontFamily = FontFamily.Serif,
                fontSize = 14.sp,
                lineHeight = 20.sp
            )
            if (showProsody) {
                ProsodyPreview(text = suggestion)
            }
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
        ) {
            // Syllable count badge
            Surface(
                shape = RoundedCornerShape(DesignTokens.Radius.xs),
                color = colorScheme.surfaceContainerHigh,
                contentColor = colorScheme.onSurfaceVariant
            ) {
                Text(
                    text = "${SyllableCounter.countText(suggestion)}",
                    fontFamily = FontFamily.Monospace,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(horizontal = DesignTokens.Spacing.sm, vertical = DesignTokens.Spacing.xs)
                )
            }
            // Rhyme tier pill — "hook" for chorus repeats, "perfect" for tier 2,
            // "near" for tier 1; nothing for unverified (tier 0).
            val tierLabel = when {
                isHook -> "hook"
                rhymeTier >= 2 -> "perfect"
                rhymeTier == 1 -> "near"
                else -> null
            }
            if (tierLabel != null) {
                Text(
                    text = tierLabel,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    color = colorScheme.onTertiaryContainer,
                    modifier = Modifier
                        .background(
                            colorScheme.tertiaryContainer,
                            RoundedCornerShape(4.dp)
                        )
                        .padding(horizontal = DesignTokens.Spacing.xs, vertical = 2.dp)
                )
            }
        }
        }
        FlowRow(
            modifier = Modifier.fillMaxWidth().padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.xs),
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
        ) {
            FilledTonalButton(onClick = onUse, modifier = Modifier.heightIn(min = DesignTokens.Touch.minTarget)) {
                Text("Use line")
            }
            onKeep?.let { keep ->
                TextButton(onClick = keep, enabled = !isKept, modifier = Modifier.heightIn(min = DesignTokens.Touch.minTarget)) {
                    Text(if (isKept) "Kept" else "Keep for later")
                }
            }
        }
    }
}
