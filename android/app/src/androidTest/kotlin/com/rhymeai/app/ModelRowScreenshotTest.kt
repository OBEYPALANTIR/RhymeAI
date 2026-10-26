package com.rhymeai.app

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import com.rhymeai.app.data.model.SavedLocalModel
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.ui.components.SettingsDialog
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.sp
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.ui.components.GEMMA_DOWNLOADS
import com.rhymeai.app.ui.components.ModelRow
import com.rhymeai.app.ui.components.catalogModelRowState
import com.rhymeai.app.ui.components.customModelRowState
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.RhymeAITheme
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.io.File

/**
 * Review captures of every model-row state at the 412dp phone, Ink and Graphite. Runs only with
 * `-Pandroid.testInstrumentationRunnerArguments.modelRowShots=true`; writes PNGs to the app's
 * external files (`model-rows/`) for `adb pull`. Never committed.
 */
class ModelRowScreenshotTest {
    @get:Rule val compose = createComposeRule()

    private val e2b = GEMMA_DOWNLOADS[0]
    private val e4b = GEMMA_DOWNLOADS[1]
    private val onDisk = e2b.expectedBytes

    private fun e2b(fileBytes: Long? = null, verified: Boolean = false, selected: Boolean = false, downloading: Boolean = false,
                    progress: Float? = null, verifying: Boolean = false, pausedBytes: Long? = null, deleting: Boolean = false,
                    freedBytes: Long? = null) =
        catalogModelRowState(e2b, fileBytes, verified, selected, true, false, downloading, progress, verifying, pausedBytes, deleting, freedBytes)

    private val first = listOf(
        "1 Not downloaded" to e2b(),
        "2 Starting (ghost loop)" to e2b(downloading = true, progress = 0f),
        "3 Downloading" to e2b(downloading = true, progress = 0.43f),
        "4 Paused" to e2b(pausedBytes = onDisk * 43 / 100),
        "5 Checking" to e2b(downloading = true, progress = 1f, verifying = true),
        "6 Downloaded" to e2b(fileBytes = onDisk, verified = true),
        "7 Selected (dry)" to e2b(fileBytes = onDisk, verified = true, selected = true)
    )
    private val second = listOf(
        "8 Stale file" to e2b(fileBytes = 32L),
        "9 Memory-gated" to catalogModelRowState(e4b, null, false, false, false, true),
        "9b Memory-gated, on disk" to catalogModelRowState(e4b, e4b.expectedBytes, true, false, false, true),
        "10 Deleting (strike)" to e2b(fileBytes = onDisk, verified = true, deleting = true),
        "11 Deleted (4 s)" to e2b(freedBytes = onDisk),
        "C Custom import" to customModelRowState("My song model", 2_100_000_000L, selected = false, deleting = false),
        "C Custom, in use" to customModelRowState("My song model", 2_100_000_000L, selected = true, deleting = false)
    )

    private var appearance by mutableStateOf(AppAppearance.INK)
    private var rows by mutableStateOf(first)
    private var animations by mutableStateOf(true)
    private var fontScale by mutableStateOf(1f)

