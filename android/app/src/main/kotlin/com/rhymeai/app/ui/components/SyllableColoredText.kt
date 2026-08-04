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
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.rhymeai.app.data.model.AnalysisPresentation
import com.rhymeai.app.ui.theme.InkUnderlinePattern
import com.rhymeai.app.ui.theme.LocalAnalysisPresentation
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.analysisFontWeight
import com.rhymeai.app.ui.theme.syllableColor
import com.rhymeai.app.util.LyricTokenizer
import com.rhymeai.app.util.SyllableCounter

private val wordPattern = LyricTokenizer.alphanumericWordPattern

fun buildSyllableWordColorAnnotatedString(
    text: String,
    baseTextColor: Color,
    isDark: Boolean
): AnnotatedString = buildSyllableWordAnnotatedString(
    text = text,
    baseTextColor = baseTextColor,
    isDark = isDark,
    presentation = AnalysisPresentation.COLOR
)

fun buildSyllableWordAnnotatedString(
    text: String,
    baseTextColor: Color,
    isDark: Boolean,
    presentation: AnalysisPresentation
): AnnotatedString = buildAnnotatedString {
    var cursor = 0
    for (match in wordPattern.findAll(text)) {
        val start = match.range.first
        val end = match.range.last + 1
        if (start > cursor) {
            withStyle(SpanStyle(color = baseTextColor)) {
                append(text.substring(cursor, start))
            }
        }
        val syllableCount = SyllableCounter.count(match.value)
        val wordStyle = when (presentation) {
            AnalysisPresentation.COLOR -> SpanStyle(
                color = syllableColor(syllableCount, isDark),
                fontWeight = FontWeight.SemiBold
            )
            AnalysisPresentation.INK_MARKS -> SpanStyle(
                color = baseTextColor,
                fontWeight = analysisFontWeight(syllableCount)
            )
        }
        withStyle(wordStyle) {
            append(match.value)
        }
        cursor = end
    }
    if (cursor < text.length) {
        withStyle(SpanStyle(color = baseTextColor)) {
            append(text.substring(cursor))
        }
    }
}

@Composable
fun SyllableWordColoredText(
    text: String,
    modifier: Modifier = Modifier,
    style: TextStyle = TextStyle.Default
) {
    val baseTextColor = MaterialTheme.colorScheme.onBackground
    val isDark = LocalAppAppearance.current.isDark
    val presentation = LocalAnalysisPresentation.current
    val annotated = remember(text, baseTextColor, isDark, presentation) {
        buildSyllableWordAnnotatedString(
            text = text,
            baseTextColor = baseTextColor,
            isDark = isDark,
            presentation = presentation
        )
    }

    Text(
        text = annotated,
        modifier = modifier,
        style = style
    )
}

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
    val isDark = LocalAppAppearance.current.isDark
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
            strokeWidth = strokeWidth,
            pattern = InkUnderlinePattern.SOLID
        )
    }
}

fun Modifier.rhymeUnderlines(
    spans: List<RhymeUnderlineSpan>,
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
            strokeWidth = strokeWidth,
            pattern = span.pattern
        )
    }
}

private fun DrawScope.drawWordUnderline(
    layout: TextLayoutResult,
    start: Int,
    endExclusive: Int,
    color: Color,
    underlineGap: Float,
    strokeWidth: Float,
    pattern: InkUnderlinePattern
) {
    if (start >= endExclusive) return

    var segmentStart = start
    var segmentLine = layout.getLineForOffset(start)

    for (offset in (start + 1) until endExclusive) {
        val line = layout.getLineForOffset(offset)
        if (line != segmentLine) {
            drawUnderlineSegment(layout, segmentStart, offset, color, underlineGap, strokeWidth, pattern)
            segmentStart = offset
            segmentLine = line
        }
    }

    drawUnderlineSegment(layout, segmentStart, endExclusive, color, underlineGap, strokeWidth, pattern)
}

private fun DrawScope.drawUnderlineSegment(
    layout: TextLayoutResult,
    start: Int,
    endExclusive: Int,
    color: Color,
    underlineGap: Float,
    strokeWidth: Float,
    pattern: InkUnderlinePattern
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
        cap = StrokeCap.Round,
        pathEffect = pattern.pathEffect(strokeWidth)
    )
}

private fun InkUnderlinePattern.pathEffect(strokeWidth: Float): PathEffect? = when (this) {
    InkUnderlinePattern.SOLID -> null
    InkUnderlinePattern.DASHED -> PathEffect.dashPathEffect(
        floatArrayOf(4 * strokeWidth, 3 * strokeWidth)
    )
    InkUnderlinePattern.DOTTED -> PathEffect.dashPathEffect(
        floatArrayOf(strokeWidth, 2.5f * strokeWidth)
    )
    InkUnderlinePattern.DASH_DOT -> PathEffect.dashPathEffect(
        floatArrayOf(4 * strokeWidth, 2 * strokeWidth, strokeWidth, 2 * strokeWidth)
    )
}
