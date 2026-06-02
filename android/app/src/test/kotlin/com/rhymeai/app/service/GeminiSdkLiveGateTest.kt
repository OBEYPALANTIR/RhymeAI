package com.rhymeai.app.service

import com.google.ai.client.generativeai.GenerativeModel
import com.rhymeai.app.BuildConfig
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class GeminiSdkLiveGateTest {

    private val apiKey: String
        get() = BuildConfig.GEMINI_TEST_KEY

    private fun skipWhenNoDebugKey(): Boolean {
        if (apiKey.isNotBlank()) return false
        println("Skipping live Gemini SDK gate: android/local.properties has no geminiTestKey.")
        return true
    }

    @Test
    fun androidGenerativeAiSdkServesDefaultGeminiModelWhenDebugKeyIsPresent() = runBlocking {
        if (skipWhenNoDebugKey()) return@runBlocking

        val response = withTimeout(30_000) {
            GenerativeModel(
                modelName = AIModel.DEFAULT.id,
                apiKey = apiKey
            ).generateContent("Respond with one short songwriting word.")
        }

        assertNotNull(response.text)
        assertTrue(response.text.orEmpty().isNotBlank())
    }

    @Test
    fun geminiSuggestionRewriteAndStreamingPathsWorkWithDebugKey() = runBlocking {
        if (skipWhenNoDebugKey()) return@runBlocking
        val service = AIService()
        val lyrics = "[Verse]\nYellow lights on a midnight road\nI keep the melody close"

        val suggestions = withTimeout(45_000) {
            service.getSuggestions(
                provider = AIProvider.GEMINI,
                apiKey = apiKey,
                modelId = AIModel.DEFAULT.id,
                theme = "late-night resolve",
                lyrics = lyrics,
                targetRhymeLine = "Yellow lights on a midnight road",
                rhymeType = RhymeType.PERFECT,
                rhymeScheme = "AABB",
                currentLetter = "A",
                currentSection = SongSection.VERSE,
                complexity = RhymeComplexity.MODERATE,
                useWholeSongContext = false
            )
        }
        assertTrue(suggestions.isNotEmpty(), "Gemini returned no suggestions")
        assertTrue(suggestions.all { it.isNotBlank() })

        val rewrite = withTimeout(45_000) {
            service.getRewrite(
                provider = AIProvider.GEMINI,
                apiKey = apiKey,
                modelId = AIModel.DEFAULT.id,
                action = RewriteAction.REPHRASE,
                fullLyrics = lyrics,
                selection = "I keep the melody close",
                currentSection = SongSection.VERSE
            )
        }
        assertTrue(rewrite.isNotBlank(), "Gemini returned no rewrite")

        val streamed = withTimeout(45_000) {
            service.streamSuggestions(
                provider = AIProvider.GEMINI,
                apiKey = apiKey,
                modelId = AIModel.DEFAULT.id,
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
        assertTrue(streamed.isNotEmpty(), "Gemini stream emitted no suggestions")
        assertTrue(streamed.all { it.isNotBlank() })
    }

    @Test
    fun geminiInvalidKeyFailureIsUserFacingAndDoesNotEchoSecret() = runBlocking {
        val service = AIService()
        val invalidKey = "invalid-gemini-key-for-test"

        val error = assertFailsWith<RuntimeException> {
            withTimeout(30_000) {
                service.getSuggestions(
                    provider = AIProvider.GEMINI,
                    apiKey = invalidKey,
                    modelId = AIModel.DEFAULT.id,
                    theme = "",
                    lyrics = "one line",
                    targetRhymeLine = null,
                    rhymeType = RhymeType.PERFECT,
                    rhymeScheme = "AABB",
                    currentLetter = "A",
                    currentSection = SongSection.UNKNOWN,
                    complexity = RhymeComplexity.MODERATE,
                    useWholeSongContext = false
                )
            }
        }

        val message = error.message.orEmpty()
        assertTrue(message.isNotBlank())
        assertTrue("Provider" in message)
        assertTrue(invalidKey !in message)
    }
}
