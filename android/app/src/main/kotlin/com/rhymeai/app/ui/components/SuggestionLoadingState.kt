package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.dp
import com.rhymeai.app.SuggestedLine
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled

/**
 * How many empty suggestion slots the Assistant shows while lines are still
 * arriving. Suggestions stream in one line at a time, so the panel reserves a
 * few slots up front and lets each arriving line take the next one; lines past
 * the reserved slots simply append. Mirrors `SuggestionPlaceholders` on iOS.
 */
object SuggestionPlaceholders {
    /** Slots drawn as skeleton cards before the first line arrives. */
    const val VISIBLE_SLOTS = 3

    /** Skeleton cards to draw under the lines that have already arrived. */
    fun count(isLoading: Boolean, arrived: Int): Int =
        if (isLoading) (VISIBLE_SLOTS - arrived).coerceAtLeast(0) else 0

    /** Total slots to lay out: every arrived line plus any remaining placeholders. */
    fun slotCount(isLoading: Boolean, arrived: Int): Int = arrived + count(isLoading, arrived)
}

/**
 * The pencil that scribbles a skeleton card's two lines while the real line is
 * being written. One loop writes the first (longer) line, then the second,
 * holds for a beat, and starts over on a clean card. The wave is the UnBlock
 * underline's zigzag, tiled along the line. Mirrors `SuggestionScribbleMotion`
 * on iOS; the numbers are shared and unit-tested on both platforms.
 */
object ScribbleMotion {
    /** Time to write both lines, start to finish. */
    const val WRITE_MILLIS = 1300

    /** Pause with both lines drawn before the card is wiped and written again. */
    const val HOLD_MILLIS = 350
    const val PERIOD_MILLIS = WRITE_MILLIS + HOLD_MILLIS

    /** Share of the writing time the first line takes: its share of the two lines' length. */
    const val FIRST_LINE_SHARE = 0.63f

    /** With animations off the card holds this frame: first line written, second half way. */
    val STATIC_LINES = 1f to 0.6f

    /** One wave of the UnBlock scribble in unit space, from `UnBlockWordmark`. */
    val wave = listOf(0f to 0.55f, 0.18f to 0.25f, 0.42f to 0.78f, 0.68f to 0.28f, 1f to 0.58f)
    val waveWidth = 34.dp
    val lineHeight = 10.dp
    val strokeWidth = 1.6.dp
    val pencilSize = 14.dp

    /** How much of each line is drawn [elapsedMillis] into the loop, each in 0..1. */
    fun lines(elapsedMillis: Long): Pair<Float, Float> {
        val phase = Math.floorMod(elapsedMillis, PERIOD_MILLIS.toLong()).toFloat() / WRITE_MILLIS
        val first = (phase / FIRST_LINE_SHARE).coerceIn(0f, 1f)
        val second = ((phase - FIRST_LINE_SHARE) / (1f - FIRST_LINE_SHARE)).coerceIn(0f, 1f)
        return first to second
    }
}

/**
 * One suggestion slot. It appears as a skeleton card while its line is still
 * being written, cross-fades into the real card when the line arrives, and
 * collapses if generation ends before a line reached it. Sizes animate on the
 * standard spring; the arrival cross-fade uses the 260ms state tier, the
 * collapse the 160ms dismiss tier, and everything snaps when system animations
 * are off.
 */
@Composable
fun SuggestionSlot(
    line: SuggestedLine?,
    pending: Boolean,
    skeletonVariant: Int,
    modifier: Modifier = Modifier,
    card: @Composable (SuggestedLine) -> Unit
) {
    val animationsEnabled = LocalAnimationsEnabled.current
    val visibleState = remember { MutableTransitionState(false) }
    visibleState.targetState = line != null || pending

    AnimatedVisibility(
        visibleState = visibleState,
        modifier = modifier,
        enter = if (animationsEnabled) {
            fadeIn(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)) +
                expandVertically(DesignTokens.Motion.standardSpring(), expandFrom = Alignment.Top)
        } else {
            EnterTransition.None
        },
        exit = if (animationsEnabled) {
            fadeOut(tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing)) +
                shrinkVertically(tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing), shrinkTowards = Alignment.Top)
        } else {
            ExitTransition.None
        }
    ) {
        AnimatedContent(
            targetState = line,
            contentKey = { it != null },
            transitionSpec = {
                if (animationsEnabled) {
                    // Both halves of the arrival cross-fade share the state tier;
                    // the dismiss tier is reserved for slots that stay empty.
                    (fadeIn(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)) togetherWith
                        fadeOut(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)))
                        .using(SizeTransform(clip = false) { _, _ -> DesignTokens.Motion.standardSpring() })
                } else {
                    (EnterTransition.None togetherWith ExitTransition.None)
                        .using(SizeTransform(clip = false) { _, _ -> snap() })
                }
            },
            label = "suggestionSlot"
        ) { target ->
            if (target != null) card(target) else SuggestionSkeletonCard(variant = skeletonVariant)
        }
    }
}

