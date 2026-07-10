package com.rhymeai.app.ui.screens

import androidx.compose.ui.unit.Dp
import com.rhymeai.app.ui.theme.DesignTokens

internal fun unBlockWordmarkWidth(measuredWordmarkWidth: Dp): Dp =
    maxOf(DesignTokens.EditorChrome.unBlockScribbleWidth, measuredWordmarkWidth)

internal fun unBlockButtonWidth(
    measuredWordmarkWidth: Dp,
    maxAvailableWidth: Dp
): Dp {
    val desiredWidth = DesignTokens.EditorChrome.unBlockIconSize +
        DesignTokens.EditorChrome.unBlockWordmarkGap +
        unBlockWordmarkWidth(measuredWordmarkWidth) +
        DesignTokens.EditorChrome.unBlockHorizontalPadding
    return desiredWidth
        .coerceAtLeast(DesignTokens.EditorChrome.unBlockExtendedWidth)
        .coerceAtMost(maxAvailableWidth)
}
