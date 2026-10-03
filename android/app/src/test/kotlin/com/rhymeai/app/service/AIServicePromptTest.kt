package com.rhymeai.app.service

import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.util.PronunciationDictionary
import com.rhymeai.app.util.RhymeConstraint
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AIServicePromptTest {
    @Test
    fun reducedPayloadsExcludePrivateLyricsForEveryCloudProvider() {
        val service = AIService()
        val privateText = "PRIVATE_VERSE_SENTINEL"
        val chorusText = "PRIVATE_CHORUS_SENTINEL"
        val song = "[Verse]\n$privateText\n\n[Chorus]\n$chorusText"
        for (wholeSong in listOf(false, true)) {
            val suggestions = service.buildPrompt(
                "allowed theme", song, "ALLOWED_TARGET", RhymeType.PERFECT, "AABB", "A",
                SongSection.CHORUS, RhymeComplexity.MODERATE, wholeSong,
                sectionRef = com.rhymeai.app.util.SectionRef(SongSection.CHORUS, 2, "Chorus", 3 until 5)
            )
            val rewrite = service.buildRewritePrompt(
                RewriteAction.entries.first(), song, "ALLOWED_SELECTION", SongSection.VERSE, wholeSong
            )
            for (prompt in listOf(suggestions, rewrite)) {
                // Gemini SDK receives this exact prompt; the other providers serialize it here.
                for (stream in listOf(false, true)) {
                    val payloads = listOf(
                        prompt,
                        service.buildOpenAIChatRequestBody("fixture", prompt, 0.7, stream).toString(),
                        service.buildClaudeMessagesRequestBody("fixture", prompt, stream).toString()
                    )
                    payloads.forEach { payload ->
                        assertEquals(wholeSong, payload.contains(privateText))
                        assertEquals(wholeSong, payload.contains(chorusText))
                        assertContains(payload, "ALLOWED_")
                    }
                }
            }
        }
    }

    private val rhymeDictionary = PronunciationDictionary.fromLines(
        sequenceOf(
            "road\tR OW1 D",
            "glowed\tG L OW1 D",
            "showed\tSH OW1 D"
        )
    )

    @Test
    fun serviceBatchAndStreamRetainPerfectRhymeBeyondCappedDisplayPool() = runBlocking {
        val crowded = PronunciationDictionary.fromLines(
            sequenceOf("rain\tR EY1 N", "pain\tP EY1 N") +
                (0 until 65).asSequence().map { index ->
                    "rhyme${'a' + index / 26}${'a' + index % 26}\tR EY1 N"
                } + sequenceOf("wane\tW EY1 N", "night\tN AY1 T")
        )
        val service = AIService()
        val constraint = assertNotNull(service.suggestionRhymeConstraint(
            targetRhymeLine = "I wait beneath the rain",
            rhymeType = RhymeType.PERFECT,
            dictionary = crowded
        ))
        assertFalse("wane" in constraint.candidateWords)

        val batch = service.parseSuggestionList(
            "I wander through the night\nI watch the lanterns wane",
            constraint
        )
        assertEquals("I watch the lanterns wane", batch.first().text)
        assertEquals(2, batch.first().rhymeTier)
        assertEquals(0, batch.last().rhymeTier)

        val chunkProcessed = CompletableDeferred<Unit>()
        val finishUpstream = CompletableDeferred<Unit>()
        val streamed = mutableListOf<com.rhymeai.app.SuggestedLine>()
        val collector = launch {
            flow<com.rhymeai.app.SuggestedLine> {
                with(service) {
                    emitLinesFromTokens(flow {
                        emit(
                            "I wander through the night\n" +
                                "I watch the lanterns wane\n" +
                                "I wait along the shore\n" +
                                "I watch the lanterns wane\n"
                        )
                        chunkProcessed.complete(Unit)
                        finishUpstream.await()
                    }, constraint)
                }
            }.collect { streamed += it }
        }
        try {
            withTimeout(5_000) { chunkProcessed.await() }
            assertEquals(listOf("I watch the lanterns wane"), streamed.map { it.text })
            assertEquals(listOf(2), streamed.map { it.rhymeTier })
        } finally {
            finishUpstream.complete(Unit)
        }
        withTimeout(5_000) { collector.join() }
        assertEquals(
            listOf("I watch the lanterns wane", "I wander through the night", "I wait along the shore"),
            streamed.map { it.text }
        )
        assertEquals(listOf(2, 0, 0), streamed.map { it.rhymeTier })
    }

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
        assertContains(immediatePrompt, "Prioritize the target line")
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
        assertContains(localPrompt, "Task: write exactly 6 next-line options for the song.")
        assertContains(localPrompt, "Return exactly 6 lines.")
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

        assertFalse(prompt.contains("<start_of_turn>"))
        assertFalse(prompt.contains("<|turn>"))
        assertContains(prompt, "Task: write exactly 6 next-line options for the song.")
        assertContains(prompt, "End every suggestion with a slant rhyme")
        assertContains(prompt, "Return only candidate lyric lines")
        assertContains(prompt, "Do not apologize, explain limitations, or restate the rules")
        assertContains(prompt, "Keep each suggestion under 16 words")
    }

    @Test
    fun localRewriteCleanerAcceptsJsonAndRejectsChatMarkers() {
        val service = AIService()

        assertEquals(
            "I trade the dark for a borrowed glow",
            service.cleanLocalRewrite("""{"rewrite":"I trade the dark for a borrowed glow"}""")
        )
        assertEquals(
            "",
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
    fun localRewriteCleanerRequiresBareSingleWordReplacement() {
        val service = AIService()

        assertEquals("gleam", service.cleanLocalRewrite("gleam", selection = "glow"))
        assertEquals("", service.cleanLocalRewrite("glow -> gleam", selection = "glow"))
        assertEquals("", service.cleanLocalRewrite("shine, gleam, radiance", selection = "glow"))
        assertEquals("", service.cleanLocalRewrite("The replacement is \"gleam\".", selection = "glow"))
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
    fun localPassageRewriteCleanerRequiresExactSelectedLineCount() {
        val service = AIService()

        assertEquals(
            "I hum a tune to hold it near",
            service.cleanLocalRewrite(
                response = "I hum a tune to hold it near",
                selection = "I hum the hook to keep it close"
            )
        )
        assertEquals(
            "I counted all the miles\nYou watched the county line",
            service.cleanLocalRewrite(
                response = "I counted all the miles\nYou watched the county line",
                selection = "I counted every mile\nYou watched the county line"
            )
        )
        assertEquals(
            "",
            service.cleanLocalRewrite(
                response = "I hum a tune to hold it near\nA low and steady sound I hear",
                selection = "I hum the hook to keep it close"
            )
        )
        assertEquals(
            "",
            service.cleanLocalRewrite(
                response = "I counted all the miles",
                selection = "I counted every mile\nYou watched the county line"
            )
        )
    }

    @Test
    fun emptySuggestionResponsesParseToEmptyList() {
        val service = AIService()

        assertEquals(emptyList<com.rhymeai.app.SuggestedLine>(), service.parseSuggestionList(""))
        assertEquals(emptyList<com.rhymeai.app.SuggestedLine>(), service.parseSuggestionList("```json\n[]\n```"))
    }

    // --- Section-aware prompt directive tests ---

    @Test
    fun buildPromptIncludesVerseOrdinalDirective() {
        val service = AIService()
        val ref = com.rhymeai.app.util.SectionRef(
            type = SongSection.VERSE,
            ordinal = 2,
            label = "Verse 2",
            lineRange = 5 until 10
        )
        val constraint = service.suggestionRhymeConstraint(
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            dictionary = rhymeDictionary,
            sectionRef = ref
        )
        val prompt = service.buildPrompt(
            theme = "late-night resolve",
            lyrics = "[Verse]\nYellow lights on a midnight road\n\n[Verse 2]\nI find the words in the city glow",
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            rhymeScheme = "AABB",
            currentLetter = "A",
            currentSection = SongSection.VERSE,
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = true,
            constraint = constraint
        )
        assertContains(prompt, "This is Verse 2.")
        // Existing section label must still be present.
        assertContains(prompt, "Current song section: Verse.")
    }

    @Test
    fun buildPromptIncludesBridgeDirective() {
        val service = AIService()
        val ref = com.rhymeai.app.util.SectionRef(
            type = SongSection.BRIDGE,
            ordinal = 1,
            label = "Bridge",
            lineRange = 8 until 12
        )
        val constraint = service.suggestionRhymeConstraint(
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.NEAR,
            dictionary = rhymeDictionary,
            sectionRef = ref
        )
        val prompt = service.buildPrompt(
            theme = "late-night resolve",
            lyrics = "[Chorus]\nKeep moving through the dark\n\n[Bridge]\nSomething different here",
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.NEAR,
            rhymeScheme = "AABB",
            currentLetter = "A",
            currentSection = SongSection.BRIDGE,
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = true,
            constraint = constraint
        )
        assertContains(prompt, "This is the bridge — introduce a contrasting rhyme sound and cadence; avoid the chorus's ending words.")
        assertContains(prompt, "Current song section: Bridge.")
    }

    @Test
    fun buildPromptIncludesChorusRepeatDirectiveForSecondInstance() {
        val service = AIService()
        val lyrics = "[Verse]\nYellow lights on a midnight road\n\n[Chorus]\nKeep moving through the dark\nNever let go of the spark\n\n[Chorus]\nSecond chorus here"
        val ref = com.rhymeai.app.util.SectionRef(
            type = SongSection.CHORUS,
            ordinal = 2,
            label = "Chorus",
            lineRange = 7 until 9
        )
        val constraint = service.suggestionRhymeConstraint(
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            dictionary = rhymeDictionary,
            sectionRef = ref
        )
        val prompt = service.buildPrompt(
            theme = "late-night resolve",
            lyrics = lyrics,
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            rhymeScheme = "AABB",
            currentLetter = "A",
            currentSection = SongSection.CHORUS,
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = true,
            constraint = constraint
        )
        assertContains(prompt, "This is the chorus (instance 2). Keep hook language and ending words consistent with the established chorus:")
        // First chorus lines should be quoted so the LLM knows the anchor.
        assertContains(prompt, "Keep moving through the dark")
    }

    @Test
    fun buildPromptDoesNotAddDirectiveForFirstChorusInstance() {
        val service = AIService()
        val ref = com.rhymeai.app.util.SectionRef(
            type = SongSection.CHORUS,
            ordinal = 1,
            label = "Chorus",
            lineRange = 3 until 6
        )
        val constraint = service.suggestionRhymeConstraint(
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            dictionary = rhymeDictionary,
            sectionRef = ref
        )
        val prompt = service.buildPrompt(
            theme = "late-night resolve",
            lyrics = "[Chorus]\nKeep moving through the dark",
            targetRhymeLine = "Yellow lights on a midnight road",
            rhymeType = RhymeType.PERFECT,
            rhymeScheme = "AABB",
            currentLetter = "A",
            currentSection = SongSection.CHORUS,
            complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = false,
            constraint = constraint
        )
        assertFalse(prompt.contains("This is the chorus (instance"))
    }

    @Test
    fun verseConstraintExcludesChorusEndWords() {
        val service = AIService()
        // Build a lyrics string where "glowed" is a chorus end-word
        val lyrics = "[Chorus]\nI never let the fire glowed\n[Verse]\nYellow lights on a midnight road"
        val chorusEnds = service.firstChorusEndWords(lyrics, rhymeDictionary)
        assertTrue("glowed" in chorusEnds, "chorus end words should include 'glowed'")

        val ref = com.rhymeai.app.util.SectionRef(
            type = SongSection.VERSE,
            ordinal = 1,
            label = "Verse",
            lineRange = 2 until 4
        )
        val constraint = assertNotNull(
            service.suggestionRhymeConstraint(
                targetRhymeLine = "Yellow lights on a midnight road",
                rhymeType = RhymeType.PERFECT,
                dictionary = rhymeDictionary,
                sectionRef = ref,
                chorusEndWords = chorusEnds
            )
        )
        // "road" is the target word; chorus end word "glowed" is also a rhyme
        // candidate but should be excluded from verse candidate words.
        assertFalse("glowed" in constraint.candidateWords, "'glowed' should be excluded from verse candidates")
        // Remaining candidates must not be empty (fallback logic).
        assertTrue(constraint.candidateWords.isNotEmpty(), "verse candidates must remain non-empty after exclusion")
    }

    @Test
    fun verseConstraintKeepsUnfilteredListWhenExclusionWouldEmpty() {
        val service = AIService()
        // All rhyme candidates happen to be chorus end-words; exclusion must not
        // produce an empty list — the unfiltered set is kept instead.
        val allCandidateWords = RhymeConstraint.candidateEndWords("road", RhymeType.PERFECT, dictionary = rhymeDictionary)
        // Use ALL candidates as chorus end-words to trigger the fallback.
        val chorusEnds = allCandidateWords.toSet()
        val ref = com.rhymeai.app.util.SectionRef(
            type = SongSection.VERSE,
            ordinal = 1,
            label = "Verse",
            lineRange = 0 until 2
        )
        val constraint = assertNotNull(
            service.suggestionRhymeConstraint(
                targetRhymeLine = "Yellow lights on a midnight road",
                rhymeType = RhymeType.PERFECT,
                dictionary = rhymeDictionary,
                sectionRef = ref,
                chorusEndWords = chorusEnds
            )
        )
        // Fallback: full candidate list retained.
        assertEquals(allCandidateWords, constraint.candidateWords)
    }

    @Test
    fun tierBadgeIsHookWhenChorusRepeatEndWordMatches() {
        val service = AIService()
        val lyrics = "[Chorus]\nI follow every road\n\n[Chorus]\nSecond chorus"
        val chorusEnds = service.firstChorusEndWords(lyrics, rhymeDictionary)
        val ref = com.rhymeai.app.util.SectionRef(
            type = SongSection.CHORUS,
            ordinal = 2,
            label = "Chorus",
            lineRange = 3 until 5
        )
        val constraint = assertNotNull(
            service.suggestionRhymeConstraint(
                targetRhymeLine = "Yellow lights on a midnight road",
                rhymeType = RhymeType.PERFECT,
                dictionary = rhymeDictionary,
                sectionRef = ref,
                chorusEndWords = chorusEnds
            )
        )
        // "road" is in firstChorusEndWords; parseSuggestionList should mark it isHook.
        val results = service.parseSuggestionList(
            raw = "I walk along the road\nI glow under the showed",
            constraint = constraint
        )
        val hookLine = results.firstOrNull { it.isHook }
        assertNotNull(hookLine, "Expected at least one isHook=true suggestion when end word matches chorus")
    }
}
