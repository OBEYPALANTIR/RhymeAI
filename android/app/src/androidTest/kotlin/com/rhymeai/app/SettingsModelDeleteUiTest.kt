package com.rhymeai.app

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.core.app.ApplicationProvider
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.ui.components.GEMMA_DOWNLOADS
import com.rhymeai.app.ui.components.GemmaDownload
import com.rhymeai.app.ui.components.SettingsDialog
import com.rhymeai.app.ui.components.gemmaDownloadStateFile
import com.rhymeai.app.ui.components.gemmaDownloadTempFile
import com.rhymeai.app.ui.theme.RhymeAITheme
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** The Settings row for a verified installed catalog model offers Delete, confirms, then offers Download again. */
class SettingsModelDeleteUiTest {
    @get:Rule val compose = createComposeRule()

    private val model = GEMMA_DOWNLOADS.first()
    private val installed = File(ApplicationProvider.getApplicationContext<android.content.Context>().filesDir, model.fileName)
    private val downloading = mutableStateOf<GemmaDownload?>(null)
    private val loading = mutableStateOf(false)
    private val revision = mutableStateOf(0)
    private val verified = mutableStateOf(setOf(model.fileName))
    private val deleted = mutableListOf<GemmaDownload>()
    private var wroteFixture = false

    @Before fun installVerifiedFixture() {
        // Never touch a real download. A sparse file of the catalog size with a GGUF header passes the
        // row's size and header checks without using the emulator's disk, so the row starts as Downloaded.
        val cacheDir = ApplicationProvider.getApplicationContext<android.content.Context>().cacheDir
        val temp = gemmaDownloadTempFile(cacheDir, model)
        assumeFalse(
            "an artifact of ${model.fileName} already exists on this device",
            installed.exists() || temp.exists() || gemmaDownloadStateFile(temp).exists()
        )
        RandomAccessFile(installed, "rw").use { file ->
            file.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).put("GGUF".toByteArray()).putInt(3).array())
            file.setLength(model.expectedBytes)
        }
        wroteFixture = true
    }

    @After fun cleanUp() {
        // @After still runs after a skipped @Before; only remove what this test wrote.
        if (wroteFixture) installed.delete()
    }

    @Test fun confirmingDeleteTurnsTheDownloadedRowBackIntoADownloadRow() {
        showSettings()
        compose.onNodeWithText("Quick drafts · 3.43 GB on this device").performScrollTo().assertIsDisplayed()
        deleteButton().assertIsEnabled().performClick()
        compose.onNodeWithText("Delete ${model.label}?").assertIsDisplayed()
        compose.onNodeWithText("Frees 3.43 GB on this device. You can download it again later.").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Delete ${model.label}?").assertDoesNotExist()
        assertFalse(deleted.contains(model))
        compose.onNodeWithText("Quick drafts · 3.43 GB on this device").assertIsDisplayed()

        deleteButton().performClick()
        compose.onNodeWithText("Delete").performClick()

        compose.onNodeWithText("Delete ${model.label}?").assertDoesNotExist()
        assertFalse(installed.exists())
        deleteButton().assertDoesNotExist()
        compose.onNodeWithText("Quick drafts · 3.43 GB on this device").assertDoesNotExist()
        compose.onNodeWithContentDescription("Download ${model.label}").performScrollTo().assertIsDisplayed()
    }

    @Test fun whileThatModelDownloadsTheColumnCancelsInsteadOfDeleting() {
        showSettings()
        deleteButton().performScrollTo().assertIsEnabled()
        compose.runOnIdle { downloading.value = model }
        deleteButton().assertDoesNotExist()
        compose.onNodeWithContentDescription("Cancel download of ${model.label}").assertIsEnabled()
        compose.runOnIdle { downloading.value = null }
        deleteButton().assertIsEnabled()
    }

    @Test fun deleteIsDisabledWhileTheLocalModelLoads() {
        showSettings()
        deleteButton().performScrollTo().assertIsEnabled()
        compose.runOnIdle { loading.value = true }
        deleteButton().assertIsNotEnabled()
        compose.runOnIdle { loading.value = false }
        deleteButton().assertIsEnabled()
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
                    localModelLoading = loading.value,
                    localModelLoaded = false,
                    localModelPath = null,
                    localModelError = null,
                    savedLocalModels = emptyList(),
                    selectedLocalModelId = null,
                    onApplyAISettings = { _, _, _ -> Result.success(Unit) },
                    onSaveProvider = {},
                    onSaveModel = {},
                    onRegisterLocalModel = { _, _ -> },
                    onSelectSavedLocalModel = {},
                    onUnloadLocalModel = {},
                    gemmaDownloadingModel = downloading.value,
                    gemmaDownloadRevision = revision.value,
                    verifiedGemmaFileNames = verified.value,
                    onDeleteDownloadedGemma = {
                        deleted += it
                        installed.delete()
                        verified.value = emptySet()
                        revision.value++
                    },
                    onDismiss = {}
                )
            }
        }
        compose.onNodeWithText("AI setup").performScrollTo().performClick()
    }

    private fun deleteButton() = compose.onNodeWithContentDescription("Delete ${model.label}")
}
