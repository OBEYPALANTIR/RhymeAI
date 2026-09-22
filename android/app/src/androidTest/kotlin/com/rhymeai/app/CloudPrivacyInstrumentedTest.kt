package com.rhymeai.app

import android.content.Context
import android.os.SystemClock
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.SecureKeyStore
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.junit.*
import org.junit.Assert.*
import java.io.File

class CloudPrivacyInstrumentedTest {
    @get:Rule val composeRule = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var context: Context
    private lateinit var scenario: ActivityScenario<MainActivity>
    private lateinit var vm: MainViewModel
    private lateinit var repo: ProjectRepository
    private lateinit var keys: Map<String, String>
    private lateinit var consents: Set<String>
    private lateinit var provider: AIProvider
    private lateinit var model: AIModel
    private var wholeSong = false

    @Before fun start() {
        context = instrumentation.targetContext
        check(context.packageName == "com.rhymeai.app.motionqa") { "Privacy fixtures require the owned isolated QA app." }
        repo = ProjectRepository(context)
        keys = repo.apiKeySnapshot()
        consents = runBlocking { repo.cloudAIConsentsFlow.first() }
        scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario.onActivity { vm = ViewModelProvider(it)[MainViewModel::class.java] }
        waitUntil { vm.aiSettingsLoaded }
        onMain { provider = vm.selectedProvider; model = vm.selectedModel; wholeSong = vm.useWholeSongContext }
        runBlocking { AIProvider.entries.filter { it != AIProvider.LOCAL }.forEach { repo.saveApiKey(it.name, "") } }
        composeRule.onNodeWithText("New Song", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("songTitleEditor").assertExists()
        onMain {
            AIProvider.entries.filter { it != AIProvider.LOCAL }.forEach { p ->
                assertTrue("No live key is allowed in this fixture", vm.apiKey(p).isEmpty())
                CloudAISharingScope.entries.forEach { vm.setCloudAISharingConsent(p, it, false) }
            }
            vm.selectedProvider = AIProvider.GEMINI
            vm.selectedModel = AIModel.modelsForProvider(AIProvider.GEMINI).first()
            vm.saveUseWholeSongContext(false)
            vm.seedEditorForTesting("Privacy fixture", "private first line\nselected word", TextRange(19, 27))
        }
        awaitConsentWrites()
        waitUntil { runBlocking { repo.cloudAIConsentsFlow.first().isEmpty() } }
        composeRule.onNodeWithTag("songTitleEditor").assertTextEquals("Privacy fixture")
        onMain { vm.lyricsFieldValue = vm.lyricsFieldValue.copy(selection = TextRange(19, 27)) }
    }

    @After fun stop() {
        if (!::vm.isInitialized) return
        onMain {
            vm.cancelCloudAISharing(); vm.cancelSuggestions(); vm.dismissRewrite(); vm.dismissInspector()
            vm.selectedProvider = provider; vm.selectedModel = model; vm.saveUseWholeSongContext(wholeSong)
        }
        awaitConsentWrites()
        runBlocking {
            AIProvider.entries.filter { it != AIProvider.LOCAL }.forEach { p ->
                repo.saveApiKey(p.name, keys[p.name].orEmpty())
                CloudAISharingScope.entries.forEach { scope ->
                    val key = "${p.name}.${scope.name}"
                    repo.saveCloudAIConsent(key, key in consents)
                }
            }
        }
        scenario.close()
    }

    @Test fun everyCloudEntryPointStopsBeforeRequestUntilConsent() {
        onMain {
            vm.getSuggestions()
            assertEquals("suggestions", vm.cloudAISharingRequest?.purpose)
            assertFalse(vm.isLoading)
            vm.cancelCloudAISharing()
            vm.lyricsFieldValue = vm.lyricsFieldValue.copy(selection = TextRange(19, 27))
            vm.requestRewrite(RewriteAction.entries.first())
            assertEquals("rewrite", vm.cloudAISharingRequest?.purpose)
            assertFalse(vm.rewriteLoading)
            vm.cancelCloudAISharing(); vm.dismissRewrite()
            vm.openInspector("word", TextRange(28, 32))
            assertEquals("synonyms", vm.cloudAISharingRequest?.purpose)
            assertFalse(vm.inspectorSynonymsLoading)
            assertNull(vm.errorMessage)
            assertNull(vm.inspectorSynonymsError)
        }
    }

    @Test fun nativeConsentDialogSupportsCancelAndDurableApproval() {
        onMain { vm.getSuggestions() }
        composeRule.onNodeWithText("Allow sharing").assertIsDisplayed()
        // Compose idling does not wait for the platform dialog window's fade.
        SystemClock.sleep(350)
        val directory = File(context.filesDir, "privacy-qa").apply { mkdirs() }
        instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
            File(directory, "cloud-consent.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
        composeRule.onNodeWithText("Cancel", substring = false).performClick()
        waitUntil { vm.cloudAISharingRequest == null }
        assertFalse(vm.hasCloudAISharingConsent(AIProvider.GEMINI, CloudAISharingScope.SELECTED_CONTEXT))
        onMain { vm.getSuggestions() }
        composeRule.onNodeWithText("Allow sharing").assertIsDisplayed()
        composeRule.onNodeWithText("Allow sharing").performClick()
        waitUntil { vm.hasCloudAISharingConsent(AIProvider.GEMINI, CloudAISharingScope.SELECTED_CONTEXT) && !vm.cloudAIConsentSaving }
        waitUntil { vm.errorMessage?.startsWith("No API key set.") == true }
        assertNull(vm.cloudAISharingRequest)
        assertFalse(vm.isLoading)
    }

    @Test fun grantsAreDurableProviderAndScopeSpecificAndRevocable() {
        onMain { vm.setCloudAISharingConsent(AIProvider.GEMINI, CloudAISharingScope.SELECTED_CONTEXT, true) }
        waitUntil { vm.hasCloudAISharingConsent(AIProvider.GEMINI, CloudAISharingScope.SELECTED_CONTEXT) }
        assertTrue(runBlocking { "GEMINI.SELECTED_CONTEXT" in repo.cloudAIConsentsFlow.first() })
        onMain {
            assertFalse(vm.hasCloudAISharingConsent(AIProvider.GEMINI, CloudAISharingScope.WHOLE_SONG))
            assertFalse(vm.hasCloudAISharingConsent(AIProvider.CLAUDE, CloudAISharingScope.SELECTED_CONTEXT))
            vm.saveUseWholeSongContext(true); vm.getSuggestions()
            assertEquals(CloudAISharingScope.WHOLE_SONG, vm.cloudAISharingRequest?.scope)
            vm.cancelCloudAISharing()
            vm.setCloudAISharingConsent(AIProvider.GEMINI, CloudAISharingScope.SELECTED_CONTEXT, false)
            vm.openInspector("word", TextRange(28, 32))
            assertEquals(CloudAISharingScope.SELECTED_CONTEXT, vm.cloudAISharingRequest?.scope)
            assertFalse(vm.inspectorSynonymsLoading)
        }
        waitUntil { runBlocking { "GEMINI.SELECTED_CONTEXT" !in repo.cloudAIConsentsFlow.first() } }
    }

    @Test fun staleAndCancelledApprovalsDoNotGrantOrStartRequests() {
        onMain {
            val changes: List<() -> Unit> = listOf(
                { vm.cancelCloudAISharing() },
                { vm.selectedProvider = AIProvider.CLAUDE },
                { vm.saveUseWholeSongContext(true) },
                { vm.onThemeChanged("new theme") },
                { vm.onLyricsChanged(TextFieldValue("different lyrics")) }
            )
            changes.forEach { change ->
                vm.selectedProvider = AIProvider.GEMINI
                vm.saveUseWholeSongContext(false)
                vm.getSuggestions()
                val stale = vm.cloudAISharingRequest!!
                change()
                vm.approveCloudAISharing(stale)
                assertFalse(vm.hasCloudAISharingConsent(AIProvider.GEMINI, CloudAISharingScope.SELECTED_CONTEXT))
                assertFalse(vm.isLoading)
                assertNull(vm.cloudAISharingRequest)
            }
        }
    }

    @Test fun queuedKeyLookupKeepsCapturedProvider() = runBlocking {
        repo.saveApiKey(AIProvider.GEMINI.name, "synthetic-gemini-fixture")
        repo.saveApiKey(AIProvider.CLAUDE.name, "synthetic-claude-fixture")
        val queued = async(start = CoroutineStart.LAZY) { vm.resolveApiKey(AIProvider.GEMINI) }
        onMain { vm.selectedProvider = AIProvider.CLAUDE }
        assertEquals("synthetic-gemini-fixture", queued.await())
    }

    @Test fun changedContextRejectsLateResultsAndCancelsActiveWork() {
        onMain {
            val boundaries: List<() -> Unit> = listOf(
                { vm.selectedProvider = AIProvider.CLAUDE },
                { vm.selectedModel = AIModel.modelsForProvider(vm.selectedProvider).last() },
                { vm.saveUseWholeSongContext(!vm.useWholeSongContext) },
                { vm.onThemeChanged("new request theme") },
                { vm.onLyricsChanged(TextFieldValue("same song changed")) },
                { vm.onTitleChanged("another identity") },
                { vm.setCloudAISharingConsent(AIProvider.GEMINI, CloudAISharingScope.SELECTED_CONTEXT, false) }
            )
            boundaries.forEach { change ->
                val captured = vm.editorAIContext()
                val jobs = listOf("suggestionsJob", "rewriteJob", "inspectorSynonymsJob").map { name ->
                    Job().also { job -> field(name).set(vm, job) }
                }
                change()
                assertTrue(jobs.all { it.isCancelled })
                assertFalse(vm.isLoading); assertFalse(vm.rewriteLoading); assertFalse(vm.inspectorSynonymsLoading)
                if (captured != vm.editorAIContext()) assertFalse(vm.isCurrentAIContext(captured))
            }
            val captured = vm.editorAIContext()
            vm.openInspector("changed", TextRange(0, 7))
            assertFalse(vm.isCurrentAIContext(captured))
        }
    }

    @Test fun failedGrantPersistenceDoesNotAuthorizeThePendingAction() = runBlocking {
        val blocker = File(context.cacheDir, "privacy-consent-${System.nanoTime()}").apply { writeText("not a directory") }
        val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = PreferenceDataStoreFactory.create(scope = ioScope) { File(blocker, "settings.preferences_pb") }
        val original = field("repo").get(vm) as ProjectRepository
        val secure = ProjectRepository::class.java.getDeclaredField("secureKeyStore").apply { isAccessible = true }.get(original) as SecureKeyStore
        try {
            onMain {
                field("repo").set(vm, ProjectRepository(store, secure))
                vm.getSuggestions()
                vm.approveCloudAISharing(vm.cloudAISharingRequest!!)
            }
            waitUntil { vm.errorMessage?.contains("permission could not be saved") == true }
            onMain {
                assertFalse(vm.cloudAIConsentSaving)
                assertFalse(vm.hasCloudAISharingConsent(AIProvider.GEMINI, CloudAISharingScope.SELECTED_CONTEXT))
                assertFalse(vm.isLoading)
            }
        } finally {
            onMain { field("repo").set(vm, original) }
            ioScope.cancel()
            blocker.delete()
        }
    }

    private fun awaitConsentWrites() = runBlocking { (field("cloudAIConsentMutex").get(vm) as Mutex).withLock {} }
    private fun field(name: String) = MainViewModel::class.java.getDeclaredField(name).apply { isAccessible = true }
    private fun onMain(block: () -> Unit) = instrumentation.runOnMainSync(block)
    private fun waitUntil(condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return
            SystemClock.sleep(25)
        }
        fail("Privacy fixture did not reach the expected state")
    }
}
