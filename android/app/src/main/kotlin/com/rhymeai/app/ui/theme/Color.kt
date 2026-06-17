package com.rhymeai.app.ui.theme

import androidx.compose.ui.graphics.Color

val DarkBackground = Color(0xFF0A0A0A)
val DarkSurface = Color(0xFF111111)
val DarkSurfaceVariant = Color(0xFF1A1A1A)

val Indigo400 = Color(0xFF818CF8)
val Indigo500 = Color(0xFF6366F1)
val Indigo600 = Color(0xFF4F46E5)
val Purple400 = Color(0xFFC084FC)

val Warning = Color(0xFFFFA000)
val SyllableEmerald = Color(0xFF6EE7B7)
val SyllableBlue = Color(0xFF93C5FD)
val SyllablePurple = Color(0xFFD8B4FE)
val SyllableRose = Color(0xFFFDA4AF)

val SyllableEmeraldOnLight = Color(0xFF047857) // emerald-700
val SyllableBlueOnLight = Color(0xFF0369A1) // sky-700
val SyllablePurpleOnLight = Color(0xFF7E22CE) // purple-700
val SyllableRoseOnLight = Color(0xFFB91C1C) // rose-700

// Pastels: WCAG-passing on dark surface.
val RhymePaletteDark = listOf(
    Color(0xFFFCA5A5), // rose
    Color(0xFFFCD34D), // amber
    Color(0xFF86EFAC), // green
    Color(0xFF7DD3FC), // sky
    Color(0xFFC4B5FD), // violet
    Color(0xFFF9A8D4), // pink
    Color(0xFFFDBA74), // orange
    Color(0xFF67E8F9), // cyan
    Color(0xFFA7F3D0), // mint
    Color(0xFFE9D5FF), // light purple
    Color(0xFFFEF08A), // yellow
    Color(0xFFBEF264)  // lime
)

// Tailwind *-700: WCAG-passing on light surface.
val RhymePaletteLight = listOf(
    Color(0xFFB91C1C), // rose
    Color(0xFFB45309), // amber
    Color(0xFF15803D), // green
    Color(0xFF0369A1), // sky
    Color(0xFF6D28D9), // violet
    Color(0xFFBE185D), // pink
    Color(0xFFC2410C), // orange
    Color(0xFF0E7490), // cyan
    Color(0xFF047857), // emerald
    Color(0xFF7E22CE), // purple
    Color(0xFFA16207), // yellow
    Color(0xFF4D7C0F)  // lime
)

@Deprecated("Use rhymePalette(isDark) so contrast adapts to theme.", ReplaceWith("RhymePaletteDark"))
val RhymePalette: List<Color> = RhymePaletteDark

fun rhymePalette(isDark: Boolean): List<Color> =
    if (isDark) RhymePaletteDark else RhymePaletteLight

fun syllableColor(count: Int, isDark: Boolean): Color =
    if (isDark) {
        when (count) {
            1 -> SyllableEmerald
            2 -> SyllableBlue
            3 -> SyllablePurple
            else -> SyllableRose
        }
    } else {
        when (count) {
            1 -> SyllableEmeraldOnLight
            2 -> SyllableBlueOnLight
            3 -> SyllablePurpleOnLight
            else -> SyllableRoseOnLight
        }
    }

val WhiteHigh = Color(0xFFE5E5E5)
val WhiteMedium = Color(0xFFB3B3B3)
val WhiteLow = Color(0xFF666666)
val WhiteVeryLow = Color(0xFF333333)
