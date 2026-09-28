package com.rhymeai.app.service

import com.google.ai.client.generativeai.GenerativeModel
import com.google.ai.client.generativeai.type.generationConfig
import com.rhymeai.app.SuggestedLine
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.util.PronunciationDictionary
import com.rhymeai.app.util.ProsodyAnalyzer
import com.rhymeai.app.util.RhymeConstraint
import com.rhymeai.app.util.SectionMap
import com.rhymeai.app.util.SectionRef
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.IOException
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException

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
    GEMINI_35_FLASH("gemini-3.5-flash", "Gemini 3.5 Flash", AIProvider.GEMINI),
    GEMINI_31_PRO("gemini-3.1-pro-preview", "Gemini 3.1 Pro", AIProvider.GEMINI),
    GEMINI_3_FLASH("gemini-3-flash-preview", "Gemini 3 Flash", AIProvider.GEMINI),
    GEMINI_31_FLASH_LITE("gemini-3.1-flash-lite-preview", "Gemini 3.1 Flash Lite", AIProvider.GEMINI),
    GEMINI_25_PRO("gemini-2.5-pro", "Gemini 2.5 Pro", AIProvider.GEMINI),
    GEMINI_25_FLASH("gemini-2.5-flash", "Gemini 2.5 Flash", AIProvider.GEMINI),
    GEMINI_25_FLASH_LITE("gemini-2.5-flash-lite", "Gemini 2.5 Flash Lite", AIProvider.GEMINI),

    // OpenAI
    GPT_55("gpt-5.5", "GPT-5.5", AIProvider.OPENAI),
    GPT_55_PRO("gpt-5.5-pro", "GPT-5.5 Pro", AIProvider.OPENAI),
    GPT_54("gpt-5.4", "GPT-5.4", AIProvider.OPENAI),
    GPT_54_MINI("gpt-5.4-mini", "GPT-5.4 Mini", AIProvider.OPENAI),
    GPT_54_NANO("gpt-5.4-nano", "GPT-5.4 Nano", AIProvider.OPENAI),
    GPT_41("gpt-4.1", "GPT-4.1", AIProvider.OPENAI),
    GPT_41_MINI("gpt-4.1-mini", "GPT-4.1 Mini", AIProvider.OPENAI),
    GPT_41_NANO("gpt-4.1-nano", "GPT-4.1 Nano", AIProvider.OPENAI),
    GPT_4O("gpt-4o", "GPT-4o", AIProvider.OPENAI),
    GPT_4O_MINI("gpt-4o-mini", "GPT-4o Mini", AIProvider.OPENAI),

    // Claude
    CLAUDE_OPUS_47("claude-opus-4-7", "Claude Opus 4.7", AIProvider.CLAUDE),
    CLAUDE_SONNET_46("claude-sonnet-4-6", "Claude Sonnet 4.6", AIProvider.CLAUDE),
    CLAUDE_OPUS("claude-opus-4-20250514", "Claude Opus 4", AIProvider.CLAUDE),
    CLAUDE_SONNET("claude-sonnet-4-20250514", "Claude Sonnet 4", AIProvider.CLAUDE),
    CLAUDE_HAIKU("claude-haiku-4-5-20251001", "Claude Haiku 4.5", AIProvider.CLAUDE),

    // Local on-device
    LOCAL_MODEL("local-model", "On-Device Model", AIProvider.LOCAL);

    companion object {
        val DEFAULT = GEMINI_35_FLASH
        fun fromId(id: String): AIModel =
            entries.find { it.id == id } ?: DEFAULT
        fun modelsForProvider(provider: AIProvider): List<AIModel> =
            entries.filter { it.provider == provider }
    }
}

class AIService {
    internal data class SingleWordRewriteContext(
        val line: String,
        val previousWord: String?,
        val nextWord: String?,
        val isLineEnding: Boolean
    )

    // Computed once per suggestion request and shared by the prompt builders
    // (constrain end words, over-generate) and the output filters (verify/rank).
    internal data class SuggestionRhymeConstraint(
        val targetLine: String,
        val targetWord: String,
        val candidateWords: List<String>,
        val rhymeType: RhymeType,
        val dictionary: PronunciationDictionary,
        /** The resolved section ref for the current cursor position, if any. */
        val sectionRef: SectionRef? = null,
        /** End-words of lines in the first chorus instance, used for chorus-repeat
         *  candidate promotion and verse/bridge exclusion. Empty when no chorus exists. */
        val chorusEndWords: Set<String> = emptySet()
    )

    private companion object {
        const val SUGGESTION_COUNT = 6
        const val LOCAL_RECENT_CONTEXT_CHARS = 2600
        const val LOCAL_WHOLE_SONG_HEAD_CHARS = 900
        const val LOCAL_WHOLE_SONG_TAIL_CHARS = 2200
        const val LOCAL_REWRITE_ATTEMPTS = 2
        val fallbackRephraseWords = mapOf(
            "believe" to listOf("imagine", "trust", "dream"),
            "birds" to listOf("sparrows", "voices", "wings"),
            "calls" to listOf("rings", "echoes", "signals"),
            "enemies" to listOf("rivals", "foes", "strangers"),
            "feel" to listOf("sense", "know", "ache"),
            "free" to listOf("loose", "clear", "unbound"),
            "glow" to listOf("gleam", "shine", "spark"),
            "lies" to listOf("myths", "spin", "masks"),
            "real" to listOf("true", "clear", "solid"),
            "street" to listOf("block", "road", "lane"),
            "tvs" to listOf("screens", "feeds", "channels"),
            "walls" to listOf("barriers", "rooms", "blocks")
        )
        val fallbackHarderRhymeWords = mapOf(
            "believe" to listOf("deceive", "relieve", "receive"),
            "birds" to listOf("words", "herds", "thirds"),
            "calls" to listOf("walls", "falls", "halls"),
            "enemies" to listOf("remedies", "memories", "melodies"),
            "feel" to listOf("real", "steel", "wheel"),
            "free" to listOf("see", "be", "flee"),
            "glow" to listOf("show", "flow", "low"),
            "lies" to listOf("eyes", "skies", "disguise"),
            "real" to listOf("feel", "steel", "wheel"),
            "street" to listOf("beat", "heat", "feet"),
            "tvs" to listOf("feeds", "screens", "dreams"),
            "walls" to listOf("calls", "falls", "halls")
        )
        val fallbackPunchUpWords = mapOf(
            "believe" to listOf("swallow", "worship", "chase"),
            "birds" to listOf("sirens", "static", "wires"),
            "calls" to listOf("alarms", "signals", "sirens"),
            "enemies" to listOf("traitors", "targets", "rivals"),
            "feel" to listOf("burn", "bleed", "know"),
            "free" to listOf("wild", "untamed", "unbound"),
            "glow" to listOf("flare", "blaze", "spark"),
            "lies" to listOf("poison", "fraud", "venom"),
            "real" to listOf("raw", "true", "solid"),
            "street" to listOf("asphalt", "gutter", "curb"),
            "tvs" to listOf("screens", "static", "feeds"),
            "walls" to listOf("concrete", "barricades", "barriers")
        )

        fun userFacingStatusMessage(code: Int): String = when (code) {
            401, 403 -> "Provider rejected the request — check your API key in Settings."
            404 -> "Provider could not find the requested model — pick another in Settings."
            429 -> "Provider rate limit reached — wait a moment and retry."
            in 500..599 -> "Provider service error — try again shortly."
            else -> "Provider request failed (status $code)."
        }

        fun userFacingProviderException(error: Throwable): RuntimeException {
            if (error is CancellationException) throw error
            val causes = error.causes()
            val rawMessage = causes.joinToString(" ") { cause ->
                "${cause::class.java.simpleName} ${cause.message.orEmpty()}"
            }
            val blocked = listOf("blocked", "safety", "finishReason", "prohibited")
                .any { rawMessage.contains(it, ignoreCase = true) }
            if (blocked) {
                return RuntimeException("Provider blocked the response for safety. Try adjusting the lyric or prompt.")
            }
            val networkFailure = causes.any { it is IOException || it is SocketTimeoutException || it is UnknownHostException } ||
                listOf("timeout", "timed out", "Unable to resolve host", "UnknownHostException", "SocketTimeoutException")
                    .any { rawMessage.contains(it, ignoreCase = true) }
            if (networkFailure) {
                return RuntimeException("Provider request failed — check your connection and try again.")
            }
            val status = Regex("\\b(?:401|403|404|429|5\\d\\d)\\b")
                .find(rawMessage)
                ?.value
                ?.toIntOrNull()
            val message = status?.let(::userFacingStatusMessage)
                ?: "Provider request failed — check your connection, API key, and selected model."
            return RuntimeException(message)
        }

        private fun Throwable.causes(): List<Throwable> {
            val chain = mutableListOf<Throwable>()
            var current: Throwable? = this
            while (current != null && current !in chain) {
                chain += current
                current = current.cause
            }
            return chain
        }
    }

