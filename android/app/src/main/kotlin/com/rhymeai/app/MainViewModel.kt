package com.rhymeai.app

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.core.content.edit
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
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
import com.rhymeai.app.data.repository.MissingActiveProjectException
import com.rhymeai.app.data.sync.BackupArchive
import com.rhymeai.app.data.sync.BackupManifest
import com.rhymeai.app.data.sync.BackupProbe
import com.rhymeai.app.data.sync.BackupRunOutcome
import com.rhymeai.app.data.sync.BackupScheduler
import com.rhymeai.app.data.sync.actionAfterAuthorization
import com.rhymeai.app.data.sync.backupFailureReason
import com.rhymeai.app.data.sync.consentDismissedFailure
import com.rhymeai.app.data.sync.BackupStatus
import com.rhymeai.app.data.sync.DamagedBackupException
import com.rhymeai.app.data.sync.DriveAuthorization
import com.rhymeai.app.data.sync.DriveAuthorizer
import com.rhymeai.app.data.sync.DriveClient
import com.rhymeai.app.data.sync.DriveSyncService
import com.rhymeai.app.data.sync.PlayServicesDriveAuthorizer
import com.rhymeai.app.data.sync.ProbeResult
import com.rhymeai.app.data.sync.RealDriveClient
import com.rhymeai.app.data.sync.SyncResult
import com.rhymeai.app.data.sync.UnsupportedBackupVersionException
import com.rhymeai.app.data.sync.recordingsAllowedForUpload
import com.rhymeai.app.data.sync.resumesAfterConsent
import com.rhymeai.app.data.sync.snapshotLocalRecordings
import com.rhymeai.app.data.repository.EncryptedPrefsKeyStore
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.service.AIService
import com.rhymeai.app.service.LocalModelService
import com.rhymeai.app.service.LocalModelOperationGate
import com.rhymeai.app.service.SyntheticGenerationCapture
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
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
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
 * rhymeTier: 3 = slant, 2 = perfect/multi-syllable, 1 = near, 0 = unverified.
 * isHook: true when this line repeats a chorus end-word from the first chorus
 *         instance — badge shows "hook" instead of "perfect".
 */
data class SuggestedLine(
    val text: String,
    val rhymeTier: Int,
    val isHook: Boolean = false
)

/**
 * Rhyme context of the line a next-line suggestion will be inserted as
 * (see [NextLinePlacement]), not of the line the cursor is on.
 *
 * [targetLine] is the rhyme anchor: the latest earlier line in the stanza with
 * [currentLetter]. [stanzaLines] is the cursor's blank-line-delimited block with an
 * empty row at [currentLineIndex] standing for the line to be inserted.
 */
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

/** Lets instrumented tests run the real backup flow against a fake Drive. */
/** Lets a test hold New Song's selection save after the editor opened the new song (null in the app). */
/** Lets a test fail exactly the next draft save (null in the app). */
internal object DraftSaveTestHooks {
    val failNext = java.util.concurrent.atomic.AtomicBoolean(false)
}

internal object NewSongTestHooks {
    @Volatile var beforeSelectionSave: kotlinx.coroutines.CompletableDeferred<Unit>? = null
}

/** Lets a test hold launch loading after the appearance is known (null in the app). */
internal object LaunchTestHooks {
    @Volatile var beforeLoading: kotlinx.coroutines.CompletableDeferred<Unit>? = null
}

internal object BackupTestHooks {
    @Volatile var driveClient: DriveClient? = null
    @Volatile var authorizer: DriveAuthorizer? = null
}

/** What the launch check of the recordings kept rather than changed, as one notice's sentences (T5.3, T5.12, T5.13, T5.22). */
internal fun recordingMaintenanceNotes(leftInPlace: Int, unresolved: Int, unreadableTrash: Int, heldRestores: Int, setAside: Int): List<String> = listOfNotNull(
    leftInPlace.takeIf { it > 0 }?.let { "$it older recording file(s) could not be renamed because a file with their new name already exists. They were left in place." },
    unresolved.takeIf { it > 0 }?.let { "$it recording move(s) could not be finished. The recordings were kept." },
    unreadableTrash.takeIf { it > 0 }?.let { "$it file(s) in the recordings Trash have names this version cannot read. They were kept and are listed in the Trash Bin." },
    heldRestores.takeIf { it > 0 }?.let { "An interrupted restore from an older version could not be finished. Its files were kept." },
    setAside.takeIf { it > 0 }?.let { "$it deleted recording(s) were set aside on this device." }
)

internal enum class BackupAction { Connect, BackUp, Restore, Migrate }

internal fun backupResultNotice(result: SyncResult.Success, action: BackupAction): String? = listOfNotNull(
    "Your older encrypted backup was moved to the new format. Its files stay in your Google Drive.".takeIf { result.migratedLegacyBackup },
    when (result.songsSetAside) {
        0 -> null
        1 -> "1 song with an unknown date was removed by a deletion; a copy is kept on this device."
        else -> "${result.songsSetAside} songs with unknown dates were removed by a deletion; copies are kept on this device."
    },
    when (result.deletedRecordingsKeptInDrive) {
        0 -> null
        1 -> "1 deleted recording with an unknown date was kept in your Google Drive."
        else -> "${result.deletedRecordingsKeptInDrive} deleted recordings with unknown dates were kept in your Google Drive."
    },
    when (result.unmovedLegacyRecordings) {
        0 -> null
        1 -> "1 older recording could not be moved; the older backup was kept."
        else -> "${result.unmovedLegacyRecordings} older recordings could not be moved; the older backup was kept."
    },
    when (result.unmovedLegacySongs) {
        0 -> null
        1 -> "1 older song could not be moved; the older backup was kept."
        else -> "${result.unmovedLegacySongs} older songs could not be moved; the older backup was kept."
    },
    if (action == BackupAction.Restore) {
        "Restored ${plural(result.merged.projects.size, "song")} and ${plural(result.merged.recordings.size, "recording")}."
    } else null,
    when (result.skippedLargeRecordings) {
        0 -> null
        1 -> "1 recording is over 16 MB and was skipped."
        else -> "${result.skippedLargeRecordings} recordings are over 16 MB and were skipped."
    },
    when (result.conflictingRecordings) {
        0 -> null
        1 -> "1 recording was not uploaded because Google Drive holds different audio for it."
        else -> "${result.conflictingRecordings} recordings were not uploaded because Google Drive holds different audio for them."
    },
    when (result.unmigratedRecordings) {
        0 -> null
        1 -> "1 recording still has its old file name and was left out. Reopen the app to finish updating it."
        else -> "${result.unmigratedRecordings} recordings still have their old file names and were left out. Reopen the app to finish updating them."
    },
    when (result.damagedRecordings) {
        0 -> null
        1 -> "1 recording did not match its backup checksum and was not saved."
        else -> "${result.damagedRecordings} recordings did not match their backup checksum and were not saved."
    }
).joinToString(" ").ifEmpty { null }

