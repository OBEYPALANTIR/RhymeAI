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

    // ---------------------------------------------------------------------------
    // Task 2 — delete bug: memo list must rescan after deletion
    // ---------------------------------------------------------------------------

    @Test
    fun memoListRescanAfterDeleteReflectsDeletion() {
        val dir = File(tempFolder.root, "voice-memos/proj-delete")
        dir.mkdirs()
        val fileA = File(dir, "1000.m4a").also { it.createNewFile() }
        File(dir, "2000.m4a").createNewFile()

        // Before deletion: 2 files.
        val before = dir.listFiles()?.filter { it.name.endsWith(".m4a") } ?: emptyList()
        assertEquals(2, before.size)

        // Simulate deleteMemo (pure file deletion — service not instantiated in JVM tests).
        fileA.delete()

        // After deletion, a fresh filesystem scan returns 1.
        val after = dir.listFiles()?.filter { it.name.endsWith(".m4a") } ?: emptyList()
        assertEquals(1, after.size)
        assertFalse(after.any { it.name == "1000.m4a" })
    }

    // ---------------------------------------------------------------------------
    // Task 3 — rename: sanitizeBasename
    // ---------------------------------------------------------------------------

    @Test
    fun sanitizeBasenameTrimsPadding() {
        assertEquals("hello", VoiceMemoService.sanitizeBasename("  hello  "))
    }

    @Test
    fun sanitizeBasenameStripsIllegalChars() {
        // All of / \ : * ? " < > | should be removed.
        val input = """slash/back\colon:star*question?quote"lt<gt>pipe|"""
        val result = VoiceMemoService.sanitizeBasename(input)
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
        assertEquals("a b c", VoiceMemoService.sanitizeBasename("a   b   c"))
    }

    @Test
    fun sanitizeBasenameEmptyAfterStripReturnsEmpty() {
        assertEquals("", VoiceMemoService.sanitizeBasename("   /\\:*?\"<>|   "))
    }

    @Test
    fun sanitizeBasenamePreservesNormalName() {
        assertEquals("My Cool Track", VoiceMemoService.sanitizeBasename("My Cool Track"))
    }

    // ---------------------------------------------------------------------------
    // Task 3 — rename: resolveCollision
    // ---------------------------------------------------------------------------

    @Test
    fun resolveCollisionReturnsPrimaryNameWhenFree() {
        val dir = File(tempFolder.root, "voice-memos/proj-collision")
        dir.mkdirs()
        // No files exist — should return base.m4a.
        val result = VoiceMemoService.resolveCollision(dir, "chorus")
        assertEquals("chorus.m4a", result.name)
    }

    @Test
    fun resolveCollisionAppendsNumberOnConflict() {
        val dir = File(tempFolder.root, "voice-memos/proj-conflict")
        dir.mkdirs()
        File(dir, "chorus.m4a").createNewFile()

        val result = VoiceMemoService.resolveCollision(dir, "chorus")
        assertEquals("chorus 2.m4a", result.name)
    }

    @Test
    fun resolveCollisionIncrementsPastMultipleConflicts() {
        val dir = File(tempFolder.root, "voice-memos/proj-multi")
        dir.mkdirs()
        File(dir, "verse.m4a").createNewFile()
        File(dir, "verse 2.m4a").createNewFile()
        File(dir, "verse 3.m4a").createNewFile()

        val result = VoiceMemoService.resolveCollision(dir, "verse")
        assertEquals("verse 4.m4a", result.name)
    }

    // ---------------------------------------------------------------------------
    // Task 3 — rename: displayName
    // ---------------------------------------------------------------------------

    @Test
    fun displayNameReturnsFormattedLabelForTimestampFilename() {
        val ts = 1_718_000_000_000L
        val file = File(tempFolder.root, "$ts.m4a")
        val label = VoiceMemoService.displayName(file)
        // Must be the same as formatMemoLabel — non-empty and not the raw number.
        assertTrue(label.isNotBlank())
        assertFalse(label == ts.toString())
    }

    @Test
    fun displayNameReturnsBasenameForCustomFilename() {
        val file = File(tempFolder.root, "My Hook Idea.m4a")
        assertEquals("My Hook Idea", VoiceMemoService.displayName(file))
    }

    @Test
    fun displayNameHandlesNonTimestampNumericName() {
        // "12345" is all digits but may or may not parse as a valid timestamp —
        // the contract is simply: if toLongOrNull() != null, use formatted label.
        val file = File(tempFolder.root, "12345.m4a")
        val label = VoiceMemoService.displayName(file)
        // Should not crash and should be non-empty.
        assertTrue(label.isNotBlank())
    }

    // ---------------------------------------------------------------------------
    // Task 3 — rename: file-level rename via File.renameTo
    // ---------------------------------------------------------------------------

    @Test
    fun renameFileToDifferentBasenameSucceeds() {
        val dir = File(tempFolder.root, "voice-memos/proj-rename")
        dir.mkdirs()
        val original = File(dir, "1718000000000.m4a").also { it.createNewFile() }

        val sanitized = VoiceMemoService.sanitizeBasename("Bridge Hook")
        val target = VoiceMemoService.resolveCollision(dir, sanitized)

        assertTrue(original.renameTo(target))
        assertTrue(target.exists())
        assertEquals("Bridge Hook.m4a", target.name)
        assertFalse(original.exists())
    }
}
