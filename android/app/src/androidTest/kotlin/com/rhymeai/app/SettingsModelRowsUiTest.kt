package com.rhymeai.app

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.data.model.SavedLocalModel
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.ui.components.GEMMA_DOWNLOADS
import com.rhymeai.app.ui.components.GemmaDownload
import com.rhymeai.app.ui.components.SettingsDialog
import com.rhymeai.app.ui.theme.RhymeAITheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File

/** The Settings lists after the split, the delete confirmation copy, and the download row's two buttons. */
class SettingsModelRowsUiTest {
    @get:Rule val compose = createComposeRule()

    private val filesDir = ApplicationProvider.getApplicationContext<android.content.Context>().filesDir
    private val customFile = File(filesDir, "custom-rows-qa.gguf")
    private val e2b = GEMMA_DOWNLOADS.first()
    private val custom = SavedLocalModel(id = customFile.name, displayName = "Rows QA model", fileName = customFile.name, isCustom = true)
    // A catalog download as Settings saved it before the split, under its old display name.
    private val savedCatalog = SavedLocalModel(id = e2b.fileName, displayName = "RhymeAI Gemma E2B", fileName = e2b.fileName, isCustom = false)
    private val selectedId = mutableStateOf<String?>(null)
    private val loaded = mutableStateOf(false)
    private val selections = mutableListOf<String>()
    private val downloading = mutableStateOf<GemmaDownload?>(null)
    private val progress = mutableStateOf<Float?>(null)
    private var paused = 0
    private val cancelled = mutableListOf<GemmaDownload>()
    private val customDeletes = mutableListOf<String>()

    @Before fun writeCustomCopy() {
        customFile.writeBytes(ByteArray(2_048))
    }

    @After fun removeCustomCopy() {
        customFile.delete()
    }

    @Test fun catalogDownloadsAppearOnlyUnderGemmaDownloadsAndCustomModelsHoldsImports() {
        showSettings()
        compose.onNodeWithText("Custom Models").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("customGGUF.${custom.id}").assertIsDisplayed()
        compose.onAllNodesWithTag("customGGUF.${savedCatalog.id}").assertCountEquals(0)
        compose.onAllNodesWithText("RhymeAI Gemma E2B", substring = true).assertCountEquals(0)
        compose.onAllNodesWithText("Saved Models").assertCountEquals(0)
        compose.onAllNodesWithText("Recommended Downloads").assertCountEquals(0)
        compose.onNodeWithText("RhymeAI Gemma Downloads").performScrollTo().assertIsDisplayed()
        compose.onAllNodesWithTag("gemmaDownload.${e2b.fileName}").assertCountEquals(1)
    }

    @Test fun theInUseSentenceAppearsOnlyWhenTheModelIsSelected() {
        showSettings()
        val inUse = "It's in use now; on-device suggestions stop until you choose another model."

        compose.onNodeWithTag("customGGUFDelete.${custom.id}").performScrollTo().performClick()
        compose.onNodeWithText("Delete Rows QA model?").assertIsDisplayed()
        compose.onNodeWithText("Frees 0.00 GB on this device. You can import it again later.").assertIsDisplayed()
        compose.onAllNodesWithText(inUse, substring = true).assertCountEquals(0)
        compose.onNodeWithText("Cancel").performClick()

        compose.runOnIdle { selectedId.value = custom.id }
        compose.onNodeWithTag("customGGUFDelete.${custom.id}").performScrollTo().performClick()
        compose.onNodeWithText("Frees 0.00 GB on this device. You can import it again later. $inUse").assertIsDisplayed()
        compose.onNodeWithText("Delete").performClick()
        compose.runOnIdle { assertEquals(listOf(custom.id), customDeletes) }
    }

    @Test fun aSelectedModelThatIsNotLoadedLoadsAgainFromItsRow() {
        selectedId.value = custom.id
        loaded.value = true
        showSettings()
        compose.onNodeWithTag("customGGUF.${custom.id}").performScrollTo().performClick()
        compose.runOnIdle { assertEquals("a loaded selection does nothing", emptyList<String>(), selections) }

        // After Unload Model, or a failed load, the selected row loads it again.
        compose.runOnIdle { loaded.value = false }
        compose.onNodeWithTag("customGGUF.${custom.id}").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(listOf(custom.id), selections) }
    }

    @Test fun theDownloadingRowPausesFromItsChipAndCancelsFromItsColumn() {
        downloading.value = e2b
        progress.value = 0.43f
        showSettings()
        compose.onNodeWithText("1.47 of 3.43 GB · 43%").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("gemmaDownload.${e2b.fileName}").performClick()
        compose.runOnIdle { assertEquals(1, paused) }
        compose.onNodeWithTag("gemmaCancel.${e2b.fileName}").performClick()
        compose.runOnIdle { assertEquals(listOf(e2b), cancelled) }
    }

    private fun showSettings() {
        compose.setContent {
            RhymeAITheme {
                SettingsDialog(
                    currentAppearance = AppAppearance.INK,
                    onAppearanceChange = {},
                    apiKeyPresence = emptyMap(),
                    currentProvider = AIProvider.LOCAL,
                    currentModel = AIModel.LOCAL_MODEL,
                    localModelLoading = false,
                    localModelLoaded = loaded.value,
                    localModelPath = null,
                    localModelError = null,
                    savedLocalModels = listOf(savedCatalog, custom),
                    selectedLocalModelId = selectedId.value,
                    onApplyAISettings = { _, _, _ -> Result.success(Unit) },
                    onSaveProvider = {},
                    onSaveModel = {},
                    onRegisterLocalModel = { _, _ -> },
                    onSelectSavedLocalModel = { selections += it; selectedId.value = it },
                    onUnloadLocalModel = {},
                    gemmaDownloadingModel = downloading.value,
                    gemmaDownloadProgress = progress.value,
                    onPauseGemmaDownload = { paused++ },
                    onCancelGemmaDownload = { cancelled += it },
                    onDeleteCustomLocalModel = { customDeletes += it },
                    onDismiss = {}
                )
            }
        }
        compose.onNodeWithText("AI setup").performScrollTo().performClick()
    }
}
