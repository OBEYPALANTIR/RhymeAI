package com.rhymeai.app.ui.components

import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.ui.unit.IntSize
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
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.SuggestedLine
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled

/**
 * Slot arithmetic and timing for the placeholders shown while next-line
 * suggestions stream in. When a request starts, three slots open as ghost
 * cards; each streamed line takes the next slot in place, lines past the
 * third append below, and any slot still empty when the stream stops
 * collapses. While a ghost waits, its text bar is written like an ink line,
 * held, cleared and written again. Every step is one tier of the motion
 * ladder, so none passes the 500ms cap on utilitarian motion, and the ghosts
 * of one request start together, so their lines write in step.
 *
 * iOS mirror: `SuggestionInkLineMotion` in
 * `Writers Block/Components/SuggestionPlaceholderCardView.swift`.
 */
object SuggestionPlaceholderMotion {
    /** Slots opened as ghost cards when a request starts. */
    const val RESERVED_SLOTS = 3

    /** The iOS settle tier; Android settles with a spring and has no 420ms constant. */
    const val DRAW_MILLIS = 420
    const val HOLD_MILLIS = DesignTokens.Motion.standardMillis
    const val FADE_MILLIS = DesignTokens.Motion.dismissMillis
    const val REST_MILLIS = DesignTokens.Motion.standardMillis
    const val CYCLE_MILLIS = DRAW_MILLIS + HOLD_MILLIS + FADE_MILLIS + REST_MILLIS

    const val RESTING_INK_ALPHA = 0.08f
    const val STROKE_INK_ALPHA = 0.34f
    /** Bar alpha when animations are off: a still bar must read on its own. */
    const val STATIC_INK_ALPHA = 0.16f
    const val GHOST_ALPHA = 0.08f
    const val GHOST_SOFT_ALPHA = 0.06f

    val textBarFractions = listOf(0.72f, 0.56f, 0.64f)

    /** Ghost cards still waiting for a line: the reserved slots not filled yet, none once the stream stops. */
    fun placeholderCount(arrived: Int, isLoading: Boolean): Int =
        if (isLoading) (RESERVED_SLOTS - arrived).coerceAtLeast(0) else 0

    /** Slots to lay out: every line that has arrived plus the ghosts still waiting. */
    fun slotCount(arrived: Int, isLoading: Boolean): Int = arrived + placeholderCount(arrived, isLoading)

    fun textBarFraction(slot: Int): Float = textBarFractions[slot.coerceAtLeast(0) % textBarFractions.size]

    /** Position inside the cycle, [elapsedMillis] after the ghost started writing. */
    fun phaseMillis(elapsedMillis: Long): Int =
        if (elapsedMillis <= 0) 0 else (elapsedMillis % CYCLE_MILLIS).toInt()

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
 * One suggestion slot. It holds a ghost card while its line is being written,
 * cross-fades into the real card when the line arrives, and collapses if
 * writing stops before a line reached it. A slot composed together with its
 * section ([appearsWithSection]: the request just opened it, or the sheet was
 * reopened or rotated) appears with the section instead of animating on its
 * own, so nothing that already landed replays. The arrival cross-fade uses the
 * 260ms state tier, the collapse the 160ms dismiss tier, sizes settle on the
 * standard spring, and everything snaps when animations are off. [modifier]
 * applies inside the collapse, so spacing passed in collapses with the slot.
 */
@Composable
fun SuggestionSlot(
    line: SuggestedLine?,
    pending: Boolean,
    appearsWithSection: Boolean,
    ghost: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    card: @Composable (SuggestedLine) -> Unit
) {
    val animationsEnabled = LocalAnimationsEnabled.current
    val visible = line != null || pending
    val visibleState = remember { MutableTransitionState(appearsWithSection && visible) }
    visibleState.targetState = visible

    AnimatedVisibility(
        visibleState = visibleState,
        enter = if (animationsEnabled) {
            fadeIn(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)) +
                expandVertically(DesignTokens.Motion.standardSpring(IntSize.VisibilityThreshold), expandFrom = Alignment.Top)
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
            modifier = modifier,
            contentKey = { it != null },
            transitionSpec = {
                if (animationsEnabled) {
                    // Both halves of the arrival share the state tier; the
                    // dismiss tier is kept for slots that stay empty.
                    (fadeIn(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)) togetherWith
                        fadeOut(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)))
                        .using(SizeTransform(clip = false) { _, _ -> DesignTokens.Motion.standardSpring(IntSize.VisibilityThreshold) })
                } else {
                    (EnterTransition.None togetherWith ExitTransition.None)
                        .using(SizeTransform(clip = false) { _, _ -> snap() })
                }
            },
            label = "suggestionSlot"
        ) { target ->
            if (target != null) card(target) else ghost()
        }
    }
}

