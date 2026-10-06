package com.rhymeai.app.ui.components

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.attribute.FileTime
import java.security.MessageDigest
import kotlin.io.path.createTempDirectory

class GemmaDownloadsTest {
    private val tempDirs = mutableListOf<File>()
    private var server: TestHttpServer? = null

    @After
    fun tearDown() {
        server?.close()
        tempDirs.forEach { it.deleteRecursively() }
    }

    @Test
    fun validateDownloadedGemmaRejectsMissingIncompleteAndNonGgufFiles() {
        val model = tinyGemma(expectedBytes = 24)
        val dir = tempDir()
        val file = File(dir, model.fileName)

        assertEquals("Gemma Tiny is not downloaded yet", validateDownloadedGemma(model, file))

        file.writeBytes(byteArrayOf('G'.code.toByte(), 'G'.code.toByte(), 'U'.code.toByte(), 'F'.code.toByte()))
        assertEquals(
            "Gemma Tiny download is incomplete: 0.00 GB of 0.00 GB",
            validateDownloadedGemma(model, file)
        )

        file.writeBytes(ByteArray(24) { 1 })
        assertEquals("Gemma Tiny download did not produce a GGUF file", validateDownloadedGemma(model, file))

        file.writeBytes(
            ByteBuffer.allocate(24)
                .order(ByteOrder.LITTLE_ENDIAN)
                .put("GGUF".toByteArray())
                .putInt(3)
                .putLong(1)
                .putLong(1)
                .array()
        )
        assertNull(validateDownloadedGemma(model, file))

        file.appendBytes(byteArrayOf(0))
        assertEquals(
            "Gemma Tiny download has an unexpected size: 0.00 GB instead of 0.00 GB",
            validateDownloadedGemma(model, file)
        )
    }

    @Test
    fun validateDownloadedGemmaIntegrityRequiresMatchingSha256() {
        val bytes = validTinyGguf()
        val dir = tempDir()
        val file = File(dir, "tiny.gguf")
        file.writeBytes(bytes)

        val validModel = tinyGemma(
            expectedBytes = bytes.size.toLong(),
            sha256 = sha256(bytes)
        )
        assertNull(validateDownloadedGemmaIntegrity(validModel, file))

        val mismatchedModel = validModel.copy(sha256 = "0".repeat(64))
        assertEquals(
            "Gemma Tiny download failed its integrity check",
            validateDownloadedGemmaIntegrity(mismatchedModel, file)
        )
    }

    @Test
    fun cachedIntegrityVerificationIsAcceptedOnlyForTheSameCatalogAndFileIdentity() {
        val bytes = validTinyGguf()
        val file = File(tempDir(), "tiny.gguf").apply { writeBytes(bytes) }
        val model = tinyGemma(expectedBytes = bytes.size.toLong(), sha256 = sha256(bytes))
        val verifiedModified = file.lastModified()

        assertTrue(
            hasCurrentGemmaVerification(
                model,
                file,
                model.sha256,
                file.length(),
                verifiedModified
            )
        )
        assertFalse(
            hasCurrentGemmaVerification(
                model.copy(sha256 = "0".repeat(64)),
                file,
                model.sha256,
                file.length(),
                verifiedModified
            )
        )

        Files.setLastModifiedTime(file.toPath(), FileTime.fromMillis(verifiedModified + 2_000L))
        assertFalse(
            hasCurrentGemmaVerification(
                model,
                file,
                model.sha256,
                file.length(),
                verifiedModified
            )
        )

        val invalidHeader = bytes.copyOf().also { it[0] = 0 }
        file.writeBytes(invalidHeader)
        Files.setLastModifiedTime(file.toPath(), FileTime.fromMillis(verifiedModified))
        assertFalse(
            hasCurrentGemmaVerification(
                model,
                file,
                model.sha256,
                file.length(),
                file.lastModified()
            )
        )
    }

