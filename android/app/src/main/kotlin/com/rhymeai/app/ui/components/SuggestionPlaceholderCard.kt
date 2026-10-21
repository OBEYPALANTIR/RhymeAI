package com.rhymeai.app.ui.components

import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.ui.unit.IntSize
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
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
import androidx.compose.runtime.LaunchedEffect
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
 * suggestions stream in. When a request starts, one slot opens as a ghost
 * card; each streamed line takes the ghost's slot in place and the next ghost
 * opens below it while the request is still writing, and the ghost still
 * waiting when the stream stops collapses. When a ghost opens, its text bar is
 * written once from the left on the 420ms settle tier and then holds still
 * until its line arrives; with animations off it is the same still bar.
 *
 * iOS mirror: `SuggestionInkLineMotion` in
 * `Writers Block/Components/SuggestionPlaceholderCardView.swift`.
 */
object SuggestionPlaceholderMotion {
    /** The iOS settle tier; Android settles with a spring and has no 420ms constant. */
    const val DRAW_MILLIS = 420

    /** The text bar's ink while it draws and once it rests, with animations on or off. */
    const val RESTING_INK_ALPHA = 0.08f
    const val GHOST_ALPHA = 0.08f
    const val GHOST_SOFT_ALPHA = 0.06f

    val textBarFractions = listOf(0.72f, 0.56f, 0.64f)

    /** Ghost cards still waiting for a line: one while the request writes, none once the stream stops. */
    fun placeholderCount(arrived: Int, isLoading: Boolean): Int = if (isLoading) 1 else 0

    /** Slots to lay out: every line that has arrived plus the ghosts still waiting. */
    fun slotCount(arrived: Int, isLoading: Boolean): Int = arrived + placeholderCount(arrived, isLoading)

    fun textBarFraction(slot: Int): Float = textBarFractions[slot.coerceAtLeast(0) % textBarFractions.size]

    /** Horizontal extent of the stroke, 0..1, [elapsedMillis] after the ghost opened: drawn once on the standard curve, then full. */
    fun strokeExtent(elapsedMillis: Long): Float {
        if (elapsedMillis <= 0) return 0f
        if (elapsedMillis >= DRAW_MILLIS) return 1f
        return DesignTokens.Motion.standardEasing.transform(elapsedMillis / DRAW_MILLIS.toFloat())
    }
}

/**
 * One suggestion slot. It holds a ghost card while its line is being written,
 * cross-fades into the real card when the line arrives, and collapses if
 * writing stops before a line reached it. A slot composed together with its
 * section ([appearsWithSection]: the request just opened it, or the sheet was
 * reopened or rotated) appears with the section instead of animating on its
 * own, so nothing that already landed replays. The arrival cross-fade uses the
 * 260ms state tier, with the arriving card rising 24dp into place as it fades
 * in; the collapse uses the 160ms dismiss tier, sizes settle on the
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
    // The same short rise the iOS undo toast uses.
    val arrivalRisePx = with(LocalDensity.current) { 24.dp.roundToPx() }
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
                    // dismiss tier is kept for slots that stay empty. An
                    // arriving card also rises into place; a ghost does not.
                    val fade = fadeIn(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing))
                    val enter = if (targetState != null) {
                        fade + slideInVertically(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)) { arrivalRisePx }
                    } else {
                        fade
                    }
                    (enter togetherWith
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
 * The ghost's text bar, written once from the left when the ghost opens and
 * then held still. The stroke is read in the draw phase, so the bar redraws
 * each frame without recomposing. With animations off it starts fully drawn.
 */
@Composable
private fun InkLine(ink: Color, animationsEnabled: Boolean, modifier: Modifier = Modifier) {
    val barHeight = with(LocalDensity.current) { 9.sp.toDp() }
    val drawMillis = SuggestionPlaceholderMotion.DRAW_MILLIS.toFloat()
    val elapsed = remember { Animatable(if (animationsEnabled) 0f else drawMillis) }
    LaunchedEffect(Unit) {
        elapsed.animateTo(drawMillis, tween(SuggestionPlaceholderMotion.DRAW_MILLIS, easing = LinearEasing))
    }
    // The pill clips the stroke, so its leading end stays round while it draws.
    Box(modifier.height(barHeight).clip(RoundedCornerShape(50))) {
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer {
                    scaleX = SuggestionPlaceholderMotion.strokeExtent(elapsed.value.toLong())
                    transformOrigin = TransformOrigin(0f, 0.5f)
                }
                .background(ink.copy(alpha = SuggestionPlaceholderMotion.RESTING_INK_ALPHA))
        )
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
