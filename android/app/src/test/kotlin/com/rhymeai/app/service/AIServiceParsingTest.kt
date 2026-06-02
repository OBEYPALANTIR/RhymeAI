package com.rhymeai.app.service

import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals

class AIServiceParsingTest {

    @Test
    fun suggestionParserSanitizesProviderLineResponses() {
        val raw = """
            1. "Yellow lights keep pulling me home"
            * Yellow lights keep pulling me home
            - Static in the choir of the road
            model_response>
            You are RhymeAI's on-device songwriting assistant.
            This line is deliberately far too long to be a usable lyric suggestion because it keeps going past the expected single-line length limit for the assistant surface.
            2) I trade the dark for a borrowed glow
        """.trimIndent()

        val suggestions = AIService().parseSuggestionList(raw)

        assertEquals(
            listOf(
                "Yellow lights keep pulling me home",
                "Static in the choir of the road",
                "I trade the dark for a borrowed glow"
            ),
            suggestions
        )
    }

    @Test
    fun suggestionParserAcceptsJsonArrayAndObjectWrappers() {
        val service = AIService()

        assertEquals(
            listOf("First clean line", "Second clean line"),
            service.parseSuggestionList("""["1. First clean line", "\"Second clean line\"", "First clean line"]""")
        )
        assertEquals(
            listOf("First wrapped line", "Second wrapped line"),
            service.parseSuggestionList("""{"suggestions":["- First wrapped line","2) Second wrapped line"]}""")
        )
    }

    @Test
    fun suggestionParserDropsLocalModelChatter() {
        val raw = """
            Sure, here are six options:
            Here are the next-line suggestions:
            I can't know the exact melody, but:
            - Static in the choir of the road
            - I trade the dark for a borrowed glow
        """.trimIndent()

        assertEquals(
            listOf(
                "Static in the choir of the road",
                "I trade the dark for a borrowed glow"
            ),
            AIService().parseSuggestionList(raw)
        )
    }

    @Test
    fun synonymParserAcceptsCommaSeparatedLocalOutput() {
        assertEquals(
            listOf("gleam", "shine", "radiance"),
            AIService().extractSynonyms("gleam, shine, glow, radiance", exclude = "glow")
        )
    }

    @Test
    fun localSynonymPromptAsksForPlainWordsInsteadOfJson() {
        val prompt = AIService().buildLocalSynonymsPrompt(
            word = "glow",
            lineContext = "Static in the dashboard glow",
            limit = 6
        )

        assertContains(prompt, "<start_of_turn>user")
        assertContains(prompt, "Return only replacement words")
        assertContains(prompt, "one per line")
        assertContains(prompt, "No JSON")
    }
}
