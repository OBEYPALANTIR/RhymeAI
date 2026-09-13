package com.rhymeai.app.ui.motion

import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.unit.dp

data class RewriteHighlightState(
    val range: TextRange?
)

data class RewriteHighlightColors(
    val fill: Color,
    val stroke: Color
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
            onDrawWithContent {
                drawPath(selectionPath, colors.fill)
                drawPath(selectionPath, colors.stroke, style = Stroke(width = 1.dp.toPx()))
                drawContent()
            }
        }
    }
}
