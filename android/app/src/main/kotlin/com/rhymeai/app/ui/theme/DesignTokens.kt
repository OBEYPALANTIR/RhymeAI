package com.rhymeai.app.ui.theme

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.spring
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object DesignTokens {
    object Phi {
        const val ratio = 1.6180339f
        const val inverse = 0.6180339f
        const val major = ratio
        const val minor = inverse
    }

    object Spacing {
        val xs = 4.dp
        val sm = 8.dp
        val md = 12.dp
        val lg = 20.dp
        val xl = 24.dp
        val xxl = 32.dp
        val golden = 52.dp
    }

    object Typography {
        // De-facto caption size used across dialogs, sheets, and the editor for
        // secondary/support text — the 13px rung of the φ-rounded 12/13px caption tier.
        val caption = 13.sp
    }

    object Touch {
        val minTarget = 48.dp
    }

    object Indicator {
        val spinnerSm = 14.dp
        val spinnerMd = 16.dp
    }

    object Editor {
        val horizontalPadding = 24.dp
        val bottomRest = 300.dp
        val keyboardOffset = 72.dp
        val estimatedCharacterWidth = 8.5.dp
        val lyricMeasureLineHeight = 28.dp
        val lyricFontSize = 16.sp
        val lyricLineHeight = 28.sp
        val syllableUnderlineGap = 2.dp
        val syllableUnderlineWidth = 3.dp
    }

    object EditorChrome {
        val saveStatusStrokeWidth = 2.dp
        val statsEndPadding = 4.dp
        val fabSize = 56.dp
        val micRecordingWidth = 216.dp
        val micRecordingRestWidth = fabSize
        val unBlockExtendedWidth = 150.dp
        val unBlockScribbleWidth = 68.dp
        val unBlockHorizontalPadding = 32.dp
        val recordingContentGap = 8.dp
        val recordingContentStartPadding = 16.dp
        val recordingMeterHeight = 24.dp
        val recordingMinBarHeight = 2.dp
        val recordingIconSize = 24.dp
        val recordingElapsedFontSize = 12.sp
        val unBlockIconSize = 18.dp
        val unBlockWordmarkGap = 8.dp
        const val recordingBarCount = 22
        const val recordingBarsFadeStart = 0.55f
        const val recordingBarsFadeDistance = 0.30f
    }

    object Sheet {
        val handleArea = 64.dp
        val handleWidth = 52.dp
        val handleHeight = 4.dp
    }

    object Drawer {
        val compactWidth = 304.dp
        val width = 360.dp
        val expandedWidth = 584.dp
    }

    object Radius {
        val xs = 6.dp
        val sm = 8.dp
        val md = 10.dp
        val lg = 12.dp
        val xl = 14.dp
        val xxl = 16.dp
        val xxxl = 18.dp
        val sheet = 22.dp
        val pill = 28.dp
        val appIcon = 22.dp
        val appIconShell = 30.dp
    }

    object Motion {
        // Golden-ratio duration ladder: 0.16 ×φ ≈0.26 ×φ ≈0.42 (φ=1.618). Utilitarian tiers ≤0.50s.
        const val feedbackMillis = 160
        const val dismissMillis = 160
        const val standardMillis = 260
        const val dialogMillis = 260
        const val assistantPresentMillis = 260
        const val sheetPresentMillis = 260
        const val drawerPresentMillis = 260
        const val dragSettleMillis = 420
        const val rewriteShimmerMillis = 1200

        val standardEasing: Easing = CubicBezierEasing(0.2f, 0f, 0f, 1f)
        val emphasizedEasing: Easing = CubicBezierEasing(0.2f, 0f, 0f, 1f)
        val exitEasing: Easing = CubicBezierEasing(0.4f, 0f, 1f, 1f)

        fun <T> standardSpring(visibilityThreshold: T? = null): SpringSpec<T> = spring(
            dampingRatio = 0.88f,
            stiffness = Spring.StiffnessMediumLow,
            visibilityThreshold = visibilityThreshold
        )

        fun <T> settleSpring(visibilityThreshold: T? = null): SpringSpec<T> = spring(
            dampingRatio = 0.80f,
            stiffness = Spring.StiffnessLow,
            visibilityThreshold = visibilityThreshold
        )

        /**
         * Expressive spring for the mic↔pill choreography AND the UnBlock FAB
         * fall-down, so both travel on one clock the way iOS does.
         *
         * Tuned to match the iOS reference `spring(response: 0.40, dampingFraction: 0.76)`.
         * SwiftUI's `response` maps to Compose stiffness via stiffness = (2π / response)²
         * ≈ 247, and `dampingFraction` maps directly to `dampingRatio`. Result is a
         * ~0.4s glide with a subtle settle — no hard snap — identical in feel to iOS.
         * (The previous StiffnessMedium = 1500 gave a ~0.16s snap that desynced from iOS.)
         */
        fun <T> expressiveSpring(visibilityThreshold: T? = null): SpringSpec<T> = spring(
            dampingRatio = 0.76f,
            stiffness = 247f,
            visibilityThreshold = visibilityThreshold
        )
    }
}
