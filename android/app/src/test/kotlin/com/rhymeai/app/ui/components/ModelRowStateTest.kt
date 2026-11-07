package com.rhymeai.app.ui.components

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The copy every model-row state shows and announces (build spec §2 and §5). */
class ModelRowStateTest {
    private val e2b = GEMMA_DOWNLOADS[0]
    private val e4b = GEMMA_DOWNLOADS[1]
    private val e2bBytes = e2b.expectedBytes

    private fun e2b(
        fileBytes: Long? = null,
        verified: Boolean = false,
        selected: Boolean = false,
        recommended: Boolean = true,
        downloading: Boolean = false,
        progress: Float? = null,
        verifying: Boolean = false,
        pausedBytes: Long? = null,
        deleting: Boolean = false,
        freedBytes: Long? = null
    ) = catalogModelRowState(
        e2b, fileBytes, verified, selected, recommended, needsMoreMemory = false,
        downloading = downloading, downloadProgress = progress, verifying = verifying,
        pausedBytes = pausedBytes, deleting = deleting, freedBytes = freedBytes
    )

    @Test fun catalogTitlesCarryTheGemma4Name() {
        assertEquals(listOf("RhymeAI Gemma 4 E2B", "RhymeAI Gemma 4 E4B"), GEMMA_DOWNLOADS.map { it.label })
        assertEquals(listOf("Quick drafts", "Richer lines"), GEMMA_DOWNLOADS.map { it.character })
    }

    @Test fun notDownloaded() {
        val row = e2b()
        assertEquals(ModelRowKind.NotDownloaded, row.kind)
        assertEquals("Quick drafts · 3.43 GB · Recommended", row.metadata)
        assertEquals(ModelRowChip.Download, row.chip)
        assertEquals(ModelRowColumn.None, row.column)
        assertEquals("Download RhymeAI Gemma 4 E2B", row.a11yLabel)
        assertEquals("Quick drafts, 3.43 GB, Recommended", row.a11yValue)
        assertFalse(row.hasLine)
        val richer = catalogModelRowState(e4b, null, false, false, recommended = false, needsMoreMemory = false)
        assertEquals("Richer lines · 5.34 GB", richer.metadata)
        assertNull(richer.warning)
    }

    @Test fun startingThenDownloading() {
        val starting = e2b(downloading = true, progress = 0f)
        assertEquals(ModelRowKind.Starting, starting.kind)
        assertEquals("Starting download…", starting.metadata)
        assertEquals(ModelRowChip.Pause, starting.chip)
        assertEquals(ModelRowColumn.Cancel, starting.column)
        assertNull("the line loops: no length yet", starting.progress)

        val writing = e2b(downloading = true, progress = 0.43f)
        assertEquals("1.47 of 3.43 GB · 43%", writing.metadata)
        assertEquals("Pause download of RhymeAI Gemma 4 E2B", writing.a11yLabel)
        assertEquals("43 percent, 1.47 of 3.43 GB", writing.a11yValue)
        assertEquals("Cancel download of RhymeAI Gemma 4 E2B", writing.columnLabel)
        assertEquals(0.43f, writing.progress!!, 0.0001f)
    }

    @Test fun pausedKeepsItsBytes() {
        val paused = e2b(pausedBytes = (e2bBytes * 0.43).toLong())
        assertEquals(ModelRowKind.Paused, paused.kind)
        assertEquals("Paused · 1.47 of 3.43 GB", paused.metadata)
        assertEquals(ModelRowChip.Resume, paused.chip)
        assertEquals(ModelRowColumn.Cancel, paused.column)
        assertEquals("Resume download of RhymeAI Gemma 4 E2B", paused.a11yLabel)
        assertEquals("Paused, 1.47 of 3.43 GB", paused.a11yValue)
        assertEquals(0.43f, paused.progress!!, 0.001f)
    }

    @Test fun checkingHasNoChipAndNoColumn() {
        val checking = e2b(downloading = true, progress = 1f, verifying = true)
        assertEquals("Checking the file…", checking.metadata)
        assertNull(checking.chip)
        assertEquals(ModelRowColumn.None, checking.column)
        assertEquals(1f, checking.progress)
        assertEquals("RhymeAI Gemma 4 E2B", checking.a11yLabel)
        assertEquals("Checking the file", checking.a11yValue)
    }

