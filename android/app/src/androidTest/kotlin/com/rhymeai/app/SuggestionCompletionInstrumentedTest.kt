package com.rhymeai.app

import android.app.Application
import android.os.SystemClock
import androidx.compose.ui.text.input.TextFieldValue
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.RhymeType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * The Assistant's ink burst follows [MainViewModel.suggestionRunsCompleted]: it
 * moves only when a request ends by itself with at least one line.
 */
class SuggestionCompletionInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app: Application = ApplicationProvider.getApplicationContext()
    private lateinit var viewModel: MainViewModel

    @Before
    fun setUp() {
        onMain { viewModel = MainViewModel(app) }
        waitUntil { viewModel.aiSettingsLoaded }
        onMain { viewModel.onLyricsChanged(TextFieldValue("A line to answer\n")) }
    }

    @Test
    fun naturalCompletionWithLinesCounts() {
        run(ScriptedSuggestionStream(holdMillis = 0, intervalMillis = 0, count = 2))
        waitUntil { !viewModel.isLoading }
        assertEquals(2, viewModel.suggestions.size)
        assertEquals(1, viewModel.suggestionRunsCompleted)
    }

    @Test
    fun emptyAnswerDoesNotCount() {
        run(ScriptedSuggestionStream(holdMillis = 0, intervalMillis = 0, count = 0))
        waitUntil { !viewModel.isLoading }
        assertTrue(viewModel.errorMessage != null)
        assertEquals(0, viewModel.suggestionRunsCompleted)
    }

    @Test
    fun stopAfterTheFirstLineDoesNotCount() {
        run(ScriptedSuggestionStream(holdMillis = 0, intervalMillis = 1_000, count = 3))
        waitUntil { viewModel.suggestions.size == 1 }
        onMain { viewModel.cancelSuggestions() }
        SystemClock.sleep(2_500)
        instrumentation.waitForIdleSync()
        assertEquals(1, viewModel.suggestions.size)
        assertEquals(0, viewModel.suggestionRunsCompleted)
    }

    @Test
    fun settingsChangeMidStreamDoesNotCount() {
        run(ScriptedSuggestionStream(holdMillis = 0, intervalMillis = 1_000, count = 3))
        waitUntil { viewModel.suggestions.size == 1 }
        onMain { viewModel.rhymeType = if (viewModel.rhymeType == RhymeType.NEAR) RhymeType.SLANT else RhymeType.NEAR }
        SystemClock.sleep(2_500)
        instrumentation.waitForIdleSync()
        assertTrue(!viewModel.isLoading)
        assertEquals(0, viewModel.suggestionRunsCompleted)
    }

    @Test
    fun firstAutosaveOfANewSongKeepsTheRunningRequest() {
        onMain { viewModel.newProject() }
        waitUntil { viewModel.currentProjectId == null && viewModel.lyrics.isEmpty() }
        // Typing schedules the 450 ms autosave that gives the draft its ID; the
        // request outlives it.
        onMain { viewModel.onLyricsChanged(TextFieldValue("A line to answer\n")) }
        run(ScriptedSuggestionStream(holdMillis = 1_500, intervalMillis = 0, count = 2))
        waitUntil { viewModel.currentProjectId != null }
        waitUntil { !viewModel.isLoading }
        assertEquals(null, viewModel.errorMessage)
        assertEquals(2, viewModel.suggestions.size)
        assertEquals(1, viewModel.suggestionRunsCompleted)
    }

    private fun run(script: ScriptedSuggestionStream) = onMain {
        viewModel.enableScriptedSuggestionsForTesting(script)
        viewModel.getSuggestions()
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
