package com.rhymeai.app.ui.theme

import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Test

class AnalysisInkMarksTest {
    @Test
    fun `rhyme pattern mapping is deterministic`() {
        val keys = listOf("EY1", "AY1", "OW1", "IY1", "ER1", "EH1", "AE1", "UW1")
        assertEquals(keys.map(::analysisInkPattern), keys.map(::analysisInkPattern))
        assertEquals(InkUnderlinePattern.entries.toSet(), keys.map(::analysisInkPattern).toSet())
    }

    @Test
    fun `syllable weight uses four buckets`() {
        assertEquals(FontWeight.Normal, analysisFontWeight(1))
        assertEquals(FontWeight.Medium, analysisFontWeight(2))
        assertEquals(FontWeight.SemiBold, analysisFontWeight(3))
        assertEquals(FontWeight.Bold, analysisFontWeight(4))
        assertEquals(FontWeight.Bold, analysisFontWeight(8))
    }
}
