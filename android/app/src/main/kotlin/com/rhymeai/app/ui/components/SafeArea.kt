package com.rhymeai.app.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.rhymeai.app.ui.theme.DesignTokens

val LocalNavBottom = compositionLocalOf<Dp> { 0.dp }
val LocalImeBottom = compositionLocalOf<Dp> { 0.dp }
val LocalStatusBarTop = compositionLocalOf<Dp> { 0.dp }

@Composable
internal fun navigationBarBottomPadding(extra: Dp = DesignTokens.Spacing.lg): Dp {
    val density = LocalDensity.current
    val localNav = LocalNavBottom.current
    val navigationBarBottom = if (localNav > 0.dp) {
        localNav
    } else {
        with(density) { WindowInsets.navigationBars.getBottom(density).toDp() }
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
    val localIme = LocalImeBottom.current
    val localNav = LocalNavBottom.current

    val fallbackIme = with(density) { WindowInsets.ime.getBottom(density).toDp() }
    val fallbackNav = with(density) { WindowInsets.navigationBars.getBottom(density).toDp() }

    val imeBottom = if (localIme > 0.dp) localIme else fallbackIme
    val navBottom = if (localNav > 0.dp) localNav else fallbackNav

    val bottomInset = maxOf(imeBottom, navBottom)
    return bottomInset + extra
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
/**
 * Wraps [content] in a [Column] that sits above the system navigation bar.
 *
 * The Column's background fills the screen edge-to-edge (the parent should
 * provide that background via its own Surface), and the content is padded by
 * `navigationBars + extra` so that interactive controls stay clear of the
 * gesture indicator on every device.
 */
@Composable
internal fun BottomSafeActionArea(
    modifier: Modifier = Modifier,
    extra: Dp = DesignTokens.Spacing.xxl,
    horizontalAlignment: Alignment.Horizontal = Alignment.CenterHorizontally,
    content: @Composable () -> Unit
) {
    Column(
        modifier = modifier.padding(bottom = navigationBarBottomPadding(extra)),
        horizontalAlignment = horizontalAlignment
    ) {
        content()
    }
}
