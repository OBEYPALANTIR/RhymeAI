package com.rhymeai.app.ui.screens

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class EditorScreenTest {
    @Test
    fun `history controls yield to active recording`() {
        assertTrue(historyControlsVisible(editorActionsVisible = true, isRecording = false))
        assertFalse(historyControlsVisible(editorActionsVisible = true, isRecording = true))
        assertFalse(historyControlsVisible(editorActionsVisible = false, isRecording = false))
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
    fun `lyric stats are visible only for the text they describe`() {
        val snapshot = LyricStatsSnapshot(
            sourceText = "first lyric",
            wordCount = 2,
            syllableCount = 3
        )

        assertSame(snapshot, currentLyricStats("first lyric", snapshot))
        assertNull(currentLyricStats("replacement lyric", snapshot))
        assertNull(currentLyricStats("first lyric", null))
    }
}
