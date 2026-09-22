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

    object Rhythm {
        val tight = 8.dp
        val related = 13.dp
        val standard = 21.dp
        val section = 34.dp
        val primary = 55.dp
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
        val horizontalPadding = Rhythm.standard
        val bottomRest = 300.dp
        val keyboardOffset = 72.dp
        val estimatedCharacterWidth = 8.5.dp
        val lyricMeasureLineHeight = 27.dp
        val lyricFontSize = 17.sp
        val lyricLineHeight = 27.sp
        val titleFontSize = 34.sp
        val titleLineHeight = 42.sp
        val metadataFontSize = 13.sp
        val metadataLineHeight = 16.sp
        val syllableUnderlineGap = 2.dp
        val syllableUnderlineWidth = 3.dp
    }

    object EditorChrome {
        val saveStatusStrokeWidth = 2.dp
        val fabSize = Rhythm.primary
        val micRecordingWidth = 216.dp
        val micRecordingRestWidth = fabSize
        val unBlockExtendedWidth = 144.dp
        val unBlockScribbleWidth = 68.dp
        val unBlockHorizontalPadding = Rhythm.standard
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
        // Feedback is brief; occasional surfaces preserve spatial origin.
        const val feedbackMillis = 160
        const val pageFadeMillis = 140
        const val dismissMillis = 160
        const val disclosureMillis = 200
        const val standardMillis = 260
        const val dialogMillis = 260
        const val assistantPresentMillis = 260
        const val sheetPresentMillis = 260
        const val drawerPresentMillis = 260

        val standardEasing: Easing = CubicBezierEasing(0.23f, 1f, 0.32f, 1f)
        val emphasizedEasing: Easing = CubicBezierEasing(0.23f, 1f, 0.32f, 1f)
        val exitEasing: Easing = standardEasing

        fun <T> settleSpring(visibilityThreshold: T? = null): SpringSpec<T> = spring(
            dampingRatio = 0.80f,
            stiffness = Spring.StiffnessLow,
            visibilityThreshold = visibilityThreshold
        )


    }
}
