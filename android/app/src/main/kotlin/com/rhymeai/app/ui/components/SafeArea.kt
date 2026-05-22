package com.rhymeai.app.ui.components

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import com.rhymeai.app.ui.theme.DesignTokens

@Composable
internal fun navigationBarBottomPadding(extra: Dp = DesignTokens.Spacing.lg): Dp {
    val density = LocalDensity.current
    val navigationBarBottom = with(density) {
        WindowInsets.navigationBars.getBottom(density).toDp()
    }
    return navigationBarBottom + extra
}

internal fun Modifier.bottomSafeActionPadding(
    extra: Dp = DesignTokens.Spacing.xxl
): Modifier = composed {
    padding(bottom = navigationBarBottomPadding(extra))
}

@Composable
internal fun keyboardAwareBottomPadding(extra: Dp = DesignTokens.Spacing.xxl): Dp {
    val density = LocalDensity.current
    val bottomInset = maxOf(
        WindowInsets.ime.getBottom(density),
        WindowInsets.navigationBars.getBottom(density)
    )
    return with(density) { bottomInset.toDp() } + extra
}

@Composable
internal fun KeyboardSafeActionArea(
    modifier: Modifier = Modifier,
    extra: Dp = DesignTokens.Spacing.xxl,
    horizontalAlignment: Alignment.Horizontal = Alignment.CenterHorizontally,
    content: @Composable () -> Unit
) {
    Column(
        modifier = modifier.padding(bottom = keyboardAwareBottomPadding(extra = extra)),
        horizontalAlignment = horizontalAlignment
    ) {
        content()
    }
}

@Composable
internal fun BottomSafeActionArea(
    modifier: Modifier = Modifier,
    extra: Dp = DesignTokens.Spacing.xxl,
    horizontalAlignment: Alignment.Horizontal = Alignment.CenterHorizontally,
    content: @Composable () -> Unit
) {
    Column(
        modifier = modifier
            .bottomSafeActionPadding(extra = extra)
            .offset(y = -extra),
        horizontalAlignment = horizontalAlignment
    ) {
        content()
    }
}
