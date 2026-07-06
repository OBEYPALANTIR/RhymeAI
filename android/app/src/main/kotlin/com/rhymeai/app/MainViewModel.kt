package com.rhymeai.app

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rhymeai.app.data.model.RewriteAction
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeScheme
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongSection
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.model.TRASH_RETENTION_MILLIS
import com.rhymeai.app.data.model.TrashedSongProject
import android.app.PendingIntent
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.data.sync.DriveSyncService
import com.rhymeai.app.data.sync.DRIVE_SYNC_PASSPHRASE_REQUIREMENT_MESSAGE
import com.rhymeai.app.data.sync.SyncResult
import com.rhymeai.app.data.repository.EncryptedPrefsKeyStore
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.service.AIService
import com.rhymeai.app.service.LocalModelService
import com.rhymeai.app.service.VoiceMemoService
import com.rhymeai.app.util.ProsodyAnalyzer
import com.rhymeai.app.util.RhymeMatches
import com.rhymeai.app.util.SectionRef
import com.rhymeai.app.util.WordProsody
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    var isLoading by mutableStateOf(false)
    var rhymeType by mutableStateOf(RhymeType.PERFECT)
    var rhymeScheme by mutableStateOf(RhymeScheme.AABB)
    var customRhymeScheme by mutableStateOf("")
    var rhymeComplexity by mutableStateOf(RhymeComplexity.MODERATE)
    // Editor toggles — initialized from DataStore in init{}, persisted on every change.
    var useWholeSongContext by mutableStateOf(false)
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
    var saveStatus by mutableStateOf(SaveStatus.IDLE)
    var showProjectsDialog by mutableStateOf(false)
    var showTemplatesDialog by mutableStateOf(false)
    var showStartMenu by mutableStateOf(true)
    var showExportSheet by mutableStateOf(false)

    // Settings
    var selectedProvider by mutableStateOf(AIProvider.GEMINI)
    var selectedModel by mutableStateOf(AIModel.DEFAULT)
    var showSettingsDialog by mutableStateOf(false)
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
    private suspend fun resolveApiKey(): String =
        withContext(Dispatchers.IO) { apiKey(selectedProvider) }

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

    val activeRhymeScheme: String
        get() = if (rhymeScheme == RhymeScheme.CUSTOM)
            customRhymeScheme.ifEmpty { "AABB" }
        else rhymeScheme.pattern

    init {
        // Reflect stored passphrase presence without reading the value itself.
        syncPassphraseStored = driveSyncService.hasPassphrase()

        viewModelScope.launch {
            // Load projects
            projects = repo.projectsFlow.first()
            trashedProjects = repo.trashedProjectsFlow.first()
            purgeExpiredTrashedProjects()
            scheduleTrashPurge()
            currentProjectId = repo.currentProjectIdFlow.first()

            // Load API keys, provider, and model. The key values themselves are
            // never copied into Compose state — we only record which providers
            // have a non-empty key so the UI can show a "configured" badge.
            repo.ensureApiKeysMigrated()
            apiKeyPresence = repo.apiKeySnapshot().mapValues { it.value.isNotEmpty() }
            val savedProvider = repo.selectedProviderFlow.first()
            selectedProvider = AIProvider.fromName(savedProvider)
            val savedModelId = repo.modelIdFlow.first()
            if (savedModelId.isNotEmpty()) selectedModel = AIModel.fromId(savedModelId)

            // Load editor state
            val (savedTitle, savedLyrics, savedTheme) = repo.editorStateFlow().first()
            title = savedTitle
            lyricsFieldValue = TextFieldValue(savedLyrics)
            theme = savedTheme

            // Load persisted editor toggles — must happen before the editor is shown.
            val toggles = repo.editorTogglesFlow.first()
            useWholeSongContext = toggles.useWholeSongContext
            isHighlightEnabled = toggles.isHighlightEnabled
            isSyllableColoringEnabled = toggles.isSyllableColoringEnabled
            isStressPreviewEnabled = toggles.isStressIpaEnabled
            isRhymeHighlightEnabled = toggles.isRhymeHighlightEnabled
            isBeatGridEnabled = toggles.isBeatGridEnabled

            // Always show start menu on fresh launch
            showStartMenu = true

            // Observe project changes
            launch {
                repo.projectsFlow.collect { projects = it }
            }
            launch {
                repo.trashedProjectsFlow.collect {
                    trashedProjects = it
                    scheduleTrashPurge()
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
        val context = computeRhymeContext()
        suggestionsJob?.cancel()
        suggestions = emptyList()
        errorMessage = null
        isLoading = true
        suggestionsJob = viewModelScope.launch {
            try {
                var emittedSuggestion = false
                aiService.streamSuggestions(
                    selectedProvider, resolveApiKey(), selectedModel.id, theme, lyrics, context.targetLine,
                    rhymeType, activeRhymeScheme, context.currentLetter, context.currentSection,
                    rhymeComplexity, useWholeSongContext, context.currentSectionRef, lyrics
                ).collect { line ->
                    emittedSuggestion = true
                    suggestions = suggestions + line
                }
                if (!emittedSuggestion) {
                    errorMessage = "AI did not return suggestions. Try again."
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = e.message ?: "Failed to get suggestions"
            } finally {
                isLoading = false
            }
        }
    }

    fun cancelSuggestions() {
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
        rewriteJob?.cancel()
        pendingRewriteRange = null
        rewriteAction = action
        rewriteOriginal = original
        rewriteRange = range
        rewriteRejectedCandidates = rewriteRejectedCandidates + rejectedCandidates + original
        rewritePreview = null
        rewriteError = null
        rewriteLoading = true
        val fullLyrics = lyrics
        val currentSection = currentSongSection(fullLyrics, range.min)
        val rejectedForRequest = rewriteRejectedCandidates

        rewriteJob = viewModelScope.launch {
            try {
                val result = aiService.getRewrite(
                    provider = selectedProvider,
                    apiKey = resolveApiKey(),
                    modelId = selectedModel.id,
                    action = action,
                    fullLyrics = fullLyrics,
                    selection = original,
                    currentSection = currentSection,
                    selectionStart = range.min,
                    rejectedCandidates = rejectedForRequest
                )
                rewritePreview = result
            } catch (e: Exception) {
                rewriteError = e.message ?: "Rewrite failed"
            } finally {
                rewriteLoading = false
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
        lyricsFieldValue = TextFieldValue(newText, TextRange(newCursor))
        dismissRewrite()
        triggerAutoSave()
    }

    fun dismissRewrite() {
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

        viewModelScope.launch {
            val prosodyResult = withContext(Dispatchers.IO) { ProsodyAnalyzer.analyzeWord(word) }
            val matchesResult = withContext(Dispatchers.IO) { ProsodyAnalyzer.findRhymes(word) }
            inspectorProsody = prosodyResult
            inspectorMatches = matchesResult
        }

        fetchInspectorSynonyms(word, range)
    }

    fun retryInspectorSynonyms() {
        val word = inspectorWord ?: return
        val range = inspectorRange ?: return
        fetchInspectorSynonyms(word, range)
    }

    private fun fetchInspectorSynonyms(word: String, range: TextRange) {
        inspectorSynonymsJob?.cancel()
        inspectorSynonymsError = null
        inspectorSynonymsLoading = true
        val lineContext = currentLineForRange(range)
        inspectorSynonymsJob = viewModelScope.launch {
            try {
                val results = aiService.getSynonyms(
                    provider = selectedProvider,
                    apiKey = resolveApiKey(),
                    modelId = selectedModel.id,
                    word = word,
                    lineContext = lineContext
                )
                inspectorSynonyms = results
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                inspectorSynonymsError = e.message ?: "Failed to load synonyms"
            } finally {
                inspectorSynonymsLoading = false
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
        lyricsFieldValue = TextFieldValue(newText, TextRange(newCursor))
        dismissInspector()
        triggerAutoSave()
    }

    fun dismissInspector() {
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
        lyricsFieldValue = TextFieldValue(newText, TextRange(newPos))
        suggestions = emptyList()
        triggerAutoSave()
    }

    fun newProject() {
        autoSaveJob?.cancel()
        pendingRewriteRange = null
        title = ""
        lyricsFieldValue = TextFieldValue("")
        theme = ""
        currentProjectId = null
        suggestions = emptyList()
        showProjectsDialog = false
        showStartMenu = false
        viewModelScope.launch {
            repo.setCurrentProjectId(null)
            repo.saveEditorState("", "", "")
        }
    }

    fun loadProject(project: SongProject) {
        autoSaveJob?.cancel()
        pendingRewriteRange = null
        title = project.title
        lyricsFieldValue = TextFieldValue(project.lyrics)
        theme = project.theme
        currentProjectId = project.id
        suggestions = emptyList()
        showProjectsDialog = false
        showStartMenu = false
        viewModelScope.launch {
            repo.setCurrentProjectId(project.id)
            repo.saveEditorState(project.title, project.lyrics, project.theme)
        }
    }

    fun moveProjectToTrash(id: String) {
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
        val updatedTrashedProjects = trashedProjects.filter { it.project.id != id }
        trashedProjects = updatedTrashedProjects
        viewModelScope.launch {
            repo.saveTrashedProjects(updatedTrashedProjects)
            // Remove any recorded memos that belonged to this project.
            voiceMemoService.deleteMemoDirectory(id)
        }
        scheduleTrashPurge()
    }

    fun purgeExpiredTrashedProjects() {
        val now = System.currentTimeMillis()
        val retainedProjects = trashedProjects.filter { it.deleteAfter > now }
        if (retainedProjects.size != trashedProjects.size) {
            val purgedIds = trashedProjects
                .filter { it.deleteAfter <= now }
                .map { it.project.id }
            trashedProjects = retainedProjects
            viewModelScope.launch {
                repo.saveTrashedProjects(retainedProjects)
                // Purge memo directories for each project that was permanently removed.
                purgedIds.forEach { voiceMemoService.deleteMemoDirectory(it) }
            }
        }
        scheduleTrashPurge()
    }

    private fun scheduleTrashPurge() {
        trashSchedulerJob?.cancel()
        val now = System.currentTimeMillis()
        val nextDeleteAfter = trashedProjects
            .filter { it.deleteAfter > now }
            .minOfOrNull { it.deleteAfter }
            ?: return
        trashSchedulerJob = viewModelScope.launch {
            delay((nextDeleteAfter - now).coerceAtLeast(0L))
            trashSchedulerJob = null
            purgeExpiredTrashedProjects()
        }
    }

    private fun clearEditorAfterProjectDelete() {
        autoSaveJob?.cancel()
        pendingRewriteRange = null
        title = ""
        lyricsFieldValue = TextFieldValue("")
        theme = ""
        currentProjectId = null
        suggestions = emptyList()
        errorMessage = null
        saveStatus = SaveStatus.IDLE
    }

    fun importProject(imported: SongProject) {
        pendingRewriteRange = null
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
        suggestions = emptyList()
        showProjectsDialog = false
        showStartMenu = false
        viewModelScope.launch {
            persistActiveProjectSnapshot(
                projectId = project.id,
                projectList = projects,
                editorTitle = project.title,
                editorLyrics = project.lyrics,
                editorTheme = project.theme
            )
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
        repo.saveProjects(projectList)
        repo.setCurrentProjectId(projectId)
        repo.saveEditorState(editorTitle, editorLyrics, editorTheme)
    }

    fun applyTemplate(name: String, templateTheme: String, templateLyrics: String) {
        pendingRewriteRange = null
        title = "Untitled $name"
        theme = templateTheme
        lyricsFieldValue = TextFieldValue(templateLyrics)
        currentProjectId = null
        showTemplatesDialog = false
        showStartMenu = false
        triggerAutoSave()
    }

    // A recording needs a project folder before any lyrics exist (people hum
    // the melody first). Creates and persists an Untitled project on demand.
    fun ensureProjectForRecording(): String {
        currentProjectId?.let { return it }
        val newProject = createUntitledProjectSnapshot()
        projects = listOf(newProject) + projects
        currentProjectId = newProject.id
        showStartMenu = false
        viewModelScope.launch {
            persistActiveProjectSnapshot(
                projectId = newProject.id,
                projectList = projects,
                editorTitle = title,
                editorLyrics = lyrics,
                editorTheme = theme
            )
        }
        return newProject.id
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

                projects = updatedProjects
                currentProjectId = updatedProjectId

                persistActiveProjectSnapshot(
                    projectId = updatedProjectId,
                    projectList = updatedProjects,
                    editorTitle = currentTitle,
                    editorLyrics = currentLyrics,
                    editorTheme = currentTheme
                )

                delay(SAVE_STATUS_VISIBLE_MILLIS)
                saveStatus = SaveStatus.SAVED
            } finally {
                // Cancellation mid-save would otherwise leave the indicator stuck on SAVING.
                if (saveStatus == SaveStatus.SAVING) saveStatus = SaveStatus.IDLE
            }
        }
    }

    fun onTitleChanged(newTitle: String) {
        title = newTitle
        triggerAutoSave()
    }

    fun onLyricsChanged(newValue: TextFieldValue) {
        if (hasActiveRewrite) return
        val previousText = lyricsFieldValue.text
        val nextValue = newValue.withValidRanges()
        if (nextValue.text != previousText) {
            pendingRewriteRange = null
            lyricsFieldValue = nextValue
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
            return
        }

        pendingRewriteRange?.let { pendingRange ->
            if (nextSelection.start != pendingRange.min && nextSelection.start != pendingRange.max) {
                pendingRewriteRange = null
            }
        }
        lyricsFieldValue = nextValue
    }

    fun clearPendingRewriteSelection() {
        pendingRewriteRange = null
        val selection = lyricsFieldValue.selection
        if (!selection.collapsed) {
            lyricsFieldValue = lyricsFieldValue.copy(selection = TextRange(selection.max))
        }
    }

    fun onThemeChanged(newTheme: String) {
        theme = newTheme
        triggerAutoSave()
    }

    fun goToStartMenu() {
        showStartMenu = true
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
        apiKeyPresence = apiKeyPresence + (provider.name to key.isNotEmpty())
        viewModelScope.launch {
            repo.saveApiKey(provider.name, key)
        }
    }

    fun saveProvider(provider: AIProvider) {
        selectedProvider = provider
        // Auto-select first model for this provider
        val models = AIModel.modelsForProvider(provider)
        if (selectedModel.provider != provider && models.isNotEmpty()) {
            selectedModel = models.first()
        }
        viewModelScope.launch {
            repo.saveSelectedProvider(provider.name)
            repo.saveModelId(selectedModel.id)
        }
    }

    override fun onCleared() {
        super.onCleared()
        voiceMemoService.release()
    }

    fun saveModel(model: AIModel) {
        selectedModel = model
        viewModelScope.launch {
            repo.saveModelId(model.id)
        }
    }

    fun loadLocalModel(path: String) {
        localModelPath = path
        localModelLoading = true
        localModelError = null
        localModelLoaded = false
        viewModelScope.launch {
            try {
                localModelService.loadModel(path)
                localModelLoaded = true
            } catch (e: Exception) {
                localModelError = e.message ?: "Failed to load model"
                localModelLoaded = false
            } finally {
                localModelLoading = false
            }
        }
    }

    fun unloadLocalModel() {
        localModelService.unload()
        localModelLoaded = false
        localModelPath = null
    }
}
