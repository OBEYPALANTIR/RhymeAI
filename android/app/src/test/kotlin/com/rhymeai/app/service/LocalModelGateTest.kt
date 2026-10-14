package com.rhymeai.app.service

import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.util.PronunciationDictionary
import com.rhymeai.app.util.SectionMap
import com.rhymeai.app.util.WordFrequency
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import java.io.File
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URI
import java.security.MessageDigest
import org.junit.Assume.assumeTrue
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Promoted from the 2026-10-13 replay: only the JNI transport is replaced by llama-server. */
class LocalModelGateTest {
    private val root by lazy { File(requireNotNull(System.getenv("RHYMEAI_GATE_INPUT"))) }
    private val repo by lazy { File(requireNotNull(System.getenv("RHYMEAI_GATE_REPO"))) }
    private val service = AIService()
    private fun JsonObject.str(key: String) = getValue(key).jsonPrimitive.content
    private fun JsonObject.nullString(key: String) = get(key)?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
    private fun digest(text: String) = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
    private fun strings(xs: List<String>) = JsonArray(xs.map(::JsonPrimitive))
    private fun records(name: String) = Json.parseToJsonElement(File(root, name).readText()).jsonArray

    private fun initialize(phase: String) {
        assumeTrue("Offline: RHYMEAI_GATE_INPUT is unset", !System.getenv("RHYMEAI_GATE_INPUT").isNullOrBlank())
        assumeTrue(System.getenv("RHYMEAI_GATE_PHASE") == phase)
        File(repo, "shared/pronunciation/cmudict-rhymeai.tsv").inputStream().use(PronunciationDictionary::initialize)
        File(repo, "shared/pronunciation/word-frequency.txt").inputStream().use(WordFrequency.shared::initialize)
        assertTrue(PronunciationDictionary.shared.wordCount > 100_000)
    }

    private fun constraint(r: JsonObject): AIService.SuggestionRhymeConstraint? {
        if (r.str("task") != "suggestions") return null
        val c = r.getValue("inputs").jsonObject
        val section = c["section"]?.takeUnless { it is JsonNull }?.jsonArray
        val ref = section?.let { wanted -> SectionMap.parse(c.str("lyrics")).allSections.first {
            it.type.name == wanted[0].jsonPrimitive.content && it.ordinal == wanted[1].jsonPrimitive.int
        } }
        return service.suggestionRhymeConstraint(c.nullString("target_rhyme_line"), RhymeType.valueOf(c.str("rhyme_type")),
            PronunciationDictionary.shared, ref, service.firstChorusEndWords(c.str("lyrics")), RhymeComplexity.valueOf(c.str("complexity")))
    }

    private fun rejected(c: JsonObject) = c["rejected_candidates"]?.jsonArray?.map { it.jsonPrimitive.content }?.toSet() ?: emptySet()

    private fun prompt(r: JsonObject, rejects: Set<String>? = null): String {
        val c = r.getValue("inputs").jsonObject
        return when (r.str("task")) {
            "suggestions" -> service.buildLocalPrompt(theme=c.str("theme"), lyrics=c.str("lyrics"),
                targetRhymeLine=c.nullString("target_rhyme_line"), rhymeType=RhymeType.valueOf(c.str("rhyme_type")),
                rhymeScheme=c.str("rhyme_scheme"), currentLetter=c.str("current_letter"),
                currentSection=SongSection.valueOf(c.str("current_section")), complexity=RhymeComplexity.valueOf(c.str("complexity")),
                useWholeSongContext=c.getValue("use_whole_song_context").jsonPrimitive.boolean, constraint=constraint(r),
                cursorLine=c.getValue("cursor_line").jsonPrimitive.int)
            "rewrite_passage", "rewrite_word" -> service.buildLocalRewritePrompt(
                RewriteAction.valueOf(c.str("action")), c.str("lyrics"), c.str("selection"),
                SongSection.valueOf(c.str("current_section")), c.getValue("selection_start").jsonPrimitive.int, rejects ?: rejected(c))
            "synonyms" -> service.buildLocalSynonymsPrompt(c.str("word"), c.str("line_context"), c.getValue("limit").jsonPrimitive.int)
            else -> error("Unknown gate task")
        }
    }

    @Test
    fun promptParity() {
        initialize("parity")
        val frozen = File(root, "prompts.json").takeIf { it.exists() }?.let {
            records("prompts.json").associate { el -> el.jsonObject.str("id") to el.jsonObject }
        }
        val output = records("inputs.json").map { el ->
            val r = el.jsonObject
            val actual = prompt(r)
            frozen?.getValue(r.str("id"))?.let { assertEquals(it.str("prompt"), actual, r.str("id")) }
            buildJsonObject {
                put("id", r.str("id")); put("prompt", actual); put("prompt_sha256", digest(actual))
                put("candidate_words", constraint(r)?.candidateWords?.let(::strings) ?: JsonNull)
                put("frozen_byte_parity", frozen != null)
            }
        }
        File(root, "parity.jsonl").writeText(output.joinToString("\n", postfix="\n"))
        assertEquals(records("inputs.json").size, output.size)
    }

