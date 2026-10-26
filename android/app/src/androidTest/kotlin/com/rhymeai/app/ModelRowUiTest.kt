package com.rhymeai.app

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHeightIsEqualTo
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.unit.dp
import com.rhymeai.app.ui.components.GEMMA_DOWNLOADS
import com.rhymeai.app.ui.components.ModelRow
import com.rhymeai.app.ui.components.ModelRowChipDryness
import com.rhymeai.app.ui.components.catalogModelRowState
import com.rhymeai.app.ui.components.customModelRowState
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.RhymeAITheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** The row's geometry and motion, rendered on the device at the 412dp phone's 370dp row. */
class ModelRowUiTest {
    @get:Rule val compose = createComposeRule()

    private val e2b = GEMMA_DOWNLOADS[0]
    private val e4b = GEMMA_DOWNLOADS[1]
    private val onDisk = e2b.expectedBytes

    private fun e2b(
        fileBytes: Long? = null,
        verified: Boolean = false,
        selected: Boolean = false,
        downloading: Boolean = false,
        progress: Float? = null,
        verifying: Boolean = false,
        pausedBytes: Long? = null,
        deleting: Boolean = false,
        freedBytes: Long? = null
    ) = catalogModelRowState(
        e2b, fileBytes, verified, selected, recommended = true, needsMoreMemory = false,
        downloading = downloading, downloadProgress = progress, verifying = verifying,
        pausedBytes = pausedBytes, deleting = deleting, freedBytes = freedBytes
    )

    private val everyState = listOf(
        e2b(),
        e2b(downloading = true, progress = 0f),
        e2b(downloading = true, progress = 0.43f),
        e2b(pausedBytes = onDisk * 43 / 100),
        e2b(downloading = true, progress = 1f, verifying = true),
        e2b(fileBytes = onDisk, verified = true),
        e2b(fileBytes = onDisk, verified = true, selected = true),
        e2b(fileBytes = 32L, verified = false),
        catalogModelRowState(e4b, null, false, false, recommended = false, needsMoreMemory = true),
        e2b(fileBytes = onDisk, verified = true, deleting = true),
        e2b(freedBytes = onDisk),
        customModelRowState("My song model", 2_100_000_000L, selected = false, deleting = false),
        customModelRowState("My song model", 2_100_000_000L, selected = true, deleting = false)
    )

    private var shown by mutableStateOf(everyState.first())
    private var animations by mutableStateOf(true)

    private fun showRow() {
        compose.setContent {
            RhymeAITheme {
                CompositionLocalProvider(LocalAnimationsEnabled provides animations) {
                    Box(Modifier.width(370.dp)) {
                        ModelRow(
                            state = shown,
                            chipEnabled = true,
                            columnEnabled = true,
                            onChip = {},
                            onColumn = {},
                            mainTag = "main",
                            deleteTag = "delete",
                            cancelTag = "cancel",
                            modifier = Modifier.testTag("row")
                        )
                    }
                }
            }
        }
    }

    @Test fun rowStaysAt89dpInEveryState() {
        showRow()
        everyState.forEach { state ->
            compose.runOnIdle { shown = state }
            compose.waitForIdle()
            try {
                compose.onNodeWithTag("row").assertHeightIsEqualTo(89.dp)
            } catch (error: AssertionError) {
                throw AssertionError("${state.kind} \"${state.metadata}\" / \"${state.warning}\": ${error.message}", error)
            }
        }
    }

    @Test fun aMemoryGatedModelOnDiskNeedsAThirdLine() {
        // Known spec conflict (build spec §2, state 9b): "Richer lines · 5.34 GB on this device"
        // wraps in the 200dp text column and the warning keeps its own line, so this one state
        // grows by one 16dp line at the 412dp phone; every other state holds 89dp.
        shown = catalogModelRowState(e4b, e4b.expectedBytes, true, false, recommended = false, needsMoreMemory = true)
        showRow()
        val height = compose.onNodeWithTag("row").fetchSemanticsNode().size.height / compose.density.density
        assertTrue("grows past 89dp by at most one line: $height", height > 89.5f && height <= 89f + 16f + 0.5f)
    }

    @Test fun choosingAModelWetsTheChipHoldsItThenDriesIt() {
        shown = e2b(fileBytes = onDisk, verified = true)
        showRow()
        compose.mainClock.autoAdvance = false
        compose.runOnIdle { shown = e2b(fileBytes = onDisk, verified = true, selected = true) }
        compose.mainClock.advanceTimeBy(400)
        assertEquals("wet ink during the hold", 0f, dryness(), 0.001f)
        compose.mainClock.advanceTimeBy(1_500)
        assertEquals("still held before 2.0s", 0f, dryness(), 0.001f)
        compose.mainClock.advanceTimeBy(1_600)
        assertEquals("dry once the settle spring lands", 1f, dryness(), 0.02f)
    }

    @Test fun withAnimationsOffEveryChangeLandsInOneFrame() {
        animations = false
        shown = e2b(fileBytes = onDisk, verified = true)
        showRow()
        compose.mainClock.autoAdvance = false

        // Select: straight to the dry chip, no wet phase.
        compose.runOnIdle { shown = e2b(fileBytes = onDisk, verified = true, selected = true) }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        assertEquals(1f, dryness(), 0.001f)
        compose.onNodeWithText("Use").assertDoesNotExist()

        // Delete: the label and column swap in one frame, and so does the freed line.
        compose.runOnIdle { shown = e2b(fileBytes = onDisk, verified = true, deleting = true) }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Deleting…").assertExists()
        compose.onNodeWithText("Selected").assertDoesNotExist()
        compose.onNodeWithTag("delete").assertDoesNotExist()
        compose.runOnIdle { shown = e2b(freedBytes = onDisk) }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("3.43 GB back for your songs").assertExists()
        compose.onNodeWithText("Deleting…").assertDoesNotExist()
    }

    @Test fun withAnimationsOnTheOldLabelIsStillLeavingAfterOneFrame() {
        // The control for the test above: with motion, the dismiss tier keeps the old label a while.
        shown = e2b(fileBytes = onDisk, verified = true)
        showRow()
        compose.mainClock.autoAdvance = false
        compose.runOnIdle { shown = e2b(fileBytes = onDisk, verified = true, deleting = true) }
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Quick drafts · 3.43 GB on this device").assertExists()
    }

    @Test fun downloadingRowReportsItsProgressAndLabels() {
        shown = e2b(downloading = true, progress = 0.43f)
        showRow()
        compose.onNodeWithTag("main")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription, listOf("Pause download of RhymeAI Gemma 4 E2B")))
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "43 percent, 1.47 of 3.43 GB"))
        compose.onNodeWithTag("cancel")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription, listOf("Cancel download of RhymeAI Gemma 4 E2B")))
    }

    private fun dryness(): Float =
        compose.onNodeWithTag("main").fetchSemanticsNode().config[ModelRowChipDryness]
}
