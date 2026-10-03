package com.rhymeai.app.ui.components

import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class SafeImportsTest {
    @Test
    fun projectImportRejectsBytesBeyondLimit() {
        val oversized = ByteArray(MAX_PROJECT_IMPORT_BYTES + 1) { 'a'.code.toByte() }

        val error = assertFailsWith<IllegalArgumentException> {
            readProjectText(ByteArrayInputStream(oversized))
        }

        assertEquals("Project files must be 10 MB or smaller.", error.message)
    }

    @Test
    fun modelImportAcceptsExactLimitAndAtomicallyReplacesDestination() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-model-import").toFile()
        try {
            val destination = directory.resolve("model.gguf").apply { writeText("old") }
            val model = ggufHeader(version = 3)

            copyLocalModelAtomically(ByteArrayInputStream(model), destination, maxBytes = model.size.toLong())

            assertEquals(model.toList(), destination.readBytes().toList())
            assertFalse(directory.listFiles().orEmpty().any { it.name.startsWith(".model-import-") })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun oversizedModelLeavesExistingDestinationUntouched() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-model-import").toFile()
        try {
            val destination = directory.resolve("model.gguf").apply { writeText("old") }
            val oversized = ggufHeader(version = 3) + byteArrayOf(1)

            assertFailsWith<IllegalArgumentException> {
                copyLocalModelAtomically(ByteArrayInputStream(oversized), destination, maxBytes = 24L)
            }

            assertEquals("old", destination.readText())
            assertFalse(directory.listFiles().orEmpty().any { it.name.startsWith(".model-import-") })
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun unsupportedGgufVersionLeavesExistingDestinationUntouched() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("rhymeai-model-import").toFile()
        try {
            val destination = directory.resolve("model.gguf").apply { writeText("old") }

            assertFailsWith<IllegalArgumentException> {
                copyLocalModelAtomically(
                    ByteArrayInputStream(ggufHeader(version = 1)),
                    destination,
                    maxBytes = 24L
                )
            }

            assertEquals("old", destination.readText())
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun ggufHeader(version: Int): ByteArray = ByteBuffer.allocate(24)
        .order(ByteOrder.LITTLE_ENDIAN)
        .put("GGUF".toByteArray())
        .putInt(version)
        .putLong(1)
        .putLong(1)
        .array()
}
