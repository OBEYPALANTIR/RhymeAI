package com.rhymeai.app

import android.app.Application
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.ui.components.GemmaDownload
import com.rhymeai.app.ui.components.gemmaDownloadStateFile
import com.rhymeai.app.ui.components.gemmaDownloadTempFile
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/** Deleting an installed catalog model removes its files and, when it was selected, clears the selection. */
class GemmaDeleteInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app: Application = ApplicationProvider.getApplicationContext()
    private lateinit var viewModel: MainViewModel
    private val file = File(app.filesDir, "delete-qa.gguf")
    private val other = File(app.filesDir, "delete-qa-other.gguf")
    private lateinit var download: GemmaDownload
    private lateinit var otherDownload: GemmaDownload

    @Before
    fun setUp() {
        download = fixture(file, "Delete QA")
        otherDownload = fixture(other, "Delete QA other")
        onMain { viewModel = MainViewModel(app) }
        waitUntil { viewModel.aiSettingsLoaded }
        onMain { viewModel.saveProvider(AIProvider.LOCAL) }
    }

    @After
    fun tearDown() {
        LocalModelTestHooks.beforeRegistrationSelectionWrite?.complete(Unit)
        LocalModelTestHooks.beforeRegistrationSelectionWrite = null
        listOf(file, other).forEach { it.delete() }
        listOf(download, otherDownload).forEach { model ->
            val temp = gemmaDownloadTempFile(app.cacheDir, model)
            gemmaDownloadStateFile(temp).delete()
            temp.delete()
        }
    }

    @Test
    fun deletingTheSelectedModelRemovesItsFilesAndClearsTheSelection() {
        val temp = gemmaDownloadTempFile(app.cacheDir, download).apply { writeBytes(ByteArray(8)) }
        val state = gemmaDownloadStateFile(temp).apply { writeBytes(ByteArray(4)) }
        assertTrue(runBlocking(Dispatchers.Main) { viewModel.useDownloadedGemma(download) })
        // A second saved model (custom, so restore keeps it) is the fallback a relaunch must not pick.
        onMain { viewModel.registerAndSelectLocalModel(other.absolutePath, "Other", isCustom = true, select = false) }
        assertEquals(file.name, viewModel.selectedLocalModelId)
        assertTrue(file.name in viewModel.verifiedGemmaFileNames)
        waitUntil("load attempt to settle") { !viewModel.localModelLoading }
        val choiceRevisionBefore = viewModel.modelChoiceRevision
        val unloadsBefore = viewModel.localModelUnloadCount

        onMain { viewModel.deleteDownloadedGemma(download) }
        waitUntil("delete to finish") { viewModel.gemmaDeletingModel == null && !viewModel.localModelLoading }

        // The service released its context on the delete path itself, not only through the load's own cleanup.
        assertEquals(unloadsBefore + 1, viewModel.localModelUnloadCount)
        assertFalse(file.exists())
        assertFalse(temp.exists())
        assertFalse(state.exists())
        assertNull(viewModel.selectedLocalModelId)
        assertNull(viewModel.localModelPath)
        assertFalse(viewModel.localModelLoaded)
        assertFalse(file.name in viewModel.verifiedGemmaFileNames)
        assertTrue(viewModel.savedLocalModels.none { it.fileName == file.name })
        assertNull(viewModel.gemmaDownloadError)
        assertTrue("a download finishing later must not re-select", viewModel.modelChoiceRevision > choiceRevisionBefore)

        // Relaunch: the explicit "none" survives and the other installed model is not selected instead.
        lateinit var relaunched: MainViewModel
        onMain { relaunched = MainViewModel(app) }
        // aiSettingsLoaded flips after restoreSavedLocalModels has finished restoring the selection.
        waitUntil("relaunch to finish restoring") { relaunched.aiSettingsLoaded }
        assertTrue(relaunched.savedLocalModels.any { it.fileName == other.name })
        assertNull(relaunched.selectedLocalModelId)
        assertTrue(relaunched.savedLocalModels.none { it.fileName == file.name })
    }

    @Test
    fun deletingAnotherModelKeepsTheSelection() {
        assertTrue(runBlocking(Dispatchers.Main) { viewModel.useDownloadedGemma(download) })
        assertTrue(runBlocking(Dispatchers.Main) { viewModel.useDownloadedGemma(otherDownload, viewModel.modelChoiceRevision - 1) })
        assertEquals(file.name, viewModel.selectedLocalModelId)
        waitUntil("load attempt to settle") { !viewModel.localModelLoading }

        onMain { viewModel.deleteDownloadedGemma(otherDownload) }
        waitUntil("delete to finish") { !other.exists() && viewModel.savedLocalModels.none { it.fileName == other.name } }

        assertTrue(file.exists())
        assertEquals(file.name, viewModel.selectedLocalModelId)
        assertTrue(file.name in viewModel.verifiedGemmaFileNames)
        assertFalse(other.name in viewModel.verifiedGemmaFileNames)
    }

    @Test
    fun deletingAModelWhoseSelectionWasRejectedLeavesTheSelectedModelAlone() {
        assertTrue(runBlocking(Dispatchers.Main) { viewModel.useDownloadedGemma(download) })
        assertTrue(runBlocking(Dispatchers.Main) { viewModel.useDownloadedGemma(otherDownload, viewModel.modelChoiceRevision - 1) })
        waitUntil("load attempt to settle") { !viewModel.localModelLoading }

        // Selecting the other model is rejected (its fixture is not in the trusted catalog), which
        // leaves the selection on the first model but the last attempted load path on the other.
        onMain { viewModel.selectSavedLocalModel(other.name) }
        waitUntil("rejected selection to settle") { !viewModel.localModelLoading && viewModel.localModelError != null }
        assertEquals(file.name, viewModel.selectedLocalModelId)
        assertEquals(other.absolutePath, viewModel.localModelPath)

        onMain { viewModel.deleteDownloadedGemma(otherDownload) }
        waitUntil("delete to finish") { viewModel.gemmaDeletingModel == null && !other.exists() }

        assertEquals(file.name, viewModel.selectedLocalModelId)
        assertTrue(file.exists())
        assertNull(viewModel.gemmaDownloadError)
    }

    @Test
    fun aRegistrationStillWritingItsSelectionCannotUndoADeletedModelsClearedSelection() {
        // Fallback candidate for a relaunch that wrongly finds a missing selection.
        onMain { viewModel.registerAndSelectLocalModel(other.absolutePath, "Other", isCustom = true, select = false) }
        val gate = CompletableDeferred<Unit>()
        LocalModelTestHooks.beforeRegistrationSelectionWrite = gate
        assertTrue(runBlocking(Dispatchers.Main) { viewModel.useDownloadedGemma(download) })
        assertEquals(file.name, viewModel.selectedLocalModelId)
        waitUntil("load attempt to settle") { !viewModel.localModelLoading }

        // The registration's selection write is still pending when the delete persists "none".
        onMain { viewModel.deleteDownloadedGemma(download) }
        waitUntil("delete to finish") { viewModel.gemmaDeletingModel == null && !viewModel.localModelLoading }
        assertNull(viewModel.selectedLocalModelId)
        gate.complete(Unit)
        onMain { }

        lateinit var relaunched: MainViewModel
        onMain { relaunched = MainViewModel(app) }
        waitUntil("relaunch to finish restoring") { relaunched.aiSettingsLoaded }
        assertTrue(relaunched.savedLocalModels.any { it.fileName == other.name })
        assertNull("the delayed registration write must not revive a selection", relaunched.selectedLocalModelId)
    }

    private fun fixture(file: File, label: String): GemmaDownload {
        // Smallest file the download validator accepts: GGUF magic, version 3, 24+ bytes.
        file.writeBytes(ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN).put("GGUF".toByteArray()).putInt(3).array())
        val sha256 = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
        return GemmaDownload(
            label = label,
            description = "test fixture",
            fileName = file.name,
            url = "https://example.invalid/${file.name}",
            expectedBytes = file.length(),
            sha256 = sha256
        )
    }

    private fun onMain(block: () -> Unit) {
        instrumentation.runOnMainSync(block)
        instrumentation.waitForIdleSync()
    }

    private fun waitUntil(message: String = "Condition", timeoutMillis: Long = 10_000, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + timeoutMillis
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.waitForIdleSync()
            if (condition()) return
            SystemClock.sleep(50)
        }
        fail("$message was not met within ${timeoutMillis}ms")
    }
}
