package com.rhymeai.app.ui.theme

import androidx.compose.foundation.background
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.center
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.rhymeai.app.data.model.AppAppearance
import kotlin.math.hypot

private class Grain(
    val color: Color,
    val columnSpacing: Dp,
    val markLength: Dp,
    val strokeWidth: Dp,
    val vignetteAlpha: Float = 0f
)

private fun grainFor(appearance: AppAppearance): Grain = when (appearance) {
    // Warm fibre and a faint edge vignette.
    AppAppearance.PAPER -> Grain(PaperOutline.copy(alpha = 0.045f), 22.dp, 0.8.dp, 0.75.dp, vignetteAlpha = 0.02f)
    // Finer and tighter.
    AppAppearance.INK -> Grain(InkOutline.copy(alpha = 0.03f), 16.dp, 0.6.dp, 0.6.dp)
    AppAppearance.GRAPHITE -> Grain(GraphiteWarmWhite.copy(alpha = 0.04f), 22.dp, 0.8.dp, 0.75.dp)
}

@Composable
fun Modifier.appWritingSurface(baseColor: Color = MaterialTheme.colorScheme.background): Modifier {
    val appearance = LocalAppAppearance.current
    val vignetteInk = MaterialTheme.colorScheme.onSurface
    val textureEnabled = !LocalHighTextContrastEnabled.current

    val baseModifier = background(baseColor)
    if (!textureEnabled) return baseModifier
    val grain = grainFor(appearance)

    return baseModifier.drawWithCache {
        val marks = Path().apply {
            val rowSpacing = 16.dp.toPx()
            val columnSpacing = grain.columnSpacing.toPx()
            val markLength = grain.markLength.toPx()
            var row = 0
            var y = 8.dp.toPx()
            while (y < size.height) {
                var x = (6 + (row % 3) * 5).dp.toPx()
                while (x < size.width) {
                    moveTo(x, y)
                    lineTo(x + markLength, y + markLength * 0.35f)
                    x += columnSpacing
                }
                row += 1
                y += rowSpacing
            }
        }
        val stroke = Stroke(width = grain.strokeWidth.toPx())
        val vignette = if (grain.vignetteAlpha > 0f) {
            Brush.radialGradient(
                0.35f to Color.Transparent,
                1f to vignetteInk.copy(alpha = grain.vignetteAlpha),
                center = size.center,
                radius = hypot(size.width, size.height) / 2f
            )
        } else {
            null
        }
        onDrawBehind {
            drawPath(path = marks, color = grain.color, style = stroke)
            vignette?.let { drawRect(it) }
        }
    }
}