    @Test fun captureEveryState() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("modelRowShots") == "true")
        compose.setContent {
            RhymeAITheme(appearance) {
                val density = LocalDensity.current
                CompositionLocalProvider(LocalAnimationsEnabled provides animations, LocalDensity provides Density(density.density, fontScale)) {
                    Column(
                        Modifier
                            .testTag("board")
                            .width(412.dp)
                            .background(MaterialTheme.colorScheme.background)
                            .padding(horizontal = DesignTokens.Rhythm.standard, vertical = DesignTokens.Rhythm.related),
                        verticalArrangement = Arrangement.spacedBy(DesignTokens.Rhythm.tight)
                    ) {
                        rows.forEach { (name, state) ->
                            Text(name, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            ModelRow(state, chipEnabled = true, columnEnabled = true, onChip = {}, onColumn = {},
                                mainTag = "main-$name", deleteTag = "delete-$name", cancelTag = "cancel-$name")
                        }
                    }
                }
            }
        }
        for (look in listOf(AppAppearance.INK, AppAppearance.GRAPHITE)) {
            compose.runOnUiThread { appearance = look }
            for ((part, list) in listOf("a" to first, "b" to second)) {
                compose.runOnUiThread { rows = list }
                compose.waitForIdle()
                compose.mainClock.advanceTimeBy(700) // the strike drawn and the ghost part way through its write
                save("${look.name.lowercase()}-$part")
            }
            // Keyframes of the select and delete beats, and the animations-off still frame.
            compose.mainClock.autoAdvance = false
            compose.runOnUiThread { rows = listOf("Use tapped (t 0)" to e2b(fileBytes = onDisk, verified = true)) }
            compose.mainClock.advanceTimeBy(100)
            compose.runOnUiThread { rows = listOf("Selected, wet ink (t 600)" to e2b(fileBytes = onDisk, verified = true, selected = true)) }
            compose.mainClock.advanceTimeBy(600)
            save("${look.name.lowercase()}-wet")
            compose.runOnUiThread { rows = listOf("Deleting, crossing out (t 130)" to e2b(fileBytes = onDisk, verified = true, deleting = true)) }
            compose.mainClock.advanceTimeBy(130)
            save("${look.name.lowercase()}-strike")
            compose.mainClock.autoAdvance = true
            compose.runOnUiThread { animations = false }
            compose.runOnUiThread { rows = listOf("Starting, animations off (still frame)" to e2b(downloading = true, progress = 0f)) }
            compose.waitForIdle()
            save("${look.name.lowercase()}-still")
            compose.runOnUiThread { animations = true }
        }
        // Accessibility size: the chip drops under the metadata and the split is dropped.
        compose.runOnUiThread {
            appearance = AppAppearance.INK
            fontScale = 1.6f
            rows = listOf("Downloading, font scale 1.6" to e2b(downloading = true, progress = 0.43f), "Selected, font scale 1.6" to e2b(fileBytes = onDisk, verified = true, selected = true))
        }
        compose.waitForIdle()
        save("ink-accessibility-size")
    }

    @Test fun captureTheSettingsSection() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("modelRowShots") == "true")
        val filesDir = InstrumentationRegistry.getInstrumentation().targetContext.filesDir
        val custom = File(filesDir, "custom-shot.gguf").apply { writeBytes(ByteArray(4_096)) }
        try {
            compose.setContent {
                RhymeAITheme(appearance) {
                    SettingsDialog(
                        currentAppearance = appearance, onAppearanceChange = {}, apiKeyPresence = emptyMap(),
                        currentProvider = AIProvider.LOCAL, currentModel = AIModel.LOCAL_MODEL,
                        localModelLoading = false, localModelLoaded = true, localModelPath = custom.absolutePath, localModelError = null,
                        savedLocalModels = listOf(SavedLocalModel(custom.name, "My song model", custom.name, isCustom = true)),
                        selectedLocalModelId = custom.name,
                        onApplyAISettings = { _, _, _ -> Result.success(Unit) }, onSaveProvider = {}, onSaveModel = {},
                        onRegisterLocalModel = { _, _ -> }, onSelectSavedLocalModel = {}, onUnloadLocalModel = {},
                        gemmaDownloadingModel = e2b, gemmaDownloadProgress = 0.43f,
                        onDismiss = {}
                    )
                }
            }
            compose.onNodeWithText("AI setup").performScrollTo().performClick()
            compose.onNodeWithText("Custom Models").performScrollTo()
            for (look in listOf(AppAppearance.INK, AppAppearance.GRAPHITE)) {
                compose.runOnUiThread { appearance = look }
                compose.waitForIdle()
                compose.mainClock.advanceTimeBy(700)
                saveNode(compose.onRoot(), "${look.name.lowercase()}-settings")
            }
        } finally {
            custom.delete()
        }
    }

    private fun save(name: String) = saveNode(compose.onNodeWithTag("board"), name)

    private fun saveNode(node: androidx.compose.ui.test.SemanticsNodeInteraction, name: String) {
        val bitmap = node.captureToImage().asAndroidBitmap()
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "model-rows").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
