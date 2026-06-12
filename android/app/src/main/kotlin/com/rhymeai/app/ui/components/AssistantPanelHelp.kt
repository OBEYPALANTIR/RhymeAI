package com.rhymeai.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.rhymePalette
import com.rhymeai.app.ui.theme.syllableColor

internal enum class FeatureLegend {
    SYLLABLES,
    RHYMES
}

internal enum class FeatureHelp(
    val title: String,
    val message: String,
    val legend: FeatureLegend? = null
) {
    CONTEXT_THEME(
        "Context & Theme",
        "Adds a short topic or mood for the assistant when Whole Song Context is off. Use it to steer the next line without sending the full lyric."
    ),
    TARGET_LINE(
        "Target Line",
        "The lyric line the assistant is matching. Put the cursor on a line when you want suggestions to rhyme with that exact sound."
    ),
    RHYME_SCHEME(
        "Rhyme Scheme",
        "Chooses the pattern the song should follow. Common patterns like AABB pair nearby lines, while Custom lets you type your own letter pattern."
    ),
    RHYME_DENSITY(
        "Rhyme Density",
        "Controls how tightly the suggestion should rhyme. Perfect is strict, Near gives a little room, and Slant is the most flexible."
    ),
    COMPLEXITY(
        "Complexity",
        "Changes how advanced the generated line should be. Higher complexity leans toward richer wording, multisyllable rhymes, and denser phrasing."
    ),
    WHOLE_SONG_CONTEXT(
        "Whole Song Context",
        "Uses the full current lyric as context so suggestions fit the story, tone, and previous lines. Turning it off uses only the theme and target line."
    ),
    HIGHLIGHT_RHYMES(
        "Highlight Rhymes",
        "Highlights rhyme words in suggestions so matching sounds are easier to spot before you insert a line."
    ),
    UNDERLINE_SYLLABLES(
        "Underline Syllables",
        "Draws colored underlines under words by syllable count. This keeps syllable cues visible while leaving rhyme colors free for rhyme families.",
        FeatureLegend.SYLLABLES
    ),
    STRESS_IPA(
        "Stress + IPA",
        "Shows dictionary-backed syllable stress and IPA previews for the target line and suggestions. Stressed syllables are shown as DA and unstressed syllables as da."
    ),
    COLOR_RHYMES(
        "Color Rhymes",
        "Colors words that share the same rhyme sound. Each color represents a rhyme family, so matching colors should rhyme or echo each other.",
        FeatureLegend.RHYMES
    ),
    BEAT_GRID(
        "Beat Grid",
        "Shows how many beats each line fills at the current BPM. Lines that fit within one bar are normal, tight lines use one extra beat of grace, and overflow lines exceed the bar in red."
    )
}

@Composable
internal fun FeatureHelpLabel(
    text: String,
    help: FeatureHelp,
    onHelp: (FeatureHelp) -> Unit,
    color: Color,
    fontSizeSp: Int = 13,
    fontWeight: FontWeight = FontWeight.Medium
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
    ) {
        Text(
            text = text,
            fontSize = fontSizeSp.sp,
            fontWeight = fontWeight,
            color = color
        )
        HelpButton(
            onClick = { onHelp(help) },
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            contentDescription = "$text help"
        )
    }
}

@Composable
private fun HelpButton(
    onClick: () -> Unit,
    tint: Color,
    contentDescription: String
) {
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(DesignTokens.Touch.minTarget)
            .semantics { this.contentDescription = contentDescription }
    ) {
        Icon(
            imageVector = Icons.AutoMirrored.Outlined.HelpOutline,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(20.dp)
        )
    }
}

@Composable
internal fun FeatureHelpDialog(
    help: FeatureHelp,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colorScheme.surfaceContainerHigh,
        titleContentColor = colorScheme.onSurface,
        textContentColor = colorScheme.onSurfaceVariant,
        title = {
            Text(help.title, fontWeight = FontWeight.SemiBold)
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)) {
                Text(help.message, fontSize = 14.sp, lineHeight = 20.sp)

                when (help.legend) {
                    FeatureLegend.SYLLABLES -> SyllableLegend()
                    FeatureLegend.RHYMES -> RhymeLegend()
                    null -> Unit
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("Got it")
            }
        }
    )
}

@Composable
private fun SyllableLegend() {
    val isDark = isSystemInDarkTheme()
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Underline colors", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurface)
        LegendRow(color = syllableColor(1, isDark), label = "1 syllable")
        LegendRow(color = syllableColor(2, isDark), label = "2 syllables")
        LegendRow(color = syllableColor(3, isDark), label = "3 syllables")
        LegendRow(color = syllableColor(4, isDark), label = "4+ syllables")
    }
}

@Composable
private fun RhymeLegend() {
    val palette = rhymePalette(isSystemInDarkTheme())
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Rhyme colors", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurface)
        Text(
            "Matching colors belong to the same rhyme family. New rhyme families get the next available color.",
            fontSize = 12.sp,
            lineHeight = 17.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            palette.take(6).forEach { color ->
                Box(
                    modifier = Modifier
                        .size(18.dp)
                        .background(color, CircleShape)
                        .border(1.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                )
            }
        }
    }
}

@Composable
private fun LegendRow(
    color: Color,
    label: String
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Box(
            modifier = Modifier
                .width(26.dp)
                .height(4.dp)
                .background(color, RoundedCornerShape(50))
        )
        Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
