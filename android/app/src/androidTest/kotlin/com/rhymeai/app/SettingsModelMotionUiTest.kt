package com.rhymeai.app

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasProgressBarRangeInfo
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.data.model.SavedLocalModel
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.ui.components.GEMMA_DOWNLOADS
import com.rhymeai.app.ui.components.GemmaDownload
import com.rhymeai.app.ui.components.SettingsDialog
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.RhymeAITheme
import org.junit.Rule
import org.junit.Test

/** Exercises the real Settings composition; installed loading and download flows are checked separately. */
class SettingsModelMotionUiTest {
    @get:Rule val compose = createComposeRule()

    private val loading = mutableStateOf(false)
    private val loaded = mutableStateOf(false)
    private val error = mutableStateOf<String?>(null)
    private val downloading = mutableStateOf<GemmaDownload?>(null)
    private val downloadProgress = mutableStateOf<Float?>(null)
    private val verifying = mutableStateOf(false)
    private val downloadError = mutableStateOf<String?>(null)
    private val selectedId = mutableStateOf<String?>("motion-qa-model")
    private val model = SavedLocalModel(
        id = "motion-qa-model",
        displayName = "Motion QA model",
        fileName = "motion-qa.gguf",
        isCustom = true
    )

    @Test fun savedSelectionRestoresAfterDownloadAndLoadFinish() {
        showSettings(animations = true)
        savedModelButton().assertIsEnabled()

        compose.runOnIdle {
            downloading.value = GEMMA_DOWNLOADS.first()
            downloadProgress.value = 0.43f
        }
        savedModelButton().assertIsNotEnabled()
        compose.onNodeWithText("1.47 of 3.43 GB · 43%").performScrollTo().assertIsDisplayed()
        // The download is a written line now; its row reports the share as its progress.
        compose.onAllNodes(hasProgressBarRangeInfo(ProgressBarRangeInfo(0.43f, 0f..1f))).assertCountEquals(1)

        compose.runOnIdle { verifying.value = true }
        compose.onNodeWithText("Checking the file…").performScrollTo().assertIsDisplayed()

        compose.runOnIdle {
            downloading.value = null
            downloadProgress.value = null
            verifying.value = false
            downloadError.value = "Synthetic download failure"
        }
        savedModelButton().assertIsEnabled()
        compose.onNodeWithText("Synthetic download failure").performScrollTo().assertIsDisplayed()

        compose.runOnIdle {
            downloadError.value = null
            loading.value = true
        }
        savedModelButton().assertIsNotEnabled()
        compose.onNodeWithText("Loading model...").performScrollTo().assertIsDisplayed()
        assertOneProgressIndicator()

        compose.runOnIdle {
            loading.value = false
            loaded.value = true
        }
        savedModelButton().assertIsEnabled()
        compose.onNodeWithText("Model loaded").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Unload Model").performScrollTo().assertIsEnabled()
    }

    @Test fun unloadExitDisablesActionAndCanReverse() {
        loaded.value = true
        showSettings(animations = true)
        scrollLoadActionIntoView()
        compose.onNodeWithText("Unload Model").assertIsDisplayed().assertIsEnabled()

        compose.mainClock.autoAdvance = false
        compose.onNodeWithText("Unload Model").performClick()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Unload Model").assertIsNotEnabled()
        compose.onNodeWithText("Loading model...").assertIsDisplayed()

        compose.mainClock.advanceTimeBy(64)
        compose.runOnUiThread {
            loading.value = false
            loaded.value = true
        }
        compose.mainClock.advanceTimeBy(300)
        compose.onNodeWithText("Model loaded").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Unload Model").assertIsEnabled()
        compose.mainClock.autoAdvance = true
    }

    @Test fun reducedMotionRemovesStatusAndActionImmediately() {
        loaded.value = true
        showSettings(animations = false)
        scrollLoadActionIntoView()
        compose.mainClock.autoAdvance = false
        compose.onNodeWithText("Unload Model").assertIsDisplayed().performClick()
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Unload Model").assertDoesNotExist()
        compose.onNodeWithText("Model loaded").assertDoesNotExist()
        compose.onNodeWithText("Loading model...").performScrollTo().assertIsDisplayed()

        compose.runOnUiThread {
            loading.value = false
            error.value = "Synthetic load failure"
        }
        compose.mainClock.advanceTimeByFrame()
        savedModelButton().assertIsEnabled()
        compose.onNodeWithText("Synthetic load failure").performScrollTo().assertIsDisplayed()

        compose.runOnUiThread {
            error.value = null
            loaded.value = true
        }
        compose.mainClock.advanceTimeByFrame()
        compose.onNodeWithText("Model loaded").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Unload Model").assertIsEnabled()
        compose.mainClock.autoAdvance = true
    }

    private fun showSettings(animations: Boolean) {
        compose.setContent {
            RhymeAITheme {
                CompositionLocalProvider(LocalAnimationsEnabled provides animations) {
                    SettingsDialog(
                        currentAppearance = AppAppearance.INK,
                        onAppearanceChange = {},
                        apiKeyPresence = emptyMap(),
                        currentProvider = AIProvider.LOCAL,
                        currentModel = AIModel.LOCAL_MODEL,
                        localModelLoading = loading.value,
                        localModelLoaded = loaded.value,
                        localModelPath = "/synthetic/motion-qa.gguf",
                        localModelError = error.value,
                        savedLocalModels = listOf(model),
                        selectedLocalModelId = selectedId.value,
                        onApplyAISettings = { _, _, _ -> Result.success(Unit) },
                        onSaveProvider = {},
                        onSaveModel = {},
                        onRegisterLocalModel = { _, _ -> },
                        onSelectSavedLocalModel = { selectedId.value = it },
                        onUnloadLocalModel = {
                            loaded.value = false
                            loading.value = true
                        },
                        gemmaDownloadingModel = downloading.value,
                        gemmaDownloadProgress = downloadProgress.value,
                        gemmaDownloadVerifying = verifying.value,
                        gemmaDownloadError = downloadError.value,
                        onDismiss = {}
                    )
                }
            }
        }
        compose.onNodeWithText("AI setup").performScrollTo().performClick()
        savedModelButton().performScrollTo()
    }

    /**
     * The load action sits below the downloads list, off-screen on a phone; scroll to it, then
     * back up to Unload so both are on screen. Scroll while the clock still advances: a scroll
     * requested under a paused clock never settles.
     */
    private fun scrollLoadActionIntoView() {
        compose.onNodeWithText("Choose Model File").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Unload Model").performScrollTo()
        compose.onNodeWithText("Choose Model File").assertIsDisplayed()
    }

    private fun savedModelButton() =
        compose.onNode(hasText("Motion QA model") and hasClickAction())

    private fun assertOneProgressIndicator() {
        compose.onAllNodes(
            hasProgressBarRangeInfo(ProgressBarRangeInfo.Indeterminate),
            useUnmergedTree = true
        ).assertCountEquals(1)
    }
}
