package com.rhymeai.app.service

import com.google.ai.client.generativeai.GenerativeModel
import com.google.ai.client.generativeai.type.generationConfig
import com.rhymeai.app.data.model.RhymeType
import kotlinx.serialization.json.Json

enum class GeminiModel(val id: String, val displayName: String) {
    GEMINI_31_PRO("gemini-3.1-pro-preview", "Gemini 3.1 Pro"),
    GEMINI_3_FLASH("gemini-3-flash-preview", "Gemini 3 Flash"),
    GEMINI_31_FLASH_LITE("gemini-3.1-flash-lite-preview", "Gemini 3.1 Flash Lite"),
    GEMINI_25_PRO("gemini-2.5-pro", "Gemini 2.5 Pro"),
    GEMINI_25_FLASH("gemini-2.5-flash", "Gemini 2.5 Flash"),
    GEMINI_25_FLASH_LITE("gemini-2.5-flash-lite", "Gemini 2.5 Flash Lite");

    companion object {
        val DEFAULT = GEMINI_3_FLASH
        fun fromId(id: String): GeminiModel =
            entries.find { it.id == id } ?: DEFAULT
    }
}

class GeminiService {
    private val json = Json { ignoreUnknownKeys = true }

    private fun createModel(apiKey: String, modelId: String) = GenerativeModel(
        modelName = modelId,
        apiKey = apiKey,
        generationConfig = generationConfig {
            responseMimeType = "application/json"
        }
    )

    suspend fun getRhymeSuggestions(
        apiKey: String,
        modelId: String,
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String
    ): List<String> {
        if (apiKey.isBlank()) {
            throw IllegalStateException("No API key set. Go to Settings to add your Gemini API key.")
        }

        val rhymeInstruction = if (targetRhymeLine != null) {
            "Crucially, the new line MUST end with a **${rhymeType.displayName}** to this specific line: \"$targetRhymeLine\"."
        } else {
            "Since this is a new rhyme sound (\"$currentLetter\"), the new line should introduce a new end-rhyme that fits the meter and theme."
        }

        val prompt = """
You are an expert songwriter and lyricist.
The user is writing a song with the following theme/context: "${theme.ifEmpty { "No specific theme provided" }}".
Here are the current lyrics:
${"\"\"\""}
$lyrics
${"\"\"\""}

The user needs a line that follows the current lyrics.
The current stanza follows a "$rhymeScheme" rhyme scheme, and the next line corresponds to the letter "$currentLetter".
$rhymeInstruction

Provide 5 creative, poetic, and contextually relevant suggestions for the next line.
Make sure the rhythm and meter match the style of the current lyrics${if (targetRhymeLine != null) ", and strictly adhere to the requested rhyme type (${rhymeType.displayName})" else ""}.

Respond ONLY with a JSON array of 5 strings. No markdown, no code fences, just the raw JSON array.
""".trimIndent()

        return try {
            val model = createModel(apiKey, modelId)
            val response = model.generateContent(prompt)
            val text = response.text?.trim() ?: return emptyList()
            val cleaned = text
                .removePrefix("```json")
                .removePrefix("```")
                .removeSuffix("```")
                .trim()
            json.decodeFromString<List<String>>(cleaned)
        } catch (e: Exception) {
            e.printStackTrace()
            throw e
        }
    }
}
