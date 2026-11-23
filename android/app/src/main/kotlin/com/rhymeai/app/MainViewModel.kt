package com.rhymeai.app

import android.app.Application
import com.rhymeai.app.ui.screens.modalKeepsRewriteSelection
import com.rhymeai.app.ui.theme.DesignTokens
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
import com.rhymeai.app.data.model.DominantHand
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
import com.rhymeai.app.data.repository.HoldResult
import com.rhymeai.app.data.repository.PreservationTicket
import com.rhymeai.app.data.repository.SongCreation
import com.rhymeai.app.data.repository.CreationIdTakenException
import com.rhymeai.app.data.repository.SameIdTrashCopiesException
import com.rhymeai.app.data.repository.SameIdActiveCopiesException
import com.rhymeai.app.data.repository.TrashCopyOutranksActiveException
import com.rhymeai.app.data.sync.BackupArchive
import com.rhymeai.app.data.sync.BackupGate
import com.rhymeai.app.data.sync.BackupManifest
import com.rhymeai.app.data.sync.BackupProbe
import com.rhymeai.app.data.sync.BackupRevision
import com.rhymeai.app.data.sync.RevisionsResult
import com.rhymeai.app.data.sync.RecoveryResult
import com.rhymeai.app.data.sync.RecoverySummary
import com.rhymeai.app.data.sync.GatedBackupRun
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
import com.rhymeai.app.util.LyricTokenizer
import com.rhymeai.app.util.ProsodyAnalyzer
import com.rhymeai.app.util.EditHistory
import com.rhymeai.app.util.RhymeMatches
import com.rhymeai.app.util.SectionMap
import com.rhymeai.app.util.SectionRef
import com.rhymeai.app.util.WordProsody
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
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

enum class SaveStatus { IDLE, SAVING, SAVED, FAILED }

/** When the open draft carries a failed save: as on Apple, it stays until a save of the open words commits. */
internal object SaveFailureRules {
    enum class WriteFailure { WRITE_ERROR, REREAD_CORRUPT, MISSING_ROW }

    /**
     * A write of [failedId] failed: only the draft still open ([openId]) is marked. A confirmed missing
     * row whose words were not edited has nothing unsaved; every other failure has.
     */
    fun failedAfterWriteError(
        wasFailed: Boolean, failedId: String, openId: String?, failure: WriteFailure, wordsEdited: Boolean,
        supersededByCommit: Boolean = false
    ): Boolean = when {
        // A write older than a commit of the open words has nothing left unsaved.
        failedId != openId || supersededByCommit -> wasFailed
        failure == WriteFailure.MISSING_ROW -> wordsEdited
        else -> true
    }

    /** A write of [committedId] committed: it clears the failure only when it is the open song and holds the editor's words. */
    fun failedAfterCommit(wasFailed: Boolean, committedId: String, openId: String?, wordsMatchEditor: Boolean): Boolean =
        wasFailed && !(committedId == openId && wordsMatchEditor)

    /** A song switch, close, new song or Trash of the open song clears it once it completes; one that fails leaves it. */
    fun failedAfterTransition(wasFailed: Boolean, completed: Boolean): Boolean = wasFailed && !completed

    /** An emptied editor writes only on Retry, when the erase of a song it holds is the save that failed. */
    fun emptyDraftNeedsWrite(failed: Boolean, holdsSong: Boolean, retry: Boolean): Boolean = retry && failed && holdsSong

    /** A skipped empty autosave keeps the held song's failure; with no song there is nothing left to save. */
    fun failedAfterEmptySkip(failed: Boolean, holdsSong: Boolean): Boolean = failed && holdsSong

    /** Where a save that ended or was cancelled leaves the indicator. */
    fun restingStatus(failed: Boolean): SaveStatus = if (failed) SaveStatus.FAILED else SaveStatus.IDLE
}

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
    /** Fails the next reread after a failed draft save. */
    val failNextReread = java.util.concurrent.atomic.AtomicBoolean(false)
    /** Holds the next reread after a failed draft save. */
    @Volatile var beforeReread: kotlinx.coroutines.CompletableDeferred<Unit>? = null
    /** Holds the next autosave after its commit, before its "Saved" beat. */
    @Volatile var afterAutosaveCommit: kotlinx.coroutines.CompletableDeferred<Unit>? = null
    /** Holds the next draft write before it runs, so a test can order it against another save. */
    @Volatile var beforeWrite: kotlinx.coroutines.CompletableDeferred<Unit>? = null
    /** Holds the next delayed editor-position save before it writes. */
    @Volatile var beforePositionSave: kotlinx.coroutines.CompletableDeferred<Unit>? = null
}

/** Draws every generated song id; tests replace [next] to force a clash. */
internal object SongIdAllocator {
    @Volatile var next: () -> String = { java.util.UUID.randomUUID().toString() }
}

internal object NewSongTestHooks {
    @Volatile var beforeSelectionSave: kotlinx.coroutines.CompletableDeferred<Unit>? = null
}

/** Lets a test hold an open after its settle beat, with the column faded, before the song swaps (null in the app). */
internal object SongOpenTestHooks {
    @Volatile var beforeSwap: kotlinx.coroutines.CompletableDeferred<Unit>? = null
}

/** Lets a test hold a saved model's, or an explicit Use's, validation before it runs (null in the app). */
/** Persisted when the selected local model was deleted: restore must not pick another one. */
private const val NO_LOCAL_MODEL_SELECTION = ""
internal const val REWRITE_NEEDS_MODEL = "Choose a local model in Settings to rewrite."

/** An exception with no usable message shows [fallback], never an empty error line. */
internal fun failureMessage(error: Throwable, fallback: String): String =
    error.message?.takeIf { it.isNotBlank() } ?: fallback

internal object LocalModelTestHooks {
    @Volatile var beforeSavedModelValidation: kotlinx.coroutines.CompletableDeferred<Unit>? = null
    @Volatile var beforeUseValidation: kotlinx.coroutines.CompletableDeferred<Unit>? = null
    @Volatile var beforeRegistrationSelectionWrite: kotlinx.coroutines.CompletableDeferred<Unit>? = null
}

/** Lets a test hold launch loading after the appearance is known (null in the app). */
internal object LaunchTestHooks {
    @Volatile var beforeLoading: kotlinx.coroutines.CompletableDeferred<Unit>? = null
}

internal object BackupTestHooks {
    @Volatile var driveClient: DriveClient? = null
    @Volatile var authorizer: DriveAuthorizer? = null
    /** Runs in a hold after its draft save, before the operation (a test interleaves another window, or stops there). */
    @Volatile var beforeHeldOperation: (suspend () -> Unit)? = null
    /** Holds the next one-liner send to a song behind the start menu before its write (a test runs a restore meanwhile). */
    @Volatile var beforeMenuSend: kotlinx.coroutines.CompletableDeferred<Unit>? = null
    /** Runs in a hold after its operation, before its result is read (a test changes the store there, or fails the read). */
    @Volatile var beforeHoldResolve: (suspend () -> Unit)? = null
    /** Runs before a held editor's song-list refresh, after its result was read (a test makes the refresh fail). */
    @Volatile var beforeHoldListRefresh: (suspend () -> Unit)? = null
}

/** What the launch check of the recordings kept rather than changed, as one notice's sentences (T5.3, T5.12, T5.13, T5.22). */
internal fun recordingMaintenanceNotes(leftInPlace: Int, unresolved: Int, unreadableTrash: Int, heldRestores: Int, setAside: Int): List<String> = listOfNotNull(
    leftInPlace.takeIf { it > 0 }?.let { "$it older recording file(s) could not be renamed because a file with their new name already exists. They were left in place." },
    unresolved.takeIf { it > 0 }?.let { "$it recording move(s) could not be finished. The recordings were kept." },
    unreadableTrash.takeIf { it > 0 }?.let { "$it file(s) in the recordings Trash have names this version cannot read. They were kept and are listed in the Trash Bin." },
    heldRestores.takeIf { it > 0 }?.let { "An interrupted restore from an older version could not be finished. Its files were kept." },
    setAside.takeIf { it > 0 }?.let { "$it deleted recording(s) were set aside on this device." }
)

/** [Recover] lists Drive's earlier backups again (after consent) or recovers one. */
internal enum class BackupAction { Connect, BackUp, Restore, Migrate, Recover }

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
        // Recordings actually on this device after the apply, not the manifest's count.
        "Restored ${plural(result.merged.projects.size, "song")} and ${plural(result.restoredRecordings, "recording")}."
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
    },
    when (result.missingRecordings) {
        0 -> null
        1 -> "1 recording is no longer in your Google Drive and was not restored."
        else -> "${result.missingRecordings} recordings are no longer in your Google Drive and were not restored."
    }
).joinToString(" ").ifEmpty { null }

/** Whatever a recovery added here reaches Drive through the next backup. */
internal fun recoveryNeedsBackup(summary: RecoverySummary): Boolean = summary.songsAdded > 0 || summary.recordingsAdded > 0

