package com.rhymeai.app.ui.components

import kotlinx.coroutines.launch
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
            listOf(3_427_880_800L, 5_335_292_800L),
            GEMMA_DOWNLOADS.map(GemmaDownload::expectedBytes)
        )
        assertEquals(
            listOf(
                "902e5d83a86393f064b1c8abc1a9d25fec5b3634683317792b02856c01c604e0",
                "6d6b7890655943a3dba1a4212f6668537503a9e085f55fbdeeb40265c5e91944"
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
            listOf(GEMMA4_RHYMEAI_V2_CHAT_TEMPLATE_SHA256, GEMMA4_RHYMEAI_V2_CHAT_TEMPLATE_SHA256),
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
    fun sameSizeE2bV21IsReverifiedAndReclaimedForV6() {
        val e2b = GEMMA_DOWNLOADS.first()
        val dir = tempDir()
        val file = File(dir, e2b.fileName)
        // The shipped v2.1 E2B file has exactly the v6 size and name; only its SHA-256 differs.
        java.io.RandomAccessFile(file, "rw").use { output ->
            output.write(validTinyGguf())
            output.setLength(e2b.expectedBytes)
        }
        val v21Sha = "4cfffebcb0b96e154d963de5d90ed63962d0bcd9e77ab9fec38314257870e6a5"
        assertTrue(!v21Sha.equals(e2b.sha256, ignoreCase = true))

        // Size and header alone cannot tell the versions apart...
        assertNull(validateDownloadedGemma(e2b, file))
        // ...so a registration verified against the v2.1 catalog SHA is not reused,
        assertFalse(
            hasCurrentGemmaVerification(e2b, file, v21Sha, file.length(), file.lastModified())
        )
        // the forced re-check rejects the v2.1 bytes,
        assertEquals(
            "${e2b.label} download failed its integrity check",
            validateDownloadedGemmaIntegrity(e2b, file)
        )
        // and the stale file is reclaimed before the v6 download.
        assertEquals(e2b.expectedBytes, reclaimStaleInstalledGemma(e2b, file))
        assertFalse(file.exists())
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
    fun pausingADownloadKeepsItsSegmentsAndResumeContinuesFromThem() = runBlocking {
        val dir = tempDir()
        val tempFile = File(dir, "tiny.gguf.download")
        val expected = validTinyGguf()
        // The first server sends 8 of the 24 bytes, then stalls until it is released.
        val stalled = java.util.concurrent.CountDownLatch(1)
        val url = startServer { _, output ->
            output.write("HTTP/1.1 206 Test\r\nContent-Length: 24\r\nContent-Range: bytes 0-23/24\r\n\r\n".toByteArray())
            output.write(expected, 0, 8)
            output.flush()
            stalled.await(10, java.util.concurrent.TimeUnit.SECONDS)
        }
        val model = tinyGemma(url = url, expectedBytes = expected.size.toLong(), sha256 = sha256(expected))

        val run = launch(kotlinx.coroutines.Dispatchers.IO) {
            // The app's job catches the closed connection the pause causes; so does this one.
            runCatching { downloadGemmaToTemp(model = model, tempFile = tempFile, onProgress = {}, connectionCount = 1) }
        }
        val deadline = System.currentTimeMillis() + 10_000
        while (!(tempFile.isFile && tempFile.readBytes().copyOf(8).contentEquals(expected.copyOf(8)))) {
            assertTrue("the first bytes never arrived", System.currentTimeMillis() < deadline)
            Thread.sleep(20)
        }
        Thread.sleep(200) // let the reader record the bytes it wrote
        // The JDK's disconnect waits on the reading thread's lock, so here the server's close ends
        // the read; on Android, disconnect cancels the OkHttp call (GemmaPauseInstrumentedTest).
        run.cancel()
        stalled.countDown()
        kotlinx.coroutines.withTimeout(5_000) { run.join() }

        // Paused: the partial and its resume state survive, crediting the bytes already written.
        assertTrue(tempFile.isFile)
        assertTrue(gemmaDownloadStateFile(tempFile).isFile)
        server?.close()

        var resumedFrom: String? = null
        val resumeUrl = startServer { request, output ->
            resumedFrom = Regex("Range: bytes=(\\d+-\\d+)").find(request)?.groupValues?.get(1)
            output.writeResponse(206, expected.copyOfRange(8, 24), contentRange = "bytes 8-23/24")
        }
        downloadGemmaToTemp(model = model.copy(url = resumeUrl), tempFile = tempFile, onProgress = {}, connectionCount = 1)

        assertEquals("8-23", resumedFrom)
        assertEquals(expected.toList(), tempFile.readBytes().toList())
        assertFalse(gemmaDownloadStateFile(tempFile).exists())
    }

    @Test
    fun cancellingRemovesOnlyThePartialNeverTheInstalledFile() {
        val cacheDir = tempDir()
        val filesDir = tempDir()
        val model = tinyGemma(expectedBytes = 24)
        val installed = File(filesDir, model.fileName).apply { writeBytes(ByteArray(24) { 3 }) }
        val temp = gemmaDownloadTempFile(cacheDir, model).apply { writeBytes(ByteArray(24)) }
        saveDownloadState(gemmaDownloadStateFile(temp), model, longArrayOf(6L, 0L, 0L, 0L))
        assertEquals(6L, gemmaPartialBytes(model, cacheDir))

        deleteGemmaPartial(model, cacheDir)

        assertFalse(temp.exists())
        assertFalse(gemmaDownloadStateFile(temp).exists())
        assertNull(gemmaPartialBytes(model, cacheDir))
        assertEquals(ByteArray(24) { 3 }.toList(), installed.readBytes().toList())
    }

    @Test
    fun resumeStateFromAnotherArtifactOrOlderFormatIsDiscarded() = runBlocking {
        val expected = validTinyGguf()
        val model = tinyGemma(expectedBytes = expected.size.toLong(), sha256 = sha256(expected))
        val previousVersion = model.copy(sha256 = "059e73281d764ba0d541470aabdbd89de84878263b67d50c6c3afbc292933626")
        val writeForeignState = listOf<(File) -> Unit>(
            // Current format, recorded for the previous artifact under the same file name.
            { state -> saveDownloadState(state, previousVersion, longArrayOf(8L)) },
            // The format written by builds before artifact-keyed state (no SHA recorded).
            { state ->
                java.io.DataOutputStream(state.outputStream()).use { output ->
                    output.writeInt(0x52484D44)
                    output.writeInt(1)
                    output.writeInt(1)
                    output.writeLong(8L)
                }
            }
        )
        writeForeignState.forEach { writeState ->
            val dir = tempDir()
            val tempFile = File(dir, "tiny.gguf.download").apply { writeBytes(ByteArray(8) { 0x7f }) }
            writeState(gemmaDownloadStateFile(tempFile))
            val ranges = mutableListOf<String>()
            val url = startServer { request, output ->
                val range = Regex("Range: bytes=(\\d+)-(\\d+)").find(request)!!
                ranges += range.value
                val start = range.groupValues[1].toInt()
                val end = range.groupValues[2].toInt()
                output.writeResponse(
                    206,
                    expected.copyOfRange(start, end + 1),
                    contentRange = "bytes $start-$end/${expected.size}"
                )
            }

            downloadGemmaToTemp(
                model = model.copy(url = url),
                tempFile = tempFile,
                onProgress = {},
                connectionCount = 1
            )

            assertEquals(listOf("Range: bytes=0-23"), ranges)
            assertEquals(expected.toList(), tempFile.readBytes().toList())
            server?.close()
            server = null
        }
    }

    @Test
    fun staleInstalledFileIsReclaimedButAValidOneIsKept() {
        val dir = tempDir()
        val expected = validTinyGguf()
        val model = tinyGemma(expectedBytes = expected.size.toLong(), sha256 = sha256(expected))
        val destination = File(dir, model.fileName)

        // Previous version under the same name: different size.
        destination.writeBytes(expected.copyOf(20))
        assertEquals(20L, reclaimStaleInstalledGemma(model, destination))
        assertFalse(destination.exists())

        // Same size, different bytes: still fails the current SHA-256.
        destination.writeBytes(expected.copyOf().also { it[23] = 9 })
        assertEquals(24L, reclaimStaleInstalledGemma(model, destination))
        assertFalse(destination.exists())

        destination.writeBytes(expected)
        assertEquals(0L, reclaimStaleInstalledGemma(model, destination))
        assertEquals(expected.toList(), destination.readBytes().toList())
    }

    @Test
    fun deleteInstalledGemmaRemovesAStaleFileAndEveryDownloadArtifact() {
        val filesDir = tempDir()
        val cacheDir = tempDir()
        val model = tinyGemma(expectedBytes = 24)
        // Stale version under the catalog name: wrong size, so it is not "installed" but must still go.
        val installed = File(filesDir, model.fileName).apply { writeBytes(ByteArray(20)) }
        val temp = gemmaDownloadTempFile(cacheDir, model).apply { writeBytes(ByteArray(8)) }
        val state = gemmaDownloadStateFile(temp).apply { writeBytes(ByteArray(4)) }
        val stagingState = File(cacheDir, "${state.name}.tmp").apply { writeBytes(ByteArray(2)) }
        val unrelated = File(filesDir, "custom-keep.gguf").apply { writeBytes(ByteArray(3)) }

        deleteInstalledGemma(model, filesDir, cacheDir)

        listOf(installed, temp, state, stagingState).forEach { assertFalse(it.path, it.exists()) }
        assertTrue(unrelated.exists())

        // Nothing on disk is not a failure.
        deleteInstalledGemma(model, filesDir, cacheDir)
    }

    @Test
    fun upgradeSpaceCheckCountsTheReclaimedStaleModel() {
        val dir = tempDir()
        val model = tinyGemma(expectedBytes = 1_000L)
        val destination = File(dir, model.fileName).apply { writeBytes(validTinyGguf()) }
        val tempFile = File(dir, "${model.fileName}.download")
        val staleBytes = destination.length()
        val required = model.expectedBytes + MIN_FREE_SPACE_AFTER_DOWNLOAD_BYTES
        // Free space only suffices once the stale model's bytes are returned to the volume.
        val usable: (File) -> Long = { if (destination.exists()) required - staleBytes else required }

        ensureEnoughSpaceForGemma(model, destination, tempFile, usable)
        assertFalse(destination.exists())

        // A valid installed file is kept until replacement, so it is not counted as free.
        val kept = validTinyGguf()
        val installed = tinyGemma(expectedBytes = kept.size.toLong(), sha256 = sha256(kept))
        val installedFile = File(dir, installed.fileName).apply { writeBytes(kept) }
        val tight = installed.expectedBytes + MIN_FREE_SPACE_AFTER_DOWNLOAD_BYTES - 1L
        val error = runCatching {
            ensureEnoughSpaceForGemma(installed, installedFile, tempFile) { tight }
        }.exceptionOrNull()
        assertNotNull(error)
        assertTrue(installedFile.exists())
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

    @Test
    fun gemmaModelNeedsMoreMemoryWarnsOnlyForE4BBelowThreshold() {
        val gb = 1024L * 1024L * 1024L
        val e2b = GEMMA_DOWNLOADS[0]
        val e4b = GEMMA_DOWNLOADS[1]
        for (ram in listOf(6L, 8L, 10L, 12L).map { it * gb }) {
            assertFalse("E2B at $ram", gemmaModelNeedsMoreMemory(e2b, ram))
        }
        assertTrue(gemmaModelNeedsMoreMemory(e4b, 6L * gb))
        assertTrue(gemmaModelNeedsMoreMemory(e4b, 8L * gb))
        assertFalse(gemmaModelNeedsMoreMemory(e4b, 10L * gb))
        assertFalse(gemmaModelNeedsMoreMemory(e4b, 12L * gb))
    }

    private fun tinyGemma(
        url: String = "https://example.invalid/tiny.gguf",
        expectedBytes: Long,
        sha256: String = "0".repeat(64)
    ) = GemmaDownload(
        label = "Gemma Tiny",
        character = "Tiny test model.",
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
