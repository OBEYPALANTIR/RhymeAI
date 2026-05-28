package com.rhymeai.app

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.foundation.text.input.TextFieldBuffer
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.ui.text.TextRange
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
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.service.AIService
import com.rhymeai.app.service.LocalModelService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

enum class SaveStatus { IDLE, SAVING, SAVED }

data class RhymeContext(
    val targetLine: String?,
    val currentLetter: String,
    val stanzaLines: List<String>,
    val currentLineIndex: Int,
    val currentSection: SongSection = SongSection.UNKNOWN
)

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private companion object {
        private const val AUTOSAVE_DEBOUNCE_MILLIS = 450L
        private const val SAVE_STATUS_VISIBLE_MILLIS = 700L
        val sectionHeaderRegex = Regex("^\\s*\\[.*]\\s*$")
        val sectionHeaderCaptureRegex = Regex("^\\s*\\[(.+)]\\s*$")
    }

    private val repo = ProjectRepository(application)
    private val localModelService = LocalModelService().also {
        it.initialize(application)
    }
    private val aiService = AIService().also { it.localModelService = localModelService }

    // Editor state. The lyrics editor uses the state-based BasicTextField API:
    // it owns text + selection and coordinates selection gestures with scrolling,
    // which the old value-based field did not (long-press over-selected).
    var title by mutableStateOf("")
    val lyricsState = TextFieldState()
    var theme by mutableStateOf("")

    // Last lyrics text the change-observer processed, so programmatic edits
    // (load / apply rewrite / insert suggestion) are not mistaken for user typing.
    private var lastObservedLyrics: String = ""

    val lyrics: String get() = lyricsState.text.toString()
    val cursorPosition: Int
        get() = lyricsState.selection.start.coerceIn(0, lyricsState.text.length)

    // UI state
    var suggestions by mutableStateOf<List<String>>(emptyList())
    var isLoading by mutableStateOf(false)
    var rhymeType by mutableStateOf(RhymeType.PERFECT)
    var rhymeScheme by mutableStateOf(RhymeScheme.AABB)
    var customRhymeScheme by mutableStateOf("")
    var rhymeComplexity by mutableStateOf(RhymeComplexity.MODERATE)
    var useWholeSongContext by mutableStateOf(false)
    var isHighlightEnabled by mutableStateOf(true)
    var isSyllableColoringEnabled by mutableStateOf(true)
    var isStressPreviewEnabled by mutableStateOf(false)
    var isRhymeHighlightEnabled by mutableStateOf(false)

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
    var apiKeys by mutableStateOf(mapOf<String, String>())
    var selectedModel by mutableStateOf(AIModel.DEFAULT)
    var showSettingsDialog by mutableStateOf(false)

    val currentApiKey: String get() = apiKeys[selectedProvider.name] ?: ""

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
    private var suggestionsJob: Job? = null

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

    // Drives the editor's OutputTransformation during an active rewrite: the
    // displayed text shows the preview in place of the selection while the
    // underlying TextFieldState (and `lyrics`) keep the real, unedited text.
    val rewriteOutputRange: TextRange?
        get() = rewriteRange
    val rewriteOutputReplacement: String?
        get() = rewriteRange?.let { rewritePreview ?: rewriteOriginal }

    private var autoSaveJob: Job? = null
    private var trashSchedulerJob: Job? = null

    val activeRhymeScheme: String
        get() = if (rhymeScheme == RhymeScheme.CUSTOM)
            customRhymeScheme.ifEmpty { "AABB" }
        else rhymeScheme.pattern

    init {
        viewModelScope.launch {
            // Load projects
            projects = repo.projectsFlow.first()
            trashedProjects = repo.trashedProjectsFlow.first()
            purgeExpiredTrashedProjects()
            scheduleTrashPurge()
            currentProjectId = repo.currentProjectIdFlow.first()

            // Load API keys, provider, and model
            apiKeys = repo.allApiKeysFlow().first()
            val savedProvider = repo.selectedProviderFlow.first()
            selectedProvider = AIProvider.fromName(savedProvider)
            val savedModelId = repo.modelIdFlow.first()
            if (savedModelId.isNotEmpty()) selectedModel = AIModel.fromId(savedModelId)

            // Load editor state
            val (savedTitle, savedLyrics, savedTheme) = repo.editorStateFlow().first()
            title = savedTitle
            setLyrics(savedLyrics)
            theme = savedTheme

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

        // React to lyrics text/selection changes from the text field. Replaces
        // the old onValueChange callback now that the field mutates state directly.
        viewModelScope.launch {
            snapshotFlow { lyricsState.text.toString() to lyricsState.selection }
                .collect { (text, selection) -> onLyricsStateChanged(text, selection) }
        }
    }

    private fun onLyricsStateChanged(text: String, selection: TextRange) {
        if (hasActiveRewrite) {
            lastObservedLyrics = text
            return
        }
        if (text != lastObservedLyrics) {
            lastObservedLyrics = text
            pendingRewriteRange = null
            triggerAutoSave()
            return
        }

        // Selection-only change: maintain the "select to rhyme" pending range.
        if (!selection.collapsed) {
            val start = selection.min.coerceIn(0, text.length)
            val end = selection.max.coerceIn(0, text.length)
            val selectedText = if (start < end) text.substring(start, end) else ""
            pendingRewriteRange = if (start < end && selectedText.isNotBlank()) {
                TextRange(start, end)
            } else {
                null
            }
        } else {
            pendingRewriteRange?.let { pendingRange ->
                if (selection.start != pendingRange.min && selection.start != pendingRange.max) {
                    pendingRewriteRange = null
                }
            }
        }
    }

    fun computeRhymeContext(): RhymeContext {
        val text = lyrics
        val scheme = activeRhymeScheme
        if (text.isEmpty()) {
            return RhymeContext(null, scheme.firstOrNull()?.toString() ?: "A", emptyList(), 0)
        }

        val pos = cursorPosition.coerceIn(0, text.length)
        val currentSection = currentSongSection(text, pos)
        val textBefore = text.substring(0, pos)
        val textAfter = text.substring(pos)

        // Find stanza boundaries
        val lastDoubleNewline = textBefore.lastIndexOf("\n\n")
        val stanzaStart = if (lastDoubleNewline == -1) 0 else lastDoubleNewline + 2

        val nextDoubleNewline = textAfter.indexOf("\n\n")
        val stanzaEnd = if (nextDoubleNewline == -1) text.length else pos + nextDoubleNewline

        val currentStanza = text.substring(stanzaStart, stanzaEnd)
        val stanzaLines = currentStanza.split("\n")

        // Determine which raw line the cursor is on
        val stanzaTextBefore = textBefore.substring(stanzaStart)
        val rawCursorLineIndex = stanzaTextBefore.split("\n").size - 1

        // Find the lyric-line position of the cursor line
        // Count how many non-header lines are at or before the cursor
        val lyricLinePos = stanzaLines.take(rawCursorLineIndex + 1).count { line ->
            !sectionHeaderRegex.matches(line) && line.isNotBlank()
        } - 1
        val effectiveLineIndex = maxOf(lyricLinePos, 0)

        val schemeLetters = scheme.toList()
        if (schemeLetters.isEmpty()) {
            return RhymeContext(null, "A", stanzaLines, rawCursorLineIndex, currentSection)
        }

        val currentLetter = schemeLetters[effectiveLineIndex % schemeLetters.size].toString()

        // Find previous lyric line with the same scheme letter
        var targetLine: String? = null
        var lyricCount = 0
        for (i in stanzaLines.indices) {
            if (i >= rawCursorLineIndex) break
            val line = stanzaLines[i].trim()
            if (sectionHeaderRegex.matches(line) || line.isEmpty()) continue
            val letterForThis = schemeLetters[lyricCount % schemeLetters.size].toString()
            if (letterForThis == currentLetter && line.isNotEmpty()) {
                targetLine = line
            }
            lyricCount++
        }

        return RhymeContext(targetLine, currentLetter, stanzaLines, rawCursorLineIndex, currentSection)
    }

    private fun currentSongSection(text: String, cursor: Int): SongSection {
        val textBeforeCursor = text.take(cursor.coerceIn(0, text.length))
        val header = textBeforeCursor
            .lineSequence()
            .mapNotNull { sectionHeaderCaptureRegex.matchEntire(it)?.groupValues?.getOrNull(1) }
            .lastOrNull()
        return header?.let(SongSection::fromHeader) ?: SongSection.UNKNOWN
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
                aiService.streamSuggestions(
                    selectedProvider, currentApiKey, selectedModel.id, theme, lyrics, context.targetLine,
                    rhymeType, activeRhymeScheme, context.currentLetter, context.currentSection, rhymeComplexity, useWholeSongContext
                ).collect { line ->
                    suggestions = suggestions + line
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

    fun requestRewrite(action: RewriteAction) {
        val selection = pendingRewriteRange ?: lyricsState.selection
        val start = selection.min.coerceIn(0, lyrics.length)
        val end = selection.max.coerceIn(0, lyrics.length)
        if (start >= end) return
        val original = lyrics.substring(start, end)
        if (original.isBlank()) {
            clearPendingRewriteSelection()
            return
        }

        beginRewrite(action, TextRange(start, end), original)
    }

    fun retryRewrite() {
        val action = rewriteAction ?: return
        val range = rewriteRange ?: return
        val original = rewriteOriginal ?: return
        beginRewrite(action, range, original)
    }

    private fun beginRewrite(action: RewriteAction, range: TextRange, original: String) {
        rewriteJob?.cancel()
        pendingRewriteRange = null
        rewriteAction = action
        rewriteOriginal = original
        rewriteRange = range
        rewritePreview = null
        rewriteError = null
        rewriteLoading = true
        val fullLyrics = lyrics
        val currentSection = currentSongSection(fullLyrics, range.min)

        rewriteJob = viewModelScope.launch {
            try {
                val result = aiService.getRewrite(
                    provider = selectedProvider,
                    apiKey = currentApiKey,
                    modelId = selectedModel.id,
                    action = action,
                    fullLyrics = fullLyrics,
                    selection = original,
                    currentSection = currentSection
                )
                rewritePreview = result
            } catch (e: Exception) {
                rewriteError = e.message ?: "Rewrite failed"
            } finally {
                rewriteLoading = false
            }
        }
    }

    fun applyRewrite() {
        val preview = rewritePreview ?: return
        val range = rewriteRange ?: return
        val text = lyrics
        if (range.start > text.length || range.end > text.length) {
            dismissRewrite()
            return
        }
        if (rewriteOriginal != null && text.substring(range.min, range.max) != rewriteOriginal) {
            dismissRewrite()
            return
        }
        val before = text.substring(0, range.start)
        val after = text.substring(range.end)
        val newText = before + preview + after
        val newCursor = (range.start + preview.length).coerceAtMost(newText.length)
        dismissRewrite()
        setLyrics(newText, newCursor)
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
        setLyrics(newText, newPos)
        suggestions = emptyList()
        triggerAutoSave()
    }

    fun newProject() {
        title = ""
        setLyrics("")
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
        title = project.title
        setLyrics(project.lyrics)
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
        }
        scheduleTrashPurge()
    }

    fun purgeExpiredTrashedProjects() {
        val now = System.currentTimeMillis()
        val retainedProjects = trashedProjects.filter { it.deleteAfter > now }
        if (retainedProjects.size != trashedProjects.size) {
            trashedProjects = retainedProjects
            viewModelScope.launch {
                repo.saveTrashedProjects(retainedProjects)
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
        title = ""
        setLyrics("")
        theme = ""
        currentProjectId = null
        suggestions = emptyList()
        errorMessage = null
        saveStatus = SaveStatus.IDLE
    }

    fun importProject(imported: SongProject) {
        val newId = java.util.UUID.randomUUID().toString()
        val project = imported.copy(
            id = newId,
            title = imported.title.ifBlank { "Imported Song" },
            updatedAt = System.currentTimeMillis()
        )
        projects = listOf(project) + projects
        title = project.title
        setLyrics(project.lyrics)
        theme = project.theme
        currentProjectId = project.id
        suggestions = emptyList()
        showProjectsDialog = false
        showStartMenu = false
        viewModelScope.launch {
            repo.saveProjects(projects)
            repo.setCurrentProjectId(project.id)
            repo.saveEditorState(project.title, project.lyrics, project.theme)
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

    fun applyTemplate(name: String, templateTheme: String, templateLyrics: String) {
        title = "Untitled $name"
        theme = templateTheme
        setLyrics(templateLyrics)
        currentProjectId = null
        showTemplatesDialog = false
        showStartMenu = false
        triggerAutoSave()
    }

    fun triggerAutoSave() {
        autoSaveJob?.cancel()
        autoSaveJob = viewModelScope.launch {
            val currentTitle = title
            val currentLyrics = lyrics
            val currentTheme = theme

            if (currentTitle.isEmpty() && currentLyrics.isEmpty() && currentTheme.isEmpty()) {
                saveStatus = SaveStatus.IDLE
                return@launch
            }

            delay(AUTOSAVE_DEBOUNCE_MILLIS)
            saveStatus = SaveStatus.SAVING

            val projectId = currentProjectId
            val updatedProjectId: String
            val updatedProjects = if (projectId == null) {
                val newId = java.util.UUID.randomUUID().toString()
                val newProject = SongProject(
                    id = newId,
                    title = currentTitle.ifEmpty { "Untitled Song" },
                    lyrics = currentLyrics,
                    theme = currentTheme,
                    updatedAt = System.currentTimeMillis()
                )
                updatedProjectId = newId
                listOf(newProject) + projects
            } else {
                updatedProjectId = projectId
                projects.map {
                    if (it.id == projectId) it.copy(
                        title = currentTitle.ifEmpty { "Untitled Song" },
                        lyrics = currentLyrics,
                        theme = currentTheme,
                        updatedAt = System.currentTimeMillis()
                    ) else it
                }
            }

            projects = updatedProjects
            currentProjectId = updatedProjectId

            repo.saveProjects(updatedProjects)
            repo.setCurrentProjectId(updatedProjectId)
            repo.saveEditorState(currentTitle, currentLyrics, currentTheme)

            delay(SAVE_STATUS_VISIBLE_MILLIS)
            saveStatus = SaveStatus.SAVED
        }
    }

    fun onTitleChanged(newTitle: String) {
        title = newTitle
        triggerAutoSave()
    }

    // Programmatically replaces the editor text and places the cursor. Updates
    // lastObservedLyrics first so the change-observer treats this as a
    // programmatic edit (no autosave / pending-rewrite side effects); callers
    // that need a save (apply rewrite, insert, template) call triggerAutoSave.
    private fun setLyrics(text: String, cursor: Int = 0) {
        lastObservedLyrics = text
        pendingRewriteRange = null
        lyricsState.edit {
            replace(0, this.length, text)
            placeCursorAt(cursor)
        }
    }

    private fun TextFieldBuffer.placeCursorAt(offset: Int) {
        when {
            this.length == 0 -> placeCursorAtEnd()
            offset <= 0 -> placeCursorBeforeCharAt(0)
            offset >= this.length -> placeCursorAtEnd()
            else -> placeCursorBeforeCharAt(offset)
        }
    }

    fun clearPendingRewriteSelection() {
        pendingRewriteRange = null
        val selection = lyricsState.selection
        if (!selection.collapsed) {
            lyricsState.edit { placeCursorAt(selection.max) }
        }
    }

    fun onThemeChanged(newTheme: String) {
        theme = newTheme
        triggerAutoSave()
    }

    fun goToStartMenu() {
        showStartMenu = true
    }

    fun saveApiKey(provider: AIProvider, key: String) {
        apiKeys = apiKeys + (provider.name to key)
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