    private val json = Json { ignoreUnknownKeys = true }

    internal fun userFacingStatusMessageForStatus(code: Int): String =
        userFacingStatusMessage(code)

    internal fun userFacingProviderMessageForError(error: Throwable): String =
        userFacingProviderException(error).message.orEmpty()

    // LLMs rhyme unreliably because tokens hide phonetics. When the dictionary
    // knows the target end word, we pin suggestions to verified rhyme words and
    // ask for double the lines so the phonetic filter has material to rank.
    internal fun suggestionRhymeConstraint(
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared,
        sectionRef: SectionRef? = null,
        chorusEndWords: Set<String> = emptySet()
    ): SuggestionRhymeConstraint? {
        if (targetRhymeLine.isNullOrBlank()) return null
        val targetWord = RhymeConstraint.lineEndWord(targetRhymeLine)
        if (targetWord.isEmpty()) return null
        var candidates = RhymeConstraint.candidateEndWords(targetWord, rhymeType, dictionary = dictionary)
        if (candidates.isEmpty()) return null

        val type = sectionRef?.type ?: SongSection.UNKNOWN
        val ordinal = sectionRef?.ordinal ?: 1

        // Chorus repeat (2nd+): promote first-chorus end-words to the front of candidates.
        if (type == SongSection.CHORUS && ordinal >= 2 && chorusEndWords.isNotEmpty()) {
            val promoted = chorusEndWords.filter { it != targetWord && it in candidates }
            val rest = candidates.filter { it !in promoted }
            candidates = promoted + rest
        }

        // Verse and bridge: exclude the chorus's end-words unless that would empty the list.
        if ((type == SongSection.VERSE || type == SongSection.BRIDGE) && chorusEndWords.isNotEmpty()) {
            val filtered = candidates.filter { it !in chorusEndWords }
            if (filtered.isNotEmpty()) candidates = filtered
        }

        return SuggestionRhymeConstraint(
            targetRhymeLine, targetWord, candidates, rhymeType, dictionary, sectionRef, chorusEndWords
        )
    }

    /** Collects the normalised end-words of all lyric lines within the *first*
     *  CHORUS section in [lyrics]. Returns an empty set when no chorus exists. */
    internal fun firstChorusEndWords(
        lyrics: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): Set<String> {
        val map = SectionMap.parse(lyrics)
        val firstChorus = map.allSections.firstOrNull { it.type == SongSection.CHORUS }
            ?: return emptySet()
        val lines = lyrics.split('\n')
        return firstChorus.lineRange
            .mapNotNull { idx -> lines.getOrNull(idx) }
            .map { RhymeConstraint.lineEndWord(it) }
            .filter { it.isNotEmpty() }
            .toSet()
    }

    private fun constraintInstruction(constraint: SuggestionRhymeConstraint): String =
        "The new line must rhyme with: \"${constraint.targetLine}\" (it ends with \"${constraint.targetWord}\").\n" +
            "End each line with one of these rhyming words: ${constraint.candidateWords.joinToString(", ")} (choose the most natural fit)."

    /**
     * Returns an additional directive sentence (with trailing newline) based on the
     * section ref, or an empty string when no special directive applies.
     *
     * These exact sentences are part of the iOS/Android prompt parity contract —
     * do NOT change them without updating the iOS AIService mirror.
     */
    private fun buildSectionDirective(ref: SectionRef?, lyrics: String): String {
        if (ref == null) return ""
        return when (ref.type) {
            SongSection.VERSE -> "This is Verse ${ref.ordinal}.\n"
            SongSection.BRIDGE -> "This is the bridge — introduce a contrasting rhyme sound and cadence; avoid the chorus's ending words.\n"
            SongSection.CHORUS -> {
                if (ref.ordinal < 2) return ""
                // Collect the first chorus's lines to anchor hook language.
                val firstChorusLines = firstChorusLines(lyrics)
                val chorusBlock = if (firstChorusLines.isNotEmpty()) {
                    "\n" + firstChorusLines.joinToString("\n")
                } else {
                    ""
                }
                "This is the chorus (instance ${ref.ordinal}). Keep hook language and ending words consistent with the established chorus:$chorusBlock\n"
            }
            SongSection.UNKNOWN -> ""
        }
    }

    /** Lines of lyrics content (non-header, non-blank) within the first chorus section. */
    private fun firstChorusLines(lyrics: String): List<String> {
        val map = SectionMap.parse(lyrics)
        val firstChorus = map.allSections.firstOrNull { it.type == SongSection.CHORUS }
            ?: return emptyList()
        val lines = lyrics.split('\n')
        val headerPattern = Regex("""^\s*\[.+]\s*$""")
        return firstChorus.lineRange
            .mapNotNull { idx -> lines.getOrNull(idx) }
            .filter { it.isNotBlank() && !headerPattern.matches(it) }
    }