    @Test
    fun catalogPinsTheSameImmutableHuggingFaceArtifactsAsIos() {
        assertEquals(
            listOf(3_427_880_800L, 5_335_290_784L),
            GEMMA_DOWNLOADS.map(GemmaDownload::expectedBytes)
        )
        assertEquals(
            listOf(
                "b250c2f6a91d9f7659f7ac2c90ccc563ca96a84aea4c1e8a3463fafc77d004af",
                "e39b2475a5c8d86d1b376babe16ffce32993c96ab650b6fed7c4e14f5d0d11a3"
            ),
            GEMMA_DOWNLOADS.map(GemmaDownload::sha256)
        )
        GEMMA_DOWNLOADS.forEach { model ->
            assertTrue(model.url.contains("/resolve/$GEMMA_HUGGING_FACE_REVISION/"))
            assertFalse(model.url.contains("/resolve/main/"))
        }
    }

    // The catalog must pin an immutable commit, never a branch or placeholder.
    @Test
    fun catalogPinsAnImmutableHuggingFaceCommit() {
        assertTrue(
            "GEMMA_HUGGING_FACE_REVISION must be a 40-character commit hash",
            GEMMA_HUGGING_FACE_REVISION.matches(Regex("[0-9a-f]{40}"))
        )
    }

    @Test
    fun catalogRecordsEachModelsEmbeddedChatTemplate() {
        assertEquals(
            listOf(GEMMA4_E2B_V2_CHAT_TEMPLATE_SHA256, GEMMA4_CHAT_TEMPLATE_SHA256),
            GEMMA_DOWNLOADS.map(GemmaDownload::chatTemplateSha256)
        )
    }

    @Test
    fun previousE2bVersionUnderTheSameNameIsNotTreatedAsInstalled() {
        val e2b = GEMMA_DOWNLOADS.first()
        val file = File(tempDir(), e2b.fileName)
        // The shipped v1 E2B file: same name, 2,016 bytes smaller than the v2 entry.
        java.io.RandomAccessFile(file, "rw").use { output ->
            output.write(validTinyGguf())
            output.setLength(3_427_878_784L)
        }
        val previousSha = "059e73281d764ba0d541470aabdbd89de84878263b67d50c6c3afbc292933626"

        // A registration verified against the old catalog SHA is not reused...
        assertFalse(
            hasCurrentGemmaVerification(e2b, file, previousSha, file.length(), file.lastModified())
        )
        // ...and the re-check (also the download short-circuit) rejects the old bytes.
        assertNotNull(validateDownloadedGemma(e2b, file))
        assertNotNull(validateDownloadedGemmaIntegrity(e2b, file))
    }

    @Test
    fun downloadGemmaToTempResumesPartialFileAndReportsProgress() = runBlocking {
        val dir = tempDir()
        val tempFile = File(dir, "tiny.gguf.download")
        val expected = validTinyGguf()
        val prefix = expected.copyOfRange(0, 8)
        val suffix = expected.copyOfRange(8, expected.size)
        tempFile.writeBytes(prefix)

        var sawRangeHeader = false
        val url = startServer { request, output ->
            sawRangeHeader = request.contains("Range: bytes=8-23")
            output.writeResponse(206, suffix, contentRange = "bytes 8-23/24")
        }
        val model = tinyGemma(
            url = url,
            expectedBytes = expected.size.toLong(),
            sha256 = sha256(expected)
        )
        val progress = mutableListOf<Float>()

        downloadGemmaToTemp(
            model = model,
            tempFile = tempFile,
            onProgress = { progress += it },
            connectionCount = 1
        )

        assertTrue(sawRangeHeader)
        assertEquals(listOf(1f / 3f, 1.0f), progress)
        assertEquals(expected.toList(), tempFile.readBytes().toList())
        assertFalse(gemmaDownloadStateFile(tempFile).exists())
    }

