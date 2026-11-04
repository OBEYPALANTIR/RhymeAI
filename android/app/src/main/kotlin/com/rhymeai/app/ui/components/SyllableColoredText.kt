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
import com.rhymeai.app.util.SyllableCounter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

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

/** Each word's underline in [text]; words come from the shared per-line memo, so an edit re-reads only its lines. */
fun analyzeSyllableUnderlines(text: String, enabled: Boolean): List<SyllableUnderlineAnalysis> {
    if (!enabled || text.isEmpty()) return emptyList()
    val result = ArrayList<SyllableUnderlineAnalysis>()
    SyllableCounter.forEachLyricLine(text) { lineStart, line ->
        val tokens = line.tokens
        for (i in tokens.indices step 3) {
            result += SyllableUnderlineAnalysis(lineStart + tokens[i], lineStart + tokens[i + 1], tokens[i + 2])
        }
    }
    return result
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

/** The single changed region between [old] and [new]: their common prefix and non-overlapping suffix. */
internal class TextEdit(old: String, new: String) {
    val prefix = old.commonPrefixWith(new).length
    val suffix: Int = run {
        val max = minOf(old.length, new.length) - prefix
        var length = 0
        while (length < max && old[old.length - 1 - length] == new[new.length - 1 - length]) length++
        length
    }
    val delta = new.length - old.length

    /** End of the changed region in [new]. */
    val newEnd = new.length - suffix

    /** Characters replaced or inserted, whichever is more. */
    val size = maxOf(old.length, new.length) - prefix - suffix
}

/**
 * For each word in [new], the index of the word in [old] it continues after [edit], or -1 for a new
 * word. Words after the edit shift by its length change, words before it keep their offset; each
 * old word continues at most one new word. Both lists are in text order.
 */
internal fun matchUnderlineSpans(
    edit: TextEdit,
    old: List<SyllableUnderlineSpan>,
    new: List<SyllableUnderlineSpan>
): IntArray {
    val used = BooleanArray(old.size)
    fun unused(start: Int): Int? {
        var low = 0
        var high = old.lastIndex
        while (low <= high) {
            val middle = (low + high).ushr(1)
            val oldStart = old[middle].start
            when {
                oldStart < start -> low = middle + 1
                oldStart > start -> high = middle - 1
                else -> return middle.takeIf { !used[it] }
            }
        }
        return null
    }
    return IntArray(new.size) { i ->
        val word = new[i]
        // After the edit first ("a light" -> "light"), else before it ("a light" -> "a ight"),
        // unless the word lies wholly inside inserted text.
        val match = (if (word.start >= edit.newEnd) unused(word.start - edit.delta) else null)
            ?: (if (word.start <= edit.prefix && !(word.start == edit.prefix && word.endExclusive <= edit.newEnd)) unused(word.start) else null)
        match?.also { used[it] = true } ?: -1
    }
}

/** Edits larger than this (a paste, a big undo, another song's text) snap instead of easing. */
internal const val MAX_ANIMATED_EDIT_CHARS = 200

/**
 * Underline lengths carried across edits: each word's line eases from its previous length to the
 * new one, so deleting a letter shortens it by that letter and typing grows it; words that vanish
 * fade out. Draw-phase state only: the analysis is never re-run per frame, and only words whose
 * length changed hold an animation.
 */
class SyllableUnderlineMotion internal constructor(private val scope: CoroutineScope) {
    private var text: String? = null
    private var spans: List<SyllableUnderlineSpan> = emptyList()
    private var lines: List<UnderlineLine> = emptyList()
    private val fading = mutableListOf<UnderlineLine>()
    private var easeNextLayout = false

    private class UnderlineLine(var color: Color) {
        var target = -1f // full length on the layout in segmentsFor; -1 until measured
        var length: Animatable<Float, AnimationVector1D>? = null // null draws target
        var overflow = 0f // how far a shrinking line may run past its word, on the row it already had
        var snap = false
        var segments = FloatArray(0) // left, right, y for each text row, as last measured
        var segmentsFor: TextLayoutResult? = null
        var alpha: Animatable<Float, AnimationVector1D>? = null
        var fade: Job? = null

        fun drawnLength(): Float = length?.value?.let { minOf(it, target + overflow) } ?: target
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
        val ease = animate && easeNextLayout
        lines.forEachIndexed { index, line ->
            if (laidOut && line.segmentsFor !== layout) {
                val span = newSpans[index]
                remeasure(line, underlineSegments(layout, span.start, span.endExclusive, underlineGap), ease)
                line.segmentsFor = layout
            }
            drawSegments(line.segments, line.drawnLength(), line.color, 1f, strokeWidth)
        }
        if (laidOut) easeNextLayout = false
        fading.forEach { line ->
            drawSegments(line.segments, line.drawnLength(), line.color, line.alpha?.value ?: 0f, strokeWidth)
        }
    }

    private fun sync(newText: String, newSpans: List<SyllableUnderlineSpan>, animate: Boolean) {
        val oldText = text
        val oldSpans = spans
        val old = lines
        text = newText
        spans = newSpans
        val edit = if (oldText != null && oldText != newText) TextEdit(oldText, newText) else null
        val animateEdit = animate && edit != null && edit.size <= MAX_ANIMATED_EDIT_CHARS
        easeNextLayout = animateEdit
        // Analysis switched off (Focus, a toggle, a rewrite) or a snapped edit: no dead lines linger.
        if (!animateEdit && (edit != null || newSpans.isEmpty())) clearFades()
        val matches = when {
            edit != null -> matchUnderlineSpans(edit, oldSpans, newSpans)
            oldText != null && oldSpans.size == newSpans.size -> IntArray(newSpans.size) { it } // same text, new colours
            else -> null
        }
        val continued = BooleanArray(old.size)
        lines = List(newSpans.size) { index ->
            val previous = matches?.get(index)?.takeIf { it >= 0 }
            if (previous != null) {
                continued[previous] = true
                old[previous].also { line ->
                    line.color = newSpans[index].color
                    if (edit != null && !animateEdit) line.snap = true
                }
            } else {
                UnderlineLine(newSpans[index].color).also { line ->
                    if (animateEdit) line.length = Animatable(0f) // a new word grows from nothing
                }
            }
        }
        if (animateEdit) old.forEachIndexed { index, line -> if (!continued[index]) fadeOut(line) }
    }

    private fun remeasure(line: UnderlineLine, segments: FloatArray, ease: Boolean) {
        val previous = line.segments
        // Past its word only along the row it already occupied, never across a reflowed neighbour.
        line.overflow = if (previous.isNotEmpty() && previous.size == segments.size && previous.last() == segments.last()) {
            val shownEnd = previous[previous.size - 2] + maxOf(0f, line.drawnLength() - line.target)
            maxOf(0f, shownEnd - segments[segments.size - 2])
        } else {
            0f
        }
        line.segments = segments
        val full = segments.totalLength()
        val snap = line.snap || !ease
        line.snap = false
        if (full == line.target && !snap) return
        val from = line.target
        line.target = full
        if (snap || from < 0f && line.length == null) {
            line.length = null
            line.overflow = 0f
            return
        }
        val length = line.length ?: Animatable(from).also { line.length = it }
        scope.launch { length.animateTo(full, motionSpec()) }
    }

    private fun fadeOut(line: UnderlineLine) {
        if (line.segments.isEmpty()) return
        val alpha = Animatable(1f)
        line.alpha = alpha
        fading += line
        line.fade = scope.launch {
            try {
                alpha.animateTo(0f, motionSpec())
            } finally {
                fading -= line
            }
        }
    }

    private fun clearFades() {
        fading.forEach { it.fade?.cancel() }
        fading.clear()
    }

    private fun motionSpec() = tween<Float>(DesignTokens.Motion.feedbackMillis, easing = FastOutSlowInEasing)
}

/** Fresh motion state per [key] (the open song), so one song never inherits another's lines. */
@Composable
fun rememberSyllableUnderlineMotion(key: Any?): SyllableUnderlineMotion {
    val scope = rememberCoroutineScope()
    return remember(scope, key) { SyllableUnderlineMotion(scope) }
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

/** One (left, right, y) triple per text row the word [start, endExclusive) occupies. */
private fun underlineSegments(
    layout: TextLayoutResult,
    start: Int,
    endExclusive: Int,
    underlineGap: Float
): FloatArray {
    if (start >= endExclusive || endExclusive > layout.layoutInput.text.length) return FloatArray(0)
    val firstRow = layout.getLineForOffset(start)
    val lastRow = layout.getLineForOffset(endExclusive - 1)
    val segments = FloatArray((lastRow - firstRow + 1) * 3)
    var size = 0
    for (row in firstRow..lastRow) {
        val segmentStart = if (row == firstRow) start else layout.getLineStart(row)
        val segmentEnd = if (row == lastRow) endExclusive else layout.getLineEnd(row)
        if (segmentEnd <= segmentStart) continue
        val startBox = layout.getBoundingBox(segmentStart)
        val endBox = layout.getBoundingBox(segmentEnd - 1)
        if (endBox.right <= startBox.left) continue
        segments[size++] = startBox.left
        segments[size++] = endBox.right
        segments[size++] = maxOf(startBox.bottom, endBox.bottom) + underlineGap
    }
    return if (size == segments.size) segments else segments.copyOf(size)
}

private fun FloatArray.totalLength(): Float {
    var total = 0f
    for (i in indices step 3) total += this[i + 1] - this[i]
    return total
}

/**
 * Draws [length] pixels along [segments], continuing onto the next text row as needed; a length
 * past the word's end (a just-deleted letter easing out, bounded by its row) runs on from the last row.
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
