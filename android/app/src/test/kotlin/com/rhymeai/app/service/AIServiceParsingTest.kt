package com.rhymeai.app.service

import com.rhymeai.app.data.model.RewriteAction
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertTrue

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

        val suggestions = AIService().parseSuggestionList(raw).map { it.text }

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
            service.parseSuggestionList("""["1. First clean line", "\"Second clean line\"", "First clean line"]""").map { it.text }
        )
        assertEquals(
            listOf("First wrapped line", "Second wrapped line"),
            service.parseSuggestionList("""{"suggestions":["- First wrapped line","2) Second wrapped line"]}""").map { it.text }
        )
    }

    @Test
    fun suggestionParserDropsLocalModelChatter() {
        val raw = """
            Sure, here are six options:
            Here are the next-line suggestions:
            I can't know the exact melody, but:
            start_of_turn>
            - Static in the choir of the road
            - I trade the dark for a borrowed glow
        """.trimIndent()

        assertEquals(
            listOf(
                "Static in the choir of the road",
                "I trade the dark for a borrowed glow"
            ),
            AIService().parseSuggestionList(raw).map { it.text }
        )
    }

    @Test
    fun localRewriteCleanerStripsMalformedTurnMarkers() {
        val raw = """
            start_of_turn>model
            Where we swear we're free
            <end_of_turn>
        """.trimIndent()

        assertEquals(
            "Where we swear we're free",
            AIService().cleanLocalRewrite(raw, selection = "Where we claim to be free")
        )
    }

    @Test
    fun localRewriteCleanerExtractsJsonAfterMarkers() {
        val raw = """
            <start_of_turn>model
            {"rewrite":"Cold corporate walls still listen"}
            <end_of_turn>
        """.trimIndent()

        assertEquals(
            "Cold corporate walls still listen",
            AIService().cleanLocalRewrite(raw, selection = "Cold corporate walls")
        )
    }

    @Test
    fun localRewriteCleanerRejectsMarkerOnlyAndUnchangedOutput() {
        val service = AIService()

        assertTrue(service.cleanLocalRewrite("start_of_turn>", selection = "Where we claim to be free").isBlank())
        assertTrue(service.cleanLocalRewrite("Where we claim to be free", selection = "Where we claim to be free").isBlank())
    }

    @Test
    fun localSingleWordRewriteDropsLabelsAndMarkers() {
        val raw = """
            <start_of_turn>model
            Replacement: gleam
            <end_of_turn>
        """.trimIndent()

        assertEquals("gleam", AIService().cleanLocalRewrite(raw, selection = "glow"))
    }

    @Test
    fun localSingleWordFallbackCoversCommonRewriteActions() {
        val service = AIService()

        assertEquals("gleam", service.fallbackLocalSingleWordRewrite("glow", RewriteAction.REPHRASE))
        assertEquals("show", service.fallbackLocalSingleWordRewrite("glow", RewriteAction.HARDER_RHYME))
        assertEquals("flare", service.fallbackLocalSingleWordRewrite("glow", RewriteAction.PUNCH_UP))
        assertEquals("feel", service.fallbackLocalSingleWordRewrite("real", RewriteAction.HARDER_RHYME))
        assertTrue(service.fallbackLocalSingleWordRewrite("xylophone", RewriteAction.REPHRASE).isBlank())
    }

    @Test
    fun localSingleWordValidatorRejectsAwkwardHarderRhymeExpansion() {
        val service = AIService()

        assertEquals("reality", service.cleanLocalRewrite("reality", selection = "real"))
        assertTrue(
            service.acceptLocalSingleWordRewrite(
                candidate = "reality",
                selection = "real",
                action = RewriteAction.HARDER_RHYME
            ).isBlank()
        )
        assertEquals(
            "feel",
            service.acceptLocalSingleWordRewrite(
                candidate = "reality",
                selection = "real",
                action = RewriteAction.HARDER_RHYME
            ).ifBlank { service.fallbackLocalSingleWordRewrite("real", RewriteAction.HARDER_RHYME) }
        )
        assertEquals(
            "feel",
            service.acceptLocalSingleWordRewrite(
                candidate = "feel",
                selection = "real",
                action = RewriteAction.HARDER_RHYME
            )
        )
    }

    @Test
    fun localHarderRhymeValidatorRejectsReportedBadSingleWordContexts() {
        val service = AIService()
        val makeLyrics = "In the land of make believe"
        val makeContext = service.singleWordRewriteContext(
            lyrics = makeLyrics,
            selection = "make",
            selectionStart = makeLyrics.indexOf("make")
        )
        assertTrue(
            service.acceptLocalSingleWordRewrite(
                candidate = "deceive",
                selection = "make",
                action = RewriteAction.HARDER_RHYME,
                context = makeContext,
                rejectedCandidates = emptySet()
            ).isBlank()
        )

        val callsLyrics = "Birds chirping in phone calls"
        val callsContext = service.singleWordRewriteContext(
            lyrics = callsLyrics,
            selection = "calls",
            selectionStart = callsLyrics.indexOf("calls")
        )
        assertTrue(
            service.acceptLocalSingleWordRewrite(
                candidate = "walls",
                selection = "calls",
                action = RewriteAction.HARDER_RHYME,
                context = callsContext,
                rejectedCandidates = emptySet()
            ).isBlank()
        )
        assertTrue(
            service.fallbackLocalSingleWordRewrite(
                selection = "calls",
                action = RewriteAction.HARDER_RHYME,
                context = callsContext
            ).isBlank()
        )

        val feedsLyrics = "Personalized social feeds"
        val feedsContext = service.singleWordRewriteContext(
            lyrics = feedsLyrics,
            selection = "feeds",
            selectionStart = feedsLyrics.indexOf("feeds")
        )
        assertTrue(
            service.acceptLocalSingleWordRewrite(
                candidate = "streams",
                selection = "feeds",
                action = RewriteAction.HARDER_RHYME,
                context = feedsContext,
                rejectedCandidates = emptySet()
            ).isBlank()
        )
    }

    @Test
    fun localHarderRhymeValidatorRejectsPreviousPreviewOnRedo() {
        val service = AIService()
        val lyrics = "Cold corporate walls"
        val context = service.singleWordRewriteContext(
            lyrics = lyrics,
            selection = "walls",
            selectionStart = lyrics.indexOf("walls")
        )

        assertEquals(
            "calls",
            service.acceptLocalSingleWordRewrite(
                candidate = "calls",
                selection = "walls",
                action = RewriteAction.HARDER_RHYME,
                context = context,
                rejectedCandidates = emptySet()
            )
        )
        assertTrue(
            service.acceptLocalSingleWordRewrite(
                candidate = "calls",
                selection = "walls",
                action = RewriteAction.HARDER_RHYME,
                context = context,
                rejectedCandidates = setOf("calls")
            ).isBlank()
        )
        assertEquals(
            "falls",
            service.fallbackLocalSingleWordRewrite(
                selection = "walls",
                action = RewriteAction.HARDER_RHYME,
                context = context,
                rejectedCandidates = setOf("calls")
            )
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
