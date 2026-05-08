package com.rhymeai.app.service

import com.google.ai.client.generativeai.GenerativeModel
import com.google.ai.client.generativeai.type.generationConfig
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

enum class AIProvider(val displayName: String) {
    GEMINI("Gemini"),
    OPENAI("OpenAI"),
    CLAUDE("Claude"),
    LOCAL("Local");

    companion object {
        fun fromName(name: String): AIProvider =
            entries.find { it.name == name } ?: GEMINI
    }
}

enum class AIModel(val id: String, val displayName: String, val provider: AIProvider) {
    // Gemini
    GEMINI_31_PRO("gemini-3.1-pro-preview", "Gemini 3.1 Pro", AIProvider.GEMINI),
    GEMINI_3_FLASH("gemini-3-flash-preview", "Gemini 3 Flash", AIProvider.GEMINI),
    GEMINI_31_FLASH_LITE("gemini-3.1-flash-lite-preview", "Gemini 3.1 Flash Lite", AIProvider.GEMINI),
    GEMINI_25_PRO("gemini-2.5-pro", "Gemini 2.5 Pro", AIProvider.GEMINI),
    GEMINI_25_FLASH("gemini-2.5-flash", "Gemini 2.5 Flash", AIProvider.GEMINI),
    GEMINI_25_FLASH_LITE("gemini-2.5-flash-lite", "Gemini 2.5 Flash Lite", AIProvider.GEMINI),

    // OpenAI
    GPT_41("gpt-4.1", "GPT-4.1", AIProvider.OPENAI),
    GPT_41_MINI("gpt-4.1-mini", "GPT-4.1 Mini", AIProvider.OPENAI),
    GPT_41_NANO("gpt-4.1-nano", "GPT-4.1 Nano", AIProvider.OPENAI),
    GPT_4O("gpt-4o", "GPT-4o", AIProvider.OPENAI),
    GPT_4O_MINI("gpt-4o-mini", "GPT-4o Mini", AIProvider.OPENAI),

    // Claude
    CLAUDE_SONNET("claude-sonnet-4-20250514", "Claude Sonnet 4", AIProvider.CLAUDE),
    CLAUDE_HAIKU("claude-haiku-4-5-20251001", "Claude Haiku 4.5", AIProvider.CLAUDE),
    CLAUDE_OPUS("claude-opus-4-20250514", "Claude Opus 4", AIProvider.CLAUDE),

    // Local on-device
    LOCAL_MODEL("local-model", "On-Device Model", AIProvider.LOCAL);

    companion object {
        val DEFAULT = GEMINI_3_FLASH
        fun fromId(id: String): AIModel =
            entries.find { it.id == id } ?: DEFAULT
        fun modelsForProvider(provider: AIProvider): List<AIModel> =
            entries.filter { it.provider == provider }
    }
}

class AIService {
    private companion object {
        const val SUGGESTION_COUNT = 6
    }

    private val json = Json { ignoreUnknownKeys = true }

