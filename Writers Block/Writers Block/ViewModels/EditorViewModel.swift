import Combine
import Foundation
import SwiftData
import SwiftUI

enum SaveStatus {
    case idle, saving, saved
}

final class EditorViewModel: ObservableObject {

    // MARK: - Editor State

    @Published var title: String = ""
    @Published var lyrics: String = ""
    @Published var theme: String = ""
    @Published var cursorPosition: Int = 0

    // MARK: - AI State

    @Published var suggestions: [String] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Rhyme Settings

    @Published var rhymeType: RhymeType = .perfect
    @Published var rhymeScheme: RhymeScheme = .aabb
    @Published var customRhymeScheme: String = ""
    @Published var rhymeComplexity: RhymeComplexity = .moderate
    @Published var useWholeSongContext: Bool = false
    @Published var isHighlightEnabled: Bool = true
    @Published var isSyllableColoringEnabled: Bool = true
    @Published var isContextExpanded: Bool = false

    // MARK: - Navigation

    @Published var showWelcome: Bool = true
    @Published var showProjectsSheet: Bool = false
    @Published var showTemplatesSheet: Bool = false
    @Published var showSettingsSheet: Bool = false
    @Published var showAssistantSheet: Bool = false

    // MARK: - Project Management

    @Published var currentProjectId: String?
    @Published var saveStatus: SaveStatus = .idle

    // MARK: - Settings

    @Published var selectedProvider: AIProvider = .gemini
    @Published var selectedModel: AIModel = .default
    @Published var apiKeys: [String: String] = [:]

    // MARK: - Internal

    var modelContext: ModelContext?
    private let aiService = AIService()
    private var autoSaveTask: Task<Void, Never>?

    // MARK: - Computed

    var activeRhymeScheme: String {
        if rhymeScheme == .custom {
            return customRhymeScheme.isEmpty ? "AABB" : customRhymeScheme
        }
        return rhymeScheme.pattern
    }

    var currentApiKey: String {
        apiKeys[selectedProvider.rawValue] ?? ""
    }

    var wordCount: Int {
        SyllableCounter.wordCount(lyrics)
    }

    var syllableCount: Int {
        SyllableCounter.countText(lyrics)
    }

    // MARK: - Init

    init() {
        let providerRaw = UserDefaults.standard.string(forKey: "selectedProvider") ?? AIProvider.gemini.rawValue
        selectedProvider = AIProvider(rawValue: providerRaw) ?? .gemini
        let modelRaw = UserDefaults.standard.string(forKey: "selectedModel") ?? AIModel.default.rawValue
        selectedModel = AIModel(rawValue: modelRaw) ?? .default

        for provider in AIProvider.allCases {
            apiKeys[provider.rawValue] = UserDefaults.standard.string(forKey: "apiKey_\(provider.rawValue)") ?? ""
        }
    }

    // MARK: - Rhyme Context

    func computeRhymeContext() -> RhymeContext {
        guard !lyrics.isEmpty else {
            return RhymeContext(
                targetLine: nil,
                currentLetter: String(activeRhymeScheme.first ?? Character("A")),
                stanzaLines: [],
                currentLineIndex: 0
            )
        }

        let pos = min(cursorPosition, lyrics.count)
        let textIndex = lyrics.index(lyrics.startIndex, offsetBy: pos)
        let textBeforeCursor = String(lyrics[lyrics.startIndex..<textIndex])
        let textAfterCursor = String(lyrics[textIndex..<lyrics.endIndex])

        // Find stanza boundaries (double newline)
        let stanzaStart: String.Index
        if let range = textBeforeCursor.range(of: "\n\n", options: .backwards) {
            stanzaStart = lyrics.index(range.upperBound, offsetBy: 0, limitedBy: lyrics.endIndex) ?? lyrics.startIndex
        } else {
            stanzaStart = lyrics.startIndex
        }

        let stanzaEnd: String.Index
        if let range = textAfterCursor.range(of: "\n\n") {
            let offset = textAfterCursor.distance(from: textAfterCursor.startIndex, to: range.lowerBound)
            stanzaEnd = lyrics.index(textIndex, offsetBy: offset, limitedBy: lyrics.endIndex) ?? lyrics.endIndex
        } else {
            stanzaEnd = lyrics.endIndex
        }

        let currentStanza = String(lyrics[stanzaStart..<stanzaEnd])
        let stanzaLines = currentStanza.components(separatedBy: "\n")

        // Determine current line index within stanza
        let stanzaTextBeforeCursor = String(lyrics[stanzaStart..<textIndex])
        let currentLineIndex = stanzaTextBeforeCursor.components(separatedBy: "\n").count - 1

        let schemeLetters = Array(activeRhymeScheme)
        guard !schemeLetters.isEmpty else {
            return RhymeContext(targetLine: nil, currentLetter: "A", stanzaLines: stanzaLines, currentLineIndex: currentLineIndex)
        }

        let currentLetter = String(schemeLetters[currentLineIndex % schemeLetters.count])

        // Find previous line in stanza with same scheme letter
        var targetLine: String?
        for i in stride(from: currentLineIndex - 1, through: 0, by: -1) {
            let letter = String(schemeLetters[i % schemeLetters.count])
            if letter == currentLetter {
                let line = stanzaLines[i].trimmingCharacters(in: .whitespaces)
                // Skip section headers like [Verse 1]
                if !line.isEmpty && !line.hasPrefix("[") {
                    targetLine = line
                    break
                }
            }
        }

        return RhymeContext(
            targetLine: targetLine,
            currentLetter: currentLetter,
            stanzaLines: stanzaLines,
            currentLineIndex: currentLineIndex
        )
    }

