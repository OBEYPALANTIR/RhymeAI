package com.rhymeai.app.service

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LocalModelServiceTest {
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

    private fun temporaryFile(contents: ByteArray): File =
        kotlin.io.path.createTempFile(prefix = "rhymeai-gguf-", suffix = ".gguf")
            .toFile()
            .apply { writeBytes(contents) }
}
