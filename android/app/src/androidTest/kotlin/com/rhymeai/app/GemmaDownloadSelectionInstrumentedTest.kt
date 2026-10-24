package com.rhymeai.app

import android.app.Application
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.ui.components.GEMMA_DOWNLOADS
import com.rhymeai.app.ui.components.GemmaDownload
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/**
 * A finished download installs its model, but only takes over the provider and
 * model selection when the user has not picked something else meanwhile.
 */
class GemmaDownloadSelectionInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app: Application = ApplicationProvider.getApplicationContext()
    private lateinit var viewModel: MainViewModel
    private val file = File(app.filesDir, "selection-qa.gguf")
    private lateinit var download: GemmaDownload

    @Before
    fun setUp() {
        // Smallest file the download validator accepts: GGUF magic, version 3, 24+ bytes.
        file.writeBytes(ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN).put("GGUF".toByteArray()).putInt(3).array())
        val sha256 = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
        download = GemmaDownload(
            label = "Selection QA",
            description = "test fixture",
            fileName = file.name,
            url = "https://example.invalid/selection-qa.gguf",
            expectedBytes = file.length(),
            sha256 = sha256
        )
        onMain { viewModel = MainViewModel(app) }
        waitUntil { viewModel.aiSettingsLoaded }
        onMain { viewModel.saveProvider(AIProvider.LOCAL) }
    }

    @After
    fun tearDown() {
        file.delete()
    }

    @Test
    fun completionKeepsAProviderChosenDuringTheDownload() {
        val revisionAtStart = viewModel.modelChoiceRevision
        onMain { viewModel.saveProvider(AIProvider.GEMINI) }

        val installed = runBlocking(Dispatchers.Main) { viewModel.useDownloadedGemma(download, revisionAtStart) }

        assertTrue(installed)
        assertEquals(AIProvider.GEMINI, viewModel.selectedProvider)
        assertNotEquals(file.name, viewModel.selectedLocalModelId)
        assertTrue(viewModel.savedLocalModels.any { it.fileName == file.name })
    }

    @Test
    fun completionYieldsToASavedModelStillBeingValidated() {
        // A catalog file name makes selectSavedLocalModel validate asynchronously, so the
        // selected ID has not moved yet when the download finishes.
        val pending = File(app.filesDir, GEMMA_DOWNLOADS.first().fileName)
        pending.writeBytes(file.readBytes())
        try {
            onMain { viewModel.registerAndSelectLocalModel(pending.absolutePath, "Pending", isCustom = false, select = false) }
            val revisionAtStart = viewModel.modelChoiceRevision
            onMain { viewModel.selectSavedLocalModel(pending.name) }

            runBlocking(Dispatchers.Main) { viewModel.useDownloadedGemma(download, revisionAtStart) }

            assertNotEquals(file.name, viewModel.selectedLocalModelId)
            assertTrue(viewModel.savedLocalModels.any { it.fileName == file.name })
        } finally {
            pending.delete()
        }
    }

    @Test
    fun completionSelectsTheModelWhenNothingChanged() {
        val revisionAtStart = viewModel.modelChoiceRevision

        runBlocking(Dispatchers.Main) { viewModel.useDownloadedGemma(download, revisionAtStart) }

        assertEquals(AIProvider.LOCAL, viewModel.selectedProvider)
        assertEquals(file.name, viewModel.selectedLocalModelId)
    }

    private fun onMain(block: () -> Unit) {
        instrumentation.runOnMainSync(block)
        instrumentation.waitForIdleSync()
    }

    private fun waitUntil(timeoutMillis: Long = 5_000, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + timeoutMillis
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.waitForIdleSync()
            if (condition()) return
            SystemClock.sleep(50)
        }
        fail("Condition was not met within ${timeoutMillis}ms")
    }
}
