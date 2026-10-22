package com.rhymeai.app

import com.rhymeai.app.data.recording.RecordingFiles
import android.content.Context
import android.content.ContextWrapper
import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.net.Uri
import android.provider.DocumentsContract
import androidx.core.content.IntentCompat
import com.rhymeai.app.service.VoiceMemoService
import com.rhymeai.app.ui.components.OpenAudioDocument
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import org.junit.Assert.*

@RunWith(AndroidJUnit4::class)
class RecordingImportInstrumentedTest {
    @Test fun importsPlayableWavWithoutRecordingAndKeepsSongIdentityThroughRenameTrashRestore() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val owned = File(context.filesDir, "recording-test-${UUID.randomUUID()}").apply { mkdirs() }
        val isolated = object : ContextWrapper(context) { override fun getFilesDir(): File = owned }
        val service = VoiceMemoService(isolated)
        try {
            val source = File(owned, "take.wav").apply { writeBytes(wav()) }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", source)
            val first = service.importRecording("song-a", uri)
            val second = service.importRecording("song-a", uri)
            assertTrue(first.durationMs > 0)
            assertFalse(service.isRecording)
            assertEquals(2, service.memosForProject("song-a").size)
            assertTrue(service.memosForProject("song-b").isEmpty())
            assertNotEquals(first.file.name, second.file.name)
            assertArrayEquals(source.readBytes(), first.file.readBytes())
            val renamed = requireNotNull(service.renameMemo(first, "Verse idea"))
            assertEquals("Verse idea.wav", renamed.file.name)
            val trashed = requireNotNull(service.trashMemo(renamed))
            assertEquals(1, service.trashedMemos().size)
            assertTrue(service.restoreTrashedMemo(trashed))
            assertEquals(2, service.memosForProject("song-a").size)
            assertTrue(service.trashedMemos().isEmpty())
        } finally {
            service.release()
            owned.deleteRecursively()
        }
    }

    @Test fun rejectsRenamedTextAndLeavesNoImportedRecording() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val owned = File(context.filesDir, "recording-test-${UUID.randomUUID()}").apply { mkdirs() }
        val service = VoiceMemoService(object : ContextWrapper(context) { override fun getFilesDir(): File = owned })
        try {
            val source = File(owned, "fake.wav").apply { writeText("This is not audio") }
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", source)
            try {
                service.importRecording("song", uri)
                fail("Invalid audio must be rejected")
            } catch (_: IllegalArgumentException) {
                // Invalid container or absence of an audio track is rejected.
            } catch (_: java.io.IOException) {
                // Some platform extractors report invalid containers as I/O errors.
            }
            assertTrue(service.memosForProject("song").isEmpty())
            assertTrue(RecordingFiles.memoDirectory(owned, "song").listFiles().orEmpty().isEmpty())
        } finally {
            service.release()
            owned.deleteRecursively()
        }
    }

    @Test fun importPickerStartsOnTheAudioRootInsteadOfEmptyRecent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val intent = OpenAudioDocument.createIntent(context, arrayOf("audio/*"))
        val start = requireNotNull(IntentCompat.getParcelableExtra(intent, DocumentsContract.EXTRA_INITIAL_URI, Uri::class.java))
        assertEquals("audio_root", DocumentsContract.getRootId(start))
        // The provider must exist on the device, or the picker falls back to the empty Recent screen.
        assertNotNull(context.packageManager.resolveContentProvider(requireNotNull(start.authority), 0))
    }

    private fun wav(): ByteArray {
        val samples = 8000
        return ByteBuffer.allocate(44 + samples * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt(36 + samples * 2); put("WAVEfmt ".toByteArray())
            putInt(16); putShort(1); putShort(1); putInt(8000); putInt(16000); putShort(2); putShort(16)
            put("data".toByteArray()); putInt(samples * 2)
            repeat(samples) { putShort((kotlin.math.sin(it * 2 * Math.PI * 440 / 8000) * 1000).toInt().toShort()) }
        }.array()
    }
}
