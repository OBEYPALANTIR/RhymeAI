package com.rhymeai.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import com.rhymeai.app.ui.theme.LocalAppAppearance
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
        "Adds a short topic or mood that steers the next line. It is sent with every suggestion request, together with the full lyric when Whole Song Context is on. Leave it empty and the assistant works from the lyrics alone."
    ),
    TARGET_LINE(
        "Target Line",
        "The earlier line the next suggestion has to rhyme with, picked by your rhyme scheme for the line being added. It is empty when the next line starts a new rhyme sound."
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
        "Changes how advanced the suggested lines should be. Simple keeps the language plain with no wordplay, Moderate uses a balanced vocabulary, and Complex asks for clever wordplay and intricate rhymes."
    ),
    WHOLE_SONG_CONTEXT(
        "Whole Song Context",
        "Uses the full current lyric as context so suggestions fit the story, tone, and previous lines. Turning it off uses only the theme and target line."
    ),
    HIGHLIGHT_RHYMES(
        "Suggestion Rhymes",
        "Highlights the rhyme ending inside generated suggestions so you can check the sound before inserting a line. This does not recolor the song."
    ),
    UNDERLINE_SYLLABLES(
        "Syllable Guide",
        "Marks words by syllable count. Words carry their syllable color when Rhyme Families is off; when both guides are on, the count moves to an underline.",
        legend = FeatureLegend.SYLLABLES
    ),
    STRESS_IPA(
        "Stress + IPA",
        "Shows dictionary-backed syllable stress and IPA previews for the target line and suggestions. Stressed syllables are shown as DA and unstressed syllables as da."
    ),
    RHYME_FAMILIES(
        "Rhyme Families",
        "Colors matching rhyme sounds throughout the current lyric. Each color represents one rhyme family; this does not change generated suggestions.",
        legend = FeatureLegend.RHYMES
    ),
    BEAT_GRID(
        "Beat Grid",
        "Maps one syllable to one beat, labels whether each line fits a four-beat bar, and estimates line duration at the current BPM. Tight lines use one extra beat of grace; overflow lines exceed that allowance."
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
    val isDark = LocalAppAppearance.current.isDark
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            "Syllable colors",
            fontSize = DesignTokens.Typography.caption,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurface
        )
        LegendRow(color = syllableColor(1, isDark), label = "1 syllable")
        LegendRow(color = syllableColor(2, isDark), label = "2 syllables")
        LegendRow(color = syllableColor(3, isDark), label = "3 syllables")
        LegendRow(color = syllableColor(4, isDark), label = "4+ syllables")
    }
}

@Composable
private fun RhymeLegend() {
    val palette = rhymePalette(LocalAppAppearance.current.isDark)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            "Rhyme colors",
            fontSize = DesignTokens.Typography.caption,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurface
        )
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