    // MARK: - AI Suggestions

    func getSuggestions() {
        guard !lyrics.isEmpty else { return }
        let context = computeRhymeContext()
        isLoading = true
        errorMessage = nil
        suggestions = []

        Task { @MainActor in
            do {
                let results = try await aiService.getSuggestions(
                    provider: selectedProvider,
                    apiKey: currentApiKey,
                    modelId: selectedModel.id,
                    theme: theme,
                    lyrics: lyrics,
                    targetRhymeLine: context.targetLine,
                    rhymeType: rhymeType,
                    rhymeScheme: activeRhymeScheme,
                    currentLetter: context.currentLetter,
                    complexity: rhymeComplexity,
                    useWholeSongContext: useWholeSongContext
                )
                self.suggestions = results
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    // MARK: - Suggestion Insertion

    func insertSuggestion(_ suggestion: String) {
        let pos = min(cursorPosition, lyrics.count)
        let beforeIndex = lyrics.index(lyrics.startIndex, offsetBy: pos)
        let before = String(lyrics[lyrics.startIndex..<beforeIndex])
        let after = String(lyrics[beforeIndex..<lyrics.endIndex])

        let needsNewline = !before.isEmpty && !before.hasSuffix("\n")
        let insertText = (needsNewline ? "\n" : "") + suggestion + "\n"

        lyrics = before + insertText + after
        cursorPosition = pos + insertText.count
        suggestions = []
        triggerAutoSave()
    }

    // MARK: - Project Management

    func newProject() {
        title = ""
        lyrics = ""
        theme = ""
        cursorPosition = 0
        currentProjectId = nil
        suggestions = []
        errorMessage = nil
        saveStatus = .idle
        showWelcome = false
        showProjectsSheet = false
    }

    func loadProject(_ project: SongProject) {
        title = project.title
        lyrics = project.lyrics
        theme = project.theme
        cursorPosition = 0
        currentProjectId = project.id
        suggestions = []
        errorMessage = nil
        saveStatus = .idle
        showWelcome = false
        showProjectsSheet = false
    }

    func deleteProject(_ project: SongProject) {
        guard let context = modelContext else { return }
        if currentProjectId == project.id {
            currentProjectId = nil
        }
        context.delete(project)
        try? context.save()
    }

    func applyTemplate(_ template: SongTemplate) {
        title = "Untitled \(template.name)"
        theme = template.theme
        lyrics = template.lyrics
        cursorPosition = 0
        currentProjectId = nil
        suggestions = []
        saveStatus = .idle
        showWelcome = false
        showTemplatesSheet = false
        triggerAutoSave()
    }

    func goToStartMenu() {
        showWelcome = true
    }

    // MARK: - Auto-Save

    func triggerAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !title.isEmpty || !lyrics.isEmpty || !theme.isEmpty else {
                saveStatus = .idle
                return
            }
            saveStatus = .saving

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            guard let context = modelContext else { return }

            if let projectId = currentProjectId {
                let descriptor = FetchDescriptor<SongProject>(
                    predicate: #Predicate<SongProject> { $0.id == projectId }
                )
                if let existing = try? context.fetch(descriptor).first {
                    existing.title = title.isEmpty ? "Untitled Song" : title
                    existing.lyrics = lyrics
                    existing.theme = theme
                    existing.updatedAt = Date()
                }
            } else {
                let project = SongProject(
                    title: title.isEmpty ? "Untitled Song" : title,
                    lyrics: lyrics,
                    theme: theme
                )
                context.insert(project)
                currentProjectId = project.id
            }

            try? context.save()
            saveStatus = .saved
        }
    }

    // MARK: - Settings

    func saveApiKey(provider: AIProvider, key: String) {
        apiKeys[provider.rawValue] = key
        UserDefaults.standard.set(key, forKey: "apiKey_\(provider.rawValue)")
    }

    func saveProvider(_ provider: AIProvider) {
        selectedProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider")
        if selectedModel.provider != provider {
            if let first = AIModel.models(for: provider).first {
                saveModel(first)
            }
        }
    }

    func saveModel(_ model: AIModel) {
        selectedModel = model
        UserDefaults.standard.set(model.rawValue, forKey: "selectedModel")
    }
}
