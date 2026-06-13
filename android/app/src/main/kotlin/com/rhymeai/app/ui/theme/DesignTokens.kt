package com.rhymeai.app.ui.theme

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.spring
import androidx.compose.ui.unit.dp

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
        const val feedbackMillis = 180
        const val dismissMillis = 180
        const val standardMillis = 260
        const val dialogMillis = 260
        const val assistantPresentMillis = 340
        const val sheetPresentMillis = 340
        const val drawerPresentMillis = 340
        const val dragSettleMillis = 420

        val standardEasing: Easing = CubicBezierEasing(0.2f, 0f, 0f, 1f)
        val emphasizedEasing: Easing = CubicBezierEasing(0.2f, 0f, 0f, 1f)
        val exitEasing: Easing = CubicBezierEasing(0.4f, 0f, 1f, 1f)

        fun <T> standardSpring(visibilityThreshold: T? = null): SpringSpec<T> = spring(
            dampingRatio = 0.88f,
            stiffness = Spring.StiffnessMediumLow,
            visibilityThreshold = visibilityThreshold
        )

        fun <T> settleSpring(visibilityThreshold: T? = null): SpringSpec<T> = spring(
            dampingRatio = 0.72f,
            stiffness = Spring.StiffnessLow,
            visibilityThreshold = visibilityThreshold
        )

        /**
         * Expressive spring for personality-forward shape/size transitions — used by
         * the mic↔pill choreography. dampingRatio 0.65 gives a gentle overshoot;
         * StiffnessMedium (~400 N/m) keeps the total duration under ~400ms.
         *
         * iOS equivalent: spring(response: 0.38, dampingFraction: 0.65)
         */
        fun <T> expressiveSpring(visibilityThreshold: T? = null): SpringSpec<T> = spring(
            dampingRatio = 0.65f,
            stiffness = Spring.StiffnessMedium,
            visibilityThreshold = visibilityThreshold
        )
    }
}