    internal fun buildPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        currentSection: SongSection = SongSection.UNKNOWN,
        complexity: RhymeComplexity,
        useWholeSongContext: Boolean,
        constraint: SuggestionRhymeConstraint? = null
    ): String {
        val rhymeInstruction = if (targetRhymeLine != null) {
            "Crucially, the new line MUST end with a **${rhymeType.displayName}** to this specific line: \"$targetRhymeLine\"."
        } else {
            "Since this is a new rhyme sound (\"$currentLetter\"), the new line should introduce a new end-rhyme that fits the meter and theme."
        }
        val constraintBlock = constraint?.let { "\n" + constraintInstruction(it) }.orEmpty()
        val requestCount = if (constraint != null) SUGGESTION_COUNT * 2 else SUGGESTION_COUNT
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

        val sectionDirective = buildSectionDirective(constraint?.sectionRef, lyrics)

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
$sectionDirective$rhymeInstruction$constraintBlock
$songContextInstruction

Complexity level: ${complexity.label}. ${complexity.promptHint}

Provide $requestCount creative, poetic, and contextually relevant suggestions for the next line.
Make sure the rhythm and meter match the style of the current lyrics${if (targetRhymeLine != null) ", and strictly adhere to the requested rhyme type (${rhymeType.displayName})" else ""}.

Respond with exactly $requestCount lines, one suggestion per line. No numbering, no bullets, no quotes, no markdown, no code fences, and no commentary — just the bare suggestion lines.
""".trimIndent()
    }

    var localModelService: LocalModelService? = null
        internal set

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
        useWholeSongContext: Boolean = false,
        sectionRef: SectionRef? = null,
        fullLyrics: String = lyrics
    ): List<SuggestedLine> {
        if (provider != AIProvider.LOCAL && apiKey.isBlank()) {
            throw IllegalStateException("No API key set. Go to Settings to add your ${provider.displayName} API key.")
        }

        val chorusEnds = firstChorusEndWords(fullLyrics)
        val constraint = suggestionRhymeConstraint(
            targetRhymeLine, rhymeType, sectionRef = sectionRef, chorusEndWords = chorusEnds
        )
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
                useWholeSongContext = useWholeSongContext,
                constraint = constraint
            )
            callLocal(localPrompt, lyrics, constraint)
        } else {
            val prompt = buildPrompt(theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter, currentSection, complexity, useWholeSongContext, constraint)
            when (provider) {
                AIProvider.GEMINI -> callGemini(apiKey, modelId, prompt, constraint)
                AIProvider.OPENAI -> callOpenAI(apiKey, modelId, prompt, constraint)
                AIProvider.CLAUDE -> callClaude(apiKey, modelId, prompt, constraint)
                AIProvider.LOCAL -> error("unreachable")
            }
        }
    }

    fun streamSuggestions(
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
        useWholeSongContext: Boolean = false,
        sectionRef: SectionRef? = null,
        fullLyrics: String = lyrics
    ): Flow<SuggestedLine> = flow {
        if (provider != AIProvider.LOCAL && apiKey.isBlank()) {
            throw IllegalStateException("No API key set. Go to Settings to add your ${provider.displayName} API key.")
        }

        val chorusEnds = firstChorusEndWords(fullLyrics)
        val constraint = suggestionRhymeConstraint(
            targetRhymeLine, rhymeType, sectionRef = sectionRef, chorusEndWords = chorusEnds
        )
        if (provider == AIProvider.LOCAL) {
            // Local model already streams tokens internally; needs its own Flow surface (follow-up).
            getSuggestions(provider, apiKey, modelId, theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter, currentSection, complexity, useWholeSongContext, sectionRef, fullLyrics)
                .forEach { emit(it) }
        } else {
            val prompt = buildPrompt(theme, lyrics, targetRhymeLine, rhymeType, rhymeScheme, currentLetter, currentSection, complexity, useWholeSongContext, constraint)
            when (provider) {
                AIProvider.GEMINI -> streamGemini(apiKey, modelId, prompt, constraint).collect { emit(it) }
                AIProvider.OPENAI -> streamOpenAI(apiKey, modelId, prompt, constraint).collect { emit(it) }
                AIProvider.CLAUDE -> streamClaude(apiKey, modelId, prompt, constraint).collect { emit(it) }
                AIProvider.LOCAL -> error("unreachable")
            }
        }
    }.flowOn(Dispatchers.IO)

    private fun streamGemini(apiKey: String, modelId: String, prompt: String, constraint: SuggestionRhymeConstraint? = null): Flow<SuggestedLine> = flow {
        try {
            val model = GenerativeModel(modelName = modelId, apiKey = apiKey)
            val tokens = model.generateContentStream(prompt).mapNotNull { it.text }
            emitLinesFromTokens(tokens, constraint)
        } catch (error: Throwable) {
            throw userFacingProviderException(error)
        }
    }

    private fun streamOpenAI(apiKey: String, modelId: String, prompt: String, constraint: SuggestionRhymeConstraint? = null): Flow<SuggestedLine> = flow {
        val payloads = httpPostStream(
            url = "https://api.openai.com/v1/chat/completions",
            headers = mapOf(
                "Authorization" to "Bearer $apiKey",
                "Content-Type" to "application/json",
                "Accept" to "text/event-stream"
            ),
            body = buildOpenAIChatRequestBody(
                modelId = modelId,
                prompt = prompt,
                temperature = 0.8,
                stream = true
            ).toString()
        )
        val tokens = payloads.mapNotNull(::parseOpenAIStreamToken)
        emitLinesFromTokens(tokens, constraint)
    }

    private fun streamClaude(apiKey: String, modelId: String, prompt: String, constraint: SuggestionRhymeConstraint? = null): Flow<SuggestedLine> = flow {
        val payloads = httpPostStream(
            url = "https://api.anthropic.com/v1/messages",
            headers = mapOf(
                "x-api-key" to apiKey,
                "anthropic-version" to "2023-06-01",
                "Content-Type" to "application/json",
                "Accept" to "text/event-stream"
            ),
            body = buildClaudeMessagesRequestBody(
                modelId = modelId,
                prompt = prompt,
                stream = true
            ).toString()
        )
        val tokens = payloads.mapNotNull(::parseClaudeStreamToken)
        emitLinesFromTokens(tokens, constraint)
    }

    private fun buildOpenAIChatRequestBody(
        modelId: String,
        prompt: String,
        temperature: Double,
        stream: Boolean = false,
        jsonResponse: Boolean = false
    ) = buildJsonObject {
        put("model", modelId)
        put("messages", buildJsonArray {
            add(buildJsonObject {
                put("role", "user")
                put("content", prompt)
            })
        })
        put("temperature", temperature)
        if (jsonResponse) {
            put("response_format", buildJsonObject {
                put("type", "json_object")
            })
        }
        if (stream) {
            put("stream", true)
        }
    }

    private fun parseOpenAIMessageContent(responseText: String): String? {
        val responseJson = json.parseToJsonElement(responseText).jsonObject
        return responseJson["choices"]?.jsonArray
            ?.firstOrNull()?.jsonObject
            ?.get("message")?.jsonObject
            ?.get("content")?.jsonPrimitive?.content
    }

    private fun parseOpenAIStreamToken(payload: String): String? =
        runCatching {
            json.parseToJsonElement(payload).jsonObject["choices"]
                ?.jsonArray?.firstOrNull()?.jsonObject
                ?.get("delta")?.jsonObject
                ?.get("content")?.jsonPrimitive?.content
        }.getOrNull()

    private fun buildClaudeMessagesRequestBody(
        modelId: String,
        prompt: String,
        stream: Boolean = false
    ) = buildJsonObject {
        put("model", modelId)
        put("max_tokens", 1024)
        if (stream) {
            put("stream", true)
        }
        put("messages", buildJsonArray {
            add(buildJsonObject {
                put("role", "user")
                put("content", prompt)
            })
        })
    }

    private fun parseClaudeMessageText(responseText: String): String? {
        val responseJson = json.parseToJsonElement(responseText).jsonObject
        return responseJson["content"]?.jsonArray
            ?.firstOrNull()?.jsonObject
            ?.get("text")?.jsonPrimitive?.content
    }

    private fun parseClaudeStreamToken(payload: String): String? =
        runCatching {
            val obj = json.parseToJsonElement(payload).jsonObject
            if (obj["type"]?.jsonPrimitive?.content != "content_block_delta") return@runCatching null
            obj["delta"]?.jsonObject?.get("text")?.jsonPrimitive?.content
        }.getOrNull()

    private fun geminiModel(
        apiKey: String,
        modelId: String,
        mimeType: String? = null
    ): GenerativeModel =
        mimeType?.let { responseType ->
            GenerativeModel(
                modelName = modelId,
                apiKey = apiKey,
                generationConfig = generationConfig {
                    responseMimeType = responseType
                }
            )
        } ?: GenerativeModel(modelName = modelId, apiKey = apiKey)

    private suspend fun generateGeminiText(
        apiKey: String,
        modelId: String,
        prompt: String,
        responseMimeType: String? = null
    ): String? =
        geminiModel(apiKey, modelId, responseMimeType)
            .generateContent(prompt)
            .text
            ?.trim()

    internal suspend fun FlowCollector<SuggestedLine>.emitLinesFromTokens(
        tokens: Flow<String>,
        constraint: SuggestionRhymeConstraint? = null
    ) {
        val buffer = StringBuilder()
        val seen = mutableSetOf<String>()
        val held = mutableListOf<String>()
        // Constrained requests over-generate 2x, surface verified rhymes as they
        // stream, and keep the rest as ranked backfill for the end of the stream.
        val matches = constraint?.let {
            ProsodyAnalyzer.findRhymes(it.targetWord, dictionary = it.dictionary)
        }
        val isChorusRepeat = constraint?.let {
            it.sectionRef?.type == SongSection.CHORUS && (it.sectionRef.ordinal) >= 2
        } ?: false
        val chorusEnds = constraint?.chorusEndWords ?: emptySet()
        val acceptLimit = if (constraint != null) SUGGESTION_COUNT * 2 else SUGGESTION_COUNT
        var accepted = 0
        var emitted = 0

        suspend fun flushLine(rawLine: String): Boolean {
            if (accepted >= acceptLimit || emitted >= SUGGESTION_COUNT) return false
            val cleaned = cleanLocalSuggestionLine(rawLine) ?: return false
            val key = normalizeSuggestionKey(cleaned)
            if (key.isEmpty() || !seen.add(key)) return false
            accepted++

            // Determine phonetic tier; treat chorus-repeat end-words as tier 2
            // so they stream immediately rather than being held.
            val endWord = RhymeConstraint.lineEndWord(cleaned)
            val isHook = isChorusRepeat && endWord.isNotEmpty() && endWord in chorusEnds
            val tier = when {
                isHook -> 2
                matches != null && constraint != null -> RhymeConstraint.rhymeTier(
                    cleaned, constraint.targetWord, matches, constraint.dictionary
                )
                else -> 0
            }

            if (matches != null && tier == 0 && !isHook) {
                held += cleaned
                return true
            }
            emit(SuggestedLine(cleaned, tier, isHook))
            emitted++
            return true
        }

        tokens.collect { chunk ->
            buffer.append(chunk)
            while (accepted < acceptLimit && emitted < SUGGESTION_COUNT) {
                val newlineIdx = buffer.indexOf('\n')
                if (newlineIdx < 0) break
                val rawLine = buffer.substring(0, newlineIdx)
                buffer.delete(0, newlineIdx + 1)
                flushLine(rawLine)
            }
        }
        if (buffer.isNotBlank()) {
            flushLine(buffer.toString())
        }
        if (constraint != null && emitted < SUGGESTION_COUNT && held.isNotEmpty()) {
            RhymeConstraint.filterAndRank(
                lines = held,
                targetLine = constraint.targetLine,
                rhymeType = constraint.rhymeType,
                want = SUGGESTION_COUNT - emitted,
                dictionary = constraint.dictionary
            ).forEach { line ->
                val endWord = RhymeConstraint.lineEndWord(line)
                val isHook = isChorusRepeat && endWord.isNotEmpty() && endWord in chorusEnds
                val tier = RhymeConstraint.rhymeTier(
                    line, constraint.targetWord, requireNotNull(matches), constraint.dictionary
                )
                emit(SuggestedLine(line, tier, isHook))
            }
        }
    }

    private fun httpPostStream(
        url: String,
        headers: Map<String, String>,
        body: String
    ): Flow<String> = flow {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = 30000
            connection.readTimeout = 60000
            headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }

            OutputStreamWriter(connection.outputStream, "UTF-8").use { it.write(body) }

            val code = connection.responseCode
            if (code !in 200..299) {
                // Drain the error stream so the connection can clean up, but do not
                // surface the body — provider error payloads can echo back the
                // request URL or the API key into user-visible text. A drain failure
                // must not mask the mapped status message either.
                runCatching { connection.errorStream?.bufferedReader()?.use { it.readText() } }
                throw RuntimeException(userFacingStatusMessage(code))
            }

            connection.inputStream.bufferedReader().use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty() || line.startsWith(":")) continue
                    if (!line.startsWith("data:")) continue
                    val payload = line.substring(5).trim()
                    if (payload == "[DONE]") break
                    if (payload.isEmpty()) continue
                    emit(payload)
                }
            }
        } finally {
            connection.disconnect()
        }
    }.flowOn(Dispatchers.IO)

    suspend fun getSynonyms(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        word: String,
        lineContext: String,
        limit: Int = 8
    ): List<String> {
        val target = word.trim()
        if (target.isBlank()) return emptyList()
        if (provider != AIProvider.LOCAL && apiKey.isBlank()) {
            throw IllegalStateException("No API key set. Go to Settings to add your ${provider.displayName} API key.")
        }

        val raw = if (provider == AIProvider.LOCAL) {
            val service = localModelService
                ?: throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
            if (!service.isLoaded) {
                throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
            }
            service.generateResponse(buildLocalSynonymsPrompt(target, lineContext, limit))
        } else {
            val prompt = buildSynonymsPrompt(target, lineContext, limit)
            callCloudRaw(provider, apiKey, modelId, prompt)
        }
        return extractSynonyms(raw, exclude = target).take(limit)
    }

    private fun buildSynonymsPrompt(word: String, lineContext: String, limit: Int): String {
        val contextLine = lineContext.trim().take(240)
        val contextBlock = if (contextLine.isEmpty()) {
            "(no surrounding line)"
        } else {
            contextLine
        }
        return """
You are RhymeAI's word inspector. Given a target word and the lyric line it appears in, return synonyms that could replace the target while preserving meaning, register, and roughly the same syllable count.

Target word: "$word"
Lyric line: "$contextBlock"

Rules:
- Provide up to $limit synonyms.
- No multi-word phrases unless they would naturally read as a single concept.
- No duplicates. No the target word itself.
- Match the tone of the line (slang stays slang, formal stays formal).

Respond ONLY with a JSON object of the form {"synonyms": ["..."]}. No code fences, no commentary.
""".trimIndent()
    }

    internal fun buildLocalSynonymsPrompt(word: String, lineContext: String, limit: Int): String {
        val contextLine = lineContext.trim().take(180)
        val contextBlock = if (contextLine.isEmpty()) {
            "(no surrounding line)"
        } else {
            contextLine
        }
        val userPrompt = """
You are RhymeAI's on-device word helper.

Task: give up to $limit single-word replacements for "$word" in this lyric line:
"$contextBlock"

Rules:
- Return only replacement words, one per line.
- No JSON, bullets, numbering, labels, quotes, or commentary.
- Do not include "$word".
- Prefer words with similar tone and syllable count.
""".trimIndent()
        return gemmaInstructionPrompt(userPrompt)
    }

    internal fun extractSynonyms(raw: String, exclude: String): List<String> {
        val cleaned = raw.trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
        if (cleaned.isEmpty()) return emptyList()
        val excludeKey = exclude.lowercase()
        val tryObject = runCatching {
            val obj = json.parseToJsonElement(cleaned).jsonObject
            obj["synonyms"]?.jsonArray?.mapNotNull { it.jsonPrimitive.content.trim().takeIf(String::isNotEmpty) }
        }.getOrNull()
        val tryArray = if (tryObject == null) runCatching {
            json.decodeFromString<List<String>>(cleaned)
        }.getOrNull() else null
        val candidates = tryObject ?: tryArray ?: cleaned
            .lines()
            .flatMap { it.split(",") }
            .map { line -> line.trim().trim('"', '\'', ',', '-', '*', '•', ' ') }
            .filter { it.isNotEmpty() }

        val seen = mutableSetOf<String>()
        return candidates.mapNotNull { raw ->
            val word = raw.trim().trim('"', '\'').trim()
            if (word.isEmpty() || word.length > 32) return@mapNotNull null
            val key = word.lowercase()
            if (key == excludeKey || !seen.add(key)) null else word
        }
    }

    suspend fun getRewrite(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        action: RewriteAction,
        fullLyrics: String,
        selection: String,
        currentSection: SongSection = SongSection.UNKNOWN,
        selectionStart: Int? = null,
        rejectedCandidates: Set<String> = emptySet()
    ): String {
        if (provider != AIProvider.LOCAL && apiKey.isBlank()) {
            throw IllegalStateException("No API key set. Go to Settings to add your ${provider.displayName} API key.")
        }
        if (selection.isBlank()) {
            throw IllegalStateException("Nothing selected to rewrite.")
        }

        return if (provider == AIProvider.LOCAL) {
            callLocalRewrite(
                action = action,
                lyrics = fullLyrics,
                selection = selection,
                currentSection = currentSection,
                selectionStart = selectionStart,
                rejectedCandidates = rejectedCandidates
            )
        } else {
            val prompt = buildRewritePrompt(action, fullLyrics, selection, currentSection)
            val raw = callCloudRaw(provider, apiKey, modelId, prompt)
            extractRewriteField(raw)?.takeIf { it.isNotBlank() }
                ?: throw RuntimeException("AI did not return a rewrite. Try again.")
        }
    }

    internal fun buildRewritePrompt(
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

    internal fun buildLocalRewritePrompt(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection = SongSection.UNKNOWN,
        selectionStart: Int? = null,
        rejectedCandidates: Set<String> = emptySet()
    ): String {
        val lyricContext = localLyricsContext(lyrics, useWholeSongContext = false)
        val singleWord = isSingleWordSelection(selection)
        val selectedLine = selectionStart
            ?.let { lyricLineAt(lyrics, it) }
            ?.takeIf { it.isNotBlank() }
        val taskLine = if (singleWord) {
            "Task: replace the selected word with a different word that fits the song."
        } else {
            "Task: rewrite the selected passage from the user's song."
        }
        val rejectedKeys = rewriteRejectKeys(selection, rejectedCandidates)
        val rejectedRule = if (singleWord && rejectedKeys.isNotEmpty()) {
            "- Do not return any of these rejected words: ${rejectedKeys.joinToString(", ")}."
        } else {
            ""
        }
        val outputRules = if (singleWord) {
            """
- Return exactly one replacement word.
- The replacement must be different from the selected word.
- Do not return "$selection".
$rejectedRule
- No quotes, no markdown, no labels, no commentary.
""".trimIndent()
        } else {
            """
- Output the rewritten passage only.
- Preserve line breaks if the selection has multiple lines.
- No quotes, no markdown, no labels, no commentary.
""".trimIndent()
        }
        val userPrompt = """
You are RhymeAI's on-device songwriting assistant.

$taskLine
Current song section: ${currentSection.displayName}.
${currentSection.promptHint}
Action: ${action.label}.
Instruction: ${action.instruction}

Lyrics context:
${"\"\"\""}
$lyricContext
${"\"\"\""}

${selectedLine?.let { "Line containing the selected word:\n\"\"\"\n$it\n\"\"\"\n" }.orEmpty()}
Selected passage to rewrite:
${"\"\"\""}
$selection
${"\"\"\""}

Rules:
$outputRules
""".trimIndent()
        return gemmaInstructionPrompt(userPrompt)
    }

    private fun isSingleWordSelection(selection: String): Boolean =
        selection.trim().matches(Regex("[\\p{L}\\p{N}'-]+"))

    private suspend fun callGeminiRaw(apiKey: String, modelId: String, prompt: String): String {
        return try {
            generateGeminiText(
                apiKey = apiKey,
                modelId = modelId,
                prompt = prompt,
                responseMimeType = "application/json"
            ).orEmpty()
        } catch (error: Throwable) {
            throw userFacingProviderException(error)
        }
    }

    private suspend fun callOpenAIRaw(apiKey: String, modelId: String, prompt: String): String {
        val responseText = httpPost(
            url = "https://api.openai.com/v1/chat/completions",
            headers = mapOf(
                "Authorization" to "Bearer $apiKey",
                "Content-Type" to "application/json"
            ),
            body = buildOpenAIChatRequestBody(
                modelId = modelId,
                prompt = prompt,
                temperature = 0.7,
                jsonResponse = true
            ).toString()
        )
        return parseOpenAIMessageContent(responseText).orEmpty()
    }

    private suspend fun callClaudeRaw(apiKey: String, modelId: String, prompt: String): String {
        val responseText = httpPost(
            url = "https://api.anthropic.com/v1/messages",
            headers = mapOf(
                "x-api-key" to apiKey,
                "anthropic-version" to "2023-06-01",
                "Content-Type" to "application/json"
            ),
            body = buildClaudeMessagesRequestBody(modelId, prompt).toString()
        )
        return parseClaudeMessageText(responseText).orEmpty()
    }

    private suspend fun callCloudRaw(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        prompt: String
    ): String =
        when (provider) {
            AIProvider.GEMINI -> callGeminiRaw(apiKey, modelId, prompt)
            AIProvider.OPENAI -> callOpenAIRaw(apiKey, modelId, prompt)
            AIProvider.CLAUDE -> callClaudeRaw(apiKey, modelId, prompt)
            AIProvider.LOCAL -> error("unreachable")
        }

    private suspend fun callLocalRewrite(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection,
        selectionStart: Int?,
        rejectedCandidates: Set<String>
    ): String {
        val service = localModelService
            ?: throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        if (!service.isLoaded) {
            throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        }

        if (!isSingleWordSelection(selection)) {
            val prompt = buildLocalRewritePrompt(action, lyrics, selection, currentSection)
            val parsed = cleanLocalRewrite(service.generateResponse(prompt), selection)
            if (parsed.isBlank()) {
                throw RuntimeException("Local model returned no rewrite. Try a different model or use a cloud provider.")
            }
            if (normalizeSuggestionKey(parsed) == normalizeSuggestionKey(selection)) {
                throw RuntimeException("Local model returned the original text unchanged. Try again or use a cloud provider.")
            }
            return parsed
        }

        val context = singleWordRewriteContext(lyrics, selection, selectionStart)
        val rejectedKeys = rewriteRejectKeys(selection, rejectedCandidates).toMutableSet()
        repeat(LOCAL_REWRITE_ATTEMPTS) {
            val prompt = buildLocalRewritePrompt(
                action = action,
                lyrics = lyrics,
                selection = selection,
                currentSection = currentSection,
                selectionStart = selectionStart,
                rejectedCandidates = rejectedKeys
            )
            val parsed = cleanLocalRewrite(service.generateResponse(prompt), selection)
            val accepted = acceptLocalSingleWordRewrite(parsed, selection, action, context, rejectedKeys)
            if (accepted.isNotBlank()) return accepted
            normalizeSuggestionKey(parsed).takeIf { it.isNotBlank() }?.let { rejectedKeys += it }
        }

        val fallback = fallbackLocalSingleWordRewrite(selection, action, context, rejectedKeys)
        if (fallback.isNotBlank()) return fallback

        if (action == RewriteAction.HARDER_RHYME) {
            throw RuntimeException("No safe rhyme. Select the line.")
        }
        throw RuntimeException("Local model returned no rewrite. Try a different model or use a cloud provider.")
    }

    internal fun acceptLocalSingleWordRewrite(candidate: String, selection: String, action: RewriteAction): String =
        acceptLocalSingleWordRewrite(candidate, selection, action, context = null, rejectedCandidates = emptySet())

    internal fun acceptLocalSingleWordRewrite(
        candidate: String,
        selection: String,
        action: RewriteAction,
        context: SingleWordRewriteContext?,
        rejectedCandidates: Set<String>
    ): String {
        val word = candidate.trim()
        if (!isSingleWordSelection(word)) return ""
        val originalKey = normalizeSuggestionKey(selection)
        val candidateKey = normalizeSuggestionKey(word)
        if (
            candidateKey.isEmpty() ||
            candidateKey == originalKey ||
            candidateKey in rewriteRejectKeys(selection, rejectedCandidates)
        ) {
            return ""
        }

        if (action == RewriteAction.HARDER_RHYME) {
            val originalSyllables = ProsodyAnalyzer.countWord(selection).coerceAtLeast(1)
            val candidateSyllables = ProsodyAnalyzer.countWord(word).coerceAtLeast(1)
            if (candidateSyllables > originalSyllables + 1) return ""
            if (!harderRhymeFitsContext(selection, word, context)) return ""
        }

        return word
    }

    internal fun fallbackLocalSingleWordRewrite(
        selection: String,
        action: RewriteAction,
        context: SingleWordRewriteContext? = null,
        rejectedCandidates: Set<String> = emptySet()
    ): String {
        val originalKey = normalizeSuggestionKey(selection)
        if (originalKey.isEmpty()) return ""
        val candidates = when (action) {
            RewriteAction.REPHRASE -> fallbackRephraseWords[originalKey]
            RewriteAction.HARDER_RHYME -> fallbackHarderRhymeWords[originalKey]
            RewriteAction.PUNCH_UP -> fallbackPunchUpWords[originalKey]
        }.orEmpty()
        return candidates.firstOrNull { candidate ->
            acceptLocalSingleWordRewrite(candidate, selection, action, context, rejectedCandidates).isNotBlank()
        }.orEmpty()
    }

    internal fun singleWordRewriteContext(
        lyrics: String,
        selection: String,
        selectionStart: Int?
    ): SingleWordRewriteContext? {
        val start = selectionStart ?: return null
        if (start !in 0..lyrics.length) return null
        val lineStart = lyrics.lastIndexOf('\n', (start - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
        val lineEnd = lyrics.indexOf('\n', start).let { if (it < 0) lyrics.length else it }
        val line = lyrics.substring(lineStart, lineEnd)
        val relativeStart = start - lineStart
        val relativeEnd = relativeStart + selection.length
        val matches = singleWordPattern.findAll(line).toList()
        val selectedIndex = matches.indexOfFirst { match ->
            val range = match.range
            relativeStart <= range.last + 1 && relativeEnd >= range.first
        }
        if (selectedIndex < 0) return null
        val selectedMatch = matches[selectedIndex]
        val trailing = line.substring(selectedMatch.range.last + 1)
        return SingleWordRewriteContext(
            line = line,
            previousWord = matches.getOrNull(selectedIndex - 1)?.value,
            nextWord = matches.getOrNull(selectedIndex + 1)?.value,
            isLineEnding = trailing.none { it.isLetterOrDigit() }
        )
    }

    private fun harderRhymeFitsContext(
        selection: String,
        candidate: String,
        context: SingleWordRewriteContext?
    ): Boolean {
        val ctx = context ?: return true
        val originalKey = normalizeSuggestionKey(selection)
        val candidateKey = normalizeSuggestionKey(candidate)
        val previousKey = ctx.previousWord?.let(::normalizeSuggestionKey).orEmpty()
        val nextKey = ctx.nextWord?.let(::normalizeSuggestionKey).orEmpty()

        if (!ctx.isLineEnding) return false
        if (originalKey == "make" && nextKey == "believe") return false
        if (previousKey == "phone" && candidateKey in setOf("walls", "falls", "halls")) return false
        if (!harderRhymeSoundsClose(selection, candidate)) return false
        return true
    }

    private fun harderRhymeSoundsClose(selection: String, candidate: String): Boolean {
        val originalKey = normalizeSuggestionKey(selection)
        val candidateKey = normalizeSuggestionKey(candidate)
        val fallbackKeys = fallbackHarderRhymeWords[originalKey].orEmpty().map(::normalizeSuggestionKey).toSet()
        if (candidateKey in fallbackKeys) return true

        val originalRhymeKeys = ProsodyAnalyzer.rhymeKeys(selection, maxDepth = 2).toSet()
        val candidateRhymeKeys = ProsodyAnalyzer.rhymeKeys(candidate, maxDepth = 2).toSet()
        if (originalRhymeKeys.isNotEmpty() && candidateRhymeKeys.isNotEmpty()) {
            return originalRhymeKeys.intersect(candidateRhymeKeys).isNotEmpty()
        }

        val originalTail = spellingRhymeTail(originalKey)
        val candidateTail = spellingRhymeTail(candidateKey)
        return originalTail.isNotBlank() && originalTail == candidateTail
    }

    private fun spellingRhymeTail(word: String): String {
        if (word.length < 2) return ""
        return word
            .replace("ee", "i")
            .replace("ea", "i")
            .replace("ie", "i")
            // "ight" must collapse before the bare "igh" rule so "night"/"invite"
            // land in the same bucket ("nite"/"vite" share the "ite" tail).
            .replace("ight", "ite")
            .replace("igh", "i")
            .replace("ai", "a")
            .replace("ay", "a")
            .takeLast(3)
    }

    private fun lyricLineAt(lyrics: String, selectionStart: Int): String {
        val start = selectionStart.coerceIn(0, lyrics.length)
        val lineStart = lyrics.lastIndexOf('\n', (start - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
        val lineEnd = lyrics.indexOf('\n', start).let { if (it < 0) lyrics.length else it }
        return lyrics.substring(lineStart, lineEnd).trim()
    }

    private fun rewriteRejectKeys(selection: String, rejectedCandidates: Set<String>): Set<String> =
        (rejectedCandidates + selection)
            .mapNotNull { normalizeSuggestionKey(it).takeIf(String::isNotBlank) }
            .toSet()

    internal fun cleanLocalRewrite(response: String, selection: String? = null): String {
        val trimmed = stripLocalModelArtifacts(response)
        // If the model still emitted JSON, extract its rewrite field.
        val extracted = extractRewriteField(trimmed)?.let(::stripLocalModelArtifacts) ?: trimmed
        val cleaned = extracted
            .removeSurrounding("\"")
            .removeSurrounding("'")
            .trim()
        val candidate = if (selection != null && isSingleWordSelection(selection)) {
            cleanSingleWordRewrite(cleaned, selection)
        } else {
            cleanRewritePassage(cleaned)
        }
        return if (selection != null && normalizeSuggestionKey(candidate) == normalizeSuggestionKey(selection)) {
            ""
        } else {
            candidate
        }
    }

    private fun cleanRewritePassage(response: String): String {
        val cleaned = stripLocalModelArtifacts(response)
            .lines()
            .mapNotNull { cleanLocalOutputLine(it, maxLength = 240) }
            .joinToString("\n")
            .trim()
        if (cleaned.isBlank()) return ""
        if (localControlMarkerPattern.containsMatchIn(cleaned)) return ""
        return cleaned
    }

    private fun cleanSingleWordRewrite(response: String, selection: String): String {
        val originalKey = normalizeSuggestionKey(selection)
        val labelTokens = setOf(
            "a",
            "an",
            "as",
            "be",
            "i",
            "instead",
            "is",
            "model",
            "original",
            "replace",
            "replacement",
            "rewrite",
            "selected",
            "suggest",
            "the",
            "try",
            "turn",
            "use",
            "user",
            "with",
            "word",
            "would"
        )
        return stripLocalModelArtifacts(response)
            .replace("=>", "->")
            .replace(":", " ")
            .lineSequence()
            .flatMap { line -> line.split("->", ",", "/", "|").asSequence() }
            .map { part ->
                part.trim()
                    .removePrefix("replacement")
                    .removePrefix("Replacement")
                    .removePrefix("rewrite")
                    .removePrefix("Rewrite")
                    .trim('"', '\'', '`', '.', '!', '?', ';', ':', '-', '*', '•', ' ')
            }
            .flatMap { part ->
                if (part.any(Char::isWhitespace)) {
                    part.split(Regex("\\s+")).asSequence()
                } else {
                    sequenceOf(part)
                }
            }
            .map { it.trim('"', '\'', '`', '.', '!', '?', ';', ':', '-', '*', '•', ' ') }
            .firstOrNull { token ->
                val key = normalizeSuggestionKey(token)
                key.isNotEmpty() &&
                    key != originalKey &&
                    token.length <= 32 &&
                    key !in labelTokens
            }
            .orEmpty()
    }

    private fun extractRewriteField(text: String): String? {
        val cleaned = stripLocalModelArtifacts(text)
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

    private suspend fun callGemini(apiKey: String, modelId: String, prompt: String, constraint: SuggestionRhymeConstraint? = null): List<SuggestedLine> {
        return try {
            val text = generateGeminiText(apiKey, modelId, prompt) ?: return emptyList()
            parseSuggestionList(text, constraint)
        } catch (error: Throwable) {
            throw userFacingProviderException(error)
        }
    }

    private suspend fun callOpenAI(apiKey: String, modelId: String, prompt: String, constraint: SuggestionRhymeConstraint? = null): List<SuggestedLine> {
        val responseText = httpPost(
            url = "https://api.openai.com/v1/chat/completions",
            headers = mapOf(
                "Authorization" to "Bearer $apiKey",
                "Content-Type" to "application/json"
            ),
            body = buildOpenAIChatRequestBody(
                modelId = modelId,
                prompt = prompt,
                temperature = 0.8
            ).toString()
        )
        val content = parseOpenAIMessageContent(responseText) ?: return emptyList()
        return parseSuggestionList(content, constraint)
    }

    private suspend fun callClaude(apiKey: String, modelId: String, prompt: String, constraint: SuggestionRhymeConstraint? = null): List<SuggestedLine> {
        val responseText = httpPost(
            url = "https://api.anthropic.com/v1/messages",
            headers = mapOf(
                "x-api-key" to apiKey,
                "anthropic-version" to "2023-06-01",
                "Content-Type" to "application/json"
            ),
            body = buildClaudeMessagesRequestBody(modelId, prompt).toString()
        )
        val content = parseClaudeMessageText(responseText) ?: return emptyList()
        return parseSuggestionList(content, constraint)
    }

    internal fun parseSuggestionList(raw: String, constraint: SuggestionRhymeConstraint? = null): List<SuggestedLine> {
        val limit = if (constraint != null) SUGGESTION_COUNT * 2 else SUGGESTION_COUNT
        val parsed = parseJsonArray(raw, limit).ifEmpty { parseLines(raw) }
        val seen = mutableSetOf<String>()
        val cleaned = parsed
            .mapNotNull { cleanLocalSuggestionLine(it) }
            .filter {
                val key = normalizeSuggestionKey(it)
                key.isNotEmpty() && seen.add(key)
            }
            .take(limit)
        if (constraint == null) return cleaned.map { SuggestedLine(it, 0) }
        val ranked = RhymeConstraint.filterAndRank(
            lines = cleaned,
            targetLine = constraint.targetLine,
            rhymeType = constraint.rhymeType,
            want = SUGGESTION_COUNT,
            dictionary = constraint.dictionary
        )
        val matches = ProsodyAnalyzer.findRhymes(constraint.targetWord, dictionary = constraint.dictionary)
        val isChorusRepeat = constraint.sectionRef?.type == SongSection.CHORUS &&
                (constraint.sectionRef.ordinal) >= 2
        val chorusEnds = constraint.chorusEndWords
        return ranked.map { line ->
            val endWord = RhymeConstraint.lineEndWord(line)
            val isHook = isChorusRepeat && endWord.isNotEmpty() && endWord in chorusEnds
            val tier = RhymeConstraint.rhymeTier(
                line, constraint.targetWord, matches, constraint.dictionary
            )
            SuggestedLine(line, tier, isHook)
        }
    }

    internal fun buildLocalPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        currentSection: SongSection = SongSection.UNKNOWN,
        complexity: RhymeComplexity,
        useWholeSongContext: Boolean,
        constraint: SuggestionRhymeConstraint? = null
    ): String {
        val rhymeHint = if (targetRhymeLine != null) {
            "End every suggestion with a ${rhymeType.displayName.lowercase()} for: \"$targetRhymeLine\"."
        } else {
            "Start a new rhyme sound for letter \"$currentLetter\"."
        }
        val constraintBlock = constraint?.let { "\n" + constraintInstruction(it) }.orEmpty()
        // Cloud over-generates 2x for the rhyme filter; the on-device model is
        // slow and small, and doubling its output length doubles the chance of
        // malformed output — keep the ask at 6 and let filterAndRank re-rank.
        val requestCount = SUGGESTION_COUNT
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
        val sectionDirective = buildSectionDirective(constraint?.sectionRef, lyrics)
        val userPrompt = """
You are RhymeAI's on-device songwriting assistant.

Task: write exactly $requestCount next-line options for the song.
Theme: $effectiveTheme
Rhyme scheme: "$rhymeScheme"; next line is "$currentLetter".
Current song section: ${currentSection.displayName}.
${currentSection.promptHint}
${sectionDirective}$rhymeHint$constraintBlock
$songContextInstruction
Complexity: ${complexity.label}. ${complexity.promptHint}

Lyrics context:
${"\"\"\""}
$lyricContext
${"\"\"\""}

Rules:
- Return exactly $requestCount lines.
- One suggestion per line.
- Return only candidate lyric lines.
- Do not copy any existing lyric line.
- Do not repeat the same suggestion.
- No numbering, bullets, quotes, markdown, labels, or explanation.
- Do not apologize, explain limitations, or restate the rules.
- Keep each suggestion under 16 words.
""".trimIndent()

        return gemmaInstructionPrompt(userPrompt)
    }

    private suspend fun callLocal(prompt: String, lyrics: String, constraint: SuggestionRhymeConstraint? = null): List<SuggestedLine> {
        val service = localModelService
            ?: throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        if (!service.isLoaded) {
            throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        }
        // The local prompt asks for SUGGESTION_COUNT lines even when constrained
        // (see buildLocalPrompt); filterAndRank still verifies and re-ranks them.
        val limit = SUGGESTION_COUNT
        val response = service.generateResponse(prompt)
        val rawResults = parseJsonArray(response, limit).ifEmpty { parseLines(response) }
        val sanitized = sanitizeLocalSuggestions(rawResults, lyrics, limit)
        val ranked = if (constraint == null) sanitized else RhymeConstraint.filterAndRank(
            lines = sanitized,
            targetLine = constraint.targetLine,
            rhymeType = constraint.rhymeType,
            want = SUGGESTION_COUNT,
            dictionary = constraint.dictionary
        )
        if (ranked.isEmpty()) {
            throw RuntimeException("Local model returned no usable suggestions. Try a different model or use a cloud provider.")
        }
        val matches = constraint?.let {
            ProsodyAnalyzer.findRhymes(it.targetWord, dictionary = it.dictionary)
        }
        return ranked.map { line ->
            if (constraint == null) {
                SuggestedLine(line, 0)
            } else {
                val endWord = RhymeConstraint.lineEndWord(line)
                val isChorusRepeat = constraint.sectionRef?.type == SongSection.CHORUS &&
                        (constraint.sectionRef.ordinal) >= 2
                val isHook = isChorusRepeat && endWord.isNotEmpty() && endWord in constraint.chorusEndWords
                val tier = RhymeConstraint.rhymeTier(
                    line, constraint.targetWord, requireNotNull(matches), constraint.dictionary
                )
                SuggestedLine(line, tier, isHook)
            }
        }
    }

    private val listPrefixPattern = Regex("^\\s*(?:[-*]\\s+|\\d+[.)\\-:]\\s*)")
    private val markerOnlyPattern = Regex(
        pattern = "^\\s*(?:_?response>|_?output>|_?model_response>|assistant_response>|model_response>|<?/?(?:start|end)_?(?:of_?)?turn>?\\w*|<[^>]+>|>|user|model|assistant)\\s*$",
        option = RegexOption.IGNORE_CASE
    )
    private val markerPrefixPattern = Regex(
        pattern = "^\\s*(?:_?response>|_?output>|_?model_response>|assistant_response>|model_response>|assistant:|model:|user:|<?/?(?:start|end)_?(?:of_?)?turn>?\\w*)\\s*",
        option = RegexOption.IGNORE_CASE
    )
    private val modelPayloadPrefixPattern = Regex(
        pattern = ".*(?:<start_?(?:of_?)?turn>\\s*model|start_?(?:of_?)?turn>\\s*model|_?model_response>|assistant_response>|model_response>)\\s*",
        options = setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)
    )
    // Turn markers are plain text to the gemma-4 tokenizer, so the model spells
    // them out and a sampling derailment can glue a mutated or truncated marker
    // (e.g. "<end_turn>", "<end_") to the end of an otherwise good line. Strip
    // those instead of rejecting the lyric.
    private val trailingControlMarkerPattern = Regex(
        pattern = "(?:\\s*<?/?(?:start|end)_?(?:of_?)?turn>?)+\\s*$|\\s*<[a-z_/]{0,16}$",
        option = RegexOption.IGNORE_CASE
    )
    private val localControlMarkerPattern = Regex(
        pattern = "<?/?(?:start|end)_?(?:of_?)?turn>?\\w*|_?response>|_?model_response>|assistant_response>|model_response>",
        option = RegexOption.IGNORE_CASE
    )
    private val promptEchoPattern = Regex(
        pattern = "^(?:task:|theme:|rhyme scheme:|lyrics context:|rules:|return exactly|return only|one suggestion|no numbering|do not|keep each|you are rhymeai|sure[, ]|here are|i can(?:not|'t)|as an ai)",
        option = RegexOption.IGNORE_CASE
    )
    private val normalizedLinePattern = Regex("[^a-z0-9]+")
    private val singleWordPattern = Regex("[\\p{L}\\p{N}'-]+")

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
                    // Drop the response body — provider error payloads can echo
                    // back the request URL or the API key.
                    throw RuntimeException(userFacingStatusMessage(code))
                }
                response
            } finally {
                connection.disconnect()
            }
        }

    private fun parseJsonArray(text: String, limit: Int = SUGGESTION_COUNT): List<String> {
        val cleaned = text.trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
        if (cleaned.isEmpty()) return emptyList()

        val directArray = runCatching {
            json.decodeFromString<List<String>>(cleaned)
        }.getOrNull()
        if (directArray != null) return directArray.take(limit)

        return runCatching {
            json.parseToJsonElement(cleaned).jsonObject.values
                .firstNotNullOfOrNull { value ->
                    runCatching {
                        value.jsonArray.mapNotNull { item ->
                            item.jsonPrimitive.content.trim().takeIf(String::isNotEmpty)
                        }
                    }.getOrNull()
                }
                ?.take(limit)
                ?: emptyList()
        }.getOrDefault(emptyList())
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

    private fun sanitizeLocalSuggestions(
        candidates: List<String>,
        lyrics: String,
        limit: Int = SUGGESTION_COUNT
    ): List<String> {
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
            .take(limit)
    }

    private fun cleanLocalSuggestionLine(line: String): String? {
        var cleaned = stripLocalModelArtifacts(line)
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()

        if (cleaned.isBlank() || markerOnlyPattern.matches(cleaned)) return null

        cleaned = cleanLocalOutputLine(cleaned, maxLength = 140) ?: return null
        cleaned = trailingControlMarkerPattern.replace(cleaned, "").trim()

        if (cleaned.isBlank()) return null
        if (markerOnlyPattern.matches(cleaned)) return null
        if (promptEchoPattern.containsMatchIn(cleaned)) return null
        if (localControlMarkerPattern.containsMatchIn(cleaned)) return null
        if (cleaned.length > 140) return null

        return cleaned
    }

    private fun cleanLocalOutputLine(line: String, maxLength: Int): String? {
        val cleaned = stripLocalModelArtifacts(line)
            .let { markerPrefixPattern.replace(it, "") }
            .let { listPrefixPattern.replace(it, "") }
            .trim()
            .removeSurrounding("\"")
            .removeSurrounding("'")
            .trim()

        if (cleaned.isBlank()) return null
        if (markerOnlyPattern.matches(cleaned)) return null
        if (promptEchoPattern.containsMatchIn(cleaned)) return null
        if (localControlMarkerPattern.containsMatchIn(cleaned)) return null
        if (cleaned.length > maxLength) return null
        return cleaned
    }

    private fun stripLocalModelArtifacts(text: String): String {
        return text
            .trim()
            .let { modelPayloadPrefixPattern.replace(it, "") }
            .substringBefore("<end_of_turn>")
            .substringBefore("end_of_turn>")
            .let { localControlMarkerPattern.replace(it, "") }
            .lines()
            .filterNot { line ->
                val trimmed = line.trim()
                trimmed.equals("```json", ignoreCase = true) || trimmed == "```" || markerOnlyPattern.matches(trimmed)
            }
            .joinToString("\n")
            .trim()
            .removePrefix("```json")
            .removePrefix("```")
            .removeSuffix("```")
            .trim()
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
