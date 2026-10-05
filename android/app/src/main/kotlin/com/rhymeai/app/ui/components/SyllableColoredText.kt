package com.rhymeai.app.ui.components

import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.text.TextLayoutResult
import com.rhymeai.app.ui.theme.syllableColor
import com.rhymeai.app.util.LyricTokenizer
import com.rhymeai.app.util.SectionMap
import com.rhymeai.app.util.SyllableCounter

private val wordPattern = LyricTokenizer.alphanumericWordPattern

@Immutable
data class SyllableUnderlineSpan(
    val start: Int,
    val endExclusive: Int,
    val color: Color
)

@Immutable
data class SyllableUnderlineAnalysis(
    val start: Int,
    val endExclusive: Int,
    val syllableCount: Int
)

fun analyzeSyllableUnderlines(text: String, enabled: Boolean): List<SyllableUnderlineAnalysis> {
    if (!enabled || text.isEmpty()) return emptyList()

    val headerRanges = SectionMap.headerRanges(text)
    return wordPattern.findAll(text)
        .filterNot { match ->
            SectionMap.intersectsHeader(match.range, headerRanges)
        }
        .map { match ->
            SyllableUnderlineAnalysis(
                start = match.range.first,
                endExclusive = match.range.last + 1,
                syllableCount = SyllableCounter.count(match.value)
            )
        }
        .toList()
}

fun colorSyllableUnderlines(
    analysis: List<SyllableUnderlineAnalysis>,
    isDark: Boolean
): List<SyllableUnderlineSpan> = analysis.map { token ->
    SyllableUnderlineSpan(
        start = token.start,
        endExclusive = token.endExclusive,
        color = syllableColor(token.syllableCount, isDark)
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
