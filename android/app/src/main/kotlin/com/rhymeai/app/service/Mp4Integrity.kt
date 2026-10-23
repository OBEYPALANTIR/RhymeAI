package com.rhymeai.app.service

import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer

/**
 * Structural check of an MPEG-4 file (A27): every box fits in the file, there is one
 * `moov` index, and every sample its sample tables list lies inside an `mdat` payload.
 * A recorder writes the index when it finishes, so an unfinished or truncated take
 * fails here. [InvalidMp4] means the bytes are definitively not a finished take; an
 * [java.io.IOException] means the file could not be read and the check can be retried.
 */
internal object Mp4Integrity {
    class InvalidMp4(message: String) : Exception(message)

    class Box(val type: String, val offset: Long, val size: Long, val headerSize: Int)

    class Track(val handler: String, val sampleCount: Int, val duration: Long, val timescale: Long)

    private const val MAX_INDEX_BYTES = 16L * 1024 * 1024

    fun topLevelBoxes(file: File): List<Box> = RandomAccessFile(file, "r").use { raf ->
        val length = raf.length()
        val boxes = mutableListOf<Box>()
        var offset = 0L
        while (offset < length) {
            if (length - offset < 8) throw InvalidMp4("Trailing bytes after the last box")
            raf.seek(offset)
            var size = raf.readInt().toLong() and 0xffffffffL
            val type = ByteArray(4).also { raf.readFully(it) }.toString(Charsets.ISO_8859_1)
            var header = 8
            when (size) {
                1L -> {
                    if (length - offset < 16) throw InvalidMp4("Truncated box header")
                    size = raf.readLong()
                    header = 16
                }
                0L -> size = length - offset
            }
            if (size < header || offset + size > length) throw InvalidMp4("Box $type runs past the end of the file")
            boxes += Box(type, offset, size, header)
            offset += size
        }
        boxes
    }

    fun check(file: File): List<Track> {
        val boxes = topLevelBoxes(file)
        val moov = boxes.singleOrNull { it.type == "moov" } ?: throw InvalidMp4("No single moov index")
        val mdats = boxes.filter { it.type == "mdat" }.map { (it.offset + it.headerSize) until (it.offset + it.size) }
        if (mdats.isEmpty()) throw InvalidMp4("No media data")
        if (moov.size > MAX_INDEX_BYTES) throw InvalidMp4("Index too large")
        val index = ByteArray((moov.size - moov.headerSize).toInt())
        RandomAccessFile(file, "r").use { it.seek(moov.offset + moov.headerSize); it.readFully(index) }
        val tracks = try {
            children(ByteBuffer.wrap(index)).filter { it.first == "trak" }.map { (_, trak) -> track(trak, mdats) }
        } catch (e: IndexOutOfBoundsException) {
            throw InvalidMp4("A box in the index is too short")
        } catch (e: java.nio.BufferUnderflowException) {
            throw InvalidMp4("A box in the index is too short")
        }
        if (tracks.none { it.handler == "soun" && it.sampleCount > 0 && it.duration > 0 && it.timescale > 0 }) {
            throw InvalidMp4("No audio track with samples and a duration")
        }
        return tracks
    }

    /** The child boxes of [parent]'s remaining bytes, as (type, payload). */
    private fun children(parent: ByteBuffer): List<Pair<String, ByteBuffer>> {
        val out = mutableListOf<Pair<String, ByteBuffer>>()
        val buffer = parent.slice()
        while (buffer.remaining() >= 8) {
            val start = buffer.position()
            var size = buffer.int.toLong() and 0xffffffffL
            val type = ByteArray(4).also { buffer.get(it) }.toString(Charsets.ISO_8859_1)
            var header = 8
            if (size == 1L) {
                if (buffer.remaining() < 8) throw InvalidMp4("Truncated box header in index")
                size = buffer.long
                header = 16
            } else if (size == 0L) {
                size = (buffer.limit() - start).toLong()
            }
            if (size < header || start + size > buffer.limit()) throw InvalidMp4("Box $type runs past its parent")
            val payload = buffer.duplicate().apply { position(start + header); limit((start + size).toInt()) }.slice()
            out += type to payload
            buffer.position((start + size).toInt())
        }
        if (buffer.hasRemaining()) throw InvalidMp4("Trailing bytes in index")
        return out
    }

