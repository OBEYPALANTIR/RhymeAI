package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.SizeTransform
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
import androidx.compose.foundation.layout.Row
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
import androidx.compose.ui.draw.alpha
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
 * One suggestion slot. It appears as a skeleton card while its line is still
 * being written, cross-fades into the real card when the line arrives, and
 * collapses if generation ends before a line reached it. Sizes animate on the
 * standard spring; the fades use the 260ms state and 160ms dismiss tiers, and
 * everything snaps when system animations are off.
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
                    (fadeIn(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)) togetherWith
                        fadeOut(tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing)))
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
 * outline, radius and padding, two text bars where the serif line will go, a
 * badge block and a button block. It breathes between 55% and full opacity on
 * a 1.3s ease-in-out loop; with animations off it holds at 75%. Hidden from
 * accessibility services, which hear "Writing…" from the section header instead.
 */
@Composable
fun SuggestionSkeletonCard(
    modifier: Modifier = Modifier,
    variant: Int = 0
) {
    val colorScheme = MaterialTheme.colorScheme
    val animationsEnabled = LocalAnimationsEnabled.current
    val (firstLine, secondLine) = skeletonLineWidths[Math.floorMod(variant, skeletonLineWidths.size)]
    val breathing = rememberInfiniteTransition(label = "suggestionSkeleton")
    val animatedAlpha by breathing.animateFloat(
        initialValue = SKELETON_MIN_ALPHA,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(SKELETON_BREATH_MILLIS, easing = DesignTokens.Motion.standardEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "alpha"
    )
    val alpha = if (animationsEnabled) animatedAlpha else SKELETON_STATIC_ALPHA

    OutlinedCard(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = DesignTokens.Touch.minTarget)
            .alpha(alpha)
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
                    SkeletonBar(widthFraction = firstLine)
                    SkeletonBar(widthFraction = secondLine)
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

@Composable
private fun SkeletonBar(widthFraction: Float) {
    Box(
        Modifier
            .fillMaxWidth(widthFraction)
            .height(12.dp)
            .background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(DesignTokens.Radius.xs))
    )
}

private const val SKELETON_MIN_ALPHA = 0.55f
private const val SKELETON_STATIC_ALPHA = 0.75f
private const val SKELETON_BREATH_MILLIS = 1300
