package com.rhymeai.app.ui.theme

import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext

/**
 * True when the user has not disabled animations via Settings → Accessibility → "Remove animations".
 *
 * Jetpack Compose's built-in `tween`, `spring`, `keyframes`, and `AnimatedVisibility`
 * already honour the system `MotionDurationScale` (which the OS zeros when the user
 * removes animations), so most call sites need no change. Use this flag only when a
 * non-time-driven animation (e.g. a custom drag transition with manual offset math)
 * needs an explicit "skip animation" branch.
 */
val LocalAnimationsEnabled = compositionLocalOf { true }

@Composable
fun rememberAnimationsEnabledFromSystem(): Boolean {
    val context = LocalContext.current
    val enabled = remember(context) {
        try {
            Settings.Global.getFloat(
                context.contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f
            )
        } catch (_: Settings.SettingNotFoundException) {
            1f
        } > 0f
    }
    return enabled
}

@Composable
fun ProvideAccessibleAnimations(content: @Composable () -> Unit) {
    val enabled = rememberAnimationsEnabledFromSystem()
    CompositionLocalProvider(LocalAnimationsEnabled provides enabled, content = content)
}
