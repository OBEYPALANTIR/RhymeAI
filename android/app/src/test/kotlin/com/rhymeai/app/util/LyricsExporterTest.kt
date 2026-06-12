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

    // wrapLine tests use one unit of width per character so maxWidth doubles
    // as a character budget.
    private val charWidth: (String) -> Float = { it.length.toFloat() }

    @Test
    fun wrapLineKeepsFittingLineIntact() {
        assertEquals(listOf("short line"), LyricsExporter.wrapLine("short line", 10f, charWidth))
    }

    @Test
    fun wrapLineKeepsExactFitAsSingleRow() {
        assertEquals(listOf("exact fit!"), LyricsExporter.wrapLine("exact fit!", 10f, charWidth))
    }

    @Test
    fun wrapLineKeepsEmptyLineAsSingleEmptyRow() {
        assertEquals(listOf(""), LyricsExporter.wrapLine("", 10f, charWidth))
    }

    @Test
    fun wrapLineBreaksAtWordBoundaryAndTrimsLeadingSpaces() {
        assertEquals(
            listOf("hello world", "again"),
            LyricsExporter.wrapLine("hello world again", 12f, charWidth)
        )
    }

    @Test
    fun wrapLineHardBreaksWordLongerThanWidth() {
        assertEquals(
            listOf("abc", "def", "ghi", "j"),
            LyricsExporter.wrapLine("abcdefghij", 3f, charWidth)
        )
    }

    @Test
    fun wrapLineEmitsOverflowRowWhenNothingFits() {
        // Not even one character fits; the remainder must still come out in
        // one row instead of looping forever.
        assertEquals(listOf("ab"), LyricsExporter.wrapLine("ab", 10f) { 100f })
    }
}