    @Test fun downloadedSelectedAndStale() {
        val downloaded = e2b(fileBytes = e2bBytes, verified = true)
        assertEquals("Quick drafts · 3.43 GB on this device", downloaded.metadata)
        assertEquals(ModelRowChip.Use, downloaded.chip)
        assertEquals(ModelRowColumn.Trash, downloaded.column)
        assertEquals("Use RhymeAI Gemma 4 E2B", downloaded.a11yLabel)
        assertEquals("Delete RhymeAI Gemma 4 E2B", downloaded.columnLabel)

        val selected = e2b(fileBytes = e2bBytes, verified = true, selected = true)
        assertEquals("In use · 3.43 GB on this device", selected.metadata)
        assertEquals(ModelRowChip.Selected, selected.chip)
        assertEquals("RhymeAI Gemma 4 E2B", selected.a11yLabel)
        assertEquals("In use, 3.43 GB on this device", selected.a11yValue)

        val stale = e2b(fileBytes = 32L, verified = false, selected = true)
        assertEquals(ModelRowKind.Stale, stale.kind)
        assertNull(stale.metadata)
        assertEquals("Older version on this device", stale.warning)
        assertEquals(ModelRowChip.Update, stale.chip)
        assertEquals(ModelRowColumn.Trash, stale.column)
        assertEquals("Update RhymeAI Gemma 4 E2B", stale.a11yLabel)
    }

    @Test fun memoryGateWarnsOnItsOwnLine() {
        val gated = catalogModelRowState(e4b, null, false, false, recommended = false, needsMoreMemory = true)
        assertEquals("Richer lines · 5.34 GB", gated.metadata)
        assertEquals("Writes slowly: needs 10 GB", gated.warning)
        assertEquals(ModelRowChip.Download, gated.chip)
        assertEquals("Richer lines, 5.34 GB, Writes slowly, needs 10 GB memory", gated.a11yValue)

        val gatedOnDisk = catalogModelRowState(e4b, e4b.expectedBytes, true, false, recommended = false, needsMoreMemory = true)
        assertEquals("Richer lines · 5.34 GB on this device", gatedOnDisk.metadata)
        assertEquals("Writes slowly: needs 10 GB", gatedOnDisk.warning)
        assertEquals(ModelRowColumn.Trash, gatedOnDisk.column)
        // The download line replaces the gate while bytes arrive.
        assertNull(catalogModelRowState(e4b, null, false, false, false, true, downloading = true, downloadProgress = 0.5f).warning)
    }

    @Test fun deletingThenFreed() {
        val deleting = e2b(fileBytes = e2bBytes, verified = true, selected = true, deleting = true)
        assertEquals("Deleting…", deleting.metadata)
        assertNull(deleting.chip)
        assertEquals(ModelRowColumn.Spinner, deleting.column)
        assertEquals("Deleting RhymeAI Gemma 4 E2B", deleting.columnLabel)

        val freed = e2b(freedBytes = e2bBytes)
        assertEquals(ModelRowKind.Freed, freed.kind)
        assertEquals("3.43 GB back for your songs", freed.metadata)
        assertEquals(ModelRowChip.Download, freed.chip)
        assertEquals(ModelRowColumn.None, freed.column)
        // A file back under the name wins over a stale freed line.
        assertEquals(ModelRowKind.Downloaded, e2b(fileBytes = e2bBytes, verified = true, freedBytes = e2bBytes).kind)
    }

    @Test fun downloadingWinsOverPausedAndStale() {
        assertEquals(ModelRowKind.Downloading, e2b(fileBytes = 32L, downloading = true, progress = 0.2f, pausedBytes = 10L).kind)
        assertEquals(ModelRowKind.Paused, e2b(fileBytes = 32L, pausedBytes = 10L).kind)
    }

    @Test fun customModels() {
        val imported = customModelRowState("My Song Model", 2_100_000_000L, selected = false, deleting = false)
        assertEquals("Imported · 2.10 GB on this device", imported.metadata)
        assertEquals(ModelRowChip.Use, imported.chip)
        assertEquals(ModelRowColumn.Trash, imported.column)
        assertEquals("Use My Song Model", imported.a11yLabel)
        assertEquals("Delete My Song Model", imported.columnLabel)
        val inUse = customModelRowState("My Song Model", 2_100_000_000L, selected = true, deleting = false)
        assertEquals("In use · 2.10 GB on this device", inUse.metadata)
        assertEquals(ModelRowChip.Selected, inUse.chip)
        assertEquals(ModelRowKind.Deleting, customModelRowState("x", 1L, selected = true, deleting = true).kind)
    }

    @Test fun deleteMessageAddsTheInUseSentenceOnlyForTheSelectedModel() {
        assertEquals(
            "Frees 3.43 GB on this device. You can download it again later.",
            modelDeleteMessage(e2bBytes, custom = false, inUse = false).text
        )
        assertEquals(
            "Frees 3.43 GB on this device. You can download it again later. " +
                "It's in use now; on-device suggestions stop until you choose another model.",
            modelDeleteMessage(e2bBytes, custom = false, inUse = true).text
        )
        assertEquals(
            "Frees 2.10 GB on this device. You can import it again later.",
            modelDeleteMessage(2_100_000_000L, custom = true, inUse = false).text
        )
        val sized = modelDeleteMessage(e2bBytes, custom = false, inUse = false)
        assertTrue("the size is set in medium weight", sized.spanStyles.any { sized.text.substring(it.start, it.end) == "3.43 GB" })
    }
}
