package com.rhymeai.app.ui.components

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import com.rhymeai.app.ui.theme.RhymePaletteDark
import com.rhymeai.app.ui.theme.RhymePaletteLight
import com.rhymeai.app.ui.theme.rhymeMatchColor
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class RhymeMatchTextTest {
    private val violet = Color(0xFF6D28D9)

    private fun styledText(annotated: AnnotatedString): List<String> =
        annotated.spanStyles.map { annotated.text.substring(it.start, it.end) }

    @Test
    fun `last word gets the violet semibold underline span`() {
        val annotated = rhymeMatchAnnotated("I walk the line", violet)

        assertEquals("I walk the line", annotated.text)
        assertEquals(listOf("line"), styledText(annotated))
        val style = annotated.spanStyles.single().item
        assertEquals(violet, style.color)
        assertEquals(FontWeight.SemiBold, style.fontWeight)
        assertEquals(TextDecoration.Underline, style.textDecoration)
    }

    @Test
    fun `trailing punctuation and quotes stay outside the span`() {
        assertEquals(listOf("night"), styledText(rhymeMatchAnnotated("\"Out all night?!\"", violet)))
    }

    @Test
    fun `single word line is styled whole`() {
        assertEquals(listOf("Fire"), styledText(rhymeMatchAnnotated("Fire", violet)))
    }

    @Test
    fun `text without a word is returned plain`() {
        assertEquals(AnnotatedString(""), rhymeMatchAnnotated("", violet))
        assertTrue(rhymeMatchAnnotated("...", violet).spanStyles.isEmpty())
    }

    @Test
    fun `match colour is the violet rhyme family in each appearance`() {
        assertEquals(Color(0xFF6D28D9), rhymeMatchColor(isDark = false))
        assertEquals(Color(0xFFC4B5FD), rhymeMatchColor(isDark = true))
        assertEquals(RhymePaletteLight[4], rhymeMatchColor(isDark = false))
        assertEquals(RhymePaletteDark[4], rhymeMatchColor(isDark = true))
    }
}
