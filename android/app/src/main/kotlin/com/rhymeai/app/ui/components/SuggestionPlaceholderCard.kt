package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.StartOffset
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled

/**
 * Timing for the "ink line" placeholders shown while next-line suggestions
 * stream in. Each placeholder is the suggestion card at its real paddings
 * whose text bar is written from the left, held, and faded, so the list
 * reads as lines being written in the order they will arrive.
 *
 * iOS mirror: `SuggestionInkLineMotion` in
 * `Writers Block/Components/SuggestionPlaceholderCardView.swift`.
 */
object SuggestionPlaceholderMotion {
    /** Ghost rows shown before the first line lands. */
    const val INITIAL_ROWS = 3

    /** The settle tier (420ms) stretched by φ: the bar is written, not flashed. */
    const val DRAW_MILLIS = 680
    const val HOLD_MILLIS = DesignTokens.Motion.standardMillis
    const val FADE_MILLIS = DesignTokens.Motion.dismissMillis
    const val REST_MILLIS = DesignTokens.Motion.standardMillis
    const val CYCLE_MILLIS = DRAW_MILLIS + HOLD_MILLIS + FADE_MILLIS + REST_MILLIS

    /** Rows start one state tier apart, top to bottom. */
    const val ROW_OFFSET_MILLIS = DesignTokens.Motion.standardMillis

    const val RESTING_INK_ALPHA = 0.08f
    const val STROKE_INK_ALPHA = 0.34f
    /** Bar alpha when animations are off: a still bar must read on its own. */
    const val STATIC_INK_ALPHA = 0.16f
    const val GHOST_ALPHA = 0.08f
    const val GHOST_SOFT_ALPHA = 0.06f

    val textBarFractions = listOf(0.72f, 0.56f, 0.64f)
    val arrivalRise: Dp = 8.dp

    /**
     * How many ghost rows to show: three before anything arrives, one trailing
     * row while the stream is still open, none once it closes or is stopped.
     */
    fun placeholderCount(suggestionCount: Int, isLoading: Boolean): Int = when {
        !isLoading -> 0
        suggestionCount == 0 -> INITIAL_ROWS
        else -> 1
    }

    fun textBarFraction(row: Int): Float = textBarFractions[row.coerceAtLeast(0) % textBarFractions.size]

    fun rowOffsetMillis(row: Int): Int = row.coerceAtLeast(0) * ROW_OFFSET_MILLIS

    /** Position inside the cycle for a row, 0 until that row's offset has elapsed. */
    fun phaseMillis(elapsedMillis: Long, row: Int): Int {
        val shifted = elapsedMillis - rowOffsetMillis(row)
        if (shifted <= 0) return 0
        return (shifted % CYCLE_MILLIS).toInt()
    }

    /** Horizontal extent of the stroke, 0..1, on the standard curve while drawing. */
    fun strokeExtent(phaseMillis: Int): Float {
        if (phaseMillis <= 0) return 0f
        if (phaseMillis >= DRAW_MILLIS) return 1f
        return DesignTokens.Motion.standardEasing.transform(phaseMillis / DRAW_MILLIS.toFloat())
    }

    /** Stroke alpha: solid through draw and hold, out on the exit curve, then resting. */
    fun strokeAlpha(phaseMillis: Int): Float {
        val fadeStart = DRAW_MILLIS + HOLD_MILLIS
        if (phaseMillis < fadeStart) return 1f
        val fadeEnd = fadeStart + FADE_MILLIS
        if (phaseMillis >= fadeEnd) return 0f
        return 1f - DesignTokens.Motion.exitEasing.transform((phaseMillis - fadeStart) / FADE_MILLIS.toFloat())
    }
}

/**
 * A ghost of [SuggestionCard] that holds the slot a streamed line will fill.
 * Hidden from accessibility services; the "Writing lines…" caption above the
 * list is what TalkBack announces.
 */
