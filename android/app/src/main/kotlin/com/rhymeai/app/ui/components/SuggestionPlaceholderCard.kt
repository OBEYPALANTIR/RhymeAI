package com.rhymeai.app.ui.components

import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.ui.unit.IntSize
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.withInfiniteAnimationFrameMillis
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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
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
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.placeholderColorFor
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/**
 * Slot arithmetic and timing for the placeholders shown while next-line
 * suggestions stream in. When a request starts, one slot opens as a ghost
 * card; each streamed line takes the ghost's slot in place and the next ghost
 * opens below it while the request is still writing, and the ghost still
 * waiting when the stream stops collapses. Each ghost scribbles two wave lines
 * in, tip first, on a loop: the first line over 63% of a 1.3s write, then the
 * second, a 350ms hold with both drawn, then a wipe. With animations off it
 * holds one frame: the first line drawn, the second stopped 60% along.
 *
 * iOS mirror: `SuggestionInkLineMotion` in
 * `Writers Block/Components/SuggestionPlaceholderCardView.swift`.
 */
object SuggestionPlaceholderMotion {
    const val WRITE_MILLIS = 1300
    const val HOLD_MILLIS = 350
    const val PERIOD_MILLIS = WRITE_MILLIS + HOLD_MILLIS
    /** The share of the write spent on the first line. */
    const val FIRST_LINE_SHARE = 0.63f

    const val WAVE_PERIOD_DP = 34f
    const val WAVE_HEIGHT_DP = 10f
    const val STROKE_WIDTH_DP = 1.6f

    /** The frame held with animations off: first line drawn, second stopped 60% along. */
    val STILL_FRAME = 1f to 0.6f

    /** Wave points across one period, as fractions of its width and the line's height. */
    private val WAVE = listOf(0f to 0.55f, 0.18f to 0.25f, 0.42f to 0.78f, 0.68f to 0.28f, 1f to 0.58f)

    const val GHOST_ALPHA = 0.08f
    const val GHOST_SOFT_ALPHA = 0.06f

    val textBarFractions = listOf(0.72f, 0.56f, 0.64f)
    /** The second line's width as a share of the first's, near the design's 78/46 and 64/38 pairs. */
    const val SECOND_LINE_SHARE = 0.6f

    /** Ghost cards still waiting for a line: one while the request writes, none once the stream stops. */
    fun placeholderCount(arrived: Int, isLoading: Boolean): Int = if (isLoading) 1 else 0

    /** Slots to lay out: every line that has arrived plus the ghosts still waiting. */
    fun slotCount(arrived: Int, isLoading: Boolean): Int = arrived + placeholderCount(arrived, isLoading)

    fun textBarFraction(slot: Int): Float = textBarFractions[slot.coerceAtLeast(0) % textBarFractions.size]

    fun secondBarFraction(slot: Int): Float = textBarFraction(slot) * SECOND_LINE_SHARE

    /** How far each line is drawn, 0..1, [elapsedMillis] after the ghost opened. */
    fun lineProgress(elapsedMillis: Long): Pair<Float, Float> {
        val phase = Math.floorMod(elapsedMillis, PERIOD_MILLIS.toLong()) / WRITE_MILLIS.toFloat()
        return (phase / FIRST_LINE_SHARE).coerceIn(0f, 1f) to
            ((phase - FIRST_LINE_SHARE) / (1f - FIRST_LINE_SHARE)).coerceIn(0f, 1f)
    }

    /** The wave tiled from x = 0 to [width]: one wave every [period], the last cut at the edge. */
    fun wavePoints(width: Float, period: Float, height: Float): List<Offset> {
        val points = mutableListOf(Offset(0f, WAVE[0].second * height))
        var cycle = 0
        while (points.last().x < width) {
            for ((fx, fy) in WAVE.drop(1)) {
                val x = (cycle + fx) * period
                val y = fy * height
                val previous = points.last()
                if (x >= width) {
                    val f = if (x > previous.x) (width - previous.x) / (x - previous.x) else 0f
                    points += Offset(width, previous.y + (y - previous.y) * f)
                    break
                }
                points += Offset(x, y)
            }
            cycle++
        }
        return points
    }
}

/**
 * The ink burst when writing ends with at least one line: fourteen dots leave
 * the Stop spinner's centre over 480ms on an ease-out cubic, each with its own
 * jitter and speed, dropping as they go but never past [REACH_DP]; they keep
 * their size until the last 30%, then fade and shrink to 40%. A blot at the
 * centre collapses on the same curve.
 */
object InkBurstMotion {
    const val DURATION_MILLIS = 480
    const val DOT_COUNT = 14
    const val REACH_DP = 44f
    const val DOT_RADIUS_DP = 2.2f
    const val BLOT_RADIUS_DP = 6f

    /** One dot: [x] and [y] in units of the reach (never past 1), radius in dp, and alpha. */
    data class Dot(val x: Float, val y: Float, val radiusDp: Float, val alpha: Float)

