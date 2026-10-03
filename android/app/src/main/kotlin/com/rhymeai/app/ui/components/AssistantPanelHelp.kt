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
import com.rhymeai.app.data.model.AnalysisPresentation
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnalysisPresentation
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
    val legend: FeatureLegend? = null,
    val inkMarksMessage: String? = null
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
        "Suggestion Rhymes",
        "Highlights the rhyme ending inside generated suggestions so you can check the sound before inserting a line. This does not recolor the song."
    ),
    UNDERLINE_SYLLABLES(
        "Syllable Guide",
        "Marks words by syllable count. In Color style, words carry syllable color when Rhyme Families is off; when both guides are on, the count moves to an underline.",
        legend = FeatureLegend.SYLLABLES,
        inkMarksMessage = "Marks words by syllable count using text weight: one syllable is regular, two medium, three semibold, and four or more bold."
    ),
    STRESS_IPA(
        "Stress + IPA",
        "Shows dictionary-backed syllable stress and IPA previews for the target line and suggestions. Stressed syllables are shown as DA and unstressed syllables as da."
    ),
    RHYME_FAMILIES(
        "Rhyme Families",
        "Colors matching rhyme sounds throughout the current lyric. Each color represents one rhyme family; this does not change generated suggestions.",
        legend = FeatureLegend.RHYMES,
        inkMarksMessage = "Underlines matching rhyme sounds throughout the current lyric. Solid, dashed, dotted, and dash-dot lines identify rhyme families; this does not change generated suggestions."
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
    val presentation = LocalAnalysisPresentation.current
    val message = if (presentation == AnalysisPresentation.INK_MARKS) {
        help.inkMarksMessage ?: help.message
    } else {
        help.message
    }

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
                Text(message, fontSize = 14.sp, lineHeight = 20.sp)

                when (help.legend) {
                    FeatureLegend.SYLLABLES -> SyllableLegend(presentation)
                    FeatureLegend.RHYMES -> RhymeLegend(presentation)
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
private fun SyllableLegend(presentation: AnalysisPresentation) {
    val isDark = LocalAppAppearance.current.isDark
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (presentation == AnalysisPresentation.INK_MARKS) {
            Text(
                "Syllable weights",
                fontSize = DesignTokens.Typography.caption,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface
            )
            listOf(
                "1 syllable" to FontWeight.Normal,
                "2 syllables" to FontWeight.Medium,
                "3 syllables" to FontWeight.SemiBold,
                "4+ syllables" to FontWeight.Bold
            ).forEach { (label, weight) ->
                Text(
                    text = label,
                    fontSize = 12.sp,
                    fontWeight = weight,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        } else {
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
}

@Composable
private fun RhymeLegend(presentation: AnalysisPresentation) {
    val palette = rhymePalette(LocalAppAppearance.current.isDark)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (presentation == AnalysisPresentation.INK_MARKS) {
            Text(
                "Rhyme underline patterns",
                fontSize = DesignTokens.Typography.caption,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface
            )
            Text(
                "Solid, dashed, dotted, and dash-dot lines identify rhyme families.",
                fontSize = 12.sp,
                lineHeight = 17.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        } else {
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
