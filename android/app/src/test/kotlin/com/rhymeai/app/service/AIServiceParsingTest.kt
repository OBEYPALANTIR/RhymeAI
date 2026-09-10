package com.rhymeai.app.service

import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.util.PronunciationDictionary
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class AIServiceParsingTest {
    private val dictionary = PronunciationDictionary.fromLines(
        sequenceOf(
            "glow\tG L OW1",
            "gleam\tG L IY1 M",
            "shine\tSH AY1 N",
            "radiance\tR EY1 D IY0 AH0 N S",
            "real\tR IY1 L",
            "feel\tF IY1 L",
            "reality\tR IY0 AE1 L AH0 T IY0"
        )
    )

    @Test
    fun suggestionParserSanitizesProviderLineResponses() {
        val raw = """
            1. "Yellow lights keep pulling me home"
            * Yellow lights keep pulling me home
            - Static in the choir of the road
            model_response>
            You are RhymeAI's on-device songwriting assistant.
            2) I trade the dark for a borrowed glow
        """.trimIndent()

        assertEquals(
            listOf(
                "Yellow lights keep pulling me home",
                "Static in the choir of the road",
                "I trade the dark for a borrowed glow"
            ),
            AIService().parseSuggestionList(raw).map { it.text }
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
    fun suggestionParserDropsLocalModelChatterForCloudCompatibility() {
        val raw = """
            Sure, here are six options:
            Here are the next-line suggestions:
            I can't know the exact melody, but:
            start_of_turn>
            - Static in the choir of the road
            - I trade the dark for a borrowed glow
        """.trimIndent()

        assertEquals(
            listOf("Static in the choir of the road", "I trade the dark for a borrowed glow"),
            AIService().parseSuggestionList(raw).map { it.text }
        )
    }

    @Test
    fun localSuggestionBoundaryRequiresSixDistinctCompleteLines() = runBlocking {
        val service = AIService()
        val valid = (1..6).joinToString("\n") { "Original lyric option $it" }

        assertEquals(
            (1..6).map { "Original lyric option $it" },
            service.validatedLocalSuggestionStream(flowOf(valid), lyrics = "Existing lyric").toList().map { it.text }
        )

        val error = assertFailsWith<RuntimeException> {
            service.validatedLocalSuggestionStream(
                flowOf("One\nTwo\nTwo\nExisting lyric\nFive"),
                lyrics = "Existing lyric"
            ).toList()
        }
        assertEquals("Local model returned an incomplete response. Try again or use a cloud provider.", error.message)
    }

    @Test
    fun localSuggestionBoundaryStreamsOnlyCompleteValidatedLines() = runBlocking {
        val lines = AIService().validatedLocalSuggestionStream(
            flowOf("First line\nSecond", " line\nThird line\nFourth line\nFifth line\nSixth line"),
            lyrics = ""
        ).toList().map { it.text }

        assertEquals(
            listOf("First line", "Second line", "Third line", "Fourth line", "Fifth line", "Sixth line"),
            lines
        )
    }

    @Test
    fun localSuggestionBoundaryRejectsMarkupBeforeCleanup() = runBlocking {
        val error = assertFailsWith<RuntimeException> {
            AIService().validatedLocalSuggestionStream(
                flowOf("<start_of_turn>model\nOne\nTwo\nThree\nFour\nFive\nSix"),
                lyrics = ""
            ).toList()
        }
        assertEquals("Local model returned an incomplete response. Try again or use a cloud provider.", error.message)
    }

    @Test
    fun passageRewritePreservesLineStructureAndRejectsLeakageOrUnchangedText() {
        val service = AIService()
        val selection = "First source line\n\nSecond source line"

        assertEquals(
            "First changed line\n\nSecond changed line",
            service.cleanLocalRewrite("First changed line\n\nSecond changed line", selection)
        )
        assertTrue(service.cleanLocalRewrite("Only one line", selection).isBlank())
        assertTrue(service.cleanLocalRewrite("First changed line\nSecond changed line\nThird line", selection).isBlank())
        assertTrue(service.cleanLocalRewrite(selection, selection).isBlank())
        assertTrue(service.cleanLocalRewrite("<end_of_turn>\nFirst changed line\n\nSecond changed line", selection).isBlank())
    }

    @Test
    fun localRewriteCleanerAcceptsPlainOrJsonAndRejectsTurnMarkers() {
        val service = AIService()

        assertEquals(
            "Where we swear we're free",
            service.cleanLocalRewrite("Where we swear we're free", selection = "Where we claim to be free")
        )
        assertEquals(
            "Cold corporate walls still listen",
            service.cleanLocalRewrite(
                """{"rewrite":"Cold corporate walls still listen"}""",
                selection = "Cold corporate walls"
            )
        )
        assertTrue(
            service.cleanLocalRewrite(
                "<start_of_turn>model\nWhere we swear we're free\n<end_of_turn>",
                selection = "Where we claim to be free"
            ).isBlank()
        )
    }

    @Test
    fun singleWordBoundaryRejectsLabelsMarkupLossySpellingsAndExclusions() {
        val service = AIService()

        assertEquals("gleam", service.cleanLocalRewrite("gleam", selection = "glow"))
        assertTrue(service.cleanLocalRewrite("Replacement: gleam", selection = "glow").isBlank())
        assertTrue(service.cleanLocalRewrite("<b>gleam</b>", selection = "glow").isBlank())
        listOf("g-l-e-a-m", "Gleam").forEach { candidate ->
            assertTrue(
                service.acceptLocalSingleWordRewrite(
                    candidate = candidate,
                    selection = "glow",
                    action = RewriteAction.REPHRASE,
                    context = null,
                    rejectedCandidates = setOf("gleam"),
                    dictionary = dictionary
                ).isBlank()
            )
        }
    }

    @Test
    fun harderRhymeRequiresLineEndingKnownWordAndRhymeFit() {
        val service = AIService()

        assertEquals(
            "feel",
            service.acceptLocalSingleWordRewrite(
                candidate = "feel",
                selection = "real",
                action = RewriteAction.HARDER_RHYME,
                context = service.singleWordRewriteContext("What is real", "real", 8),
                rejectedCandidates = emptySet(),
                dictionary = dictionary
            )
        )
        assertTrue(
            service.acceptLocalSingleWordRewrite(
                candidate = "reality",
                selection = "real",
                action = RewriteAction.HARDER_RHYME,
                context = service.singleWordRewriteContext("What is real", "real", 8),
                rejectedCandidates = emptySet(),
                dictionary = dictionary
            ).isBlank()
        )
        assertTrue(
            service.acceptLocalSingleWordRewrite(
                candidate = "feel",
                selection = "real",
                action = RewriteAction.HARDER_RHYME,
                context = service.singleWordRewriteContext("The real thing", "real", 4),
                rejectedCandidates = emptySet(),
                dictionary = dictionary
            ).isBlank()
        )
    }

    @Test
    fun localSingleWordValidatorRejectsPreviousPreviewOnRedo() {
        val service = AIService()

        assertEquals(
            "feel",
            service.acceptLocalSingleWordRewrite(
                candidate = "feel",
                selection = "real",
                action = RewriteAction.HARDER_RHYME,
                context = service.singleWordRewriteContext("What is real", "real", 8),
                rejectedCandidates = emptySet(),
                dictionary = dictionary
            )
        )
        assertTrue(
            service.acceptLocalSingleWordRewrite(
                candidate = "feel",
                selection = "real",
                action = RewriteAction.HARDER_RHYME,
                context = service.singleWordRewriteContext("What is real", "real", 8),
                rejectedCandidates = setOf("FEEL"),
                dictionary = dictionary
            ).isBlank()
        )
    }

    @Test
    fun synonymBoundaryAllowsKnownWordsAndBlocksAdversaries() {
        val service = AIService()

        assertEquals(
            listOf("gleam", "shine", "radiance"),
            service.extractSynonyms("gleam, shine, glow, radiance", exclude = "glow", dictionary = dictionary)
        )
        assertEquals(
            emptyList(),
            service.extractSynonyms("g-l-e-a-m, a-skew, GLOW", exclude = "glow", dictionary = dictionary)
        )
        assertEquals(
            emptyList(),
            service.extractSynonyms("<start_of_turn>model\ngleam", exclude = "glow", dictionary = dictionary)
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
