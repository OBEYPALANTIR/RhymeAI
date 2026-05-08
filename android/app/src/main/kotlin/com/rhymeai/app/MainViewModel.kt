package com.rhymeai.app

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeScheme
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.data.model.SongProject
import com.rhymeai.app.data.repository.ProjectRepository
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.service.AIProvider
import com.rhymeai.app.service.AIService
import com.rhymeai.app.service.LocalModelService
import com.rhymeai.app.service.ModelDownloader
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

enum class SaveStatus { IDLE, SAVING, SAVED }

data class RhymeContext(
    val targetLine: String?,
    val currentLetter: String,
    val stanzaLines: List<String>,
    val currentLineIndex: Int
)

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private companion object {
        val sectionHeaderRegex = Regex("^\\s*\\[.*]\\s*$")
    }

    private val repo = ProjectRepository(application)
    private val localModelService = LocalModelService().also {
        it.initialize(application)
    }
    private val aiService = AIService().also { it.localModelService = localModelService }
    private val modelDownloader = ModelDownloader(application)

    // Editor state
    var title by mutableStateOf("")
    var lyricsFieldValue by mutableStateOf(TextFieldValue(""))
    var theme by mutableStateOf("")

    val lyrics: String get() = lyricsFieldValue.text
    val cursorPosition: Int get() = lyricsFieldValue.selection.start

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

    // Project management
    var projects by mutableStateOf<List<SongProject>>(emptyList())
    var currentProjectId by mutableStateOf<String?>(null)
    var saveStatus by mutableStateOf(SaveStatus.IDLE)
    var showProjectsDialog by mutableStateOf(false)
    var showTemplatesDialog by mutableStateOf(false)
    var showStartMenu by mutableStateOf(true)

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

    // Featured-model download state, mirrored from ModelDownloader
    var downloadState by mutableStateOf<ModelDownloader.State>(ModelDownloader.State.Idle)
    var pendingMeteredModel by mutableStateOf<ModelDownloader.FeaturedModel?>(null)
    val featuredModels: List<ModelDownloader.FeaturedModel> = ModelDownloader.FeaturedModel.entries

    // Error state
    var errorMessage by mutableStateOf<String?>(null)

    private var autoSaveJob: Job? = null

    val activeRhymeScheme: String
        get() = if (rhymeScheme == RhymeScheme.CUSTOM)
            customRhymeScheme.ifEmpty { "AABB" }
        else rhymeScheme.pattern

    init {
        viewModelScope.launch {
            modelDownloader.state.collect { state ->
                downloadState = state
                if (state is ModelDownloader.State.Complete) {
                    loadLocalModel(state.filePath)
                }
            }
        }
        viewModelScope.launch {
            // Load projects
            projects = repo.projectsFlow.first()
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
            lyricsFieldValue = TextFieldValue(savedLyrics)
            theme = savedTheme

            // Always show start menu on fresh launch
            showStartMenu = true

            // Observe project changes
            launch {
                repo.projectsFlow.collect { projects = it }
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
            return RhymeContext(null, "A", stanzaLines, rawCursorLineIndex)
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

        return RhymeContext(targetLine, currentLetter, stanzaLines, rawCursorLineIndex)
    }

    fun getSuggestions() {
        if (lyrics.isEmpty()) return
        val context = computeRhymeContext()
        isLoading = true
        errorMessage = null
        viewModelScope.launch {
            try {
                val results = aiService.getSuggestions(
                    selectedProvider, currentApiKey, selectedModel.id, theme, lyrics, context.targetLine,
                    rhymeType, activeRhymeScheme, context.currentLetter, rhymeComplexity, useWholeSongContext
                )
                suggestions = results
            } catch (e: Exception) {
                errorMessage = e.message ?: "Failed to get suggestions"
            } finally {
                isLoading = false
            }
        }
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

    fun deleteProject(id: String) {
        projects = projects.filter { it.id != id }
        if (currentProjectId == id) currentProjectId = null
        viewModelScope.launch {
            repo.saveProjects(projects)
            if (currentProjectId == null) repo.setCurrentProjectId(null)
        }
    }

    fun applyTemplate(name: String, templateTheme: String, templateLyrics: String) {
        title = "Untitled $name"
        theme = templateTheme
        lyricsFieldValue = TextFieldValue(templateLyrics)
        currentProjectId = null
        showTemplatesDialog = false
        showStartMenu = false
        triggerAutoSave()
    }

    fun triggerAutoSave() {
        autoSaveJob?.cancel()
        autoSaveJob = viewModelScope.launch {
            if (title.isEmpty() && lyrics.isEmpty() && theme.isEmpty()) {
                saveStatus = SaveStatus.IDLE
                return@launch
            }

            saveStatus = SaveStatus.SAVING

            // Create or update project
            if (currentProjectId == null) {
                val newId = java.util.UUID.randomUUID().toString()
                val newProject = SongProject(
                    id = newId,
                    title = title.ifEmpty { "Untitled Song" },
                    lyrics = lyrics,
                    theme = theme,
                    updatedAt = System.currentTimeMillis()
                )
                projects = listOf(newProject) + projects
                currentProjectId = newId
            } else {
                projects = projects.map {
                    if (it.id == currentProjectId) it.copy(
                        title = title.ifEmpty { "Untitled Song" },
                        lyrics = lyrics,
                        theme = theme,
                        updatedAt = System.currentTimeMillis()
                    ) else it
                }
            }

            repo.saveProjects(projects)
            repo.setCurrentProjectId(currentProjectId)
            repo.saveEditorState(title, lyrics, theme)

            delay(1000)
            saveStatus = SaveStatus.SAVED
        }
    }

    fun onTitleChanged(newTitle: String) {
        title = newTitle
        triggerAutoSave()
    }

    fun onLyricsChanged(newValue: TextFieldValue) {
        lyricsFieldValue = newValue
        triggerAutoSave()
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

    fun requestFeaturedDownload(model: ModelDownloader.FeaturedModel) {
        if (modelDownloader.isOnUnmeteredNetwork()) {
            startFeaturedDownload(model, allowMetered = false)
        } else {
            // Defer to UI: show "this will use ~X MB of mobile data" confirm.
            pendingMeteredModel = model
        }
    }

    fun confirmMeteredDownload() {
        val model = pendingMeteredModel ?: return
        pendingMeteredModel = null
        startFeaturedDownload(model, allowMetered = true)
    }

    fun cancelMeteredPrompt() {
        pendingMeteredModel = null
    }

    fun cancelDownload() {
        modelDownloader.cancelDownload()
    }

    fun dismissDownloadResult() {
        modelDownloader.reset()
    }

    private fun startFeaturedDownload(
        model: ModelDownloader.FeaturedModel,
        allowMetered: Boolean
    ) {
        localModelError = null
        modelDownloader.startDownload(model, allowMetered)
    }
}
