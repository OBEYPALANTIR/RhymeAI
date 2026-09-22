package com.rhymeai.app.service

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.system.measureTimeMillis
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LocalModelServiceTest {
    @Test
    fun responseLimitNeverSplitsUtf16SurrogatePairs() {
        val text = "ab\uD83D\uDE00cd"

        assertEquals("ab", text.takeUtf16CodeUnits(3))
        assertEquals("ab\uD83D\uDE00", text.takeUtf16CodeUnits(4))
        assertEquals(text, text.takeUtf16CodeUnits(6))
    }

    @Test
    fun `GGUF validation rejects a truncated magic-only file`() {
        val file = temporaryFile("GGUF".toByteArray())
        try {
            assertFalse(file.isGgufFile())
        } finally {
            file.delete()
        }
    }

    @Test
    fun `GGUF validation accepts a complete supported header`() {
        val header = ByteBuffer.allocate(24)
            .order(ByteOrder.LITTLE_ENDIAN)
            .put("GGUF".toByteArray())
            .putInt(3)
            .putLong(1)
            .putLong(1)
            .array()
        val file = temporaryFile(header)
        try {
            assertTrue(file.isGgufFile())
        } finally {
            file.delete()
        }
    }

    @Test
    fun gemma4MetadataSelectsNativeGemma4Envelope() {
        val format = GGUFPromptFormat.resolve(
            architecture = "gemma4",
            chatTemplate = "{% if role == 'user' %}<|turn>user{{ content }}<turn|>{% endif %}"
        )

        assertEquals(GGUFPromptFormat.GEMMA4, format)
    }

    @Test
    fun legacyGemmaMetadataPreservesLegacyEnvelope() {
        val format = GGUFPromptFormat.resolve(
            architecture = "gemma3",
            chatTemplate = "{% if role == 'user' %}<start_of_turn>user{{ content }}<end_of_turn>{% endif %}"
        )

        assertEquals(GGUFPromptFormat.GEMMA_LEGACY, format)
    }

    @Test
    fun mismatchedArchitectureAndTemplateAreRejected() {
        assertEquals(
            null,
            GGUFPromptFormat.resolve(
                architecture = "gemma4",
                chatTemplate = "<start_of_turn>user{{ content }}<end_of_turn>"
            )
        )
    }

    @Test
    fun closeSchedulesNativeStopWithoutBlockingCaller() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val stopStarted = CountDownLatch(1)
        val allowStop = CompletableDeferred<Unit>()
        val released = CountDownLatch(1)
        lateinit var shutdownJob: Job

        try {
            val elapsedMs = measureTimeMillis {
                shutdownJob = scope.launchLocalModelShutdown(
                    stopActiveGeneration = {
                        stopStarted.countDown()
                        allowStop.await()
                    },
                    releaseModel = { released.countDown() },
                    stopTimeoutMs = 2_000L
                )
            }

            assertTrue(elapsedMs < 500L)
            assertTrue(stopStarted.await(2, TimeUnit.SECONDS))
            assertFalse(released.await(100, TimeUnit.MILLISECONDS))
            allowStop.complete(Unit)
            runBlocking { withTimeout(2_000L) { shutdownJob.join() } }
            assertTrue(released.await(100, TimeUnit.MILLISECONDS))
        } finally {
            scope.cancel()
        }
    }

    private fun temporaryFile(contents: ByteArray): File =
        kotlin.io.path.createTempFile(prefix = "rhymeai-gguf-", suffix = ".gguf")
            .toFile()
            .apply { writeBytes(contents) }
}