private val skeletonLineWidths = listOf(0.78f to 0.46f, 0.64f to 0.38f, 0.72f to 0.52f)

/**
 * The shape of a [SuggestionCard] with nothing written in it yet: the same
 * outline, radius and padding, a pencil scribbling two lines where the serif
 * line will go, a badge block and a button block. With animations off the
 * pencil rests part way along the second line. Hidden from accessibility
 * services, which hear "Writing…" from the section header instead.
 */
@Composable
fun SuggestionSkeletonCard(
    modifier: Modifier = Modifier,
    variant: Int = 0
) {
    val colorScheme = MaterialTheme.colorScheme
    val animationsEnabled = LocalAnimationsEnabled.current
    val (firstLine, secondLine) = skeletonLineWidths[Math.floorMod(variant, skeletonLineWidths.size)]
    // The loop exists only while animations are on; with them off the card
    // holds one frame and schedules nothing.
    val lines = if (animationsEnabled) {
        val loop = rememberInfiniteTransition(label = "suggestionScribble")
        val elapsed by loop.animateFloat(
            initialValue = 0f,
            targetValue = ScribbleMotion.PERIOD_MILLIS.toFloat(),
            animationSpec = infiniteRepeatable(
                animation = tween(ScribbleMotion.PERIOD_MILLIS, easing = LinearEasing),
                repeatMode = RepeatMode.Restart
            ),
            label = "elapsed"
        )
        ScribbleMotion.lines(elapsed.toLong())
    } else {
        ScribbleMotion.STATIC_LINES
    }

    OutlinedCard(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = DesignTokens.Touch.minTarget)
            .clearAndSetSemantics { },
        shape = RoundedCornerShape(DesignTokens.Radius.lg),
        colors = CardDefaults.outlinedCardColors(
            containerColor = colorScheme.surfaceContainer,
            contentColor = colorScheme.onSurface
        ),
        border = BorderStroke(1.dp, colorScheme.outlineVariant)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DesignTokens.Spacing.lg),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
            ) {
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .padding(top = DesignTokens.Spacing.xs),
                    verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                ) {
                    // The pencil sits on whichever line is being written.
                    ScribbleLine(widthFraction = firstLine, progress = lines.first, showPencil = lines.first < 1f)
                    ScribbleLine(widthFraction = secondLine, progress = lines.second, showPencil = lines.first >= 1f && lines.second < 1f)
                }
                Box(
                    Modifier
                        .size(width = 28.dp, height = 22.dp)
                        .background(colorScheme.surfaceContainerHigh, RoundedCornerShape(DesignTokens.Radius.xs))
                )
            }
            Box(
                Modifier
                    .size(width = 92.dp, height = 32.dp)
                    .background(colorScheme.surfaceContainerHigh, RoundedCornerShape(DesignTokens.Radius.pill))
            )
        }
    }
}

/**
 * One line of the scribble: the UnBlock wave tiled across [widthFraction] of
 * the text column, drawn from the left up to [progress], with the pencil glyph
 * resting on the tip while [showPencil] is true.
 */
@Composable
private fun ScribbleLine(widthFraction: Float, progress: Float, showPencil: Boolean) {
    val ink = MaterialTheme.colorScheme.outline
    val pencil = rememberVectorPainter(Icons.Default.Edit)
    val path = remember { Path() }
    val segment = remember { Path() }
    val measure = remember { PathMeasure() }

    Canvas(
        Modifier
            .fillMaxWidth(widthFraction)
            .height(ScribbleMotion.lineHeight)
    ) {
        val cycles = (size.width / ScribbleMotion.waveWidth.toPx()).toInt().coerceAtLeast(1)
        val cycleWidth = size.width / cycles
        path.reset()
        for (cycle in 0 until cycles) {
            ScribbleMotion.wave.forEachIndexed { index, (unitX, unitY) ->
                val x = (cycle + unitX) * cycleWidth
                val y = unitY * size.height
                when {
                    cycle == 0 && index == 0 -> path.moveTo(x, y)
                    index == 0 -> Unit // each wave continues from the previous wave's end point
                    else -> path.lineTo(x, y)
                }
            }
        }
        measure.setPath(path, false)
        val drawn = measure.length * progress.coerceIn(0f, 1f)
        if (drawn <= 0f) return@Canvas
        segment.reset()
        measure.getSegment(0f, drawn, segment, true)
        drawPath(
            path = segment,
            color = ink,
            style = Stroke(width = ScribbleMotion.strokeWidth.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
        )
        if (showPencil) {
            // The glyph's point is its bottom-left corner; rest it on the tip.
            val tip = measure.getPosition(drawn)
            val glyph = ScribbleMotion.pencilSize.toPx()
            translate(left = tip.x, top = tip.y - glyph) {
                with(pencil) {
                    draw(size = Size(glyph, glyph), colorFilter = ColorFilter.tint(ink))
                }
            }
        }
    }
}
