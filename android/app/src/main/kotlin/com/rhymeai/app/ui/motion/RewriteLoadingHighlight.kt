package com.rhymeai.app.ui.motion

import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.style.ResolvedTextDirection
import androidx.compose.ui.unit.dp
import kotlin.math.PI
import kotlin.math.sin

data class RewriteHighlightState(
    val range: TextRange?,
    val loading: Boolean,
    val error: Boolean,
    val motionStyle: RewriteMotionStyle,
    val progress: () -> Float
) {
    companion object {
        const val stableProgress = 0.72f
    }
}

data class RewriteHighlightColors(
    val fill: Color,
    val stroke: Color,
    val motion: Color,
    val paper: Color
)

private data class SelectedLineBounds(
    val left: Float,
    val right: Float,
    val top: Float,
    val bottom: Float,
    val revealFromRight: Boolean
)

fun Modifier.rewriteLoadingHighlight(
    textLayoutResult: TextLayoutResult?,
    state: RewriteHighlightState,
    colors: RewriteHighlightColors
): Modifier {
    val range = state.range ?: return this

    return drawWithCache {
        val layout = textLayoutResult
        val textLength = layout?.layoutInput?.text?.text?.length ?: 0
        val start = range.min.coerceIn(0, textLength)
        val end = range.max.coerceIn(0, textLength)
        if (layout == null || start >= end) {
            onDrawWithContent { drawContent() }
        } else {
            val selectionPath = layout.getPathForRange(start, end)
            val lines = layout.selectedLineBounds(start, end)
            onDrawWithContent {
                if (state.error || !state.loading) {
                    drawPath(selectionPath, colors.fill)
                    drawPath(selectionPath, colors.stroke, style = Stroke(width = 1.dp.toPx()))
                    drawContent()
                    return@onDrawWithContent
                }

                val progress = state.progress().coerceIn(0f, 1f)
                when (state.motionStyle) {
                    RewriteMotionStyle.PENCIL -> {
                        drawPath(selectionPath, colors.fill.copy(alpha = colors.fill.alpha * 0.72f))
                        drawContent()
                        lines.forEach { bounds ->
                            clipToLine(bounds) {
                                drawPencilRevision(bounds, progress, colors.motion)
                            }
                        }
                    }
                    RewriteMotionStyle.RIPPLE -> {
                        drawPath(selectionPath, colors.fill.copy(alpha = colors.fill.alpha * 0.62f))
                        drawContent()
                        lines.forEach { bounds ->
                            clipToLine(bounds) {
                                drawRhymeRipple(bounds, progress, colors.motion)
                            }
                        }
                    }
                    RewriteMotionStyle.PAPER -> {
                        lines.forEach { bounds ->
                            clipToLine(bounds) {
                                drawPaperSlip(bounds, progress, colors.paper, colors.motion)
                            }
                        }
                        drawContent()
                        lines.forEach { bounds ->
                            clipToLine(bounds) {
                                drawPaperFold(bounds, progress, colors.motion)
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun TextLayoutResult.selectedLineBounds(start: Int, end: Int): List<SelectedLineBounds> {
    val bounds = mutableListOf<SelectedLineBounds>()
    var current: SelectedLineBounds? = null
    for (offset in start until end) {
        val box = getBoundingBox(offset)
        if (box.width <= 0f || box.height <= 0f) continue
        val revealFromRight = getBidiRunDirection(offset) == ResolvedTextDirection.Rtl
        val candidate = SelectedLineBounds(
            left = box.left,
            right = box.right,
            top = box.top,
            bottom = box.bottom,
            revealFromRight = revealFromRight
        )
        val active = current
        current = if (
            active != null &&
            active.top == candidate.top &&
            active.bottom == candidate.bottom &&
            active.revealFromRight == candidate.revealFromRight
        ) {
            active.copy(
                left = minOf(active.left, candidate.left),
                right = maxOf(active.right, candidate.right)
            )
        } else {
            if (active != null) bounds += active
            candidate
        }
    }
    if (current != null) bounds += current
    return bounds
}

private inline fun DrawScope.clipToLine(
    bounds: SelectedLineBounds,
    draw: DrawScope.() -> Unit
) {
    clipRect(bounds.left, bounds.top, bounds.right, bounds.bottom, block = draw)
}

internal fun pencilRevealFraction(progress: Float): Float {
    val value = progress.coerceIn(0f, 1f)
    return when {
        value < 0.60f -> value / 0.60f
        value < 0.82f -> 1f
        else -> ((1f - value) / 0.18f).coerceIn(0f, 1f)
    }
}

internal fun pencilFleckAlpha(progress: Float): Float {
    val value = progress.coerceIn(0f, 1f)
    return when {
        value < 0.52f -> 0f
        value < 0.68f -> (value - 0.52f) / 0.16f
        value < 0.82f -> 1f
        else -> ((1f - value) / 0.18f).coerceIn(0f, 1f)
    }
}

internal fun paperSlipEnterFraction(progress: Float): Float {
    val normalized = (progress.coerceIn(0f, 1f) / 0.24f).coerceIn(0f, 1f)
    val remaining = 1f - normalized
    return 1f - remaining * remaining * remaining
}

internal fun paperSlipAlpha(progress: Float): Float {
    val value = progress.coerceIn(0f, 1f)
    return when {
        value < 0.18f -> value / 0.18f
        value < 0.82f -> 1f
        else -> ((1f - value) / 0.18f).coerceIn(0f, 1f)
    }
}

private fun DrawScope.drawPencilRevision(
    bounds: SelectedLineBounds,
    progress: Float,
    color: Color
) {
    val reveal = pencilRevealFraction(progress)
    val width = bounds.right - bounds.left
    val startX = if (bounds.revealFromRight) bounds.right else bounds.left
    val endX = startX + if (bounds.revealFromRight) -width * reveal else width * reveal
    val baseY = bounds.bottom - 2.25.dp.toPx()
    drawRoughLine(
        startX = startX,
        endX = endX,
        y = baseY,
        amplitude = 0.7.dp.toPx(),
        color = color.copy(alpha = 0.92f),
        strokeWidth = 1.35.dp.toPx()
    )
    drawRoughLine(
        startX = startX,
        endX = endX,
        y = baseY + 1.45.dp.toPx(),
        amplitude = 0.45.dp.toPx(),
        color = color.copy(alpha = 0.48f),
        strokeWidth = 0.8.dp.toPx()
    )

    val fleckAlpha = pencilFleckAlpha(progress)
    if (fleckAlpha > 0f) {
        val direction = if (bounds.revealFromRight) -1f else 1f
        val firstRadius = 0.9.dp.toPx()
        val secondRadius = 0.55.dp.toPx()
        drawCircle(
            color = color.copy(alpha = fleckAlpha * 0.55f),
            radius = firstRadius,
            center = Offset(
                x = (endX - direction * 4.dp.toPx())
                    .coerceIn(bounds.left + firstRadius, bounds.right - firstRadius),
                y = baseY - 3.dp.toPx()
            )
        )
        drawCircle(
            color = color.copy(alpha = fleckAlpha * 0.36f),
            radius = secondRadius,
            center = Offset(
                x = (endX + direction * 1.5.dp.toPx())
                    .coerceIn(bounds.left + secondRadius, bounds.right - secondRadius),
                y = baseY - 1.dp.toPx()
            )
        )
    }
}

private fun DrawScope.drawRoughLine(
    startX: Float,
    endX: Float,
    y: Float,
    amplitude: Float,
    color: Color,
    strokeWidth: Float
) {
    var previous = Offset(startX, y)
    repeat(7) { index ->
        val fraction = (index + 1) / 7f
        val jitter = if (index % 2 == 0) amplitude else -amplitude
        val next = Offset(startX + (endX - startX) * fraction, y + jitter)
        drawLine(color, previous, next, strokeWidth)
        previous = next
    }
}

private fun DrawScope.drawRhymeRipple(
    bounds: SelectedLineBounds,
    progress: Float,
    color: Color
) {
    val phase = progress * (2f * PI.toFloat())
    val baseY = bounds.bottom - 3.5.dp.toPx()
    drawWave(bounds, baseY, phase, 1.45.dp.toPx(), color.copy(alpha = 0.88f), 1.2.dp.toPx())
    drawWave(
        bounds = bounds,
        y = bounds.bottom - 1.35.dp.toPx(),
        phase = phase + PI.toFloat() * 0.7f,
        amplitude = 0.8.dp.toPx(),
        color = color.copy(alpha = 0.42f),
        strokeWidth = 0.8.dp.toPx()
    )
}

private fun DrawScope.drawWave(
    bounds: SelectedLineBounds,
    y: Float,
    phase: Float,
    amplitude: Float,
    color: Color,
    strokeWidth: Float
) {
    var previous = Offset(bounds.left, y + sin(phase) * amplitude)
    repeat(24) { index ->
        val fraction = (index + 1) / 24f
        val angle = fraction * 4f * PI.toFloat() + phase
        val next = Offset(
            x = bounds.left + (bounds.right - bounds.left) * fraction,
            y = y + sin(angle) * amplitude
        )
        drawLine(color, previous, next, strokeWidth)
        previous = next
    }
}

private fun DrawScope.drawPaperSlip(
    bounds: SelectedLineBounds,
    progress: Float,
    paper: Color,
    edge: Color
) {
    val enter = paperSlipEnterFraction(progress)
    val alpha = paperSlipAlpha(progress)
    val horizontalOffset = -3.dp.toPx() * (1f - enter)
    val verticalOffset = 1.25.dp.toPx() * (1f - enter)
    val insetX = 0.75.dp.toPx()
    val insetY = 0.5.dp.toPx()
    val left = bounds.left + insetX + horizontalOffset
    val top = bounds.top + insetY + verticalOffset
    val width = (bounds.right - insetX - left).coerceAtLeast(0f)
    val height = (bounds.bottom - insetY - top).coerceAtLeast(0f)
    val radius = 3.dp.toPx()
    drawRoundRect(
        color = edge.copy(alpha = alpha * 0.18f),
        topLeft = Offset(left + 1.5.dp.toPx(), top + 2.dp.toPx()),
        size = Size(width, height),
        cornerRadius = CornerRadius(radius)
    )
    drawRoundRect(
        color = paper.copy(alpha = paper.alpha * alpha),
        topLeft = Offset(left, top),
        size = Size(width, height),
        cornerRadius = CornerRadius(radius)
    )
}

private fun DrawScope.drawPaperFold(
    bounds: SelectedLineBounds,
    progress: Float,
    edge: Color
) {
    val enter = paperSlipEnterFraction(progress)
    val alpha = paperSlipAlpha(progress)
    val horizontalOffset = -3.dp.toPx() * (1f - enter)
    val verticalOffset = 1.25.dp.toPx() * (1f - enter)
    val right = bounds.right - 1.dp.toPx() + horizontalOffset
    val top = bounds.top + 1.dp.toPx() + verticalOffset
    drawLine(
        color = edge.copy(alpha = alpha * 0.64f),
        start = Offset(right - 7.dp.toPx(), top),
        end = Offset(right, top + 7.dp.toPx()),
        strokeWidth = 0.9.dp.toPx()
    )
}
