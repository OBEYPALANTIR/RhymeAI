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

    /** The marker startRecording writes before recording: the take's id, not yet finished. */
    fun startMarker(take: File, id: String): File =
        File(take.parentFile, take.name + ".take").apply { writeText("$id\nrecording\n0\n") }
}
