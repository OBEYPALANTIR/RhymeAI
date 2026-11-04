package com.rhymeai.app.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.text.TextLayoutResult
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.syllableColor
import com.rhymeai.app.util.LyricTokenizer
import com.rhymeai.app.util.SectionMap
import com.rhymeai.app.util.SyllableCounter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

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


/**
 * For each word in [newWords], the index of the word in [oldStarts] it continues after one edit
 * turned [oldText] into [newText], or -1 for a new word. Words after the edit shift by its length
 * change, words before it keep their offset; each old word continues at most one new word.
 */
internal fun matchUnderlineSpans(
    oldText: String,
    oldStarts: List<Int>,
    newText: String,
    newWords: List<IntRange>
): IntArray {
    val prefix = oldText.commonPrefixWith(newText).length
    val maxSuffix = minOf(oldText.length, newText.length) - prefix
    var suffix = 0
    while (suffix < maxSuffix && oldText[oldText.length - 1 - suffix] == newText[newText.length - 1 - suffix]) suffix++
    val editEnd = newText.length - suffix
    val delta = newText.length - oldText.length
    val oldIndexByStart = oldStarts.withIndex().associate { (index, start) -> start to index }
    val used = BooleanArray(oldStarts.size)
    fun unused(oldStart: Int) = oldIndexByStart[oldStart]?.takeIf { !used[it] }
    return IntArray(newWords.size) { i ->
        val word = newWords[i]
        // After the edit first ("a light" -> "light"), else before it ("a light" -> "a ight"),
        // unless the word lies wholly inside inserted text.
        val match = (if (word.first >= editEnd) unused(word.first - delta) else null)
            ?: (if (word.first <= prefix && !(word.first == prefix && word.last < editEnd)) unused(word.first) else null)
        match?.also { used[it] = true } ?: -1
    }
}

/**
 * Underline lengths carried across edits: each word's line eases from its previous length to the
 * new one, so deleting a letter shortens it by that letter and typing grows it; words that vanish
 * fade out. Draw-phase state only: the analysis is never re-run per frame.
 */
class SyllableUnderlineMotion internal constructor(private val scope: CoroutineScope) {
    private var text: String? = null
    private var spans: List<SyllableUnderlineSpan> = emptyList()
    private var lines: List<UnderlineLine> = emptyList()
    private val fading = mutableListOf<UnderlineLine>()

    private class UnderlineLine(
        val color: Color,
        var length: Animatable<Float, AnimationVector1D>?,
        var target: Float,
        var segments: FloatArray = FloatArray(0) // left, right, y for each text line, as last drawn
    ) {
        var alpha: Animatable<Float, AnimationVector1D>? = null
    }

    internal fun draw(
        drawScope: DrawScope,
        layout: TextLayoutResult,
        newText: String,
        newSpans: List<SyllableUnderlineSpan>,
        animate: Boolean,
        underlineGap: Float,
        strokeWidth: Float
    ) = with(drawScope) {
        if (newSpans !== spans || newText != text) sync(newText, newSpans, animate)
        // Until the field lays out this text, keep last frame's lines rather than drawing nothing.
        val laidOut = layout.layoutInput.text.text == newText
        lines.forEachIndexed { index, line ->
            if (laidOut) {
                val span = newSpans[index]
                line.segments = underlineSegments(layout, span.start, span.endExclusive, underlineGap)
                retarget(line, line.segments.totalLength(), animate)
            }
            drawSegments(line.segments, line.length?.value ?: 0f, line.color, 1f, strokeWidth)
        }
        fading.forEach { line ->
            drawSegments(line.segments, line.length?.value ?: 0f, line.color, line.alpha?.value ?: 0f, strokeWidth)
        }
    }

    private fun sync(newText: String, newSpans: List<SyllableUnderlineSpan>, animate: Boolean) {
        val oldText = text
        val old = lines
        val matches = if (oldText == null) IntArray(newSpans.size) { -1 } else {
            matchUnderlineSpans(oldText, spans.map { it.start }, newText, newSpans.map { it.start until it.endExclusive })
        }
        val edited = oldText != null && oldText != newText
        // A wholesale replacement (another song opening, a paste over most of it) snaps instead.
        val animateEdit = animate && edited &&
            (oldText.commonPrefixWith(newText).length + oldText.commonSuffixWith(newText).length) * 2 >=
            minOf(oldText.length, newText.length)
        val continued = BooleanArray(old.size)
        lines = newSpans.mapIndexed { index, span ->
            val previous = matches[index].takeIf { it >= 0 }?.let { continued[it] = true; old[it] }
            when {
                previous != null && (animateEdit || !edited) ->
                    UnderlineLine(span.color, previous.length, previous.target, previous.segments)
                animateEdit -> UnderlineLine(span.color, Animatable(0f), 0f) // a new word grows from nothing
                else -> UnderlineLine(span.color, null, -1f)
            }
        }
        if (animateEdit) old.forEachIndexed { index, line -> if (!continued[index]) fadeOut(line) }
        text = newText
        spans = newSpans
    }

