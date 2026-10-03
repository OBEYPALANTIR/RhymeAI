package com.rhymeai.app.ui.theme

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext

private const val HighTextContrastSetting = "high_text_contrast_enabled"

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
val LocalHighTextContrastEnabled = compositionLocalOf { false }

@Composable
fun rememberAnimationsEnabledFromSystem(): Boolean {
    val context = LocalContext.current
    fun readSetting(): Boolean =
        try {
            Settings.Global.getFloat(
                context.contentResolver,
                Settings.Global.ANIMATOR_DURATION_SCALE,
                1f
            )
        } catch (_: Settings.SettingNotFoundException) {
            1f
        } > 0f

    var enabled by remember(context) { mutableStateOf(readSetting()) }
    DisposableEffect(context) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                enabled = readSetting()
            }
        }
        context.contentResolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE),
            false,
            observer
        )
        onDispose { context.contentResolver.unregisterContentObserver(observer) }
    }
    return enabled
}

@Composable
private fun rememberHighTextContrastEnabledFromSystem(): Boolean {
    val context = LocalContext.current
    fun readSetting(): Boolean =
        Settings.Secure.getInt(context.contentResolver, HighTextContrastSetting, 0) == 1

    var enabled by remember(context) { mutableStateOf(readSetting()) }
    DisposableEffect(context) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                enabled = readSetting()
            }
        }
        context.contentResolver.registerContentObserver(
            Settings.Secure.getUriFor(HighTextContrastSetting),
            false,
            observer
        )
        onDispose { context.contentResolver.unregisterContentObserver(observer) }
    }
    return enabled
}

@Composable
fun ProvideAccessibleAnimations(content: @Composable () -> Unit) {
    val animationsEnabled = rememberAnimationsEnabledFromSystem()
    val highTextContrastEnabled = rememberHighTextContrastEnabledFromSystem()
    CompositionLocalProvider(
        LocalAnimationsEnabled provides animationsEnabled,
        LocalHighTextContrastEnabled provides highTextContrastEnabled,
        content = content
    )
}
