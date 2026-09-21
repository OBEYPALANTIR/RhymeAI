package com.rhymeai.app.service

import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.io.IOException
import kotlinx.coroutines.CancellationException
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import kotlin.test.*

class RecordingImportStoreTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun duplicateNamesKeepOriginalBytesAndOtherSongsIsolated() {
        val song = temporary.newFolder("song")
        val other = temporary.newFolder("other")
        val existing = File(song, "take.wav").apply { writeText("original") }
        val untouched = File(other, "take.wav").apply { writeText("other song") }
        val imported = RecordingImportStore.copy(ByteArrayInputStream(byteArrayOf(1, 2, 3)), song, "take.WAV", {}, { assertEquals(3, it.length()) })
        assertEquals("take 2.wav", imported.name)
        assertEquals("original", existing.readText())
        assertEquals("other song", untouched.readText())
        assertContentEquals(byteArrayOf(1, 2, 3), imported.readBytes())
        assertTrue(VoiceMemoService.isMemoFile(imported))
    }

    @Test fun invalidAudioAndEmptyInputLeaveNoFile() {
        val song = temporary.newFolder()
        assertFailsWith<IllegalArgumentException> {
            RecordingImportStore.copy(ByteArrayInputStream(byteArrayOf(1)), song, "bad.mp3", {}, { throw IllegalArgumentException("invalid") })
        }
        assertFailsWith<IllegalArgumentException> {
            RecordingImportStore.copy(ByteArrayInputStream(byteArrayOf()), song, "empty.m4a", {}, { fail("Empty file must not reach validation") })
        }
        assertTrue(song.listFiles().orEmpty().isEmpty())
    }

    @Test fun cancellationAfterCopyAndValidationRemovesStagedFile() {
        val song = temporary.newFolder()
        var validated = false
        assertFailsWith<CancellationException> {
            RecordingImportStore.copy(ByteArrayInputStream(byteArrayOf(1)), song, "take.aac",
                { if (validated) throw CancellationException() }, { validated = true })
        }
        assertTrue(validated)
        assertTrue(song.listFiles().orEmpty().isEmpty())
    }

    @Test fun providerCloseFailureCannotPublishRecording() {
        val song = temporary.newFolder()
        val source = object : ByteArrayInputStream(byteArrayOf(1)) {
            override fun close() { throw IOException("provider close failed") }
        }
        assertFailsWith<IOException> {
            RecordingImportStore.copy(source, song, "take.wav", {}, { fail("Provider must close before validation") })
        }
        assertTrue(song.listFiles().orEmpty().isEmpty())
    }

    @Test fun copyFailureRemovesPartialFile() {
        val song = temporary.newFolder()
        val input = object : InputStream() {
            override fun read(): Int = throw IOException("read failed")
        }
        assertFailsWith<IOException> { RecordingImportStore.copy(input, song, "take.wav", {}, {}) }
        assertTrue(song.listFiles().orEmpty().isEmpty())
    }

    @Test fun oversizedFileIsRejectedWithoutLeavingPartialAudio() {
        val song = temporary.newFolder()
        var remaining = RecordingImportStore.MAX_IMPORT_BYTES + 1
        val input = object : InputStream() {
            override fun read(): Int = if (remaining-- > 0) 0 else -1
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
                if (remaining <= 0) return -1
                val count = minOf(remaining, length.toLong()).toInt()
                remaining -= count
                return count
            }
        }
        assertFailsWith<IllegalArgumentException> { RecordingImportStore.copy(input, song, "long.wav", {}, {}) }
        assertTrue(song.listFiles().orEmpty().isEmpty())
    }

    @Test fun unicodeNamesLeaveRoomForDuplicateAndTrashNames() {
        val song = temporary.newFolder()
        val name = "曲".repeat(80) + ".wav"
        val first = RecordingImportStore.copy(ByteArrayInputStream(byteArrayOf(1)), song, name, {}, {})
        val duplicate = RecordingImportStore.copy(ByteArrayInputStream(byteArrayOf(2)), song, name, {}, {})
        assertEquals("曲".repeat(66) + ".wav", first.name)
        assertEquals("曲".repeat(66) + " 2.wav", duplicate.name)
        assertTrue(("${System.currentTimeMillis()}__${duplicate.name}").toByteArray().size <= 240)
        assertEquals(2, song.listFiles().orEmpty().size)
    }

    @Test fun importedNamesRemoveControlsAndRetainWholeUnicodeCharacters() {
        val song = temporary.newFolder()
        val imported = RecordingImportStore.copy(ByteArrayInputStream(byteArrayOf(1)), song, "verse\u0000\u0001\u200B\nidea.wav", {}, {})
        assertEquals("verse idea.wav", imported.name)
        val emoji = VoiceMemoService.sanitizeBasename("🎵".repeat(60))
        assertEquals("🎵".repeat(50), emoji)
        assertEquals(200, emoji.toByteArray().size)
    }

    @Test fun filenamesCannotEscapeSongAndStagingFilesAreNotRecordings() {
        val song = temporary.newFolder()
        val result = RecordingImportStore.copy(ByteArrayInputStream(byteArrayOf(1)), song, "../outside.wav", {}, {})
        assertEquals(song.canonicalFile, result.canonicalFile.parentFile)
        val pending = File(song, "import.pending").apply { writeText("partial") }
        assertFalse(VoiceMemoService.isMemoFile(pending))
        assertFailsWith<IllegalArgumentException> {
            RecordingImportStore.copy(ByteArrayInputStream(byteArrayOf(1)), song, "video.mp4", {}, {})
        }
    }
}
