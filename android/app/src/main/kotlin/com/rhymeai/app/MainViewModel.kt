package com.rhymeai.app

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rhymeai.app.data.model.AnalysisPresentation
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.SavedLocalModel
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeScheme
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.data.model.SongWorkspace
import com.rhymeai.app.data.model.DraftVersion
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.data.model.TrashedSongProject
import android.app.PendingIntent
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.repository.CorruptLibraryException
import com.rhymeai.app.data.sync.DriveSyncService
import com.rhymeai.app.data.sync.DRIVE_SYNC_PASSPHRASE_REQUIREMENT_MESSAGE
import com.rhymeai.app.data.sync.SyncResult
import com.rhymeai.app.data.repository.EncryptedPrefsKeyStore
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.service.AIService
import com.rhymeai.app.service.LocalModelService
import com.rhymeai.app.service.LocalModelOperationGate
import com.rhymeai.app.service.VoiceMemoService
import com.rhymeai.app.util.ProsodyAnalyzer
import com.rhymeai.app.util.EditHistory
import com.rhymeai.app.util.RhymeMatches
import com.rhymeai.app.util.SectionMap
import com.rhymeai.app.util.SectionRef
import com.rhymeai.app.util.WordProsody
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

enum class CloudAISharingScope(val label: String) { SELECTED_CONTEXT("Selected context"), WHOLE_SONG("Whole song") }

data class CloudAISharingRequest(
    val provider: AIProvider,
    val scope: CloudAISharingScope,
    val purpose: String,
    val id: String = java.util.UUID.randomUUID().toString()
)

internal data class EditorAIContext(
    val projectId: String?, val title: String, val lyrics: String, val theme: String,
    val selection: TextRange, val provider: AIProvider, val model: AIModel,
    val wholeSong: Boolean, val rhymeType: RhymeType, val scheme: String,
    val complexity: RhymeComplexity, val word: String?, val wordRange: TextRange?
)

enum class SaveStatus { IDLE, SAVING, SAVED }

/**
 * A suggestion line paired with its phonetic tier and hook flag.
 *
 * rhymeTier: 2 = perfect/multi-syllable, 1 = near, 0 = unverified.
 * isHook: true when this line repeats a chorus end-word from the first chorus
 *         instance — badge shows "hook" instead of "perfect".
 */
data class SuggestedLine(
    val text: String,
    val rhymeTier: Int,
    val isHook: Boolean = false
)

data class RhymeContext(
    val targetLine: String?,
    val currentLetter: String,
    val stanzaLines: List<String>,
    val currentLineIndex: Int,
    val currentSection: SongSection = SongSection.UNKNOWN,
    /** Full section identity including ordinal and chorus line content. Null when
     *  the cursor is in an unrecognised position (should rarely happen). */
    val currentSectionRef: SectionRef? = null
)

internal enum class DriveSyncAction {
    Sync,
    Restore
}

internal fun formatDriveSyncSuccessStatus(
    action: DriveSyncAction,
    projectCount: Int,
    trashedCount: Int,
    recordingCount: Int
): String {
    val verb = when (action) {
        DriveSyncAction.Sync -> "Sync complete"
        DriveSyncAction.Restore -> "Restore complete"
    }
    return "$verb — ${plural(projectCount, "project")}, $trashedCount trashed, ${plural(recordingCount, "recording")}. API keys stay on this device."
}

internal fun driveSyncProgressLabel(action: DriveSyncAction?): String =
    when (action) {
        DriveSyncAction.Restore -> "Restoring backup..."
        else -> "Syncing backup..."
    }

internal fun nextDriveSyncActionAfterAuthorization(pendingAction: DriveSyncAction?): DriveSyncAction =
    pendingAction ?: DriveSyncAction.Sync

internal fun shouldAttemptBackgroundDriveSync(
    hasPassphrase: Boolean,
    authorizedForNonInteractiveSync: Boolean,
    syncInProgress: Boolean
): Boolean = hasPassphrase && authorizedForNonInteractiveSync && !syncInProgress

internal fun shouldDeferBackgroundDriveSync(
    nowMillis: Long,
    lastAttemptMillis: Long,
    minIntervalMillis: Long
): Boolean = lastAttemptMillis > 0L && nowMillis - lastAttemptMillis < minIntervalMillis

private fun plural(count: Int, noun: String): String =
    if (count == 1) "$count $noun" else "$count ${noun}s"

