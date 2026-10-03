package com.rhymeai.app.service

import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.BuildConfig
import com.rhymeai.app.RhymeContextAnalyzer
import com.rhymeai.app.SuggestedLine
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.util.PronunciationDictionary
import com.rhymeai.app.util.WordFrequency
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.util.Collections
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalSyntheticCaptureInstrumentedTest {
    private data class Fixture(
        val id: String,
        val theme: String,
        val lyrics: String,
        val targetLine: String?,
        val rhymeType: RhymeType,
        val scheme: String,
        val letter: String,
        val section: SongSection
    )

    private data class Chunk(val elapsedNs: Long, val text: String)

    private val fixtures = listOf(
        Fixture(
            id = "contract_suggestions_targeted_stanza",
            theme = "city rain and returning home",
            lyrics = "[Verse]\nThe last train hums beneath my feet\n" +
                "Old names are fading from the street\n" +
                "The streetlights blur like stars against the rain",
            targetLine = "The streetlights blur like stars against the rain",
            rhymeType = RhymeType.PERFECT,
            scheme = "AABB",
            letter = "B",
            section = SongSection.VERSE
        ),
        Fixture(
            id = "synthetic_ui_rain_next_line",
            theme = "city rain and returning home",
            lyrics = "[Verse]\nThe last train hums beneath my feet\n" +
                "Old names are fading from the street\n" +
                "The streetlights blur like stars against the rain\n",
            targetLine = "The streetlights blur like stars against the rain",
            rhymeType = RhymeType.PERFECT,
            scheme = "AABB",
            letter = "B",
            section = SongSection.VERSE
        ),
        Fixture(
            id = "synthetic_unicode_moon_cafe",
            theme = "moonlit return",
            lyrics = "[Verse]\nThe moon 🌙 hangs over café streets",
            targetLine = null,
            rhymeType = RhymeType.NEAR,
            scheme = "ABAB",
            letter = "A",
            section = SongSection.VERSE
        )
    )

    @Test
    fun capturesNativeAndProductionParserForSyntheticFixtures() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        assumeTrue("Opt in with qaSyntheticCapture=true", args.getString("qaSyntheticCapture") == "true")
        assertTrue("Synthetic capture requires a debug APK", BuildConfig.DEBUG)
        val target = instrumentation.targetContext
        val seed = args.getString("qaSyntheticSeed")?.toIntOrNull() ?: 37
        assertTrue("A fixed nonnegative seed is required", seed >= 0)
        val targetSerial = args.getString("qaTargetSerial").orEmpty()
        assertTrue("Pass the explicit adb target as qaTargetSerial", targetSerial.isNotBlank())
        val model = File(target.filesDir, "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf")
        assertTrue("The catalog model must be in the app's root files directory", model.isFile)
        assertEquals(target.filesDir.canonicalFile, model.canonicalFile.parentFile)
        val modelSha = sha256(model)
        assertEquals(EXPECTED_MODEL_SHA, modelSha)
        if (PronunciationDictionary.shared.wordCount == 0) {
            target.assets.open("cmudict-rhymeai.tsv").use(PronunciationDictionary::initialize)
        }
        if (!WordFrequency.shared.isLoaded) {
            target.assets.open("word-frequency.txt").use(WordFrequency.shared::initialize)
        }
        val apkSha = sha256(File(target.applicationInfo.sourceDir))
        val outputDir = File(target.filesDir, "qa-synthetic-captures")
        assertTrue(outputDir.isDirectory || outputDir.mkdirs())

        val local = LocalModelService()
        local.initialize(target)
        try {
            local.loadModel(model.absolutePath)
            val failures = fixtures.flatMap { fixture ->
                captureFixture(fixture, seed, local, modelSha, apkSha,
                    targetSerial, outputDir)
            }
            assertTrue(failures.joinToString("; "), failures.isEmpty())
        } finally {
            local.unload()
        }
    }

    private suspend fun captureFixture(
        fixture: Fixture,
        seed: Int,
        local: LocalModelService,
        modelSha: String,
        apkSha: String,
        targetSerial: String,
        outputDir: File
    ): List<String> {
        val ai = AIService().also { it.localModelService = local }
        val context = RhymeContextAnalyzer.compute(fixture.lyrics, fixture.lyrics.length, fixture.scheme)
        val constraint = ai.suggestionRhymeConstraint(
            fixture.targetLine, fixture.rhymeType, sectionRef = context.currentSectionRef,
            chorusEndWords = ai.firstChorusEndWords(fixture.lyrics)
        )
        val prompt = ai.buildLocalPrompt(
            theme = fixture.theme, lyrics = fixture.lyrics, targetRhymeLine = fixture.targetLine,
            rhymeType = fixture.rhymeType, rhymeScheme = fixture.scheme,
            currentLetter = fixture.letter, currentSection = fixture.section,
            complexity = RhymeComplexity.MODERATE, useWholeSongContext = false,
            constraint = constraint
        )
        val native = Collections.synchronizedList(mutableListOf<Chunk>())
        val postBoundaryEmitted = Collections.synchronizedList(mutableListOf<Chunk>())
        val generationStartedAtNs = AtomicLong(0L)
        val promptSha = sha256(prompt.toByteArray(Charsets.UTF_8))
        val runId = UUID.randomUUID().toString()
        local.captureNextSyntheticRequestForTesting(SyntheticGenerationCapture(
            runId = runId,
            expectedPromptSha256 = promptSha,
            seed = seed,
            onNativeChunk = { text, elapsedNs -> native += Chunk(elapsedNs, text) },
            onParserChunk = { text, elapsedNs -> postBoundaryEmitted += Chunk(elapsedNs, text) },
            onGenerationStarted = generationStartedAtNs::set
        ))

        val displayed = mutableListOf<SuggestedLine>()
        val downstreamConsumed = mutableListOf<Chunk>()
        val priorMetrics = local.lastGenerationMetrics
        val startedUtc = Instant.now().toString()
        val productionError = runCatching {
            withTimeout(LocalModelService.GENERATION_TIMEOUT_MS + 15_000L) {
                ai.streamSuggestions(
                    provider = AIProvider.LOCAL, apiKey = "", modelId = AIModel.LOCAL_MODEL.id,
                    theme = fixture.theme, lyrics = fixture.lyrics,
                    targetRhymeLine = fixture.targetLine, rhymeType = fixture.rhymeType,
                    rhymeScheme = fixture.scheme, currentLetter = fixture.letter,
                    currentSection = fixture.section, complexity = RhymeComplexity.MODERATE,
                    useWholeSongContext = false, sectionRef = context.currentSectionRef,
                    fullLyrics = fixture.lyrics
                ).collect {
                    displayed += it
                    downstreamConsumed += Chunk(System.nanoTime() - generationStartedAtNs.get(), it.text)
                }
            }
        }.exceptionOrNull()

        val decisions = mutableListOf<AIService.LocalSuggestionDecision>()
        val replayDisplayed = mutableListOf<SuggestedLine>()
        val parserChunks = postBoundaryEmitted.toList()
        val replayError = runCatching {
            ai.validatedLocalSuggestionStream(
                flowOf(*parserChunks.map(Chunk::text).toTypedArray()), fixture.lyrics, constraint,
                onDecision = { decisions += it }
            ).collect { replayDisplayed += it }
        }.exceptionOrNull()

        val metrics = local.lastGenerationMetrics.takeIf { it !== priorMetrics }
        val report = buildJsonObject {
            put("kind", "synthetic_fixed_seed_native_and_production_parser")
            put("runId", runId)
            put("fixtureId", fixture.id)
            put("sharedManifestSha256", SHARED_MANIFEST_SHA.takeIf {
                fixture.id == "contract_suggestions_targeted_stanza" })
            put("startedUtc", startedUtc)
            put("generationStartedMonotonicNs", generationStartedAtNs.get())
            put("targetSerialArgument", targetSerial)
            put("deviceFingerprint", Build.FINGERPRINT)
            put("apkSha256", apkSha)
            put("modelFileName", "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf")
            put("modelSha256", modelSha)
            put("seed", seed)
            put("normalUiSeed", LocalModelService.SEED)
            put("theme", fixture.theme)
            put("lyrics", fixture.lyrics)
            put("targetRhymeLine", fixture.targetLine)
            put("prompt", prompt)
            put("promptSha256", promptSha)
            put("nativeCallbackArrivalChunks", chunksJson(native.toList()))
            put("postBoundaryServiceEmissionChunks", chunksJson(parserChunks))
            put("downstreamConsumedSuggestions", chunksJson(downstreamConsumed))
            put("nativeRawResponse", native.joinToString("") { it.text })
            put("postBoundaryServiceEmissionResponse", parserChunks.joinToString("") { it.text })
            put("unicodeChatFormatReachedGeneration", if (
                fixture.id == "synthetic_unicode_moon_cafe") metrics != null else null)
            put("decisionSource", "replay_of_post_boundary_service_emissions")
            put("decisions", JsonArray(decisions.map { decision -> buildJsonObject {
                put("rawLine", decision.rawLine)
                put("candidate", decision.candidate)
                put("disposition", decision.disposition)
            } }))
            put("acceptedCount", decisions.count { it.disposition == "accepted" })
            put("rejectedCount", decisions.count { it.disposition in
                setOf("format", "existing_lyric", "duplicate", "markup_or_control") })
            put("heldForRankingCount", decisions.count { it.disposition == "held_for_rhyme_ranking" })
            put("displayedDirectCount", decisions.count { it.disposition == "displayed" })
            put("rankedCount", decisions.count { it.disposition == "displayed_after_rhyme_ranking" })
            put("displayLimitCount", decisions.count { it.disposition == "display_limit" })
            put("productionDisplayed", suggestionsJson(displayed))
            put("replayDisplayed", suggestionsJson(replayDisplayed))
            put("productionErrorClass", productionError?.javaClass?.name)
            put("productionError", productionError?.message)
            put("replayErrorClass", replayError?.javaClass?.name)
            put("replayError", replayError?.message)
            put("replayMatchesProduction", replayDisplayed == displayed &&
                replayError?.javaClass?.name == productionError?.javaClass?.name &&
                replayError?.message == productionError?.message)
            put("terminationReason", metrics?.terminationReason)
            put("timeToFirstChunkMs", metrics?.timeToFirstChunkMs)
            put("totalDurationMs", metrics?.totalDurationMs)
            put("outputCharacters", metrics?.outputCharacters)
        }
        val output = File.createTempFile("${fixture.id}-", ".json", outputDir)
        output.writeText(report.toString() + "\n")
        println("SYNTHETIC_CAPTURE_FILE=${output.absolutePath}")

        return buildList {
            if (replayDisplayed != displayed) add("${fixture.id}: parser replay differs from production display")
            if (replayError?.javaClass?.name != productionError?.javaClass?.name ||
                replayError?.message != productionError?.message) {
                add("${fixture.id}: parser replay error differs from production error")
            }
            if (metrics == null) add("${fixture.id}: fresh native generation metrics missing")
        }
    }

    private fun chunksJson(chunks: List<Chunk>): JsonArray = JsonArray(chunks.map { chunk ->
        buildJsonObject {
            put("elapsedNs", chunk.elapsedNs)
            put("text", chunk.text)
        }
    })

    private fun suggestionsJson(lines: List<SuggestedLine>): JsonArray = JsonArray(lines.map { line ->
        buildJsonObject {
            put("text", line.text)
            put("rhymeTier", line.rhymeTier)
            put("isHook", line.isHook)
        }
    })

    private fun sha256(file: File): String = file.inputStream().buffered().use { input ->
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(1024 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
        digest.digest().joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }

    private fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }

    private companion object {
        const val EXPECTED_MODEL_SHA =
            "059e73281d764ba0d541470aabdbd89de84878263b67d50c6c3afbc292933626"
        const val SHARED_MANIFEST_SHA =
            "649b0a49e5a90626bf26ad6f66eb8b0979cd42992db5ff16ea51bf197e1acb2d"
    }
}
