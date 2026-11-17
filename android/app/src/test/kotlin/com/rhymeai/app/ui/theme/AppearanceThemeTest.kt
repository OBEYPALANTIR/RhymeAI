package com.rhymeai.app.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import com.rhymeai.app.data.model.AppAppearance
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AppearanceThemeTest {
    @Test
    fun `each appearance selects its canonical background and action palette`() {
        assertEquals(PaperWhite, colorSchemeFor(AppAppearance.INK).background)
        assertEquals(Ink, colorSchemeFor(AppAppearance.INK).primary)

        assertEquals(PaperIvory, colorSchemeFor(AppAppearance.PAPER).background)
        assertEquals(Pencil, colorSchemeFor(AppAppearance.PAPER).primary)

        assertEquals(Graphite, colorSchemeFor(AppAppearance.GRAPHITE).background)
        assertEquals(GraphiteWarmWhite, colorSchemeFor(AppAppearance.GRAPHITE).primary)
    }

    @Test
    fun `selection colors use the authored appearance tokens`() {
        assertEquals(InkSurfaceHighest, selectionColorFor(AppAppearance.INK))
        assertEquals(PaperSurfaceHighest, selectionColorFor(AppAppearance.PAPER))
        assertEquals(GraphiteSelection, selectionColorFor(AppAppearance.GRAPHITE))
    }

    @Test
    fun `selected song row secondary text clears 5 to 1 in every appearance`() {
        AppAppearance.entries.forEach { appearance ->
            val scheme = colorSchemeFor(appearance)
            val text = scheme.onPrimaryContainer
                .copy(alpha = DesignTokens.Drawer.selectedRowSecondaryAlpha)
                .compositeOver(scheme.primaryContainer)
            val (light, dark) = listOf(text.luminance(), scheme.primaryContainer.luminance()).sortedDescending()
            val ratio = (light + 0.05f) / (dark + 0.05f)
            assertTrue(ratio >= 5.0f, "$appearance selected-row secondary text is $ratio:1")
        }
    }

    @Test
    fun `placeholder colors remain readable on interactive surfaces`() {
        assertEquals(InkOutlineStrong, placeholderColorFor(AppAppearance.INK))
        assertEquals(PaperMuted, placeholderColorFor(AppAppearance.PAPER))
        assertEquals(GraphitePlaceholder, placeholderColorFor(AppAppearance.GRAPHITE))
    }

    @Test
    fun `graphite alone uses the dark analysis palette`() {
        assertFalse(AppAppearance.INK.isDark)
        assertFalse(AppAppearance.PAPER.isDark)
        assertTrue(AppAppearance.GRAPHITE.isDark)

        assertEquals(RhymePaletteLight, rhymePalette(AppAppearance.INK.isDark))
        assertEquals(RhymePaletteLight, rhymePalette(AppAppearance.PAPER.isDark))
        assertEquals(RhymePaletteDark, rhymePalette(AppAppearance.GRAPHITE.isDark))
    }

    @Test
    fun `light rhyme palette matches the approved contrast-safe tokens`() {
        assertEquals(
            listOf(
                Color(0xFFB91C1C),
                Color(0xFF92400E),
                Color(0xFF166534),
                Color(0xFF0369A1),
                Color(0xFF6D28D9),
                Color(0xFFBE185D),
                Color(0xFF9A3412),
                Color(0xFF155E75),
                Color(0xFF047857),
                Color(0xFF7E22CE),
                Color(0xFF854D0E),
                Color(0xFF3F6212)
            ),
            RhymePaletteLight
        )
    }

    @Test
    fun `appearance theme installs restrained authored shapes`() {
        assertEquals(RoundedCornerShape(DesignTokens.Radius.sm), RhymeShapes.small)
        assertEquals(RoundedCornerShape(DesignTokens.Radius.md), RhymeShapes.medium)
        assertEquals(RoundedCornerShape(DesignTokens.Radius.lg), RhymeShapes.large)
    }
}