    private fun child(parent: ByteBuffer, type: String): ByteBuffer =
        children(parent).firstOrNull { it.first == type }?.second ?: throw InvalidMp4("Missing $type")

    private fun track(trak: ByteBuffer, mdats: List<LongRange>): Track {
        val mdia = child(trak, "mdia")
        val mdhd = child(mdia, "mdhd")
        val version = mdhd.get(0).toInt()
        val (timescale, duration) = if (version == 1) {
            (mdhd.getInt(20).toLong() and 0xffffffffL) to mdhd.getLong(24)
        } else {
            (mdhd.getInt(12).toLong() and 0xffffffffL) to (mdhd.getInt(16).toLong() and 0xffffffffL)
        }
        val hdlr = child(mdia, "hdlr")
        if (hdlr.limit() < 12) throw InvalidMp4("Short handler box")
        val handler = ByteArray(4) { hdlr.get(8 + it) }.toString(Charsets.ISO_8859_1)
        val stbl = child(child(mdia, "minf"), "stbl")
        val stsz = child(stbl, "stsz")
        val uniformSize = stsz.getInt(4).toLong() and 0xffffffffL
        val sampleCount = stsz.getInt(8)
        if (sampleCount < 0) throw InvalidMp4("Bad sample count")
        fun sampleSize(i: Int): Long = if (uniformSize != 0L) uniformSize else stsz.getInt(12 + 4 * i).toLong() and 0xffffffffL
        if (uniformSize == 0L && stsz.limit() < 12 + 4L * sampleCount) throw InvalidMp4("Sample size table is short")

        val stsc = child(stbl, "stsc")
        val stscEntries = stsc.getInt(4)
        if (stscEntries < 0 || stsc.limit() < 8 + 12L * stscEntries) throw InvalidMp4("Sample-to-chunk table is short")
        val runs = (0 until stscEntries).map { stsc.getInt(8 + 12 * it) to stsc.getInt(12 + 12 * it) }
        val offsets: List<Long> = children(stbl).let { boxes ->
            boxes.firstOrNull { it.first == "stco" }?.second?.let { stco ->
                val n = stco.getInt(4)
                if (n < 0 || stco.limit() < 8 + 4L * n) throw InvalidMp4("Chunk offset table is short")
                (0 until n).map { stco.getInt(8 + 4 * it).toLong() and 0xffffffffL }
            } ?: boxes.firstOrNull { it.first == "co64" }?.second?.let { co64 ->
                val n = co64.getInt(4)
                if (n < 0 || co64.limit() < 8 + 8L * n) throw InvalidMp4("Chunk offset table is short")
                (0 until n).map { co64.getLong(8 + 8 * it) }
            } ?: throw InvalidMp4("Missing chunk offsets")
        }
        // Every listed sample must lie inside one mdat payload.
        var sample = 0
        for ((chunk, chunkOffset) in offsets.withIndex()) {
            val perChunk = runs.lastOrNull { it.first <= chunk + 1 }?.second ?: throw InvalidMp4("Chunk without samples")
            var offset = chunkOffset
            repeat(perChunk) {
                if (sample >= sampleCount) throw InvalidMp4("Chunks list more samples than the size table")
                val end = offset + sampleSize(sample)
                if (mdats.none { offset >= it.first && end <= it.last + 1 }) throw InvalidMp4("Sample $sample lies outside the media data")
                offset = end
                sample++
            }
        }
        if (sample != sampleCount) throw InvalidMp4("Chunks cover $sample of $sampleCount samples")
        return Track(handler, sampleCount, duration, timescale)
    }
}
