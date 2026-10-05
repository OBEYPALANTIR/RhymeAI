package com.rhymeai.app.ui.components

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextRange
import com.rhymeai.app.data.model.AnalysisPresentation
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.ui.theme.SyllableBlue
import com.rhymeai.app.ui.theme.SyllableBlueOnLight
import com.rhymeai.app.ui.theme.rhymePalette
import com.rhymeai.app.ui.theme.SyllableEmerald
import com.rhymeai.app.ui.theme.SyllableEmeraldOnLight
import com.rhymeai.app.ui.theme.SyllableRose
import com.rhymeai.app.ui.theme.SyllableRoseOnLight
import com.rhymeai.app.ui.theme.editorSyllableCountColor
import com.rhymeai.app.ui.theme.editorWordCountColor
import org.junit.Assert.assertEquals
import org.junit.Test

class SyllableWordColorTest {
    private val base = Color(0xFF101010)
    private val lyric = "The harbor lights are burning low\nBeautiful and unforgettable tonight"
    private val syllablesByWord = listOf(
        "The" to 1, "harbor" to 2, "lights" to 1, "are" to 1, "burning" to 2, "low" to 1,
        "Beautiful" to 3, "and" to 1, "unforgettable" to 5, "tonight" to 2
    )
    private val lightPalette = listOf(
        Color(0xFF047857), Color(0xFF0369A1), Color(0xFF7E22CE), Color(0xFFB91C1C)
    )
    private val graphitePalette = listOf(
        Color(0xFF6EE7B7), Color(0xFF93C5FD), Color(0xFFD8B4FE), Color(0xFFFDA4AF)
    )

    private fun analyse(isDark: Boolean, rhymeEnabled: Boolean) = buildAnalysisText(
        text = lyric,
        baseTextColor = base,
        rhymePalette = rhymePalette(isDark),
        isDark = isDark,
        presentation = AnalysisPresentation.COLOR,
        rhymeEnabled = rhymeEnabled,
        syllablesEnabled = true
    )

    @Test
    fun editorCountersUseGreenForWordsAndRedForSyllables() {
        assertEquals(SyllableEmeraldOnLight, editorWordCountColor(isDark = false))
        assertEquals(SyllableEmerald, editorWordCountColor(isDark = true))
        assertEquals(SyllableRoseOnLight, editorSyllableCountColor(isDark = false))
        assertEquals(SyllableRose, editorSyllableCountColor(isDark = true))
    }

    @Test
    fun editorTintsEachWordBySyllableCountInEveryAppearance() {
        val expectedByAppearance = mapOf(
            AppAppearance.INK to lightPalette,
            AppAppearance.PAPER to lightPalette,
            AppAppearance.GRAPHITE to graphitePalette
        )
        assertEquals(AppAppearance.entries.toSet(), expectedByAppearance.keys)

        expectedByAppearance.forEach { (appearance, palette) ->
            val analysed = analyse(isDark = appearance.isDark, rhymeEnabled = false).text

            assertEquals(lyric, analysed.text)
            syllablesByWord.forEach { (word, syllables) ->
                val span = analysed.spanStyles.single { it.start == lyric.indexOf(word) }
                assertEquals("$word end in ${appearance.displayName}", lyric.indexOf(word) + word.length, span.end)
                assertEquals(
                    "$word colour in ${appearance.displayName}",
                    palette[(syllables - 1).coerceAtMost(3)],
                    span.item.color
                )
            }
            val gap = analysed.spanStyles.first { it.start == lyric.indexOf(" ") }
            assertEquals(base, gap.item.color)
        }
    }

    @Test
    fun selectionMapsOntoColouredWordsWithoutClearingThem() {
        val analysed = analyse(isDark = true, rhymeEnabled = false).text
        val transformed = lyricAnalysisTransformation(active = true, analysed = analysed)
            .filter(AnnotatedString(lyric))
        val selection = TextRange(lyric.indexOf("harbor"), lyric.indexOf("harbor") + "harbor".length)

        assertEquals(selection.start, transformed.offsetMapping.originalToTransformed(selection.start))
        assertEquals(selection.end, transformed.offsetMapping.originalToTransformed(selection.end))
        val selectedSpan = transformed.text.spanStyles.single {
            it.start == selection.start && it.end == selection.end
        }
        assertEquals(SyllableBlue, selectedSpan.item.color)
        assertEquals(analysed.spanStyles, transformed.text.spanStyles)
    }

    @Test
    fun staleOrInactiveAnalysisLeavesTheTypedTextUnstyled() {
        val analysed = analyse(isDark = false, rhymeEnabled = false).text
        val typed = AnnotatedString("$lyric and more")

        assertEquals(typed, lyricAnalysisTransformation(active = true, analysed = analysed).filter(typed).text)
        assertEquals(
            AnnotatedString(lyric),
            lyricAnalysisTransformation(active = false, analysed = analysed).filter(AnnotatedString(lyric)).text
        )
    }

    @Test
    fun rhymeFamiliesOwnTheWordColourAndSyllablesMoveToTheUnderline() {
        val text = "hold the light tonight"
        val rhymePalette = listOf(Color.Magenta, Color.Cyan)
        val analysed = buildAnalysisText(
            text = text,
            baseTextColor = base,
            rhymePalette = rhymePalette,
            isDark = false,
            presentation = AnalysisPresentation.COLOR,
            rhymeEnabled = true,
            syllablesEnabled = true
        ).text

        fun colourOf(word: String) = analysed.spanStyles.single { it.start == text.indexOf(word) }.item.color
        assertEquals(Color.Magenta, colourOf("light"))
        assertEquals(Color.Magenta, colourOf("tonight"))
        assertEquals(base, colourOf("hold"))
        assertEquals(
            listOf(SyllableEmeraldOnLight, SyllableEmeraldOnLight, SyllableEmeraldOnLight, SyllableBlueOnLight),
            colorSyllableUnderlines(analyzeSyllableUnderlines(text, enabled = true), isDark = false).map { it.color }
        )
    }

    @Test
    fun themeChangesReuseThemeIndependentSyllableAnalysis() {
        val text = "[Verse]\nhello sunshine"
        val analysis = analyzeSyllableUnderlines(text, enabled = true)

        assertEquals(listOf("hello", "sunshine"), analysis.map { text.substring(it.start, it.endExclusive) })
        assertEquals(
            analysis.map { it.start to it.endExclusive },
            colorSyllableUnderlines(analysis, isDark = false).map { it.start to it.endExclusive }
        )
        assertEquals(
            analysis.map { it.start to it.endExclusive },
            colorSyllableUnderlines(analysis, isDark = true).map { it.start to it.endExclusive }
        )
    }
}
