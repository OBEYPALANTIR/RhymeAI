package com.rhymeai.app.ui.components

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import com.rhymeai.app.ui.theme.syllableColor
import com.rhymeai.app.util.SyllableCounter
import org.junit.Assert.assertEquals
import org.junit.Test

class SyllableWordColorTest {
    @Test
    fun eachWordIsTintedBySyllableCount() {
        val base = Color(0xFF101010)
        val text = "hello sunshine"
        val annotated = buildSyllableWordColorAnnotatedString(text, base, isDark = true)

        val helloStart = text.indexOf("hello")
        val helloSpan = annotated.spanStyles.first { it.start == helloStart }
        assertEquals(syllableColor(SyllableCounter.count("hello"), true), helloSpan.item.color)
        assertEquals(FontWeight.SemiBold, helloSpan.item.fontWeight)

        val spaceSpan = annotated.spanStyles.first { it.start == text.indexOf(" ") }
        assertEquals(base, spaceSpan.item.color)

        val sunStart = text.indexOf("sunshine")
        val sunSpan = annotated.spanStyles.first { it.start == sunStart }
        assertEquals(syllableColor(SyllableCounter.count("sunshine"), true), sunSpan.item.color)
        assertEquals(FontWeight.SemiBold, sunSpan.item.fontWeight)
    }
}
