package com.rhymeai.app.ui.components

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.isSystemInDarkTheme
import com.rhymeai.app.ui.theme.syllableColor
import com.rhymeai.app.util.LyricTokenizer
import com.rhymeai.app.util.SyllableCounter

private val wordPattern = LyricTokenizer.alphanumericWordPattern

@Immutable
data class SyllableUnderlineSpan(
    val start: Int,
    val endExclusive: Int,
    val color: Color
)

fun buildSyllableUnderlineSpans(text: String, enabled: Boolean, isDark: Boolean): List<SyllableUnderlineSpan> {
    if (!enabled || text.isEmpty()) return emptyList()

    return wordPattern.findAll(text)
        .map { match ->
            SyllableUnderlineSpan(
                start = match.range.first,
                endExclusive = match.range.last + 1,
                color = syllableColor(SyllableCounter.count(match.value), isDark)
            )
        }
        .toList()
}

@Composable
fun SyllableColoredText(
    text: String,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    style: TextStyle = TextStyle.Default
) {
    val baseTextColor = MaterialTheme.colorScheme.onBackground
    val isDark = isSystemInDarkTheme()
    var layoutResult by remember { mutableStateOf<TextLayoutResult?>(null) }
    val density = LocalDensity.current
    val strokeWidth = with(density) { 3.dp.toPx() }
    val underlineGap = with(density) { 2.dp.toPx() }
    val spans = remember(text, enabled, isDark) { buildSyllableUnderlineSpans(text, enabled, isDark) }

    Text(
        text = text,
        modifier = modifier.syllableUnderlines(
            spans = spans,
            textLayoutResult = layoutResult,
            underlineGap = underlineGap,
            strokeWidth = strokeWidth
        ),
        style = style,
        color = baseTextColor,
        onTextLayout = { layoutResult = it }
    )
}

fun Modifier.syllableUnderlines(
    spans: List<SyllableUnderlineSpan>,
    textLayoutResult: TextLayoutResult?,
    underlineGap: Float,
    strokeWidth: Float
): Modifier = drawBehind {
    val layout = textLayoutResult ?: return@drawBehind
    if (spans.isEmpty()) return@drawBehind

    spans.forEach { span ->
        if (span.endExclusive > layout.layoutInput.text.length) return@forEach
        drawWordUnderline(
            layout = layout,
            start = span.start,
            endExclusive = span.endExclusive,
            color = span.color,
            underlineGap = underlineGap,
            strokeWidth = strokeWidth
        )
    }
}

private fun DrawScope.drawWordUnderline(
    layout: TextLayoutResult,
    start: Int,
    endExclusive: Int,
    color: Color,
    underlineGap: Float,
    strokeWidth: Float
) {
    if (start >= endExclusive) return

    var segmentStart = start
    var segmentLine = layout.getLineForOffset(start)

    for (offset in (start + 1) until endExclusive) {
        val line = layout.getLineForOffset(offset)
        if (line != segmentLine) {
            drawUnderlineSegment(layout, segmentStart, offset, color, underlineGap, strokeWidth)
            segmentStart = offset
            segmentLine = line
        }
    }

    drawUnderlineSegment(layout, segmentStart, endExclusive, color, underlineGap, strokeWidth)
}

private fun DrawScope.drawUnderlineSegment(
    layout: TextLayoutResult,
    start: Int,
    endExclusive: Int,
    color: Color,
    underlineGap: Float,
    strokeWidth: Float
) {
    val safeEnd = (endExclusive - 1).coerceAtLeast(start)
    val startBox = layout.getBoundingBox(start)
    val endBox = layout.getBoundingBox(safeEnd)
    val y = maxOf(startBox.bottom, endBox.bottom) + underlineGap
    val left = startBox.left
    val right = endBox.right

    if (right <= left) return

    drawLine(
        color = color.copy(alpha = 0.95f),
        start = Offset(left, y),
        end = Offset(right, y),
        strokeWidth = strokeWidth,
        cap = StrokeCap.Round
    )
}
