package com.rhymeai.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.service.AIService
import com.rhymeai.app.service.LocalModelService
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LocalModelInstrumentedTest {
    @Test
    fun cancellationQuiescesBeforeImmediateNextRequest() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val modelPath = arguments.getString("localModelPath").orEmpty()
        val modelLabel = arguments.getString("localModelLabel") ?: "accepted-e2b"
        assumeTrue(
            "Set instrumentation argument localModelPath to run the live GGUF cancellation test.",
            modelPath.isNotBlank()
        )

        val service = LocalModelService()
        service.initialize(instrumentation.targetContext)
        try {
            service.loadModel(modelPath)
            val invalidModel = File(instrumentation.targetContext.cacheDir, "invalid-replacement.gguf")
            invalidModel.writeBytes("GGUF-not-a-model".toByteArray())
            val replacementFailure = runCatching { service.loadModel(invalidModel.absolutePath) }
            assertTrue("Invalid replacement model must fail", replacementFailure.isFailure)
            assertFalse("Failed replacement must clear loaded state", service.isLoaded)
            service.loadModel(modelPath)
            assertTrue("Accepted model must reload after replacement failure", service.isLoaded)
            invalidModel.delete()
            val firstChunk = CompletableDeferred<String>()
            val privacySentinel = "RHYME_PRIVACY_SENTINEL_7319"
            val oldRequest = launch {
                service.streamResponse(
                    gemmaInstructionPrompt("Repeat $privacySentinel on 64 separate lines. Return only those lines.")
                ).collect { chunk ->
                    if (!firstChunk.isCompleted) firstChunk.complete(chunk)
                }
            }
            withTimeout(LocalModelService.GENERATION_TIMEOUT_MS) { firstChunk.await() }
            oldRequest.cancelAndJoin()
            val cancelled = requireNotNull(service.lastGenerationMetrics)
            assertTrue("Cancelled request must record cancellation", cancelled.terminationReason == "cancelled")

            val freshResponse = withTimeout(LocalModelService.GENERATION_TIMEOUT_MS + 10_000L) {
                service.generateResponse(
                    gemmaInstructionPrompt("Write one short original lyric line. Return only the line.")
                )
            }.trim()
            val fresh = requireNotNull(service.lastGenerationMetrics)
            assertTrue("Immediate next request returned blank output", freshResponse.isNotBlank())
            assertFalse("Immediate next request received a stale token", freshResponse.contains(privacySentinel))
            assertTrue("Fresh request must not inherit cancellation", fresh.terminationReason != "cancelled")
            println(
                "LOCAL_MODEL_CANCELLATION model=$modelLabel " +
                    "cancelTotalMs=${cancelled.totalDurationMs} freshTtfcMs=${fresh.timeToFirstChunkMs} " +
                    "freshTotalMs=${fresh.totalDurationMs} freshChars=${fresh.outputCharacters} " +
                    "freshReason=${fresh.terminationReason}"
            )
        } finally {
            service.unload()
        }
    }

    @Test
    fun localGgufModelLoadsAndGeneratesText() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val modelPath = InstrumentationRegistry.getArguments().getString("localModelPath").orEmpty()
        val modelLabel = InstrumentationRegistry.getArguments().getString("localModelLabel") ?: "local-gguf"
        assumeTrue(
            "Set instrumentation argument localModelPath to run the live GGUF smoke test.",
            modelPath.isNotBlank()
        )

        val modelFile = File(modelPath)
        assertTrue("Model file does not exist at $modelPath", modelFile.exists())
        assertTrue("Model file is not readable at $modelPath", modelFile.canRead())

        val service = LocalModelService()
        service.initialize(instrumentation.targetContext)

        try {
            service.loadModel(modelPath)
            val rawStart = System.currentTimeMillis()
            val response = firstNonBlankRawResponse(service)
            println("LOCAL_MODEL_RESULT model=$modelLabel case=raw_generate elapsedMs=${System.currentTimeMillis() - rawStart} chars=${response.length}")

            assertTrue("Local model returned blank output", response.isNotBlank())

            runServiceEval(modelLabel, service)
        } finally {
            service.unload()
        }
    }

    private suspend fun firstNonBlankRawResponse(service: LocalModelService): String {
        val prompts = listOf(
            gemmaInstructionPrompt("Write one short, original songwriting line. Return only the line."),
            gemmaInstructionPrompt("Continue this lyric with one short line:\nMidnight notes on a borrowed train"),
            "Write one short, original songwriting line. Return only the line."
        )
        for (prompt in prompts) {
            val response = service.generateResponse(prompt).trim()
            if (response.isNotBlank()) return response
        }
        return ""
    }

    private suspend fun runServiceEval(modelLabel: String, localModelService: LocalModelService) {
        val service = AIService().also { it.localModelService = localModelService }
        val lyrics = """
            [Verse]
            Yellow lights on a midnight road
            I hum the hook to keep it close
            Static in the dashboard glow
        """.trimIndent()

        val suggestions = timedEval(modelLabel, "suggestions") {
            service.getSuggestions(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                theme = "late-night resolve",
                lyrics = lyrics,
                targetRhymeLine = "Yellow lights on a midnight road",
                rhymeType = RhymeType.SLANT,
                rhymeScheme = "AABB",
                currentLetter = "A",
                currentSection = SongSection.VERSE,
                complexity = RhymeComplexity.MODERATE,
                useWholeSongContext = false
            )
        }
        assertTrue("Local suggestions should contain exactly six usable lines", suggestions.size == 6)
        assertTrue(
            "Local suggestions should be distinct",
            suggestions.map { it.text.trim().lowercase() }.distinct().size == suggestions.size
        )
        assertTrue("Local suggestions should not be blank", suggestions.all { it.text.isNotBlank() })
        assertNoPromptEcho("suggestion", suggestions.map { it.text })
        assertFalse("Local suggestions should not copy an existing lyric line", suggestions.any { lyrics.lines().contains(it.text) })

        val rewrite = timedEval(modelLabel, "rewrite") {
            service.getRewrite(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                action = RewriteAction.REPHRASE,
                fullLyrics = lyrics,
                selection = "I hum the hook to keep it close",
                currentSection = SongSection.VERSE
            )
        }
        assertTrue("Local rewrite should return usable text", rewrite.isNotBlank())
        assertNoPromptEcho("rewrite", listOf(rewrite))
        assertFalse("Local rewrite should change the selected text", rewrite.trim() == "I hum the hook to keep it close")

        val singleWordRewrite = timedEval(modelLabel, "single_word_rewrite") {
            service.getRewrite(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                action = RewriteAction.REPHRASE,
                fullLyrics = lyrics,
                selection = "glow",
                currentSection = SongSection.VERSE
            )
        }
        assertTrue("Local single-word rewrite should return one replacement word", singleWordRewrite.matches(Regex("[\\p{L}\\p{N}'-]+")))
        assertFalse("Local single-word rewrite should not return the selected word", singleWordRewrite.equals("glow", ignoreCase = true))
        assertNoPromptEcho("single word rewrite", listOf(singleWordRewrite))

        val punchUpRewrite = timedEval(modelLabel, "punch_up") {
            service.getRewrite(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                action = RewriteAction.PUNCH_UP,
                fullLyrics = lyrics,
                selection = "I hum the hook to keep it close",
                currentSection = SongSection.VERSE
            )
        }
        println("LOCAL_MODEL_SAMPLE model=$modelLabel case=punch_up text=${punchUpRewrite.replace("\n", " / ")}")
        assertTrue("Local punch-up rewrite should return usable text", punchUpRewrite.isNotBlank())
        assertNoPromptEcho("punch up rewrite", listOf(punchUpRewrite))
        assertFalse("Local punch-up rewrite should change the selected text", punchUpRewrite.trim() == "I hum the hook to keep it close")

        val singleWordPunchUp = timedEval(modelLabel, "single_word_punch_up") {
            service.getRewrite(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                action = RewriteAction.PUNCH_UP,
                fullLyrics = lyrics,
                selection = "glow",
                currentSection = SongSection.VERSE
            )
        }
        println("LOCAL_MODEL_SAMPLE model=$modelLabel case=single_word_punch_up text=$singleWordPunchUp")
        assertTrue("Local single-word punch-up should return one replacement word", singleWordPunchUp.matches(Regex("[\\p{L}\\p{N}'-]+")))
        assertFalse("Local single-word punch-up should not return the selected word", singleWordPunchUp.equals("glow", ignoreCase = true))
        assertNoPromptEcho("single word punch up", listOf(singleWordPunchUp))

        val harderSingleWordRewrite = timedEval(modelLabel, "harder_single_word_rewrite") {
            val chorusLyrics = """
                [Chorus]
                We're lost
                We don't even know what's real
                We're lost
                We go with what we feel
            """.trimIndent()
            service.getRewrite(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                action = RewriteAction.HARDER_RHYME,
                fullLyrics = chorusLyrics,
                selection = "real",
                currentSection = SongSection.CHORUS,
                selectionStart = chorusLyrics.indexOf("real")
            )
        }
        assertTrue(
            "Local harder-rhyme single-word rewrite should return one short replacement word",
            harderSingleWordRewrite.matches(Regex("[\\p{L}\\p{N}'-]+")) && harderSingleWordRewrite.length <= 8
        )
        assertFalse("Local harder-rhyme single-word rewrite should not return the selected word", harderSingleWordRewrite.equals("real", ignoreCase = true))
        assertFalse("Local harder-rhyme single-word rewrite should reject awkward expansions", harderSingleWordRewrite.equals("reality", ignoreCase = true))
        assertNoPromptEcho("harder single word rewrite", listOf(harderSingleWordRewrite))

        val reportedLyrics = """
            [Verse 1]
            In the land of make believe
            Where we claim to be free
            Hypnotized by TVs
            Personalized social feeds

            Cold corporate walls
            Birds chirping in phone calls
        """.trimIndent()
        val wallsRewrite = timedEval(modelLabel, "harder_reported_walls") {
            service.getRewrite(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                action = RewriteAction.HARDER_RHYME,
                fullLyrics = reportedLyrics,
                selection = "walls",
                currentSection = SongSection.VERSE,
                selectionStart = reportedLyrics.indexOf("walls")
            )
        }
        assertFalse("Local harder-rhyme rewrite should not repeat walls", wallsRewrite.equals("walls", ignoreCase = true))
        assertNoPromptEcho("reported walls harder rhyme", listOf(wallsRewrite))

        assertRejectsBadHarderRhyme(
            modelLabel = modelLabel,
            caseName = "harder_reported_calls",
            service = service,
            lyrics = reportedLyrics,
            selection = "calls",
            forbidden = setOf("calls", "walls", "falls", "halls")
        )
        assertRejectsBadHarderRhyme(
            modelLabel = modelLabel,
            caseName = "harder_reported_make",
            service = service,
            lyrics = reportedLyrics,
            selection = "make",
            forbidden = setOf("make", "deceive")
        )
        assertRejectsBadHarderRhyme(
            modelLabel = modelLabel,
            caseName = "harder_reported_feeds",
            service = service,
            lyrics = reportedLyrics,
            selection = "feeds",
            forbidden = setOf("feeds", "streams")
        )

        val synonyms = timedEval(modelLabel, "synonyms") {
            service.getSynonyms(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                word = "glow",
                lineContext = "Static in the dashboard glow",
                limit = 6
            )
        }
        assertTrue("Local synonyms should return at least one valid word", synonyms.isNotEmpty())
        assertTrue("Local synonyms should be bounded to the requested limit", synonyms.size <= 6)
        assertTrue("Local synonyms should not include the target word", synonyms.none { it.equals("glow", ignoreCase = true) })
    }

    private suspend fun <T> timedEval(modelLabel: String, caseName: String, block: suspend () -> T): T {
        val start = System.currentTimeMillis()
        val result = block()
        val count = when (result) {
            is Collection<*> -> result.size
            is String -> result.length
            else -> 1
        }
        println("LOCAL_MODEL_RESULT model=$modelLabel case=$caseName elapsedMs=${System.currentTimeMillis() - start} count=$count")
        return result
    }

    private suspend fun assertRejectsBadHarderRhyme(
        modelLabel: String,
        caseName: String,
        service: AIService,
        lyrics: String,
        selection: String,
        forbidden: Set<String>
    ) {
        val start = System.currentTimeMillis()
        val result = runCatching {
            service.getRewrite(
                provider = AIProvider.LOCAL,
                apiKey = "",
                modelId = AIModel.LOCAL_MODEL.id,
                action = RewriteAction.HARDER_RHYME,
                fullLyrics = lyrics,
                selection = selection,
                currentSection = SongSection.VERSE,
                selectionStart = lyrics.indexOf(selection)
            )
        }
        val value = result.getOrNull().orEmpty()
        println(
            "LOCAL_MODEL_RESULT model=$modelLabel case=$caseName elapsedMs=${System.currentTimeMillis() - start} " +
                "count=${value.length} status=${if (result.isSuccess) "accepted" else "rejected"}"
        )
        result.onSuccess { rewrite ->
            assertTrue("Local harder-rhyme $caseName should return one word", rewrite.matches(Regex("[\\p{L}\\p{N}'-]+")))
            assertFalse(
                "Local harder-rhyme $caseName accepted a forbidden preview: $rewrite",
                forbidden.any { rewrite.equals(it, ignoreCase = true) }
            )
            assertNoPromptEcho(caseName, listOf(rewrite))
        }.onFailure { error ->
            assertTrue(
                "Local harder-rhyme $caseName should fail with the single-word guidance, got: ${error.message}",
                error.message?.contains("No safe rhyme", ignoreCase = true) == true
            )
        }
    }

    private fun assertNoPromptEcho(caseName: String, lines: List<String>) {
        val forbiddenPrefixes = listOf(
            "task:",
            "theme:",
            "rules:",
            "lyrics context:",
            "sure",
            "here are",
            "as an ai",
            "i can't"
        )
        val echoed = lines.firstOrNull { line ->
            forbiddenPrefixes.any { prefix -> line.trim().startsWith(prefix, ignoreCase = true) }
        }
        assertTrue("$caseName output echoed prompt/chatter: $echoed", echoed == null)
    }

    private fun gemmaInstructionPrompt(userPrompt: String): String =
        """
<start_of_turn>user
$userPrompt
<end_of_turn>
<start_of_turn>model
""".trimIndent()
}