    @Test
    fun downloadGemmaToTempSurfacesHttpFailure() = runBlocking {
        val dir = tempDir()
        val tempFile = File(dir, "tiny.gguf.download")
        val url = startServer { _, output ->
            output.writeResponse(503, ByteArray(0))
        }
        val model = tinyGemma(url = url, expectedBytes = 8)

        val error = runCatching {
            downloadGemmaToTemp(
                model = model,
                tempFile = tempFile,
                onProgress = {},
                connectionCount = 1
            )
        }.exceptionOrNull()

        assertNotNull(error)
        assertTrue(error!!.message!!.contains("Hugging Face returned HTTP 503"))
        assertTrue(gemmaDownloadStateFile(tempFile).isFile)
    }

    @Test
    fun failedRedownloadPreservesExistingInstalledModel() = runBlocking {
        val dir = tempDir()
        val destinationFile = File(dir, "installed.gguf")
        val existingBytes = validTinyGguf()
        destinationFile.writeBytes(existingBytes)
        val tempFile = File(dir, "replacement.gguf.download")
        val url = startServer { _, output ->
            output.writeResponse(503, ByteArray(0))
        }
        val model = tinyGemma(
            url = url,
            expectedBytes = existingBytes.size.toLong(),
            sha256 = "0".repeat(64)
        )

        val error = runCatching {
            downloadGemmaAndInstall(
                model = model,
                tempFile = tempFile,
                destinationFile = destinationFile,
                onProgress = {},
                connectionCount = 1
            )
        }.exceptionOrNull()

        assertNotNull(error)
        assertEquals(existingBytes.toList(), destinationFile.readBytes().toList())
    }

    @Test
    fun verifiedTempAtomicallyReplacesInstalledModel() = runBlocking {
        val dir = tempDir()
        val destinationFile = File(dir, "installed.gguf").apply { writeText("old") }
        val expectedBytes = validTinyGguf()
        val tempFile = File(dir, "replacement.gguf.download").apply { writeBytes(expectedBytes) }
        val model = tinyGemma(
            expectedBytes = expectedBytes.size.toLong(),
            sha256 = sha256(expectedBytes)
        )

        downloadGemmaAndInstall(
            model = model,
            tempFile = tempFile,
            destinationFile = destinationFile,
            onProgress = {},
            connectionCount = 1
        )

        assertEquals(expectedBytes.toList(), destinationFile.readBytes().toList())
        assertFalse(tempFile.exists())
    }

    @Test
    fun gemmaDownloadSegmentsCoverTheModelWithFourNonOverlappingRanges() {
        assertEquals(
            listOf(
                GemmaDownloadSegment(0, 4),
                GemmaDownloadSegment(5, 9),
                GemmaDownloadSegment(10, 14),
                GemmaDownloadSegment(15, 16)
            ),
            gemmaDownloadSegments(expectedBytes = 17, connectionCount = 4)
        )
    }

    @Test
    fun ensureEnoughSpaceForGemmaSurfacesNoStorageMessage() {
        val dir = tempDir()
        val tempFile = File(dir, "tiny.gguf.download")
        val model = tinyGemma(expectedBytes = dir.usableSpace + 1L)

        val error = runCatching {
            ensureEnoughSpaceForGemma(model, File(dir, "tiny.gguf"), tempFile)
        }.exceptionOrNull()

        assertNotNull(error)
        assertTrue(error!!.message!!.contains("Need "))
        assertTrue(error.message!!.contains("free for Gemma Tiny"))
    }

    @Test
    fun formatDownloadProgressHandlesUnknownAndPercentValues() {
        assertEquals("downloading...", formatDownloadProgress(null))
        assertEquals("downloading...", formatDownloadProgress(0f))
        assertEquals("42%", formatDownloadProgress(0.42f))
        assertEquals("100%", formatDownloadProgress(1f))
    }

    // --- recommendedGemmaModel ---

    @Test
    fun recommendedGemmaModelReturnsE2BForTypicalPhone() {
        // 8 GB phone (most Android flagships) — E4B thrashes here, so E2B is correct.
        val eightGb = 8L * 1024L * 1024L * 1024L
        val rec = recommendedGemmaModel(eightGb)
        assertEquals(GEMMA_DOWNLOADS[0].fileName, rec.fileName)
    }