/** "Recovered 2 songs and 3 recordings. 1 already here." and what was left out, from what was created. */
internal fun recoveryNotice(summary: RecoverySummary): String = listOfNotNull(
    "Recovered ${plural(summary.songsAdded, "song")} and ${plural(summary.recordingsAdded, "recording")}. ${summary.alreadyHere} already here.",
    (summary.deletedSongs to summary.deletedRecordings).takeIf { it != (0 to 0) }?.let { (songs, takes) ->
        val parts = listOfNotNull(plural(songs, "song").takeIf { songs > 0 }, plural(takes, "recording").takeIf { takes > 0 })
        "${parts.joinToString(" and ")} deleted after an earlier recovery stay deleted."
    },
    summary.deletedSongsStillHere.takeIf { it > 0 }?.let {
        "An earlier copy of $it of them is still on this phone; a deletion elsewhere keeps it out of the backup unless you edit it here."
    },
    summary.unknownDateDeletions.takeIf { it > 0 }?.let {
        "$it could not be placed because an earlier deletion of unknown date names ${if (it == 1) "it" else "them"}."
    },
    when (summary.missingRecordings) {
        0 -> null
        1 -> "1 recording is no longer in your Google Drive and was not recovered."
        else -> "${summary.missingRecordings} recordings are no longer in your Google Drive and were not recovered."
    },
    when (summary.damagedRecordings) {
        0 -> null
        1 -> "1 recording did not match its backup checksum and was not saved."
        else -> "${summary.damagedRecordings} recordings did not match their backup checksum and were not saved."
    },
    when (summary.skippedLargeRecordings) {
        0 -> null
        1 -> "1 recording is over 16 MB and was skipped."
        else -> "${summary.skippedLargeRecordings} recordings are over 16 MB and were skipped."
    }
).joinToString(" ")

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
        set(value) { val next = sanitizedTitle(value); if (next != titleState) editRevision++; titleState = next }
    private var lyricsFieldState by mutableStateOf(TextFieldValue(""))
    var lyricsFieldValue: TextFieldValue
        get() = lyricsFieldState
        set(value) { if (value.text != lyricsFieldState.text) { editRevision++; lyricsRevision++ }; lyricsFieldState = value }
    private var themeState by mutableStateOf("")
    var theme: String
        get() = themeState
        set(value) { if (value != themeState) editRevision++; themeState = value }

    // Edits to the editor's words since this view model last loaded the song or saved them: a hold saves only these.
    private var editRevision = 0L
    private var savedRevision = 0L
    // Changes to the words alone: a one-liner callback must not load over words changed meanwhile, even back to equal.
    private var lyricsRevision = 0L
    // A load of the song's stored words is not the writer's edit: a pending one-liner callback still loads after it.
    private fun loadWords(text: String) {
        val revision = lyricsRevision
        lyricsFieldValue = TextFieldValue(text)
        lyricsRevision = revision
    }
    private val editorDirty: Boolean get() = editRevision != savedRevision || saveFailed
    private fun markEditorSaved(revision: Long = editRevision) { savedRevision = maxOf(savedRevision, revision) }

    val lyrics: String get() = lyricsFieldValue.text
    val cursorPosition: Int
        get() = lyricsFieldValue.selection.start.coerceIn(0, lyricsFieldValue.text.length)

    // UI state
    var suggestions by mutableStateOf<List<SuggestedLine>>(emptyList())
    var suggestionInsertion by mutableStateOf<SuggestionInsertion?>(null)
        private set
    private var suggestionInsertionRevision = 0L
    /** Bumped when a different song fills the editor (open, New Song, template, import) so the writing column fades in once; a first autosave does not bump it. */
    var openRevision by mutableIntStateOf(0)
        private set
    /** True while another song is being fetched for an editor that is on screen; the writing column fades out meanwhile. */
    var openingSong by mutableStateOf(false)
        private set
    /** The latest open request; an older request that wakes after its settle beat must not replace the editor. */
    private var openRequest = 0
    /** The [openRevision] New Song produced, so the editor puts the caret in the title for that open only. */
    var newSongOpenRevision by mutableIntStateOf(-1)
        private set
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
    /** One new song's creation in this window; [retired] once it is refused or detached, after which it never writes. */
    private class CreationAttempt(val creation: SongCreation = SongCreation()) {
        var retired = false
        /** Whether the save that queued notebook changes wait on stored the song; a Retry after a failure gets a fresh one. */
        var outcome = CompletableDeferred<Boolean>()
        /** Notebook changes made before the song is stored, kept apart from [workspaces] (which may cache another song at this id). */
        var workspace by mutableStateOf<SongWorkspace?>(null)
        fun retire() { retired = true; creation.withdrawn = true; outcome.complete(false) }
    }

    /** New songs not yet known to be stored, each with the attempt its saves carry (captured before they suspend). */
    private val pendingCreations = mutableMapOf<String, CreationAttempt>()
    private var workspaces by mutableStateOf<Map<String, SongWorkspace>>(emptyMap())
    val songWorkspace: SongWorkspace get() =
        currentProjectId?.let(pendingCreations::get)?.let { it.workspace ?: SongWorkspace() } ?: workspaces[currentProjectId] ?: SongWorkspace()
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
    /** Welcome's Continue: the song last open in the editor (persisted as the current song). */
    val recentProject: SongProject? get() = continueSong(projects, currentProjectId)

    // One Liners: a pool of stray lines beside the songs. The widget snapshot follows every change.
    val oneLinersStore = com.rhymeai.app.data.repository.OneLinersStore(application) {
        com.rhymeai.app.widget.OneLinersWidget.refresh(application)
    }
    var oneLiners by mutableStateOf<List<com.rhymeai.app.data.model.OneLiner>>(emptyList())
        private set
    var trashedOneLiners by mutableStateOf<List<com.rhymeai.app.data.model.TrashedOneLiner>>(emptyList())
        private set
    var showOneLiners by mutableStateOf(false)
    /** The One Liners screen was opened from the songs drawer, so its back returns there. */
    var oneLinersOpenedFromDrawer by mutableStateOf(false)
    /** The open capture sheet's words and take; they outlive an activity recreation. */
    val oneLinerCaptures = com.rhymeai.app.service.OneLinerCaptures(viewModelScope)

    /** Saves the open capture in the ViewModel's scope, so a recreated activity never cuts a save short. */
    fun saveOneLinerCapture() = oneLinerCaptures.save { text, take, durationMs ->
        when (val mode = oneLinerCaptures.current?.mode) {
            is com.rhymeai.app.service.OneLinerCaptureSession.Mode.Edit -> updateOneLinerText(mode.line.id, text)
            else -> saveOneLiner(text, take, durationMs)
        }
    }
    /** A widget, tile or link asked for this; the One Liners screen (or an open capture) takes it. */
    var pendingOneLinerAction by mutableStateOf<com.rhymeai.app.ui.navigation.OneLinerAction?>(null)

    fun requestOneLinerAction(action: com.rhymeai.app.ui.navigation.OneLinerAction) {
        pendingOneLinerAction = action
        showOneLiners = true
    }

    /** Saves a capture; throws (with the take's place) so the sheet keeps the words and the take. */
    suspend fun saveOneLiner(text: String, take: java.io.File?, audioDurationMs: Long) {
        oneLinersStore.add(text, take, audioDurationMs)
    }

    suspend fun updateOneLinerText(id: String, text: String) {
        oneLinersStore.updateText(id, text)
    }

    suspend fun trashOneLiner(id: String): Boolean =
        (oneLinersStore.trash(id) != null).also { scheduleTrashPurge() }

    suspend fun restoreOneLiner(id: String): Boolean = oneLinersStore.restore(id) != null

    suspend fun permanentlyDeleteOneLiner(id: String): Boolean = oneLinersStore.permanentlyDelete(id)

    /**
     * Puts the line into the song: at the editor's cursor when that song is the open one (one
     * undoable edit, saved right away), otherwise as its new last line. The line stays in the
     * pool, marked used. Returns the message to show.
     */
    /** Runs in the ViewModel's scope (never the screen's), then reports the message to show. */
    fun sendOneLinerToSong(line: com.rhymeai.app.data.model.OneLiner, project: SongProject, onResult: (String) -> Unit) {
        viewModelScope.launch { onResult(sendOneLinerNow(line, project)) }
    }

    private suspend fun sendOneLinerNow(line: com.rhymeai.app.data.model.OneLiner, project: SongProject): String {
        val text = line.text.trim()
        if (text.isEmpty()) return "Transcribe or type the words first."
        if (editorHeld) return "Couldn't add the line while songs are being restored. Try again in a moment."
        return try {
            if (!showStartMenu && currentProjectId == project.id) {
                val notSaved = "Couldn't add the line to the open song. Try again in a moment."
                val stored = projects.firstOrNull { it.id == project.id } ?: return notSaved
                val creation = pendingCreations[project.id]
                // The marker is saved first: if that fails, nothing went into the song.
                oneLinersStore.markUsed(line.id, project.id) ?: return "This line is no longer in One Liners."
                if (!insertSuggestion(text)) {
                    oneLinersStore.markUsed(line.id, line.usedInProjectId)
                    return notSaved
                }
                val insertion = lyricsHistory.revision
                // Saved right away and awaited: on failure or cancellation the insertion and the
                // marker are put back, and the edits the cancelled autosave held are saved again.
                autoSaveJob?.cancel()
                val savedTitle = title
                val savedLyrics = lyrics
                val savedTheme = theme
                val savedAt = editRevision
                var saved = false
                suspend fun putBack() = withContext(kotlinx.coroutines.NonCancellable) {
                    // Only this insertion is undone, and only while it is the latest edit.
                    if (currentProjectId == project.id && !openingSong) {
                        lyricsHistory.undoIfLatest(insertion, lyricsFieldValue)?.let(::applyHistoryState)
                    }
                    runCatching { oneLinersStore.markUsed(line.id, line.usedInProjectId) }
                }
                val snapshot = stored.copy(title = savedTitle.ifEmpty { "Untitled Song" }, lyrics = savedLyrics, theme = savedTheme,
                    updatedAt = System.currentTimeMillis(), precedenceRepaired = false)
                val attempt = ++saveAttempts
                try {
                    persistActiveProjectSnapshot(snapshot, savedTitle, savedLyrics, savedTheme, attempt, creation)
                    markEditorSaved(savedAt)
                    saved = true
                } catch (cancelled: CancellationException) {
                    putBack()
                    throw cancelled
                } catch (error: Exception) {
                    putBack()
                    if (error is CreationIdTakenException) reconcileFailedProjectSave(snapshot, error, attempt, creation)
                    return notSaved
                } finally {
                    if (!saved) triggerAutoSave()
                }
            } else {
                val wordsRevisionAtSend = lyricsRevision
                BackupTestHooks.beforeMenuSend?.let { BackupTestHooks.beforeMenuSend = null; it.await() }
                val songs = oneLinersStore.sendToSong(line.id, project.id, repo)
                    ?: return "That song is no longer in your library."
                // The song is the editor's (behind the start menu): its words follow the stored song, unless they changed
                // meanwhile. Changed words stay unsaved and their next save wins over the appended line, as before.
                // Only the words are loaded here, so a title or theme edit stays unsaved too: the editor is not marked saved.
                if (currentProjectId == project.id && lyricsRevision == wordsRevisionAtSend) {
                    songs.firstOrNull { it.id == project.id }?.let {
                        loadWords(it.lyrics)
                        resetLyricsHistory()
                    }
                }
            }
            "Sent to “${project.title.ifEmpty { "Untitled Song" }}”"
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: com.rhymeai.app.data.repository.OneLinerHasNoWordsException) {
            "Transcribe or type the words first."
        } catch (_: SameIdActiveCopiesException) {
            "Two songs share this song's identity; the line was not sent."
        } catch (_: Exception) {
            "Couldn't send this line. Try again."
        }
    }
    /**
     * Debug builds only: answers Suggest Next Line for UI tests and emulator QA
     * (see [ScriptedSuggestionStream]). Null in normal use.
     */
    private var scriptedSuggestions by mutableStateOf<ScriptedSuggestionStream?>(null)
    val localReady: Boolean get() = localModelLoaded && !localModelLoading && localModelError == null
    internal val localModelUnloadCount: Int get() = localModelService.unloadCount
    /** Suggest Next Line can run on the device: the local model is ready, or a scripted stream answers it. */
    val localSuggestionsReady: Boolean get() = localReady || scriptedSuggestions != null
    val localReadinessLabel: String get() = when {
        scriptedSuggestions != null -> "Scripted suggestions"
        localModelLoading -> "Loading model"
        localModelError != null -> "Model unavailable"
        localReady -> "Ready"
        else -> "Choose a model"
    }

    /**
     * A loaded song stores [workspace]. A new song's [change] waits for the save that stores the song and is then applied
     * to the notebook of the row its creation made; false when that save did not store it, and nothing is written.
     */
    private suspend fun saveWorkspaceForActiveIdentity(
        id: String, creation: CreationAttempt?, workspace: SongWorkspace, change: (SongWorkspace) -> SongWorkspace
    ): Boolean {
        if (creation == null) {
            repo.saveWorkspace(id, workspace)
            return true
        }
        if (!creation.creation.inserted && !creation.outcome.await() && !creation.creation.inserted) return false
        repo.saveWorkspace(id, creation.creation, change)
        return true
    }

    private fun updateWorkspace(id: String, transform: (SongWorkspace) -> SongWorkspace) {
        if (notebookError != null || restoringDraft || (editorHeld && !flushingHeldDraft)) return
        val creation = pendingCreations[id]
        val next = transform(creation?.let { it.workspace ?: SongWorkspace() } ?: workspaces[id] ?: SongWorkspace())
        if (creation != null) creation.workspace = next else workspaces = workspaces + (id to next)
        viewModelScope.launch {
            try {
                saveWorkspaceForActiveIdentity(id, creation, next, transform)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: MissingActiveProjectException) {
                if (currentProjectId == id && !editorHeld) persistenceError = "This song is no longer active. Notebook changes were not saved."
            } catch (_: Exception) {
                notebookError = "Song Notebook could not be saved. Your lyrics are still available. Restart the app to try again."
            }
        }
    }

    fun rememberEditorPosition(scrollOffset: Float = editorScrollOffset) {
        editorScrollOffset = scrollOffset.coerceAtLeast(0f)
        if (notebookError != null || restoringDraft || (editorHeld && !flushingHeldDraft)) return
        val id = currentProjectId ?: return
        val range = lyricsFieldValue.selection
        val scrollOffset = editorScrollOffset
        val position: (SongWorkspace) -> SongWorkspace = { it.copy(selectionStart = range.start, selectionEnd = range.end, scrollOffset = scrollOffset) }
        val creation = pendingCreations[id]
        if (creation != null) creation.workspace = position(creation.workspace ?: SongWorkspace())
        else workspaces = workspaces + (id to position(songWorkspace))
        positionSaveJob?.cancel()
        positionSaveJob = viewModelScope.launch {
            delay(250)
            DraftSaveTestHooks.beforePositionSave?.let { DraftSaveTestHooks.beforePositionSave = null; it.await() }
            try {
                (if (creation != null) SongWorkspace() else workspaces[id])?.let { saveWorkspaceForActiveIdentity(id, creation, it, position) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: MissingActiveProjectException) {
                if (currentProjectId == id && !editorHeld) persistenceError = "This song is no longer active. Notebook changes were not saved."
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
        if (text.isBlank() || notebookError != null || restoringDraft || editorHeld) return
        val id = ensureProjectForNotebook()
        val now = System.currentTimeMillis()
        // One kept line has one id, in the notebook shown now and in the one stored after a new song's insert.
        val lineId = java.util.UUID.randomUUID().toString()
        updateWorkspace(id) { it.keep(text, now, lineId) }
    }

    fun keepSelectedLyrics() {
        val selection = pendingRewriteRange ?: lyricsFieldValue.selection
        keepAlternate(lyrics.substring(selection.min.coerceIn(0, lyrics.length), selection.max.coerceIn(0, lyrics.length)))
    }

    fun removeAlternate(id: String) {
        currentProjectId?.let { songId -> updateWorkspace(songId) { it.copy(alternates = it.alternates.filterNot { line -> line.id == id }) } }
    }

    fun saveDraftVersion() {
        if (notebookError != null || restoringDraft || editorHeld) return
        val id = ensureProjectForNotebook()
        val (savedTitle, savedLyrics, savedTheme) = Triple(title, lyrics, theme)
        val now = System.currentTimeMillis()
        val versionId = java.util.UUID.randomUUID().toString()
        updateWorkspace(id) { it.checkpoint(savedTitle, savedLyrics, savedTheme, now, force = true, id = versionId) }
        triggerAutoSave()
    }

    fun restoreDraftVersion(version: DraftVersion, onRestored: () -> Unit = {}) {
        if (editorFrozen) return
        val id = currentProjectId ?: return
        if (notebookError != null || restoringDraft) return
        val currentTitle = title
        val currentLyrics = lyrics
        val currentTheme = theme
        val now = System.currentTimeMillis()
        val creation = pendingCreations[id]
        val versionId = java.util.UUID.randomUUID().toString()
        val preserved = songWorkspace.checkpoint(currentTitle, currentLyrics, currentTheme, now, force = true, id = versionId)
        positionSaveJob?.cancel()
        restoringDraft = true
        var restored = false
        viewModelScope.launch {
            try {
                if (!saveWorkspaceForActiveIdentity(id, creation, preserved) { it.checkpoint(currentTitle, currentLyrics, currentTheme, now, force = true, id = versionId) }) return@launch
                // The song may have started leaving for another one while the checkpoint saved.
                if (openingSong) return@launch
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
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: MissingActiveProjectException) {
                // Nothing was restored; the notebook stays usable.
                if (currentProjectId == id && !editorHeld) persistenceError = "This song is no longer active. Notebook changes were not saved."
            } catch (_: Exception) {
                notebookError = "Your current draft could not be preserved, so nothing was restored. Restart the app to try again."
            } finally {
                restoringDraft = false
                if (restored) rememberEditorPosition()
                purgeExpiredTrashedProjects()
            }
        }
    }

    private fun detachMissingActiveProject(id: String, creation: CreationAttempt? = pendingCreations[id]) {
        if (creation != null && pendingCreations[id] === creation) pendingCreations.remove(id)?.retire()
        currentProjectId = null
        positionSaveJob?.cancel()
        saveStatus = SaveFailureRules.restingStatus(saveFailed)
    }

    private fun reportRecoveredDraft() {
        val message = "This song is no longer active. Your draft was saved as a new song."
        persistenceError = listOfNotNull(persistenceError, message).joinToString("\n")
    }

    fun flushCurrentDraft(onSaved: () -> Unit = justSave) {
        // While the editor is held its words are already saved: a plain save (going to the background)
        // never takes the slot of a navigation waiting for the hold to end.
        if (editorHeld && onSaved === justSave && queuedNavigation != null) return
        // A navigation asked for while a draft is being saved, or while the editor is held, runs once
        // that is done (the latest one wins); it then saves whatever the editor holds by then, first.
        if (savingBeforeNavigation || editorHeld) { queuedNavigation = { flushCurrentDraft(onSaved) }; return }
        if (restoringDraft) return
        startDraftFlush(onSaved)
    }

    /** Set while a restore, import or same-song Trash restore runs: edits, autosave and draft writes stop and navigation waits. */
    var editorHeld by mutableStateOf(false)
        private set
    private val editorFrozen: Boolean get() = openingSong || editorHeld
    private val justSave: () -> Unit = {}

    /**
     * Runs [operation], which may replace stored songs, after the open draft is saved, with the editor
     * held until it shows what storage then holds. False, with nothing run, when the draft could not be saved.
     */
    private suspend fun holdEditorFor(operation: suspend () -> Unit): Boolean {
        // A draft save, song open or draft-version restore already running finishes first; nothing captured before is replayed.
        while (restoringDraft || savingBeforeNavigation || editorHeld || opensInFlight > 0 || draftWritesInFlight > 0) delay(20)
        editorHeld = true
        try {
            autoSaveJob?.cancelAndJoin()
            positionSaveJob?.cancelAndJoin()
            // Edits the flush is about to write over the stored song are marked in that same write: a commit that
            // replaces them keeps them as a new song, also when the app dies in between.
            val songId = currentProjectId
            val stored = projects.firstOrNull { it.id == songId }?.takeIf { it.id !in pendingCreations }
            // Only words edited here since the song was loaded or saved are written: a buffer another window's save
            // left behind is no edit, writes nothing and reloads after the operation.
            val dirty = editorDirty
            val edited = dirty && stored != null
            // The ticket for this song's kept copy: new for edits this flush writes, else one a flush stored
            // before the app died. The reload takes it from here, never from the shared selection another window moves.
            val ticket = if (edited) PreservationTicket(SongIdAllocator.next())
                else songId?.let { try { repo.preservedTicket(it) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null } }
            // A failed save keeps its failed state and Retry, as today; nothing is restored over it.
            flushingHeldDraft = true
            val flush = try { if (!dirty) null else startDraftFlush({}, preserveAs = ticket.takeIf { edited }) } finally { flushingHeldDraft = false }
            if (flush?.await() == false) return false
            // The flush re-armed the delayed position save; it must not write while the operation runs.
            positionSaveJob?.cancel()
            restoringDraft = true
            // Also after a failed or cancelled operation: whatever it committed is what the editor shows.
            try {
                BackupTestHooks.beforeHeldOperation?.invoke()
                operation()
            } finally {
                withContext(NonCancellable) {
                    // Only the mark this operation wrote goes; one it read (written before the app died) stays until a commit uses it.
                    if (songId != null && edited && ticket != null) try { repo.clearPreservedSong(songId, ticket) } catch (_: Exception) {}
                    showStoredOpenSong(songId, ticket, untouchedRow = stored.takeIf { !dirty })
                }
            }
            return true
        } finally {
            restoringDraft = false
            editorHeld = false
            queuedNavigation?.let { queued -> queuedNavigation = null; queued() }
        }
    }

    private var flushingHeldDraft = false
    private var opensInFlight = 0
    private var draftWritesInFlight = 0

    /**
     * The held editor shows where the store says its words are, in memory only: the copy the commit made for its
     * [ticket] when [source] is still open, else the open song as stored, or nothing when the song is gone.
     * [untouchedRow] is the song's row before an operation that wrote nothing for this editor.
     */
    private suspend fun showStoredOpenSong(source: String?, ticket: PreservationTicket?, untouchedRow: SongProject? = null) {
        val id = currentProjectId ?: return
        try {
            BackupTestHooks.beforeHoldResolve?.invoke()
            showHeldResult(id, repo.resolveHold(id, ticket.takeIf { source == id }), untouchedRow)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // Unread: the editor's words are kept as a new song rather than written over the stored one.
            detachMissingActiveProject(id)
            persistenceError = "Your songs could not be reread. The open draft will be saved as a new song."
        }
    }

    /**
     * A held editor still on [id] shows [result]: the row its words went to, or the source as stored now. Nothing is
     * selected or written, so another window's selection and saved draft stay as they are.
     */
    private suspend fun showHeldResult(id: String, result: HoldResult, untouchedRow: SongProject?) {
        if (currentProjectId != id) return
        // The song list is a separate read: its failure leaves the result in place.
        try {
            BackupTestHooks.beforeHoldListRefresh?.invoke()
            val stored = repo.projectsFlow.first()
            if (currentProjectId != id) return
            projects = projects.filter { it.id in pendingCreations && stored.none { s -> s.id == it.id } } + stored
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
        }
        val row = when (result) {
            is HoldResult.Adopted -> result.row.also { row ->
                if (projects.none { it.id == row.id }) projects = projects + row
                currentProjectId = row.id
                if (result.appended) {
                    persistenceError = listOfNotNull(persistenceError, "This song was replaced from a backup, so your latest edits were saved as a new song.").joinToString("\n")
                }
            }
            is HoldResult.Miss -> {
                val source = result.source
                if (source == null) {
                    // Its words were saved before the operation; it removed or trashed them.
                    if (id !in pendingCreations) clearEditorAfterProjectDelete()
                    return
                }
                // A row the operation left as it was keeps a separately saved draft (an interrupted save's) on screen.
                if (source == untouchedRow && result.editor == Triple(title, lyrics, theme)) return
                source
            }
        }
        if (row.title == title.ifEmpty { "Untitled Song" } && row.lyrics == lyrics && row.theme == theme) return
        dismissRewrite()
        title = row.title
        loadWords(row.lyrics)
        theme = row.theme
        completeDraftTransition()
        restoreEditorPosition()
        resetLyricsHistory()
        markEditorSaved()
        openRevision++
    }

    /** Null when there was nothing to save; otherwise true once the editor's words committed. */
    private fun startDraftFlush(onSaved: () -> Unit, preserveAs: PreservationTicket? = null): Deferred<Boolean>? {
        if (!appearanceLoaded || showStartMenu) { onSaved(); return null }
        autoSaveJob?.cancel()
        positionSaveJob?.cancel()
        if (title.isBlank() && lyrics.isBlank() && theme.isBlank() && currentProjectId == null) { onSaved(); return null }
        val now = System.currentTimeMillis()
        val existing = projects.firstOrNull { it.id == currentProjectId }
        val missingId = currentProjectId?.takeIf { existing == null }
        if (missingId != null) {
            detachMissingActiveProject(missingId)
            if (title.isBlank() && lyrics.isBlank() && theme.isBlank()) { onSaved(); return null }
        }
        val project = existing?.copy(
            title = title.ifEmpty { "Untitled Song" }, lyrics = lyrics, theme = theme,
            updatedAt = if (existing.lyrics == lyrics && existing.title == title.ifEmpty { "Untitled Song" } && existing.theme == theme) existing.updatedAt else now
        ) ?: createUntitledProjectSnapshot().also {
            pendingCreations[it.id] = CreationAttempt()
        }
        val creation = pendingCreations[project.id]
        currentProjectId = project.id
        if (existing == null) projects = listOf(project) + projects
        rememberEditorPosition()
        val savedTitle = title
        val savedLyrics = lyrics
        val savedTheme = theme
        // The words this flush saves, not the editor's words when a new song's queued copy is applied.
        val versionId = java.util.UUID.randomUUID().toString()
        updateWorkspace(project.id) { it.checkpoint(savedTitle, savedLyrics, savedTheme, now, force = true, id = versionId) }
        val savedAt = editRevision
        savingBeforeNavigation = true
        val attempt = ++saveAttempts
        return viewModelScope.async {
            try {
                persistActiveProjectSnapshot(project, savedTitle, savedLyrics, savedTheme, attempt, creation, preserveAs)
                markEditorSaved(savedAt)
                if (currentProjectId == project.id && title == savedTitle && lyrics == savedLyrics && theme == savedTheme) {
                    if (missingId != null) reportRecoveredDraft()
                    onSaved()
                }
                true
            } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
                reconcileFailedProjectSave(project, error, attempt, creation, storedBefore = existing)
                false
            } finally {
                savingBeforeNavigation = false
                queuedNavigation?.let { queued -> queuedNavigation = null; queued() }
            }
        }
    }

    var saveStatus by mutableStateOf(SaveStatus.IDLE)
    /** The open draft's last save failed and no save of its words has committed since; outlives SAVING during a retry. */
    private var saveFailed = false
    /** Numbers each draft write in start order; [committedAttempt] is the newest one that committed the open words. */
    private var saveAttempts = 0L
    private var committedAttempt = 0L

    private fun setSaveFailed(failed: Boolean) {
        saveFailed = failed
        if (failed) saveStatus = SaveStatus.FAILED else if (saveStatus == SaveStatus.FAILED) saveStatus = SaveStatus.IDLE
    }

    private fun completeDraftTransition() = setSaveFailed(SaveFailureRules.failedAfterTransition(saveFailed, completed = true))

    /** The save-status retry: saves the open words at once, under a new song when the old one is gone. */
    fun retrySave() {
        if (saveFailed && !openingSong) triggerAutoSave(retry = true)
    }

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
    private var _dominantHand by mutableStateOf(DominantHand.RIGHT)
    val dominantHand: DominantHand
        get() = _dominantHand
    private var _selectedProvider by mutableStateOf(AIProvider.LOCAL)
    var selectedProvider: AIProvider
        get() = _selectedProvider
        set(value) {
            if (_selectedProvider == value) return
            cancelEditorAIWork(keepRewriteTarget = true)
            _selectedProvider = value
        }
    private var _selectedModel by mutableStateOf(AIModel.LOCAL_MODEL)
    var selectedModel: AIModel
        get() = _selectedModel
        set(value) {
            if (_selectedModel == value) return
            cancelEditorAIWork(keepRewriteTarget = true)
            _selectedModel = value
        }
    var showSettingsDialog by mutableStateOf(false)
    /** Settings was opened by "Set up model": it opens with AI setup expanded. */
    var settingsOpensAiSetup by mutableStateOf(false)
        private set

    fun openModelSetup() {
        settingsOpensAiSetup = true
        showSettingsDialog = true
    }

    fun dismissSettings() {
        showSettingsDialog = false
        settingsOpensAiSetup = false
    }
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

    internal fun isCurrentAIContext(context: EditorAIContext): Boolean {
        val current = editorAIContext()
        // The first autosave gives an unsaved draft its ID without changing what the
        // request was built from; navigation to another song bumps the revisions instead.
        return context == current || (context.projectId == null && context == current.copy(projectId = null))
    }

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

    /**
     * Stops in-flight AI work and closes the rewrite review. With [keepRewriteTarget], the writer's selection
     * survives, as on iOS, where cancelling AI work never clears it. Only cancels that leave the lyrics and the
     * song as they are pass it (model and provider changes, Apply, going to the background); every path that
     * changes the text or the song clears the range itself, so a kept range is always on the current lyrics.
     */
    private fun cancelEditorAIWork(keepRewriteTarget: Boolean = false) {
        val rewriteTarget = pendingRewriteRange.takeIf { keepRewriteTarget }
        cancelCloudAISharing()
        cancelSuggestions()
        suggestions = emptyList()
        errorMessage = null
        dismissRewrite()
        if (rewriteTarget != null && rewriteTarget.min < rewriteTarget.max && rewriteTarget.max <= lyrics.length) {
            pendingRewriteRange = rewriteTarget
        }
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

    /** Drive's song count while Back up now waits for the user to confirm backing up an empty library. */
    var emptyBackupConfirm by mutableStateOf<Int?>(null)
        private set

    /** Drive's earlier manifest versions while "Recover an earlier backup…" is open. */
    var backupRevisions by mutableStateOf<List<BackupRevision>?>(null)
        private set

    /** The earlier version chosen in the list, waiting for the user's "Recover" (nothing has been asked of Drive yet). */
    var chosenRevision by mutableStateOf<BackupRevision?>(null)
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
    /** Every scheduled, retried, background, connect and Back up now run passes [BackupGate] here. */
    private val gatedBackup = GatedBackupRun(
        localSongCount = ::localSongCount,
        probe = { backupMutex.withLock { driveSyncService.probe(repo) } },
        backUp = {
            backupStatus = BackupStatus.BackingUp
            backupMutex.withLock { driveSyncService.backUp(repo) }
        },
        onGated = { decision, remoteSongs ->
            backupStatus = BackupStatus.Paused(remoteSongs)
            if (decision == BackupGate.Decision.CONFIRM) emptyBackupConfirm = remoteSongs
        },
        onResult = { result, interactive ->
            when (handleBackupResult(result, BackupAction.BackUp, interactive)) {
                true -> BackupRunOutcome.RETRY
                false -> if (result is SyncResult.Success) BackupRunOutcome.SUCCEEDED else BackupRunOutcome.STOP
            }
        },
        decisionPending = { restoreOffer != null }
    )

    private val backupScheduler = BackupScheduler(
        scope = viewModelScope,
        clock = System::currentTimeMillis,
        isConnected = ::isBackupConnected,
        onPending = { if (backupStatus !is BackupStatus.Failed && backupStatus !is BackupStatus.Paused) backupStatus = BackupStatus.Pending }
    ) { interactive -> gatedBackup(interactive) }

    /** Songs stored here, active plus Trash; null when the library cannot be read (nothing then uploads). */
    private suspend fun localSongCount(): Int? = try {
        repo.projectsFlow.first().size + repo.trashedProjectsFlow.first().size
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    /** An empty library over a Drive with songs pauses automatic backup until Restore. */
    private suspend fun pausesBackup(remoteSongs: Int) =
        BackupGate.decide(localSongCount(), remoteSongs, interactive = false, userConfirmed = false) == BackupGate.Decision.PAUSE

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
                    val remoteSongs = result.probe.projectCount
                    // While the restore offer is up nothing uploads; Not now decides.
                    if (remoteSongs > 0) restoreOffer = result.probe else startBackup(interactive = false)
                    // isBackupConnected after the read: a Disconnect meanwhile keeps NotConnected.
                    if (pausesBackup(remoteSongs) && isBackupConnected()) backupStatus = BackupStatus.Paused(remoteSongs)
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
        emptyBackupConfirm = null
        backupRevisions = null
        chosenRevision = null
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
            var refused = false
            // Only the local commit holds the editor; sign-in, Drive reads and downloads run while it stays editable.
            val result = backupMutex.withLock {
                driveSyncService.restore(repo) { commit ->
                    withContext(Dispatchers.Main.immediate) {
                        refused = !holdEditorFor { withContext(Dispatchers.IO) { commit() } }
                    }
                    if (refused) throw IllegalStateException("The open draft could not be saved")
                }
            }
            backupBusyLabel = null
            if (!refused) handleBackupResult(result, BackupAction.Restore, interactive = true)
            else {
                backupStatus = if (isBackupConnected()) BackupStatus.Connected(lastBackupAt) else BackupStatus.NotConnected
                // Recordings may already be downloaded by then; a retry keeps them and downloads nothing twice.
                backupNotice = "Your open draft could not be saved, so your songs were not restored. Some recordings may have been downloaded already; restore again to finish."
            }
        }
    }

    fun listBackupRevisions() {
        backupNotice = null
        backupBusyLabel = "Looking for earlier backups…"
        viewModelScope.launch {
            val result = backupMutex.withLock { driveSyncService.probeRevisions() }
            backupBusyLabel = null
            when (result) {
                is RevisionsResult.Ready ->
                    if (result.revisions.isEmpty()) backupNotice = "Google Drive keeps no earlier backups."
                    else backupRevisions = result.revisions
                is RevisionsResult.Failed -> handleBackupResult(result.result, BackupAction.Recover, interactive = true)
            }
        }
    }

    fun closeBackupRevisions() {
        backupRevisions = null
        chosenRevision = null
    }

    /** Asks for confirmation; Drive is asked to keep the version only when the user confirms. */
    fun chooseBackupRevision(revision: BackupRevision) {
        backupRevisions = null
        chosenRevision = revision
    }

    /** Keeps the chosen version forever, then adds its songs not on this phone as new songs. */
    fun recoverBackupRevision() {
        val revision = chosenRevision ?: return
        chosenRevision = null
        backupNotice = null
        backupBusyLabel = "Recovering…"
        viewModelScope.launch {
            val result = backupMutex.withLock { driveSyncService.recoverRevision(repo, revision) }
            backupBusyLabel = null
            when (result) {
                is RecoveryResult.Recovered -> {
                    backupNotice = recoveryNotice(result.summary)
                    // Takes alone change no song list, so the backup is queued here (as Import does).
                    if (recoveryNeedsBackup(result.summary)) scheduleAutoBackup()
                }
                is RecoveryResult.Failed -> handleBackupResult(result.result, BackupAction.Recover, interactive = true)
            }
        }
    }

    fun acceptRestoreOffer() {
        restoreOffer = null
        restoreFromBackup()
    }

    /** Not now: Drive stays as it is. An empty library stays paused; one with songs backs up. */
    fun declineRestoreOffer() {
        val offer = restoreOffer ?: return
        restoreOffer = null
        if (!isBackupConnected()) return
        viewModelScope.launch {
            val pause = pausesBackup(offer.projectCount)
            // A Disconnect during the library read already set NotConnected; keep it.
            if (!isBackupConnected()) return@launch
            if (pause) backupStatus = BackupStatus.Paused(offer.projectCount)
            else startBackup(interactive = false)
        }
    }

    /** Back up now's explicit confirmation to back up an empty library over Drive's songs. */
    fun confirmEmptyBackup() {
        emptyBackupConfirm = null
        gatedBackup.confirmOnce()
        startBackup(interactive = true)
    }

    fun cancelEmptyBackup() {
        emptyBackupConfirm = null
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
            BackupAction.Recover -> listBackupRevisions()
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

    /** At most one queued cleanup of recovery stages, waiting for the running backup or recovery. */
    private var recoveryStageCleanup: Job? = null

    /**
     * Queued, not blocking maintenance: runs once the backup or recovery releases the lock. A failure
     * (for example storage full while a record is written) is reported like any maintenance failure,
     * never thrown; the next launch or recovery tries again.
     */
    private fun queueRecoveryStageCleanup(filesDir: java.io.File) = synchronized(this) {
        if (recoveryStageCleanup?.isActive == true) return@synchronized
        recoveryStageCleanup = viewModelScope.launch(Dispatchers.IO) {
            try {
                backupMutex.withLock { com.rhymeai.app.data.recording.RecordingTransitions.removeRecoveryStages(repo, filesDir) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                withContext(Dispatchers.Main) {
                    reportRecordingMaintenance("Files left by an interrupted recovery could not be cleaned up yet. The app tries again later.")
                }
            }
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
            if (pausesBackup(result.probe.projectCount) && isBackupConnected()) {
                restoreOffer = result.probe
                backupStatus = BackupStatus.Paused(result.probe.projectCount)
            }
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
                    established.projects.groupingBy { it.id }.eachCount().entries.firstOrNull { it.value > 1 }?.let {
                        error("Two songs on this device share the id ${it.key}, so nothing was exported.")
                    }
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
                // Copied and read before the editor is held: a stalled file provider never locks the editor.
                val contents = withContext(Dispatchers.IO) {
                    val temp = java.io.File.createTempFile("import-", ".backup", app.cacheDir)
                    try {
                        app.contentResolver.openInputStream(uri)?.use { input ->
                            temp.outputStream().use { input.copyTo(it) }
                        } ?: throw java.io.IOException("The file could not be opened")
                        BackupArchive.read(temp)
                    } finally {
                        temp.delete()
                    }
                }
                var imported: BackupArchive.ImportSummary? = null
                val ran = backupMutex.withLock {
                    holdEditorFor { imported = withContext(Dispatchers.IO) { BackupArchive.import(contents, repo, app.filesDir) } }
                }
                if (!ran) throw java.io.IOException("your open draft could not be saved")
                val summary = checkNotNull(imported)
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
    /** The rewrite failed for want of a local model and none is ready yet: the bar offers setup, not Retry. */
    val rewriteNeedsModelSetup: Boolean get() = rewriteError == REWRITE_NEEDS_MODEL && !localReady
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
            if (word.any { !it.isLetter() && it !in LyricTokenizer.APOSTROPHES }) return null
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
            _dominantHand = runCatching { repo.dominantHandFlow.first() }.getOrDefault(DominantHand.RIGHT)
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
                val pendingAtLoad = projects.filter { it.id in pendingCreations }
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
                    markEditorSaved()
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
                        val pending = projects.filter { it.id in pendingCreations &&
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
            fun oneLinersFailed(error: Exception) {
                persistenceError = (error as? CorruptLibraryException)?.let(::corruptLibraryMessage)
                    ?: "One Liners could not be opened. Your songs are still available."
            }
            launch {
                try {
                    oneLinersStore.reconcileAudioFiles()
                    oneLinersStore.publishSnapshot()
                    oneLinersStore.linesFlow.collect { oneLiners = it }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    oneLinersFailed(error)
                }
            }
            launch {
                try {
                    oneLinersStore.trashFlow.collect { trashedOneLiners = it }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    oneLinersFailed(error)
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
                    // Serialized with recovery (backup lock) and every move (transition lock): only unreferenced
                    // stages go. A backup or recovery running now cleans up itself, so this one is skipped then.
                    if (backupMutex.tryLock()) {
                        try {
                            com.rhymeai.app.data.recording.RecordingTransitions.removeRecoveryStages(repo, filesDir)
                        } finally {
                            backupMutex.unlock()
                        }
                    } else {
                        queueRecoveryStageCleanup(filesDir)
                    }
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
                if (revision == suggestionsRevision && isCurrentAIContext(requestContext)) errorMessage = failureMessage(e, "Failed to get suggestions")
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
                oneLinersStore.publishSnapshot() // the widget follows the appearance
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = e.message ?: "Failed to save appearance"
            }
        }
    }

    fun setDominantHand(hand: DominantHand) {
        if (_dominantHand == hand) return
        _dominantHand = hand
        viewModelScope.launch {
            try {
                repo.saveDominantHand(hand)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = e.message ?: "Failed to save dominant hand"
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
            rewriteError = if (localModelLoading) "Wait for your local model to finish loading." else REWRITE_NEEDS_MODEL
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
                if (revision == rewriteRevision && isCurrentAIContext(requestContext)) rewriteError = failureMessage(e, "Rewrite failed")
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
        saveFailed = false
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
        if (editorFrozen) return
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

        inspectorProsody = null
        inspectorMatches = null
        viewModelScope.launch {
            // Both results depend only on the word, so they publish for as long as this
            // inspector is open, whatever else (lyrics, project ID, selection) changes meanwhile.
            fun stillCurrent() = inspectorWord == word && inspectorRange == range
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
        if (editorFrozen) return
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

    /** Returns false when nothing was inserted (the song is leaving for another one). */
    fun insertSuggestion(suggestion: String): Boolean {
        if (editorFrozen) return false
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
        return true
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
        if (editorFrozen) return
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
        // The newest request owns the transition: an older one gives up its beat and must not leave the column faded.
        val request = ++openRequest
        openingSong = false
        flushCurrentDraft {
            if (request != openRequest) return@flushCurrentDraft
            autoSaveJob?.cancel()
            opensInFlight++ // a hold waits for it
            viewModelScope.launch {
                try {
                    // The drawer leaves with the tap; the blank page follows once the column has faded.
                    showProjectsDialog = false
                    if (!settleBeforeOpen(request)) return@launch
                    // The draft is saved (the flush); the editor opens the new song at once, before the
                    // selection is stored, so nothing typed from here on is ever cleared by this New Song.
                    dismissRewrite()
                    title = ""
                    lyricsFieldValue = TextFieldValue("")
                    theme = ""
                    currentProjectId = null
                    completeDraftTransition()
                    restoreEditorPosition()
                    suggestions = emptyList()
                    showStartMenu = false
                    resetLyricsHistory()
                    markEditorSaved() // an empty new song: nothing to save
                    openingSong = false
                    openRevision++
                    newSongOpenRevision = openRevision
                    NewSongTestHooks.beforeSelectionSave?.await()
                    // Typing (or another song opened) since the editor cleared owns the stored
                    // selection now; the empty new song's selection is stored only if untouched.
                    val untouched = currentProjectId == null && title.isEmpty() && lyrics.isEmpty() && theme.isEmpty()
                    val committed = if (untouched) repo.saveActiveState(null, null, "", "", "") else repo.projectsFlow.first()
                    // A song started (or opened) meanwhile keeps its place in the list.
                    projects = projects.filter { it.id in pendingCreations && committed.none { saved -> saved.id == it.id } } + committed
                    onReady()
                } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
                    persistenceError = trashFailureMessage("open a new song", error)
                } finally {
                    opensInFlight--
                    if (openRequest == request) openingSong = false
                }
            }
        }
    }

    /**
     * Gives an on-screen editor the dismiss tier to fade its column out before another song replaces
     * it, at the system animator scale; with animations removed there is nothing to wait for.
     * The caller clears [openingSong] in the same frame it bumps [openRevision].
     */
    private suspend fun settleBeforeOpen(request: Int): Boolean {
        if (showStartMenu) return true
        openingSong = true
        val animatorScale = animatorScaleNow()
        // Waited in short steps so animations removed mid-beat release the editor at once.
        val deadline = android.os.SystemClock.uptimeMillis() + (DesignTokens.Motion.dismissMillis * animatorScale).toLong()
        while (android.os.SystemClock.uptimeMillis() < deadline && animatorScaleNow() > 0f && request == openRequest) delay(16)
        SongOpenTestHooks.beforeSwap?.await()
        // A newer open took over during the beat; it owns the editor and openingSong now.
        return request == openRequest
    }

    private fun animatorScaleNow(): Float = android.provider.Settings.Global.getFloat(
        getApplication<Application>().contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f
    )

    fun loadProject(requestedProject: SongProject, onReady: () -> Unit = {}) {
        // The newest request owns the transition: an older one gives up its beat and must not leave the column faded.
        val request = ++openRequest
        openingSong = false
        flushCurrentDraft {
            if (request != openRequest) return@flushCurrentDraft
            autoSaveJob?.cancel()
            opensInFlight++ // a hold waits for it
            viewModelScope.launch {
                try {
                    showProjectsDialog = false
                    if (!settleBeforeOpen(request)) return@launch
                    val project = repo.selectProject(requestedProject.id)
                    // Overtaken while the song was read (Back, or another open): leave the editor alone.
                    if (request != openRequest) return@launch
                    dismissRewrite()
                    title = project.title
                    loadWords(project.lyrics)
                    theme = project.theme
                    currentProjectId = project.id
                    completeDraftTransition()
                    restoreEditorPosition()
                    suggestions = emptyList()
                    showStartMenu = false
                    resetLyricsHistory()
                    markEditorSaved()
                    // Cleared in the same frame the new song lands, so the fade-in starts from there.
                    openingSong = false
                    openRevision++
                    onReady()
                } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
                    persistenceError = trashFailureMessage("open the song", error)
                } finally {
                    opensInFlight--
                    if (openRequest == request) openingSong = false
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
                pendingCreations.remove(id)?.retire()
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

    fun restoreTrashedProject(id: String, onCommitted: (Boolean) -> Unit = {}) {
        viewModelScope.launch {
            var restored = false
            try {
                val committed = repo.restoreTrashedProject(id, System.currentTimeMillis())
                    ?: return@launch reportMissingTrashProject()
                projects = committed.projects
                trashedProjects = committed.trashedProjects
                restored = true
                // The active song with this id is never changed; only a Trash copy with other words returns, as a new song.
                if (committed.activeKept) persistenceError = if (committed.copied)
                    "This song was already in your songs, so its Trash copy was restored as a new song."
                else "This song was already in your songs, so its Trash copy was removed."
                scheduleTrashPurge()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                persistenceError = trashFailureMessage("restore the song", error)
            } finally {
                onCommitted(restored)
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
                trashedProjects = committed.trashedProjects
                if (id in committed.purgedIds) { // (c); on (b) the active song keeps its notebook, creation mark and recordings
                    pendingCreations.remove(id)?.retire()
                    workspaces = workspaces - id
                    if (!retryPendingRecordingDeletions(id)) {
                        persistenceError = "The song was removed, but some recording files could not be deleted. Deletion is incomplete; cleanup will be retried on the next launch or Trash purge."
                    }
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
                for (id in committed.purgedIds) pendingCreations.remove(id)?.retire()
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
            // One liners expire alongside the songs; a failure leaves them for the next purge.
            try {
                oneLinersStore.purgeExpired(now)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
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
        is SameIdTrashCopiesException -> "Trash holds more than one copy of this song, so none was ${if (action == "restore the song") "restored" else "deleted"}. Stored songs were left untouched."
        is SameIdActiveCopiesException -> if (action == "move the song to Trash") "More than one song shares this identity, so nothing was moved to Trash."
            else "More than one of your songs has this song's identity, so nothing was restored. Stored songs were left untouched."
        is TrashCopyOutranksActiveException -> "This song's Trash copy would replace the song already in your songs, so nothing was restored. Stored songs were left untouched."
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
            val nextOneLinerExpiry = runCatching { oneLinersStore.nextExpiry(now) }.getOrNull()
            val nextDeleteAfter = listOfNotNull(nextProjectExpiry, nextMemoExpiry, nextOneLinerExpiry).minOrNull()
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
        completeDraftTransition()
        saveStatus = SaveStatus.IDLE
        resetLyricsHistory()
        markEditorSaved() // the song is gone: nothing to save
    }

    fun importProject(imported: SongProject, onReady: () -> Unit = {}) {
        // The newest request owns the transition: an older one gives up its beat and must not leave the column faded.
        val request = ++openRequest
        openingSong = false
        flushCurrentDraft {
            if (request != openRequest) return@flushCurrentDraft
            opensInFlight++ // a hold waits for it
            viewModelScope.launch {
                showProjectsDialog = false
                val owned = try { settleBeforeOpen(request) } finally { if (openRequest == request) openingSong = false }
                if (!owned) return@launch
                dismissRewrite()
                val project = imported.copy(
                    id = SongIdAllocator.next(),
                    title = imported.title.ifBlank { "Imported Song" },
                    updatedAt = System.currentTimeMillis()
                )
                val creation = CreationAttempt().also { pendingCreations[project.id] = it }
                projects = listOf(project) + projects
                title = project.title
                lyricsFieldValue = TextFieldValue(project.lyrics)
                theme = project.theme
                currentProjectId = project.id
                completeDraftTransition()
                restoreEditorPosition()
                suggestions = emptyList()
                showStartMenu = false
                resetLyricsHistory()
                openRevision++
                val attempt = ++saveAttempts
                val savedAt = editRevision
                viewModelScope.launch {
                    try {
                        persistActiveProjectSnapshot(project, project.title, project.lyrics, project.theme, attempt, creation)
                        markEditorSaved(savedAt)
                        onReady()
                    } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
                        reconcileFailedProjectSave(project, error, attempt, creation)
                    }
                }
            }.invokeOnCompletion { opensInFlight-- }
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
        id: String = SongIdAllocator.next(),
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
        editorTheme: String,
        attempt: Long,
        creation: CreationAttempt?,
        preserveAs: PreservationTicket? = null
    ): List<SongProject> {
        // Notebook changes queued on a new song wait on this save; after a failure, a Retry's save gets a fresh outcome.
        val outcome = creation?.let {
            if (!it.retired && !it.creation.inserted && it.outcome.isCompleted) CompletableDeferred<Boolean>().also { fresh -> it.outcome = fresh }
            else it.outcome
        }
        var stored = false
        try {
            if (currentProjectId != project.id || creation?.retired == true) throw CancellationException("Song changed")
            draftWritesInFlight++ // a hold waits for it
            val committed = try {
                DraftSaveTestHooks.beforeWrite?.let { DraftSaveTestHooks.beforeWrite = null; it.await() }
                if (DraftSaveTestHooks.failNext.compareAndSet(true, false)) throw java.io.IOException("injected draft save failure")
                repo.saveActiveState(project, creation?.creation, editorTitle, editorLyrics, editorTheme, preserveAs)
            } finally { draftWritesInFlight-- }
            stored = true
            // The stored song's notebook changes made while it was new now join the loaded notebooks.
            // A save without a creation never owns one: an attempt at its id now is a newer song's.
            if (creation != null && pendingCreations[project.id] === creation) {
                pendingCreations.remove(project.id)?.workspace?.let { workspaces = workspaces + (project.id to it) }
            }
            outcome?.complete(true)
            if (currentProjectId == project.id) projects = committed
            val wordsMatch = title == editorTitle && lyrics == editorLyrics && theme == editorTheme
            if (currentProjectId == project.id && wordsMatch) committedAttempt = maxOf(committedAttempt, attempt)
            if (!SaveFailureRules.failedAfterCommit(saveFailed, project.id, currentProjectId, wordsMatch)) setSaveFailed(false)
            return committed
        } finally {
            if (!stored) outcome?.complete(false)
        }
    }

    /** Marks the open draft failed, unless the failed write belongs to a draft no longer open or a newer commit of its words. */
    private fun markFailedSave(id: String, attempt: Long, failure: SaveFailureRules.WriteFailure, wordsEdited: Boolean = true) {
        val superseded = attempt < committedAttempt
        val owned = currentProjectId == id && !superseded
        saveFailed = SaveFailureRules.failedAfterWriteError(saveFailed, id, currentProjectId, failure, wordsEdited, superseded)
        if (owned) saveStatus = SaveFailureRules.restingStatus(saveFailed)
    }

    /** [storedBefore] is the song's row as read before the write: with it a vanished unedited song is told from lost edits. */
    private suspend fun reconcileFailedProjectSave(
        project: SongProject, error: Exception, attempt: Long, creation: CreationAttempt?, storedBefore: SongProject? = null
    ) {
        val missing = error is MissingActiveProjectException
        // An attempt already refused or detached, or one a newer creation at this id replaced, has nothing here to mark or detach.
        if (creation?.retired == true) return
        if (missing) creation?.retire()
        if (pendingCreations[project.id].let { it != null && it !== creation }) return
        val known = storedBefore?.takeIf { it.id !in pendingCreations }
        if (missing) pendingCreations.remove(project.id)?.retire()
        val unedited = known != null && known.title == title.ifEmpty { "Untitled Song" } &&
            known.lyrics == lyrics && known.theme == theme
        // Marked before the reread, so a reread that fails cannot leave the draft unmarked.
        markFailedSave(
            project.id, attempt,
            if (missing) SaveFailureRules.WriteFailure.MISSING_ROW else SaveFailureRules.WriteFailure.WRITE_ERROR,
            wordsEdited = !unedited
        )
        // Detached with the mark, before the reread suspends: edits made meanwhile autosave under a new song.
        // A write older than a commit of the open words under this id leaves the draft where it is.
        val detached = missing && currentProjectId == project.id && attempt >= committedAttempt
        if (detached) {
            // A retry saves the draft under a new song and never restores the deleted one.
            currentProjectId = null
            positionSaveJob?.cancel()
        }
        try {
            DraftSaveTestHooks.beforeReread?.let { DraftSaveTestHooks.beforeReread = null; it.await() }
            if (DraftSaveTestHooks.failNextReread.compareAndSet(true, false)) throw java.io.IOException("injected reread failure")
            val stored = repo.projectsFlow.first()
            projects = if (!missing && currentProjectId == project.id &&
                project.id in pendingCreations && stored.none { it.id == project.id }
            ) listOf(project) + stored else stored
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (corrupt: CorruptLibraryException) {
            persistenceError = corruptLibraryMessage(corrupt)
            markFailedSave(project.id, attempt, SaveFailureRules.WriteFailure.REREAD_CORRUPT)
            return
        } catch (_: Exception) {
            // The song list keeps what the view model last heard; the draft is already marked.
        }
        // Read after the reread: a newer commit of the open words may have landed meanwhile.
        val stale = !detached && attempt < committedAttempt
        persistenceError = when (error) {
            is CorruptLibraryException -> corruptLibraryMessage(error)
            else -> if (stale) persistenceError else if (missing) {
                "This song is no longer active. The unsaved draft remains in the editor; no deleted song was restored."
            } else "Your draft could not be saved. It is still open. Try again."
        }
    }

    fun applyTemplate(name: String, templateTheme: String, templateLyrics: String, onReady: () -> Unit = {}) {
        // The newest request owns the transition: an older one gives up its beat and must not leave the column faded.
        val request = ++openRequest
        openingSong = false
        flushCurrentDraft {
            if (request != openRequest) return@flushCurrentDraft
            opensInFlight++ // a hold waits for it
            viewModelScope.launch {
                showTemplatesDialog = false
                val owned = try { settleBeforeOpen(request) } finally { if (openRequest == request) openingSong = false }
                if (!owned) return@launch
                dismissRewrite()
                title = "Untitled $name"
                theme = templateTheme
                lyricsFieldValue = TextFieldValue(templateLyrics)
                currentProjectId = null
                completeDraftTransition()
                restoreEditorPosition()
                showStartMenu = false
                resetLyricsHistory()
                editRevision++ // a new document, even when its fields equal the last one's
                openRevision++
                triggerAutoSave()

                onReady()
            }.invokeOnCompletion { opensInFlight-- }
        }
    }

    private fun reserveProjectIdentity(): String = currentProjectId ?: createUntitledProjectSnapshot().let { project ->
        pendingCreations[project.id] = CreationAttempt()
        projects = listOf(project) + projects
        currentProjectId = project.id
        showStartMenu = false
        project.id
    }

    private fun ensureProjectForNotebook(): String {
        currentProjectId?.let { return it }
        val projectId = reserveProjectIdentity()
        val project = projects.first { it.id == projectId }
        val creation = pendingCreations[projectId]
        val savedTitle = title
        val savedLyrics = lyrics
        val savedTheme = theme
        val savedAt = editRevision
        val attempt = ++saveAttempts
        viewModelScope.launch {
            try {
                persistActiveProjectSnapshot(project, savedTitle, savedLyrics, savedTheme, attempt, creation)
                markEditorSaved(savedAt)
            } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
                reconcileFailedProjectSave(project, error, attempt, creation)
            }
        }
        return projectId
    }

    // Reserve identity before suspending so edits keep the same autosave target.
    // Persist retries too: a failed save must not admit an orphaned recording.
    suspend fun ensureProjectForRecording(): String {
        if (editorHeld) throw CancellationException("Song changed")
        val projectId = reserveProjectIdentity()
        val creation = pendingCreations[projectId]
        val project = (projects.firstOrNull { it.id == projectId }
            ?: createUntitledProjectSnapshot(title, lyrics, theme, id = projectId)).copy(
            title = title.ifEmpty { "Untitled Song" },
            lyrics = lyrics,
            theme = theme,
            updatedAt = System.currentTimeMillis()
        )
        val attempt = ++saveAttempts
        val savedAt = editRevision
        try {
            persistActiveProjectSnapshot(project, title, lyrics, theme, attempt, creation)
            markEditorSaved(savedAt)
        } catch (cancelled: CancellationException) { throw cancelled } catch (error: Exception) {
            // The caller reports the recording; the open words are still unsaved. A refused new song is detached first.
            if (error is CreationIdTakenException) reconcileFailedProjectSave(project, error, attempt, creation)
            else markFailedSave(project.id, attempt, SaveFailureRules.WriteFailure.WRITE_ERROR)
            throw error
        }
        if (currentProjectId != projectId) throw CancellationException("Song changed")
        return projectId
    }

    /** [retry] is the save-status Retry: it saves at once and, unlike an ordinary autosave, writes an emptied editor. */
    fun triggerAutoSave(retry: Boolean = false) {
        if (editorHeld) return
        autoSaveJob?.cancel()
        autoSaveJob = viewModelScope.launch {
            val currentTitle = title
            val currentLyrics = lyrics
            val currentTheme = theme
            val revisionAtTrigger = editRevision
            val projectIdAtTrigger = currentProjectId
            val creationAtTrigger = projectIdAtTrigger?.let(pendingCreations::get)
            val holdsSong = projects.any { it.id == projectIdAtTrigger }

            if (currentTitle.isEmpty() && currentLyrics.isEmpty() && currentTheme.isEmpty() &&
                !SaveFailureRules.emptyDraftNeedsWrite(saveFailed, holdsSong, retry)
            ) {
                // An autosave never stores empty words over a song; a failure on the held song stays.
                setSaveFailed(SaveFailureRules.failedAfterEmptySkip(saveFailed, holdsSong))
                saveStatus = SaveFailureRules.restingStatus(saveFailed)
                return@launch
            }

            if (!retry) delay(AUTOSAVE_DEBOUNCE_MILLIS)

            // The editor switched projects (or this one was trashed) during the
            // debounce; saving the stale snapshot now would clobber the newly
            // loaded project or resurrect a deleted one.
            if (currentProjectId != projectIdAtTrigger) return@launch
            val missingId = projectIdAtTrigger?.takeIf { projects.none { project -> project.id == it } }
            if (missingId != null) detachMissingActiveProject(missingId, creationAtTrigger)

            saveStatus = SaveStatus.SAVING
            val storedBefore = projects.firstOrNull { it.id == projectIdAtTrigger && missingId == null }
            var creation = creationAtTrigger
            val project = if (projectIdAtTrigger == null || missingId != null) {
                createUntitledProjectSnapshot(
                    title = currentTitle, lyrics = currentLyrics, theme = currentTheme
                ).also {
                    creation = CreationAttempt().also { attempt -> pendingCreations[it.id] = attempt }
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
            val attempt = ++saveAttempts
            try {
                projects.firstOrNull { it.id == project.id && it.id !in pendingCreations }?.let { previous ->
                    if (previous.lyrics != currentLyrics || previous.title != currentTitle || previous.theme != currentTheme) {
                        updateWorkspace(project.id) { it.checkpoint(previous.title, previous.lyrics, previous.theme, System.currentTimeMillis(), force = false) }
                    }
                }
                rememberEditorPosition()
                persistActiveProjectSnapshot(project, currentTitle, currentLyrics, currentTheme, attempt, creation)
                markEditorSaved(revisionAtTrigger)
                if (missingId != null) reportRecoveredDraft()
                DraftSaveTestHooks.afterAutosaveCommit?.let { DraftSaveTestHooks.afterAutosaveCommit = null; it.await() }
                delay(SAVE_STATUS_VISIBLE_MILLIS)
                // Another save of this draft may have failed during the beat; SAVED would hide its Retry.
                if (currentProjectId == project.id && title == currentTitle &&
                    lyrics == currentLyrics && theme == currentTheme && !saveFailed
                ) saveStatus = SaveStatus.SAVED
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                reconcileFailedProjectSave(project, error, attempt, creation, storedBefore)
            } finally {
                // Cancellation mid-save would otherwise leave the indicator stuck on SAVING; an unresolved failure stays FAILED.
                if (saveStatus == SaveStatus.SAVING) saveStatus = SaveFailureRules.restingStatus(saveFailed)
            }
        }
    }

    fun onTitleChanged(newTitle: String) {
        // Nothing edits the song that is leaving for another one.
        if (editorFrozen) return
        cancelEditorAIWork()
        title = newTitle
        triggerAutoSave()
    }

    fun onLyricsChanged(
        newValue: TextFieldValue,
        timestampMilliseconds: Long = android.os.SystemClock.uptimeMillis()
    ) {
        if (hasActiveRewrite || editorFrozen) return
        val previousText = lyricsFieldValue.text
        val nextValue = newValue.withValidRanges()
        // Focus leaving for a modal that uses the selection collapses the cursor onto one of its ends; keep the range
        // through that. A selection restored on song open never set the range, so the field's own selection stands in.
        val modalRange = if (modalKeepsRewriteSelection(showSongNotebook, showOneLiners, settingsOpensAiSetup)) {
            // Collapsed or blank selections get no range, as in the expanded-selection branch below.
            pendingRewriteRange ?: lyricsFieldValue.selection.takeUnless {
                val text = lyricsFieldValue.text
                text.substring(it.min.coerceIn(0, text.length), it.max.coerceIn(0, text.length)).isBlank()
            }
        } else null
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

        pendingRewriteRange = (modalRange ?: pendingRewriteRange)?.takeIf { nextSelection.start == it.min || nextSelection.start == it.max }
        lyricsFieldValue = nextValue
        rememberEditorPosition()
    }

    fun undoLyrics() {
        if (editorFrozen) return
        val previous = lyricsHistory.undo(lyricsFieldValue) ?: return
        applyHistoryState(previous)
    }

    fun redoLyrics() {
        if (editorFrozen) return
        val next = lyricsHistory.redo(lyricsFieldValue) ?: return
        applyHistoryState(next)
    }

    private fun applyAtomicLyricsEdit(nextValue: TextFieldValue) {
        if (editorFrozen) return
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
        if (editorFrozen) return
        cancelEditorAIWork()
        theme = newTheme
        triggerAutoSave()
    }

    fun goToStartMenu(onReady: () -> Unit = {}) {
        // Back cancels any open still waiting out its settle beat.
        openRequest++
        openingSong = false
        flushCurrentDraft { suggestionInsertion = null; showStartMenu = true; completeDraftTransition(); onReady() }
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
        modelChoiceRevision++
        cancelEditorAIWork(keepRewriteTarget = true)
        return try {
            withContext(Dispatchers.IO) {
                keys.forEach { (keyProvider, key) -> repo.saveApiKey(keyProvider.name, key) }
                repo.saveSelectedProvider(provider.name)
                repo.saveModelId(model.id)
            }
            cancelEditorAIWork(keepRewriteTarget = true)
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
        modelChoiceRevision++
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
            // Stopping finishes the take's file; with the capture gone it is cleared with the other abandoned pending takes.
            oneLinerCaptures.current?.recorder?.stop()
            super.onCleared()
        }
    }

    fun saveModel(model: AIModel) {
        modelChoiceRevision++
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
        val storedSelection = repo.selectedLocalModelIdFlow.first()
        // An explicit "none" (the selected model was deleted) never falls back to another model.
        val cleared = storedSelection == NO_LOCAL_MODEL_SELECTION
        selectedLocalModelId = storedSelection?.takeIf { selectedId -> persisted.any { it.id == selectedId } }
            ?: persisted.firstOrNull()?.id?.takeUnless { cleared }
        repo.saveSelectedLocalModelId(selectedLocalModelId ?: NO_LOCAL_MODEL_SELECTION.takeIf { cleared })
        if (selectedProvider == AIProvider.LOCAL) {
            selectedSavedLocalModel()?.let { model ->
                loadLocalModel(java.io.File(filesDir, model.fileName).absolutePath)
            }
        }
    }

    /**
     * Counts the user's provider and model selections, bumped as soon as one is asked for
     * (before any validation lands), so a finished download knows whether a newer choice came
     * in while it ran.
     */
    internal var modelChoiceRevision = 0L
        private set

    /** Adds the model to the saved list; with [select] it also becomes the active local model and provider. */
    fun registerAndSelectLocalModel(
        path: String,
        displayName: String,
        isCustom: Boolean,
        verifiedCatalogSha256: String? = null,
        select: Boolean = true
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
        viewModelScope.launch {
            persistSavedLocalModels()
            LocalModelTestHooks.beforeRegistrationSelectionWrite?.await()
            // A delete may have cleared the selection meanwhile; its explicit none must stay.
            savedLocalModelsWriteLock.withLock {
                if (select && selectedLocalModelId == model.id) repo.saveSelectedLocalModelId(model.id)
            }
        }
        if (!select) return
        selectedLocalModelId = model.id
        saveProvider(AIProvider.LOCAL)
        saveModel(AIModel.LOCAL_MODEL)
        loadLocalModel(file.absolutePath)
    }

    fun selectSavedLocalModel(modelId: String) {
        val model = savedLocalModels.firstOrNull { it.id == modelId } ?: return
        if (gemmaDeletingModel?.fileName == model.fileName) return
        modelChoiceRevision++
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
                    LocalModelTestHooks.beforeSavedModelValidation?.await()
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

    /**
     * Installs a finished download. [choiceRevisionAtStart] is [modelChoiceRevision] when
     * the download began; the model only takes over the selection when the user has not
     * asked for another provider or model since. Null means the user asked to use it now,
     * which is itself a choice that a download finishing later must not override.
     */
    internal suspend fun useDownloadedGemma(
        model: com.rhymeai.app.ui.components.GemmaDownload,
        choiceRevisionAtStart: Long? = null
    ): Boolean {
        if (gemmaDeletingModel?.fileName == model.fileName) return false
        val deletesAtStart = gemmaDeleteCounts[model.fileName]
        if (choiceRevisionAtStart == null) {
            modelChoiceRevision++
            LocalModelTestHooks.beforeUseValidation?.await()
        }
        val destFile = java.io.File(getApplication<android.app.Application>().filesDir, model.fileName)
        val validationError = withContext(Dispatchers.IO) {
            com.rhymeai.app.ui.components.validateDownloadedGemmaIntegrity(model, destFile)
        }
        if (validationError != null) {
            gemmaDownloadError = validationError
            verifiedGemmaFileNames -= model.fileName
            return false
        }
        // A delete may have started, or started and finished, while the integrity check ran;
        // never publish a selection for a file it removed.
        if (gemmaDeletingModel?.fileName == model.fileName || gemmaDeleteCounts[model.fileName] != deletesAtStart) {
            return false
        }
        verifiedGemmaFileNames += model.fileName
        registerAndSelectLocalModel(
            path = destFile.absolutePath,
            displayName = model.label,
            isCustom = false,
            verifiedCatalogSha256 = model.sha256,
            select = choiceRevisionAtStart == null || choiceRevisionAtStart == modelChoiceRevision
        )
        return true
    }

    internal fun startGemmaDownload(model: com.rhymeai.app.ui.components.GemmaDownload) {
        if (gemmaDownloadingModel != null || gemmaDeletingModel?.fileName == model.fileName) return
        gemmaDownloadingModel = model
        gemmaDownloadProgress = 0f
        gemmaDownloadVerifying = false
        gemmaDownloadError = null
        gemmaLastDownloadAttempt = model
        val choiceRevisionAtStart = modelChoiceRevision
        val app = getApplication<android.app.Application>()

        viewModelScope.launch(Dispatchers.IO) {
            val destFile = java.io.File(app.filesDir, model.fileName)
            val tempFile = com.rhymeai.app.ui.components.gemmaDownloadTempFile(app.cacheDir, model)
            try {
                if (com.rhymeai.app.ui.components.validateDownloadedGemmaIntegrity(model, destFile) == null) {
                    withContext(Dispatchers.Main) {
                        gemmaDownloadingModel = null
                        gemmaDownloadProgress = null
                        gemmaDownloadVerifying = false
                        useDownloadedGemma(model, choiceRevisionAtStart)
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
                    useDownloadedGemma(model, choiceRevisionAtStart)
                }
            } catch (e: Exception) {
                android.util.Log.w("RhymeAI", "Gemma download failed", e)
                withContext(Dispatchers.Main) {
                    gemmaDownloadingModel = null
                    gemmaDownloadProgress = null
                    gemmaDownloadVerifying = false
                    // The attempt may have reclaimed a stale installed file; the rows re-read the disk.
                    gemmaDownloadRevision++
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
        cancelEditorAIWork(keepRewriteTarget = true)
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

    /** The catalog model being deleted; its row actions, download, use and select are refused meanwhile. */
    internal var gemmaDeletingModel by mutableStateOf<com.rhymeai.app.ui.components.GemmaDownload?>(null)
        private set

    /** Deletes started per catalog file; a download validated across one must not publish its selection. */
    private val gemmaDeleteCounts = mutableMapOf<String, Int>()
    private val savedLocalModelsWriteLock = Mutex()

    /** Writes the saved list as it stands when its turn comes, so an older queued write cannot restore a deleted entry. */
    private suspend fun persistSavedLocalModels() =
        savedLocalModelsWriteLock.withLock { repo.saveLocalModels(savedLocalModels) }

    /**
     * Deletes an installed catalog model together with its partial download and resume state.
     * Every delete runs on the loader's serial path so it never overlaps a load or unload. The
     * selected model is unloaded first, its selection is cleared and persisted as an explicit
     * none, and no other model is picked in its place; a download finishing later does not
     * re-select on its own. Bookkeeping follows the disk whatever the outcome, and every
     * failure, including a persistence failure, reports on the download error row.
     */
    internal fun deleteDownloadedGemma(model: com.rhymeai.app.ui.components.GemmaDownload) {
        if (gemmaDeletingModel != null || gemmaDownloadingModel?.fileName == model.fileName) return
        val app = getApplication<android.app.Application>()
        val installedFile = java.io.File(app.filesDir, model.fileName)
        gemmaDeletingModel = model
        gemmaDeleteCounts[model.fileName] = (gemmaDeleteCounts[model.fileName] ?: 0) + 1
        gemmaDownloadError = null
        // Only the saved selection counts: localModelPath also names a rejected selection attempt.
        val wasSelected = selectedSavedLocalModel()?.fileName == model.fileName
        val attempt: suspend () -> Unit = {
            try {
                if (wasSelected) {
                    localModelService.unload()
                    savedLocalModelsWriteLock.withLock {
                        repo.saveSelectedLocalModelId(NO_LOCAL_MODEL_SELECTION)
                        // Cleared only once both succeeded, so a failed attempt can be retried whole.
                        localModelPath = null
                        selectedLocalModelId = null
                    }
                }
                try {
                    withContext(Dispatchers.IO) {
                        com.rhymeai.app.ui.components.deleteInstalledGemma(model, app.filesDir, app.cacheDir)
                    }
                } finally {
                    // Whatever was removed, the rows and the saved list follow the disk.
                    gemmaDownloadRevision++
                    if (!installedFile.isFile) {
                        verifiedGemmaFileNames -= model.fileName
                        savedLocalModels = savedLocalModels.filterNot { it.fileName == model.fileName }
                        persistSavedLocalModels()
                    }
                }
            } catch (error: Exception) {
                gemmaLastDownloadAttempt = null
                gemmaDownloadError = "Failed to delete ${model.label}: ${error.message}"
            } finally {
                gemmaDeletingModel = null
            }
        }
        val ticket = if (wasSelected) {
            modelChoiceRevision++
            beginLocalModelChange()
        } else {
            null
        }
        viewModelScope.launch {
            // Queued behind any load or unload and never superseded: a newer selection waits for
            // the delete to finish instead of abandoning it half way.
            withContext(NonCancellable) { localModelOperations.serialized(attempt) }
            if (ticket != null && localModelOperations.isCurrent(ticket)) localModelLoading = false
        }
    }

    fun onBackground() {
        cancelEditorAIWork(keepRewriteTarget = true)
    }
}

/** The song last open in the editor, else the most recently updated one. */
internal fun continueSong(projects: List<SongProject>, lastOpenedId: String?): SongProject? =
    projects.firstOrNull { it.id == lastOpenedId } ?: projects.maxByOrNull { it.updatedAt }
