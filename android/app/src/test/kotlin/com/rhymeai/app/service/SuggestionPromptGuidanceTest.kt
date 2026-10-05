package com.rhymeai.app.service

import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.util.PronunciationDictionary
import com.rhymeai.app.util.RhymeConstraint
import com.rhymeai.app.util.WordFrequency
import java.io.File
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Next-line guidance shared with iOS `SuggestionPromptGuidanceTests.swift`:
 * per-level complexity wording, the inspire-not-finish rules, and the
 * on-device lyric context budget. Expected strings are identical on both sides.
 */
class SuggestionPromptGuidanceTest {
    private val service = AIService()

    private fun asset(name: String): File = sequenceOf(
        "../../shared/pronunciation/$name",
        "../shared/pronunciation/$name",
        "shared/pronunciation/$name"
    ).map(::File).first(File::isFile)

    private val dictionary: PronunciationDictionary by lazy {
        asset("cmudict-rhymeai.tsv").bufferedReader().useLines(PronunciationDictionary::fromLines)
    }
    private val frequency: WordFrequency by lazy {
        WordFrequency().also { wf -> asset("word-frequency.txt").bufferedReader().useLines(wf::load) }
    }

    private val lyrics = "[Verse]\nI keep the porch light on at home"
    private val target = "I keep the porch light on at home"

    private fun nearConstraint(): AIService.SuggestionRhymeConstraint {
        val words = RhymeConstraint.candidateEndWords("home", RhymeType.NEAR, dictionary = dictionary, wordFrequency = frequency)
        assertTrue(words.isNotEmpty())
        return AIService.SuggestionRhymeConstraint(target, "home", words, RhymeType.NEAR, dictionary)
    }

    private fun localPrompt(
        complexity: RhymeComplexity = RhymeComplexity.MODERATE,
        targetLine: String? = target,
        constraint: AIService.SuggestionRhymeConstraint? = null,
        wholeSong: Boolean = true
    ) = service.buildLocalPrompt(
        theme = "",
        lyrics = lyrics,
        targetRhymeLine = targetLine,
        rhymeType = RhymeType.NEAR,
        rhymeScheme = "AABB",
        currentLetter = "A",
        currentSection = SongSection.VERSE,
        complexity = complexity,
        useWholeSongContext = wholeSong,
        constraint = constraint
    )

    @Test
    fun complexityHintsOnlyAskForWordplayAtComplex() {
        assertEquals(
            "Use plain, simple, everyday language. No wordplay, puns, or clever twists. Use clear rhymes that are easy to hear.",
            RhymeComplexity.SIMPLE.promptHint
        )
        assertEquals(
            "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear rather than clever.",
            RhymeComplexity.MODERATE.promptHint
        )
        assertEquals(
            "Use advanced, rich vocabulary with clever wordplay and intricate rhymes: multi-syllable rhymes, internal rhymes, and double meanings.",
            RhymeComplexity.COMPLEX.promptHint
        )
        assertFalse(RhymeComplexity.MODERATE.promptHint.contains("wordplay"))
        assertEquals(listOf(0, 1, 2), RhymeComplexity.entries.map { it.level })

        for (level in RhymeComplexity.entries) {
            assertContains(localPrompt(complexity = level), "\nComplexity: ${level.label}. ${level.promptHint}\n")
            val cloud = service.buildPrompt(
                "", lyrics, target, RhymeType.NEAR, "AABB", "A", SongSection.VERSE, level, true
            )
            assertContains(cloud, "Complexity level: ${level.label}. ${level.promptHint}")
            assertFalse(cloud.contains("some clever wordplay"))
        }
    }

    @Test
    fun localPromptAsksForIdeasNotAFinishedVerse() {
        val prompt = localPrompt(constraint = nearConstraint())
        println("NEAR_CASE_PROMPT_BEGIN\n$prompt\nNEAR_CASE_PROMPT_END")

        assertContains(prompt, "\nThe writer is stuck on the next line and wants ideas to pick from, not a finished verse.\n")
        assertContains(prompt, "End each line with one of these rhyming words: ")
        assertTrue(prompt.endsWith(RULES_WITH_LIST), prompt)
        // Parser-facing count and format rules are unchanged.
        assertContains(prompt, "Task: write exactly 6 next-line options for the song.")
    }

    @Test
    fun localPromptWithoutWordListAsksForDifferentEndWords() {
        val noTarget = localPrompt(targetLine = null)
        assertTrue(noTarget.endsWith(RULES_WITHOUT_LIST), noTarget)
        assertFalse(noTarget.contains("allowed list"))

        val unknownTarget = localPrompt(constraint = null)
        assertTrue(unknownTarget.endsWith(RULES_WITHOUT_LIST), unknownTarget)
    }

    private fun numberedSong(lineCount: Int) =
        (1..lineCount).joinToString("\n") { "line %04d of the song".format(it) }

    private fun lines(range: IntRange) = range.joinToString("\n") { "line %04d of the song".format(it) }

    @Test
    fun localContextKeepsWholeSongWithinBudget() {
        // 130 lines = 2,859 characters: over 2,600 but within head + tail, so sent whole.
        val medium = numberedSong(130)
        assertEquals(2859, medium.length)
        assertEquals(medium, service.localLyricsContext(medium, useWholeSongContext = true))

        // 300 lines = 6,599 characters: opening 900 and closing 2,200 characters, cut to whole lines.
        val long = numberedSong(300)
        assertEquals(
            lines(1..40) + "\n\n[Middle lyrics trimmed for on-device speed]\n\n" + lines(201..300),
            service.localLyricsContext(long, useWholeSongContext = true)
        )

        // Whole Song Context off (Android only; iOS sends the stanza) keeps the last 2,600 characters.
        assertEquals(
            "[Earlier lyrics trimmed for on-device speed]\n" + lines(183..300),
            service.localLyricsContext(long, useWholeSongContext = false)
        )
        assertEquals("a\nb", service.localLyricsContext("  a\nb \n", useWholeSongContext = true))
    }

    private companion object {
        const val RULES_HEAD = """Rules:
- Return exactly 6 lines.
- One suggestion per line.
- Return only candidate lyric lines.
- Make the six lines six different directions: a different idea, image or angle in each. Do not write the same thought six ways.
"""
        const val RULES_TAIL = """- Write them as raw material in the writer's own voice: match the length, plainness and capitalisation of the lines around it.
- Do not resolve or conclude the song, do not sum it up, and no grand statements.
- Stay inside what the song is already about.
- Do not copy any existing lyric line.
- Do not repeat the same suggestion.
- No numbering, bullets, quotes, markdown, labels, or explanation.
- Do not apologize, explain limitations, or restate the rules.
- Keep each suggestion under 16 words."""
        const val RULES_WITH_LIST = RULES_HEAD + "- End each line on a different word from the allowed list.\n" + RULES_TAIL
        const val RULES_WITHOUT_LIST = RULES_HEAD + "- End each line on a different word.\n" + RULES_TAIL
    }
}
