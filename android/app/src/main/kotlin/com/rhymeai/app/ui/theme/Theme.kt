package com.rhymeai.app.ui.theme

import android.os.Build
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

private val DarkColorScheme = darkColorScheme(
    primary = Indigo600,
    onPrimary = Color.White,
    primaryContainer = Indigo500,
    onPrimaryContainer = Color.White,
    secondary = Purple400,
    onSecondary = Color.White,
    tertiary = SyllableEmerald,
    onTertiary = Color(0xFF003824),
    tertiaryContainer = Color(0xFF005235),
    onTertiaryContainer = Color(0xFF90F7C4),
    background = DarkBackground,
    surface = DarkBackground,
    surfaceVariant = DarkSurface,
    surfaceContainerLow = DarkSurface,
    surfaceContainer = DarkSurfaceVariant,
    surfaceContainerHigh = Color(0xFF222222),
    onBackground = Color.White,
    onSurface = Color.White,
    onSurfaceVariant = WhiteMedium,
    outline = WhiteVeryLow,
    outlineVariant = Color.White.copy(alpha = 0.1f),
    inverseSurface = Color.White,
    inverseOnSurface = DarkBackground
)

private val LightColorScheme = lightColorScheme(
    primary = Indigo600,
    onPrimary = Color.White,
    primaryContainer = Indigo400.copy(alpha = 0.2f),
    onPrimaryContainer = Indigo600,
    secondary = Purple400,
    onSecondary = Color.White,
    tertiary = Color(0xFF006D43),
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFF90F7C4),
    onTertiaryContainer = Color(0xFF002111),
    background = Color(0xFFFBFBFE),
    surface = Color(0xFFFBFBFE),
    surfaceVariant = Color(0xFFF0F0F5),
    onBackground = Color(0xFF1B1B1F),
    onSurface = Color(0xFF1B1B1F),
    onSurfaceVariant = Color(0xFF46464F),
    outline = Color(0xFF767680),
    outlineVariant = Color(0xFFC6C5D0)
)

@Composable
fun RhymeAITheme(
    darkTheme: Boolean = true,
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && darkTheme && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            dynamicDarkColorScheme(context)
        }
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = RhymeTypography,
        content = content
    )
}
