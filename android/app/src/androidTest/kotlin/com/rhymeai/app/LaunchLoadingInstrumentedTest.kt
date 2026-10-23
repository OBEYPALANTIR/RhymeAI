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
import com.rhymeai.app.data.model.TrashedSongProject
import com.rhymeai.app.data.sync.RecordingRecord
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

    // The library as the class found it: every test puts it back, so later classes see no songs of ours.
    private val projectsBefore = runBlocking { repo.projectsFlow.first() }
    private val trashBefore = runBlocking { repo.trashedProjectsFlow.first() }

    @After fun stop() {
        LaunchTestHooks.beforeLoading?.complete(Unit)
        LaunchTestHooks.beforeLoading = null
        heldStore?.let { store -> instrumentation.runOnMainSync { store.clear() } }
        scenario?.close()
        runBlocking {
            repo.saveProjects(projectsBefore)
            repo.saveTrashedProjects(trashBefore)
        }
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
        // T2.37/T2.38/T2.40: a song, a Trash entry with a future deadline and a trashed recording
        // with its own deadline are stored; none may be published, selected or scheduled.
        val persistedId = "launch-${UUID.randomUUID()}"
        val binnedId = "launch-bin-${UUID.randomUUID()}"
        val recordingId = UUID.randomUUID().toString()
        val trashFile = java.io.File(com.rhymeai.app.data.recording.RecordingFiles.trashDirectory(app.filesDir, binnedId).apply { mkdirs() }, "$recordingId.m4a")
            .apply { writeText("trashed take") }
        val now = System.currentTimeMillis()
        runBlocking {
            repo.saveProjects(repo.projectsFlow.first() + SongProject(id = persistedId, title = "Kept", lyrics = "kept words"))
            repo.saveTrashedProjects(repo.trashedProjectsFlow.first() + TrashedSongProject(SongProject(id = binnedId, title = "Binned", updatedAt = now), deletedAt = now))
            repo.updateRecordingRecords { records ->
                records + RecordingRecord(recordingId, binnedId, "take.m4a", now, com.rhymeai.app.data.sync.RecordingFileStore.sha256Hex(trashFile),
                    trashFile.length(), RecordingRecord.RECORDED, path = com.rhymeai.app.data.recording.RecordingTransitions.relativePath(app.filesDir, trashFile),
                    trashedAt = now)
            }
            repo.setCurrentProjectId(persistedId)
            // A malformed first-seen ledger makes precedence impossible to establish.
            app.dataStore.edit { it[ledgerKey] = """{"song:$persistedId":0}""" }
        }
        try {
            launch()
            waitUntil { vm.initialized }
            SystemClock.sleep(1_000)
            onMain {
                assertTrue(vm.projects.isEmpty())
                assertTrue(vm.trashedProjects.isEmpty())
                assertNull(vm.currentProjectId)
                assertNotNull(vm.persistenceError)
                assertNull(vm.scheduledTrashPurgeAt)
            }
            // Nothing stored was changed.
            assertEquals("kept words", runBlocking { repo.projectsFlow.first() }.single { it.id == persistedId }.lyrics)
            assertTrue(runBlocking { repo.trashedProjectsFlow.first() }.any { it.project.id == binnedId })
            assertEquals("trashed take", trashFile.readText())
        } finally {
            runBlocking {
                app.dataStore.edit { it.remove(ledgerKey) }
                repo.updateRecordingRecords { records -> records.filterNot { it.id == recordingId } }
                repo.saveTrashedProjects(repo.trashedProjectsFlow.first().filterNot { it.project.id == binnedId })
            }
            trashFile.parentFile?.deleteRecursively()
        }
    }

    @Test fun aDeletionWhoseDraftCannotBeSavedFirstIsAbortedAndTheEditorKept() {
        // iOS final review item 3: only the draft save fails; the song itself stays deletable.
        launch()
        waitUntil { vm.initialized }
        val draft = "unsaved words ${UUID.randomUUID()}"
        onMain { vm.applyTemplate("Verse", "", "template line") }
        onMain { vm.onLyricsChanged(TextFieldValue("first words")) }
        waitUntil { vm.currentProjectId != null && runBlocking { repo.projectsFlow.first().any { it.id == vm.currentProjectId } } }
        val id = vm.currentProjectId!!
        try {
            onMain { vm.onLyricsChanged(TextFieldValue(draft)) }
            onMain {
                DraftSaveTestHooks.failNext.set(true)
                vm.moveProjectToTrash(id)
            }
            waitUntil { !DraftSaveTestHooks.failNext.get() && !vm.savingBeforeNavigation }
            SystemClock.sleep(500)
            onMain {
                assertEquals(draft, vm.lyrics)
                assertEquals(id, vm.currentProjectId)
                assertTrue(vm.trashedProjects.none { it.project.id == id })
            }
            assertTrue(runBlocking { repo.trashedProjectsFlow.first() }.none { it.project.id == id })

            // The same deletion succeeds once the draft can be saved: only the save had failed.
            onMain { vm.moveProjectToTrash(id) }
            waitUntil { runBlocking { repo.trashedProjectsFlow.first() }.any { it.project.id == id && it.project.lyrics == draft } }
        } finally {
            DraftSaveTestHooks.failNext.set(false)
        }
    }

    @Test fun typingWhileNewSongStoresItsSelectionIsKept() {
        // Final review 2, finding 2: after the flush, the selection save is held; text typed then must survive.
        launch()
        waitUntil { vm.initialized }
        onMain { vm.applyTemplate("Verse", "", "template line") }
        onMain { vm.onLyricsChanged(TextFieldValue("the earlier song ${UUID.randomUUID()}")) }
        waitUntil { vm.currentProjectId != null && runBlocking { repo.projectsFlow.first().any { it.id == vm.currentProjectId } } }
        val earlier = vm.currentProjectId
        val gate = CompletableDeferred<Unit>()
        NewSongTestHooks.beforeSelectionSave = gate
        try {
            onMain { vm.newProject() }
            // The flush has finished; the selection save is still held.
            waitUntil { !vm.savingBeforeNavigation }
            val typed = "typed while New Song was saving ${UUID.randomUUID()}"
            onMain { vm.onLyricsChanged(TextFieldValue(typed)) }
            gate.complete(Unit)
            waitUntil { runBlocking { repo.projectsFlow.first().any { it.lyrics == typed } } }
            onMain {
                assertEquals(typed, vm.lyrics)
                assertTrue(vm.currentProjectId != earlier)
            }
        } finally {
            NewSongTestHooks.beforeSelectionSave = null
            gate.complete(Unit)
        }
    }
}
