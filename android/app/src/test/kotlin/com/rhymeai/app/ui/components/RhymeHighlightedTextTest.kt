package com.rhymeai.app.ui.components

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import com.rhymeai.app.data.model.AnalysisPresentation
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class RhymeHighlightedTextTest {
    @Test
    fun `ink marks use authored ink and syllable weights`() {
        val result = buildAnalysisText(
            text = "light night unbelievable",
            baseTextColor = Color.Black,
            rhymePalette = listOf(Color.Red, Color.Blue),
            isDark = false,
            presentation = AnalysisPresentation.INK_MARKS,
            rhymeEnabled = true,
            syllablesEnabled = true
        )

        assertTrue(result.rhymeSpans.isNotEmpty())
        assertTrue(result.rhymeSpans.all { it.color == Color.Black })
        assertEquals(FontWeight.Bold, result.wordWeights.last().weight)
    }

    @Test
    fun `rhyme only ink marks preserve body weight for every token`() {
        val result = buildAnalysisText(
            text = "light night alone",
            baseTextColor = Color.Black,
            rhymePalette = listOf(Color.Red, Color.Blue),
            isDark = false,
            presentation = AnalysisPresentation.INK_MARKS,
            rhymeEnabled = true,
            syllablesEnabled = false
        )

        assertTrue(result.rhymeSpans.isNotEmpty())
        assertTrue(result.wordWeights.isEmpty())
        assertTrue(result.text.spanStyles.all { it.item.fontWeight == null })
    }

    @Test
    fun `distinct rhyme families receive distinct colors until the palette is exhausted`() {
        val palette = listOf(Color.Red, Color.Blue, Color.Green)
        val colors = assignRhymeFamilyColors(
            familyKeys = listOf("EY", "AY", "EY", "OW"),
            palette = palette
        )

        assertEquals(colors.getValue("EY"), colors.getValue("EY"))
        assertNotEquals(colors.getValue("EY"), colors.getValue("AY"))
        assertNotEquals(colors.getValue("AY"), colors.getValue("OW"))
    }
}
