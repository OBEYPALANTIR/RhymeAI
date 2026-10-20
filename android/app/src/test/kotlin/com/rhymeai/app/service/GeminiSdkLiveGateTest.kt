package com.rhymeai.app.service

import com.google.ai.client.generativeai.GenerativeModel
import com.rhymeai.app.BuildConfig
import com.rhymeai.app.SuggestedLine
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
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class GeminiSdkLiveGateTest {

    private val apiKey: String
        get() = BuildConfig.GEMINI_TEST_KEY

    private val liveGeminiModels = listOf(
        AIModel.GEMINI_35_FLASH,
        AIModel.GEMINI_31_PRO
    )

    private fun requireDebugKey() {
        assumeTrue(
            "Skipping live Gemini SDK gate: android/local.properties has no geminiTestKey.",
            apiKey.isNotBlank()
        )
    }

    @Test
    fun androidGenerativeAiSdkServesConfiguredGeminiModelsWhenDebugKeyIsPresent() = runBlocking {
        requireDebugKey()

        liveGeminiModels.forEach { model ->
            val response = withTimeout(45_000) {
                GenerativeModel(
                    modelName = model.id,
                    apiKey = apiKey
                ).generateContent("Respond with one short songwriting word.")
            }

            assertNotNull(response.text, "Gemini returned no text for ${model.id}")
            assertTrue(response.text.orEmpty().isNotBlank(), "Gemini returned blank text for ${model.id}")
        }
    }

    @Test
    fun geminiSuggestionRewriteAndStreamingPathsWorkWithDebugKey() = runBlocking {
        requireDebugKey()
        val service = AIService()
        val lyrics = "[Verse]\nYellow lights on a midnight road\nI keep the melody close"

        liveGeminiModels.forEach { model ->
            val suggestions = withTimeout(60_000) {
                service.streamSuggestions(
                    provider = AIProvider.GEMINI,
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
            assertTrue(suggestions.isNotEmpty(), "Gemini returned no suggestions for ${model.id}")
            assertTrue(suggestions.all { it.text.isNotBlank() }, "Gemini returned blank suggestions for ${model.id}")

            RewriteAction.entries.forEach { action ->
                val rewrite = withTimeout(60_000) {
                    service.getRewrite(
                        provider = AIProvider.GEMINI,
                        apiKey = apiKey,
                        modelId = model.id,
                        action = action,
                        fullLyrics = lyrics,
                        selection = "I keep the melody close",
                        currentSection = SongSection.VERSE
                    )
                }
                assertTrue(rewrite.isNotBlank(), "Gemini returned no ${action.name} rewrite for ${model.id}")
            }

            val streamed = withTimeout(60_000) {
                service.streamSuggestions(
                    provider = AIProvider.GEMINI,
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
                ).toList()
            }
            assertTrue(streamed.isNotEmpty(), "Gemini stream emitted no suggestions for ${model.id}")
            assertTrue(streamed.all { it.text.isNotBlank() }, "Gemini stream emitted blank suggestions for ${model.id}")
        }
    }

    @Test
    fun geminiStreamingCanBeCancelledAfterFirstSuggestionWithDebugKey() = runBlocking {
        requireDebugKey()
        val service = AIService()
        val lyrics = "[Verse]\nYellow lights on a midnight road\nI keep the melody close"

        liveGeminiModels.forEach { model ->
            val firstSuggestion = withTimeout(60_000) {
                service.streamSuggestions(
                    provider = AIProvider.GEMINI,
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

            assertEquals(1, firstSuggestion.size, "Gemini stream did not cancel after first suggestion for ${model.id}")
            assertTrue(firstSuggestion.single().text.isNotBlank(), "Gemini first streamed suggestion was blank for ${model.id}")
        }
    }

    @Test
    fun geminiInvalidKeyFailureIsUserFacingAndDoesNotEchoSecret() = runBlocking {
        val service = AIService()
        val invalidKey = "invalid-gemini-key-for-test"

        liveGeminiModels.forEach { model ->
            val error = assertFailsWith<RuntimeException> {
                withTimeout(30_000) {
                    service.streamSuggestions(
                        provider = AIProvider.GEMINI,
                        apiKey = invalidKey,
                        modelId = model.id,
                        theme = "",
                        lyrics = "one line",
                        targetRhymeLine = null,
                        rhymeType = RhymeType.PERFECT,
                        rhymeScheme = "AABB",
                        currentLetter = "A",
                        currentSection = SongSection.UNKNOWN,
                        complexity = RhymeComplexity.MODERATE,
                        useWholeSongContext = false
                    ).toList()
                }
            }

            val message = error.message.orEmpty()
            assertTrue(message.isNotBlank(), "Invalid-key failure message was blank for ${model.id}")
            assertTrue("Provider" in message, "Invalid-key failure was not user-facing for ${model.id}: $message")
            assertTrue(invalidKey !in message, "Invalid Gemini key leaked for ${model.id}")
        }
    }
}