data class SuggestionInsertion(val id: Long, val range: TextRange, val lyrics: String)

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private companion object {
        private const val AUTOSAVE_DEBOUNCE_MILLIS = 450L
        private const val SAVE_STATUS_VISIBLE_MILLIS = 700L
        private const val BACKGROUND_SYNC_MIN_INTERVAL_MILLIS = 15 * 60 * 1000L
    }

    private val repo = ProjectRepository(application)
    private val driveSyncService = DriveSyncService(
        context = application,
        secureKeyStore = EncryptedPrefsKeyStore(application),
        driveClientId = BuildConfig.DRIVE_OAUTH_CLIENT_ID
    )
    private val localModelService = LocalModelService().also {
        it.initialize(application)
    }
    private val aiService = AIService().also { it.localModelService = localModelService }

    /** Owns MediaRecorder/MediaPlayer resources; released in onCleared(). */
    val voiceMemoService = VoiceMemoService(application)

    // Editor state
    var title by mutableStateOf("")
    var lyricsFieldValue by mutableStateOf(TextFieldValue(""))
    var theme by mutableStateOf("")

    val lyrics: String get() = lyricsFieldValue.text
    val cursorPosition: Int
        get() = lyricsFieldValue.selection.start.coerceIn(0, lyricsFieldValue.text.length)

    // UI state
    var suggestions by mutableStateOf<List<SuggestedLine>>(emptyList())
    var suggestionInsertion by mutableStateOf<SuggestionInsertion?>(null)
        private set
    private var suggestionInsertionRevision = 0L
    var isLoading by mutableStateOf(false)
    private var _rhymeType by mutableStateOf(RhymeType.PERFECT)
    var rhymeType: RhymeType
        get() = _rhymeType
        set(value) {
            if (_rhymeType == value) return
            cancelEditorAIWork()
            _rhymeType = value
        }
    private var _rhymeScheme by mutableStateOf(RhymeScheme.AABB)
    var rhymeScheme: RhymeScheme
        get() = _rhymeScheme
        set(value) {
            if (_rhymeScheme == value) return
            cancelEditorAIWork()
            _rhymeScheme = value
        }
    private var _customRhymeScheme by mutableStateOf("")
    var customRhymeScheme: String
        get() = _customRhymeScheme
        set(value) {
            if (_customRhymeScheme == value) return
            cancelEditorAIWork()
            _customRhymeScheme = value
        }
    private var _rhymeComplexity by mutableStateOf(RhymeComplexity.MODERATE)
    var rhymeComplexity: RhymeComplexity
        get() = _rhymeComplexity
        set(value) {
            if (_rhymeComplexity == value) return
            cancelEditorAIWork()
            _rhymeComplexity = value
        }
    // Editor toggles — initialized from DataStore in init{}, persisted on every change.
    var useWholeSongContext by mutableStateOf(false)
        private set

    fun saveUseWholeSongContext(value: Boolean) {
        if (useWholeSongContext == value) return
        cancelEditorAIWork()
        useWholeSongContext = value
        persistEditorToggles()
    }
    var isHighlightEnabled by mutableStateOf(true)
    var isSyllableColoringEnabled by mutableStateOf(true)
    var isStressPreviewEnabled by mutableStateOf(false)
    var isRhymeHighlightEnabled by mutableStateOf(false)
    var isBeatGridEnabled by mutableStateOf(false)
    var beatGridBpm by mutableStateOf(90)

    // Project management
    var projects by mutableStateOf<List<SongProject>>(emptyList())
    var trashedProjects by mutableStateOf<List<TrashedSongProject>>(emptyList())
    var currentProjectId by mutableStateOf<String?>(null)
    private var positionSaveJob: Job? = null
    private var workspaces by mutableStateOf<Map<String, SongWorkspace>>(emptyMap())
    val songWorkspace: SongWorkspace get() = workspaces[currentProjectId] ?: SongWorkspace()
    var editorScrollOffset by mutableStateOf(0f)
        private set
    var editorPositionRevision by mutableStateOf(0)
        private set
    var showSongNotebook by mutableStateOf(false)
    var persistenceError by mutableStateOf<String?>(null)
    var savingBeforeNavigation by mutableStateOf(false)
        private set
    var notebookError by mutableStateOf<String?>(null)
        private set
    var restoringDraft by mutableStateOf(false)
        private set
    val recentProject: SongProject? get() = projects.maxByOrNull { it.updatedAt }
    val localReady: Boolean get() = localModelLoaded && !localModelLoading && localModelError == null
    val localReadinessLabel: String get() = when {
        localModelLoading -> "Loading model"
        localModelError != null -> "Model unavailable"
        localReady -> "Ready"
        else -> "Choose a model"
    }

    private fun updateWorkspace(id: String, transform: (SongWorkspace) -> SongWorkspace) {
        if (notebookError != null || restoringDraft) return
        val next = transform(workspaces[id] ?: SongWorkspace())
        workspaces = workspaces + (id to next)
        viewModelScope.launch {
            try { repo.saveWorkspace(id, next) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { notebookError = "Song Notebook could not be saved. Your lyrics are still available. Restart the app to try again." }
        }
    }

    fun rememberEditorPosition(scrollOffset: Float = editorScrollOffset) {
        editorScrollOffset = scrollOffset.coerceAtLeast(0f)
        if (notebookError != null || restoringDraft) return
        val id = currentProjectId ?: return
        val range = lyricsFieldValue.selection
        workspaces = workspaces + (id to songWorkspace.copy(selectionStart = range.start, selectionEnd = range.end, scrollOffset = editorScrollOffset))
        positionSaveJob?.cancel()
        positionSaveJob = viewModelScope.launch {
            delay(250)
            try { workspaces[id]?.let { repo.saveWorkspace(id, it) } } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { notebookError = "Song Notebook could not be saved. Your lyrics are still available. Restart the app to try again." }
        }
    }

    private fun restoreEditorPosition() {
        val saved = songWorkspace
        lyricsFieldValue = lyricsFieldValue.copy(selection = TextRange(
            saved.selectionStart.coerceIn(0, lyrics.length), saved.selectionEnd.coerceIn(0, lyrics.length)
        ))
        editorScrollOffset = saved.scrollOffset.coerceAtLeast(0f)
        editorPositionRevision++
    }

    fun keepAlternate(text: String) {
        if (text.isBlank() || notebookError != null || restoringDraft) return
        val id = ensureProjectForNotebook()
        updateWorkspace(id) { it.keep(text, System.currentTimeMillis()) }
    }

    fun keepSelectedLyrics() {
        val selection = pendingRewriteRange ?: lyricsFieldValue.selection
        keepAlternate(lyrics.substring(selection.min.coerceIn(0, lyrics.length), selection.max.coerceIn(0, lyrics.length)))
    }

    fun removeAlternate(id: String) {
        currentProjectId?.let { songId -> updateWorkspace(songId) { it.copy(alternates = it.alternates.filterNot { line -> line.id == id }) } }
    }

    fun saveDraftVersion() {
        if (notebookError != null || restoringDraft) return
        val id = ensureProjectForNotebook()
        updateWorkspace(id) { it.checkpoint(title, lyrics, theme, System.currentTimeMillis(), force = true) }
        triggerAutoSave()
    }

    fun restoreDraftVersion(version: DraftVersion, onRestored: () -> Unit = {}) {
        val id = currentProjectId ?: return
        if (notebookError != null || restoringDraft) return
        val currentTitle = title
        val currentLyrics = lyrics
        val currentTheme = theme
        val preserved = songWorkspace.checkpoint(currentTitle, currentLyrics, currentTheme, System.currentTimeMillis(), force = true)
        positionSaveJob?.cancel()
        restoringDraft = true
        var restored = false
        viewModelScope.launch {
            try {
                repo.saveWorkspace(id, preserved)
                if (currentProjectId != id || projects.none { it.id == id } || title != currentTitle || lyrics != currentLyrics || theme != currentTheme) return@launch
                workspaces = workspaces + (id to preserved)
                dismissRewrite()
                title = version.title
                theme = version.theme
                applyAtomicLyricsEdit(TextFieldValue(version.lyrics))
                editorScrollOffset = 0f
                editorPositionRevision++
                restored = true
                triggerAutoSave()
                onRestored()
            } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) {
                notebookError = "Your current draft could not be preserved, so nothing was restored. Restart the app to try again."
            } finally {
                restoringDraft = false
                if (restored) rememberEditorPosition()
                purgeExpiredTrashedProjects()
            }
        }
    }

    fun flushCurrentDraft(onSaved: () -> Unit = {}) {
        if (restoringDraft || savingBeforeNavigation) return
        if (!appearanceLoaded || showStartMenu) { onSaved(); return }
        autoSaveJob?.cancel()
        positionSaveJob?.cancel()
        if (title.isBlank() && lyrics.isBlank() && theme.isBlank() && currentProjectId == null) { onSaved(); return }
        val now = System.currentTimeMillis()
        val existing = projects.firstOrNull { it.id == currentProjectId }
        val project = existing?.copy(
            title = title.ifEmpty { "Untitled Song" }, lyrics = lyrics, theme = theme,
            updatedAt = if (existing.lyrics == lyrics && existing.title == title.ifEmpty { "Untitled Song" } && existing.theme == theme) existing.updatedAt else now
        ) ?: createUntitledProjectSnapshot()
        currentProjectId = project.id
        projects = listOf(project) + projects.filterNot { it.id == project.id }
        rememberEditorPosition()
        updateWorkspace(project.id) { it.checkpoint(title, lyrics, theme, now, force = true) }
        val savedProjects = projects
        val savedTitle = title
        val savedLyrics = lyrics
        val savedTheme = theme
        savingBeforeNavigation = true
        viewModelScope.launch {
            try {
                persistActiveProjectSnapshot(project.id, savedProjects, savedTitle, savedLyrics, savedTheme)
                if (currentProjectId == project.id && title == savedTitle && lyrics == savedLyrics && theme == savedTheme) {
                    onSaved()
                }
            } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) {
                persistenceError = "Your draft could not be saved. It is still open. Free up storage and try again."
            } finally {
                savingBeforeNavigation = false
            }
        }
    }

    var saveStatus by mutableStateOf(SaveStatus.IDLE)
    var showProjectsDialog by mutableStateOf(false)
    var showTemplatesDialog by mutableStateOf(false)
    var showStartMenu by mutableStateOf(true)
    var showExportSheet by mutableStateOf(false)

    // Settings
    private var _appAppearance by mutableStateOf(AppAppearance.INK)
    val appAppearance: AppAppearance
        get() = _appAppearance
    private var _analysisPresentation by mutableStateOf(AnalysisPresentation.COLOR)
    val analysisPresentation: AnalysisPresentation
        get() = _analysisPresentation
    var appearanceLoaded by mutableStateOf(false)
        private set
    private var _selectedProvider by mutableStateOf(AIProvider.LOCAL)
    var selectedProvider: AIProvider
        get() = _selectedProvider
        set(value) {
            if (_selectedProvider == value) return
            cancelEditorAIWork()
            _selectedProvider = value
        }
    private var _selectedModel by mutableStateOf(AIModel.LOCAL_MODEL)
    var selectedModel: AIModel
        get() = _selectedModel
        set(value) {
            if (_selectedModel == value) return
            cancelEditorAIWork()
            _selectedModel = value
        }
    var showSettingsDialog by mutableStateOf(false)
    var cloudAISharingRequest by mutableStateOf<CloudAISharingRequest?>(null)
        private set
    internal var aiSettingsLoaded by mutableStateOf(false)
        private set
    var cloudAIConsentSaving by mutableStateOf(false)
        private set
    private var cloudAIConsents by mutableStateOf<Set<String>>(emptySet())
    private var pendingCloudAIAction: (() -> Unit)? = null
    private var pendingCloudAIContext: EditorAIContext? = null
    private val cloudAIConsentMutex = kotlinx.coroutines.sync.Mutex()
    private val cloudAIConsentVersions = mutableMapOf<String, Long>()
    private var suggestionsRevision = 0L
    private var rewriteRevision = 0L
    private var synonymsRevision = 0L

    internal fun editorAIContext() = EditorAIContext(
        currentProjectId, title, lyrics, theme, lyricsFieldValue.selection, selectedProvider,
        selectedModel, useWholeSongContext, rhymeType, activeRhymeScheme, rhymeComplexity,
        inspectorWord, inspectorRange
    )

    internal fun isCurrentAIContext(context: EditorAIContext) = context == editorAIContext()

    fun hasCloudAISharingConsent(provider: AIProvider, scope: CloudAISharingScope): Boolean =
        provider == AIProvider.LOCAL || "${provider.name}.${scope.name}" in cloudAIConsents

    fun setCloudAISharingConsent(provider: AIProvider, scope: CloudAISharingScope, allowed: Boolean) {
        if (provider == AIProvider.LOCAL) return
        val key = "${provider.name}.${scope.name}"
        if (!allowed) {
            cloudAIConsents = cloudAIConsents - key
            cancelEditorAIWork()
        }
        val version = (cloudAIConsentVersions[key] ?: 0L) + 1L
        cloudAIConsentVersions[key] = version
        viewModelScope.launch { persistCloudAIConsent(key, allowed, version) }
    }

    private suspend fun persistCloudAIConsent(
        key: String, allowed: Boolean, version: Long, isCurrent: () -> Boolean = { true }
    ): Boolean = cloudAIConsentMutex.withLock {
            if (cloudAIConsentVersions[key] != version || (allowed && !isCurrent())) return@withLock false
            try {
                // Publish grants only after durable storage succeeds.
                repo.saveCloudAIConsent(key, allowed)
                if (cloudAIConsentVersions[key] != version) return@withLock false
                if (allowed && !isCurrent()) {
                    repo.saveCloudAIConsent(key, false)
                    cloudAIConsents = cloudAIConsents - key
                    return@withLock false
                }
                cloudAIConsents = if (allowed) cloudAIConsents + key else cloudAIConsents - key
                true
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                cloudAIConsents = cloudAIConsents - key
                cancelEditorAIWork()
                errorMessage = "Sharing permission could not be saved. Review it again before using cloud AI."
                false
            }
        }

    private fun sharingScope(purpose: String) =
        if (purpose != "synonyms" && useWholeSongContext) CloudAISharingScope.WHOLE_SONG
        else CloudAISharingScope.SELECTED_CONTEXT

    private fun authorizeCloudAI(purpose: String, action: () -> Unit): Boolean {
        val scope = sharingScope(purpose)
        if (hasCloudAISharingConsent(selectedProvider, scope)) return true
        cloudAISharingRequest = CloudAISharingRequest(selectedProvider, scope, purpose)
        pendingCloudAIContext = editorAIContext()
        pendingCloudAIAction = action
        return false
    }

    fun approveCloudAISharing(request: CloudAISharingRequest) {
        if (cloudAIConsentSaving) return
        val context = pendingCloudAIContext
        if (cloudAISharingRequest != request || context == null || !isCurrentAIContext(context) ||
            request.scope != sharingScope(request.purpose)) {
            cancelCloudAISharing()
            return
        }
        val action = pendingCloudAIAction
        val key = "${request.provider.name}.${request.scope.name}"
        val version = (cloudAIConsentVersions[key] ?: 0L) + 1L
        cloudAIConsentVersions[key] = version
        cloudAIConsentSaving = true
        viewModelScope.launch {
            try {
                val saved = persistCloudAIConsent(key, true, version) {
                    cloudAISharingRequest == request && isCurrentAIContext(context)
                }
                if (saved && cloudAISharingRequest == request && isCurrentAIContext(context)) {
                    cancelCloudAISharing()
                    action?.invoke()
                }
            } finally {
                cloudAIConsentSaving = false
            }
        }
    }

    fun cancelCloudAISharing() {
        cloudAISharingRequest = null
        pendingCloudAIAction = null
        pendingCloudAIContext = null
    }

    private fun cancelEditorAIWork() {
        cancelCloudAISharing()
        cancelSuggestions()
        suggestions = emptyList()
        errorMessage = null
        dismissRewrite()
        synonymsRevision++
        inspectorSynonymsJob?.cancel()
        inspectorSynonymsJob = null
        inspectorSynonyms = emptyList()
        inspectorSynonymsLoading = false
        inspectorSynonymsError = null
    }
    /**
     * Surfaces whether each provider has any key stored. The actual key values
     * never live in observable state — they are pulled from the secure store on
     * demand at request time so they cannot leak via heap dumps, Compose state
     * snapshots, or test fixtures.
     */
    var apiKeyPresence by mutableStateOf<Map<String, Boolean>>(emptyMap())
        private set

    /**
     * EncryptedSharedPreferences hits the Android Keystore on first read, which can
     * take tens of milliseconds — resolve off the main thread inside request coroutines.
     */
    internal suspend fun resolveApiKey(provider: AIProvider): String =
        withContext(Dispatchers.IO) { apiKey(provider) }

    fun apiKey(provider: AIProvider): String {
        val storedKey = repo.getApiKey(provider.name)
        if (storedKey.isNotBlank()) return storedKey

        return if (BuildConfig.DEBUG &&
            provider == AIProvider.GEMINI &&
            BuildConfig.GEMINI_TEST_KEY.isNotBlank()
        ) {
            BuildConfig.GEMINI_TEST_KEY
        } else {
            ""
        }
    }

    // --- Drive sync state ---

    /** True while a sync is in progress. */
    var syncInProgress by mutableStateOf(false)
        private set

    private var syncCurrentAction by mutableStateOf<DriveSyncAction?>(null)

    val syncProgressLabel: String
        get() = driveSyncProgressLabel(syncCurrentAction)

    /**
     * Human-readable result of the last sync attempt.
     * Null = never synced this session.
     * Positive string = success.
     * Negative string = error description.
     */
    var syncLastResult by mutableStateOf<String?>(null)
        private set

    /**
     * Set when Drive authorization requires the user to approve a consent screen.
     * The UI should launch this intent via startIntentSenderForResult; after the
     * user returns, clear it and call [triggerSync] again.
     */
    var syncPendingIntent by mutableStateOf<PendingIntent?>(null)

    /** True if a sync passphrase has been stored in the secure key store. */
    var syncPassphraseStored by mutableStateOf(false)
        private set

    private var driveSyncAuthorizedForNonInteractive by mutableStateOf(false)
    private var pendingAuthAction: DriveSyncAction? = null
    private var lastBackgroundSyncAttemptMillis = 0L

    fun saveSyncPassphrase(passphrase: String) {
        if (!driveSyncService.setPassphrase(passphrase)) {
            syncLastResult = DRIVE_SYNC_PASSPHRASE_REQUIREMENT_MESSAGE
            syncPassphraseStored = driveSyncService.hasPassphrase()
            driveSyncAuthorizedForNonInteractive = false
            return
        }
        syncPassphraseStored = true
        driveSyncAuthorizedForNonInteractive = false
        syncLastResult = null
    }

    fun triggerSync() {
        runDriveSync(action = DriveSyncAction.Sync, interactive = true)
    }

    fun triggerRestore() {
        runDriveSync(action = DriveSyncAction.Restore, interactive = true)
    }

    fun retryAfterDriveAuthorization() {
        val action = nextDriveSyncActionAfterAuthorization(pendingAuthAction)
        pendingAuthAction = null
        syncPendingIntent = null
        runDriveSync(action = action, interactive = true)
    }

    fun triggerBackgroundDriveSync() {
        val hasPassphrase = driveSyncService.hasPassphrase()
        val now = System.currentTimeMillis()
        syncPassphraseStored = hasPassphrase
        if (!shouldAttemptBackgroundDriveSync(
                hasPassphrase = hasPassphrase,
                authorizedForNonInteractiveSync = driveSyncAuthorizedForNonInteractive,
                syncInProgress = syncInProgress
            ) ||
            shouldDeferBackgroundDriveSync(
                nowMillis = now,
                lastAttemptMillis = lastBackgroundSyncAttemptMillis,
                minIntervalMillis = BACKGROUND_SYNC_MIN_INTERVAL_MILLIS
            )
        ) {
            return
        }
        lastBackgroundSyncAttemptMillis = now
        runDriveSync(action = DriveSyncAction.Sync, interactive = false)
    }

    private fun runDriveSync(action: DriveSyncAction, interactive: Boolean) {
        if (syncInProgress) return
        syncInProgress = true
        syncCurrentAction = action
        syncLastResult = null
        viewModelScope.launch {
            val result = when (action) {
                DriveSyncAction.Sync -> driveSyncService.sync(repo)
                DriveSyncAction.Restore -> driveSyncService.restore(repo)
            }
            syncInProgress = false
            syncCurrentAction = null
            handleSyncResult(result, action, interactive)
        }
    }

    private fun handleSyncResult(
        result: SyncResult,
        action: DriveSyncAction,
        interactive: Boolean
    ) {
        when (result) {
            is SyncResult.Success -> {
                driveSyncAuthorizedForNonInteractive = true
                pendingAuthAction = null
                syncLastResult = formatDriveSyncSuccessStatus(
                    action = action,
                    projectCount = result.merged.projects.size,
                    trashedCount = result.merged.trashed.size,
                    recordingCount = result.merged.recordings.size
                )
                // Re-read projects into UI state since the snapshot may have changed.
                projects = result.merged.projects
                trashedProjects = result.merged.trashed
            }
            is SyncResult.AuthorizationRequired -> {
                driveSyncAuthorizedForNonInteractive = false
                syncLastResult = if (interactive) {
                    pendingAuthAction = action
                    syncPendingIntent = result.pendingIntent
                    "Authorization required — approve Google Drive access to back up and restore projects, trash, and recordings."
                } else {
                    "Background sync skipped — open Settings and run Sync now to approve Google Drive access."
                }
            }
            is SyncResult.WrongPassphrase -> {
                driveSyncAuthorizedForNonInteractive = false
                syncLastResult = "Wrong passphrase — Drive backup was not changed."
            }
            is SyncResult.CorruptRemote -> {
                driveSyncAuthorizedForNonInteractive = false
                syncLastResult = "Your Drive backup is unreadable and was not overwritten. Try Restore, or contact support."
            }
            is SyncResult.NotConfigured -> {
                driveSyncAuthorizedForNonInteractive = false
                syncPassphraseStored = driveSyncService.hasPassphrase()
                syncLastResult = if (!syncPassphraseStored) {
                    "Set a sync passphrase in Settings to enable encrypted Drive backup for projects, trash, and recordings."
                } else {
                    "Drive backup is not configured — check Google Cloud Console setup."
                }
            }
            is SyncResult.NetworkError -> {
                syncLastResult = "Drive sync failed: ${result.message}"
            }
            is SyncResult.UnknownError -> {
                syncLastResult = "Drive sync failed: ${result.cause.message ?: "unexpected error"}"
            }
        }
    }

    // Local model state
    var localModelPath by mutableStateOf<String?>(null)
    var localModelLoading by mutableStateOf(false)
    var localModelLoaded by mutableStateOf(false)
    var localModelError by mutableStateOf<String?>(null)
    var savedLocalModels by mutableStateOf<List<SavedLocalModel>>(emptyList())
        private set
    var selectedLocalModelId by mutableStateOf<String?>(null)
        private set
    private var localModelValidationJob: Job? = null
    private var localModelValidationGeneration = 0L
    private val localModelOperations = LocalModelOperationGate()

    // Error state
    var errorMessage by mutableStateOf<String?>(null)

    // Rewrite state
    var rewriteAction by mutableStateOf<RewriteAction?>(null)
    var rewriteLoading by mutableStateOf(false)
    var rewritePreview by mutableStateOf<String?>(null)
    var rewriteOriginal by mutableStateOf<String?>(null)
    var rewriteError by mutableStateOf<String?>(null)
    var pendingRewriteRange by mutableStateOf<TextRange?>(null)
        private set
    private var rewriteRange: TextRange? = null
    private var rewriteJob: Job? = null
    private var rewriteRejectedCandidates: Set<String> = emptySet()
    private var suggestionsJob: Job? = null

    // Word inspector state
    var inspectorWord by mutableStateOf<String?>(null)
        private set
    var inspectorRange by mutableStateOf<TextRange?>(null)
        private set
    var inspectorProsody by mutableStateOf<WordProsody?>(null)
        private set
    var inspectorMatches by mutableStateOf<RhymeMatches?>(null)
        private set
    var inspectorSynonyms by mutableStateOf<List<String>>(emptyList())
        private set
    var inspectorSynonymsLoading by mutableStateOf(false)
        private set
    var inspectorSynonymsError by mutableStateOf<String?>(null)
        private set
    private var inspectorSynonymsJob: Job? = null

    val showInspector: Boolean get() = inspectorWord != null

    val singleWordSelection: Pair<String, TextRange>?
        get() {
            val range = pendingRewriteRange ?: return null
            val text = lyrics
            if (range.min < 0 || range.max > text.length || range.min >= range.max) return null
            val word = text.substring(range.min, range.max)
            if (word.length < 2) return null
            if (word.any { !it.isLetter() && it != '\'' }) return null
            return word to range
        }

    val hasActiveRewrite: Boolean
        get() = rewriteAction != null

    val canApplyRewrite: Boolean
        get() = rewritePreview != null && !rewriteLoading

    val inlineRewriteText: String
        get() {
            val range = rewriteRange ?: return lyrics
            val replacement = rewritePreview ?: rewriteOriginal ?: return lyrics
            val text = lyrics
            if (range.min < 0 || range.max > text.length) return lyrics
            return text.replaceRange(range.min, range.max, replacement)
        }

    val inlineRewriteRange: TextRange?
        get() {
            val range = rewriteRange ?: return null
            val replacement = rewritePreview ?: rewriteOriginal ?: return null
            val displayText = inlineRewriteText
            val start = range.min
            val end = start + replacement.length
            if (start < 0 || end > displayText.length) return null
            return TextRange(start, end)
        }

    private var autoSaveJob: Job? = null
    private var trashSchedulerJob: Job? = null
    private val lyricsHistory = EditHistory<TextFieldValue>()
    var canUndoLyrics by mutableStateOf(false)
        private set
    var canRedoLyrics by mutableStateOf(false)
        private set

    val activeRhymeScheme: String
        get() = if (rhymeScheme == RhymeScheme.CUSTOM)
            customRhymeScheme.ifEmpty { "AABB" }
        else rhymeScheme.pattern

    init {
        // Reflect stored passphrase presence without reading the value itself.
        syncPassphraseStored = driveSyncService.hasPassphrase()

        viewModelScope.launch {
            _appAppearance = runCatching { repo.appearanceFlow.first() }
                .getOrDefault(AppAppearance.INK)
            _analysisPresentation = runCatching { repo.analysisPresentationFlow.first() }
                .getOrDefault(AnalysisPresentation.COLOR)
            appearanceLoaded = true

            // Load projects
            projects = try {
                repo.projectsFlow.first()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: CorruptLibraryException) {
                persistenceError = corruptLibraryMessage(error)
                emptyList()
            }
            trashedProjects = try {
                repo.trashedProjectsFlow.first()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: CorruptLibraryException) {
                persistenceError = corruptLibraryMessage(error)
                emptyList()
            }
            workspaces = try { repo.workspacesFlow.first() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) {
                notebookError = "Song Notebook could not be opened. Your songs are still available; notebook data has been left untouched."
                emptyMap()
            }
            purgeExpiredTrashedProjects()
            scheduleTrashPurge()
            currentProjectId = repo.currentProjectIdFlow.first()

            // Load API keys, provider, and model. The key values themselves are
            // never copied into Compose state — we only record which providers
            // have a non-empty key so the UI can show a "configured" badge.
            repo.ensureApiKeysMigrated()
            apiKeyPresence = repo.apiKeySnapshot().mapValues { it.value.isNotEmpty() }
            cloudAIConsents = repo.cloudAIConsentsFlow.first()
            val savedProvider = repo.selectedProviderFlow.first()
            selectedProvider = AIProvider.fromName(savedProvider)
            val savedModelId = repo.modelIdFlow.first()
            selectedModel = AIModel.entries.find { it.id == savedModelId && it.provider == selectedProvider }
                ?: AIModel.modelsForProvider(selectedProvider).first()
            restoreSavedLocalModels()

            // Load editor state
            val (savedTitle, savedLyrics, savedTheme) = repo.editorStateFlow().first()
            title = savedTitle
            lyricsFieldValue = TextFieldValue(savedLyrics)
            theme = savedTheme
            restoreEditorPosition()

            // Load persisted editor toggles — must happen before the editor is shown.
            val toggles = repo.editorTogglesFlow.first()
            useWholeSongContext = toggles.useWholeSongContext
            isHighlightEnabled = toggles.isHighlightEnabled
            isSyllableColoringEnabled = toggles.isSyllableColoringEnabled
            isStressPreviewEnabled = toggles.isStressIpaEnabled
            isRhymeHighlightEnabled = toggles.isRhymeHighlightEnabled
            isBeatGridEnabled = toggles.isBeatGridEnabled

            aiSettingsLoaded = true
            // Always show start menu on fresh launch
            showStartMenu = true

            // Observe project changes
            launch {
                try {
                    repo.projectsFlow.collect { projects = it }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: CorruptLibraryException) {
                    persistenceError = corruptLibraryMessage(error)
                }
            }
            launch {
                try {
                    repo.trashedProjectsFlow.collect {
                        trashedProjects = it
                        scheduleTrashPurge()
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: CorruptLibraryException) {
                    persistenceError = corruptLibraryMessage(error)
                }
            }
        }
    }

    fun computeRhymeContext(): RhymeContext {
        return RhymeContextAnalyzer.compute(lyrics, cursorPosition, activeRhymeScheme)
    }

    private fun currentSongSection(text: String, cursor: Int): SongSection {
        return RhymeContextAnalyzer.currentSongSection(text, cursor)
    }

    fun getSuggestions() {
        if (lyrics.isEmpty()) return
        if (selectedProvider == AIProvider.LOCAL && !localReady) {
            errorMessage = if (localModelLoading) "Wait for your local model to finish loading." else "Choose a local model in Settings to get suggestions."
            return
        }
        if (!authorizeCloudAI("suggestions", ::getSuggestions)) return
        val context = computeRhymeContext()
        cancelSuggestions()
        val revision = suggestionsRevision
        val requestContext = editorAIContext()
        val provider = selectedProvider
        val modelId = selectedModel.id
        val wholeSong = useWholeSongContext
        val requestLyrics = if (provider == AIProvider.LOCAL || wholeSong) lyrics else context.targetLine.orEmpty()
        val requestTheme = theme
        val requestRhymeType = rhymeType
        val requestScheme = activeRhymeScheme
        val requestComplexity = rhymeComplexity
        val sectionRef = if (provider == AIProvider.LOCAL || wholeSong) context.currentSectionRef else null
        suggestions = emptyList()
        errorMessage = null
        isLoading = true
        suggestionsJob = viewModelScope.launch {
            try {
                val key = resolveApiKey(provider)
                if (revision != suggestionsRevision || !isCurrentAIContext(requestContext)) return@launch
                var emittedSuggestion = false
                aiService.streamSuggestions(
                    provider, key, modelId, requestTheme, requestLyrics, context.targetLine,
                    requestRhymeType, requestScheme, context.currentLetter, context.currentSection,
                    requestComplexity, wholeSong, sectionRef, requestLyrics
                ).collect { line ->
                    if (revision != suggestionsRevision || !isCurrentAIContext(requestContext)) return@collect
                    emittedSuggestion = true
                    suggestions = suggestions + line
                }
                if (revision == suggestionsRevision && isCurrentAIContext(requestContext) && !emittedSuggestion) {
                    errorMessage = "AI did not return suggestions. Try again."
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (revision == suggestionsRevision && isCurrentAIContext(requestContext)) errorMessage = e.message ?: "Failed to get suggestions"
            } finally {
                if (revision == suggestionsRevision) isLoading = false
            }
        }
    }

    fun cancelSuggestions() {
        suggestionsRevision++
        suggestionsJob?.cancel()
        suggestionsJob = null
        isLoading = false
    }

    // ---------------------------------------------------------------------------
    // Editor toggle persistence — call after any toggle change so DataStore
    // stays in sync. Runs on a background coroutine to avoid blocking the UI.
    // ---------------------------------------------------------------------------

    fun persistEditorToggles() {
        viewModelScope.launch {
            repo.saveEditorToggles(
                ProjectRepository.EditorToggles(
                    useWholeSongContext = useWholeSongContext,
                    isStressIpaEnabled = isStressPreviewEnabled,
                    isHighlightEnabled = isHighlightEnabled,
                    isSyllableColoringEnabled = isSyllableColoringEnabled,
                    isRhymeHighlightEnabled = isRhymeHighlightEnabled,
                    isBeatGridEnabled = isBeatGridEnabled
                )
            )
        }
    }

    fun setAppAppearance(appearance: AppAppearance) {
        if (_appAppearance == appearance) return
        _appAppearance = appearance
        viewModelScope.launch {
            try {
                repo.saveAppearance(appearance)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = e.message ?: "Failed to save appearance"
            }
        }
    }

    fun setAnalysisPresentation(value: AnalysisPresentation) {
        _analysisPresentation = value
        viewModelScope.launch {
            try {
                repo.saveAnalysisPresentation(value)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                errorMessage = error.message ?: "Failed to save analysis style"
            }
        }
    }

    fun requestRewrite(action: RewriteAction) {
        val selection = pendingRewriteRange ?: lyricsFieldValue.selection
        val start = selection.min.coerceIn(0, lyrics.length)
        val end = selection.max.coerceIn(0, lyrics.length)
        if (start >= end) return
        val original = lyrics.substring(start, end)
        if (original.isBlank()) {
            clearPendingRewriteSelection()
            return
        }

        rewriteRejectedCandidates = emptySet()
        beginRewrite(action, TextRange(start, end), original)
    }

    fun retryRewrite() {
        val action = rewriteAction ?: return
        val range = rewriteRange ?: return
        val original = rewriteOriginal ?: return
        val rejectedPreview = rewritePreview?.let { setOf(it) }.orEmpty()
        beginRewrite(action, range, original, rejectedPreview)
    }

    private fun beginRewrite(
        action: RewriteAction,
        range: TextRange,
        original: String,
        rejectedCandidates: Set<String> = emptySet()
    ) {
        rewriteRevision++
        rewriteJob?.cancel()
        pendingRewriteRange = null
        rewriteAction = action
        rewriteOriginal = original
        rewriteRange = range
        rewriteRejectedCandidates = rewriteRejectedCandidates + rejectedCandidates + original
        rewritePreview = null
        rewriteError = null
        rewriteLoading = false
        if (selectedProvider == AIProvider.LOCAL && !localReady) {
            rewriteError = if (localModelLoading) "Wait for your local model to finish loading." else "Choose a local model in Settings to rewrite."
            return
        }
        if (!authorizeCloudAI("rewrite") { beginRewrite(action, range, original, rejectedCandidates) }) return
        rewriteLoading = true
        val revision = rewriteRevision
        val requestContext = editorAIContext()
        val provider = selectedProvider
        val modelId = selectedModel.id
        val wholeSong = useWholeSongContext
        val fullLyrics = lyrics
        val currentSection = currentSongSection(fullLyrics, range.min)
        val rejectedForRequest = rewriteRejectedCandidates

        rewriteJob = viewModelScope.launch {
            try {
                val key = resolveApiKey(provider)
                if (revision != rewriteRevision || !isCurrentAIContext(requestContext)) return@launch
                val result = aiService.getRewrite(
                    provider = provider,
                    apiKey = key,
                    modelId = modelId,
                    action = action,
                    fullLyrics = if (provider == AIProvider.LOCAL || wholeSong) fullLyrics else original,
                    selection = original,
                    currentSection = currentSection,
                    selectionStart = if (provider == AIProvider.LOCAL || wholeSong) range.min else 0,
                    rejectedCandidates = rejectedForRequest,
                    useWholeSongContext = wholeSong
                )
                if (revision == rewriteRevision && isCurrentAIContext(requestContext)) rewritePreview = result
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (revision == rewriteRevision && isCurrentAIContext(requestContext)) rewriteError = e.message ?: "Rewrite failed"
            } finally {
                if (revision == rewriteRevision) rewriteLoading = false
            }
        }
    }

    fun seedRewritePreviewForTesting(action: RewriteAction, range: TextRange, original: String, preview: String) {
        seedRewriteStateForTesting(
            action = action,
            range = range,
            original = original,
            preview = preview,
            error = null,
            loading = false,
            debugMessage = "Rewrite preview seeding is only available in debug builds."
        )
    }

    fun seedEditorForTesting(title: String, lyrics: String, selection: TextRange = TextRange.Zero) {
        check(BuildConfig.DEBUG) { "Editor test seeding is only available in debug builds." }
        autoSaveJob?.cancel()
        dismissRewrite()
        this.title = title
        lyricsFieldValue = TextFieldValue(lyrics, selection)
        theme = ""
        currentProjectId = null
        restoreEditorPosition()
        suggestions = emptyList()
        _analysisPresentation = AnalysisPresentation.INK_MARKS
        isSyllableColoringEnabled = true
        isRhymeHighlightEnabled = true
        saveStatus = SaveStatus.SAVED
        showStartMenu = false
        resetLyricsHistory()
    }

    fun seedRewriteErrorForTesting(action: RewriteAction, range: TextRange, original: String, error: String) {
        seedRewriteStateForTesting(
            action = action,
            range = range,
            original = original,
            preview = null,
            error = error,
            loading = false,
            debugMessage = "Rewrite error seeding is only available in debug builds."
        )
    }

    fun seedRewriteLoadingForTesting(action: RewriteAction, range: TextRange, original: String) {
        seedRewriteStateForTesting(
            action = action,
            range = range,
            original = original,
            preview = null,
            error = null,
            loading = true,
            debugMessage = "Rewrite loading seeding is only available in debug builds."
        )
    }

    private fun seedRewriteStateForTesting(
        action: RewriteAction,
        range: TextRange,
        original: String,
        preview: String?,
        error: String?,
        loading: Boolean,
        debugMessage: String
    ) {
        check(BuildConfig.DEBUG) { debugMessage }
        rewriteJob?.cancel()
        pendingRewriteRange = null
        rewriteAction = action
        rewriteOriginal = original
        rewriteRange = range
        rewriteRejectedCandidates = setOf(original)
        rewritePreview = preview
        rewriteError = error
        rewriteLoading = loading
    }

    fun applyRewrite() {
        val preview = rewritePreview ?: return
        val range = rewriteRange ?: return
        val text = lyrics
        // TextRange.start/end follow selection direction; min/max are the safe bounds.
        if (range.min < 0 || range.max > text.length) {
            dismissRewrite()
            return
        }
        if (rewriteOriginal != null && text.substring(range.min, range.max) != rewriteOriginal) {
            dismissRewrite()
            return
        }
        val before = text.substring(0, range.min)
        val after = text.substring(range.max)
        val newText = before + preview + after
        val newCursor = (range.min + preview.length).coerceAtMost(newText.length)
        applyAtomicLyricsEdit(TextFieldValue(newText, TextRange(newCursor)))
        dismissRewrite()
        triggerAutoSave()
    }

    fun dismissRewrite() {
        rewriteRevision++
        if (cloudAISharingRequest?.purpose == "rewrite") cancelCloudAISharing()
        rewriteJob?.cancel()
        rewriteJob = null
        pendingRewriteRange = null
        rewriteAction = null
        rewriteLoading = false
        rewritePreview = null
        rewriteOriginal = null
        rewriteError = null
        rewriteRange = null
        rewriteRejectedCandidates = emptySet()
    }

    fun cancelRewriteReview() {
        val rangeToRestore = rewriteRange
        dismissRewrite()
        if (rangeToRestore != null &&
            rangeToRestore.min < rangeToRestore.max &&
            rangeToRestore.max <= lyrics.length
        ) {
            pendingRewriteRange = rangeToRestore
        }
    }

    fun openInspectorForSelection() {
        val (word, range) = singleWordSelection ?: return
        openInspector(word, range)
    }

    fun openInspector(word: String, range: TextRange) {
        inspectorSynonymsJob?.cancel()
        inspectorWord = word
        inspectorRange = range
        inspectorSynonyms = emptyList()
        inspectorSynonymsError = null

        val inspectorContext = editorAIContext()
        viewModelScope.launch {
            val prosodyResult = withContext(Dispatchers.IO) { ProsodyAnalyzer.analyzeWord(word) }
            val matchesResult = withContext(Dispatchers.IO) { ProsodyAnalyzer.findRhymes(word) }
            if (isCurrentAIContext(inspectorContext)) {
                inspectorProsody = prosodyResult
                inspectorMatches = matchesResult
            }
        }

        fetchInspectorSynonyms(word, range)
    }

    fun retryInspectorSynonyms() {
        val word = inspectorWord ?: return
        val range = inspectorRange ?: return
        fetchInspectorSynonyms(word, range)
    }

    private fun fetchInspectorSynonyms(word: String, range: TextRange) {
        synonymsRevision++
        inspectorSynonymsJob?.cancel()
        inspectorSynonymsError = null
        inspectorSynonymsLoading = false
        if (!authorizeCloudAI("synonyms") { fetchInspectorSynonyms(word, range) }) return
        inspectorSynonymsLoading = true
        val revision = synonymsRevision
        val requestContext = editorAIContext()
        val provider = selectedProvider
        val modelId = selectedModel.id
        val lineContext = currentLineForRange(range)
        inspectorSynonymsJob = viewModelScope.launch {
            try {
                val key = resolveApiKey(provider)
                if (revision != synonymsRevision || !isCurrentAIContext(requestContext)) return@launch
                val results = aiService.getSynonyms(
                    provider = provider,
                    apiKey = key,
                    modelId = modelId,
                    word = word,
                    lineContext = lineContext
                )
                if (revision == synonymsRevision && isCurrentAIContext(requestContext)) inspectorSynonyms = results
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (revision == synonymsRevision && isCurrentAIContext(requestContext)) inspectorSynonymsError = e.message ?: "Failed to load synonyms"
            } finally {
                if (revision == synonymsRevision) inspectorSynonymsLoading = false
            }
        }
    }

    private fun currentLineForRange(range: TextRange): String {
        val text = lyrics
        val start = range.min.coerceIn(0, text.length)
        val end = range.max.coerceIn(0, text.length)
        val lineStart = text.lastIndexOf('\n', (start - 1).coerceAtLeast(0)).let { if (it < 0) 0 else it + 1 }
        val newlineAfter = text.indexOf('\n', end)
        val lineEnd = if (newlineAfter < 0) text.length else newlineAfter
        return text.substring(lineStart, lineEnd).trim()
    }

    fun applyInspectorReplacement(replacement: String) {
        val range = inspectorRange ?: return
        val text = lyrics
        if (range.min < 0 || range.max > text.length) {
            dismissInspector()
            return
        }
        val newText = text.replaceRange(range.min, range.max, replacement)
        val newCursor = (range.min + replacement.length).coerceAtMost(newText.length)
        applyAtomicLyricsEdit(TextFieldValue(newText, TextRange(newCursor)))
        dismissInspector()
        triggerAutoSave()
    }

    fun dismissInspector() {
        synonymsRevision++
        if (cloudAISharingRequest?.purpose == "synonyms") cancelCloudAISharing()
        inspectorSynonymsJob?.cancel()
        inspectorSynonymsJob = null
        inspectorWord = null
        inspectorRange = null
        inspectorProsody = null
        inspectorMatches = null
        inspectorSynonyms = emptyList()
        inspectorSynonymsLoading = false
        inspectorSynonymsError = null
        pendingRewriteRange = null
    }

    fun insertSuggestion(suggestion: String) {
        val pos = cursorPosition
        val text = lyrics
        val before = text.substring(0, pos)
        val after = text.substring(pos)
        val needsNewline = before.isNotEmpty() && !before.endsWith("\n")
        val insertText = (if (needsNewline) "\n" else "") + suggestion + "\n"
        val newText = before + insertText + after
        val newPos = pos + insertText.length
        applyAtomicLyricsEdit(TextFieldValue(newText, TextRange(newPos)))
        suggestionInsertion = SuggestionInsertion(
            id = ++suggestionInsertionRevision,
            range = TextRange(pos + if (needsNewline) 1 else 0, newPos - 1),
            lyrics = newText
        )
        suggestions = emptyList()
        triggerAutoSave()
    }

    fun dismissSuggestionInsertion(id: Long) {
        if (suggestionInsertion?.id == id) suggestionInsertion = null
    }

    fun undoSuggestionInsertion(id: Long) {
        val insertion = suggestionInsertion ?: return
        if (insertion.id != id || insertion.lyrics != lyrics) return
        undoLyrics()
    }

    fun insertSection(label: String) {
        val insertion = SectionMap.insertHeader(lyrics, cursorPosition, label)
        pendingRewriteRange = null
        applyAtomicLyricsEdit(
            TextFieldValue(
                text = insertion.text,
                selection = TextRange(insertion.cursor)
            )
        )
        suggestions = emptyList()
        triggerAutoSave()
    }

    fun newProject(onReady: () -> Unit = {}) {
        flushCurrentDraft {
            autoSaveJob?.cancel()
            dismissRewrite()
            title = ""
            lyricsFieldValue = TextFieldValue("")
            theme = ""
            currentProjectId = null
            restoreEditorPosition()
            suggestions = emptyList()
            showProjectsDialog = false
            showStartMenu = false
            resetLyricsHistory()
            viewModelScope.launch {
                repo.saveActiveState(projects, null, "", "", "")
            }

            onReady()
        }
    }

    fun loadProject(requestedProject: SongProject, onReady: () -> Unit = {}) {
        flushCurrentDraft {
            val project = projects.firstOrNull { it.id == requestedProject.id } ?: requestedProject
            autoSaveJob?.cancel()
            dismissRewrite()
            title = project.title
            lyricsFieldValue = TextFieldValue(project.lyrics)
            theme = project.theme
            currentProjectId = project.id
            restoreEditorPosition()
            suggestions = emptyList()
            showProjectsDialog = false
            showStartMenu = false
            resetLyricsHistory()
            viewModelScope.launch {
                repo.saveActiveState(projects, project.id, project.title, project.lyrics, project.theme)
            }

            onReady()
        }
    }

    fun moveProjectToTrash(id: String) {
        if (restoringDraft || savingBeforeNavigation) return
        if (currentProjectId == id) { flushCurrentDraft { moveSavedProjectToTrash(id) }; return }
        moveSavedProjectToTrash(id)
    }

    private fun moveSavedProjectToTrash(id: String) {
        val project = projects.firstOrNull { it.id == id } ?: return
        val now = System.currentTimeMillis()
        val wasCurrentProject = currentProjectId == id
        autoSaveJob?.cancel()

        val updatedProjects = projects.filter { it.id != id }
        val updatedTrashedProjects = listOf(
            TrashedSongProject(
                project = project,
                deletedAt = now,
                deleteAfter = now + TRASH_RETENTION_MILLIS
            )
        ) + trashedProjects.filter { it.project.id != id }
        projects = updatedProjects
        trashedProjects = updatedTrashedProjects

        if (wasCurrentProject) {
            clearEditorAfterProjectDelete()
        }

        viewModelScope.launch {
            repo.saveProjects(updatedProjects)
            repo.saveTrashedProjects(updatedTrashedProjects)
            if (wasCurrentProject) {
                repo.setCurrentProjectId(null)
                repo.saveEditorState("", "", "")
            }
        }
        scheduleTrashPurge()
    }

    fun restoreTrashedProject(id: String) {
        val trashedProject = trashedProjects.firstOrNull { it.project.id == id } ?: return
        val restoredProject = trashedProject.project.copy(updatedAt = System.currentTimeMillis())
        val updatedTrashedProjects = trashedProjects.filter { it.project.id != id }
        val updatedProjects = listOf(restoredProject) + projects.filter { it.id != id }
        trashedProjects = updatedTrashedProjects
        projects = updatedProjects
        viewModelScope.launch {
            repo.saveProjects(updatedProjects)
            repo.saveTrashedProjects(updatedTrashedProjects)
        }
        scheduleTrashPurge()
    }

    fun permanentlyDeleteTrashedProject(id: String) {
        if (restoringDraft || savingBeforeNavigation) return
        val updatedTrashedProjects = trashedProjects.filter { it.project.id != id }
        trashedProjects = updatedTrashedProjects
        workspaces = workspaces - id
        viewModelScope.launch {
            repo.saveTrashedProjects(updatedTrashedProjects)
            // Remove any recorded memos that belonged to this project.
            if (notebookError == null) try { repo.saveWorkspace(id, null) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { notebookError = "Song Notebook could not be updated." }
            voiceMemoService.deleteMemoDirectory(id)
        }
        scheduleTrashPurge()
    }

    fun purgeExpiredTrashedProjects() {
        if (restoringDraft) return
        val now = System.currentTimeMillis()
        val retainedProjects = trashedProjects.filter { it.deleteAfter > now }
        if (retainedProjects.size != trashedProjects.size) {
            val purgedIds = trashedProjects
                .filter { it.deleteAfter <= now }
                .map { it.project.id }
            workspaces = workspaces - purgedIds.toSet()
            trashedProjects = retainedProjects
            viewModelScope.launch {
                repo.saveTrashedProjects(retainedProjects)
                // Purge memo directories for each project that was permanently removed.
                purgedIds.forEach {
                    if (notebookError == null) try { repo.saveWorkspace(it, null) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { notebookError = "Song Notebook could not be updated." }
                    voiceMemoService.deleteMemoDirectory(it)
                }
            }
        }
        viewModelScope.launch {
            voiceMemoService.purgeExpiredTrashedMemos(now)
        }
        scheduleTrashPurge()
    }

    private fun scheduleTrashPurge() {
        trashSchedulerJob?.cancel()
        trashSchedulerJob = viewModelScope.launch {
            val now = System.currentTimeMillis()
            val nextProjectExpiry = trashedProjects
                .filter { it.deleteAfter > now }
                .minOfOrNull { it.deleteAfter }
            // Trashed recordings expire on their own clock; wake for whichever
            // comes first. Already-expired recordings are being purged by the
            // launch in purgeExpiredTrashedProjects, so only future expiries count.
            val nextMemoExpiry = voiceMemoService.nextTrashedMemoExpiry()?.takeIf { it > now }
            val nextDeleteAfter = listOfNotNull(nextProjectExpiry, nextMemoExpiry).minOrNull()
                ?: return@launch
            delay((nextDeleteAfter - now).coerceAtLeast(0L))
            trashSchedulerJob = null
            purgeExpiredTrashedProjects()
        }
    }

    private fun clearEditorAfterProjectDelete() {
        autoSaveJob?.cancel()
        dismissRewrite()
        title = ""
        lyricsFieldValue = TextFieldValue("")
        theme = ""
        currentProjectId = null
        restoreEditorPosition()
        suggestions = emptyList()
        errorMessage = null
        saveStatus = SaveStatus.IDLE
        resetLyricsHistory()
    }

    fun importProject(imported: SongProject, onReady: () -> Unit = {}) {
        flushCurrentDraft {
            dismissRewrite()
            val newId = java.util.UUID.randomUUID().toString()
            val project = imported.copy(
                id = newId,
                title = imported.title.ifBlank { "Imported Song" },
                updatedAt = System.currentTimeMillis()
            )
            projects = listOf(project) + projects
            title = project.title
            lyricsFieldValue = TextFieldValue(project.lyrics)
            theme = project.theme
            currentProjectId = project.id
            restoreEditorPosition()
            suggestions = emptyList()
            showProjectsDialog = false
            showStartMenu = false
            resetLyricsHistory()
            viewModelScope.launch {
                persistActiveProjectSnapshot(
                    projectId = project.id,
                    projectList = projects,
                    editorTitle = project.title,
                    editorLyrics = project.lyrics,
                    editorTheme = project.theme
                )
            }

            onReady()
        }
    }

    fun snapshotCurrentForExport(): SongProject {
        return SongProject(
            id = currentProjectId ?: java.util.UUID.randomUUID().toString(),
            title = title.ifBlank { "Untitled Song" },
            lyrics = lyrics,
            theme = theme,
            updatedAt = System.currentTimeMillis()
        )
    }

    private fun createUntitledProjectSnapshot(): SongProject {
        return createUntitledProjectSnapshot(
            title = title,
            lyrics = lyrics,
            theme = theme
        )
    }

    private fun createUntitledProjectSnapshot(
        title: String,
        lyrics: String,
        theme: String,
        id: String = java.util.UUID.randomUUID().toString(),
        updatedAt: Long = System.currentTimeMillis()
    ): SongProject {
        return SongProject(
            id = id,
            title = title.ifEmpty { "Untitled Song" },
            lyrics = lyrics,
            theme = theme,
            updatedAt = updatedAt
        )
    }

    private suspend fun persistActiveProjectSnapshot(
        projectId: String,
        projectList: List<SongProject>,
        editorTitle: String,
        editorLyrics: String,
        editorTheme: String
    ) {
        repo.saveActiveState(projectList, projectId, editorTitle, editorLyrics, editorTheme)
    }

    fun applyTemplate(name: String, templateTheme: String, templateLyrics: String, onReady: () -> Unit = {}) {
        flushCurrentDraft {
            dismissRewrite()
            title = "Untitled $name"
            theme = templateTheme
            lyricsFieldValue = TextFieldValue(templateLyrics)
            currentProjectId = null
            restoreEditorPosition()
            showTemplatesDialog = false
            showStartMenu = false
            resetLyricsHistory()
            triggerAutoSave()

            onReady()
        }
    }

    private fun reserveProjectIdentity(): String = currentProjectId ?: createUntitledProjectSnapshot().let { project ->
        projects = listOf(project) + projects
        currentProjectId = project.id
        showStartMenu = false
        project.id
    }

    private fun ensureProjectForNotebook(): String {
        currentProjectId?.let { return it }
        val projectId = reserveProjectIdentity()
        val savedProjects = projects
        val savedTitle = title
        val savedLyrics = lyrics
        val savedTheme = theme
        viewModelScope.launch {
            persistActiveProjectSnapshot(projectId, savedProjects, savedTitle, savedLyrics, savedTheme)
        }
        return projectId
    }

    // Reserve identity before suspending so edits keep the same autosave target.
    // Persist retries too: a failed save must not admit an orphaned recording.
    suspend fun ensureProjectForRecording(): String {
        val projectId = reserveProjectIdentity()
        repo.saveActiveState(projects, projectId, title, lyrics, theme)
        if (currentProjectId != projectId) throw CancellationException("Song changed")
        return projectId
    }

    fun triggerAutoSave() {
        autoSaveJob?.cancel()
        autoSaveJob = viewModelScope.launch {
            val currentTitle = title
            val currentLyrics = lyrics
            val currentTheme = theme
            val projectIdAtTrigger = currentProjectId

            if (currentTitle.isEmpty() && currentLyrics.isEmpty() && currentTheme.isEmpty()) {
                saveStatus = SaveStatus.IDLE
                return@launch
            }

            delay(AUTOSAVE_DEBOUNCE_MILLIS)

            // The editor switched projects (or this one was trashed) during the
            // debounce; saving the stale snapshot now would clobber the newly
            // loaded project or resurrect a deleted one.
            if (currentProjectId != projectIdAtTrigger) return@launch
            if (projectIdAtTrigger != null && projects.none { it.id == projectIdAtTrigger }) return@launch

            saveStatus = SaveStatus.SAVING
            try {
                val updatedProjectId: String
                val updatedProjects = if (projectIdAtTrigger == null) {
                    val newProject = createUntitledProjectSnapshot(
                        title = currentTitle,
                        lyrics = currentLyrics,
                        theme = currentTheme
                    )
                    updatedProjectId = newProject.id
                    listOf(newProject) + projects
                } else {
                    updatedProjectId = projectIdAtTrigger
                    projects.map {
                        if (it.id == projectIdAtTrigger) it.copy(
                            title = currentTitle.ifEmpty { "Untitled Song" },
                            lyrics = currentLyrics,
                            theme = currentTheme,
                            updatedAt = System.currentTimeMillis()
                        ) else it
                    }
                }

                projects.firstOrNull { it.id == updatedProjectId }?.let { previous ->
                    if (previous.lyrics != currentLyrics || previous.title != currentTitle || previous.theme != currentTheme) {
                        updateWorkspace(updatedProjectId) { it.checkpoint(previous.title, previous.lyrics, previous.theme, System.currentTimeMillis(), force = false) }
                    }
                }
                projects = updatedProjects
                currentProjectId = updatedProjectId
                rememberEditorPosition()

                persistActiveProjectSnapshot(
                    projectId = updatedProjectId,
                    projectList = updatedProjects,
                    editorTitle = currentTitle,
                    editorLyrics = currentLyrics,
                    editorTheme = currentTheme
                )

                delay(SAVE_STATUS_VISIBLE_MILLIS)
                saveStatus = SaveStatus.SAVED
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                persistenceError = "Your draft could not be saved. It is still open. Free up storage and try again."
            } finally {
                // Cancellation mid-save would otherwise leave the indicator stuck on SAVING.
                if (saveStatus == SaveStatus.SAVING) saveStatus = SaveStatus.IDLE
            }
        }
    }

    fun onTitleChanged(newTitle: String) {
        cancelEditorAIWork()
        title = newTitle
        triggerAutoSave()
    }

    fun onLyricsChanged(
        newValue: TextFieldValue,
        timestampMilliseconds: Long = android.os.SystemClock.uptimeMillis()
    ) {
        if (hasActiveRewrite) return
        val previousText = lyricsFieldValue.text
        val nextValue = newValue.withValidRanges()
        if (nextValue.text != previousText || nextValue.selection != lyricsFieldValue.selection) cancelEditorAIWork()
        if (nextValue.text != previousText) {
            suggestionInsertion = null
            pendingRewriteRange = null
            lyricsHistory.recordUserEdit(
                previous = lyricsFieldValue,
                current = nextValue,
                timestampMilliseconds = timestampMilliseconds
            )
            lyricsFieldValue = nextValue
            updateLyricsHistoryAvailability()
            triggerAutoSave()
            return
        }

        val nextSelection = nextValue.selection
        if (!nextSelection.collapsed) {
            val start = nextSelection.min.coerceIn(0, nextValue.text.length)
            val end = nextSelection.max.coerceIn(0, nextValue.text.length)
            val selectedText = nextValue.text.substring(start, end)
            pendingRewriteRange = if (start < end && selectedText.isNotBlank()) {
                TextRange(start, end)
            } else {
                null
            }
            lyricsFieldValue = nextValue
            rememberEditorPosition()
            return
        }

        pendingRewriteRange?.let { pendingRange ->
            if (nextSelection.start != pendingRange.min && nextSelection.start != pendingRange.max) {
                pendingRewriteRange = null
            }
        }
        lyricsFieldValue = nextValue
        rememberEditorPosition()
    }

    fun undoLyrics() {
        val previous = lyricsHistory.undo(lyricsFieldValue) ?: return
        applyHistoryState(previous)
    }

    fun redoLyrics() {
        val next = lyricsHistory.redo(lyricsFieldValue) ?: return
        applyHistoryState(next)
    }

    private fun applyAtomicLyricsEdit(nextValue: TextFieldValue) {
        cancelEditorAIWork()
        suggestionInsertion = null
        val safeValue = nextValue.withValidRanges()
        lyricsHistory.recordAtomicEdit(previous = lyricsFieldValue, current = safeValue)
        lyricsFieldValue = safeValue
        updateLyricsHistoryAvailability()
    }

    private fun applyHistoryState(state: TextFieldValue) {
        cancelEditorAIWork()
        suggestionInsertion = null
        dismissRewrite()
        dismissInspector()
        lyricsFieldValue = state.withValidRanges()
        suggestions = emptyList()
        updateLyricsHistoryAvailability()
        triggerAutoSave()
    }

    private fun resetLyricsHistory() {
        cancelEditorAIWork()
        suggestionInsertion = null
        lyricsHistory.reset()
        updateLyricsHistoryAvailability()
    }

    private fun updateLyricsHistoryAvailability() {
        canUndoLyrics = lyricsHistory.canUndo
        canRedoLyrics = lyricsHistory.canRedo
    }

    fun clearPendingRewriteSelection() {
        pendingRewriteRange = null
        val selection = lyricsFieldValue.selection
        if (!selection.collapsed) {
            lyricsFieldValue = lyricsFieldValue.copy(selection = TextRange(selection.max))
        }
    }

    fun onThemeChanged(newTheme: String) {
        cancelEditorAIWork()
        theme = newTheme
        triggerAutoSave()
    }

    fun goToStartMenu(onReady: () -> Unit = {}) {
        flushCurrentDraft { suggestionInsertion = null; showStartMenu = true; onReady() }
    }

    private fun TextFieldValue.withValidRanges(): TextFieldValue {
        val textLength = text.length
        val safeSelection = TextRange(
            selection.start.coerceIn(0, textLength),
            selection.end.coerceIn(0, textLength)
        )
        val safeComposition = composition?.let { range ->
            TextRange(
                range.start.coerceIn(0, textLength),
                range.end.coerceIn(0, textLength)
            )
        }
        return if (safeSelection == selection && safeComposition == composition) {
            this
        } else {
            copy(selection = safeSelection, composition = safeComposition)
        }
    }

    fun saveApiKey(provider: AIProvider, key: String) {
        cancelEditorAIWork()
        apiKeyPresence = apiKeyPresence + (provider.name to key.isNotEmpty())
        viewModelScope.launch {
            repo.saveApiKey(provider.name, key)
            cancelEditorAIWork()
        }
    }

    suspend fun applyAISettings(
        provider: AIProvider,
        model: AIModel,
        keys: Map<AIProvider, String>
    ): Result<Unit> {
        cancelEditorAIWork()
        return try {
            withContext(Dispatchers.IO) {
                keys.forEach { (keyProvider, key) -> repo.saveApiKey(keyProvider.name, key) }
                repo.saveSelectedProvider(provider.name)
                repo.saveModelId(model.id)
            }
            cancelEditorAIWork()
            selectedProvider = provider
            selectedModel = model
            apiKeyPresence = apiKeyPresence + keys
                .mapKeys { it.key.name }
                .mapValues { it.value.isNotEmpty() }
            Result.success(Unit)
        } catch (cancellation: kotlinx.coroutines.CancellationException) {
            throw cancellation
        } catch (error: Exception) {
            Result.failure(error)
        }
    }

    fun saveProvider(provider: AIProvider) {
        selectedProvider = provider
        // Auto-select first model for this provider
        val models = AIModel.modelsForProvider(provider)
        if (selectedModel.provider != provider && models.isNotEmpty()) {
            selectedModel = models.first()
        }
        val modelId = selectedModel.id
        viewModelScope.launch {
            repo.saveSelectedProvider(provider.name)
            repo.saveModelId(modelId)
        }
    }

    override fun onCleared() {
        try {
            localModelService.close()
        } finally {
            voiceMemoService.release()
            super.onCleared()
        }
    }

    fun saveModel(model: AIModel) {
        selectedModel = model
        viewModelScope.launch {
            repo.saveModelId(model.id)
        }
    }

    private suspend fun restoreSavedLocalModels() {
        val filesDir = getApplication<Application>().filesDir
        val storedModels = try {
            repo.localModelsFlow.first()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: CorruptLibraryException) {
            localModelError = "Saved local models could not be read. Existing files were left untouched."
            return
        }
        val verifiedCatalogFiles = mutableSetOf<String>()
        val persisted = withContext(Dispatchers.IO) {
            storedModels.mapNotNull { model ->
                val file = java.io.File(filesDir, model.fileName)
                if (!file.isFile) return@mapNotNull null
                if (model.isCustom) return@mapNotNull model
                val catalogModel = com.rhymeai.app.ui.components.GEMMA_DOWNLOADS
                    .firstOrNull { it.fileName == model.fileName }
                    ?: return@mapNotNull null
                val hasCurrentVerification = com.rhymeai.app.ui.components.hasCurrentGemmaVerification(
                    model = catalogModel,
                    file = file,
                    verifiedCatalogSha256 = model.verifiedCatalogSha256,
                    verifiedSizeBytes = model.verifiedSizeBytes,
                    verifiedLastModifiedMillis = model.verifiedLastModifiedMillis
                )
                if (!hasCurrentVerification && com.rhymeai.app.ui.components
                        .validateDownloadedGemmaIntegrity(catalogModel, file) != null
                ) {
                    return@mapNotNull null
                }
                verifiedCatalogFiles += model.fileName
                model.copy(
                    verifiedCatalogSha256 = catalogModel.sha256,
                    verifiedSizeBytes = file.length(),
                    verifiedLastModifiedMillis = file.lastModified().takeIf { it > 0L }
                )
            }.toMutableList()
        }
        val legacyFile = java.io.File(filesDir, "local_model.gguf")
        if (legacyFile.isFile && persisted.none { it.fileName == legacyFile.name }) {
            persisted += SavedLocalModel(
                id = legacyFile.name,
                displayName = "Custom Model",
                fileName = legacyFile.name,
                isCustom = true
            )
        }
        savedLocalModels = persisted
        verifiedGemmaFileNames = verifiedCatalogFiles
        if (persisted != storedModels) {
            repo.saveLocalModels(persisted)
        }
        selectedLocalModelId = repo.selectedLocalModelIdFlow.first()
            ?.takeIf { selectedId -> persisted.any { it.id == selectedId } }
            ?: persisted.firstOrNull()?.id
        repo.saveSelectedLocalModelId(selectedLocalModelId)
        if (selectedProvider == AIProvider.LOCAL) {
            selectedSavedLocalModel()?.let { model ->
                loadLocalModel(java.io.File(filesDir, model.fileName).absolutePath)
            }
        }
    }

    fun registerAndSelectLocalModel(
        path: String,
        displayName: String,
        isCustom: Boolean,
        verifiedCatalogSha256: String? = null
    ) {
        val file = java.io.File(path)
        val model = SavedLocalModel(
            id = file.name,
            displayName = displayName.ifBlank { file.nameWithoutExtension },
            fileName = file.name,
            isCustom = isCustom,
            verifiedCatalogSha256 = verifiedCatalogSha256,
            verifiedSizeBytes = file.length().takeIf { verifiedCatalogSha256 != null },
            verifiedLastModifiedMillis = file.lastModified().takeIf {
                verifiedCatalogSha256 != null && it > 0L
            }
        )
        savedLocalModels = (savedLocalModels.filterNot { it.id == model.id } + model)
            .sortedBy { it.displayName.lowercase() }
        selectedLocalModelId = model.id
        viewModelScope.launch {
            repo.saveLocalModels(savedLocalModels)
            repo.saveSelectedLocalModelId(model.id)
        }
        saveProvider(AIProvider.LOCAL)
        saveModel(AIModel.LOCAL_MODEL)
        loadLocalModel(file.absolutePath)
    }

    fun selectSavedLocalModel(modelId: String) {
        val model = savedLocalModels.firstOrNull { it.id == modelId } ?: return
        val ticket = beginLocalModelChange()
        val generation = localModelValidationGeneration
        val file = java.io.File(getApplication<Application>().filesDir, model.fileName)
        localModelPath = file.absolutePath
        if (!file.isFile) {
            rejectSavedLocalModel(ticket, "Saved model file is missing. Import it again.")
            return
        }
        if (!model.isCustom) {
            val catalogModel = com.rhymeai.app.ui.components.GEMMA_DOWNLOADS
                .firstOrNull { it.fileName == model.fileName }
            localModelLoading = true
            localModelError = null
            localModelValidationJob = viewModelScope.launch {
                var startedLoad = false
                try {
                    val validationError = withContext(Dispatchers.IO) {
                        if (catalogModel == null) {
                            "Saved downloaded model is not in the trusted catalog."
                        } else {
                            com.rhymeai.app.ui.components.validateDownloadedGemmaIntegrity(catalogModel, file)
                        }
                    }
                    if (generation != localModelValidationGeneration) return@launch
                    if (validationError != null) {
                        verifiedGemmaFileNames -= model.fileName
                        startedLoad = true
                        rejectSavedLocalModel(ticket, validationError)
                    } else {
                        verifiedGemmaFileNames += model.fileName
                        startedLoad = true
                        selectValidatedLocalModel(model, file, ticket)
                    }
                } finally {
                    if (generation == localModelValidationGeneration && !startedLoad) {
                        localModelLoading = false
                    }
                }
            }
            return
        }
        selectValidatedLocalModel(model, file, ticket)
    }

    private fun selectValidatedLocalModel(
        model: SavedLocalModel,
        file: java.io.File,
        ticket: LocalModelOperationGate.Ticket
    ) {
        selectedLocalModelId = model.id
        viewModelScope.launch { repo.saveSelectedLocalModelId(model.id) }
        saveProvider(AIProvider.LOCAL)
        saveModel(AIModel.LOCAL_MODEL)
        startLocalModelLoad(file.absolutePath, ticket)
    }

    private fun rejectSavedLocalModel(ticket: LocalModelOperationGate.Ticket, message: String) {
        localModelError = message
        localModelOperations.launch(
            viewModelScope, ticket, { localModelService.unload() },
            onSuccess = {},
            onFailure = { error -> localModelError = error.message ?: message },
            onFinished = { localModelLoading = false }
        )
    }

    private fun selectedSavedLocalModel(): SavedLocalModel? =
        savedLocalModels.firstOrNull { it.id == selectedLocalModelId }

    private fun corruptLibraryMessage(error: CorruptLibraryException): String =
        "Your ${error.area} could not be read. Existing data was left untouched. Restore a backup before editing."

    // ── Gemma download — lives here (not in Settings' composable scope) so a
    // multi-gigabyte download survives leaving the screen. Resume support in
    // downloadGemmaToTemp means an app restart continues where it stopped. ──
    internal var gemmaDownloadingModel by mutableStateOf<com.rhymeai.app.ui.components.GemmaDownload?>(null)
        private set
    var gemmaDownloadProgress by mutableStateOf<Float?>(null)
        private set
    var gemmaDownloadVerifying by mutableStateOf(false)
        private set
    var gemmaDownloadError by mutableStateOf<String?>(null)
    internal var gemmaLastDownloadAttempt by mutableStateOf<com.rhymeai.app.ui.components.GemmaDownload?>(null)
        private set
    var gemmaDownloadRevision by mutableStateOf(0)
        private set
    var verifiedGemmaFileNames by mutableStateOf<Set<String>>(emptySet())
        private set

    internal suspend fun useDownloadedGemma(model: com.rhymeai.app.ui.components.GemmaDownload): Boolean {
        val destFile = java.io.File(getApplication<android.app.Application>().filesDir, model.fileName)
        val validationError = withContext(Dispatchers.IO) {
            com.rhymeai.app.ui.components.validateDownloadedGemmaIntegrity(model, destFile)
        }
        if (validationError != null) {
            gemmaDownloadError = validationError
            verifiedGemmaFileNames -= model.fileName
            return false
        }
        verifiedGemmaFileNames += model.fileName
        registerAndSelectLocalModel(
            path = destFile.absolutePath,
            displayName = model.label,
            isCustom = false,
            verifiedCatalogSha256 = model.sha256
        )
        return true
    }

    internal fun startGemmaDownload(model: com.rhymeai.app.ui.components.GemmaDownload) {
        if (gemmaDownloadingModel != null) return
        gemmaDownloadingModel = model
        gemmaDownloadProgress = 0f
        gemmaDownloadVerifying = false
        gemmaDownloadError = null
        gemmaLastDownloadAttempt = model
        val app = getApplication<android.app.Application>()

        viewModelScope.launch(Dispatchers.IO) {
            val destFile = java.io.File(app.filesDir, model.fileName)
            val tempFile = java.io.File(app.cacheDir, "${model.fileName}.download")
            try {
                if (com.rhymeai.app.ui.components.validateDownloadedGemmaIntegrity(model, destFile) == null) {
                    withContext(Dispatchers.Main) {
                        gemmaDownloadingModel = null
                        gemmaDownloadProgress = null
                        gemmaDownloadVerifying = false
                        useDownloadedGemma(model)
                    }
                    return@launch
                }

                com.rhymeai.app.ui.components.ensureEnoughSpaceForGemma(model, destFile, tempFile)
                com.rhymeai.app.ui.components.downloadGemmaAndInstall(
                    model = model,
                    tempFile = tempFile,
                    destinationFile = destFile,
                    onProgress = { progress ->
                        withContext(Dispatchers.Main) {
                            gemmaDownloadProgress = progress
                        }
                    },
                    onVerifying = {
                        withContext(Dispatchers.Main) {
                            gemmaDownloadVerifying = true
                        }
                    }
                )

                withContext(Dispatchers.Main) {
                    gemmaDownloadingModel = null
                    gemmaDownloadProgress = null
                    gemmaDownloadVerifying = false
                    gemmaDownloadRevision++
                    useDownloadedGemma(model)
                }
            } catch (e: Exception) {
                android.util.Log.w("RhymeAI", "Gemma download failed", e)
                withContext(Dispatchers.Main) {
                    gemmaDownloadingModel = null
                    gemmaDownloadProgress = null
                    gemmaDownloadVerifying = false
                    gemmaDownloadError = "Failed to download ${model.label}: ${e.message}"
                }
            }
        }
    }

    fun loadLocalModel(path: String) {
        startLocalModelLoad(path, beginLocalModelChange())
    }

    private fun beginLocalModelChange(): LocalModelOperationGate.Ticket {
        localModelValidationGeneration++
        localModelValidationJob?.cancel()
        localModelValidationJob = null
        cancelEditorAIWork()
        localModelLoaded = false
        localModelLoading = true
        localModelError = null
        return localModelOperations.begin()
    }

    private fun startLocalModelLoad(path: String, ticket: LocalModelOperationGate.Ticket) {
        localModelPath = path
        localModelLoading = true
        localModelError = null
        localModelLoaded = false
        localModelOperations.launch(
            viewModelScope, ticket, {
                try {
                    localModelService.loadModel(path)
                } catch (error: Exception) {
                    withContext(NonCancellable) {
                        try {
                            localModelService.unload()
                        } catch (cleanupError: Exception) {
                            error.addSuppressed(cleanupError)
                        }
                    }
                    throw error
                }
            },
            onSuccess = { localModelLoaded = true },
            onFailure = { error -> localModelError = error.message ?: "Failed to load model" },
            onFinished = { localModelLoading = false }
        )
    }

    fun unloadLocalModel() {
        val ticket = beginLocalModelChange()
        localModelPath = null
        localModelOperations.launch(
            viewModelScope, ticket, { localModelService.unload() },
            onSuccess = {},
            onFailure = { error -> localModelError = error.message ?: "Failed to unload model" },
            onFinished = { localModelLoading = false }
        )
    }

    fun onBackground() {
        cancelEditorAIWork()
    }
}
