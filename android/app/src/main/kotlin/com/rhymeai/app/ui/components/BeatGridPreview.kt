package com.rhymeai.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.util.BeatGrid

/**
 * Renders the beat-grid preview strip for every lyric line.
 *
 * Each line shows: truncated text, a filled-segment bar visualization
 * (colored by fit classification), and a "Nsyl · M.m beats" label.
 *
 * Recomputes only when [lyrics] or [bpm] change — same caching idiom
 * as ProsodyPreview.
 */
@Composable
fun BeatGridPreview(
    lyrics: String,
    bpm: Int,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val grid = remember(lyrics, bpm) {
        BeatGrid.compute(lyrics = lyrics, bpm = bpm)
    }

    if (grid.lines.isEmpty()) return

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        grid.lines.forEach { line ->
            BeatGridLineRow(line = line)
        }
    }
}

@Composable
private fun BeatGridLineRow(line: BeatGrid.LineResult) {
    val colorScheme = MaterialTheme.colorScheme

    // Fit color: normal accent = fits, amber = tight, red = overflow.
    val barColor: Color = when (line.fit) {
        BeatGrid.Fit.FITS -> colorScheme.primary
        BeatGrid.Fit.TIGHT -> Color(0xFFFFA000)   // amber warning
        BeatGrid.Fit.OVERFLOW -> colorScheme.error
    }
    val labelColor: Color = when (line.fit) {
        BeatGrid.Fit.FITS -> colorScheme.onSurfaceVariant
        BeatGrid.Fit.TIGHT -> Color(0xFFFFA000)
        BeatGrid.Fit.OVERFLOW -> colorScheme.error
    }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Truncated line text (fixed width so bars align).
        Text(
            text = line.text,
            fontSize = 12.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            color = colorScheme.onSurface,
            modifier = Modifier.weight(1f)
        )

        // Bar visualization: one filled segment per whole beat.
        BeatSegments(
            beats = line.beats,
            beatsPerBar = 4,    // spec default; grid always uses 4 for the visual
            color = barColor
        )

        // "Nsyl · M.m beats"
        Text(
            text = "${line.syllableCount}syl · ${"%.1f".format(line.beats)}b",
            fontSize = 11.sp,
            color = labelColor,
            modifier = Modifier.width(80.dp)
        )
    }
}

/**
 * Renders small filled rectangles representing beats, grouped into bars.
 * Overflow beats past one bar are still drawn but in a muted shade to
 * keep the row width bounded.
 */
@Composable
private fun BeatSegments(
    beats: Double,
    beatsPerBar: Int,
    color: Color,
    modifier: Modifier = Modifier
) {
    val totalSegments = maxOf(beatsPerBar, beats.toInt().coerceAtLeast(1))
    val filledSegments = beats.toInt().coerceAtMost(totalSegments)

    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        repeat(totalSegments) { i ->
            val filled = i < filledSegments
            Box(
                modifier = Modifier
                    .size(width = 8.dp, height = 12.dp)
                    .background(
                        color = if (filled) color else color.copy(alpha = 0.15f),
                        shape = RoundedCornerShape(2.dp)
                    )
            )
            // Small gap between bars.
            if (i < totalSegments - 1 && (i + 1) % beatsPerBar == 0) {
                Box(Modifier.width(3.dp))
            }
        }
    }
}