    fun buildPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        complexity: RhymeComplexity,
        useWholeSongContext: Boolean
    ): String {
        val rhymeInstruction = if (targetRhymeLine != null) {
            "Crucially, the new line MUST end with a **${rhymeType.displayName}** to this specific line: \"$targetRhymeLine\"."
        } else {
            "Since this is a new rhyme sound (\"$currentLetter\"), the new line should introduce a new end-rhyme that fits the meter and theme."
        }
        val songContextInstruction = if (useWholeSongContext) {
            "Analyze the whole song for story arc, recurring images, hook language, speaker perspective, tone, and vocabulary. Make each suggestion feel connected to the entire song while still fitting the immediate target line and rhyme scheme."
        } else {
            "Prioritize the immediate writing context, current stanza, target line, rhyme scheme, and provided theme/context."
        }

        val effectiveTheme = if (useWholeSongContext) {
            "Whole song context enabled; infer the theme from the full lyrics."
        } else {
            theme.ifEmpty { "No specific theme provided" }
        }

        return """
You are an expert songwriter and lyricist.
The user is writing a song with the following theme/context: "$effectiveTheme".
Here are the current lyrics:
${"\"\"\""}
$lyrics
${"\"\"\""}

The user needs a line that follows the current lyrics.
The current stanza follows a "$rhymeScheme" rhyme scheme, and the next line corresponds to the letter "$currentLetter".
$rhymeInstruction
$songContextInstruction

Complexity level: ${complexity.label}. ${complexity.promptHint}

Provide $SUGGESTION_COUNT creative, poetic, and contextually relevant suggestions for the next line.
Make sure the rhythm and meter match the style of the current lyrics${if (targetRhymeLine != null) ", and strictly adhere to the requested rhyme type (${rhymeType.displayName})" else ""}.

Respond ONLY with a JSON array of $SUGGESTION_COUNT strings. No markdown, no code fences, just the raw JSON array.
""".trimIndent()
    }

    var localModelService: LocalModelService? = null

    suspend fun getSuggestions(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        complexity: RhymeComplexity = RhymeComplexity.MODERATE,
        useWholeSongContext: Boolean = false
    ): List<String> {
        if (provider != AIProvider.LOCAL && apiKey.isBlank()) {
            throw IllegalStateException("No API key set. Go to Settings to add your ${provider.displayName} API key.")
        }

        return if (provider == AIProvider.LOCAL) {
            val localPrompt = buildLocalPrompt(theme, lyrics, targetRhymeLine, rhymeType, currentLetter, complexity, useWholeSongContext)
            callLocal(localPrompt)
        } else {
            val prompt = buildPrompt(theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter, complexity, useWholeSongContext)
            when (provider) {
                AIProvider.GEMINI -> callGemini(apiKey, modelId, prompt)
                AIProvider.OPENAI -> callOpenAI(apiKey, modelId, prompt)
                AIProvider.CLAUDE -> callClaude(apiKey, modelId, prompt)
                AIProvider.LOCAL -> error("unreachable")
            }
        }
    }

    private suspend fun callGemini(apiKey: String, modelId: String, prompt: String): List<String> {
        val model = GenerativeModel(
            modelName = modelId,
            apiKey = apiKey,
            generationConfig = generationConfig {
                responseMimeType = "application/json"
            }
        )
        val response = model.generateContent(prompt)
        val text = response.text?.trim() ?: return emptyList()
        return parseJsonArray(text)
    }

    private suspend fun callOpenAI(apiKey: String, modelId: String, prompt: String): List<String> {
        val body = buildJsonObject {
            put("model", modelId)
            put("messages", buildJsonArray {
                add(buildJsonObject {
                    put("role", "user")
                    put("content", prompt)
                })
            })
            put("temperature", 0.8)
        }

        val responseText = httpPost(
            url = "https://api.openai.com/v1/chat/completions",
            headers = mapOf(
                "Authorization" to "Bearer $apiKey",
                "Content-Type" to "application/json"
            ),
            body = body.toString()
        )

        val responseJson = json.parseToJsonElement(responseText).jsonObject
        val content = responseJson["choices"]?.jsonArray
            ?.firstOrNull()?.jsonObject
            ?.get("message")?.jsonObject
            ?.get("content")?.jsonPrimitive?.content ?: return emptyList()

        return parseJsonArray(content)
    }

    private suspend fun callClaude(apiKey: String, modelId: String, prompt: String): List<String> {
        val body = buildJsonObject {
            put("model", modelId)
            put("max_tokens", 1024)
            put("messages", buildJsonArray {
                add(buildJsonObject {
                    put("role", "user")
                    put("content", prompt)
                })
            })
        }

        val responseText = httpPost(
            url = "https://api.anthropic.com/v1/messages",
            headers = mapOf(
                "x-api-key" to apiKey,
                "anthropic-version" to "2023-06-01",
                "Content-Type" to "application/json"
            ),
            body = body.toString()
        )

        val responseJson = json.parseToJsonElement(responseText).jsonObject
        val content = responseJson["content"]?.jsonArray
            ?.firstOrNull()?.jsonObject
            ?.get("text")?.jsonPrimitive?.content ?: return emptyList()

        return parseJsonArray(content)
    }

    private fun buildLocalPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        currentLetter: String,
        complexity: RhymeComplexity,
        useWholeSongContext: Boolean
    ): String {
        // Small on-device models need (a) a persona, (b) a one-shot example
        // showing the exact desired output format, and (c) an unambiguous
        // output contract. Without all three, Gemma-class 2-4B models tend to
        // emit preamble ("Here are six lines:"), markdown code fences, or
        // trail off mid-line. The "Output:" suffix nudges the model to start
        // generating the JSON immediately.
        val rhymeHint = if (targetRhymeLine != null) {
            """MUST rhyme (${rhymeType.displayName.lowercase()}) with: "$targetRhymeLine""""
        } else {
            """Open new rhyme sound for letter "$currentLetter""""
        }
        val effectiveTheme = if (useWholeSongContext) {
            "infer from the full lyrics"
        } else {
            theme.ifEmpty { "(no theme — match the existing tone)" }
        }
        val contextStrategy = if (useWholeSongContext) {
            "Reflect the whole song's arc and imagery."
        } else {
            "Match the current stanza's rhythm and tone."
        }

        return """
You write song lyrics. Reply with ONLY a JSON array of $SUGGESTION_COUNT short lyric lines. No commentary. No numbering. No markdown.

EXAMPLE
Theme: long road home
Lyrics so far:
"I drive these miles 'til they run out
Past the town I used to doubt"
Next line: MUST rhyme (perfect) with: "doubt"
Style: ${RhymeComplexity.MODERATE.label} — ${RhymeComplexity.MODERATE.promptHint}
Match the current stanza's rhythm and tone.

Output:
["Holding everything I'm without","Watching dreams begin to sprout","Wondering what life's about","Breaking through the silent shout","Searching for a different route","Finally figuring it out"]

NOW YOU
Theme: $effectiveTheme
Lyrics so far:
"$lyrics"
Next line: $rhymeHint
Style: ${complexity.label} — ${complexity.promptHint}
$contextStrategy

Output:
""".trimIndent()
    }

    private suspend fun callLocal(prompt: String): List<String> {
        val service = localModelService
            ?: throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        if (!service.isLoaded) {
            throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        }
        val response = service.generateResponse(
            prompt = prompt,
            params = LocalModelService.GenerationParams.SONGWRITING
        )
        // Try JSON first, fall back to line-based parsing
        val results = parseJsonArray(response).ifEmpty { parseLines(response) }
        if (results.isEmpty()) {
            throw RuntimeException("Local model returned no usable suggestions. Try a different model or use a cloud provider.")
        }
        return results
    }

    private val numberedPrefixPattern = Regex("^\\s*\\d+[.)\\-]\\s*")

    private fun parseLines(text: String): List<String> {
        return text.lines()
            .map { it.replace(numberedPrefixPattern, "").trim().removeSurrounding("\"") }
            .filter { it.isNotBlank() && it.length > 3 }
            .take(SUGGESTION_COUNT)
    }

    private suspend fun httpPost(url: String, headers: Map<String, String>, body: String): String =
        withContext(Dispatchers.IO) {
            val connection = URL(url).openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.connectTimeout = 30000
                connection.readTimeout = 60000
                headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }

                OutputStreamWriter(connection.outputStream, "UTF-8").use { it.write(body) }

                val code = connection.responseCode
                val stream = if (code in 200..299) connection.inputStream else connection.errorStream
                val response = stream.bufferedReader().use { it.readText() }

                if (code !in 200..299) {
                    throw RuntimeException("API error ($code): $response")
                }
                response
            } finally {
                connection.disconnect()
            }
        }

    private fun parseJsonArray(text: String): List<String> {
        val cleaned = text.trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
        // First try the cleaned text as-is; cloud responses are usually pristine.
        runCatching {
            return json.decodeFromString<List<String>>(cleaned).take(SUGGESTION_COUNT)
        }
        // Local models often wrap the array in preamble ("Sure! Here you go:")
        // or trail off after the closing bracket. Find the first balanced
        // top-level array substring and try parsing that.
        extractFirstJsonArray(cleaned)?.let { extracted ->
            runCatching {
                return json.decodeFromString<List<String>>(extracted).take(SUGGESTION_COUNT)
            }
        }
        return emptyList()
    }

    private fun extractFirstJsonArray(text: String): String? {
        val start = text.indexOf('[')
        if (start < 0) return null
        var depth = 0
        var inString = false
        var escaped = false
        for (i in start until text.length) {
            val c = text[i]
            if (escaped) { escaped = false; continue }
            if (c == '\\' && inString) { escaped = true; continue }
            if (c == '"') { inString = !inString; continue }
            if (inString) continue
            when (c) {
                '[' -> depth++
                ']' -> {
                    depth--
                    if (depth == 0) return text.substring(start, i + 1)
                }
            }
        }
        return null
    }
}