@Composable
fun SuggestionPlaceholderCard(
    row: Int,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val ink = colorScheme.onSurface
    val animationsEnabled = LocalAnimationsEnabled.current

    OutlinedCard(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = DesignTokens.Touch.minTarget)
            .testTag("suggestionPlaceholder")
            .clearAndSetSemantics { },
        shape = RoundedCornerShape(DesignTokens.Radius.lg),
        colors = CardDefaults.outlinedCardColors(
            containerColor = colorScheme.surfaceContainer,
            contentColor = colorScheme.onSurface
        ),
        border = BorderStroke(1.dp, colorScheme.outlineVariant)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DesignTokens.Spacing.lg),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
        ) {
            // Mirrors the 20sp line box of the serif suggestion text.
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(20.dp),
                contentAlignment = Alignment.CenterStart
            ) {
                InkLine(
                    row = row,
                    ink = ink,
                    animationsEnabled = animationsEnabled,
                    modifier = Modifier.fillMaxWidth(SuggestionPlaceholderMotion.textBarFraction(row))
                )
            }
            // Syllable badge ghost.
            Ghost(width = 26.dp, height = 22.dp, radius = DesignTokens.Radius.xs, color = ink.copy(alpha = SuggestionPlaceholderMotion.GHOST_ALPHA))
        }
        // Action row ghosts: the tonal "Use line" pill and the "Keep for later" text.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.xs)
                .height(DesignTokens.Touch.minTarget),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
        ) {
            Ghost(width = 96.dp, height = 40.dp, radius = 20.dp, color = ink.copy(alpha = SuggestionPlaceholderMotion.GHOST_ALPHA))
            Ghost(width = 108.dp, height = 20.dp, radius = 10.dp, color = ink.copy(alpha = SuggestionPlaceholderMotion.GHOST_SOFT_ALPHA))
        }
    }
}

@Composable
private fun Ghost(width: Dp, height: Dp, radius: Dp, color: Color) {
    Box(
        Modifier
            .size(width = width, height = height)
            .clip(RoundedCornerShape(radius))
            .background(color)
    )
}

@Composable
private fun InkLine(
    row: Int,
    ink: Color,
    animationsEnabled: Boolean,
    modifier: Modifier = Modifier
) {
    val shape = RoundedCornerShape(50)
    val restingAlpha = if (animationsEnabled) SuggestionPlaceholderMotion.RESTING_INK_ALPHA else SuggestionPlaceholderMotion.STATIC_INK_ALPHA
    Box(
        modifier
            .height(9.dp)
            .clip(shape)
            .background(ink.copy(alpha = restingAlpha))
    ) {
        // An infinite transition is not time-scaled by the system animator
        // setting the way a one-shot tween is, so it is skipped outright when
        // the user has removed animations and the bar stays still.
        if (animationsEnabled) {
            val transition = rememberInfiniteTransition(label = "suggestionInkLine")
            val startOffset = StartOffset(SuggestionPlaceholderMotion.rowOffsetMillis(row))
            val strokeExtent by transition.animateFloat(
                initialValue = 0f,
                targetValue = 1f,
                animationSpec = infiniteRepeatable(
                    animation = keyframes {
                        durationMillis = SuggestionPlaceholderMotion.CYCLE_MILLIS
                        0f at 0 using DesignTokens.Motion.standardEasing
                        1f at SuggestionPlaceholderMotion.DRAW_MILLIS
                        1f at SuggestionPlaceholderMotion.CYCLE_MILLIS
                    },
                    repeatMode = RepeatMode.Restart,
                    initialStartOffset = startOffset
                ),
                label = "extent"
            )
            val strokeAlpha by transition.animateFloat(
                initialValue = 1f,
                targetValue = 0f,
                animationSpec = infiniteRepeatable(
                    animation = keyframes {
                        durationMillis = SuggestionPlaceholderMotion.CYCLE_MILLIS
                        1f at 0
                        1f at SuggestionPlaceholderMotion.DRAW_MILLIS + SuggestionPlaceholderMotion.HOLD_MILLIS using DesignTokens.Motion.exitEasing
                        0f at SuggestionPlaceholderMotion.DRAW_MILLIS + SuggestionPlaceholderMotion.HOLD_MILLIS + SuggestionPlaceholderMotion.FADE_MILLIS
                        0f at SuggestionPlaceholderMotion.CYCLE_MILLIS
                    },
                    repeatMode = RepeatMode.Restart,
                    initialStartOffset = startOffset
                ),
                label = "alpha"
            )
            Box(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        scaleX = strokeExtent
                        transformOrigin = TransformOrigin(0f, 0.5f)
                        alpha = strokeAlpha
                    }
                    .background(ink.copy(alpha = SuggestionPlaceholderMotion.STROKE_INK_ALPHA))
            )
        }
    }
}

/**
 * Enter motion for a streamed suggestion: a 260ms fade with an 8dp rise on
 * the standard spring, run once when the card first appears. Snaps when the
 * user has removed animations.
 */
@Composable
fun SuggestionArrival(
    animationsEnabled: Boolean,
    content: @Composable () -> Unit
) {
    val visibleState = remember { MutableTransitionState(!animationsEnabled).apply { targetState = true } }
    val risePx = with(LocalDensity.current) { SuggestionPlaceholderMotion.arrivalRise.roundToPx() }
    AnimatedVisibility(
        visibleState = visibleState,
        enter = if (animationsEnabled) {
            fadeIn(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)) +
                slideInVertically(DesignTokens.Motion.standardSpring(IntOffset.VisibilityThreshold)) { risePx }
        } else {
            EnterTransition.None
        }
    ) {
        content()
    }
}
