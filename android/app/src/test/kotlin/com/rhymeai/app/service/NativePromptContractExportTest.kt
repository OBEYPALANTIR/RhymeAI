package com.rhymeai.app.service

import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class NativePromptContractExportTest {
    private val json = Json { prettyPrint = true }
    private val compactJson = Json
    private val service = AIService()
    private val sourceSha by lazy(::currentSourceSha)

    @Test
    fun exportsProductionPromptBuildersByteForByte() {
        val lyrics = "[Verse]\nYellow lights on a midnight road\nStatic in the dashboard glow"
        val records = listOf(
            contract(
                caseId = "android_suggestions_aabb",
                requestKind = "suggestions",
                controls = buildJsonObject {
                    put("theme", "late-night resolve")
                    put("rhymeType", "slant")
                    put("rhymeScheme", "AABB")
                    put("currentLetter", "A")
                    put("section", "verse")
                    put("complexity", "moderate")
                    put("useWholeSongContext", false)
                    put("requestCount", 6)
                },
                localContext = buildJsonObject {
                    put("lyrics", lyrics)
                    put("targetRhymeLine", "Yellow lights on a midnight road")
                },
                userText = service.buildLocalSuggestionUserPrompt(
                    theme = "late-night resolve",
                    lyrics = lyrics,
                    targetRhymeLine = "Yellow lights on a midnight road",
                    rhymeType = RhymeType.SLANT,
                    rhymeScheme = "AABB",
                    currentLetter = "A",
                    currentSection = SongSection.VERSE,
                    complexity = RhymeComplexity.MODERATE,
                    useWholeSongContext = false
                ),
                renderedText = service.buildLocalPrompt(
                    theme = "late-night resolve",
                    lyrics = lyrics,
                    targetRhymeLine = "Yellow lights on a midnight road",
                    rhymeType = RhymeType.SLANT,
                    rhymeScheme = "AABB",
                    currentLetter = "A",
                    currentSection = SongSection.VERSE,
                    complexity = RhymeComplexity.MODERATE,
                    useWholeSongContext = false
                )
            ),
            contract(
                caseId = "android_rewrite_passage",
                requestKind = "rewrite_passage",
                controls = buildJsonObject {
                    put("action", "rephrase")
                    put("section", "verse")
                },
                localContext = buildJsonObject {
                    put("lyrics", lyrics)
                    put("selection", "Static in the dashboard glow")
                },
                userText = service.buildLocalRewriteUserPrompt(
                    RewriteAction.REPHRASE,
                    lyrics,
                    "Static in the dashboard glow",
                    SongSection.VERSE
                ),
                renderedText = service.buildLocalRewritePrompt(
                    RewriteAction.REPHRASE,
                    lyrics,
                    "Static in the dashboard glow",
                    SongSection.VERSE
                )
            ),
            contract(
                caseId = "android_rewrite_word_exclusion",
                requestKind = "rewrite_word",
                controls = buildJsonObject {
                    put("action", "rephrase")
                    put("section", "verse")
                    put("rejectedCandidates", buildJsonArray { add(JsonPrimitive("gleam")) })
                },
                localContext = buildJsonObject {
                    put("lyrics", lyrics)
                    put("selection", "glow")
                    put("selectionStart", lyrics.indexOf("glow"))
                },
                userText = service.buildLocalRewriteUserPrompt(
                    RewriteAction.REPHRASE,
                    lyrics,
                    "glow",
                    SongSection.VERSE,
                    lyrics.indexOf("glow"),
                    setOf("gleam")
                ),
                renderedText = service.buildLocalRewritePrompt(
                    RewriteAction.REPHRASE,
                    lyrics,
                    "glow",
                    SongSection.VERSE,
                    lyrics.indexOf("glow"),
                    setOf("gleam")
                )
            ),
            contract(
                caseId = "android_synonyms_glow",
                requestKind = "synonyms",
                controls = buildJsonObject { put("limit", 6) },
                localContext = buildJsonObject {
                    put("word", "glow")
                    put("lineContext", "Static in the dashboard glow")
                },
                userText = service.buildLocalSynonymsUserPrompt("glow", "Static in the dashboard glow", 6),
                renderedText = service.buildLocalSynonymsPrompt("glow", "Static in the dashboard glow", 6)
            )
        )

        val output = File("build/native-contract-v1/android-smoke-input.jsonl")
        output.parentFile?.mkdirs()
        output.writeText(records.joinToString("\n") { compactJson.encodeToString(it) } + "\n")
        assertTrue(output.isFile)
        println("ANDROID_NATIVE_CONTRACT=${output.absolutePath}")
        println(json.encodeToString(records.first()))
    }

    @Test
    fun exportsSharedManifestThroughProductionBuilders() {
        val manifestFile = System.getenv("RHYME_NATIVE_CASE_MANIFEST")?.let(::File)
            ?: File("../../finetune/eval/native-contract-cases-v1.json")
        assertTrue(
            manifestFile.isFile,
            "Shared native case manifest not found at ${manifestFile.absolutePath}"
        )
        val manifest = json.parseToJsonElement(manifestFile.readText()).jsonObject
        val records = manifest.getValue("cases").jsonArray.map { element ->
            val case = element.jsonObject
            val request = case.getValue("request").jsonObject
            val controls = request.getValue("controls").jsonObject
            val localContext = request.getValue("localContext").jsonObject
            val caseId = case.getValue("caseId").jsonPrimitive.content
            val requestKind = case.getValue("requestKind").jsonPrimitive.content
            val (userText, renderedText) = when (requestKind) {
                "suggestions" -> {
                    val lyrics = localContext.getValue("lyrics").jsonPrimitive.content
                    val theme = controls.getValue("theme").jsonPrimitive.content
                    val target = controls.getValue("targetRhymeLine").jsonPrimitive.contentOrNull
                    val rhymeType = RhymeType.valueOf(controls.getValue("rhymeType").jsonPrimitive.content)
                    val rhymeScheme = controls.getValue("rhymeScheme").jsonPrimitive.content
                    val currentLetter = controls.getValue("currentLetter").jsonPrimitive.content
                    val section = SongSection.valueOf(controls.getValue("currentSection").jsonPrimitive.content)
                    val complexity = RhymeComplexity.valueOf(controls.getValue("complexity").jsonPrimitive.content)
                    val wholeSong = controls.getValue("useWholeSongContext").jsonPrimitive.boolean
                    service.buildLocalSuggestionUserPrompt(
                        theme, lyrics, target, rhymeType, rhymeScheme, currentLetter, section, complexity, wholeSong
                    ) to service.buildLocalPrompt(
                        theme, lyrics, target, rhymeType, rhymeScheme, currentLetter, section, complexity, wholeSong
                    )
                }
                "rewrite_passage", "rewrite_word" -> {
                    val lyrics = localContext.getValue("lyrics").jsonPrimitive.content
                    val selection = localContext.getValue("selection").jsonPrimitive.content
                    val action = RewriteAction.valueOf(controls.getValue("action").jsonPrimitive.content)
                    val section = localContext["currentSection"]?.jsonPrimitive?.content
                        ?.let(SongSection::valueOf) ?: SongSection.VERSE
                    val selectionStart = lyrics.indexOf(selection).takeIf { it >= 0 }
                    val rejected = controls["rejectedCandidates"]?.jsonArray
                        ?.map { it.jsonPrimitive.content }?.toSet().orEmpty()
                    service.buildLocalRewriteUserPrompt(
                        action, lyrics, selection, section, selectionStart, rejected
                    ) to service.buildLocalRewritePrompt(
                        action, lyrics, selection, section, selectionStart, rejected
                    )
                }
                "synonyms" -> {
                    val word = localContext.getValue("word").jsonPrimitive.content
                    val line = localContext.getValue("lineContext").jsonPrimitive.content
                    val limit = controls.getValue("limit").jsonPrimitive.int
                    service.buildLocalSynonymsUserPrompt(word, line, limit) to
                        service.buildLocalSynonymsPrompt(word, line, limit)
                }
                else -> error("Unknown native request kind: $requestKind")
            }
            contract(caseId, requestKind, controls, localContext, userText, renderedText)
        }

        assertEquals(12, records.size)
        val output = File("build/native-contract-v1/android-input.jsonl")
        output.parentFile?.mkdirs()
        output.writeText(records.joinToString("\n") { compactJson.encodeToString(it) } + "\n")
        println("ANDROID_NATIVE_CONTRACT=${output.absolutePath} records=${records.size}")
        println(json.encodeToString(records.first()))
    }

    private fun currentSourceSha(): String {
        val repoRoot = File("../../").canonicalFile
        val process = ProcessBuilder("git", "rev-parse", "HEAD")
            .directory(repoRoot)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().use { it.readText() }.trim()
        check(process.waitFor() == 0) { "Unable to resolve producer commit: $output" }
        check(output.matches(Regex("[0-9a-f]{40}"))) { "Invalid producer commit: $output" }
        System.getenv("RHYME_NATIVE_SOURCE_SHA")?.let { configured ->
            check(configured == output) {
                "RHYME_NATIVE_SOURCE_SHA $configured does not match checked-out producer commit $output"
            }
        }
        return output
    }

    private fun contract(
        caseId: String,
        requestKind: String,
        controls: JsonObject,
        localContext: JsonObject,
        userText: String,
        renderedText: String
    ): JsonObject {
        assertEquals(userText, renderedText)
        val catalogModel = com.rhymeai.app.ui.components.GEMMA_DOWNLOADS.first()
        val productionRenderedText = userText
        val modelSha = System.getenv("RHYME_NATIVE_MODEL_SHA256")
            ?: catalogModel.sha256
        val capturedAt = System.getenv("RHYME_NATIVE_CAPTURED_AT") ?: Instant.now().toString()
        return buildJsonObject {
            put("schemaVersion", 1)
            put("platform", "android")
            put("sourceSha", sourceSha)
            put("modelSha256", modelSha)
            put("caseId", caseId)
            put("requestKind", requestKind)
            put("request", buildJsonObject {
                put("controls", controls)
                put("localContext", localContext)
            })
            put("prompt", buildJsonObject {
                put("userText", userText)
                put("renderedText", productionRenderedText)
                put("userTextSha256", sha256(userText))
                put("renderedTextSha256", sha256(productionRenderedText))
                put("tokenizerArchitecture", catalogModel.architecture)
                put("tokenizerEnvelope", "nativeTemplatePending")
                put("tokenizerChatTemplateSha256", catalogModel.chatTemplateSha256)
                put("tokenization", buildJsonObject {
                    put("addSpecial", true)
                    put("parseSpecial", true)
                })
            })
            put("generation", generation())
            put("runtime", buildJsonObject {
                put("target", System.getenv("RHYME_NATIVE_TARGET") ?: "Android contract export")
                put("osVersion", System.getenv("RHYME_NATIVE_OS_VERSION") ?: "not-run")
                put("buildVariant", "Debug")
                put("evidenceKind", "contractInput")
                put("capturedAt", capturedAt)
            })
        }
    }

    private fun generation(): JsonObject = buildJsonObject {
        put("engine", buildJsonObject {
            put("name", "llama.cpp via vendored kotlinllamacpp")
            put("version", LOCAL_MODEL_ENGINE_VERSION)
        })
        put("contextLength", LocalModelService.CONTEXT_LENGTH)
        put("sampler", buildJsonObject {
            put("chain", buildJsonArray {
                add(algorithm("topK", buildJsonObject { put("k", LocalModelService.TOP_K) }))
                add(algorithm("topP", buildJsonObject {
                    put("p", LocalModelService.TOP_P)
                    put("minimumKeep", 1)
                }))
                add(algorithm("temperature", buildJsonObject { put("value", LocalModelService.TEMPERATURE) }))
                add(algorithm("distribution", buildJsonObject {}))
            })
            put("seed", buildJsonObject {
                put("policy", "engineDefault")
                put("value", LocalModelService.SEED)
            })
        })
        put("termination", buildJsonObject {
            put("stopOnEog", !LocalModelService.IGNORE_EOS)
            put("stopSequences", JsonArray(emptyList()))
            put("maximumOutputTokens", JsonNull)
            put("maximumResponseLength", LocalModelService.MAX_RESPONSE_CHARS)
            put("responseLengthUnit", "utf16CodeUnits")
            put("deadlineMs", LocalModelService.GENERATION_TIMEOUT_MS)
            put("reason", "notRun")
        })
        put("cache", buildJsonObject {
            put("clearKvBeforeRequest", false)
            put("promptCache", true)
            put("state", "cold")
        })
    }

    private fun algorithm(name: String, parameters: JsonObject): JsonObject = buildJsonObject {
        put("algorithm", name)
        put("parameters", parameters)
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { byte -> "%02x".format(byte) }
}
