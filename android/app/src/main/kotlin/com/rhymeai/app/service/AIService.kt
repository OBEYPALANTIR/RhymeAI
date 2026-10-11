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
import com.rhymeai.app.util.RhymeLineFilter
import com.rhymeai.app.util.SectionMap
import com.rhymeai.app.util.SectionRef
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.transformWhile
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
    LOCAL("Local"),
    GEMINI("Gemini"),
    OPENAI("OpenAI"),
    CLAUDE("Claude");

    companion object {
        fun fromName(name: String): AIProvider =
            entries.find { it.name == name } ?: LOCAL
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
    // Opt-in observer for synthetic parser tests; no production sink or file logging.
    internal data class LocalSuggestionDecision(
        val rawLine: String,
        val candidate: String?,
        val disposition: String
    )

    /** Dedupe keys and counts shared by the local path's first and retry pass. */
    internal class LineStreamState {
        val seen = mutableSetOf<String>()
        var accepted = 0
        var emitted = 0
    }

    internal data class SingleWordRewriteContext(
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
    ) {
        /** The returned-line filter for this request: admits only [rhymeType]. */
        val lineFilter: RhymeLineFilter? by lazy { RhymeLineFilter.create(targetLine, rhymeType, dictionary) }
    }

    /** No returned line matched the requested relation; mirrors iOS `noMatchingRhymes`. */
    internal class NoMatchingRhymesException(rhymeType: RhymeType) : RuntimeException(
        "The provider returned lines, but none matched the requested ${rhymeType.name.lowercase()} rhyme. Try another rhyme type."
    )

    private companion object {
        const val SUGGESTION_COUNT = 6
        /** Local rule (PARITY.md): fewer than [SUGGESTION_COUNT] survivors retries once; fewer than this after that is an error. */
        const val MIN_SUGGESTIONS = 3
        // On-device lyric context budget, shared with iOS (see PARITY.md).
        const val LOCAL_RECENT_CONTEXT_CHARS = 2600
        const val LOCAL_WHOLE_SONG_HEAD_CHARS = 900
        const val LOCAL_WHOLE_SONG_TAIL_CHARS = 2200
        const val LOCAL_TRIM_MARKER = "[Lyrics trimmed for on-device speed]"
        /** Next-line intent sentence, byte-identical to iOS `localSuggestionIntent`. */
        const val LOCAL_SUGGESTION_INTENT =
            "The writer is stuck on the next line and wants ideas to pick from, not a finished verse."
        const val LOCAL_REWRITE_ATTEMPTS = 2
        const val LOCAL_INCOMPLETE_RESPONSE =
            "Local model returned an incomplete response. Try again or use a cloud provider."

        fun userFacingStatusMessage(code: Int): String = when (code) {
            401, 403 -> "Provider rejected the request — check your API key in Settings."
            404 -> "Provider could not find the requested model — pick another in Settings."
            429 -> "Provider rate limit reached — wait a moment and retry."
            in 500..599 -> "Provider service error — try again shortly."
            else -> "Provider request failed (status $code)."
        }

        fun userFacingProviderException(error: Throwable): RuntimeException {
            if (error is CancellationException) throw error
            if (error is NoMatchingRhymesException) return error
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
    // The complexity level shapes the allowed list (RhymeConstraint.levelEndWords):
    // two-or-more-syllable rhymes first at COMPLEX, one-syllable rhymes at SIMPLE.
    internal fun suggestionRhymeConstraint(
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared,
        sectionRef: SectionRef? = null,
        chorusEndWords: Set<String> = emptySet(),
        complexity: RhymeComplexity = RhymeComplexity.MODERATE
    ): SuggestionRhymeConstraint? {
        if (targetRhymeLine.isNullOrBlank()) return null
        val targetWord = RhymeConstraint.lineEndWord(targetRhymeLine)
        if (targetWord.isEmpty()) return null
        var candidates = RhymeConstraint.candidateEndWords(
            targetWord, rhymeType, dictionary = dictionary, complexity = complexity
        )
        if (candidates.isEmpty()) return null

        val type = sectionRef?.type ?: SongSection.UNKNOWN
        val ordinal = sectionRef?.ordinal ?: 1

        // Chorus repeat (2nd+): first-chorus end words that stand in the requested
        // rhyme relation to the target go first. The relation is verified directly
        // (the same check RhymeLineFilter applies to returned lines), not by
        // membership in the level's 12-word cut or the index's capped pools, so a
        // hook the Complex or Simple ordering pushed past the limit is still
        // promoted; the merged list is then cut back to the limit. Hooks are not
        // filtered through the level: chorus consistency wins (the Simple hint says
        // "Prefer one-syllable end words" for this reason).
        if (type == SongSection.CHORUS && ordinal >= 2 && chorusEndWords.isNotEmpty()) {
            val promoted = chorusEndWords.filter {
                it != targetWord && ProsodyAnalyzer.rhymeRelation(it, targetWord, dictionary) == rhymeType
            }
            candidates = (promoted + candidates.filter { it !in promoted }).take(RhymeConstraint.CANDIDATE_LIMIT)
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
            .filter { SectionMap.headerTitle(it) == null }
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
        val instanceDirective = when (ref.type) {
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
        return instanceDirective
    }

    /** Lines of lyrics content (non-header, non-blank) within the first chorus section. */
    private fun firstChorusLines(lyrics: String): List<String> {
        val map = SectionMap.parse(lyrics)
        val firstChorus = map.allSections.firstOrNull { it.type == SongSection.CHORUS }
            ?: return emptyList()
        val lines = lyrics.split('\n')
        return firstChorus.lineRange
            .mapNotNull { idx -> lines.getOrNull(idx) }
            .filter { it.isNotBlank() && SectionMap.headerTitle(it) == null }
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
        constraint: SuggestionRhymeConstraint? = null,
        sectionRef: SectionRef? = constraint?.sectionRef
    ): String {
        val providerLyrics = if (useWholeSongContext) lyrics else targetRhymeLine.orEmpty()
        val providerSection = sectionRef.takeIf { useWholeSongContext }
        val providerConstraint = if (useWholeSongContext) constraint else constraint?.let {
            suggestionRhymeConstraint(targetRhymeLine, rhymeType, it.dictionary, complexity = complexity)
        }
        val rhymeInstruction = if (targetRhymeLine != null) {
            "Crucially, the new line MUST end with a **${rhymeType.displayName}** to this specific line: \"$targetRhymeLine\"."
        } else {
            "Since this is a new rhyme sound (\"$currentLetter\"), the new line should introduce a new end-rhyme that fits the meter and theme."
        }
        val constraintBlock = providerConstraint?.let { "\n" + constraintInstruction(it) }.orEmpty()
        val requestCount = if (providerConstraint != null) SUGGESTION_COUNT * 2 else SUGGESTION_COUNT
        val songContextInstruction = if (useWholeSongContext) {
            "Analyze the whole song for story arc, recurring images, hook language, speaker perspective, tone, and vocabulary. Make each suggestion feel connected to the entire song while still fitting the immediate target line and rhyme scheme."
        } else {
            "Prioritize the target line, rhyme scheme, and provided theme/context."
        }

        // A written theme is sent in both modes; whole-song context only changes the fallback.
        val effectiveTheme = theme.ifEmpty {
            if (useWholeSongContext) "Whole song context enabled; infer the theme from the full lyrics."
            else "No specific theme provided"
        }

        val sectionDirective = buildSectionDirective(providerSection, providerLyrics)

        return """
You are an expert songwriter and lyricist.
The user is writing a song with the following theme/context: "$effectiveTheme".
Here are the current lyrics:
${"\"\"\""}
$providerLyrics
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
        fullLyrics: String = lyrics,
        cursorLine: Int? = null
    ): List<SuggestedLine> {
        if (provider != AIProvider.LOCAL && apiKey.isBlank()) {
            throw IllegalStateException("No API key set. Go to Settings to add your ${provider.displayName} API key.")
        }

        val includeSong = provider == AIProvider.LOCAL || useWholeSongContext
        val chorusEnds = if (includeSong) firstChorusEndWords(fullLyrics) else emptySet()
        val constraint = suggestionRhymeConstraint(
            targetRhymeLine, rhymeType, sectionRef = sectionRef.takeIf { includeSong }, chorusEndWords = chorusEnds,
            complexity = complexity
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
                constraint = constraint,
                cursorLine = cursorLine
            )
            callLocal(localPrompt, lyrics, constraint)
        } else {
            val prompt = buildPrompt(
                theme,
                lyrics,
                targetRhymeLine,
                rhymeType,
                rhymeScheme,
                currentLetter,
                currentSection,
                complexity,
                useWholeSongContext,
                constraint,
                sectionRef
            )
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
        fullLyrics: String = lyrics,
        cursorLine: Int? = null
    ): Flow<SuggestedLine> = flow {
        if (provider != AIProvider.LOCAL && apiKey.isBlank()) {
            throw IllegalStateException("No API key set. Go to Settings to add your ${provider.displayName} API key.")
        }

        val includeSong = provider == AIProvider.LOCAL || useWholeSongContext
        val chorusEnds = if (includeSong) firstChorusEndWords(fullLyrics) else emptySet()
        val constraint = suggestionRhymeConstraint(
            targetRhymeLine, rhymeType, sectionRef = sectionRef.takeIf { includeSong }, chorusEndWords = chorusEnds,
            complexity = complexity
        )
        if (provider == AIProvider.LOCAL) {
            val service = localModelService
                ?: throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
            if (!service.isLoaded) {
                throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
            }
            val prompt = buildLocalPrompt(
                theme = theme,
                lyrics = lyrics,
                targetRhymeLine = targetRhymeLine,
                rhymeType = rhymeType,
                rhymeScheme = rhymeScheme,
                currentLetter = currentLetter,
                currentSection = currentSection,
                complexity = complexity,
                useWholeSongContext = useWholeSongContext,
                constraint = constraint,
                cursorLine = cursorLine
            )
            validatedLocalSuggestionStream({ service.streamResponse(prompt) }, lyrics, constraint)
                .collect { emit(it) }
        } else {
            val prompt = buildPrompt(
                theme,
                lyrics,
                targetRhymeLine,
                rhymeType,
                rhymeScheme,
                currentLetter,
                currentSection,
                complexity,
                useWholeSongContext,
                constraint,
                sectionRef
            )
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

    internal fun buildOpenAIChatRequestBody(
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

    internal fun buildClaudeMessagesRequestBody(
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
        constraint: SuggestionRhymeConstraint? = null,
        excludedKeys: Set<String> = emptySet(),
        onDecision: ((LocalSuggestionDecision) -> Unit)? = null,
        /** Local path only: state carried into the retry pass; the caller applies the count rule afterwards. */
        localPass: LineStreamState? = null
    ) {
        val buffer = StringBuilder()
        val state = localPass ?: LineStreamState()
        // Constrained requests over-generate 2x and emit only lines that end in
        // the requested relation, as they arrive (iOS `emitLines`).
        val filter = constraint?.lineFilter
        val acceptLimit = if (filter != null) SUGGESTION_COUNT * 2 else SUGGESTION_COUNT
        // The budget is per generation; a retry pass gets a fresh one.
        var passAccepted = 0

        suspend fun flushLine(rawLine: String): Boolean {
            if (passAccepted >= acceptLimit || state.emitted >= SUGGESTION_COUNT) return false
            val cleaned = cleanLocalSuggestionLine(rawLine)
            val key = cleaned?.let(::normalizeSuggestionKey).orEmpty()
            val rejection = when {
                cleaned == null || key.isEmpty() -> "format"
                key in excludedKeys -> "existing_lyric"
                !state.seen.add(key) -> "duplicate"
                else -> null
            }
            if (rejection != null) {
                onDecision?.invoke(LocalSuggestionDecision(rawLine, cleaned, rejection))
                return false
            }
            checkNotNull(cleaned)
            state.accepted++
            passAccepted++
            onDecision?.invoke(LocalSuggestionDecision(rawLine, cleaned, "accepted"))

            val tier = filter?.tier(cleaned) ?: 0
            if (filter != null && tier == 0) {
                onDecision?.invoke(LocalSuggestionDecision(rawLine, cleaned, "rhyme_mismatch"))
                return true
            }
            val isHook = constraint != null && isHookRepeat(cleaned, constraint)
            emit(SuggestedLine(cleaned, tier, isHook))
            state.emitted++
            onDecision?.invoke(LocalSuggestionDecision(rawLine, cleaned, "displayed"))
            return true
        }

        // Stop consuming the model once a cap is reached, as iOS `emitLines` breaks its loop.
        tokens.transformWhile<String, Unit> { chunk ->
            buffer.append(chunk)
            while (passAccepted < acceptLimit && state.emitted < SUGGESTION_COUNT) {
                val newlineIdx = buffer.indexOf('\n')
                if (newlineIdx < 0) break
                val rawLine = buffer.substring(0, newlineIdx)
                buffer.delete(0, newlineIdx + 1)
                flushLine(rawLine)
            }
            passAccepted < acceptLimit && state.emitted < SUGGESTION_COUNT
        }.collect()
        if (buffer.isNotBlank()) {
            flushLine(buffer.toString())
        }
        if (localPass == null && filter != null && state.accepted > 0 && state.emitted == 0) {
            throw NoMatchingRhymesException(filter.rhymeType)
        }
    }

    private fun requireMinimumLocalSuggestions(survivors: Int, accepted: Int, filter: RhymeLineFilter?) {
        if (survivors >= MIN_SUGGESTIONS) return
        if (filter != null && accepted > 0 && survivors == 0) throw NoMatchingRhymesException(filter.rhymeType)
        throw RuntimeException(LOCAL_INCOMPLETE_RESPONSE)
    }

    /** [tokens] is invoked once more for the retry pass. */
    internal fun validatedLocalSuggestionStream(
        tokens: () -> Flow<String>,
        lyrics: String,
        constraint: SuggestionRhymeConstraint? = null,
        onDecision: ((LocalSuggestionDecision) -> Unit)? = null
    ): Flow<SuggestedLine> = flow {
        val existingKeys = lyrics.lines()
            .map(::normalizeSuggestionKey)
            .filter(String::isNotEmpty)
            .toSet()
        val state = LineStreamState()
        // retryFloor = the first pass's count, snapshotted before the retry mutates state.
        suspend fun pass(retryFloor: Int?) = emitLinesFromTokens(
            tokens = flow {
                tokens().collect { chunk ->
                    if (containsMarkupOrControlLeakage(chunk)) {
                        onDecision?.invoke(LocalSuggestionDecision(chunk, null, "markup_or_control"))
                        throw RuntimeException(LOCAL_INCOMPLETE_RESPONSE)
                    }
                    emit(chunk)
                }
            }.catch { error ->
                // A failed optional retry ends the pass once the first already met the minimum.
                if (error is CancellationException || retryFloor == null || retryFloor < MIN_SUGGESTIONS) throw error
            },
            constraint = constraint,
            excludedKeys = existingKeys,
            onDecision = onDecision,
            localPass = state
        )
        pass(retryFloor = null)
        // Retry once: LocalModelService samples with seed -1, a fresh llama.cpp seed per call.
        if (state.emitted < SUGGESTION_COUNT) pass(retryFloor = state.emitted)
        requireMinimumLocalSuggestions(state.emitted, state.accepted, constraint?.lineFilter)
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
        val synonyms = extractSynonyms(raw, exclude = target).take(limit.coerceAtLeast(0))
        if (provider == AIProvider.LOCAL && synonyms.isEmpty()) {
            throw RuntimeException("Local model returned no valid synonyms. Try again or use a cloud provider.")
        }
        return synonyms
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

    internal fun buildLocalSynonymsPrompt(word: String, lineContext: String, limit: Int): String =
        buildLocalSynonymsUserPrompt(word, lineContext, limit)

    internal fun buildLocalSynonymsUserPrompt(word: String, lineContext: String, limit: Int): String {
        val contextLine = lineContext.trim().take(180)
        val contextBlock = if (contextLine.isEmpty()) {
            "(no surrounding line)"
        } else {
            contextLine
        }
        return """
You are RhymeAI's on-device word helper.

Task: give up to $limit single-word replacements for "$word" in this lyric line:
"$contextBlock"

Rules:
- Return only replacement words, one per line.
- No JSON, bullets, numbering, labels, quotes, or commentary.
- Do not include "$word".
- Prefer words with similar tone and syllable count.
""".trimIndent()
    }

    internal fun extractSynonyms(
        raw: String,
        exclude: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): List<String> {
        if (containsMarkupOrControlLeakage(raw)) return emptyList()
        val cleaned = raw.trim()
        if (cleaned.isEmpty()) return emptyList()
        val excludeKey = canonicalWordKey(exclude)
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
            .map { line -> line.trim().trim('"', '\'') }
            .filter { it.isNotEmpty() }

        val seen = mutableSetOf<String>()
        return candidates.mapNotNull { candidate ->
            val word = candidate.trim().trim('"', '\'')
            if (!isKnownSingleWord(word, dictionary)) return@mapNotNull null
            val key = canonicalWordKey(word)
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
        rejectedCandidates: Set<String> = emptySet(),
        useWholeSongContext: Boolean = false
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
            val prompt = buildRewritePrompt(
                action,
                fullLyrics,
                selection,
                currentSection,
                useWholeSongContext
            )
            val raw = callCloudRaw(provider, apiKey, modelId, prompt)
            extractRewriteField(raw)?.takeIf { it.isNotBlank() }
                ?: throw RuntimeException("AI did not return a rewrite. Try again.")
        }
    }

    internal fun buildRewritePrompt(
        action: RewriteAction,
        lyrics: String,
        selection: String,
        currentSection: SongSection = SongSection.UNKNOWN,
        useWholeSongContext: Boolean = false
    ): String =
        """
You are an expert songwriter helping the user rewrite a portion of their song.

${if (useWholeSongContext) "Full lyrics for context:" else "Selected passage context:"}
${"\"\"\""}
${if (useWholeSongContext) lyrics else selection}
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
    ): String = buildLocalRewriteUserPrompt(
            action,
            lyrics,
            selection,
            currentSection,
            selectionStart,
            rejectedCandidates
        )

    internal fun buildLocalRewriteUserPrompt(
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
        val selectedLineCount = selection.lines().size
        val selectedLineNoun = if (selectedLineCount == 1) "line" else "lines"
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
- Return exactly $selectedLineCount $selectedLineNoun.
- Preserve line breaks if the selection has multiple lines.
- No quotes, no markdown, no labels, no commentary.
""".trimIndent()
        }
        return """
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
            val prompt = buildLocalRewritePrompt(
                action,
                lyrics,
                selection,
                currentSection,
                selectionStart
            )
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
            canonicalWordKey(parsed).takeIf { it.isNotBlank() }?.let { rejectedKeys += it }
        }

        if (action == RewriteAction.HARDER_RHYME) {
            throw RuntimeException("No safe rhyme. Select the line.")
        }
        throw RuntimeException("Local model returned no valid replacement. Try again or use a cloud provider.")
    }

    internal fun acceptLocalSingleWordRewrite(candidate: String, selection: String, action: RewriteAction): String =
        acceptLocalSingleWordRewrite(candidate, selection, action, context = null, rejectedCandidates = emptySet())

    internal fun acceptLocalSingleWordRewrite(
        candidate: String,
        selection: String,
        action: RewriteAction,
        context: SingleWordRewriteContext?,
        rejectedCandidates: Set<String>,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): String {
        val word = candidate.trim()
        if (!isKnownSingleWord(word, dictionary)) return ""
        val originalKey = canonicalWordKey(selection)
        val candidateKey = canonicalWordKey(word)
        if (
            candidateKey.isEmpty() ||
            candidateKey == originalKey ||
            candidateKey in rewriteRejectKeys(selection, rejectedCandidates)
        ) {
            return ""
        }

        if (action == RewriteAction.HARDER_RHYME) {
            val originalSyllables = ProsodyAnalyzer.analyzeWord(selection, dictionary).syllableCount.coerceAtLeast(1)
            val candidateSyllables = ProsodyAnalyzer.analyzeWord(word, dictionary).syllableCount.coerceAtLeast(1)
            if (candidateSyllables > originalSyllables + 1) return ""
            if (!harderRhymeFitsContext(selection, word, context, dictionary)) return ""
        }

        return word
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
            previousWord = matches.getOrNull(selectedIndex - 1)?.value,
            nextWord = matches.getOrNull(selectedIndex + 1)?.value,
            isLineEnding = trailing.none { it.isLetterOrDigit() }
        )
    }

    private fun harderRhymeFitsContext(
        selection: String,
        candidate: String,
        context: SingleWordRewriteContext?,
        dictionary: PronunciationDictionary
    ): Boolean {
        if (context != null) {
            val originalKey = canonicalWordKey(selection)
            val candidateKey = canonicalWordKey(candidate)
            val previousKey = context.previousWord?.let(::canonicalWordKey).orEmpty()
            val nextKey = context.nextWord?.let(::canonicalWordKey).orEmpty()

            if (!context.isLineEnding) return false
            // Preserve the contextual exclusions already enforced on main and iOS.
            if (originalKey == "make" && nextKey == "believe") return false
            if (previousKey == "phone" && candidateKey in setOf("walls", "falls", "halls")) return false
        }
        return harderRhymeSoundsClose(selection, candidate, dictionary)
    }

    private fun harderRhymeSoundsClose(
        selection: String,
        candidate: String,
        dictionary: PronunciationDictionary
    ): Boolean {
        val originalRhymeKeys = ProsodyAnalyzer.rhymeKeys(selection, maxDepth = 2, dictionary = dictionary).toSet()
        val candidateRhymeKeys = ProsodyAnalyzer.rhymeKeys(candidate, maxDepth = 2, dictionary = dictionary).toSet()
        return originalRhymeKeys.isNotEmpty() &&
            candidateRhymeKeys.isNotEmpty() &&
            originalRhymeKeys.intersect(candidateRhymeKeys).isNotEmpty()
    }

    private fun lyricLineAt(lyrics: String, selectionStart: Int): String {
        val start = selectionStart.coerceIn(0, lyrics.length)
        val lineStart = lyrics.lastIndexOf('\n', (start - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
        val lineEnd = lyrics.indexOf('\n', start).let { if (it < 0) lyrics.length else it }
        return lyrics.substring(lineStart, lineEnd).trim()
    }

    private fun rewriteRejectKeys(selection: String, rejectedCandidates: Set<String>): Set<String> =
        (rejectedCandidates + selection)
            .mapNotNull { canonicalWordKey(it).takeIf(String::isNotBlank) }
            .toSet()

    internal fun cleanLocalRewrite(response: String, selection: String? = null): String {
        if (containsMarkupOrControlLeakage(response)) return ""
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
            cleanRewritePassage(cleaned, selection)
        }
        return if (selection != null && normalizeSuggestionKey(candidate) == normalizeSuggestionKey(selection)) {
            ""
        } else {
            candidate
        }
    }

    private fun cleanRewritePassage(response: String, selection: String?): String {
        val cleaned = stripLocalModelArtifacts(response)
            .lines()
            .map { line ->
                if (line.isBlank()) "" else cleanLocalOutputLine(line, maxLength = 240) ?: return ""
            }
            .joinToString("\n")
            .trim()
        if (cleaned.isBlank()) return ""
        if (localControlMarkerPattern.containsMatchIn(cleaned)) return ""
        if (selection != null) {
            val sourceLines = selection.trim().lines()
            val candidateLines = cleaned.lines()
            if (sourceLines.size != candidateLines.size) return ""
            if (sourceLines.zip(candidateLines).any { (source, candidate) -> source.isBlank() != candidate.isBlank() }) {
                return ""
            }
        }
        return cleaned
    }

    private fun cleanSingleWordRewrite(response: String, selection: String): String {
        val originalKey = normalizeSuggestionKey(selection)
        val word = response.trim().removeSurrounding("\"").removeSurrounding("'").trim()
        val key = normalizeSuggestionKey(word)
        return word.takeIf {
            isSingleWordSelection(it) &&
                it.length <= 32 &&
                key.isNotEmpty() &&
                key != originalKey
        }.orEmpty()
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
        val filter = constraint?.lineFilter ?: return cleaned.map { SuggestedLine(it, 0) }
        val ranked = filter.rank(cleaned, SUGGESTION_COUNT)
        if (ranked.isEmpty() && cleaned.isNotEmpty()) throw NoMatchingRhymesException(constraint.rhymeType)
        return ranked.map { line -> SuggestedLine(line, filter.tier(line), isHookRepeat(line, constraint)) }
    }

    /** A repeated first-chorus ending; only changes the badge. */
    private fun isHookRepeat(line: String, constraint: SuggestionRhymeConstraint): Boolean {
        val isChorusRepeat = constraint.sectionRef?.type == SongSection.CHORUS && constraint.sectionRef.ordinal >= 2
        val endWord = RhymeConstraint.lineEndWord(line)
        return isChorusRepeat && endWord.isNotEmpty() && endWord in constraint.chorusEndWords
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
        constraint: SuggestionRhymeConstraint? = null,
        cursorLine: Int? = null
    ): String = buildLocalSuggestionUserPrompt(
            theme,
            lyrics,
            targetRhymeLine,
            rhymeType,
            rhymeScheme,
            currentLetter,
            currentSection,
            complexity,
            useWholeSongContext,
            constraint,
            cursorLine
        )

    /**
     * End-word rule for the on-device Rules list, byte-identical to iOS
     * `localEndWordRule`: a list with fewer than six distinct (case-folded) words
     * allows repeats, so a duplicated word never counts twice.
     */
    internal fun localEndWordRule(allowedWords: List<String>?): String = when {
        allowedWords == null -> "- End each line on a different word."
        allowedWords.map { it.lowercase() }.toSet().size >= SUGGESTION_COUNT ->
            "- End each line on a different word from the allowed list."
        else -> "- The allowed list has fewer than six words, so end words may repeat, but the six lines must still be six different ideas."
    }

    internal fun buildLocalSuggestionUserPrompt(
        theme: String,
        lyrics: String,
        targetRhymeLine: String?,
        rhymeType: RhymeType,
        rhymeScheme: String,
        currentLetter: String,
        currentSection: SongSection = SongSection.UNKNOWN,
        complexity: RhymeComplexity,
        useWholeSongContext: Boolean,
        constraint: SuggestionRhymeConstraint? = null,
        cursorLine: Int? = null
    ): String {
        val rhymeHint = if (targetRhymeLine != null) {
            "End every suggestion with a ${rhymeType.displayName.lowercase()} for: \"$targetRhymeLine\"."
        } else {
            "Start a new rhyme sound for letter \"$currentLetter\"."
        }
        val constraintBlock = constraint?.let { "\n" + constraintInstruction(it) }.orEmpty()
        // Cloud over-generates 2x for the rhyme filter; the on-device model is
        // slow and small, and doubling its output length doubles the chance of
        // malformed output — keep the ask at 6 and let the line filter re-rank.
        val requestCount = SUGGESTION_COUNT
        val songContextInstruction = if (useWholeSongContext) {
            "Use the whole-song context for story arc, recurring images, hook language, speaker perspective, tone, and vocabulary."
        } else {
            "Use the immediate stanza, rhyme target, and theme first."
        }
        val effectiveTheme = if (theme.isNotBlank()) theme.trim() else "Infer from the lyrics."
        val lyricContext = localLyricsContext(lyrics, useWholeSongContext, cursorLine)
        val sectionDirective = buildSectionDirective(constraint?.sectionRef, lyrics)
        val endWordRule = localEndWordRule(constraint?.candidateWords)
        return """
You are RhymeAI's on-device songwriting assistant.

Task: write exactly $requestCount next-line options for the song.
Theme: $effectiveTheme
Rhyme scheme: "$rhymeScheme"; next line is "$currentLetter".
Current song section: ${currentSection.displayName}.
${currentSection.promptHint}
${sectionDirective}$rhymeHint$constraintBlock
$LOCAL_SUGGESTION_INTENT
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
- Make the six lines six different directions: a different idea, image or angle in each. Do not write the same thought six ways.
$endWordRule
- Write them as raw material in the writer's own voice: match the length, plainness and capitalisation of the lines around it.
- Do not resolve or conclude the song, do not sum it up, and no grand statements.
- Stay inside what the song is already about.
- Do not copy any existing lyric line.
- Do not repeat the same suggestion.
- No numbering, bullets, quotes, markdown, labels, or explanation.
- Do not apologize, explain limitations, or restate the rules.
- Keep each suggestion under 16 words.
""".trimIndent()
    }

    private suspend fun callLocal(prompt: String, lyrics: String, constraint: SuggestionRhymeConstraint? = null): List<SuggestedLine> {
        val service = localModelService
            ?: throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        if (!service.isLoaded) {
            throw IllegalStateException("No local model loaded. Go to Settings to load a model file.")
        }
        // The local prompt asks for SUGGESTION_COUNT lines even when constrained
        // (see buildLocalPrompt); the line filter still verifies and re-ranks them.
        val ranked = localSuggestionLines({ service.generateResponse(prompt) }, lyrics, constraint)
        val filter = constraint?.lineFilter
        return ranked.map { line ->
            if (constraint == null || filter == null) {
                SuggestedLine(line, 0)
            } else {
                SuggestedLine(line, filter.tier(line), isHookRepeat(line, constraint))
            }
        }
    }

    /** Batch local rule: [generate] is invoked once more for the retry pass; the first pass's ranking stays first. */
    internal suspend fun localSuggestionLines(
        generate: suspend () -> String,
        lyrics: String,
        constraint: SuggestionRhymeConstraint? = null
    ): List<String> {
        val state = LineStreamState()
        var lines = validateLocalSuggestionResponse(generate(), lyrics, constraint, state = state)
        // Retry once: LocalModelService samples with seed -1, a fresh llama.cpp seed per call.
        if (lines.size < SUGGESTION_COUNT) {
            val retry = try {
                validateLocalSuggestionResponse(generate(), lyrics, constraint, state = state)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                // A failed optional retry keeps the first pass once it already met the minimum.
                if (lines.size < MIN_SUGGESTIONS) throw error
                emptyList()
            }
            lines = lines + retry.take(SUGGESTION_COUNT - lines.size)
        }
        requireMinimumLocalSuggestions(lines.size, state.accepted, constraint?.lineFilter)
        return lines
    }

    /** One local response: sanitized, filtered and ranked to at most [SUGGESTION_COUNT]; [state] dedupes across passes. */
    internal fun validateLocalSuggestionResponse(
        response: String,
        lyrics: String,
        constraint: SuggestionRhymeConstraint? = null,
        onDecision: ((LocalSuggestionDecision) -> Unit)? = null,
        state: LineStreamState = LineStreamState()
    ): List<String> {
        if (containsMarkupOrControlLeakage(response)) {
            onDecision?.invoke(LocalSuggestionDecision(response, null, "markup_or_control"))
            throw RuntimeException(LOCAL_INCOMPLETE_RESPONSE)
        }
        val rawResults = parseJsonArray(response, Int.MAX_VALUE).ifEmpty { response.lines() }
        val sanitized = sanitizeLocalSuggestions(rawResults, lyrics, onDecision, state.seen)
        state.accepted += sanitized.size
        return constraint?.lineFilter?.rank(sanitized, SUGGESTION_COUNT) ?: sanitized.take(SUGGESTION_COUNT)
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
    private val markupOrControlLeakagePattern = Regex(
        pattern = "```|<[^>\\n]+>|(?:^|\\s)<?/?(?:start|end)_?(?:of_?)?turn>?|(?:^|\\s)(?:assistant|model|user)(?:_response)?>|<[a-z_/]{0,16}$",
        options = setOf(RegexOption.IGNORE_CASE, RegexOption.MULTILINE)
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

    /**
     * Keeps long songs inside the on-device context window without dropping the
     * stanza being written. `cursorLine` is the editor line the cursor is on
     * (`NextLinePlacement.cursorLineIndex`); null means the last line.
     */
    internal fun localLyricsContext(lyrics: String, useWholeSongContext: Boolean, cursorLine: Int? = null): String =
        if (useWholeSongContext) {
            localLyricWindow(lyrics, cursorLine, LOCAL_WHOLE_SONG_HEAD_CHARS + LOCAL_WHOLE_SONG_TAIL_CHARS, LOCAL_WHOLE_SONG_HEAD_CHARS)
        } else {
            localLyricWindow(lyrics, cursorLine, LOCAL_RECENT_CONTEXT_CHARS, 0)
        }

    /**
     * Lyrics over [budget] characters keep, in order: the cursor's blank-line-delimited
     * stanza plus the lines either side of the cursor; the opening lines up to
     * [headBudget]; then the lines nearest that window, one above then one below,
     * until the budget is spent. Each skipped run that holds a lyric becomes one
     * marker line, and room for two markers is reserved, so the result never exceeds
     * [budget]. A stanza too long for the budget keeps only the cursor's neighbours
     * before the nearest-line fill, and if those are still too long, only the cursor
     * line. A cursor line longer than the budget keeps its end (where the next line is
     * inserted) after a marker; the cut never starts on a low surrogate. Byte-identical to iOS `AIService.localLyricWindow`
     * and `finetune/eval/prompts.py` (shared fixture: shared/fixtures/local-lyric-window-v1.json).
     */
    internal fun localLyricWindow(lyrics: String, cursorLine: Int?, budget: Int, headBudget: Int): String {
        val trimmed = lyrics.trim()
        if (trimmed.length <= budget) return trimmed
        val lines = lyrics.split("\n")
        val last = lines.lastIndex
        val c = (cursorLine ?: last).coerceIn(0, last)
        val lineBudget = budget - 2 * (LOCAL_TRIM_MARKER.length + 1)
        fun cost(i: Int) = lines[i].length + 1
        fun blank(i: Int) = lines[i].isBlank()
        fun cost(range: IntRange) = range.sumOf { cost(it) }

        val blockStart = (c - 1 downTo 0).firstOrNull { blank(it) }?.plus(1) ?: 0
        val blockEnd = if (blank(c)) c else (c + 1..last).firstOrNull { blank(it) }?.minus(1) ?: last
        var lo = minOf(blockStart, maxOf(c - 1, 0))
        var hi = maxOf(blockEnd, minOf(c + 1, last))
        if (cost(lo..hi) > lineBudget) {
            lo = maxOf(c - 1, 0)
            hi = minOf(c + 1, last)
        }
        if (cost(lo..hi) > lineBudget) {
            lo = c
            hi = c
        }
        val cut: String? = if (cost(c) > lineBudget) {
            val line = lines[c]
            var start = line.length - (lineBudget - 1)
            if (line[start].isLowSurrogate()) start++
            line.substring(start)
        } else null
        var used = if (cut != null) lineBudget else cost(lo..hi)

        var headCount = 0
        var headUsed = 0
        while (headCount < lo && headUsed + cost(headCount) <= headBudget && used + cost(headCount) <= lineBudget) {
            headUsed += cost(headCount)
            used += cost(headCount)
            headCount++
        }

        while (true) {
            var grew = false
            if (lo - 1 >= headCount && used + cost(lo - 1) <= lineBudget) {
                lo--
                used += cost(lo)
                grew = true
            }
            if (hi + 1 <= last && used + cost(hi + 1) <= lineBudget) {
                hi++
                used += cost(hi)
                grew = true
            }
            if (!grew) break
        }

        fun hasLyric(from: Int, until: Int) = (from until until).any { !blank(it) }
        val out = lines.subList(0, headCount).toMutableList()
        if (hasLyric(headCount, lo) || cut != null) out += LOCAL_TRIM_MARKER
        out += (lo..hi).map { if (it == c) cut ?: lines[it] else lines[it] }
        if (hasLyric(hi + 1, last + 1)) out += LOCAL_TRIM_MARKER
        return out.joinToString("\n").trim()
    }

    private fun sanitizeLocalSuggestions(
        candidates: List<String>,
        lyrics: String,
        onDecision: ((LocalSuggestionDecision) -> Unit)? = null,
        seen: MutableSet<String> = mutableSetOf()
    ): List<String> {
        val existingLines = lyrics.lines()
            .map { normalizeSuggestionKey(it) }
            .filter { it.isNotEmpty() }
            .toSet()

        return candidates
            .flatMap { it.lines() }
            .mapNotNull { rawLine ->
                val cleaned = cleanLocalSuggestionLine(rawLine)
                val key = cleaned?.let(::normalizeSuggestionKey).orEmpty()
                val disposition = when {
                    cleaned == null || key.isEmpty() -> "format"
                    key in existingLines -> "existing_lyric"
                    !seen.add(key) -> "duplicate"
                    else -> "accepted"
                }
                onDecision?.invoke(LocalSuggestionDecision(rawLine, cleaned, disposition))
                cleaned.takeIf { disposition == "accepted" }
            }
    }

    private fun cleanLocalSuggestionLine(line: String): String? {
        if (containsMarkupOrControlLeakage(line)) return null
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

    private fun canonicalWordKey(text: String): String = text.trim().lowercase()

    private fun isKnownSingleWord(
        word: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): Boolean {
        val key = canonicalWordKey(word)
        return word.length <= 32 &&
            isSingleWordSelection(word) &&
            key.isNotEmpty() &&
            key == ProsodyAnalyzer.normalizeWord(word) &&
            dictionary.pronunciations(key).isNotEmpty()
    }

    private fun containsMarkupOrControlLeakage(text: String): Boolean =
        markupOrControlLeakagePattern.containsMatchIn(text)
}
