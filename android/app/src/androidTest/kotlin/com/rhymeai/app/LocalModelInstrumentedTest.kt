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
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LocalModelInstrumentedTest {
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
        assertTrue("Local suggestions should contain at least two usable lines", suggestions.size >= 2)
        assertTrue("Local suggestions should be bounded to six lines", suggestions.size <= 6)
        assertTrue("Local suggestions should not be blank", suggestions.all { it.isNotBlank() })
        assertNoPromptEcho("suggestion", suggestions)
        assertFalse("Local suggestions should not copy an existing lyric line", suggestions.any { lyrics.lines().contains(it) })

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
        assertTrue("Local synonyms should return at least two words", synonyms.size >= 2)
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
