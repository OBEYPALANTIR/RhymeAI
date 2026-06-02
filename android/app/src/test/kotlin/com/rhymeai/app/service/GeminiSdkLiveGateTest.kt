package com.rhymeai.app.service

import com.google.ai.client.generativeai.GenerativeModel
import com.rhymeai.app.BuildConfig
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class GeminiSdkLiveGateTest {

    @Test
    fun androidGenerativeAiSdkServesDefaultGeminiModelWhenDebugKeyIsPresent() = runBlocking {
        val apiKey = BuildConfig.GEMINI_TEST_KEY
        if (apiKey.isBlank()) {
            println("Skipping live Gemini SDK gate: android/local.properties has no geminiTestKey.")
            return@runBlocking
        }

        val response = withTimeout(30_000) {
            GenerativeModel(
                modelName = AIModel.DEFAULT.id,
                apiKey = apiKey
            ).generateContent("Respond with one short songwriting word.")
        }

        assertNotNull(response.text)
        assertTrue(response.text.orEmpty().isNotBlank())
    }
}
