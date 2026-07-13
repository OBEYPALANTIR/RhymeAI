package com.rhymeai.app.ui.screens

import kotlin.test.Test
import kotlin.test.assertEquals

class EditorScreenTest {
    @Test
    fun `compact editor stats format zero counts`() {
        val result = compactEditorStats(wordCount = 0, syllableCount = 0)

        assertEquals("0w · 0s", result)
    }

    @Test
    fun `compact editor stats preserve multi digit counts`() {
        val result = compactEditorStats(wordCount = 12, syllableCount = 34)

        assertEquals("12w · 34s", result)
    }
}