    private fun retarget(line: UnderlineLine, length: Float, animate: Boolean) {
        if (length == line.target) return
        line.target = length
        val current = line.length
        if (current == null || !animate) {
            line.length = Animatable(length)
        } else {
            scope.launch { current.animateTo(length, motionSpec()) }
        }
    }

    private fun fadeOut(line: UnderlineLine) {
        if (line.segments.isEmpty()) return
        val alpha = Animatable(1f)
        line.alpha = alpha
        fading += line
        scope.launch {
            try {
                alpha.animateTo(0f, motionSpec())
            } finally {
                fading -= line
            }
        }
    }

    private fun motionSpec() = tween<Float>(DesignTokens.Motion.feedbackMillis, easing = FastOutSlowInEasing)
}

@Composable
fun rememberSyllableUnderlineMotion(): SyllableUnderlineMotion {
    val scope = rememberCoroutineScope()
    return remember(scope) { SyllableUnderlineMotion(scope) }
}

/**
 * Underlines each span of [text] in its syllable colour. [motion] eases each line's length between
 * edits when [animate] is on (off under reduced motion: lines snap).
 */
fun Modifier.syllableUnderlines(
    text: String,
    spans: List<SyllableUnderlineSpan>,
    motion: SyllableUnderlineMotion,
    animate: Boolean,
    textLayoutResult: () -> TextLayoutResult?,
    underlineGap: Float,
    strokeWidth: Float
): Modifier = drawBehind {
    val layout = textLayoutResult() ?: return@drawBehind
    motion.draw(this, layout, text, spans, animate, underlineGap, strokeWidth)
}

/** One (left, right, y) triple per text line the word [start, endExclusive) occupies. */
private fun underlineSegments(
    layout: TextLayoutResult,
    start: Int,
    endExclusive: Int,
    underlineGap: Float
): FloatArray {
    if (start >= endExclusive || endExclusive > layout.layoutInput.text.length) return FloatArray(0)
    val segments = ArrayList<Float>(3)
    fun add(segmentStart: Int, segmentEnd: Int) {
        val startBox = layout.getBoundingBox(segmentStart)
        val endBox = layout.getBoundingBox((segmentEnd - 1).coerceAtLeast(segmentStart))
        if (endBox.right <= startBox.left) return
        segments += startBox.left
        segments += endBox.right
        segments += maxOf(startBox.bottom, endBox.bottom) + underlineGap
    }
    var segmentStart = start
    var segmentLine = layout.getLineForOffset(start)
    for (offset in (start + 1) until endExclusive) {
        val line = layout.getLineForOffset(offset)
        if (line != segmentLine) {
            add(segmentStart, offset)
            segmentStart = offset
            segmentLine = line
        }
    }
    add(segmentStart, endExclusive)
    return segments.toFloatArray()
}

private fun FloatArray.totalLength(): Float {
    var total = 0f
    for (i in indices step 3) total += this[i + 1] - this[i]
    return total
}

/**
 * Draws [length] pixels along [segments], continuing onto the next text line as needed; a length
 * past the word's end (a just-deleted letter easing out) runs on from its last segment.
 */
private fun DrawScope.drawSegments(
    segments: FloatArray,
    length: Float,
    color: Color,
    alpha: Float,
    strokeWidth: Float
) {
    var remaining = length
    for (i in segments.indices step 3) {
        if (remaining <= 0f || alpha <= 0f) return
        val left = segments[i]
        val right = if (i + 3 < segments.size) minOf(segments[i + 1], left + remaining) else left + remaining
        remaining -= segments[i + 1] - left
        drawLine(
            color = color.copy(alpha = 0.95f * alpha),
            start = Offset(left, segments[i + 2]),
            end = Offset(right, segments[i + 2]),
            strokeWidth = strokeWidth,
            cap = StrokeCap.Round
        )
    }
}
