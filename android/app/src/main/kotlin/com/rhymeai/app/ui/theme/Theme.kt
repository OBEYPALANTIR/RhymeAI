package com.rhymeai.app.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import com.rhymeai.app.data.model.AppAppearance

val InkColorScheme = lightColorScheme(
    primary = Ink,
    onPrimary = PaperWhite,
    primaryContainer = InkSurfaceHighest,
    onPrimaryContainer = Ink,
    inversePrimary = GraphiteWarmWhite,
    secondary = Pencil,
    onSecondary = PaperWhite,
    secondaryContainer = InkSurfaceHigh,
    onSecondaryContainer = Ink,
    tertiary = SuccessLight,
    onTertiary = OnSuccessLight,
    tertiaryContainer = SuccessContainerLight,
    onTertiaryContainer = OnSuccessContainerLight,
    background = PaperWhite,
    onBackground = Ink,
    surface = PaperWhite,
    onSurface = Ink,
    surfaceVariant = InkSurface,
    onSurfaceVariant = InkMuted,
    surfaceTint = Ink,
    inverseSurface = GraphiteSurfaceBase,
    inverseOnSurface = GraphiteWarmWhite,
    error = ErrorLight,
    onError = OnErrorLight,
    errorContainer = OnErrorDark,
    onErrorContainer = ErrorDark,
    outline = InkOutlineStrong,
    outlineVariant = InkOutlineStrong,
    scrim = InkScrim,
    surfaceBright = PaperWhite,
    surfaceDim = InkSurfaceHigh,
    surfaceContainer = InkSurface,
    surfaceContainerHigh = InkSurfaceHigh,
    surfaceContainerHighest = InkSurfaceHighest,
    surfaceContainerLow = InkSurfaceLow,
    surfaceContainerLowest = PaperWhite
)

val PaperColorScheme = lightColorScheme(
    primary = Pencil,
    onPrimary = PaperActionForeground,
    primaryContainer = PaperSurfaceHighest,
    onPrimaryContainer = Pencil,
    inversePrimary = GraphiteWarmWhite,
    secondary = PaperMuted,
    onSecondary = PaperActionForeground,
    secondaryContainer = PaperSurfaceHigh,
    onSecondaryContainer = Pencil,
    tertiary = SuccessLight,
    onTertiary = OnSuccessLight,
    tertiaryContainer = SuccessContainerLight,
    onTertiaryContainer = OnSuccessContainerLight,
    background = PaperIvory,
    onBackground = Pencil,
    surface = PaperSurface,
    onSurface = Pencil,
    surfaceVariant = PaperSurfaceContainer,
    onSurfaceVariant = PaperMuted,
    surfaceTint = Pencil,
    inverseSurface = Pencil,
    inverseOnSurface = PaperActionForeground,
    error = ErrorLight,
    onError = OnErrorLight,
    errorContainer = OnErrorDark,
    onErrorContainer = ErrorDark,
    outline = PaperOutlineStrong,
    outlineVariant = PaperOutlineStrong,
    scrim = PaperScrim,
    surfaceBright = PaperSurface,
    surfaceDim = PaperSurfaceHigh,
    surfaceContainer = PaperSurfaceContainer,
    surfaceContainerHigh = PaperSurfaceHigh,
    surfaceContainerHighest = PaperSurfaceHighest,
    surfaceContainerLow = PaperSurfaceLow,
    surfaceContainerLowest = PaperIvory
)

val GraphiteColorScheme = darkColorScheme(
    primary = GraphiteWarmWhite,
    onPrimary = Graphite,
    primaryContainer = GraphiteSelection,
    onPrimaryContainer = GraphiteWarmWhite,
    inversePrimary = Ink,
    secondary = GraphiteMuted,
    onSecondary = Graphite,
    secondaryContainer = GraphiteSurfaceHigh,
    onSecondaryContainer = GraphiteWarmWhite,
    tertiary = SuccessDark,
    onTertiary = OnSuccessDark,
    tertiaryContainer = SuccessContainerDark,
    onTertiaryContainer = OnSuccessContainerDark,
    background = Graphite,
    onBackground = GraphiteWarmWhite,
    surface = GraphiteSurfaceBase,
    onSurface = GraphiteWarmWhite,
    surfaceVariant = GraphiteSurface,
    onSurfaceVariant = GraphiteMuted,
    surfaceTint = GraphiteWarmWhite,
    inverseSurface = GraphiteWarmWhite,
    inverseOnSurface = Graphite,
    error = ErrorDark,
    onError = OnErrorDark,
    errorContainer = OnErrorDark,
    onErrorContainer = ErrorDark,
    outline = GraphiteOutlineStrong,
    outlineVariant = GraphiteOutlineStrong,
    scrim = GraphiteScrim,
    surfaceBright = GraphiteSurfaceHighest,
    surfaceDim = Graphite,
    surfaceContainer = GraphiteSurface,
    surfaceContainerHigh = GraphiteSurfaceHigh,
    surfaceContainerHighest = GraphiteSurfaceHighest,
    surfaceContainerLow = GraphiteSurfaceLow,
    surfaceContainerLowest = Graphite
)

val LocalAppAppearance = staticCompositionLocalOf { AppAppearance.INK }

val RhymeShapes = Shapes(
    small = RoundedCornerShape(DesignTokens.Radius.sm),
    medium = RoundedCornerShape(DesignTokens.Radius.md),
    large = RoundedCornerShape(DesignTokens.Radius.lg)
)

internal fun colorSchemeFor(appearance: AppAppearance): ColorScheme = when (appearance) {
    AppAppearance.INK -> InkColorScheme
    AppAppearance.PAPER -> PaperColorScheme
    AppAppearance.GRAPHITE -> GraphiteColorScheme
}

internal fun placeholderColorFor(appearance: AppAppearance) = when (appearance) {
    AppAppearance.INK -> InkOutlineStrong
    AppAppearance.PAPER -> PaperMuted
    AppAppearance.GRAPHITE -> GraphitePlaceholder
}

internal fun subtleColorFor(appearance: AppAppearance) = when (appearance) {
    AppAppearance.INK -> InkSubtle
    AppAppearance.PAPER -> PaperSubtle
    AppAppearance.GRAPHITE -> GraphiteSubtle
}

internal fun selectionColorFor(appearance: AppAppearance) = when (appearance) {
    AppAppearance.INK -> InkSurfaceHighest
    AppAppearance.PAPER -> PaperSurfaceHighest
    AppAppearance.GRAPHITE -> GraphiteSelection
}

internal fun outlineStrongColorFor(appearance: AppAppearance) = when (appearance) {
    AppAppearance.INK -> InkOutlineStrong
    AppAppearance.PAPER -> PaperOutlineStrong
    AppAppearance.GRAPHITE -> GraphiteOutlineStrong
}

@Composable
fun RhymeAITheme(
    appearance: AppAppearance = AppAppearance.INK,
    content: @Composable () -> Unit
) {
    CompositionLocalProvider(LocalAppAppearance provides appearance) {
        MaterialTheme(
            colorScheme = colorSchemeFor(appearance),
            typography = RhymeTypography,
            shapes = RhymeShapes
        ) {
            CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurface) {
                ProvideAccessibleAnimations(content = content)
            }
        }
    }
}