    /** The dots, then the blot while it has size, [elapsedMillis] into the burst; none outside it. */
    fun dots(elapsedMillis: Float): List<Dot> {
        val p = elapsedMillis / DURATION_MILLIS
        if (!(p >= 0f && p < 1f)) return emptyList()
        val inv = 1f - p
        val eased = 1f - inv * inv * inv
        val alpha = if (p < 0.7f) 1f else 1f - (p - 0.7f) / 0.3f
        val dots = (0 until DOT_COUNT).map { i ->
            val angle = i * (2 * PI / DOT_COUNT) + ((i * 7) % DOT_COUNT) / DOT_COUNT.toDouble() * 0.35
            val speed = 0.72f + 0.28f * ((i * 5) % 3) / 2f
            var x = cos(angle).toFloat() * eased * speed
            var y = sin(angle).toFloat() * eased * speed + 0.18f * p * p
            val length = hypot(x, y)
            if (length > 1f) { x /= length; y /= length }
            Dot(x, y, DOT_RADIUS_DP * (0.4f + 0.6f * alpha), alpha)
        }
        val blot = BLOT_RADIUS_DP * (1f - eased)
        return if (blot > 0f) dots + Dot(0f, 0f, blot, inv) else dots
    }
}

/**
 * One suggestion slot. It holds a ghost card while its line is being written,
 * cross-fades into the real card when the line arrives, and collapses if
 * writing stops before a line reached it. A slot composed together with its
 * section ([appearsWithSection]: the request just opened it, or the sheet was
 * reopened or rotated) appears with the section instead of animating on its
 * own, so nothing that already landed replays. The arrival cross-fade happens
 * in place on the 260ms state tier; the collapse uses the 160ms dismiss tier,
 * sizes settle on the standard spring, and everything snaps when animations
 * are off. [modifier]
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
                    // Both halves of the arrival share the state tier, in
                    // place; the dismiss tier is kept for slots that stay empty.
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
    val scribbleInk = placeholderColorFor(LocalAppAppearance.current)
    val animationsEnabled = LocalAnimationsEnabled.current
    // One clock per ghost, from when it appears; read only while drawing.
    val elapsedMillis = remember { mutableLongStateOf(0L) }
    if (animationsEnabled) {
        LaunchedEffect(Unit) {
            val start = withInfiniteAnimationFrameMillis { it }
            while (true) withInfiniteAnimationFrameMillis { elapsedMillis.longValue = it - start }
        }
    }
    val progress = {
        if (animationsEnabled) SuggestionPlaceholderMotion.lineProgress(elapsedMillis.longValue)
        else SuggestionPlaceholderMotion.STILL_FRAME
    }

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
                .padding(DesignTokens.Rhythm.standard),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.related)
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.tight)
            ) {
                // The serif line, held by one invisible line of the card's
                // style, with the two scribble lines centred over it. The
                // scribble never sizes the box: where it is taller than the
                // line it runs into the card's padding, so a one-line card
                // lands without moving the list.
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopStart) {
                    HeldLine(fontFamily = FontFamily.Serif, fontSize = 14.sp, lineHeight = 20.sp)
                    Column(
                        modifier = Modifier.matchParentSize().wrapContentHeight(unbounded = true),
                        verticalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.related)
                    ) {
                        ScribbleLine(scribbleInk, SuggestionPlaceholderMotion.textBarFraction(slot)) { progress().first }
                        ScribbleLine(scribbleInk, SuggestionPlaceholderMotion.secondBarFraction(slot)) { progress().second }
                    }
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
                    .padding(horizontal = DesignTokens.Rhythm.tight, vertical = DesignTokens.Spacing.xs)
            ) {
                HeldLine(fontFamily = FontFamily.Monospace, fontSize = 12.sp, text = "00")
            }
        }
        FlowRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = DesignTokens.Rhythm.related, end = DesignTokens.Rhythm.related, bottom = DesignTokens.Rhythm.tight),
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.tight)
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
 * One scribble line: the wave tiled across [widthFraction] of the row, 10dp
 * tall, stroked up to [progress] of its length, tip first. [progress] is read
 * in the draw phase, so the line redraws each frame without recomposing.
 */
@Composable
private fun ScribbleLine(ink: Color, widthFraction: Float, progress: () -> Float) {
    Spacer(
        Modifier
            .fillMaxWidth(widthFraction)
            .height(SuggestionPlaceholderMotion.WAVE_HEIGHT_DP.dp)
            .drawWithCache {
                val path = Path()
                SuggestionPlaceholderMotion.wavePoints(size.width, SuggestionPlaceholderMotion.WAVE_PERIOD_DP.dp.toPx(), size.height).forEachIndexed { i, point ->
                    if (i == 0) path.moveTo(point.x, point.y) else path.lineTo(point.x, point.y)
                }
                val measure = PathMeasure().apply { setPath(path, false) }
                val drawn = Path()
                val stroke = Stroke(width = SuggestionPlaceholderMotion.STROKE_WIDTH_DP.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
                onDrawBehind {
                    val p = progress()
                    if (p <= 0f) return@onDrawBehind
                    drawn.reset()
                    measure.getSegment(0f, measure.length * p, drawn, true)
                    drawPath(drawn, ink, style = stroke)
                }
            }
    )
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
