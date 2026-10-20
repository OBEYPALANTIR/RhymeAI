package com.rhymeai.app.service

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.BuildConfig
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.nehuatl.llamacpp.LlamaContext

@RunWith(AndroidJUnit4::class)
class SamplingPenaltyNativeInstrumentedTest {
    @Test
    fun compiledSamplerRestoresModelPenaltiesAcrossRequests() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue("Opt in with qaSamplingTrace=true", args.getString("qaSamplingTrace") == "true")
        assertTrue("A debug APK is required", BuildConfig.DEBUG)
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val model = File(target.filesDir, "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf")
        assertTrue("The accepted E2B model is required", model.isFile)
        assertEquals(EXPECTED_MODEL_SHA, sha256(model))
        val apkSha = sha256(File(target.applicationInfo.sourceDir))

        // Keep one real model/context alive for all four requests. A new context per arm would
        // conceal settings left behind by the preceding request.
        target.contentResolver.openFileDescriptor(Uri.fromFile(model), "r")!!.use { fd ->
            val context = LlamaContext(
                1,
                mapOf(
                    "model" to Uri.fromFile(model).toString(),
                    "model_fd" to fd.fd,
                    "use_mmap" to true,
                    "use_mlock" to false,
                    "n_ctx" to 2048,
                    "n_batch" to 512,
                    "n_threads" to 0
                )
            )
            try {
                val chunks = AtomicInteger(0)
                context.setTokenCallback { chunks.incrementAndGet() }
                val baseline = capture(context, chunks, "baseline", emptyMap())
                val first = capture(context, chunks, "explicit_a", mapOf(
                    "penalty_last_n" to 96,
                    "penalty_repeat" to 1.1,
                    "penalty_freq" to 0.15,
                    "penalty_present" to 0.25
                ))
                val second = capture(context, chunks, "explicit_b", mapOf(
                    "penalty_last_n" to -1,
                    "penalty_repeat" to 1.2,
                    "penalty_freq" to -0.2,
                    "penalty_present" to 0.1
                ))
                val restored = capture(context, chunks, "restored", emptyMap())

                for (result in listOf(baseline, first, second, restored)) {
                    assertEquals(true, result["qa_penalties_sampler_configured"])
                    assertEquals(64, result["qa_baseline_last_n"])
                    assertPenalty(result, "qa_baseline_repeat", 1.0)
                    assertPenalty(result, "qa_baseline_freq", 0.0)
                    assertPenalty(result, "qa_baseline_present", 0.0)
                }
                assertEquals(64, baseline["qa_effective_last_n"])
                assertPenalty(baseline, "qa_effective_repeat", 1.0)
                assertEquals(false, baseline["qa_penalties_sampler_active"])
                assertEquals(96, first["qa_effective_last_n"])
                assertEquals(true, first["qa_penalties_sampler_active"])
                assertPenalty(first, "qa_effective_repeat", 1.1)
                assertPenalty(first, "qa_effective_freq", 0.15)
                assertPenalty(first, "qa_effective_present", 0.25)
                assertTrue((second["qa_context_size"] as Number).toInt() > 0)
                assertEquals(second["qa_context_size"], second["qa_effective_last_n"])
                assertEquals(true, second["qa_penalties_sampler_active"])
                assertPenalty(second, "qa_effective_repeat", 1.2)
                assertPenalty(second, "qa_effective_freq", -0.2)
                assertPenalty(second, "qa_effective_present", 0.1)
                assertEquals(64, restored["qa_effective_last_n"])
                assertEquals(false, restored["qa_penalties_sampler_active"])
                assertPenalty(restored, "qa_effective_repeat", 1.0)
                assertPenalty(restored, "qa_effective_freq", 0.0)
                assertPenalty(restored, "qa_effective_present", 0.0)
                println("SAMPLING_NATIVE_BINDING apkSha256=$apkSha modelSha256=$EXPECTED_MODEL_SHA callbacks=${chunks.get()}")
            } finally {
                context.release()
            }
        }
    }

    private fun capture(
        context: LlamaContext,
        chunks: AtomicInteger,
        label: String,
        overrides: Map<String, Any>
    ): Map<String, Any> {
        context.prepareCompletion()
        val beforeChunks = chunks.get()
        val params = mapOf<String, Any>(
            "prompt" to "<start_of_turn>user\nWrite one short line about rain.<end_of_turn>\n<start_of_turn>model\n",
            "seed" to 37,
            "temperature" to 0.7,
            "top_k" to 40,
            "top_p" to 0.9,
            "n_predict" to 8,
            "emit_partial_completion" to true,
            "qa_sampling_trace" to true
        ) + overrides
        val result = context.completion(params)
        assertTrue("$label must produce a native callback", chunks.get() > beforeChunks)
        println("SAMPLING_NATIVE_STEP label=$label baselineLastN=${result["qa_baseline_last_n"]} " +
            "baselineRepeat=${result["qa_baseline_repeat"]} baselineFreq=${result["qa_baseline_freq"]} " +
            "baselinePresent=${result["qa_baseline_present"]} effectiveLastN=${result["qa_effective_last_n"]} " +
            "effectiveRepeat=${result["qa_effective_repeat"]} effectiveFreq=${result["qa_effective_freq"]} " +
            "effectivePresent=${result["qa_effective_present"]} contextSize=${result["qa_context_size"]} " +
            "penaltiesConfigured=${result["qa_penalties_sampler_configured"]} " +
            "penaltiesActive=${result["qa_penalties_sampler_active"]}")
        return result
    }

    private fun assertPenalty(result: Map<String, Any>, field: String, expected: Double) {
        assertEquals(expected, (result[field] as Number).toDouble(), 0.0001)
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private companion object {
        val EXPECTED_MODEL_SHA = com.rhymeai.app.ui.components.GEMMA_DOWNLOADS.first().sha256
    }
}
