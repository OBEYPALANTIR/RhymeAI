package com.rhymeai.app.service

import com.rhymeai.app.data.recording.RecordingFiles
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

    private var ids = 0
    private fun nextId() = "0f8fad5b-d9cb-469f-a165-%012d".format(++ids)
    private fun stage(input: InputStream, dir: File, id: String, name: String, check: () -> Unit, validate: (File) -> Unit) =
        RecordingImportStore.stage(input, dir, id, name, check, validate)

    @Test fun importsAreStagedUnderTheirIdAndKeepTheDisplayName() {
        val song = temporary.newFolder("song")
        val other = temporary.newFolder("other")
        val existing = File(song, "take.wav").apply { writeText("original") }
        val untouched = File(other, "take.wav").apply { writeText("other song") }
        val id = nextId()
        val imported = stage(ByteArrayInputStream(byteArrayOf(1, 2, 3)), song, id, "take.WAV", {}, { assertEquals(3, it.length()) })
        assertEquals("$id.wav", imported.file.name)
        assertEquals("take.wav", imported.desiredName)
        assertEquals("original", existing.readText())
        assertEquals("other song", untouched.readText())
        assertContentEquals(byteArrayOf(1, 2, 3), imported.file.readBytes())
        assertTrue(RecordingFiles.isMemoFile(imported.file))
    }

    @Test fun invalidAudioAndEmptyInputLeaveNoFile() {
        val song = temporary.newFolder()
        assertFailsWith<IllegalArgumentException> {
            stage(ByteArrayInputStream(byteArrayOf(1)), song, nextId(), "bad.mp3", {}, { throw IllegalArgumentException("invalid") })
        }
        assertFailsWith<IllegalArgumentException> {
            stage(ByteArrayInputStream(byteArrayOf()), song, nextId(), "empty.m4a", {}, { fail("Empty file must not reach validation") })
        }
        assertTrue(song.listFiles().orEmpty().isEmpty())
    }

    @Test fun cancellationAfterCopyAndValidationRemovesStagedFile() {
        val song = temporary.newFolder()
        var validated = false
        assertFailsWith<CancellationException> {
            stage(ByteArrayInputStream(byteArrayOf(1)), song, nextId(), "take.aac",
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
            stage(source, song, nextId(), "take.wav", {}, { fail("Provider must close before validation") })
        }
        assertTrue(song.listFiles().orEmpty().isEmpty())
    }

    @Test fun copyFailureRemovesPartialFile() {
        val song = temporary.newFolder()
        val input = object : InputStream() {
            override fun read(): Int = throw IOException("read failed")
        }
        assertFailsWith<IOException> { stage(input, song, nextId(), "take.wav", {}, {}) }
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
        assertFailsWith<IllegalArgumentException> { stage(input, song, nextId(), "long.wav", {}, {}) }
        assertTrue(song.listFiles().orEmpty().isEmpty())
    }

    @Test fun hiddenImportNamesBecomeVisibleOnBothPlatforms() {
        val song = temporary.newFolder()
        val imported = stage(ByteArrayInputStream(byteArrayOf(1)), song, nextId(), ".take.wav", {}, {})
        assertEquals("Imported recording.wav", imported.desiredName)
        assertFalse(imported.file.isHidden)
    }

    @Test fun longUnicodeNamesAreTrimmedAndDuplicatesStageSideBySide() {
        val song = temporary.newFolder()
        val name = "曲".repeat(80) + ".wav"
        val first = stage(ByteArrayInputStream(byteArrayOf(1)), song, nextId(), name, {}, {})
        val duplicate = stage(ByteArrayInputStream(byteArrayOf(2)), song, nextId(), name, {}, {})
        assertEquals("曲".repeat(66) + ".wav", first.desiredName)
        assertEquals(first.desiredName, duplicate.desiredName)
        assertEquals(2, song.listFiles().orEmpty().count { it.extension == "wav" })
        // Each staged import carries its ownership marker until its importer saves or discards it.
        assertTrue(RecordingImportStore.markerFor(first.file).exists() && RecordingImportStore.markerFor(duplicate.file).exists())
    }

    @Test fun importedNamesRemoveControlsAndRetainWholeUnicodeCharacters() {
        val song = temporary.newFolder()
        val imported = stage(ByteArrayInputStream(byteArrayOf(1)), song, nextId(), "verse\u0000\u0001\u200B\nidea.wav", {}, {})
        assertEquals("verse idea.wav", imported.desiredName)
        val emoji = RecordingFiles.sanitizeBasename("🎵".repeat(60))
        assertEquals("🎵".repeat(50), emoji)
        assertEquals(200, emoji.toByteArray().size)
    }

    @Test fun filenamesCannotEscapeSongAndStagingFilesAreNotRecordings() {
        val song = temporary.newFolder()
        val result = stage(ByteArrayInputStream(byteArrayOf(1)), song, nextId(), "../outside.wav", {}, {})
        assertEquals(song.canonicalFile, result.file.canonicalFile.parentFile)
        val pending = File(song, "import.pending").apply { writeText("partial") }
        assertFalse(RecordingFiles.isMemoFile(pending))
        assertFailsWith<IllegalArgumentException> {
            stage(ByteArrayInputStream(byteArrayOf(1)), song, nextId(), "video.mp4", {}, {})
        }
    }
}
