package com.rhymeai.app.service

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/** Synthetic MPEG-4 files: a finished take and truncated ones (A27). */
class Mp4IntegrityTest {
    private val dir = kotlin.io.path.createTempDirectory("rhymeai-mp4").toFile()

    @AfterTest
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun box(type: String, vararg parts: ByteArray): ByteArray {
        val payload = parts.fold(ByteArray(0)) { acc, part -> acc + part }
        return ByteArrayOutputStream().also { out ->
            DataOutputStream(out).apply { writeInt(8 + payload.size); writeBytes(type); write(payload) }
        }.toByteArray()
    }

    private fun ints(vararg values: Int): ByteArray = ByteArrayOutputStream().also { out ->
        DataOutputStream(out).apply { values.forEach { writeInt(it) } }
    }.toByteArray()

    private val ftyp = box("ftyp", "M4A ".toByteArray(), ints(0), "isom".toByteArray())

    /** Three 10-byte samples in one chunk at [chunkOffset]. */
    private fun moov(chunkOffset: Int) = box(
        "moov",
        box(
            "trak",
            box(
                "mdia",
                box("mdhd", ints(0, 0, 0, 44_100, 88_200)),
                box("hdlr", ints(0, 0), "soun".toByteArray(), ints(0, 0, 0), byteArrayOf(0)),
                box("minf", box("stbl", box("stsz", ints(0, 0, 3, 10, 10, 10)), box("stsc", ints(0, 1, 1, 3, 1)), box("stco", ints(0, 1, chunkOffset))))
            )
        )
    )

    private fun write(name: String, bytes: ByteArray) = File(dir, name).apply { writeBytes(bytes) }

    private val media = ByteArray(30) { it.toByte() }
    private val finished = ftyp + box("mdat", media) + moov(ftyp.size + 8)

    @Test
    fun aFinishedTakePasses() {
        val track = Mp4Integrity.check(write("take.m4a", finished)).single()
        assertEquals("soun", track.handler)
        assertEquals(3, track.sampleCount)
    }

    @Test
    fun aTakeCutInsideItsMediaDataFails() {
        assertFailsWith<Mp4Integrity.InvalidMp4> { Mp4Integrity.check(write("cut.m4a", finished.copyOf(ftyp.size + 8 + 15))) }
    }

    @Test
    fun anIndexWhoseSamplesPointPastShortenedMediaDataFails() {
        val shortened = ftyp + box("mdat", media.copyOf(15)) + moov(ftyp.size + 8)
        assertFailsWith<Mp4Integrity.InvalidMp4> { Mp4Integrity.check(write("short.m4a", shortened)) }
    }

    @Test
    fun aTakeWithoutAnIndexFails() {
        assertFailsWith<Mp4Integrity.InvalidMp4> { Mp4Integrity.check(write("noindex.m4a", ftyp + box("mdat", media))) }
    }
}
