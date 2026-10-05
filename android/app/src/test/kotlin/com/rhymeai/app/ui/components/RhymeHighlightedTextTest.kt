package com.rhymeai.app.ui.components

import androidx.compose.ui.graphics.Color
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class RhymeHighlightedTextTest {
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
