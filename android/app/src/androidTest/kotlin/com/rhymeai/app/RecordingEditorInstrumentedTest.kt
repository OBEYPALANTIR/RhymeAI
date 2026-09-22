package com.rhymeai.app

import androidx.compose.ui.test.isDisplayed
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.Assert.*

@RunWith(AndroidJUnit4::class)
class RecordingEditorInstrumentedTest {
    @get:Rule val compose = createEmptyComposeRule()
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var viewModel: MainViewModel

    @Before fun openEditor() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        compose.onNodeWithText("New Song").performClick()
        scenario.onActivity { viewModel = ViewModelProvider(it)[MainViewModel::class.java] }
    }

    @After fun closeEditor() { scenario.close() }

    @Test fun lyricsTypedWhileRecordingSongIsSavingKeepReservedIdentity() {
        lateinit var saving: Deferred<String>
        lateinit var reservedId: String
        compose.runOnIdle {
            saving = viewModel.viewModelScope.async(start = CoroutineStart.UNDISPATCHED) {
                viewModel.ensureProjectForRecording()
            }
            reservedId = requireNotNull(viewModel.currentProjectId)
            viewModel.onLyricsChanged(TextFieldValue("A line typed while the song is saving"))
        }
        assertEquals(reservedId, runBlocking { saving.await() })
        compose.waitUntil(5_000) {
            viewModel.projects.any { it.id == reservedId && it.lyrics == "A line typed while the song is saving" }
        }
        compose.runOnIdle { assertEquals(reservedId, viewModel.currentProjectId) }
    }

    @Test fun navigationDuringRecordingSongSaveDoesNotRestoreOldIdentity() {
        lateinit var saving: Deferred<String>
        lateinit var reservedId: String
        compose.runOnIdle {
            saving = viewModel.viewModelScope.async(start = CoroutineStart.UNDISPATCHED) {
                viewModel.ensureProjectForRecording()
            }
            reservedId = requireNotNull(viewModel.currentProjectId)
            viewModel.newProject {
                viewModel.onLyricsChanged(TextFieldValue("New song after navigation"))
            }
        }
        runBlocking { saving.join() }
        compose.waitUntil(5_000) { viewModel.projects.any { it.lyrics == "New song after navigation" } }
        compose.runOnIdle {
            assertEquals("New song after navigation", viewModel.lyrics)
            assertNotEquals(reservedId, viewModel.currentProjectId)
        }
    }

    @Test fun recordingLibrarySurvivesActivityRecreation() {
        compose.onNodeWithText("Recordings").performClick()
        compose.waitUntil(5_000) { compose.onNodeWithText("Import recording").isDisplayed() }
        compose.onNodeWithText("Import recording").assertIsDisplayed()
        scenario.recreate()
        compose.waitUntil(5_000) { compose.onNodeWithText("Import recording").isDisplayed() }
        compose.onNodeWithText("Import recording").assertIsDisplayed()
        compose.onNodeWithText("No recordings yet. Record or import audio for this song.").assertIsDisplayed()
    }
}