/**
 * A ghost of [SuggestionCard] that holds a slot until its line arrives. Each
 * row is held by invisible text in the card's own style, so the ghost grows
 * with the font scale exactly as the card does: one serif line, the
 * stress-and-IPA rows when that preview is on, and the syllable badge. The
 * card's two buttons sit in the same FlowRow, disabled and invisible, so the
 * ghost wraps them where the real card would. A suggestion that wraps to a
 * second line still grows its card when it lands. Hidden from accessibility
 * services, which hear "Writing suggestions" from the section header.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SuggestionPlaceholderCard(
    slot: Int,
    modifier: Modifier = Modifier,
    /** Mirrors [SuggestionCard]'s `showProsody`: reserves the stress-and-IPA rows. */
    showProsody: Boolean = false
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
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
            ) {
                // The serif line, held by one invisible line of the card's style.
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterStart) {
                    HeldLine(fontFamily = FontFamily.Serif, fontSize = 14.sp, lineHeight = 20.sp)
                    InkLine(
                        ink = ink,
                        animationsEnabled = animationsEnabled,
                        modifier = Modifier.fillMaxWidth(SuggestionPlaceholderMotion.textBarFraction(slot))
                    )
                }
                if (showProsody) {
                    // ProsodyPreview: two monospace lines, 2dp apart.
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        SoftRow(widthFraction = 0.4f, ink = ink)
                        SoftRow(widthFraction = 0.66f, ink = ink)
                    }
                }
            }
            // The syllable count badge, in its own style and padding.
            Box(
                Modifier
                    .clip(RoundedCornerShape(DesignTokens.Radius.xs))
                    .background(ink.copy(alpha = SuggestionPlaceholderMotion.GHOST_ALPHA))
                    .padding(horizontal = DesignTokens.Spacing.sm, vertical = DesignTokens.Spacing.xs)
            ) {
                HeldLine(fontFamily = FontFamily.Monospace, fontSize = 12.sp, text = "00")
            }
        }
        FlowRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.xs),
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
        ) {
            // The card's own buttons, disabled and invisible, so they measure
            // and wrap exactly as the real ones do; only their ghosts are drawn.
            FilledTonalButton(
                onClick = {},
                enabled = false,
                modifier = Modifier
                    .heightIn(min = DesignTokens.Touch.minTarget)
                    .ghostPill(ink.copy(alpha = SuggestionPlaceholderMotion.GHOST_ALPHA))
                    .alpha(0f)
            ) {
                Text("Use line")
            }
            TextButton(
                onClick = {},
                enabled = false,
                modifier = Modifier
                    .heightIn(min = DesignTokens.Touch.minTarget)
                    .ghostLabel(ink.copy(alpha = SuggestionPlaceholderMotion.GHOST_SOFT_ALPHA))
                    .alpha(0f)
            ) {
                Text("Keep for later")
            }
        }
    }
}

/** One invisible line of text in a card row's own style: it holds that row's height at any font scale. */
@Composable
private fun HeldLine(
    fontFamily: FontFamily,
    fontSize: TextUnit,
    text: String = "Placeholder",
    lineHeight: TextUnit = TextUnit.Unspecified
) {
    Text(
        text = text,
        fontFamily = fontFamily,
        fontSize = fontSize,
        lineHeight = lineHeight,
        maxLines = 1,
        modifier = Modifier.alpha(0f)
    )
}

/** One monospace prosody line, held by invisible text in its style, with its ghost bar. */
@Composable
private fun SoftRow(widthFraction: Float, ink: Color) {
    val barHeight = with(LocalDensity.current) { 8.sp.toDp() }
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterStart) {
        HeldLine(fontFamily = FontFamily.Monospace, fontSize = 12.sp, text = "/x/", lineHeight = 16.sp)
        Box(
            Modifier
                .fillMaxWidth(widthFraction)
                .height(barHeight)
                .clip(RoundedCornerShape(50))
                .background(ink.copy(alpha = SuggestionPlaceholderMotion.GHOST_SOFT_ALPHA))
        )
    }
}

/**
 * The ghost's text bar. While animations are on it is written from the left,
 * held, faded and rested on a loop that starts with the ghost; the loop is
 * read in the draw phase, so the bar redraws each frame without recomposing.
 * With animations off the loop is never created and the bar holds still.
 */
@Composable
private fun InkLine(ink: Color, animationsEnabled: Boolean, modifier: Modifier = Modifier) {
    val barHeight = with(LocalDensity.current) { 9.sp.toDp() }
    Box(
        modifier
            .height(barHeight)
            .clip(RoundedCornerShape(50))
            .background(
                ink.copy(
                    alpha = if (animationsEnabled) {
                        SuggestionPlaceholderMotion.RESTING_INK_ALPHA
                    } else {
                        SuggestionPlaceholderMotion.STATIC_INK_ALPHA
                    }
                )
            )
    ) {
        if (animationsEnabled) {
            val loop = rememberInfiniteTransition(label = "suggestionInkLine")
            val elapsed = loop.animateFloat(
                initialValue = 0f,
                targetValue = SuggestionPlaceholderMotion.CYCLE_MILLIS.toFloat(),
                animationSpec = infiniteRepeatable(
                    animation = tween(SuggestionPlaceholderMotion.CYCLE_MILLIS, easing = LinearEasing),
                    repeatMode = RepeatMode.Restart
                ),
                label = "elapsed"
            )
            Box(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        val phase = SuggestionPlaceholderMotion.phaseMillis(elapsed.value.toLong())
                        scaleX = SuggestionPlaceholderMotion.strokeExtent(phase)
                        alpha = SuggestionPlaceholderMotion.strokeAlpha(phase)
                        transformOrigin = TransformOrigin(0f, 0.5f)
                    }
                    .background(ink.copy(alpha = SuggestionPlaceholderMotion.STROKE_INK_ALPHA))
            )
        }
    }
}

/** A pill filling the element: the ghost of the tonal "Use line" button. */
private fun Modifier.ghostPill(color: Color): Modifier = drawBehind {
    drawRoundRect(color = color, cornerRadius = CornerRadius(size.height / 2f))
}

/** A text-sized bar inside a text button: the ghost of "Keep for later". */
private fun Modifier.ghostLabel(color: Color): Modifier = drawBehind {
    val inset = 12.dp.toPx()
    val barHeight = minOf(20.sp.toPx(), size.height)
    drawRoundRect(
        color = color,
        topLeft = Offset(inset, (size.height - barHeight) / 2f),
        size = Size((size.width - inset * 2f).coerceAtLeast(0f), barHeight),
        cornerRadius = CornerRadius(barHeight / 2f)
    )
}
