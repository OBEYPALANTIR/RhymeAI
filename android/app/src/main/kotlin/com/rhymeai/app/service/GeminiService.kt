package com.rhymeai.app.service

import com.google.ai.client.generativeai.GenerativeModel
import com.google.ai.client.generativeai.type.generationConfig
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
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
        const val LOCAL_RECENT_CONTEXT_CHARS = 2600
        const val LOCAL_WHOLE_SONG_HEAD_CHARS = 900
        const val LOCAL_WHOLE_SONG_TAIL_CHARS = 2200
    }

    private val json = Json { ignoreUnknownKeys = true }

    fun buildPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        currentSection: SongSection = SongSection.UNKNOWN,
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
Current song section: ${currentSection.displayName}.
${currentSection.promptHint}
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
        currentSection: SongSection = SongSection.UNKNOWN,
        complexity: RhymeComplexity = RhymeComplexity.MODERATE,
        useWholeSongContext: Boolean = false
    ): List<String> {
        if (provider != AIProvider.LOCAL && apiKey.isBlank()) {
            throw IllegalStateException("No API key set. Go to Settings to add your ${provider.displayName} API key.")
        }

        return if (provider == AIProvider.LOCAL) {
            val localPrompt = buildLocalPrompt(
                theme = theme,
                lyrics = lyrics,
                targetRhymeLine = targetRhymeLine,
                rhymeType = rhymeType,
                rhymeScheme = rhymeScheme,
                currentLetter = currentLetter,
                currentSection = currentSection,
                complexity = complexity,
                useWholeSongContext = useWholeSongContext
            )
            callLocal(localPrompt, lyrics)
        } else {
            val prompt = buildPrompt(theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter, currentSection, complexity, useWholeSongContext)
            when (provider) {
                AIProvider.GEMINI -> callGemini(apiKey, modelId, prompt)
                AIProvider.OPENAI -> callOpenAI(apiKey, modelId, prompt)
                AIProvider.CLAUDE -> callClaude(apiKey, modelId, prompt)
                AIProvider.LOCAL -> error("unreachable")
            }
        }
    }

    suspend fun getRewrite(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        action: RewriteAction,
        fullLyrics: String,
        selection: String,
        currentSection: SongSection = SongSection.UNKNOWN
    ): String {
        if (provider != AIProvider.LOCAL && apiKey.isBlank()) {
            throw IllegalStateException("No API key set. Go to Settings to add your ${provider.displayName} API key.")
        }
        if (selection.isBlank()) {
            throw IllegalStateException("Nothing selected to rewrite.")
        }

        return if (provider == AIProvider.LOCAL) {
            val prompt = buildLocalRewritePrompt(action, fullLyrics, selection, currentSection)
            callLocalRewrite(prompt, selection)
        } else {
            val prompt = buildRewritePrompt(action, fullLyrics, selection, currentSection)
            val raw = when (provider) {
                AIProvider.GEMINI -> callGeminiRaw(apiKey, modelId, prompt)
                AIProvider.OPENAI -> callOpenAIRaw(apiKey, modelId, prompt)
                AIProvider.CLAUDE -> callClaudeRaw(apiKey, modelId, prompt)
                AIProvider.LOCAL -> error("unreachable")
            }
            extractRewriteField(raw)?.takeIf { it.isNotBlank() }
                ?: throw RuntimeException("AI did not return a rewrite. Try again.")
        }
    }

    private fun buildRewritePrompt(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection = SongSection.UNKNOWN
    ): String =
        """
You are an expert songwriter helping the user rewrite a portion of their song.

Full lyrics for context:
${"\"\"\""}
$lyrics
${"\"\"\""}

The user has selected the following passage from those lyrics. Rewrite ONLY this passage:
${"\"\"\""}
$selection
${"\"\"\""}

Current song section: ${currentSection.displayName}.
${currentSection.promptHint}

Action: ${action.label}
Instruction: ${action.instruction}

Rules:
- Output the rewritten passage only.
- Preserve line breaks where present.
- Do not include the surrounding lyrics, commentary, labels, or markdown.

Respond ONLY with a JSON object of the form {"rewrite": "..."}. No code fences.
""".trimIndent()

    private fun buildLocalRewritePrompt(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection = SongSection.UNKNOWN
    ): String {
        val lyricContext = localLyricsContext(lyrics, useWholeSongContext = false)
        val userPrompt = """
You are RhymeAI's on-device songwriting assistant.

Task: rewrite the selected passage from the user's song.
Current song section: ${currentSection.displayName}.
${currentSection.promptHint}
Action: ${action.label}.
Instruction: ${action.instruction}

Lyrics context:
${"\"\"\""}
$lyricContext
${"\"\"\""}

Selected passage to rewrite:
${"\"\"\""}
$selection
${"\"\"\""}

Rules:
- Output the rewritten passage only.
- Preserve line breaks if the selection has multiple lines.
- No quotes, no markdown, no labels, no commentary.
""".trimIndent()
        return gemmaInstructionPrompt(userPrompt)
    }

    private suspend fun callGeminiRaw(apiKey: String, modelId: String, prompt: String): String {
        val model = GenerativeModel(
            modelName = modelId,
            apiKey = apiKey,
            generationConfig = generationConfig {
                responseMimeType = "application/json"
            }
        )
        return model.generateContent(prompt).text?.trim().orEmpty()
    }

    private suspend fun callOpenAIRaw(apiKey: String, modelId: String, prompt: String): String {
        val body = buildJsonObject {
            put("model", modelId)
            put("messages", buildJsonArray {
                add(buildJsonObject {
                    put("role", "user")
                    put("content", prompt)
                })
            })
            put("temperature", 0.7)
            put("response_format", buildJsonObject {
                put("type", "json_object")
            })
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
        return responseJson["choices"]?.jsonArray
            ?.firstOrNull()?.jsonObject
            ?.get("message")?.jsonObject
            ?.get("content")?.jsonPrimitive?.content
            .orEmpty()
    }

    private suspend fun callClaudeRaw(apiKey: String, modelId: String, prompt: String): String {
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
        return responseJson["content"]?.jsonArray
            ?.firstOrNull()?.jsonObject
            ?.get("text")?.jsonPrimitive?.content
            .orEmpty()
    }

    private suspend fun callLocalRewrite(prompt: String, selection: String): String {
        val service = localModelService
            ?: throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        if (!service.isLoaded) {
            throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        }
        val response = service.generateResponse(prompt)
        val cleaned = cleanLocalRewrite(response)
        if (cleaned.isBlank()) {
            throw RuntimeException("Local model returned no rewrite. Try a different model or use a cloud provider.")
        }
        return cleaned
    }

    private fun cleanLocalRewrite(response: String): String {
        val trimmed = response
            .substringBefore("<end_of_turn>")
            .substringBefore("<start_of_turn>")
            .trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
        // If the model still emitted JSON, extract its rewrite field.
        extractRewriteField(trimmed)?.let { return it }
        return trimmed.removeSurrounding("\"").removeSurrounding("'").trim()
    }

    private fun extractRewriteField(text: String): String? {
        val cleaned = text.trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
        if (cleaned.isEmpty()) return null
        return try {
            val obj = json.parseToJsonElement(cleaned).jsonObject
            obj["rewrite"]?.jsonPrimitive?.content
        } catch (_: Exception) {
            null
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
        rhymeScheme: String,
        currentLetter: String,
        currentSection: SongSection = SongSection.UNKNOWN,
        complexity: RhymeComplexity,
        useWholeSongContext: Boolean
    ): String {
        val rhymeHint = if (targetRhymeLine != null) {
            "End every suggestion with a ${rhymeType.displayName.lowercase()} for: \"$targetRhymeLine\"."
        } else {
            "Start a new rhyme sound for letter \"$currentLetter\"."
        }
        val songContextInstruction = if (useWholeSongContext) {
            "Use the whole-song context for story arc, recurring images, hook language, speaker perspective, tone, and vocabulary."
        } else {
            "Use the immediate stanza, rhyme target, and theme first."
        }
        val effectiveTheme = if (theme.isNotBlank() && !useWholeSongContext) {
            theme.trim()
        } else {
            "Infer from the lyrics."
        }
        val lyricContext = localLyricsContext(lyrics, useWholeSongContext)
        val userPrompt = """
You are RhymeAI's on-device songwriting assistant.

Task: write exactly $SUGGESTION_COUNT next-line options for the song.
Theme: $effectiveTheme
Rhyme scheme: "$rhymeScheme"; next line is "$currentLetter".
Current song section: ${currentSection.displayName}.
${currentSection.promptHint}
$rhymeHint
$songContextInstruction
Complexity: ${complexity.label}. ${complexity.promptHint}

Lyrics context:
${"\"\"\""}
$lyricContext
${"\"\"\""}

Rules:
- Return exactly $SUGGESTION_COUNT lines.
- One suggestion per line.
- Do not copy any existing lyric line.
- Do not repeat the same suggestion.
- No numbering, bullets, quotes, markdown, labels, or explanation.
- Keep each suggestion under 16 words.
""".trimIndent()

        return gemmaInstructionPrompt(userPrompt)
    }

    private suspend fun callLocal(prompt: String, lyrics: String): List<String> {
        val service = localModelService
            ?: throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        if (!service.isLoaded) {
            throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        }
        val response = service.generateResponse(prompt)
        val rawResults = parseJsonArray(response).ifEmpty { parseLines(response) }
        val results = sanitizeLocalSuggestions(rawResults, lyrics)
        if (results.isEmpty()) {
            throw RuntimeException("Local model returned no usable suggestions. Try a different model or use a cloud provider.")
        }
        return results
    }

    private val listPrefixPattern = Regex("^\\s*(?:[-*]\\s+|\\d+[.)\\-:]\\s*)")
    private val markerOnlyPattern = Regex(
        pattern = "^\\s*(?:_?response>|_?model_response>|assistant_response>|model_response>|<[^>]+>|user|model|assistant)\\s*$",
        option = RegexOption.IGNORE_CASE
    )
    private val markerPrefixPattern = Regex(
        pattern = "^\\s*(?:_?response>|_?model_response>|assistant_response>|model_response>|assistant:|model:|user:|<start_of_turn>\\w+|<end_of_turn>)\\s*",
        option = RegexOption.IGNORE_CASE
    )
    private val promptEchoPattern = Regex(
        pattern = "^(?:task:|theme:|rhyme scheme:|lyrics context:|rules:|return exactly|one suggestion|no numbering|keep each|you are rhymeai)",
        option = RegexOption.IGNORE_CASE
    )
    private val normalizedLinePattern = Regex("[^a-z0-9]+")

    private fun parseLines(text: String): List<String> {
        return text.lines()
            .mapNotNull { cleanLocalSuggestionLine(it) }
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
        return try {
            json.decodeFromString<List<String>>(cleaned).take(SUGGESTION_COUNT)
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun gemmaInstructionPrompt(userPrompt: String): String =
        """
<start_of_turn>user
$userPrompt
<end_of_turn>
<start_of_turn>model
""".trimIndent()

    private fun localLyricsContext(lyrics: String, useWholeSongContext: Boolean): String {
        val trimmed = lyrics.trim()
        if (trimmed.length <= LOCAL_RECENT_CONTEXT_CHARS) return trimmed

        return if (useWholeSongContext) {
            val head = trimmed.take(LOCAL_WHOLE_SONG_HEAD_CHARS).trimToLineBoundary(preferStart = false)
            val tail = trimmed.takeLast(LOCAL_WHOLE_SONG_TAIL_CHARS).trimToLineBoundary(preferStart = true)
            "$head\n\n[Middle lyrics trimmed for on-device speed]\n\n$tail"
        } else {
            "[Earlier lyrics trimmed for on-device speed]\n" +
                trimmed.takeLast(LOCAL_RECENT_CONTEXT_CHARS).trimToLineBoundary(preferStart = true)
        }
    }

    private fun sanitizeLocalSuggestions(candidates: List<String>, lyrics: String): List<String> {
        val existingLines = lyrics.lines()
            .map { normalizeSuggestionKey(it) }
            .filter { it.isNotEmpty() }
            .toSet()
        val seen = mutableSetOf<String>()

        return candidates
            .flatMap { it.lines() }
            .mapNotNull { cleanLocalSuggestionLine(it) }
            .filter { suggestion ->
                val key = normalizeSuggestionKey(suggestion)
                key.isNotEmpty() &&
                    key !in existingLines &&
                    seen.add(key)
            }
            .take(SUGGESTION_COUNT)
    }

    private fun cleanLocalSuggestionLine(line: String): String? {
        var cleaned = line.trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()

        if (cleaned.isBlank() || markerOnlyPattern.matches(cleaned)) return null

        cleaned = cleaned
            .substringBefore("<end_of_turn>")
            .substringBefore("<start_of_turn>")
            .let { markerPrefixPattern.replace(it, "") }
            .let { listPrefixPattern.replace(it, "") }
            .trim()
            .removeSurrounding("\"")
            .removeSurrounding("'")
            .trim()

        if (cleaned.isBlank()) return null
        if (markerOnlyPattern.matches(cleaned)) return null
        if (promptEchoPattern.containsMatchIn(cleaned)) return null
        if (cleaned.contains("response>", ignoreCase = true)) return null
        if (cleaned.length > 140) return null

        return cleaned
    }

    private fun normalizeSuggestionKey(text: String): String =
        normalizedLinePattern.replace(text.lowercase().trim(), "")

    private fun String.trimToLineBoundary(preferStart: Boolean): String {
        if (isEmpty()) return this
        return if (preferStart) {
            val newline = indexOf('\n')
            if (newline >= 0 && newline < lastIndex) substring(newline + 1).trim() else trim()
        } else {
            val newline = lastIndexOf('\n')
            if (newline > 0) substring(0, newline).trim() else trim()
        }
    }
}
