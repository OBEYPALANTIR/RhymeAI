package com.rhymeai.app.data.model

import com.rhymeai.app.util.SectionMap
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class SongWorkspaceTest {
    @Test fun alternatesTrimDeduplicateAndRetainNewestFifty() {
        var workspace = SongWorkspace().keep("  one line  ", 1).keep("one line", 2).keep("   ", 3)
        assertEquals(listOf("one line"), workspace.alternates.map { it.text })
        repeat(60) { workspace = workspace.keep("line $it", it.toLong()) }
        assertEquals(50, workspace.alternates.size)
        assertEquals("line 59", workspace.alternates.first().text)
    }

    @Test fun snapshotsCheckpointAtFiveMinutesAndPreserveCurrentBeforeRestore() {
        val original = SongWorkspace().checkpoint("Song", "old draft", "", 1_000_000, false)
        val early = original.checkpoint("Song", "middle draft", "", 1_299_999, false)
        assertEquals(original, early)
        val due = early.checkpoint("Song", "middle draft", "", 1_300_000, false)
        val beforeRestore = due.checkpoint("Song", "current draft", "", 1_300_001, true)
        assertEquals(listOf("current draft", "middle draft", "old draft"), beforeRestore.versions.map { it.lyrics })
    }

    @Test fun snapshotsAreBoundedAndDeduplicated() {
        var workspace = SongWorkspace()
        repeat(30) { workspace = workspace.checkpoint("Song", "draft $it", "", it.toLong(), true) }
        workspace = workspace.checkpoint("Song", "draft 15", "", 31, true)
        assertEquals(20, workspace.versions.size)
        assertEquals(1, workspace.versions.count { it.lyrics == "draft 15" })
        assertEquals("draft 15", workspace.versions.first().lyrics)
    }

    @Test fun workspaceRoundTripPreservesUtf16PositionsAndIndependentExtras() {
        val text = "🎵 quiet line"
        val workspace = SongWorkspace(selectionStart = 2, selectionEnd = text.length, scrollOffset = 125.5f)
            .keep("alternate", 1).checkpoint("Song", text, "night", 2, true)
        assertEquals(workspace, Json.decodeFromString<SongWorkspace>(Json.encodeToString(workspace)))
        assertEquals(' ', text[workspace.selectionStart])
    }

    @Test fun previewSkipsBlankAndSectionHeaderLines() {
        assertEquals("a quiet line", SectionMap.lyricContent("\n[Verse 1]\n\na quiet line\nnext line").lineSequence().first { it.isNotBlank() })
    }
}