    private data class CapturedPass(val data: JsonObject)

    private fun completion(r: JsonObject, model: String, seed: Int, pass: Int, inner: String, captured: MutableList<CapturedPass>): Flow<String> = flow {
        val config = Json.parseToJsonElement(File(root,"sampler.json").readText()).jsonObject
        val samplerSeed = seed + (System.getenv("RHYMEAI_GATE_SEED_OFFSET")?.toInt() ?: 0) + (pass - 1) * 10000
        val request = JsonObject(config + mapOf(
            "prompt" to JsonPrimitive("<|turn>user\n$inner<turn|>\n<|turn>model\n"), "seed" to JsonPrimitive(samplerSeed),
            "stream" to JsonPrimitive(true), "cache_prompt" to JsonPrimitive(false)))
        val started = System.nanoTime()
        val deadline = started + 120_000_000_000L
        val chunks = mutableListOf<JsonElement>()
        val bounded = mutableListOf<String>()
        var end = "eof"
        var failure: String? = null
        var lastPayload: JsonObject? = null
        val boundary = GenerationBoundary(listOf("<turn|>"),LocalModelService.MAX_RESPONSE_CHARS)
        val connection = URI("http://127.0.0.1:${System.getenv("RHYMEAI_GATE_PORT")}/completion").toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod="POST"; connection.doOutput=true; connection.connectTimeout=10000
            connection.readTimeout=120000; connection.setRequestProperty("Content-Type","application/json")
            connection.outputStream.use { it.write(request.toString().toByteArray()) }
            check(connection.responseCode==200) { "llama-server HTTP ${connection.responseCode}" }
            connection.inputStream.bufferedReader().use { reader ->
                while (true) {
                    val remaining = (deadline-System.nanoTime())/1_000_000
                    if (remaining<=0) throw SocketTimeoutException("120-second generation deadline")
                    connection.readTimeout=remaining.coerceAtMost(120000).toInt().coerceAtLeast(1)
                    val line = reader.readLine() ?: break
                    if (!line.startsWith("data: ")) continue
                    val data = line.removePrefix("data: ")
                    if (data=="[DONE]") break
                    val payload = Json.parseToJsonElement(data).jsonObject
                    check(payload["error"]==null) { "llama-server returned an error: ${payload["error"]}" }
                    lastPayload=payload
                    val chunk=payload["content"]?.jsonPrimitive?.content.orEmpty()
                    if (chunk.isNotEmpty()) {
                        chunks += buildJsonObject { put("text",chunk); put("elapsed_ms",(System.nanoTime()-started)/1_000_000) }
                        val accepted = boundary.accept(chunk)
                        if (accepted.text.isNotEmpty()) { bounded += accepted.text; emit(accepted.text) }
                        if (accepted.terminationReason!=null) { end=accepted.terminationReason; break }
                    }
                    if (payload["stop"]?.jsonPrimitive?.booleanOrNull==true) { end="server_stop"; break }
                }
            }
            val tail=boundary.finish()
            if (tail.text.isNotEmpty()) { bounded+=tail.text; emit(tail.text) }
        } catch (e: CancellationException) {
            end="android_line_or_display_cap"
            throw e
        } catch (e: SocketTimeoutException) {
            end="deadline"; failure="Local model took too long to respond. Try Gemma E2B or shorten the lyric context."
            throw IllegalStateException(failure,e)
        } catch (e: Exception) {
            end="exception"; failure=e.message ?: e.javaClass.simpleName
            throw e
        } finally {
            connection.disconnect()
            val data = buildJsonObject {
                put("model",model); put("id",r.str("id")); put("pass",pass); put("seed",seed); put("sampler_seed",samplerSeed)
                put("prompt",inner); put("prompt_sha256",digest(inner)); put("wrapped_prompt_sha256",digest(request.str("prompt")))
                put("request",request); put("raw_chunks",JsonArray(chunks)); put("bounded_chunks",strings(bounded))
                put("output",bounded.joinToString("")); put("termination",end); put("error",failure?.let(::JsonPrimitive) ?: JsonNull)
                put("elapsed_ms",(System.nanoTime()-started)/1_000_000); put("last_server_payload",lastPayload ?: JsonNull)
            }
            captured += CapturedPass(data)
            File(root,"raw-$model.jsonl").appendText(data.toString()+"\n")
        }
    }

    private suspend fun replay(r: JsonObject, tokens: (String) -> Flow<String>): JsonObject {
        val c = r.getValue("inputs").jsonObject
        val shown = mutableListOf<String>()
        val decisions = mutableListOf<JsonElement>()
        var failure: String? = null
        var calls = 0
        suspend fun raw(inner: String): String {
            calls++
            val output = StringBuilder()
            tokens(inner).collect { output.append(it) }
            return output.toString()
        }
        try {
            when (r.str("task")) {
                "suggestions" -> service.validatedLocalSuggestionStream(
                    { calls++; tokens(prompt(r)) }, c.str("lyrics"), constraint(r)) { d ->
                    decisions += buildJsonObject {
                        put("raw", d.rawLine); put("cleaned", d.candidate?.let(::JsonPrimitive) ?: JsonNull); put("disposition", d.disposition)
                    }
                }.collect { shown += it.text }
                "rewrite_passage" -> {
                    val parsed = service.cleanLocalRewrite(raw(prompt(r)), c.str("selection"))
                    check(parsed.isNotBlank()) { "Local model returned no valid changed rewrite." }
                    shown += parsed.lines()
                }
                "rewrite_word" -> {
                    val selection = c.str("selection")
                    val action = RewriteAction.valueOf(c.str("action"))
                    val context = service.singleWordRewriteContext(c.str("lyrics"), selection, c.getValue("selection_start").jsonPrimitive.int)
                    val rejects = (rejected(c) + selection).map { it.trim().lowercase() }.toMutableSet()
                    // Mirrors callLocalRewrite's two-attempt transport loop; validation and prompts stay in AIService.
                    for (attempt in 1..2) {
                        val parsed = service.cleanLocalRewrite(raw(prompt(r, rejects)), selection)
                        val accepted = service.acceptLocalSingleWordRewrite(parsed, selection, action, context, rejects)
                        if (accepted.isNotBlank()) { shown += accepted; break }
                        parsed.trim().lowercase().takeIf { it.isNotBlank() }?.let { rejects += it }
                    }
                    check(shown.isNotEmpty()) { "Local model returned no valid replacement." }
                }
                "synonyms" -> {
                    shown += service.extractSynonyms(raw(prompt(r)), c.str("word")).take(c.getValue("limit").jsonPrimitive.int)
                    check(shown.isNotEmpty()) { "Local model returned no valid synonyms." }
                }
            }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { failure = e.message ?: e.javaClass.simpleName }
        return buildJsonObject {
            for (key in listOf("id", "song_id", "task", "level", "rhyme_type")) put(key, r.getValue(key))
            put("calls", calls); put("error", failure?.let(::JsonPrimitive) ?: JsonNull)
            put("shown_count", shown.size); put("shown_lines", strings(shown)); put("decisions", JsonArray(decisions))
            put("category", if (failure != null) "error" else if (shown.size == 6) "6" else "accepted")
        }
    }

    @Test
    fun generateAndReplay() = runBlocking {
        initialize("generate")
        val model = requireNotNull(System.getenv("RHYMEAI_GATE_MODEL"))
        val resultFile = File(root, "replay-$model.jsonl")
        val done = if (resultFile.exists()) resultFile.readLines().filter { it.isNotBlank() }.map {
            val r = Json.parseToJsonElement(it).jsonObject
            r.str("id") + "#" + r.str("seed")
        }.toSet() else emptySet()
        val rows = records("prompts.json")
        val seeds = Json.parseToJsonElement(File(root, "benchmark.json").readText()).jsonObject.getValue("seeds").jsonArray
        for (seedValue in seeds) {
            val seed = seedValue.jsonPrimitive.int
            rows.forEachIndexed { index, el ->
                val r = el.jsonObject
                if (r.str("id") + "#" + seed in done) return@forEachIndexed
                assertEquals(r.str("prompt"), prompt(r), "Frozen prompt drift")
                val captured = mutableListOf<CapturedPass>()
                var pass = 0
                val live = replay(r) { inner -> completion(r, model, seed, ++pass, inner, captured) }
                assertTrue(pass in 1..2)
                var offlinePass = 0
                val offline = replay(r) { inner -> flow {
                    val p = captured[offlinePass++].data
                    assertEquals(p.str("prompt"), inner, "Retry prompt changed during replay")
                    p.getValue("bounded_chunks").jsonArray.forEach { emit(it.jsonPrimitive.content) }
                    p.nullString("error")?.let { throw IllegalStateException(it) }
                } }
                assertEquals(live, offline, "saved-output streaming replay: ${r.str("id")}")
                val result = JsonObject(live + mapOf("model" to JsonPrimitive(model), "seed" to seedValue,
                    "offline_replay_equal" to JsonPrimitive(true)))
                resultFile.appendText(result.toString() + "\n")
                File(root, "progress.json").writeText(buildJsonObject {
                    put("model", model); put("seed", seed); put("completed", index + 1); put("total", rows.size); put("id", r.str("id"))
                }.toString())
                println("GATE $model seed=$seed ${index + 1}/${rows.size} ${r.str("id")} ${live.str("category")}")
            }
        }
        assertEquals(rows.size * seeds.size, resultFile.readLines().count { it.isNotBlank() })
    }
}
