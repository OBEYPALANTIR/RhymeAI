package com.rhymeai.app.util

import com.rhymeai.app.data.model.SongProject
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals

class LyricsExporterTest {

    @Test
    fun txtExportUsesUntitledFallbackAndPreservesLyrics() {
        val project = SongProject(
            title = "",
            lyrics = "  cafe moon\nnaive glow",
            theme = ""
        )

        val txt = LyricsExporter.buildTxt(project).decodeToString()

        assertEquals(
            "Untitled\n\n  cafe moon\nnaive glow",
            txt
        )
    }

    @Test
    fun txtExportIncludesThemeWhenPresent() {
        val project = SongProject(
            title = "Midnight Notes",
            lyrics = "[Verse]\nquiet road",
            theme = "late-night resolve"
        )

        val txt = LyricsExporter.buildTxt(project).decodeToString()

        assertEquals(
            "Midnight Notes\nTheme: late-night resolve\n\n[Verse]\nquiet road",
            txt
        )
    }

    @Test
    fun lrcExportPreservesLeadingWhitespaceAndStripsTrailingWhitespace() {
        val project = SongProject(
            title = "Cafe",
            lyrics = "  cafe moon  \n\n[Verse]\n\tnaive glow\t",
            theme = "ignored by lrc"
        )

        val lrc = LyricsExporter.buildLrc(project).decodeToString()

        assertEquals(
            "[ti:Cafe]\n" +
                "[ar:Unknown]\n" +
                "[al:RhymeAI]\n" +
                "[length:00:00.00]\n" +
                "\n" +
                "[00:00.00]  cafe moon\n" +
                "\n" +
                "[00:00.00][Verse]\n" +
                "[00:00.00]\tnaive glow\n",
            lrc
        )
    }

    @Test
    fun jsonExportRoundTripsProjectFields() {
        val project = SongProject(
            id = "song-1",
            title = "Signal",
            lyrics = "line one\nline two",
            theme = "clear signal",
            updatedAt = 1_780_374_654L
        )

        val decoded = Json.decodeFromString<SongProject>(LyricsExporter.buildJson(project).decodeToString())

        assertEquals(project, decoded)
    }
}
