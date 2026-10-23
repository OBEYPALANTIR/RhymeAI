package com.rhymeai.app.data.recording

import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RecordingFilesTest {
    @get:Rule val tempFolder = TemporaryFolder()

    @Test
    fun liveAndTrashPathsKeepProjectsAndRootsSeparate() {
        val root = tempFolder.root
        val live = RecordingFiles.memoDirectory(root, "song-a")
        val trash = RecordingFiles.trashDirectory(root, "song-a")
        assertEquals(File(root, "voice-memos"), RecordingFiles.memosRoot(root))
        assertEquals(File(root, "voice-memos-trash"), RecordingFiles.trashRoot(root))
        assertEquals(File(root, "voice-memos/song-a").canonicalFile, live)
        assertEquals(File(root, "voice-memos-trash/song-a").canonicalFile, trash)
        assertFalse(live.exists())
        assertFalse(trash.exists())
        live.mkdirs()
        trash.mkdirs()
        File(live, "take.wav").writeText("live")
        File(trash, "123__take.wav").writeText("trash")
        val otherSong = RecordingFiles.memoDirectory(root, "song-b").apply { mkdirs() }
        assertTrue(otherSong.listFiles().orEmpty().isEmpty())
        assertEquals("live", File(live, "take.wav").readText())
        assertEquals("trash", File(trash, "123__take.wav").readText())
    }

    @Test
    fun recognizesSupportedAudioFilesAndExcludesStagingFilesAndDirectories() {
        val dir = tempFolder.newFolder()
        val supported = listOf("take.m4a", "take.MP3", "take.WaV", "take.aac")
        (supported + listOf("import.pending", ".take.wav.123.tmp", "readme.txt", "video.mp4"))
            .forEach { File(dir, it).writeText(it) }
        File(dir, "folder.wav").mkdir()
        val recognized = dir.listFiles().orEmpty().filter(RecordingFiles::isMemoFile)
        assertEquals(supported.toSet(), recognized.map { it.name }.toSet())
        assertFalse(RecordingFiles.isMemoFile(File(dir, "missing.wav")))
    }

    @Test
    fun sanitizeBasenameTrimsPadding() {
        assertEquals("hello", RecordingFiles.sanitizeBasename("  hello  "))
    }

    @Test
    fun sanitizeBasenameStripsIllegalChars() {
        // All of / \ : * ? " < > | should be removed.
        val input = """slash/back\colon:star*question?quote"lt<gt>pipe|"""
        val result = RecordingFiles.sanitizeBasename(input)
        assertFalse(result.contains('/'))
        assertFalse(result.contains('\\'))
        assertFalse(result.contains(':'))
        assertFalse(result.contains('*'))
        assertFalse(result.contains('?'))
        assertFalse(result.contains('"'))
        assertFalse(result.contains('<'))
        assertFalse(result.contains('>'))
        assertFalse(result.contains('|'))
    }

    @Test
    fun sanitizeBasenameCollapsesWhitespace() {
        assertEquals("a b c", RecordingFiles.sanitizeBasename("a   b   c"))
    }

    @Test
    fun sanitizeBasenameEmptyAfterStripReturnsEmpty() {
        assertEquals("", RecordingFiles.sanitizeBasename("   /\\:*?\"<>|   "))
    }

    @Test
    fun sanitizeBasenamePreservesNormalName() {
        assertEquals("My Cool Track", RecordingFiles.sanitizeBasename("My Cool Track"))
    }

    @Test
    fun recordingFilesAreNamedByTheirId() {
        val id = "0f8fad5b-d9cb-469f-a165-70867728950e"
        assertEquals("$id.m4a", RecordingFiles.idFileName(id, "Chorus idea.m4a"))
        assertEquals("$id.wav", RecordingFiles.idFileName(id, "take.WAV"))
        assertEquals("$id.m4a", RecordingFiles.idFileName(id, "no extension"))
        assertEquals(id, RecordingFiles.idOf(File("$id.m4a")))
        assertEquals(null, RecordingFiles.idOf(File("take.m4a")))
        assertEquals(null, RecordingFiles.idOf(File("$id.txt")))
        val memo = RecordingFiles.memoFile(tempFolder.root, "p", id, "take.m4a")
        assertEquals("$id.m4a", memo.name)
        assertEquals("p", memo.parentFile!!.name)
    }
}
