package com.rhymeai.app.service

import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.util.PronunciationDictionary
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AIServicePromptTest {
    private val rhymeDictionary = PronunciationDictionary.fromLines(
        sequenceOf(
            "road\tR OW1 D",
            "glowed\tG L OW1 D",
            "showed\tSH OW1 D"
        )
    )

    @Test
    fun suggestionPromptShapesImmediateAndWholeSongContext() {
        val service = AIService()
        val immediatePrompt = service.buildPrompt(
            theme = "late-night resolve",
            lyrics = "[Verse]\nYellow lights on a midnight road",
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            rhymeScheme = "AABB",
            currentLetter = "A",
            currentSection = SongSection.VERSE,
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = false
        )
        val wholeSongPrompt = service.buildPrompt(
            theme = "ignored when whole-song context is enabled",
            lyrics = "[Verse]\nYellow lights\n\n[Chorus]\nKeep moving",
            targetRhymeLine = null,
            rhymeType = RhymeType.SLANT,
            rhymeScheme = "ABAB",
            currentLetter = "B",
            currentSection = SongSection.CHORUS,
            complexity = RhymeComplexity.COMPLEX,
            useWholeSongContext = true
        )

        assertContains(immediatePrompt, "late-night resolve")
        assertContains(immediatePrompt, "Prioritize the immediate writing context")
        assertContains(immediatePrompt, "MUST end with a **Perfect Rhyme**")
        assertContains(immediatePrompt, "Current song section: Verse.")
        assertContains(immediatePrompt, "Complexity level: Moderate")
        assertContains(immediatePrompt, "Respond with exactly 6 lines")

        assertContains(wholeSongPrompt, "Whole song context enabled; infer the theme from the full lyrics.")
        assertContains(wholeSongPrompt, "Analyze the whole song for story arc")
        assertContains(wholeSongPrompt, "new rhyme sound (\"B\")")
        assertContains(wholeSongPrompt, "Current song section: Chorus.")
        assertContains(wholeSongPrompt, "Complexity level: Complex")
    }

    @Test
    fun suggestionPromptsConstrainEndWordsAndOverGenerateWhenDictionaryKnowsTarget() {
        val service = AIService()
        val constraint = assertNotNull(
            service.suggestionRhymeConstraint(
                targetRhymeLine = "Yellow lights on a midnight road",
                rhymeType = RhymeType.PERFECT,
                dictionary = rhymeDictionary
            )
        )
        assertEquals("road", constraint.targetWord)
        assertTrue("glowed" in constraint.candidateWords)

        val prompt = service.buildPrompt(
            theme = "late-night resolve",
            lyrics = "[Verse]\nYellow lights on a midnight road",
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            rhymeScheme = "AABB",
            currentLetter = "A",
            currentSection = SongSection.VERSE,
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = false,
            constraint = constraint
        )
        assertContains(prompt, "The new line must rhyme with: \"Yellow lights on a midnight road\" (it ends with \"road\").")
        assertContains(prompt, "End each line with one of these rhyming words: glowed, showed (choose the most natural fit).")
        assertContains(prompt, "Provide 12 creative")
        assertContains(prompt, "Respond with exactly 12 lines")

        val localPrompt = service.buildLocalPrompt(
            theme = "late-night resolve",
            lyrics = "[Verse]\nYellow lights on a midnight road",
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            rhymeScheme = "AABB",
            currentLetter = "A",
            currentSection = SongSection.VERSE,
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = false,
            constraint = constraint
        )
        assertContains(localPrompt, "End each line with one of these rhyming words: glowed, showed (choose the most natural fit).")
        assertContains(localPrompt, "Task: write exactly 12 next-line options for the song.")
        assertContains(localPrompt, "Return exactly 12 lines.")
    }

    @Test
    fun suggestionPromptsSkipRhymeConstraintWithoutTargetOrCandidates() {
        val service = AIService()

        assertNull(service.suggestionRhymeConstraint(null, RhymeType.PERFECT, rhymeDictionary))
        assertNull(service.suggestionRhymeConstraint("   ", RhymeType.PERFECT, rhymeDictionary))
        assertNull(service.suggestionRhymeConstraint("nothing rhymes with blorvex", RhymeType.PERFECT, rhymeDictionary))

        val prompt = service.buildPrompt(
            theme = "late-night resolve",
            lyrics = "[Verse]\nYellow lights on a midnight road",
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            rhymeScheme = "AABB",
            currentLetter = "A",
            currentSection = SongSection.VERSE,
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = false
        )
        assertFalse(prompt.contains("End each line with"))
        assertContains(prompt, "Respond with exactly 6 lines")
    }

    @Test
    fun rewritePromptIncludesEveryActionContract() {
        val service = AIService()

        RewriteAction.entries.forEach { action ->
            val prompt = service.buildRewritePrompt(
                action = action,
                lyrics = "[Bridge]\nI keep the melody close",
                selection = "I keep the melody close",
                currentSection = SongSection.BRIDGE
            )

            assertContains(prompt, "Current song section: Bridge.")
            assertContains(prompt, "Action: ${action.label}")
            assertContains(prompt, "Instruction: ${action.instruction}")
            assertContains(prompt, "Preserve line breaks where present.")
            assertContains(prompt, """{"rewrite": "..."}""")
        }
    }

    @Test
    fun localSuggestionPromptUsesGemmaStyleBoundedContract() {
        val service = AIService()

        val prompt = service.buildLocalPrompt(
            theme = "late-night resolve",
            lyrics = "[Verse]\nYellow lights on a midnight road\nI hum the hook to keep it close",
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.SLANT,
            rhymeScheme = "AABB",
            currentLetter = "A",
            currentSection = SongSection.VERSE,
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = false
        )

        assertContains(prompt, "<start_of_turn>user")
        assertContains(prompt, "Task: write exactly 6 next-line options for the song.")
        assertContains(prompt, "End every suggestion with a slant rhyme")
        assertContains(prompt, "Return only candidate lyric lines")
        assertContains(prompt, "Do not apologize, explain limitations, or restate the rules")
        assertContains(prompt, "Keep each suggestion under 16 words")
    }

    @Test
    fun localRewriteCleanerAcceptsJsonAndDropsChatMarkers() {
        val service = AIService()

        assertEquals(
            "I trade the dark for a borrowed glow",
            service.cleanLocalRewrite("""{"rewrite":"I trade the dark for a borrowed glow"}""")
        )
        assertEquals(
            "I trade the dark for a borrowed glow",
            service.cleanLocalRewrite(
                """
                <start_of_turn>model
                I trade the dark for a borrowed glow
                <end_of_turn>
                """.trimIndent()
            )
        )
    }

    @Test
    fun localRewriteCleanerExtractsSingleWordReplacement() {
        val service = AIService()

        assertEquals("gleam", service.cleanLocalRewrite("glow -> gleam", selection = "glow"))
        assertEquals("shine", service.cleanLocalRewrite("shine, gleam, radiance", selection = "glow"))
        assertEquals("gleam", service.cleanLocalRewrite("The replacement is \"gleam\".", selection = "glow"))
    }

    @Test
    fun localSingleWordRewritePromptRequiresDifferentReplacement() {
        val prompt = AIService().buildLocalRewritePrompt(
            action = RewriteAction.REPHRASE,
            lyrics = "[Verse]\nStatic in the dashboard glow",
            selection = "glow",
            currentSection = SongSection.VERSE
        )

        assertContains(prompt, "Task: replace the selected word")
        assertContains(prompt, "Return exactly one replacement word")
        assertContains(prompt, "Do not return \"glow\"")
        assertContains(prompt, "The replacement must be different from the selected word")
    }

    @Test
    fun emptySuggestionResponsesParseToEmptyList() {
        val service = AIService()

        assertEquals(emptyList(), service.parseSuggestionList(""))
        assertEquals(emptyList(), service.parseSuggestionList("```json\n[]\n```"))
    }
}
