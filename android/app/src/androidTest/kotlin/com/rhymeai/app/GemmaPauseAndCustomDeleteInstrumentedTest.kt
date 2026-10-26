package com.rhymeai.app

import android.app.Application
import android.os.SystemClock
import androidx.core.content.FileProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.ui.components.GEMMA_DOWNLOADS
import com.rhymeai.app.ui.components.GemmaDownload
import com.rhymeai.app.ui.components.copyLocalModelAtomically
import com.rhymeai.app.ui.components.gemmaDownloadSegments
import com.rhymeai.app.ui.components.gemmaDownloadStateFile
import com.rhymeai.app.ui.components.gemmaDownloadTempFile
import com.rhymeai.app.ui.components.gemmaPartialBytes
import com.rhymeai.app.ui.components.saveDownloadState
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Through the real ViewModel: pause keeps the resume segments, Resume continues from them,
 * Cancel removes only the partial, and deleting an imported model removes only the app's copy.
 */
class GemmaPauseAndCustomDeleteInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app: Application = ApplicationProvider.getApplicationContext()
    private lateinit var viewModel: MainViewModel
    private lateinit var stall: ServerSocket
    private val held = mutableListOf<Socket>()
    private val installed = File(app.filesDir, "pause-qa.gguf")
    private lateinit var model: GemmaDownload
    private val picked = File(app.filesDir, "picked-original.gguf")
    private var copy: File? = null

    @Before fun setUp() {
        // A TLS endpoint that accepts and never answers: each range request hangs in its handshake
        // until the pause closes the connection.
        stall = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        Thread {
            while (!stall.isClosed) runCatching { stall.accept() }.onSuccess { socket -> synchronized(held) { held += socket } }
        }.start()
        model = GemmaDownload(
            label = "Pause QA",
            character = "test fixture",
            fileName = installed.name,
            url = "https://127.0.0.1:${stall.localPort}/pause-qa.gguf",
            expectedBytes = 64L,
            sha256 = "0".repeat(64)
        )
        onMain { viewModel = MainViewModel(app) }
        waitUntil { viewModel.aiSettingsLoaded }
        onMain { viewModel.saveProvider(AIProvider.LOCAL) }
    }

    @After fun tearDown() {
        runCatching { stall.close() }
        synchronized(held) { held.forEach { runCatching { it.close() } } }
        val temp = gemmaDownloadTempFile(app.cacheDir, model)
        listOf(installed, temp, gemmaDownloadStateFile(temp), picked).forEach { it.delete() }
        copy?.delete()
    }

    @Test fun pauseKeepsTheSegmentsResumeContinuesAndCancelRemovesOnlyThePartial() {
        // A partial with its first segment written.
        val temp = gemmaDownloadTempFile(app.cacheDir, model).apply { writeBytes(ByteArray(64)) }
        val segments = gemmaDownloadSegments(model.expectedBytes)
        saveDownloadState(gemmaDownloadStateFile(temp), model, LongArray(segments.size) { if (it == 0) segments[0].length else 0L })
        assertEquals(16L, gemmaPartialBytes(model, app.cacheDir))

        onMain { viewModel.startGemmaDownload(model) }
        waitUntil("the resumed run to credit the kept segment") { viewModel.gemmaDownloadProgress == 0.25f }
        waitUntil("the remaining ranges to open") { synchronized(held) { held.size } >= 3 }

        val revision = viewModel.gemmaDownloadRevision
        onMain { viewModel.pauseGemmaDownload() }
        assertNull(viewModel.gemmaDownloadingModel)
        // The run stops promptly although its connections hang (the pause closes them), keeps its
        // partial and reports no error. The second revision bump marks the run's end.
        waitUntil("the paused run to stop", timeoutMillis = 5_000) { viewModel.gemmaDownloadRevision == revision + 2 }
        assertNull(viewModel.gemmaDownloadError)
        assertTrue(temp.isFile)
        assertEquals(16L, gemmaPartialBytes(model, app.cacheDir))

        // Resume picks the kept bytes up again.
        onMain { viewModel.startGemmaDownload(model) }
        waitUntil("the second run to credit the kept segment") { viewModel.gemmaDownloadProgress == 0.25f }
        assertEquals(model, viewModel.gemmaDownloadingModel)
        // An older version under the catalog name, written after the run reclaimed stale files at its start.
        installed.writeBytes(ByteArray(8) { 7 })

        onMain { viewModel.cancelGemmaDownload(model) }
        assertNull(viewModel.gemmaDownloadingModel)
        waitUntil("the cancel to remove the partial") { !temp.exists() && !gemmaDownloadStateFile(temp).exists() }
        assertNull(gemmaPartialBytes(model, app.cacheDir))
        assertNull(viewModel.gemmaDownloadError)
        assertArrayEquals("the installed file is never touched", ByteArray(8) { 7 }, installed.readBytes())
    }

    @Test fun deletingAnImportedModelRemovesTheAppsCopyAndNeverTheFileThePickerReturned() {
        val original = gguf(4_096)
        picked.writeBytes(original)
        val uri = FileProvider.getUriForFile(app, "${app.packageName}.fileprovider", picked)
        val imported = File(app.filesDir, "custom-${java.util.UUID.randomUUID()}.gguf").also { copy = it }
        runBlocking { copyLocalModelAtomically(app.contentResolver.openInputStream(uri)!!, imported) }
        onMain { viewModel.registerAndSelectLocalModel(imported.absolutePath, "Picked", isCustom = true) }
        assertEquals(imported.name, viewModel.selectedLocalModelId)
        waitUntil("the load attempt to settle") { !viewModel.localModelLoading }

        onMain { viewModel.deleteCustomLocalModel(imported.name) }
        assertEquals(imported.name, viewModel.deletingCustomModelId)
        waitUntil("the delete to finish") { viewModel.deletingCustomModelId == null }

        assertFalse(imported.exists())
        assertArrayEquals("the picked file is untouched", original, picked.readBytes())
        assertArrayEquals("its URI still reads", original, app.contentResolver.openInputStream(uri)!!.use { it.readBytes() })
        assertTrue(viewModel.savedLocalModels.none { it.id == imported.name })
        assertNull("the deleted model was selected; nothing replaces it", viewModel.selectedLocalModelId)
        assertNull(viewModel.gemmaDownloadError)
        val freed = viewModel.localModelFreed
        assertNotNull(freed)
        assertEquals(4_096L, freed!!.bytes)
    }

    @Test fun anEntryNamingACatalogFileIsNeverDeletedAsACustomCopy() {
        val catalog = File(app.filesDir, GEMMA_DOWNLOADS.first().fileName)
        org.junit.Assume.assumeFalse("a real ${catalog.name} is on this device", catalog.exists())
        catalog.writeBytes(gguf(64))
        try {
            onMain { viewModel.registerAndSelectLocalModel(catalog.absolutePath, "Mislabelled", isCustom = true, select = false) }
            onMain { viewModel.deleteCustomLocalModel(catalog.name) }
            assertNull(viewModel.deletingCustomModelId)
            assertTrue(catalog.exists())
            assertNotNull(viewModel.gemmaDownloadError)
        } finally {
            catalog.delete()
        }
    }

    private fun gguf(size: Int): ByteArray =
        ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN).put("GGUF".toByteArray()).putInt(3).array()

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
        fail("$message was not met within ${timeoutMillis}ms (download error: ${viewModel.gemmaDownloadError})")
    }
}
