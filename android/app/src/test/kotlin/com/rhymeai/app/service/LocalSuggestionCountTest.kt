package com.rhymeai.app.service

import com.rhymeai.app.SuggestedLine
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.util.PronunciationDictionary
import java.io.File
import java.security.MessageDigest
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class LocalSuggestionCountTest {
    private val service = AIService()
    private val lines = listOf(
        "The ropes drip water on the train",
        "A gull cries out above the chain",
        "The boats lean out beyond the pane",
        "Your footsteps leave a fading stain",
        "The tide climbs slowly up the drain",
        "The windows face a narrow lane",
        "I trace your name to ease the pain",
        "The morning warms the sacks of grain"
    )
    private val dictionary = PronunciationDictionary.fromLines(
        sequenceOf("rain\tR EY1 N", "chain\tCH EY1 N", "drain\tD R EY1 N",
            "train\tT R EY1 N", "pane\tP EY1 N", "stain\tS T EY1 N",
            "lane\tL EY1 N", "pain\tP EY1 N", "grain\tG R EY1 N")
    )
    private val constraint = AIService.SuggestionRhymeConstraint(
        "I wait beneath the rain", "rain", emptyList(), RhymeType.PERFECT, dictionary
    )

    private data class Capture(
        val decisions: List<AIService.LocalSuggestionDecision>,
        val displayed: List<String>,
        val error: Throwable?
    )

    // Only synthetic test inputs enter these files; production has no capture sink.
    private fun persist(
        name: String, raw: String, chunks: List<String>, capture: Capture,
        constrained: Boolean = false, cloud: Boolean = false
    ) {
        val source = File("src/main/kotlin/com/rhymeai/app/service/AIService.kt")
        val process = ProcessBuilder("git", "rev-parse", "HEAD").start()
        val head = process.inputStream.bufferedReader().readText().trim()
        check(process.waitFor() == 0)
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(source.readBytes()).joinToString("") { "%02x".format(it) }
        val activeConstraint = constraint.takeIf { constrained }
        val prompt = if (cloud) service.buildPrompt(
            "harbor", "Existing lyric", activeConstraint?.targetLine,
            RhymeType.PERFECT, "AABB", "B", complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = true, constraint = activeConstraint
        ) else service.buildLocalPrompt(
            "harbor", "Existing lyric", activeConstraint?.targetLine,
            RhymeType.PERFECT, "AABB", "B", complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = true, constraint = activeConstraint
        )
        val report = buildJsonObject {
            put("sourceHead", head)
            put("serviceSha256", digest)
            put("kind", "synthetic_production_parser_replay_no_inference")
            put("provider", if (cloud) "cloud" else "local")
            put("constrained", constrained)
            put("requestedCandidateCount", if (cloud && constrained) 12 else 6)
            put("requestedDisplayCount", 6)
            put("prompt", prompt)
            put("acceptedCount", capture.decisions.count { it.disposition == "accepted" })
            put("rawResponse", raw)
            put("chunks", JsonArray(chunks.map(::JsonPrimitive)))
            put("decisions", JsonArray(capture.decisions.map { event -> buildJsonObject {
                put("rawLine", event.rawLine)
                put("candidate", event.candidate)
                put("disposition", event.disposition)
            } }))
            put("displayed", JsonArray(capture.displayed.map(::JsonPrimitive)))
            put("errorType", capture.error?.javaClass?.name)
            put("error", capture.error?.message)
        }
        val directory = File(System.getenv("RHYME_COUNT_EVIDENCE_DIR") ?: "build/local-count-repro")
        check(directory.isDirectory || directory.mkdirs())
        val output = File.createTempFile("$name-", ".json", directory)
        output.writeText(report.toString() + "\n")
        println("LOCAL_COUNT_EVIDENCE=${output.absolutePath}")
    }

    private suspend fun stream(name: String, chunks: List<String>, constrained: Boolean = false): Capture {
        val decisions = mutableListOf<AIService.LocalSuggestionDecision>()
        val displayed = mutableListOf<String>()
        val error = runCatching {
            service.validatedLocalSuggestionStream(
                flowOf(*chunks.toTypedArray()), "Existing lyric", constraint.takeIf { constrained },
                onDecision = { decisions += it }
            ).collect { displayed += it.text }
        }.exceptionOrNull()
        return Capture(decisions, displayed, error).also {
            persist(name, chunks.joinToString(""), chunks, it, constrained)
        }
    }

    private fun batch(name: String, raw: String, constrained: Boolean = false): Capture {
        val decisions = mutableListOf<AIService.LocalSuggestionDecision>()
        var displayed = emptyList<String>()
        val error = runCatching {
            displayed = service.validateLocalSuggestionResponse(
                raw, "Existing lyric", constraint.takeIf { constrained }, onDecision = { decisions += it }
            )
        }.exceptionOrNull()
        return Capture(decisions, displayed, error).also { persist(name, raw, listOf(raw), it, constrained) }
    }

    @Test
    fun sixValidLinesPassAndExcessValidLinesFailBeforeSuccess() = runBlocking {
        val allRuns = mutableListOf<Pair<Int, Capture>>()
        for (constrained in listOf(false, true)) {
            for (count in listOf(6, 8)) {
                val raw = lines.take(count).joinToString("\n")
                val runs = listOf(
                    stream("stream-$constrained-$count", listOf(raw), constrained),
                    batch("batch-$constrained-$count", raw, constrained),
                    batch("json-$constrained-$count", JsonArray(lines.take(count).map(::JsonPrimitive)).toString(), constrained)
                )
                allRuns += runs.map { count to it }
            }
        }
        for ((count, capture) in allRuns) {
            assertEquals(count, capture.decisions.count { it.disposition == "accepted" })
            if (count == 6) {
                assertEquals(null, capture.error)
                assertEquals(6, capture.displayed.size)
            } else {
                assertNotNull(capture.error)
                assertTrue(capture.displayed.size <= 6)
            }
        }
    }

    @Test
    fun chunkBoundariesDuplicatesAndRejectedLinesDoNotChangeExactCount() = runBlocking {
        val raw = (listOf("Existing lyric", lines[0], lines[0], "", "Here are your suggestions:") + lines.drop(1)).joinToString("\n")
        // Keep all outcomes before asserting so a baseline failure cannot hide another partition.
        val runs = listOf(
            stream("whole-response", listOf(raw)),
            stream("character-chunks", raw.map(Char::toString)),
            stream("newline-chunks", raw.split("\n").map { "$it\n" })
        )
        for (capture in runs) {
            assertNotNull(capture.error)
            assertEquals(8, capture.decisions.count { it.disposition == "accepted" })
            assertTrue(capture.decisions.any { it.disposition == "duplicate" })
            assertTrue(capture.decisions.any { it.disposition == "existing_lyric" })
            assertTrue(capture.decisions.any { it.disposition == "format" })
        }
        val sixWithRejections = (listOf("Existing lyric", lines[0], lines[0], "") + lines.subList(1, 6)).joinToString("\n")
        val good = stream("six-with-rejections", listOf(sixWithRejections))
        assertEquals(null, good.error)
        assertEquals(lines.take(6), good.displayed)
    }

    @Test
    fun cancellationStopsConsumptionAndDoesNotBecomeCountFailure() = runBlocking {
        var upstreamReleased = false
        val chunks = mutableListOf<String>()
        val decisions = mutableListOf<AIService.LocalSuggestionDecision>()
        val displayed = mutableListOf<String>()
        val error = runCatching {
            service.validatedLocalSuggestionStream(flow {
                try {
                    for (line in lines) {
                        val chunk = "$line\n"
                        chunks += chunk
                        emit(chunk)
                    }
                } finally { upstreamReleased = true }
            }, "", onDecision = { decisions += it }).take(1).collect { displayed += it.text }
        }.exceptionOrNull()
        persist("cancellation", chunks.joinToString(""), chunks, Capture(decisions, displayed, error))
        assertEquals(null, error)
        assertTrue(upstreamReleased)
        assertEquals(1, chunks.size)
        assertEquals(lines.take(1), displayed)
    }

    @Test
    fun cloudTwelveCandidateContractStillDisplaysSix() = runBlocking {
        val localPrompt = service.buildLocalPrompt("harbor", "Existing lyric", constraint.targetLine,
            RhymeType.PERFECT, "AABB", "B", complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = true, constraint = constraint)
        val cloudPrompt = service.buildPrompt("harbor", "Existing lyric", constraint.targetLine,
            RhymeType.PERFECT, "AABB", "B", complexity = RhymeComplexity.MODERATE,
            useWholeSongContext = true, constraint = constraint)
        val raw = ((1..6).map { "Harbor image $it fades into night" } + lines.take(6)).joinToString("\n")
        val decisions = mutableListOf<AIService.LocalSuggestionDecision>()
        val displayed = mutableListOf<String>()
        val error = runCatching {
            flow<SuggestedLine> {
                with(service) { emitLinesFromTokens(flowOf(raw), constraint, onDecision = { decisions += it }) }
            }.collect { displayed += it.text }
        }.exceptionOrNull()
        persist("cloud-twelve", raw, listOf(raw), Capture(decisions, displayed, error), constrained = true, cloud = true)
        assertContains(localPrompt, "write exactly 6 next-line options")
        assertContains(cloudPrompt, "Provide 12 creative")
        assertEquals(null, error)
        assertEquals(lines.take(6), displayed)
    }
}
