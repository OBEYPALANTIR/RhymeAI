package com.rhymeai.app.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

class AnalysisPresentationTest {
    @Test
    fun `storage values and fallback remain stable`() {
        assertEquals("color", AnalysisPresentation.COLOR.storageValue)
        assertEquals("ink_marks", AnalysisPresentation.INK_MARKS.storageValue)
        assertEquals(AnalysisPresentation.COLOR, AnalysisPresentation.fromStorage(null))
        assertEquals(AnalysisPresentation.COLOR, AnalysisPresentation.fromStorage("unknown"))
    }
}
