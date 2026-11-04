package com.rhymeai.app.ui.theme

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.addOutline
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import com.rhymeai.app.data.model.AppAppearance

/** What a container is for: the page itself, a slab on it, or something lifted over it. */
enum class SurfaceLevel { Page, Raised, Floating }

// API 28+ multiplies each shadow colour's alpha by the theme's own multiplier (the app theme keeps
// the platform defaults: spot 0.19, ambient 0.039), so each is divided back out separately. The
// ambient light can never exceed its multiplier, so a token's strength is carried by the spot.
private const val PlatformSpotShadowAlpha = 0.19f
private const val PlatformAmbientShadowAlpha = 0.039f

internal fun inkShadowAlphas(visibleAlpha: Float): Pair<Float, Float> =
    (visibleAlpha / PlatformSpotShadowAlpha).coerceAtMost(1f) to
        (visibleAlpha / PlatformAmbientShadowAlpha).coerceAtMost(1f)

/** Ink for shadows: the appearance's own ink on light pages, true ink under Graphite (never a glow). */
@Composable
fun shadowInk(): Color =
    if (LocalAppAppearance.current == AppAppearance.GRAPHITE) Ink else MaterialTheme.colorScheme.onSurface

private fun Modifier.inkShadow(elevation: Dp, shape: Shape, ink: Color, visibleAlpha: Float): Modifier {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
        // API 26-27 ignore shadow colours and draw black at the platform alphas, so any lift is
        // the stock 1dp contact shadow (Material's resting card); never the heavier 3dp or 12dp.
        return shadow(DesignTokens.Elevation.contactShadow, shape, clip = false)
    }
    val (spot, ambient) = inkShadowAlphas(visibleAlpha)
    return shadow(
        elevation,
        shape,
        clip = false,
        ambientColor = ink.copy(alpha = ambient),
        spotColor = ink.copy(alpha = spot)
    )
}

/**
 * Fills the container for its [level]. With [topHighlight] a 1dp line of the brightest surface
 * sits inside the top edge (pressed paper), clipped to [shape].
 */
@Composable
fun Modifier.raisedSurface(level: SurfaceLevel, shape: Shape, topHighlight: Boolean = false): Modifier {
    val colorScheme = MaterialTheme.colorScheme
    val tokens = DesignTokens.Elevation
    val filled = when (level) {
        SurfaceLevel.Page -> background(colorScheme.surface, shape)
        SurfaceLevel.Raised -> background(colorScheme.surfaceContainerLow, shape)
        SurfaceLevel.Floating -> inkShadow(tokens.floatingShadow, shape, shadowInk(), tokens.floatingShadowAlpha)
            .background(colorScheme.surfaceContainerHigh, shape)
            .border(tokens.hairline, colorScheme.outlineVariant.copy(alpha = tokens.hairlineAlpha), shape)
    }
    if (!topHighlight) return filled
    // surfaceBright, not surface: under Graphite the surface is darker than the slab.
    val highlight = colorScheme.surfaceBright.copy(alpha = tokens.rowHighlightAlpha)
    return filled.drawWithCache {
        val outline = Path().apply { addOutline(shape.createOutline(size, layoutDirection, this@drawWithCache)) }
        val line = Size(size.width, tokens.rowHighlight.toPx())
        onDrawWithContent {
            drawContent()
            clipPath(outline) { drawRect(highlight, size = line) }
        }
    }
}

/**
 * Floating chrome (UnBlock, mic, capture buttons): a tight contact shadow plus a soft ambient one.
 * Reduced motion or high text contrast keeps only the contact shadow.
 */
@Composable
fun Modifier.floatingChromeShadow(shape: Shape): Modifier {
    val ink = shadowInk()
    val tokens = DesignTokens.Elevation
    val contact = inkShadow(tokens.contactShadow, shape, ink, tokens.contactShadowAlpha)
    val calm = !LocalAnimationsEnabled.current || LocalHighTextContrastEnabled.current ||
        Build.VERSION.SDK_INT < Build.VERSION_CODES.P
    return if (calm) contact else contact.inkShadow(tokens.ambientShadow, shape, ink, tokens.ambientShadowAlpha)
}