private fun plural(count: Int, noun: String): String =
    if (count == 1) "$count $noun" else "$count ${noun}s"

/** A song title is one line: line breaks from Enter, paste or older saves are dropped; spaces stay. */
internal fun sanitizedTitle(title: String): String = title.filterNot { it == '\n' || it == '\r' }

data class SuggestionInsertion(val id: Long, val range: TextRange, val lyrics: String)

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private companion object {
        private const val AUTOSAVE_DEBOUNCE_MILLIS = 450L
        private const val SAVE_STATUS_VISIBLE_MILLIS = 700L
        private const val BACKUP_PREFS = "rhymeai_backup"
        private const val KEY_CONNECTED = "drive_connected"
        private const val KEY_LAST_BACKUP = "last_backup_at"
        private const val KEY_CLIENT_ID = "client_id"
    }

    private val repo = ProjectRepository(application)
    private val backupPrefs = application.getSharedPreferences(BACKUP_PREFS, android.content.Context.MODE_PRIVATE)
    private val backupClientId: String by lazy {
        backupPrefs.getString(KEY_CLIENT_ID, null)
            ?: java.util.UUID.randomUUID().toString().also { backupPrefs.edit { putString(KEY_CLIENT_ID, it) } }
    }
    private val driveAuthorizer: DriveAuthorizer = BackupTestHooks.authorizer
        ?: PlayServicesDriveAuthorizer(application, BuildConfig.DRIVE_OAUTH_CLIENT_ID)
    private val driveSyncService = DriveSyncService(
        filesDir = application.filesDir,
        secureKeyStore = EncryptedPrefsKeyStore(application),
        driveClient = BackupTestHooks.driveClient ?: RealDriveClient(),
        authorizer = driveAuthorizer,
        clientId = { backupClientId }
    )
    private val localModelService = LocalModelService().also {
        it.initialize(application)
    }
    private val aiService = AIService().also { it.localModelService = localModelService }

    /** Owns MediaRecorder/MediaPlayer resources; released in onCleared(). */
    val voiceMemoService = VoiceMemoService(application).also {
        it.recordingDeletionRecorder = repo::recordRecordingDeletion
        // Recording records (id, time, location) live beside the songs (A20/A21).
        it.catalog = repo
        it.deletionsProvider = repo::syncDeletions
        // Playback of a recording stops before its bytes move to quarantine or another name.
        com.rhymeai.app.data.recording.RecordingTransitions.beforeBytesMove = it::stopPlayingIds
    }

    // Editor state
    private var titleState by mutableStateOf("")
    // Every path into the editor (typing, paste, song load, version restore, import) drops line breaks.
    var title: String
        get() = titleState
        set(value) { titleState = sanitizedTitle(value) }
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
    /**
     * Counts suggestion requests that ended by themselves with at least one line;
     * Stop, a cancel from a settings or context change, errors and empty answers
     * leave it alone. The Assistant bursts its spinner when it moves.
     */
    var suggestionRunsCompleted by mutableIntStateOf(0)
        private set
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
    var useWholeSongContext by mutableStateOf(ProjectRepository.DEFAULT_USE_WHOLE_SONG_CONTEXT)
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
    private val pendingProjectCreationIds = mutableSetOf<String>()
    private var workspaces by mutableStateOf<Map<String, SongWorkspace>>(emptyMap())
    val songWorkspace: SongWorkspace get() = workspaces[currentProjectId] ?: SongWorkspace()
    var editorScrollOffset by mutableStateOf(0f)
        private set
    var editorPositionRevision by mutableStateOf(0)
        private set
    var showSongNotebook by mutableStateOf(false)
    var persistenceError by mutableStateOf<String?>(null)
    private var queuedNavigation: (() -> Unit)? = null

    /** A draft is being saved before navigation; a navigation asked for meanwhile waits for it. */
    var savingBeforeNavigation by mutableStateOf(false)
        private set
    var notebookError by mutableStateOf<String?>(null)
        private set
    var restoringDraft by mutableStateOf(false)
        private set
    val recentProject: SongProject? get() = projects.maxByOrNull { it.updatedAt }
    /**
     * Debug builds only: answers Suggest Next Line for UI tests and emulator QA
     * (see [ScriptedSuggestionStream]). Null in normal use.
     */
    private var scriptedSuggestions by mutableStateOf<ScriptedSuggestionStream?>(null)
    val localReady: Boolean get() = localModelLoaded && !localModelLoading && localModelError == null
    /** Suggest Next Line can run on the device: the local model is ready, or a scripted stream answers it. */
    val localSuggestionsReady: Boolean get() = localReady || scriptedSuggestions != null
    val localReadinessLabel: String get() = when {
        scriptedSuggestions != null -> "Scripted suggestions"
        localModelLoading -> "Loading model"
        localModelError != null -> "Model unavailable"
        localReady -> "Ready"
        else -> "Choose a model"
    }

    private suspend fun saveWorkspaceForActiveIdentity(id: String, workspace: SongWorkspace) {
        if (id in pendingProjectCreationIds) {
            val project = projects.firstOrNull { it.id == id } ?: throw MissingActiveProjectException(id)
            persistActiveProjectSnapshot(
                project.copy(title = title.ifEmpty { "Untitled Song" }, lyrics = lyrics, theme = theme),
                title, lyrics, theme
            )
        }
        repo.saveWorkspace(id, workspace)
    }

    private fun updateWorkspace(id: String, transform: (SongWorkspace) -> SongWorkspace) {
        if (notebookError != null || restoringDraft) return
        val next = transform(workspaces[id] ?: SongWorkspace())
        workspaces = workspaces + (id to next)
        viewModelScope.launch {
            try {
                saveWorkspaceForActiveIdentity(id, next)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: MissingActiveProjectException) {
                if (currentProjectId == id) persistenceError = "This song is no longer active. Notebook changes were not saved."
            } catch (_: Exception) {
                notebookError = "Song Notebook could not be saved. Your lyrics are still available. Restart the app to try again."
            }
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
            try {
                workspaces[id]?.let { saveWorkspaceForActiveIdentity(id, it) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: MissingActiveProjectException) {
                if (currentProjectId == id) persistenceError = "This song is no longer active. Notebook changes were not saved."
            } catch (_: Exception) {
                notebookError = "Song Notebook could not be saved. Your lyrics are still available. Restart the app to try again."
            }
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
                saveWorkspaceForActiveIdentity(id, preserved)
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

    private fun detachMissingActiveProject(id: String) {
        pendingProjectCreationIds.remove(id)
        currentProjectId = null
        positionSaveJob?.cancel()
        saveStatus = SaveStatus.IDLE
    }

    private fun reportRecoveredDraft() {
        val message = "This song is no longer active. Your draft was saved as a new song."
        persistenceError = listOfNotNull(persistenceError, message).joinToString("\n")
    }

    fun flushCurrentDraft(onSaved: () -> Unit = {}) {
        if (restoringDraft) return
        // A navigation asked for while a draft is being saved runs once that save is done (the
        // latest one wins); it then saves whatever the editor holds by then, first.
        if (savingBeforeNavigation) { queuedNavigation = { flushCurrentDraft(onSaved) }; return }
        if (!appearanceLoaded || showStartMenu) { onSaved(); return }
        autoSaveJob?.cancel()
        positionSaveJob?.cancel()
        if (title.isBlank() && lyrics.isBlank() && theme.isBlank() && currentProjectId == null) { onSaved(); return }
        val now = System.currentTimeMillis()
        val existing = projects.firstOrNull { it.id == currentProjectId }
        val missingId = currentProjectId?.takeIf { existing == null }
        if (missingId != null) {
            detachMissingActiveProject(missingId)
            if (title.isBlank() && lyrics.isBlank() && theme.isBlank()) { onSaved(); return }
        }
        val project = existing?.copy(
            title = title.ifEmpty { "Untitled Song" }, lyrics = lyrics, theme = theme,
            updatedAt = if (existing.lyrics == lyrics && existing.title == title.ifEmpty { "Untitled Song" } && existing.theme == theme) existing.updatedAt else now
        ) ?: createUntitledProjectSnapshot().also {
            pendingProjectCreationIds.add(it.id)
        }
        currentProjectId = project.id
        if (existing == null) projects = listOf(project) + projects
        rememberEditorPosition()
        updateWorkspace(project.id) { it.checkpoint(title, lyrics, theme, now, force = true) }
        val savedTitle = title
        val savedLyrics = lyrics
        val savedTheme = theme
        savingBeforeNavigation = true
        viewModelScope.launch {
            try {
                persistActiveProjectSnapshot(project, savedTitle, savedLyrics, savedTheme)
                if (currentProjectId == project.id && title == savedTitle && lyrics == savedLyrics && theme == savedTheme) {
                    if (missingId != null) reportRecoveredDraft()
                    onSaved()
                }
            } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
                reconcileFailedProjectSave(project, error)
            } finally {
                savingBeforeNavigation = false
                queuedNavigation?.let { queued -> queuedNavigation = null; queued() }
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
    /** Launch loading has finished (or failed and reported); the splash stays up until then. */
    var initialized by mutableStateOf(false)
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

    // --- Backup (Google Drive) ---

    private var lastBackupAt: Long? = backupPrefs.getLong(KEY_LAST_BACKUP, 0L).takeIf { it > 0L }

    var backupStatus by mutableStateOf<BackupStatus>(
        if (isBackupConnected()) BackupStatus.Connected(lastBackupAt) else BackupStatus.NotConnected
    )
        private set

    /** One-time result line under the Backup rows (restore summary, migration, export). */
    var backupNotice by mutableStateOf<String?>(null)
        private set

    /** Non-null while a user-started backup action runs ("Restoring…", "Exporting…"). */
    var backupBusyLabel by mutableStateOf<String?>(null)
        private set

    /** The older passphrase-encrypted backup is still in Drive. */
    var legacyBackupPresent by mutableStateOf(false)
        private set

    var migrationInProgress by mutableStateOf(false)
        private set
    var migrationError by mutableStateOf<String?>(null)
        private set

    /** Drive holds songs: show "Restore your songs?" (never restored automatically). */
    var restoreOffer by mutableStateOf<BackupProbe?>(null)
        private set

    /**
     * Set when Drive authorization requires the user to approve a consent screen.
     * MainActivity launches it and calls [retryAfterDriveAuthorization] on approval.
     */
    var syncPendingIntent by mutableStateOf<PendingIntent?>(null)

    private val backupMutex = kotlinx.coroutines.sync.Mutex()
    private var pendingAuthAction: BackupAction? = null

    /** The passphrase of a migration waiting for Drive consent: memory only, cleared when used or replaced. */
    private var pendingMigrationPassphrase: String? = null
    private val backupScheduler = BackupScheduler(
        scope = viewModelScope,
        clock = System::currentTimeMillis,
        isConnected = ::isBackupConnected,
        onPending = { if (backupStatus !is BackupStatus.Failed) backupStatus = BackupStatus.Pending }
    ) { interactive ->
        backupStatus = BackupStatus.BackingUp
        val result = backupMutex.withLock { driveSyncService.backUp(repo) }
        when (handleBackupResult(result, BackupAction.BackUp, interactive)) {
            true -> BackupRunOutcome.RETRY
            false -> if (result is SyncResult.Success) BackupRunOutcome.SUCCEEDED else BackupRunOutcome.STOP
        }
    }

    private fun isBackupConnected(): Boolean = backupPrefs.getBoolean(KEY_CONNECTED, false)

    fun connectDrive() {
        backupNotice = null
        backupBusyLabel = "Connecting…"
        viewModelScope.launch {
            val result = backupMutex.withLock { driveSyncService.probe(repo) }
            backupBusyLabel = null
            when (result) {
                is ProbeResult.Ready -> {
                    backupPrefs.edit { putBoolean(KEY_CONNECTED, true) }
                    backupStatus = BackupStatus.Connected(lastBackupAt)
                    legacyBackupPresent = result.probe.legacyBackupPresent
                    if (result.probe.projectCount > 0) restoreOffer = result.probe
                    startBackup(interactive = false)
                }
                is ProbeResult.Failed -> handleBackupResult(result.result, BackupAction.Connect, interactive = true)
            }
        }
    }

    fun disconnectDrive() {
        backupScheduler.reset()
        backupPrefs.edit { remove(KEY_CONNECTED); remove(KEY_LAST_BACKUP) }
        lastBackupAt = null
        backupStatus = BackupStatus.NotConnected
        legacyBackupPresent = false
        restoreOffer = null
        backupBusyLabel = "Disconnecting…"
        viewModelScope.launch {
            val revoked = backupMutex.withLock { driveSyncService.disconnect() }
            backupBusyLabel = null
            backupNotice = if (revoked) {
                "Disconnected from Google Drive. Backups have stopped."
            } else {
                "Disconnected on this device, but Google still lists the app; remove it at myaccount.google.com/permissions."
            }
        }
    }

    fun backUpNow() {
        backupNotice = null
        startBackup(interactive = true)
    }

    fun restoreFromBackup() {
        backupNotice = null
        backupBusyLabel = "Restoring…"
        backupStatus = BackupStatus.BackingUp
        viewModelScope.launch {
            val result = backupMutex.withLock { driveSyncService.restore(repo) }
            backupBusyLabel = null
            handleBackupResult(result, BackupAction.Restore, interactive = true)
        }
    }

    fun acceptRestoreOffer() {
        restoreOffer = null
        restoreFromBackup()
    }

    fun declineRestoreOffer() {
        restoreOffer = null
    }

    fun migrateLegacyBackup(passphrase: String) {
        migrationInProgress = true
        migrationError = null
        viewModelScope.launch {
            val result = backupMutex.withLock { driveSyncService.migrateLegacyBackup(repo, passphrase) }
            migrationInProgress = false
            when (result) {
                SyncResult.WrongPassphrase -> migrationError = "That passphrase did not open the older backup."
                is SyncResult.Success -> handleBackupResult(result, BackupAction.BackUp, interactive = true)
                // Consent first; the migration resumes with this passphrase once Drive access is granted.
                is SyncResult.AuthorizationRequired -> {
                    handleBackupResult(result, BackupAction.Migrate, interactive = true)
                    pendingMigrationPassphrase = passphrase
                }
                else -> {
                    handleBackupResult(result, BackupAction.BackUp, interactive = true)
                    migrationError = (backupStatus as? BackupStatus.Failed)?.reason ?: "The older backup could not be moved. Try again."
                }
            }
        }
    }

    fun retryAfterDriveAuthorization() {
        val action = actionAfterAuthorization(pendingAuthAction, BackupAction.BackUp)
        val passphrase = pendingMigrationPassphrase
        pendingAuthAction = null
        pendingMigrationPassphrase = null
        syncPendingIntent = null
        when (action) {
            BackupAction.Connect -> connectDrive()
            BackupAction.BackUp -> startBackup(interactive = true)
            BackupAction.Restore -> restoreFromBackup()
            BackupAction.Migrate -> if (passphrase != null) migrateLegacyBackup(passphrase) else startBackup(interactive = true)
        }
    }

    /** The consent screen came back without approval (dismissed, or Google refused the request). */
    fun cancelDriveAuthorization() {
        syncPendingIntent = null
        viewModelScope.launch {
            // Play Services also returns RESULT_CANCELED when it refused the request (unregistered OAuth
            // client), so ask it once more: its own status says "cancelled", anything else does not.
            val auth = backupMutex.withLock { driveAuthorizer.authorize() }
            if (auth is DriveAuthorization.Granted) {
                // Disconnect may have landed while Play Services answered; then the saved action is dropped, not run.
                if (resumesAfterConsent(isBackupConnected(), pendingAuthAction, BackupAction.Connect)) {
                    retryAfterDriveAuthorization()
                } else {
                    pendingAuthAction = null
                    pendingMigrationPassphrase = null
                }
                return@launch
            }
            // After process death there is no pending action; while disconnected only Connect shows the notice.
            val fallback = if (isBackupConnected()) BackupAction.BackUp else BackupAction.Connect
            val action = actionAfterAuthorization(pendingAuthAction, fallback)
            pendingAuthAction = null
            pendingMigrationPassphrase = null
            val failure = consentDismissedFailure(auth)
            handleBackupResult(SyncResult.AuthorizationFailed(failure.reason, failure.retryable), action, interactive = true)
        }
    }

    /** Debounced automatic backup after a change; waits out any backoff. */
    fun scheduleAutoBackup() = backupScheduler.schedule()

    /** Leaving the app flushes a pending backup; otherwise at most every 15 minutes. */
    fun triggerBackgroundDriveSync() = backupScheduler.onBackground()

    private fun startBackup(interactive: Boolean) = backupScheduler.runNow(interactive)

    private fun checkBackupAtLaunch() {
        viewModelScope.launch {
            val result = backupMutex.withLock { driveSyncService.probe(repo) }
            if (result !is ProbeResult.Ready) return@launch
            legacyBackupPresent = result.probe.legacyBackupPresent
            if (projects.isEmpty() && result.probe.projectCount > 0) restoreOffer = result.probe
        }
    }

    /** Renders [result]; true when an automatic retry with backoff should follow. */
    private fun handleBackupResult(result: SyncResult, action: BackupAction, interactive: Boolean): Boolean {
        if (action != BackupAction.Connect && !isBackupConnected()) {
            backupStatus = BackupStatus.NotConnected
            return false
        }
        val retry = when (result) {
            is SyncResult.Success -> {
                pendingAuthAction = null
                pendingMigrationPassphrase = null
                val at = System.currentTimeMillis()
                lastBackupAt = at
                backupPrefs.edit { putLong(KEY_LAST_BACKUP, at) }
                backupStatus = BackupStatus.Connected(at)
                legacyBackupPresent = result.legacyBackupPresent
                backupResultNotice(result, action)?.let { backupNotice = it }
                false
            }
            is SyncResult.AuthorizationRequired -> {
                if (interactive) {
                    pendingAuthAction = action
                    pendingMigrationPassphrase = null
                    syncPendingIntent = result.pendingIntent
                    backupStatus = if (isBackupConnected()) BackupStatus.Connected(lastBackupAt) else BackupStatus.NotConnected
                } else {
                    backupStatus = BackupStatus.Failed("Google Drive needs your permission again.", lastBackupAt)
                }
                false
            }
            SyncResult.NoBackup -> {
                backupStatus = BackupStatus.Connected(lastBackupAt)
                backupNotice = "No backup was found in your Google Drive."
                false
            }
            SyncResult.WrongPassphrase -> {
                backupStatus = BackupStatus.Connected(lastBackupAt)
                false
            }
            SyncResult.NotConfigured, SyncResult.CorruptRemote, SyncResult.UnsupportedVersion -> {
                backupStatus = BackupStatus.Failed(backupFailureReason(result), lastBackupAt)
                false
            }
            is SyncResult.AuthorizationFailed -> {
                backupStatus = BackupStatus.Failed(backupFailureReason(result), lastBackupAt)
                result.retryable
            }
            is SyncResult.NetworkError, is SyncResult.UnknownError -> {
                backupStatus = BackupStatus.Failed(backupFailureReason(result), lastBackupAt)
                true
            }
        }
        if (action == BackupAction.Connect && !isBackupConnected() && result !is SyncResult.Success) {
            if (result !is SyncResult.AuthorizationRequired) {
                backupNotice = (backupStatus as? BackupStatus.Failed)?.reason
            }
            backupStatus = BackupStatus.NotConnected
            return false
        }
        return retry
    }

    fun exportFileName(): String = BackupArchive.fileName(System.currentTimeMillis())

    fun exportBackup(uri: android.net.Uri) {
        val app = getApplication<Application>()
        backupNotice = null
        backupBusyLabel = "Exporting…"
        viewModelScope.launch {
            backupNotice = try {
                // Recordings (in songs or the Trash Bin) still awaiting their A36 name: left out and reported.
                var notExported = 0
                val summary = withContext(Dispatchers.IO) {
                    val base = repo.snapshotLocalSyncBase()
                    // Export only reads: no file is renamed or quarantined (A17).
                    val notListed = mutableListOf<java.io.File>()
                    val snapshot = snapshotLocalRecordings(repo, app.filesDir, base.pendingIds, moveFiles = false, notListed = notListed)
                        .filterNot { it.inTrash }
                    notExported = notListed.size
                    // A32: an export carries established precedence times, never an unknown one.
                    val established = repo.establishPrecedence(listOf(base.blob.copy(recordings = snapshot.map { it.entry })), System.currentTimeMillis()).single()
                    val byId = established.recordings.associateBy { it.id }
                    val files = snapshot.map { it.copy(entry = byId.getValue(it.entry.id)) }
                    val allowed = recordingsAllowedForUpload(files.map { it.entry }, base.blob.deletions, emptyList())
                        .mapTo(HashSet()) { it.identityKey }
                    app.contentResolver.openOutputStream(uri)?.use { output ->
                        BackupArchive.write(
                            output, established, files.filter { it.entry.identityKey in allowed },
                            System.currentTimeMillis(), backupClientId
                        )
                    } ?: throw java.io.IOException("The export file could not be opened")
                }
                buildString {
                    append("Exported ${plural(summary.songs, "song")} and ${plural(summary.recordings, "recording")}.")
                    if (summary.skippedLargeRecordings > 0) {
                        append(" ${plural(summary.skippedLargeRecordings, "recording")} over 16 MB left out.")
                    }
                    if (notExported > 0) {
                        append(" ${plural(notExported, "recording")} with an old file name left out. Reopen the app to finish updating ${if (notExported == 1) "it" else "them"}.")
                    }
                    append(" Recordings in the Trash Bin, takes waiting to be saved and recordings set aside are never exported.")
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                "Export failed: ${error.message ?: "unexpected error"}"
            } finally {
                backupBusyLabel = null
            }
        }
    }

    fun importBackup(uri: android.net.Uri) {
        val app = getApplication<Application>()
        backupNotice = null
        backupBusyLabel = "Importing…"
        viewModelScope.launch {
            backupNotice = try {
                val summary = withContext(Dispatchers.IO) {
                    val temp = java.io.File.createTempFile("import-", ".backup", app.cacheDir)
                    try {
                        app.contentResolver.openInputStream(uri)?.use { input ->
                            temp.outputStream().use { input.copyTo(it) }
                        } ?: throw java.io.IOException("The file could not be opened")
                        val contents = BackupArchive.read(temp)
                        backupMutex.withLock { BackupArchive.import(contents, repo, app.filesDir) }
                    } finally {
                        temp.delete()
                    }
                }
                // Recordings added by an import change no song list, so queue the backup here.
                if (summary.recordingsAdded > 0) scheduleAutoBackup()
                buildString {
                    append("Imported ${plural(summary.songs, "song")} and added ${plural(summary.recordingsAdded, "recording")}.")
                    if (summary.damagedRecordings > 0) {
                        val verb = if (summary.damagedRecordings == 1) "was" else "were"
                        append(" ${plural(summary.damagedRecordings, "recording")} failed the checksum and $verb skipped.")
                    }
                    if (summary.skippedLargeRecordings > 0) {
                        append(" ${plural(summary.skippedLargeRecordings, "recording")} over 16 MB skipped.")
                    }
                    when (summary.songsSetAside) {
                        0 -> Unit
                        1 -> append(" 1 song with an unknown date was removed by a deletion; a copy is kept on this device.")
                        else -> append(" ${summary.songsSetAside} songs with unknown dates were removed by a deletion; copies are kept on this device.")
                    }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: DamagedBackupException) {
                BackupManifest.DAMAGED_MESSAGE
            } catch (error: UnsupportedBackupVersionException) {
                error.message
            } catch (error: Exception) {
                "Import failed: ${error.message ?: "unexpected error"}"
            } finally {
                backupBusyLabel = null
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
        viewModelScope.launch {
            _appAppearance = runCatching { repo.appearanceFlow.first() }
                .getOrDefault(AppAppearance.INK)
            appearanceLoaded = true
            LaunchTestHooks.beforeLoading?.await()
            var established = false
            try {
                // A32: every stored time is established before anything is loaded, sorted, selected or
                // scheduled. If that fails, nothing unnormalized is published (fail closed, reported).
                established = try {
                    repo.establishPrecedence(emptyList(), System.currentTimeMillis())
                    true
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    persistenceError = (error as? CorruptLibraryException)?.let(::corruptLibraryMessage)
                        ?: "Your songs could not be checked. Existing data was left untouched. Restart the app to try again."
                    false
                }
                // Load projects; a song created while this loaded (its identity reserved) stays listed.
                val pendingAtLoad = projects.filter { it.id in pendingProjectCreationIds }
                projects = if (!established) emptyList() else try {
                    pendingAtLoad + repo.projectsFlow.first().filterNot { stored -> pendingAtLoad.any { it.id == stored.id } }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: CorruptLibraryException) {
                    persistenceError = corruptLibraryMessage(error)
                    emptyList()
                }
                trashedProjects = if (!established) emptyList() else try {
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
                if (established) {
                    purgeExpiredTrashedProjects()
                    scheduleTrashPurge()
                }
                val savedProjectId = if (established) repo.currentProjectIdFlow.first() else null

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

                val (savedTitle, savedLyrics, savedTheme) = repo.editorStateFlow().first()
                // Load persisted editor toggles — must happen before the editor is shown.
                val toggles = repo.editorTogglesFlow.first()
                // Load editor state, unless the user already started a draft while this loaded: that
                // newer draft stays in the editor and is saved as its own song (never overwritten).
                val startedMeanwhile = !showStartMenu || currentProjectId != null ||
                    title.isNotEmpty() || lyrics.isNotEmpty() || theme.isNotEmpty()
                if (startedMeanwhile) {
                    triggerAutoSave()
                } else {
                    currentProjectId = savedProjectId
                    title = savedTitle
                    lyricsFieldValue = TextFieldValue(savedLyrics)
                    theme = savedTheme
                    restoreEditorPosition()
                }
                useWholeSongContext = toggles.useWholeSongContext
                isHighlightEnabled = toggles.isHighlightEnabled
                isSyllableColoringEnabled = toggles.isSyllableColoringEnabled
                isStressPreviewEnabled = toggles.isStressIpaEnabled
                isRhymeHighlightEnabled = toggles.isRhymeHighlightEnabled
                isBeatGridEnabled = toggles.isBeatGridEnabled

                aiSettingsLoaded = true
                // The start menu opens on a fresh launch, but never over a draft started meanwhile.
                if (!startedMeanwhile) showStartMenu = true
            } finally {
                initialized = true
            }
            if (!established) return@launch

            // Observe project changes
            launch {
                try {
                    repo.projectsFlow.collect { stored ->
                        val pending = projects.filter { it.id in pendingProjectCreationIds &&
                            stored.none { saved -> saved.id == it.id } }
                        projects = pending + stored
                    }
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
            // Trashed recordings have their own expiry clock and live outside the
            // preferences store; rescan it whenever the recording Trash changes.
            launch {
                voiceMemoService.trashChanges.collect { scheduleTrashPurge() }
            }
            // Any change to songs, trash, tombstones or recordings queues the one debounced Drive backup.
            launch { voiceMemoService.memoChanges.collect { scheduleAutoBackup() } }
            launch {
                try {
                    combine(repo.projectsFlow, repo.trashedProjectsFlow, repo.syncDeletionsFlow) { active, trash, tombstones ->
                        Triple(active, trash, tombstones)
                    }
                        .distinctUntilChanged()
                        .drop(1)
                        .collect { scheduleAutoBackup() }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: CorruptLibraryException) {
                    // Reported by the collectors above; nothing to back up from unreadable data.
                }
            }
            // A28: when the known tombstones change, recordings lists re-read what is visible
            // and a recording a tombstone now removes stops playing.
            launch {
                try {
                    repo.syncDeletionsFlow.distinctUntilChanged().drop(1).collect { voiceMemoService.onDeletionsChanged() }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    // Unreadable tombstones: the lists already fail closed.
                }
            }
            // Launch upkeep: A36 migration of pre-A36 files to their id names (journaled,
            // idempotent), then A28 quarantine of recordings whose deletion won (retried here
            // after an interrupted or failed move). The lists reconcile on their own and fail
            // closed meanwhile; they refresh when this finishes, whether it worked or not.
            launch(Dispatchers.IO) {
                val filesDir = getApplication<Application>().filesDir
                var leftReported = false
                voiceMemoService.maintenance = {
                    // A32: this device's own missing times are fixed before anything compares them.
                    repo.establishPrecedence(emptyList(), System.currentTimeMillis())
                    // An interrupted restore of the older encrypted-sync version first: its originals are
                    // preserved in their songs, where the migration below adopts them.
                    val heldRestores = com.rhymeai.app.data.sync.RecordingFileStore.recoverInterruptedRestores(filesDir, onlyHistorical = true)
                    val left = com.rhymeai.app.data.recording.RecordingTransitions.migrate(repo, filesDir) +
                        voiceMemoService.migrateStaging()
                    val setAside = com.rhymeai.app.data.sync.quarantineDeletedRecordings(repo, filesDir)
                    val unresolved = com.rhymeai.app.data.recording.RecordingTransitions.unresolved
                    val unreadableTrash = com.rhymeai.app.data.recording.RecordingTransitions.unrecognizedTrashFiles
                    val notes = recordingMaintenanceNotes(left.size, unresolved.size, unreadableTrash.size, heldRestores.size, setAside)
                    if (notes.isNotEmpty() && !leftReported) {
                        leftReported = true
                        withContext(Dispatchers.Main) { reportRecordingMaintenance(notes.joinToString(" ")) }
                    }
                }
                try {
                    voiceMemoService.runMaintenance()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    // Both lists show nothing until a retry (when either list is opened) succeeds.
                    withContext(Dispatchers.Main) {
                        reportRecordingMaintenance("Recordings could not be checked. They are hidden until the app can read them again.")
                    }
                }
            }
            if (isBackupConnected()) checkBackupAtLaunch()
        }
    }

    fun computeRhymeContext(): RhymeContext {
        return RhymeContextAnalyzer.compute(lyrics, cursorPosition, activeRhymeScheme)
    }

    private fun currentSongSection(text: String, cursor: Int): SongSection {
        return RhymeContextAnalyzer.currentSongSection(text, cursor)
    }

    internal fun captureNextSyntheticSuggestionForTesting(capture: SyntheticGenerationCapture) {
        check(BuildConfig.DEBUG && selectedProvider == AIProvider.LOCAL && localReady)
        localModelService.captureNextSyntheticRequestForTesting(capture)
    }

    /**
     * Debug builds only: Suggest Next Line answers from [script] instead of a
     * provider, so UI tests and emulator QA can hold the loading state and
     * deliver lines on a fixed schedule with no key, request or model. The
     * request still runs through [getSuggestions], so the Assistant's real
     * loading, arrival and cancellation states are what get exercised.
     */
    internal fun enableScriptedSuggestionsForTesting(script: ScriptedSuggestionStream = ScriptedSuggestionStream()) {
        check(BuildConfig.DEBUG) { "Scripted suggestions are only available in debug builds." }
        scriptedSuggestions = script
    }

    fun getSuggestions() {
        if (lyrics.isEmpty()) return
        // A scripted stream never leaves the device, so the readiness and
        // sharing gates, which are for real providers, do not apply to it.
        val script = scriptedSuggestions
        if (script == null) {
            if (selectedProvider == AIProvider.LOCAL && !localReady) {
                errorMessage = if (localModelLoading) "Wait for your local model to finish loading." else "Choose a local model in Settings to get suggestions."
                return
            }
            if (!authorizeCloudAI("suggestions", ::getSuggestions)) return
        }
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
        // Lets on-device trimming keep the stanza being written.
        val cursorLine = if (provider == AIProvider.LOCAL || wholeSong) {
            NextLinePlacement(lyrics, cursorPosition).cursorLineIndex
        } else null
        suggestions = emptyList()
        errorMessage = null
        isLoading = true
        suggestionsJob = viewModelScope.launch {
            try {
                val key = resolveApiKey(provider)
                if (revision != suggestionsRevision || !isCurrentAIContext(requestContext)) return@launch
                var emittedSuggestion = false
                val stream = script?.lines() ?: aiService.streamSuggestions(
                    provider, key, modelId, requestTheme, requestLyrics, context.targetLine,
                    requestRhymeType, requestScheme, context.currentLetter, context.currentSection,
                    requestComplexity, wholeSong, sectionRef, requestLyrics, cursorLine
                )
                stream.collect { line ->
                    if (revision != suggestionsRevision || !isCurrentAIContext(requestContext)) return@collect
                    emittedSuggestion = true
                    suggestions = suggestions + line
                }
                if (revision == suggestionsRevision && isCurrentAIContext(requestContext)) {
                    if (emittedSuggestion) suggestionRunsCompleted++
                    else errorMessage = "AI did not return suggestions. Try again."
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
        // The inspector modal collapses this selection. Do it before capturing
        // request context so opening the modal does not stale its own results.
        clearPendingRewriteSelection()
        inspectorWord = word
        inspectorRange = range
        inspectorSynonyms = emptyList()
        inspectorSynonymsError = null

        // Local word results remain valid when autosave assigns this song its first project ID.
        val inspectorLyrics = lyrics
        inspectorProsody = null
        inspectorMatches = null
        viewModelScope.launch {
            fun stillCurrent() = inspectorWord == word && inspectorRange == range && lyrics == inspectorLyrics
            // Pronunciation is a direct dictionary read; publish it before the rhyme search,
            // whose first run of a session builds the whole rhyme index.
            val prosodyResult = withContext(Dispatchers.IO) { ProsodyAnalyzer.analyzeWord(word) }
            if (stillCurrent()) inspectorProsody = prosodyResult
            val matchesResult = withContext(Dispatchers.IO) { ProsodyAnalyzer.findRhymes(word) }
            if (stillCurrent()) inspectorMatches = matchesResult
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
        // Same placement the rhyme context was computed for: a blank cursor line is
        // filled, otherwise the suggestion becomes a new line after the cursor's line.
        val insertion = NextLinePlacement(lyrics, cursorPosition).inserting(suggestion)
        applyAtomicLyricsEdit(TextFieldValue(insertion.text, TextRange(insertion.cursor)))
        suggestionInsertion = SuggestionInsertion(
            id = ++suggestionInsertionRevision,
            range = TextRange(insertion.start, insertion.end),
            lyrics = insertion.text
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
            // The draft is saved (the flush); the editor opens the new song at once, before the
            // selection is stored, so nothing typed from here on is ever cleared by this New Song.
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
                try {
                    NewSongTestHooks.beforeSelectionSave?.await()
                    // Typing (or another song opened) since the editor cleared owns the stored
                    // selection now; the empty new song's selection is stored only if untouched.
                    val untouched = currentProjectId == null && title.isEmpty() && lyrics.isEmpty() && theme.isEmpty()
                    val committed = if (untouched) repo.saveActiveState(null, false, "", "", "") else repo.projectsFlow.first()
                    // A song started (or opened) meanwhile keeps its place in the list.
                    projects = projects.filter { it.id in pendingProjectCreationIds && committed.none { saved -> saved.id == it.id } } + committed
                    onReady()
                } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
                    persistenceError = trashFailureMessage("open a new song", error)
                }
            }
        }
    }

    fun loadProject(requestedProject: SongProject, onReady: () -> Unit = {}) {
        flushCurrentDraft {
            autoSaveJob?.cancel()
            viewModelScope.launch {
                try {
                    val project = repo.selectProject(requestedProject.id)
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
                    onReady()
                } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
                    persistenceError = trashFailureMessage("open the song", error)
                }
            }
        }
    }

    fun moveProjectToTrash(id: String, onCommitted: (Boolean) -> Unit = {}) {
        if (restoringDraft || savingBeforeNavigation) return
        if (currentProjectId == id) {
            flushCurrentDraft { moveSavedProjectToTrash(id, onCommitted) }
        } else {
            moveSavedProjectToTrash(id, onCommitted)
        }
    }

    private fun moveSavedProjectToTrash(id: String, onCommitted: (Boolean) -> Unit) {
        if (projects.none { it.id == id }) return
        if (currentProjectId == id) autoSaveJob?.cancel()
        viewModelScope.launch {
            try {
                val committed = repo.moveProjectToTrash(id, System.currentTimeMillis())
                if (committed == null) {
                    reportMissingTrashProject()
                    onCommitted(false)
                    return@launch
                }
                pendingProjectCreationIds.remove(id)
                projects = committed.projects
                trashedProjects = committed.trashedProjects
                if (currentProjectId == id) clearEditorAfterProjectDelete()
                scheduleTrashPurge()
                onCommitted(true)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                persistenceError = trashFailureMessage("move the song to Trash", error)
                onCommitted(false)
            }
        }
    }

    fun restoreTrashedProject(id: String) {
        viewModelScope.launch {
            try {
                val committed = repo.restoreTrashedProject(id, System.currentTimeMillis())
                    ?: return@launch reportMissingTrashProject()
                projects = committed.projects
                trashedProjects = committed.trashedProjects
                scheduleTrashPurge()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                persistenceError = trashFailureMessage("restore the song", error)
            }
        }
    }

    // Adoption hashes the song's recordings: never on the main thread.
    private suspend fun adoptRecordings(projectIds: Set<String>) = withContext(Dispatchers.IO) {
        com.rhymeai.app.data.recording.RecordingTransitions.adopt(repo, getApplication<Application>().filesDir, projectIds)
    }

    fun permanentlyDeleteTrashedProject(id: String) {
        if (restoringDraft || savingBeforeNavigation) return
        viewModelScope.launch {
            try {
                // Every recording of the song gets a record first, so the deletion tombstones all of them.
                val committed = repo.permanentlyDeleteTrashedProject(id, adopt = ::adoptRecordings)
                    ?: return@launch reportMissingTrashProject()
                trashedProjects = committed
                pendingProjectCreationIds.remove(id)
                workspaces = workspaces - id
                if (!retryPendingRecordingDeletions(id)) {
                    persistenceError = "The song was removed, but some recording files could not be deleted. Deletion is incomplete; cleanup will be retried on the next launch or Trash purge."
                }
                scheduleTrashPurge()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                persistenceError = trashFailureMessage("permanently delete the song", error)
            }
        }
    }

    private fun reportRecordingMaintenance(detail: String) {
        val existing = persistenceError
        persistenceError = when {
            existing == null -> detail
            detail in existing -> existing
            else -> "$existing $detail"
        }
    }

    fun reportRecordingPurgeFailure() {
        val detail = "Expired recording cleanup did not complete. Some trashed recording files remain."
        val existing = persistenceError
        persistenceError = when {
            existing == null -> detail
            detail in existing -> existing
            else -> "$existing $detail"
        }
    }

    fun purgeExpiredTrashedProjects() {
        if (restoringDraft) return
        viewModelScope.launch {
            val now = System.currentTimeMillis()
            var songPurgeError: Exception? = null
            var memoDirectoryFailure = false
            try {
                // Finish interrupted moves and give every expiring song's recordings a record
                // before the expiry builds their tombstones.
                withContext(Dispatchers.IO) {
                    com.rhymeai.app.data.recording.RecordingTransitions.reconcile(repo, getApplication<Application>().filesDir)
                }
                val committed = repo.purgeExpiredTrashedProjects(now, adopt = ::adoptRecordings)
                trashedProjects = committed.trashedProjects
                workspaces = workspaces - committed.purgedIds.toSet()
                for (id in committed.purgedIds) pendingProjectCreationIds.remove(id)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                songPurgeError = error
            }
            // Retry every committed deletion, including leftovers from earlier launches.
            // The repository checks current song membership before touching either directory.
            if (!retryPendingRecordingDeletions()) memoDirectoryFailure = true
            // Recording Trash has its own expiry; a corrupt song/notebook store
            // must not prevent the independent recording cleanup from running.
            val recordingExpiryComplete = try {
                voiceMemoService.purgeExpiredTrashedMemos(now)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                false
            }
            persistenceError = when {
                songPurgeError != null -> {
                    val reason = if (songPurgeError is CorruptLibraryException)
                        corruptLibraryMessage(songPurgeError)
                    else "Songs due for deletion and their notebook data were retained. Try again."
                    "Scheduled song deletion did not complete. $reason" +
                        (if (memoDirectoryFailure) " Previously deleted songs may also have recording files awaiting retry." else "") +
                        (if (recordingExpiryComplete) "" else " Expired recording cleanup also failed.")
                }
                memoDirectoryFailure && !recordingExpiryComplete ->
                    "Some deleted songs may still have recording files. Expired recording cleanup also failed. Deletion is incomplete; cleanup will be retried on the next launch or Trash purge."
                memoDirectoryFailure ->
                    "Some deleted songs may still have recording files. Deletion is incomplete; cleanup will be retried on the next launch or Trash purge."
                !recordingExpiryComplete ->
                    "Expired recording cleanup did not complete. Some trashed recording files may remain."
                else -> persistenceError
            }
            scheduleTrashPurge()
        }
    }

    private suspend fun retryPendingRecordingDeletions(onlyId: String? = null): Boolean = try {
        repo.retryPendingRecordingDeletions(onlyId, voiceMemoService::deleteMemoDirectory)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        false
    }

    private fun reportMissingTrashProject() {
        persistenceError = "The selected song was not found in storage. No changes were made."
    }

    private fun trashFailureMessage(action: String, error: Exception): String = when (error) {
        is CorruptLibraryException -> corruptLibraryMessage(error)
        is MissingActiveProjectException -> "The song is no longer active. No changes were made."
        else -> "Could not $action. Stored songs were left untouched. Try again."
    }

    /** When the next Trash purge is scheduled (tests observe that nothing unnormalized is scheduled). */
    @Volatile internal var scheduledTrashPurgeAt: Long? = null
        private set

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
            scheduledTrashPurgeAt = nextDeleteAfter
            delay((nextDeleteAfter - now).coerceAtLeast(0L))
            trashSchedulerJob = null
            purgeExpiredTrashedProjects()
        }
    }

    private fun clearEditorAfterProjectDelete() {
        autoSaveJob?.cancel()
        positionSaveJob?.cancel()
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
            val project = imported.copy(
                id = java.util.UUID.randomUUID().toString(),
                title = imported.title.ifBlank { "Imported Song" },
                updatedAt = System.currentTimeMillis()
            )
            pendingProjectCreationIds.add(project.id)
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
                try {
                    persistActiveProjectSnapshot(project, project.title, project.lyrics, project.theme)
                    onReady()
                } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
                    reconcileFailedProjectSave(project, error)
                }
            }
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
        project: SongProject,
        editorTitle: String,
        editorLyrics: String,
        editorTheme: String
    ): List<SongProject> {
        if (currentProjectId != project.id) throw CancellationException("Song changed")
        if (DraftSaveTestHooks.failNext.compareAndSet(true, false)) throw java.io.IOException("injected draft save failure")
        val committed = repo.saveActiveState(
            project, project.id in pendingProjectCreationIds, editorTitle, editorLyrics, editorTheme
        )
        pendingProjectCreationIds.remove(project.id)
        if (currentProjectId == project.id) projects = committed
        return committed
    }

    private suspend fun reconcileFailedProjectSave(project: SongProject, error: Exception) {
        val missing = error is MissingActiveProjectException
        if (missing) pendingProjectCreationIds.remove(project.id)
        try {
            val stored = repo.projectsFlow.first()
            projects = if (!missing && currentProjectId == project.id &&
                project.id in pendingProjectCreationIds && stored.none { it.id == project.id }
            ) listOf(project) + stored else stored
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (corrupt: CorruptLibraryException) {
            persistenceError = corruptLibraryMessage(corrupt)
            return
        }
        if (missing && currentProjectId == project.id) {
            currentProjectId = null
            positionSaveJob?.cancel()
            saveStatus = SaveStatus.IDLE
        }
        persistenceError = when (error) {
            is MissingActiveProjectException -> "This song is no longer active. The unsaved draft remains in the editor; no deleted song was restored."
            is CorruptLibraryException -> corruptLibraryMessage(error)
            else -> "Your draft could not be saved. It is still open. Try again."
        }
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
        pendingProjectCreationIds.add(project.id)
        projects = listOf(project) + projects
        currentProjectId = project.id
        showStartMenu = false
        project.id
    }

    private fun ensureProjectForNotebook(): String {
        currentProjectId?.let { return it }
        val projectId = reserveProjectIdentity()
        val project = projects.first { it.id == projectId }
        val savedTitle = title
        val savedLyrics = lyrics
        val savedTheme = theme
        viewModelScope.launch {
            try {
                persistActiveProjectSnapshot(project, savedTitle, savedLyrics, savedTheme)
            } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
                reconcileFailedProjectSave(project, error)
            }
        }
        return projectId
    }

    // Reserve identity before suspending so edits keep the same autosave target.
    // Persist retries too: a failed save must not admit an orphaned recording.
    suspend fun ensureProjectForRecording(): String {
        val projectId = reserveProjectIdentity()
        val project = (projects.firstOrNull { it.id == projectId }
            ?: createUntitledProjectSnapshot(title, lyrics, theme, id = projectId)).copy(
            title = title.ifEmpty { "Untitled Song" },
            lyrics = lyrics,
            theme = theme,
            updatedAt = System.currentTimeMillis()
        )
        persistActiveProjectSnapshot(project, title, lyrics, theme)
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
            val missingId = projectIdAtTrigger?.takeIf { projects.none { project -> project.id == it } }
            if (missingId != null) detachMissingActiveProject(missingId)

            saveStatus = SaveStatus.SAVING
            val project = if (projectIdAtTrigger == null || missingId != null) {
                createUntitledProjectSnapshot(
                    title = currentTitle, lyrics = currentLyrics, theme = currentTheme
                ).also {
                    pendingProjectCreationIds.add(it.id)
                    projects = listOf(it) + projects
                    currentProjectId = it.id
                }
            } else {
                projects.first { it.id == projectIdAtTrigger }.copy(
                    title = currentTitle.ifEmpty { "Untitled Song" },
                    lyrics = currentLyrics,
                    theme = currentTheme,
                    updatedAt = System.currentTimeMillis()
                )
            }
            try {
                projects.firstOrNull { it.id == project.id && it.id !in pendingProjectCreationIds }?.let { previous ->
                    if (previous.lyrics != currentLyrics || previous.title != currentTitle || previous.theme != currentTheme) {
                        updateWorkspace(project.id) { it.checkpoint(previous.title, previous.lyrics, previous.theme, System.currentTimeMillis(), force = false) }
                    }
                }
                rememberEditorPosition()
                persistActiveProjectSnapshot(project, currentTitle, currentLyrics, currentTheme)
                if (missingId != null) reportRecoveredDraft()
                delay(SAVE_STATUS_VISIBLE_MILLIS)
                if (currentProjectId == project.id && title == currentTitle &&
                    lyrics == currentLyrics && theme == currentTheme
                ) saveStatus = SaveStatus.SAVED
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                reconcileFailedProjectSave(project, error)
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
            com.rhymeai.app.data.recording.RecordingTransitions.beforeBytesMove = null
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
