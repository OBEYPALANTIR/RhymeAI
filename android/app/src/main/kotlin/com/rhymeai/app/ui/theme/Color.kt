package com.rhymeai.app.ui.theme

import androidx.compose.ui.graphics.Color

val Ink = Color(0xFF050505)
val PaperWhite = Color(0xFFFCFCF8)
val PaperIvory = Color(0xFFF3EEDF)
val Graphite = Color(0xFF171716)
val GraphiteSurface = Color(0xFF232321)
val Pencil = Color(0xFF302E2A)
val GraphiteWarmWhite = Color(0xFFF6F2E8)

val InkSurfaceLow = Color(0xFFF7F7F2)
val InkSurface = Color(0xFFEFEFE9)
val InkSurfaceHigh = Color(0xFFE5E5DE)
val InkSurfaceHighest = Color(0xFFDADAD2)
val InkMuted = Color(0xFF4D4D48)
val InkSubtle = Color(0xFF666660)
val InkOutline = Color(0xFFB5B5AD)
val InkOutlineStrong = Color(0xFF5E5E58)
val InkScrim = Color(0x6B050505)

val PaperSurface = Color(0xFFF8F3E6)
val PaperSurfaceLow = Color(0xFFEFE8D7)
val PaperSurfaceContainer = Color(0xFFE8E0CE)
val PaperSurfaceHigh = Color(0xFFDDD4BF)
val PaperSurfaceHighest = Color(0xFFD2C8B0)
val PaperMuted = Color(0xFF5D574E)
val PaperSubtle = Color(0xFF6E675C)
val PaperOutline = Color(0xFFB7AC94)
val PaperOutlineStrong = Color(0xFF696257)
val PaperActionForeground = Color(0xFFFFF9EB)
val PaperScrim = Color(0x6B302E2A)

val GraphiteSurfaceBase = Color(0xFF1C1C1B)
val GraphiteSurfaceLow = Color(0xFF20201E)
val GraphiteSurfaceHigh = Color(0xFF2B2B28)
val GraphiteSurfaceHighest = Color(0xFF343430)
val GraphiteMuted = Color(0xFFC4BEB3)
val GraphiteSubtle = Color(0xFF9B968C)
val GraphitePlaceholder = Color(0xFFAAA49A)
val GraphiteOutline = Color(0xFF484843)
val GraphiteOutlineStrong = Color(0xFF7B766D)
val GraphiteSelection = Color(0xFF41413D)
val GraphiteScrim = Color(0x8C000000)

val ErrorLight = Color(0xFFB3261E)
val OnErrorLight = Color(0xFFFFFFFF)
val ErrorDark = Color(0xFFFFB4AB)
val OnErrorDark = Color(0xFF690005)

val SuccessLight = Color(0xFF047857)
val OnSuccessLight = Color(0xFFFFFFFF)
val SuccessDark = Color(0xFF6EE7B7)
val OnSuccessDark = Color(0xFF003824)
val SuccessContainerLight = Color(0xFFD1FAE5)
val OnSuccessContainerLight = Color(0xFF064E3B)
val SuccessContainerDark = Color(0xFF005235)
val OnSuccessContainerDark = Color(0xFF90F7C4)

val WarningLight = Color(0xFF92400E)
val OnWarningLight = Color(0xFFFFFFFF)
val WarningDark = Color(0xFFFFB95B)
val OnWarningDark = Color(0xFF4A2800)

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
    Color(0xFF92400E), // amber
    Color(0xFF166534), // green
    Color(0xFF0369A1), // sky
    Color(0xFF6D28D9), // violet
    Color(0xFFBE185D), // pink
    Color(0xFF9A3412), // orange
    Color(0xFF155E75), // cyan
    Color(0xFF047857), // emerald
    Color(0xFF7E22CE), // purple
    Color(0xFF854D0E), // yellow
    Color(0xFF3F6212)  // lime
)

@Deprecated("Use rhymePalette(isDark) so contrast adapts to theme.", ReplaceWith("RhymePaletteDark"))
val RhymePalette: List<Color> = RhymePaletteDark

fun rhymePalette(isDark: Boolean): List<Color> =
    if (isDark) RhymePaletteDark else RhymePaletteLight

/** Violet rhyme family: marks the end word being matched in the assistant panel. */
fun rhymeMatchColor(isDark: Boolean): Color = rhymePalette(isDark)[4]

fun statusSuccessColor(isDark: Boolean): Color = if (isDark) SuccessDark else SuccessLight

fun statusWarningColor(isDark: Boolean): Color = if (isDark) WarningDark else WarningLight

fun statusErrorColor(isDark: Boolean): Color = if (isDark) ErrorDark else ErrorLight

fun editorWordCountColor(isDark: Boolean): Color = syllableColor(1, isDark)

fun editorSyllableCountColor(isDark: Boolean): Color = syllableColor(4, isDark)

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
