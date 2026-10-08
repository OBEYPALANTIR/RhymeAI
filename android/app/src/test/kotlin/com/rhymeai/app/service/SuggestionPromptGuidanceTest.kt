package com.rhymeai.app.service

import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.util.PronunciationDictionary
import com.rhymeai.app.util.ProsodyAnalyzer
import com.rhymeai.app.util.RhymeConstraint
import com.rhymeai.app.util.WordFrequency
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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
        // Simple and Complex carry the numeric targets measured in the 2026-10-07
        // complexity experiments; byte-identical on iOS and in finetune/eval/prompts.py.
        assertEquals(
            "Each line must be 4 to 7 plain, everyday words. Prefer one-syllable end words. No wordplay.",
            RhymeComplexity.SIMPLE.promptHint
        )
        assertEquals(
            "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear rather than clever.",
            RhymeComplexity.MODERATE.promptHint
        )
        assertEquals(
            "Each line must be 8 to 12 words. End each line on a word of two or more syllables, or put an internal rhyme inside the line. Use vivid, specific, less common words and double meanings.",
            RhymeComplexity.COMPLEX.promptHint
        )
        assertFalse(RhymeComplexity.MODERATE.promptHint.contains("wordplay"))
        assertFalse(RhymeComplexity.SIMPLE.promptHint.contains("double meanings"))
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
    fun complexityLevelReachesTheAllowedEndWordList() {
        fun words(level: RhymeComplexity) = service.suggestionRhymeConstraint(
            target, RhymeType.PERFECT, dictionary, complexity = level
        )!!.candidateWords
        fun syllables(word: String) = ProsodyAnalyzer.analyzeWord(word, dictionary).syllableCount
        val moderate = words(RhymeComplexity.MODERATE)
        val complex = words(RhymeComplexity.COMPLEX)
        val simple = words(RhymeComplexity.SIMPLE)
        assertEquals(service.suggestionRhymeConstraint(target, RhymeType.PERFECT, dictionary)!!.candidateWords, moderate)
        for ((level, expected) in listOf(RhymeComplexity.MODERATE to moderate, RhymeComplexity.COMPLEX to complex, RhymeComplexity.SIMPLE to simple)) {
            assertEquals(RhymeConstraint.candidateEndWords("home", RhymeType.PERFECT, dictionary = dictionary, complexity = level), expected)
        }
        assertTrue(complex.all { syllables(it) >= 2 }, "$complex")
        assertTrue(simple.all { syllables(it) == 1 }, "$simple")
        assertTrue(complex != moderate && simple != moderate)

        // Both prompt paths list the level's words. The cloud prompt without whole-song
        // context rebuilds the constraint itself, so the level must reach that path too.
        for ((level, expected) in listOf(RhymeComplexity.COMPLEX to complex, RhymeComplexity.SIMPLE to simple)) {
            val listLine = "End each line with one of these rhyming words: ${expected.joinToString(", ")} (choose the most natural fit)."
            val constraint = service.suggestionRhymeConstraint(target, RhymeType.PERFECT, dictionary, complexity = level)!!
            val local = service.buildLocalPrompt(
                theme = "", lyrics = lyrics, targetRhymeLine = target, rhymeType = RhymeType.PERFECT,
                rhymeScheme = "AABB", currentLetter = "A", currentSection = SongSection.VERSE,
                complexity = level, useWholeSongContext = true, constraint = constraint
            )
            assertContains(local, listLine)
            assertContains(local, "\nComplexity: ${level.label}. ${level.promptHint}\n")
            val moderateConstraint = service.suggestionRhymeConstraint(target, RhymeType.PERFECT, dictionary)!!
            val cloud = service.buildPrompt(
                "", lyrics, target, RhymeType.PERFECT, "AABB", "A", SongSection.VERSE, level, false, moderateConstraint
            )
            assertContains(cloud, listLine)
        }
    }

    private fun promptAndWords(
        anchor: String,
        level: RhymeComplexity,
        cloud: Boolean = false
    ): Pair<String, List<String>> {
        val targetLine = "Everything we said about $anchor"
        val song = "[Verse]\n$targetLine"
        val words = RhymeConstraint.candidateEndWords(
            anchor, RhymeType.PERFECT, dictionary = dictionary, wordFrequency = frequency, complexity = level
        )
        val constraint = AIService.SuggestionRhymeConstraint(targetLine, anchor, words, RhymeType.PERFECT, dictionary)
        val prompt = if (cloud) {
            service.buildPrompt("", song, targetLine, RhymeType.PERFECT, "AABB", "A", SongSection.VERSE, level, true, constraint)
        } else {
            service.buildLocalPrompt(
                theme = "", lyrics = song, targetRhymeLine = targetLine, rhymeType = RhymeType.PERFECT,
                rhymeScheme = "AABB", currentLetter = "A", currentSection = SongSection.VERSE,
                complexity = level, useWholeSongContext = true, constraint = constraint
            )
        }
        return prompt to words
    }

    private fun syllables(word: String) = ProsodyAnalyzer.analyzeWord(word, dictionary).syllableCount

    /** Anchors whose Simple list must carry longer words: the hint only prefers
     *  one-syllable endings and the end-word rule matches the list size, so no rule
     *  in the complete prompt contradicts the list. */
    @Test
    fun simpleFallbackListsNeverContradictThePrompt() {
        val level = RhymeComplexity.SIMPLE
        for ((anchor, expectMono) in listOf("arrival" to 0, "river" to 0, "love" to 4, "world" to 5)) {
            for (cloud in listOf(false, true)) {
                val (prompt, words) = promptAndWords(anchor, level, cloud)
                assertEquals(expectMono, words.count { syllables(it) == 1 }, "$anchor $words")
                assertTrue(words.any { syllables(it) >= 2 }, anchor)
                assertContains(prompt, "Complexity${if (cloud) " level" else ""}: ${level.label}. ${level.promptHint}")
                assertFalse(prompt.contains("one-syllable word."), prompt)
                assertContains(prompt, "End each line with one of these rhyming words: ${words.joinToString(", ")} (choose the most natural fit).")
                if (cloud) continue
                if (anchor == "arrival") {
                    assertTrue(words.size < 6, "$words")
                    assertContains(prompt, "The allowed list has fewer than six words, so end words may repeat")
                } else {
                    assertTrue(words.size >= 6, "$words")
                    assertContains(prompt, "- End each line on a different word from the allowed list.")
                }
            }
        }
    }

    @Test
    fun roadPromptIsConsistentAtEveryLevel() {
        for (level in RhymeComplexity.entries) {
            val (prompt, words) = promptAndWords("road", level)
            assertEquals(12, words.size, level.name)
            assertContains(prompt, "\nComplexity: ${level.label}. ${level.promptHint}\n")
            assertContains(prompt, "- End each line on a different word from the allowed list.")
            assertContains(prompt, words.joinToString(", ") + " (choose the most natural fit).")
            when (level) {
                RhymeComplexity.COMPLEX -> assertTrue(words.all { syllables(it) >= 2 }, "$words")
                RhymeComplexity.SIMPLE -> assertTrue(words.all { syllables(it) == 1 }, "$words")
                RhymeComplexity.MODERATE -> Unit
            }
        }
    }

    /** A first-chorus end word that rhymes with the target leads the list at every
     *  level, even when the level ordering pushed it past the 12-word cut. */
    @Test
    fun repeatedChorusHookIsPromotedAtEveryLevel() {
        val song = "[Chorus]\nI'm breaking through the code\nNo one knows the way I rode\n\n[Chorus]\nYellow lights on a midnight road"
        val second = com.rhymeai.app.util.SectionMap.parse(song).allSections.first { it.type == SongSection.CHORUS && it.ordinal == 2 }
        val hooks = service.firstChorusEndWords(song, dictionary)
        assertEquals(setOf("code", "rode"), hooks)
        val targetLine = "Yellow lights on a midnight road"
        assertTrue(hooks.all { ProsodyAnalyzer.rhymeRelation(it, "road", dictionary) == RhymeType.PERFECT })
        // Complex pushes the one-syllable hooks past the cut; they must still lead.
        assertFalse("code" in RhymeConstraint.candidateEndWords("road", RhymeType.PERFECT, dictionary = dictionary, complexity = RhymeComplexity.COMPLEX))
        for (level in RhymeComplexity.entries) {
            val words = service.suggestionRhymeConstraint(
                targetLine, RhymeType.PERFECT, dictionary, sectionRef = second, chorusEndWords = hooks, complexity = level
            )!!.candidateWords
            assertEquals(listOf("code", "rode"), words.take(2), level.name)
            assertEquals(RhymeConstraint.CANDIDATE_LIMIT, words.size, level.name)
            assertEquals(words.size, words.toSet().size, level.name)
            val levelList = RhymeConstraint.candidateEndWords("road", RhymeType.PERFECT, dictionary = dictionary, complexity = level)
            assertEquals(levelList.filter { it !in hooks }.take(10), words.drop(2), level.name)
        }
        // A first-chorus word that does not rhyme with the target, or the target itself, is not promoted.
        val words = service.suggestionRhymeConstraint(
            targetLine, RhymeType.PERFECT, dictionary, sectionRef = second,
            chorusEndWords = linkedSetOf("spark", "road", "code"), complexity = RhymeComplexity.COMPLEX
        )!!.candidateWords
        assertEquals("code", words.first())
        assertFalse("spark" in words)
        assertFalse("road" in words)
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

    @Test
    fun themeIsSentWithWholeSongContext() {
        val song = "[Verse]\nI keep the porch light on at home\nThe kettle ticks beside the phone"
        for (wholeSong in listOf(true, false)) {
            val local = service.buildLocalPrompt(
                theme = "  leaving a small town ", lyrics = song, targetRhymeLine = null,
                rhymeType = RhymeType.NEAR, rhymeScheme = "AABB", currentLetter = "A",
                currentSection = SongSection.VERSE, complexity = RhymeComplexity.MODERATE,
                useWholeSongContext = wholeSong
            )
            assertContains(local, "\nTheme: leaving a small town\n")
            assertContains(local, "The kettle ticks beside the phone")
            val cloud = service.buildPrompt(
                "leaving a small town", song, null, RhymeType.NEAR, "AABB", "A",
                SongSection.VERSE, RhymeComplexity.MODERATE, wholeSong
            )
            assertContains(cloud, "theme/context: \"leaving a small town\"")
            assertEquals(wholeSong, cloud.contains("The kettle ticks beside the phone"))
        }
        val empty = service.buildLocalPrompt(
            theme = " ", lyrics = song, targetRhymeLine = null, rhymeType = RhymeType.NEAR,
            rhymeScheme = "AABB", currentLetter = "A", complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = true
        )
        assertContains(empty, "\nTheme: Infer from the lyrics.\n")
        val emptyCloud = service.buildPrompt(
            "", song, null, RhymeType.NEAR, "AABB", "A", SongSection.VERSE, RhymeComplexity.MODERATE, true
        )
        assertContains(emptyCloud, "Whole song context enabled; infer the theme from the full lyrics.")
    }

    private fun repoFile(path: String): File =
        sequenceOf("../../$path", "../$path", path).map(::File).first(File::isFile)

    @Test
    fun everyWindowStaysWithinBudget() {
        val songs = fixture().getValue("songs").jsonObject.mapValues { it.value.jsonPrimitive.content }
        for ((id, song) in songs) {
            val lineCount = song.split("\n").size
            for (cursor in (0 until lineCount).map<Int, Int?> { it } + null) {
                for ((wholeSong, budget) in listOf(true to 3100, false to 2600)) {
                    val window = service.localLyricsContext(song, wholeSong, cursor)
                    assertTrue(window.length <= budget, "$id cursor=$cursor wholeSong=$wholeSong: ${window.length}")
                }
            }
        }
    }

    @Test
    fun endWordRuleFollowsAllowedListSize() {
        val sixWords = listOf("phone", "alone", "known", "own", "show", "go")
        assertEquals("- End each line on a different word.", service.localEndWordRule(null))
        assertEquals(FEWER_THAN_SIX_RULE, service.localEndWordRule(sixWords.take(3)))
        assertEquals(FEWER_THAN_SIX_RULE, service.localEndWordRule(sixWords.take(5)))
        assertEquals("- End each line on a different word from the allowed list.", service.localEndWordRule(sixWords))
        // Repeated (chorus hook) words count once, case-folded.
        assertEquals(FEWER_THAN_SIX_RULE, service.localEndWordRule(List(6) { "night" } + listOf("Night", "light", "bright")))

        fun promptWith(words: List<String>) = localPrompt(
            constraint = AIService.SuggestionRhymeConstraint(target, "home", words, RhymeType.NEAR, dictionary)
        )
        val three = promptWith(listOf("phone", "alone", "known"))
        assertContains(three, "End each line with one of these rhyming words: phone, alone, known (choose the most natural fit).")
        assertTrue(three.endsWith(RULES_HEAD + FEWER_THAN_SIX_RULE + "\n" + RULES_TAIL), three)
        assertFalse(three.contains("different word from the allowed list"))
        val six = promptWith(sixWords)
        assertTrue(six.endsWith(RULES_WITH_LIST), six)
        assertFalse(six.contains("may repeat"))
        // A later chorus listing its hook word several times still has fewer than six endings.
        val hook = promptWith(List(6) { "home" } + listOf("phone", "alone"))
        assertContains(hook, "rhyming words: home, home, home, home, home, home, phone, alone (choose")
        assertTrue(hook.endsWith(RULES_HEAD + FEWER_THAN_SIX_RULE + "\n" + RULES_TAIL), hook)
    }

    private fun fixture(): JsonObject =
        Json.parseToJsonElement(repoFile("shared/fixtures/local-lyric-window-v1.json").readText()).jsonObject

    @Test
    fun localContextMatchesSharedCursorWindowFixture() {
        // iOS reads a bundled copy; it must not drift from the shared fixture.
        assertTrue(
            repoFile("shared/fixtures/local-lyric-window-v1.json").readBytes()
                .contentEquals(repoFile("Writers Block/Writers BlockTests/local-lyric-window-v1.json").readBytes()),
            "iOS fixture copy differs from shared/fixtures/local-lyric-window-v1.json"
        )
        val fixture = fixture()
        val songs = fixture.getValue("songs").jsonObject.mapValues { it.value.jsonPrimitive.content }
        val song = songs.getValue("main")
        val lines = song.split("\n")
        assertEquals(300, lines.size)
        assertEquals(4000, songs.getValue("oneLongLine").length)
        assertEquals(listOf(14, 4000, 16), songs.getValue("longMiddleLine").split("\n").map { it.length })
        val cases = fixture.getValue("cases").jsonArray.map { it.jsonObject }
        assertEquals(22, cases.size)
        assertEquals(4000, songs.getValue("emojiLine").length) // 2,000 non-BMP scalars
        for (case in cases) {
            val name = case.getValue("name").jsonPrimitive.content
            val songId = case.getValue("song").jsonPrimitive.content
            val cursor = case.getValue("cursorLine").jsonPrimitive.intOrNull
            val wholeSong = case.getValue("useWholeSongContext").jsonPrimitive.boolean
            val expected = case.getValue("expected").jsonPrimitive.content
            val actual = service.localLyricsContext(songs.getValue(songId), wholeSong, cursor)
            assertEquals(expected, actual, name)
            assertTrue(actual.length <= if (wholeSong) 3100 else 2600, name)
            if (songId == "main") {
                // The cursor's stanza and the cursor line are always present.
                val c = cursor ?: lines.lastIndex
                val start = (c - 1 downTo 0).firstOrNull { lines[it].isBlank() }?.plus(1) ?: 0
                assertContains(actual, lines.subList(start, c + 1).joinToString("\n").trim(), message = name)
            }
        }
        // The cursor reaches the built prompt.
        val middle = cases.first { it.getValue("name").jsonPrimitive.content == "middle_lyric_whole" }
        val prompt = service.buildLocalPrompt(
            theme = "", lyrics = song, targetRhymeLine = null, rhymeType = RhymeType.NEAR,
            rhymeScheme = "AABB", currentLetter = "A", complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = true, cursorLine = middle.getValue("cursorLine").jsonPrimitive.int
        )
        assertContains(prompt, "\"\"\"\n" + middle.getValue("expected").jsonPrimitive.content + "\n\"\"\"")
        // Short lyrics are sent as is.
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
        const val FEWER_THAN_SIX_RULE =
            "- The allowed list has fewer than six words, so end words may repeat, but the six lines must still be six different ideas."
        const val RULES_WITH_LIST = RULES_HEAD + "- End each line on a different word from the allowed list.\n" + RULES_TAIL
        const val RULES_WITHOUT_LIST = RULES_HEAD + "- End each line on a different word.\n" + RULES_TAIL
    }
}
