package com.rhymeai.app.service

import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Pure tests for VoiceMemoService formatting and file-deletion helpers. */
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

    @Test
    fun parseTrashedNameSplitsTimestampAndOriginalName() {
        assertEquals(1700L to "take.m4a", VoiceMemoService.parseTrashedName("1700__take.m4a"))
        assertEquals(1700L to "a__b.m4a", VoiceMemoService.parseTrashedName("1700__a__b.m4a"))
        assertEquals(null, VoiceMemoService.parseTrashedName("take.m4a"))
        assertEquals(null, VoiceMemoService.parseTrashedName("__take.m4a"))
        assertEquals(null, VoiceMemoService.parseTrashedName("abc__take.m4a"))
        assertEquals(null, VoiceMemoService.parseTrashedName("1700__"))
    }

    // ---------------------------------------------------------------------------
    // Task 3 — rename: displayName
    // ---------------------------------------------------------------------------

    @Test
    fun displayNameReturnsFormattedLabelForTimestampFilename() {
        val ts = 1_718_000_000_000L
        val file = "$ts.m4a"
        val label = VoiceMemoService.displayLabel(file)
        // Must be the same as formatMemoLabel — non-empty and not the raw number.
        assertTrue(label.isNotBlank())
        assertFalse(label == ts.toString())
    }

    @Test
    fun displayNameReturnsBasenameForCustomFilename() {
        val file = "My Hook Idea.m4a"
        assertEquals("My Hook Idea", VoiceMemoService.displayLabel(file))
    }

    @Test
    fun displayNameHandlesNonTimestampNumericName() {
        // "12345" is all digits but may or may not parse as a valid timestamp —
        // the contract is simply: if toLongOrNull() != null, use formatted label.
        val file = "12345.m4a"
        val label = VoiceMemoService.displayLabel(file)
        // Should not crash and should be non-empty.
        assertTrue(label.isNotBlank())
    }

}
