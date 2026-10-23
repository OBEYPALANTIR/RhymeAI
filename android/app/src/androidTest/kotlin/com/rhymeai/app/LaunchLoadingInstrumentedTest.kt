package com.rhymeai.app

import android.app.Application
import android.os.SystemClock
import androidx.compose.ui.text.input.TextFieldValue
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.dataStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/** The launch race: the splash stays up until loading finishes, and loading never overwrites a newer draft. */
@RunWith(AndroidJUnit4::class)
class LaunchLoadingInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app: Application = ApplicationProvider.getApplicationContext()
    private val repo = ProjectRepository(app)
    private var scenario: ActivityScenario<MainActivity>? = null
    private lateinit var vm: MainViewModel
    private val ledgerKey = stringPreferencesKey("first_seen_precedence_json")

    private var heldStore: androidx.lifecycle.ViewModelStore? = null

    @After fun stop() {
        LaunchTestHooks.beforeLoading?.complete(Unit)
        LaunchTestHooks.beforeLoading = null
        heldStore?.let { store -> instrumentation.runOnMainSync { store.clear() } }
        scenario?.close()
    }

    private fun launch() {
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario!!.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
    }

    private fun onMain(block: () -> Unit) { instrumentation.runOnMainSync(block); instrumentation.waitForIdleSync() }

    private fun waitUntil(condition: () -> Boolean) {
        val until = SystemClock.uptimeMillis() + 10_000
        while (SystemClock.uptimeMillis() < until) {
            if (condition()) return
            SystemClock.sleep(50)
        }
        fail("Launch did not settle")
    }

    @Test fun aDraftStartedWhileLaunchLoadsIsKeptAndSavedAsItsOwnSong() {
        val persistedId = "launch-${UUID.randomUUID()}"
        runBlocking {
            repo.saveProjects(repo.projectsFlow.first() + SongProject(id = persistedId, title = "Persisted", lyrics = "old words"))
            repo.setCurrentProjectId(persistedId)
            repo.saveEditorState("Persisted", "old words", "")
        }
        val gate = CompletableDeferred<Unit>()
        LaunchTestHooks.beforeLoading = gate
        // The view model on its own (no activity): the splash would keep the main thread busy
        // while loading is held. MainActivity keeps the splash up on exactly `initialized`.
        val store = androidx.lifecycle.ViewModelStore()
        instrumentation.runOnMainSync {
            vm = ViewModelProvider(store, ViewModelProvider.AndroidViewModelFactory.getInstance(app))[MainViewModel::class.java]
        }
        heldStore = store
        waitUntil { vm.appearanceLoaded }
        // Loading is held: the splash is still up (its condition), and a template plus typing happen now.
        assertFalse(vm.initialized)
        val draft = "a line typed before loading finished ${UUID.randomUUID()}"
        instrumentation.runOnMainSync {
            vm.applyTemplate("Verse", "", "template line")
            vm.onLyricsChanged(TextFieldValue(draft))
        }
        gate.complete(Unit)
        waitUntil { vm.initialized }

        onMain {
            assertEquals(draft, vm.lyrics)
            assertEquals("Untitled Verse", vm.title)
            assertFalse(vm.showStartMenu)
            assertTrue(vm.currentProjectId != persistedId)
        }
        waitUntil { runBlocking { repo.projectsFlow.first().any { it.lyrics == draft } } }
        val stored = runBlocking { repo.projectsFlow.first() }
        assertEquals("old words", stored.single { it.id == persistedId }.lyrics)
        assertEquals(vm.currentProjectId, stored.single { it.lyrics == draft }.id)
    }

    @Test fun aLaunchWhoseTimesCannotBeEstablishedPublishesNothingAndSaysSo() {
        val persistedId = "launch-${UUID.randomUUID()}"
        runBlocking {
            repo.saveProjects(repo.projectsFlow.first() + SongProject(id = persistedId, title = "Kept", lyrics = "kept words"))
            repo.setCurrentProjectId(persistedId)
            // A malformed first-seen ledger makes precedence impossible to establish.
            app.dataStore.edit { it[ledgerKey] = """{"song:$persistedId":0}""" }
        }
        try {
            launch()
            waitUntil { vm.initialized }
            onMain {
                assertTrue(vm.projects.isEmpty())
                assertTrue(vm.trashedProjects.isEmpty())
                assertNull(vm.currentProjectId)
                assertNotNull(vm.persistenceError)
            }
            // Nothing stored was changed.
            assertEquals("kept words", runBlocking { repo.projectsFlow.first() }.single { it.id == persistedId }.lyrics)
        } finally {
            runBlocking { app.dataStore.edit { it.remove(ledgerKey) } }
        }
    }

    @Test fun aDeletionWhoseDraftCannotBeSavedFirstIsAbortedAndTheEditorKept() {
        // iOS final review item 3: the draft is saved before the song leaves; if that fails, nothing is deleted.
        launch()
        waitUntil { vm.initialized }
        val draft = "unsaved words ${UUID.randomUUID()}"
        onMain { vm.applyTemplate("Verse", "", "template line") }
        onMain { vm.onLyricsChanged(TextFieldValue("first words")) }
        waitUntil { vm.currentProjectId != null && runBlocking { repo.projectsFlow.first().any { it.id == vm.currentProjectId } } }
        val id = vm.currentProjectId!!
        val projectsKey = stringPreferencesKey("projects_json")
        val stored = runBlocking { app.dataStore.data.first()[projectsKey] }
        try {
            // The song library becomes unreadable, so the draft cannot be saved before the move.
            runBlocking { app.dataStore.edit { it[projectsKey] = "{not valid json" } }
            onMain { vm.onLyricsChanged(TextFieldValue(draft)) }
            onMain { vm.moveProjectToTrash(id) }
            SystemClock.sleep(1_000)
            onMain {
                assertEquals(draft, vm.lyrics)
                assertEquals(id, vm.currentProjectId)
                assertTrue(vm.trashedProjects.none { it.project.id == id })
            }
            assertTrue(runBlocking { repo.trashedProjectsFlow.first() }.none { it.project.id == id })
        } finally {
            runBlocking { app.dataStore.edit { prefs -> if (stored == null) prefs.remove(projectsKey) else prefs[projectsKey] = stored } }
        }
    }
}
