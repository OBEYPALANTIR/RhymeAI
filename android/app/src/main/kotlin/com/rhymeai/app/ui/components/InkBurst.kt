package com.rhymeai.app.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin

/**
 * The ink firework that ends a successful suggestion request: the spinner in
 * the primary button bursts into dots of on-surface ink that fly out, drop a
 * little as if wet, shrink and fade, while a blot at the centre collapses. It
 * is the Assistant's one celebratory beat. The geometry is deterministic so
 * both platforms draw the same burst; mirrors `InkBurstMotion` on iOS.
 */
object InkBurstMotion {
    const val DURATION_MILLIS = 480
    const val PARTICLE_COUNT = 14

    /** How far the farthest dot travels. */
    val reach = 44.dp

    /** Dot radius at the start of the burst. */
    const val DOT_RADIUS_DP = 2.2f

    /** Blot radius at the start of the burst. */
    const val BLOT_RADIUS_DP = 6f

    /** One dot or blot: offset from the origin in units of [reach], radius in dp, alpha 0..1. */
    data class Particle(val x: Float, val y: Float, val radiusDp: Float, val alpha: Float)

    /** Ease-out cubic: the dots leave fast and coast. */
    fun eased(progress: Float): Float = 1f - (1f - progress.coerceIn(0f, 1f)).pow(3)

    fun alpha(progress: Float): Float {
        val p = progress.coerceIn(0f, 1f)
        return if (p < 0.7f) 1f else 1f - (p - 0.7f) / 0.3f
    }

    /** The dots [progress] (0..1) into the burst. */
    fun particles(progress: Float): List<Particle> {
        val p = progress.coerceIn(0f, 1f)
        val travel = eased(p)
        val alpha = alpha(p)
        val radius = DOT_RADIUS_DP * (1f - 0.6f * p)
        return List(PARTICLE_COUNT) { index ->
            // A fixed jitter per dot keeps the ring from reading as a gear.
            val jitter = ((index * 7) % PARTICLE_COUNT) / PARTICLE_COUNT.toFloat() * 0.35f
            val angle = index * (2f * Math.PI.toFloat() / PARTICLE_COUNT) + jitter
            val speed = 0.72f + 0.28f * ((index * 5) % 3) / 2f
            val distance = travel * speed
            val drop = 0.18f * p * p
            Particle(
                x = cos(angle) * distance,
                y = sin(angle) * distance + drop,
                radiusDp = radius,
                alpha = alpha
            )
        }
    }

    /** The blot left where the spinner was; it collapses as the dots leave. */
    fun blot(progress: Float): Particle {
        val p = progress.coerceIn(0f, 1f)
        return Particle(x = 0f, y = 0f, radiusDp = BLOT_RADIUS_DP * (1f - eased(p)), alpha = 1f - p)
    }
}

/**
 * Draws one [InkBurstMotion] burst at [origin] (in this composable's
 * coordinates) each time [trigger] changes to a new non-zero value. Nothing is
 * drawn when animations are off. The canvas does not clip, so the dots may
 * fly past its bounds.
 */
@Composable
fun InkBurst(
    trigger: Int,
    origin: Offset?,
    color: Color,
    modifier: Modifier = Modifier
) {
    val animationsEnabled = LocalAnimationsEnabled.current
    val progress = remember { Animatable(1f) }
    LaunchedEffect(trigger) {
        if (trigger == 0 || !animationsEnabled) return@LaunchedEffect
        progress.snapTo(0f)
        progress.animateTo(1f, tween(InkBurstMotion.DURATION_MILLIS, easing = LinearEasing))
    }
    val p = progress.value
    if (p >= 1f || origin == null) return

    Canvas(modifier) {
        val reach = InkBurstMotion.reach.toPx()
        InkBurstMotion.particles(p).forEach { dot ->
            drawCircle(
                color = color.copy(alpha = color.alpha * dot.alpha),
                radius = dot.radiusDp.dp.toPx(),
                center = Offset(origin.x + dot.x * reach, origin.y + dot.y * reach)
            )
        }
        val blot = InkBurstMotion.blot(p)
        if (blot.radiusDp > 0f) {
            drawCircle(
                color = color.copy(alpha = color.alpha * blot.alpha),
                radius = blot.radiusDp.dp.toPx(),
                center = origin
            )
        }
    }
}
