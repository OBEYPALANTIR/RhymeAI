package com.rhymeai.app.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.rhymeai.app.data.model.AnalysisPresentation
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnalysisPresentation

@Composable
internal fun AnalysisStyleSelector(
    current: AnalysisPresentation,
    onChange: (AnalysisPresentation) -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
    ) {
        Text("Analysis Style", style = MaterialTheme.typography.labelMedium)
        SlidingSegmentedControl(
            labels = AnalysisPresentation.entries.map { it.displayName },
            selectedIndex = AnalysisPresentation.entries.indexOf(current),
            onSelect = { onChange(AnalysisPresentation.entries[it]) },
            modifier = Modifier
                .fillMaxWidth()
                .testTag("analysisStyleSelector")
        )
        CompositionLocalProvider(LocalAnalysisPresentation provides current) {
            RhymeHighlightedText(
                text = "light in the night\ntomorrow finds a brighter road",
                enabled = true,
                syllablesEnabled = true,
                style = MaterialTheme.typography.bodyMedium
            )
        }
        val legendLines = if (current == AnalysisPresentation.INK_MARKS) {
            listOf(
                "Solid, dashed, dotted, and dash-dot lines identify rhyme families.",
                "Heavier words contain more syllables."
            )
        } else {
            listOf("Color identifies rhyme families and syllable counts.")
        }
        legendLines.forEach { line ->
            Text(
                text = line,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall
            )
        }
    }
}
