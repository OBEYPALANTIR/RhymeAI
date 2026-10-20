package com.rhymeai.app.service

import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import kotlin.test.Test
import kotlin.test.assertTrue

class ProviderLiveGateTest {

    @Test
    fun openAIConfiguredModelServesSuggestionRewriteAndStreamWhenKeyIsPresent() = runBlocking {
        verifyProviderWhenKeyIsPresent(
            provider = AIProvider.OPENAI,
            apiKey = System.getenv("OPENAI_TEST_KEY").orEmpty()
        )
    }

    @Test
    fun claudeConfiguredModelServesSuggestionRewriteAndStreamWhenKeyIsPresent() = runBlocking {
        verifyProviderWhenKeyIsPresent(
            provider = AIProvider.CLAUDE,
            apiKey = System.getenv("CLAUDE_TEST_KEY").orEmpty()
                .ifBlank { System.getenv("ANTHROPIC_TEST_KEY").orEmpty() }
        )
    }

    private suspend fun verifyProviderWhenKeyIsPresent(provider: AIProvider, apiKey: String) {
        assumeTrue(
            "Skipping live ${provider.displayName} gate: no ${testKeyDescription(provider)} is set.",
            apiKey.isNotBlank()
        )

        val service = AIService()
        val model = modelForProvider(provider)
        val lyrics = "[Verse]\nYellow lights on a midnight road\nI keep the melody close"

        val suggestions = withTimeout(60_000) {
            service.streamSuggestions(
                provider = provider,
                apiKey = apiKey,
                modelId = model.id,
                theme = "late-night resolve",
                lyrics = lyrics,
                targetRhymeLine = "Yellow lights on a midnight road",
                rhymeType = RhymeType.PERFECT,
                rhymeScheme = "AABB",
                currentLetter = "A",
                currentSection = SongSection.VERSE,
                complexity = RhymeComplexity.MODERATE,
                useWholeSongContext = false
            ).toList()
        }
        assertTrue(suggestions.isNotEmpty(), "${provider.displayName} returned no suggestions for ${model.id}")
        assertTrue(suggestions.all { it.text.isNotBlank() })

        val rewrite = withTimeout(60_000) {
            service.getRewrite(
                provider = provider,
                apiKey = apiKey,
                modelId = model.id,
                action = RewriteAction.REPHRASE,
                fullLyrics = lyrics,
                selection = "I keep the melody close",
                currentSection = SongSection.VERSE
            )
        }
        assertTrue(rewrite.isNotBlank(), "${provider.displayName} returned no rewrite for ${model.id}")

        val streamed = withTimeout(60_000) {
            service.streamSuggestions(
                provider = provider,
                apiKey = apiKey,
                modelId = model.id,
                theme = "late-night resolve",
                lyrics = lyrics,
                targetRhymeLine = null,
                rhymeType = RhymeType.PERFECT,
                rhymeScheme = "AABB",
                currentLetter = "B",
                currentSection = SongSection.VERSE,
                complexity = RhymeComplexity.MODERATE,
                useWholeSongContext = true
            ).take(1).toList()
        }
        assertTrue(streamed.isNotEmpty(), "${provider.displayName} stream emitted no suggestions for ${model.id}")
        assertTrue(streamed.all { it.text.isNotBlank() })
    }

    private fun testKeyDescription(provider: AIProvider): String =
        when (provider) {
            AIProvider.OPENAI -> "OPENAI_TEST_KEY"
            AIProvider.CLAUDE -> "CLAUDE_TEST_KEY or ANTHROPIC_TEST_KEY"
            else -> "${provider.name}_TEST_KEY"
        }

    private fun modelForProvider(provider: AIProvider): AIModel {
        val override = when (provider) {
            AIProvider.OPENAI -> System.getenv("OPENAI_TEST_MODEL")
            AIProvider.CLAUDE -> System.getenv("CLAUDE_TEST_MODEL")
            else -> null
        }.orEmpty()
        return if (override.isBlank()) {
            AIModel.modelsForProvider(provider).first()
        } else {
            AIModel.modelsForProvider(provider).firstOrNull { it.id == override }
                ?: error("Unknown ${provider.displayName} test model: $override")
        }
    }
}
