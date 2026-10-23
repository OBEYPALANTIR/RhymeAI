package com.rhymeai.app

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import com.rhymeai.app.service.Mp4Integrity
import java.io.File

/** Real takes for recording tests: a MediaRecorder MPEG-4 file and truncated copies of it. */
internal object TestRecordings {
    /** Records [millis] of microphone audio the way the app does; needs RECORD_AUDIO. */
    fun recordFinalizedM4a(context: Context, target: File, millis: Long = 1_500L): File {
        target.parentFile?.mkdirs()
        val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) MediaRecorder(context) else @Suppress("DEPRECATION") MediaRecorder()
        try {
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC)
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            recorder.setAudioEncodingBitRate(128_000)
            recorder.setAudioSamplingRate(44_100)
            recorder.setOutputFile(target.absolutePath)
            recorder.prepare()
            recorder.start()
            Thread.sleep(millis)
            recorder.stop()
        } finally {
            recorder.release()
        }
        return target
    }

    /** The file cut halfway through its media data. */
    fun cutInsideMediaData(source: File, target: File): File {
        val mdat = Mp4Integrity.topLevelBoxes(source).first { it.type == "mdat" }
        target.writeBytes(source.readBytes().copyOf((mdat.offset + mdat.headerSize + (mdat.size - mdat.headerSize) / 2).toInt()))
        return target
    }

    /** Every box kept, the index intact, but the media data shortened to half. */
    fun mediaDataShortenedKeepingIndex(source: File, target: File): File {
        val bytes = source.readBytes()
        val out = java.io.ByteArrayOutputStream()
        for (box in Mp4Integrity.topLevelBoxes(source)) {
            if (box.type != "mdat") {
                out.write(bytes, box.offset.toInt(), box.size.toInt())
                continue
            }
            val half = ((box.size - box.headerSize) / 2).toInt()
            java.io.DataOutputStream(out).apply { writeInt(8 + half); writeBytes("mdat") }
            out.write(bytes, (box.offset + box.headerSize).toInt(), half)
        }
        target.writeBytes(out.toByteArray())
        return target
    }

    /** Same length and index, every media-data byte zeroed. */
    fun zeroedMediaData(source: File, target: File): File {
        val bytes = source.readBytes()
        for (box in Mp4Integrity.topLevelBoxes(source).filter { it.type == "mdat" }) {
            for (i in (box.offset + box.headerSize).toInt() until (box.offset + box.size).toInt()) bytes[i] = 0
        }
        target.writeBytes(bytes)
        return target
    }

    /** The marker startRecording writes before recording: the take's id, not yet finished. */
    fun startMarker(take: File, id: String): File =
        File(take.parentFile, take.name + ".take").apply { writeText("$id\nrecording\n0\n") }
}

/** An in-memory Drive for tests that run the app's real Restore. */
internal class InMemoryDrive : com.rhymeai.app.data.sync.DriveClient {
    private val files = LinkedHashMap<String, Pair<String, ByteArray>>()
    private var nextId = 0

    fun put(name: String, bytes: ByteArray) {
        val id = files.entries.firstOrNull { it.value.first == name }?.key ?: "id-${nextId++}"
        files[id] = name to bytes
    }

    fun bytes(name: String): ByteArray? = files.values.firstOrNull { it.first == name }?.second

    override suspend fun findFileByName(accessToken: String, name: String) =
        files.entries.firstOrNull { it.value.first == name }?.let { com.rhymeai.app.data.sync.DriveFileMetadata(it.key, name, version = it.value.second.size.toString()) }
    override suspend fun listFilesByNamePrefix(accessToken: String, namePrefix: String) =
        files.filter { it.value.first.startsWith(namePrefix) }.map { com.rhymeai.app.data.sync.DriveFileMetadata(it.key, it.value.first, version = it.value.second.size.toString()) }
    override suspend fun downloadFile(accessToken: String, fileId: String, maxBytes: Long) = files.getValue(fileId).second
    override suspend fun uploadNewFile(
        accessToken: String, name: String, mimeType: String, content: ByteArray, appProperties: Map<String, String>
    ): String = "id-${nextId++}".also { files[it] = name to content }
    override suspend fun updateFile(
        accessToken: String, fileId: String, mimeType: String, content: ByteArray, appProperties: Map<String, String>
    ) {
        files[fileId] = files.getValue(fileId).first to content
    }
    override suspend fun deleteFile(accessToken: String, fileId: String) {
        files.remove(fileId)
    }
    override suspend fun revokeToken(token: String) {}
}