    @Test
    fun recommendedGemmaModelReturnsE2BAtBoundaryJustBelow10GB() {
        // One byte below the 10 GB threshold — still E2B territory.
        val justBelow = RAM_THRESHOLD_E4B_BYTES - 1L
        val rec = recommendedGemmaModel(justBelow)
        assertEquals(GEMMA_DOWNLOADS[0].fileName, rec.fileName)
    }

    @Test
    fun recommendedGemmaModelReturnsE4BAtExactThreshold() {
        // At exactly 10 GB total RAM the device has enough headroom for E4B.
        val rec = recommendedGemmaModel(RAM_THRESHOLD_E4B_BYTES)
        assertEquals(GEMMA_DOWNLOADS[1].fileName, rec.fileName)
    }

    @Test
    fun recommendedGemmaModelReturnsE4BForHighRamDevice() {
        // 16 GB flagship tablet / desktop-class device — E4B should be recommended.
        val sixteenGb = 16L * 1024L * 1024L * 1024L
        val rec = recommendedGemmaModel(sixteenGb)
        assertEquals(GEMMA_DOWNLOADS[1].fileName, rec.fileName)
    }

    @Test
    fun recommendedGemmaModelReturnsE2BForMinimalLowEndDevice() {
        // 3 GB budget device — definitely not enough for E4B.
        val threeGb = 3L * 1024L * 1024L * 1024L
        val rec = recommendedGemmaModel(threeGb)
        assertEquals(GEMMA_DOWNLOADS[0].fileName, rec.fileName)
    }

    private fun tinyGemma(
        url: String = "https://example.invalid/tiny.gguf",
        expectedBytes: Long,
        sha256: String = "0".repeat(64)
    ) = GemmaDownload(
        label = "Gemma Tiny",
        description = "Tiny test model.",
        fileName = "tiny.gguf",
        url = url,
        expectedBytes = expectedBytes,
        sha256 = sha256
    )

    private fun validTinyGguf(): ByteArray =
        ByteBuffer.allocate(24)
            .order(ByteOrder.LITTLE_ENDIAN)
            .put("GGUF".toByteArray())
            .putInt(3)
            .putLong(1)
            .putLong(1)
            .array()

    private fun sha256(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { String.format("%02x", it.toInt() and 0xff) }

    private fun tempDir(): File {
        val dir = createTempDirectory("rhymeai-gemma-test").toFile()
        tempDirs += dir
        return dir
    }

    private fun startServer(handler: (String, OutputStream) -> Unit): String {
        val httpServer = TestHttpServer(handler)
        server = httpServer
        return "http://${httpServer.host}:${httpServer.port}/tiny.gguf"
    }

    private class TestHttpServer(
        private val handler: (String, OutputStream) -> Unit
    ) : AutoCloseable {
        private val socket = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        private val thread = Thread {
            socket.use { serverSocket ->
                serverSocket.accept().use { client ->
                    val request = client.readRequest()
                    handler(request, client.getOutputStream())
                }
            }
        }

        val host: String = socket.inetAddress.hostAddress ?: "127.0.0.1"
        val port: Int = socket.localPort

        init {
            thread.start()
        }

        override fun close() {
            runCatching { socket.close() }
            thread.join(1_000)
        }

        private fun Socket.readRequest(): String {
            val input = getInputStream().bufferedReader()
            val lines = mutableListOf<String>()
            while (true) {
                val line = input.readLine() ?: break
                if (line.isEmpty()) break
                lines += line
            }
            return lines.joinToString("\n")
        }
    }

    private fun OutputStream.writeResponse(
        statusCode: Int,
        body: ByteArray,
        contentRange: String? = null
    ) {
        write(
            buildString {
                append("HTTP/1.1 $statusCode Test\r\n")
                append("Content-Length: ${body.size}\r\n")
                contentRange?.let { append("Content-Range: $it\r\n") }
                append("Connection: close\r\n")
                append("\r\n")
            }.toByteArray(Charsets.UTF_8)
        )
        write(body)
        flush()
    }
}
