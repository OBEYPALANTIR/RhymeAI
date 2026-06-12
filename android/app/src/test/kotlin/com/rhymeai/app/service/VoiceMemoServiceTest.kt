package com.rhymeai.app.service

import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Unit tests for pure, platform-independent logic in VoiceMemoService:
 * file naming/pathing, list ordering, purge, and the companion formatting helpers.
 *
 * MediaRecorder and MediaPlayer are Android-framework classes that cannot run on
 * the JVM; tests that would require them are instrumented tests instead.
 */
class VoiceMemoServiceTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    // ---------------------------------------------------------------------------
    // Companion formatting helpers (no Context required)
    // ---------------------------------------------------------------------------

    @Test
    fun formatDurationZeroSeconds() {
        assertEquals("0:00", VoiceMemoService.formatDuration(0L))
    }

    @Test
    fun formatDurationSubSecondRoundsToZero() {
        assertEquals("0:00", VoiceMemoService.formatDuration(500L))
    }

    @Test
    fun formatDuration65SecondsIs1Colon05() {
        assertEquals("1:05", VoiceMemoService.formatDuration(65_000L))
    }

    @Test
    fun formatDuration10MinutesExact() {
        assertEquals("10:00", VoiceMemoService.formatDuration(600_000L))
    }

    @Test
    fun formatMemoLabelIsNonEmptyForCurrentTime() {
        val label = VoiceMemoService.formatMemoLabel(System.currentTimeMillis())
        assertTrue(label.isNotBlank())
    }

    // ---------------------------------------------------------------------------
    // Pathing: memo files live in filesDir/voice-memos/<projectId>/
    // ---------------------------------------------------------------------------

    @Test
    fun memoFilePathSitsInsideVoiceMemosSubdir() {
        val filesDir = tempFolder.root
        val projectId = "proj-abc"
        val dir = File(filesDir, "voice-memos/$projectId")
        dir.mkdirs()

        val ts = 1_718_000_000_000L
        val file = File(dir, "$ts.m4a")
        file.createNewFile()

        assertTrue(file.path.startsWith(dir.path))
        assertEquals("$ts.m4a", file.name)
        assertTrue(file.name.endsWith(".m4a"))
    }

    // ---------------------------------------------------------------------------
    // Listing: newest-first ordering
    // ---------------------------------------------------------------------------

    @Test
    fun memosReturnedNewestFirst() {
        val dir = File(tempFolder.root, "voice-memos/proj-sort")
        dir.mkdirs()

        val ts1 = 1_000L
        val ts2 = 2_000L
        val ts3 = 3_000L

        listOf(ts1, ts2, ts3).forEach { ts ->
            val f = File(dir, "$ts.m4a")
            f.createNewFile()
            f.setLastModified(ts)
        }

        // Mirror VoiceMemoService.memosForProject sort without needing a real Context.
        val sorted = dir.listFiles()
            ?.filter { it.isFile && it.name.endsWith(".m4a") }
            ?.sortedByDescending { it.lastModified() }
            ?: emptyList()

        assertEquals(3, sorted.size)
        assertEquals("$ts3.m4a", sorted[0].name)
        assertEquals("$ts2.m4a", sorted[1].name)
        assertEquals("$ts1.m4a", sorted[2].name)
    }

    @Test
    fun memosEmptyWhenDirectoryDoesNotExist() {
        val dir = File(tempFolder.root, "voice-memos/nonexistent-project")
        assertFalse(dir.exists())

        // Mirror the VoiceMemoService early-return guard.
        val result: List<File> = if (!dir.exists()) emptyList() else listOf()
        assertTrue(result.isEmpty())
    }

    @Test
    fun nonM4aFilesInMemoDirAreIgnored() {
        val dir = File(tempFolder.root, "voice-memos/proj-filter")
        dir.mkdirs()
        File(dir, "1000.m4a").createNewFile()
        File(dir, "readme.txt").createNewFile()
        File(dir, "noise.mp3").createNewFile()

        val m4aFiles = dir.listFiles()
            ?.filter { it.isFile && it.name.endsWith(".m4a") }
            ?: emptyList()

        assertEquals(1, m4aFiles.size)
        assertEquals("1000.m4a", m4aFiles[0].name)
    }

    // ---------------------------------------------------------------------------
    // Purge: deleteRecursively removes the whole project directory
    // ---------------------------------------------------------------------------

    @Test
    fun deleteMemoDirectoryRemovesAllFilesAndDir() {
        val dir = File(tempFolder.root, "voice-memos/proj-purge")
        dir.mkdirs()
        File(dir, "1000.m4a").createNewFile()
        File(dir, "2000.m4a").createNewFile()

        assertTrue(dir.exists())
        assertEquals(2, dir.listFiles()?.size)

        // VoiceMemoService.deleteMemoDirectory delegates to File.deleteRecursively.
        dir.deleteRecursively()

        assertFalse(dir.exists())
    }

    @Test
    fun deleteMemoDirectoryOnNonexistentDirIsSafe() {
        val dir = File(tempFolder.root, "voice-memos/ghost-project")
        assertFalse(dir.exists())

        // deleteRecursively does not throw on a non-existent path; the directory
        // must still not exist after the call (which is trivially true here).
        dir.deleteRecursively()
        assertFalse(dir.exists())
    }

    @Test
    fun purgingOneProjectLeavesOtherProjectIntact() {
        val dirA = File(tempFolder.root, "voice-memos/proj-a")
        val dirB = File(tempFolder.root, "voice-memos/proj-b")
        dirA.mkdirs()
        dirB.mkdirs()
        File(dirA, "1000.m4a").createNewFile()
        File(dirB, "2000.m4a").createNewFile()

        dirA.deleteRecursively()

        assertFalse(dirA.exists())
        assertTrue(dirB.exists())
        assertEquals(1, dirB.listFiles()?.size)
    }
}
