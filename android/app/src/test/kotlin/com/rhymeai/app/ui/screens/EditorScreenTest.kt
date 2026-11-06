package com.rhymeai.app.ui.screens

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class EditorScreenTest {
    @Test
    fun `history controls yield to active recording`() {
        assertTrue(historyControlsVisible(editorActionsVisible = true, isRecording = false))
        assertFalse(historyControlsVisible(editorActionsVisible = true, isRecording = true))
        assertFalse(historyControlsVisible(editorActionsVisible = false, isRecording = false))
    }

    @Test
    fun `song notebook and one liners keep the rewrite selection, other modals clear it`() {
        assertTrue(modalKeepsRewriteSelection(songNotebookOpen = true, oneLinersOpen = false))
        assertTrue(modalKeepsRewriteSelection(songNotebookOpen = false, oneLinersOpen = true))
        assertFalse(modalKeepsRewriteSelection(songNotebookOpen = false, oneLinersOpen = false))
    }

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

    @Test
    fun `lyric stats follow each consecutive edit with no blank step`() {
        var text = "[Verse]\nnight light burning"
        while (text != "[Verse]\n") {
            val stats = lyricStatsFor(text)
            val words = text.substringAfter('\n').split(' ').count { it.isNotEmpty() }
            assertEquals(words, stats.wordCount, text)
            assertTrue(stats.syllableCount >= words, text)
            text = text.dropLast(1)
        }
        assertEquals(LyricStatsSnapshot(wordCount = 0, syllableCount = 0), lyricStatsFor(text))
    }
}
