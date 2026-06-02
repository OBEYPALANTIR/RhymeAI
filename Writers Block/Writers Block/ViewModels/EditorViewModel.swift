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
    @Published var lyrics: String = "" {
        didSet {
            refreshLyricsDerivedState()
        }
    }
    @Published var theme: String = ""
    @Published var cursorPosition: Int = 0 {
        didSet {
            refreshRhymeContext()
        }
    }

    // MARK: - AI State

    @Published var suggestions: [String] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Rhyme Settings

    @Published var rhymeType: RhymeType = .perfect
    @Published var rhymeScheme: RhymeScheme = .aabb {
        didSet {
            refreshRhymeContext()
        }
    }
    @Published var customRhymeScheme: String = "" {
        didSet {
            refreshRhymeContext()
        }
    }
    @Published var rhymeComplexity: RhymeComplexity = .moderate
    @Published var useWholeSongContext: Bool = false
    @Published var isHighlightEnabled: Bool = true
    @Published var isSyllableColoringEnabled: Bool = true
    @Published var isStressPreviewEnabled: Bool = false
    @Published var isRhymeHighlightEnabled: Bool = false

    // MARK: - Selection / Rewrite

    @Published var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @Published var rewriteAction: RewriteAction?
    @Published var rewriteLoading: Bool = false
    @Published var rewritePreview: String?
    @Published var rewriteOriginal: String?
    @Published var rewriteError: String?
    private var rewriteRange: NSRange?
    private var rewriteTask: Task<Void, Never>?
    private var suggestionsTask: Task<Void, Never>?

    // MARK: - Word Inspector

    @Published var inspectorWord: String?
    @Published var inspectorRange: NSRange?
    @Published var inspectorProsody: WordProsody?
    @Published var inspectorMatches: RhymeMatches?
    @Published var inspectorSynonyms: [String] = []
    @Published var inspectorSynonymsLoading: Bool = false
    @Published var inspectorSynonymsError: String?
    private var inspectorSynonymsTask: Task<Void, Never>?

    var showInspector: Bool { inspectorWord != nil }

    var singleWordSelection: (word: String, range: NSRange)? {
        let range = selectedRange
        guard range.length > 0 else { return nil }
        let ns = lyrics as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return nil }
        let word = ns.substring(with: range)
        guard word.count >= 2 else { return nil }
        for ch in word {
            if !ch.isLetter, ch != "'" { return nil }
        }
        return (word, range)
    }

    // MARK: - Export

    @Published var showExportSheet: Bool = false

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
    /// Surfaces whether each provider has any key stored. The actual key values
    /// never live in observable state — they are pulled from the Keychain on
    /// demand at request time so they cannot leak via heap dumps, SwiftUI
    /// snapshots, or test fixtures.
    @Published private(set) var apiKeyPresence: [String: Bool] = [:]

    // MARK: - Internal

    var modelContext: ModelContext? {
        didSet {
            purgeExpiredTrashedProjects()
            seedTrashProjectForUITestsIfNeeded()
        }
    }
    private let aiService = AIService()
    private let keychainStore: KeychainStore
    private var autoSaveTask: Task<Void, Never>?
    private var trashSchedulerTask: Task<Void, Never>?
    private var didSeedTrashProjectForUITests = false

    private(set) var wordCount: Int = 0
    private(set) var syllableCount: Int = 0
    private(set) lazy var rhymeContext = RhymeContext.emptyContext(currentLetter: String(activeRhymeScheme.first ?? Character("A")))

    // MARK: - Computed

    var activeRhymeScheme: String {
        if rhymeScheme == .custom {
            return customRhymeScheme.isEmpty ? "AABB" : customRhymeScheme
        }
        return rhymeScheme.pattern
    }

    var currentApiKey: String {
        apiKey(for: selectedProvider)
    }

    func apiKey(for provider: AIProvider) -> String {
        let storedKey = keychainStore.getKey(provider: provider.rawValue)
        guard storedKey.isEmpty, provider == .gemini else {
            return storedKey
        }

        #if DEBUG
        return ProcessInfo.processInfo.environment["GEMINI_TEST_KEY"] ?? ""
        #else
        return ""
        #endif
    }

    func hasApiKey(for provider: AIProvider) -> Bool {
        apiKeyPresence[provider.rawValue] ?? false
    }

    var hasActiveRewrite: Bool {
        rewriteAction != nil
    }

    var canApplyRewrite: Bool {
        rewritePreview != nil && !rewriteLoading
    }

    var inlineRewriteText: String {
        guard hasActiveRewrite,
              let range = rewriteRange,
              let replacement = rewritePreview ?? rewriteOriginal else {
            return lyrics
        }

        let ns = lyrics as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else {
            return lyrics
        }

        return ns.replacingCharacters(in: range, with: replacement)
    }

    var inlineRewriteRange: NSRange? {
        guard hasActiveRewrite,
              let range = rewriteRange,
              let replacement = rewritePreview ?? rewriteOriginal else {
            return nil
        }

        let displayLength = (inlineRewriteText as NSString).length
        let replacementLength = (replacement as NSString).length
        guard range.location >= 0, range.location + replacementLength <= displayLength else {
            return nil
        }

        return NSRange(location: range.location, length: replacementLength)
    }

    // MARK: - Init

    init(keychainStore: KeychainStore? = nil) {
        let runningUITestInMemory = ProcessInfo.processInfo.arguments.contains("--ui-test-in-memory-store")
        let resolvedStore: KeychainStore = keychainStore
            ?? (runningUITestInMemory ? InMemoryKeychainStore() : SystemKeychainStore())
        self.keychainStore = resolvedStore

        #if DEBUG
        if runningUITestInMemory,
           let geminiTestKey = ProcessInfo.processInfo.environment["GEMINI_TEST_KEY"],
           !geminiTestKey.isEmpty,
           resolvedStore.getKey(provider: AIProvider.gemini.rawValue).isEmpty {
            resolvedStore.setKey(provider: AIProvider.gemini.rawValue, key: geminiTestKey)
        }
        #endif

        let providerRaw = UserDefaults.standard.string(forKey: "selectedProvider") ?? AIProvider.gemini.rawValue
        selectedProvider = AIProvider(rawValue: providerRaw) ?? .gemini
        let modelRaw = UserDefaults.standard.string(forKey: "selectedModel") ?? AIModel.default.rawValue
        if let savedModel = AIModel(rawValue: modelRaw), savedModel.provider == selectedProvider {
            selectedModel = savedModel
        } else {
            selectedModel = AIModel.models(for: selectedProvider).first ?? .default
        }

        _ = ApiKeyMigration.apply(legacyDefaults: .standard, secure: resolvedStore)
        let secured = resolvedStore.allKeys()
        for provider in AIProvider.allCases {
            apiKeyPresence[provider.rawValue] = (secured[provider.rawValue] ?? "").isEmpty == false
        }

        if ProcessInfo.processInfo.arguments.contains("--ui-test-seed-prosody-song") {
            let seededLyrics = "[Verse]\nyellow music\nfollow music\nmellow music"
            title = "UI Prosody Song"
            lyrics = seededLyrics
            positionSeededProsodyCursorForUITests()
            isStressPreviewEnabled = ProcessInfo.processInfo.arguments.contains("--ui-test-enable-stress-preview")
            showWelcome = false
            showAssistantSheet = ProcessInfo.processInfo.arguments.contains("--ui-test-open-assistant")
        }

        if ProcessInfo.processInfo.arguments.contains("--ui-test-seed-rewrite-selection") {
            let seededLyrics = "yellow music\nfollow music"
            title = "UI Rewrite Song"
            lyrics = seededLyrics
            selectedRange = NSRange(location: 0, length: ("yellow music" as NSString).length)
            cursorPosition = selectedRange.location + selectedRange.length
            showWelcome = false
        }
    }

    deinit {
        trashSchedulerTask?.cancel()
    }

    // MARK: - Rhyme Context

    private func refreshLyricsDerivedState() {
        wordCount = SyllableCounter.wordCount(lyrics)
        syllableCount = SyllableCounter.countText(lyrics)
        refreshRhymeContext()
    }

    private func refreshRhymeContext() {
        rhymeContext = computeRhymeContext()
    }

    func computeRhymeContext() -> RhymeContext {
        guard !lyrics.isEmpty else {
            return RhymeContext.emptyContext(currentLetter: String(activeRhymeScheme.first ?? Character("A")))
        }

        let pos = min(max(cursorPosition, 0), lyrics.count)
        let currentSection = currentSongSection(in: lyrics, cursorPosition: pos)
        let textIndex = lyrics.index(lyrics.startIndex, offsetBy: pos)
        let textBeforeCursor = String(lyrics.prefix(pos))
        let textAfterCursor = String(lyrics.suffix(lyrics.count - pos))

        let stanzaStartOffset: Int
        if let range = textBeforeCursor.range(of: "\n\n", options: .backwards) {
            stanzaStartOffset = textBeforeCursor.distance(from: textBeforeCursor.startIndex, to: range.upperBound)
        } else {
            stanzaStartOffset = 0
        }

        let stanzaEndOffset: Int
        if let range = textAfterCursor.range(of: "\n\n") {
            stanzaEndOffset = pos + textAfterCursor.distance(from: textAfterCursor.startIndex, to: range.lowerBound)
        } else {
            stanzaEndOffset = lyrics.count
        }

        let stanzaStart = lyrics.index(lyrics.startIndex, offsetBy: stanzaStartOffset)
        let stanzaEnd = lyrics.index(lyrics.startIndex, offsetBy: stanzaEndOffset)

        let currentStanza = String(lyrics[stanzaStart..<stanzaEnd])
        let stanzaLines = currentStanza.components(separatedBy: "\n")

        // Determine the raw cursor line, then map only real lyric lines to the rhyme scheme.
        let stanzaTextBeforeCursor = String(lyrics[stanzaStart..<textIndex])
        let rawCursorLineIndex = stanzaTextBeforeCursor.components(separatedBy: "\n").count - 1
        let lyricLinePosition = stanzaLines.prefix(rawCursorLineIndex + 1).filter { line in
            !isSectionHeader(line) && !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count - 1
        let effectiveLineIndex = max(lyricLinePosition, 0)

        let schemeLetters = Array(activeRhymeScheme)
        guard !schemeLetters.isEmpty else {
            return RhymeContext(targetLine: nil, currentLetter: "A", stanzaLines: stanzaLines, currentLineIndex: rawCursorLineIndex, currentSection: currentSection)
        }

        let currentLetter = String(schemeLetters[effectiveLineIndex % schemeLetters.count])

        var targetLine: String?
        var lyricCount = 0
        for i in stanzaLines.indices {
            if i >= rawCursorLineIndex { break }

            let line = stanzaLines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if isSectionHeader(line) || line.isEmpty { continue }

            let letter = String(schemeLetters[lyricCount % schemeLetters.count])
            if letter == currentLetter {
                targetLine = line
            }
            lyricCount += 1
        }

        return RhymeContext(
            targetLine: targetLine,
            currentLetter: currentLetter,
            stanzaLines: stanzaLines,
            currentLineIndex: rawCursorLineIndex,
            currentSection: currentSection
        )
    }

    private func currentSongSection(in lyrics: String, cursorPosition: Int) -> SongSection {
        let safePosition = min(max(cursorPosition, 0), lyrics.count)
        let textBeforeCursor = String(lyrics.prefix(safePosition))
        let header = textBeforeCursor
            .components(separatedBy: "\n")
            .compactMap(sectionHeaderTitle)
            .last
        return header.map(SongSection.fromHeader) ?? .unknown
    }

    private func isSectionHeader(_ line: String) -> Bool {
        sectionHeaderTitle(line) != nil
    }

    private func sectionHeaderTitle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    // MARK: - AI Suggestions

    func getSuggestions() {
        guard !lyrics.isEmpty else { return }
        let context = rhymeContext
        suggestionsTask?.cancel()
        isLoading = true
        errorMessage = nil
        suggestions = []

        let stream = aiService.streamSuggestions(
            provider: selectedProvider,
            apiKey: currentApiKey,
            modelId: selectedModel.id,
            theme: theme,
            lyrics: lyrics,
            targetRhymeLine: context.targetLine,
            rhymeType: rhymeType,
            rhymeScheme: activeRhymeScheme,
            currentLetter: context.currentLetter,
            currentSection: context.currentSection,
            complexity: rhymeComplexity,
            useWholeSongContext: useWholeSongContext
        )

        suggestionsTask = Task { @MainActor in
            defer { self.isLoading = false }
            do {
                var emittedSuggestion = false
                for try await line in stream {
                    emittedSuggestion = true
                    self.suggestions.append(line)
                }
                if !emittedSuggestion, !Task.isCancelled {
                    self.errorMessage = "AI did not return suggestions. Try again."
                }
            } catch is CancellationError {
                // expected when cancelSuggestions() is invoked
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSuggestions() {
        suggestionsTask?.cancel()
        suggestionsTask = nil
        isLoading = false
    }

    // MARK: - Rewrite

    func requestRewrite(_ action: RewriteAction) {
        let range = selectedRangeForRewriteRequest()
        guard range.length > 0 else { return }
        let ns = lyrics as NSString
        guard range.location + range.length <= ns.length else { return }
        let original = ns.substring(with: range)
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        beginRewrite(action: action, range: range, original: original)
    }

    private func selectedRangeForRewriteRequest() -> NSRange {
        guard selectedRange.length == 0,
              ProcessInfo.processInfo.arguments.contains("--ui-test-seed-rewrite-selection"),
              let seedRange = rewriteSelectionSeedRange() else {
            return selectedRange
        }
        selectedRange = seedRange
        cursorPosition = seedRange.location + seedRange.length
        return seedRange
    }

    private func rewriteSelectionSeedRange() -> NSRange? {
        let ns = lyrics as NSString
        let range = ns.range(of: "yellow music")
        return range.location == NSNotFound ? nil : range
    }

    func retryRewrite() {
        guard let action = rewriteAction,
              let range = rewriteRange,
              let original = rewriteOriginal else {
            return
        }

        beginRewrite(action: action, range: range, original: original)
    }

    private func beginRewrite(action: RewriteAction, range: NSRange, original: String) {
        rewriteTask?.cancel()
        rewriteAction = action
        rewriteOriginal = original
        rewriteRange = range
        rewritePreview = nil
        rewriteError = nil
        rewriteLoading = true
        let fullLyrics = lyrics
        let currentSection = currentSongSection(in: fullLyrics, cursorPosition: range.location)

        rewriteTask = Task { @MainActor in
            do {
                let result = try await aiService.getRewrite(
                    provider: selectedProvider,
                    apiKey: currentApiKey,
                    modelId: selectedModel.id,
                    action: action,
                    fullLyrics: fullLyrics,
                    selection: original,
                    currentSection: currentSection
                )
                guard !Task.isCancelled else { return }
                rewritePreview = result
            } catch {
                guard !Task.isCancelled else { return }
                rewriteError = error.localizedDescription
            }
            rewriteLoading = false
        }
    }

    func applyRewrite() {
        guard let preview = rewritePreview, let range = rewriteRange else { return }
        let ns = lyrics as NSString
        guard range.location + range.length <= ns.length else {
            dismissRewrite()
            return
        }
        if let original = rewriteOriginal, ns.substring(with: range) != original {
            dismissRewrite()
            return
        }
        let updated = ns.replacingCharacters(in: range, with: preview)
        lyrics = updated
        let newCursor = range.location + (preview as NSString).length
        cursorPosition = newCursor
        selectedRange = NSRange(location: newCursor, length: 0)
        dismissRewrite()
        triggerAutoSave()
    }

    func dismissRewrite() {
        rewriteTask?.cancel()
        rewriteTask = nil
        rewriteAction = nil
        rewriteLoading = false
        rewritePreview = nil
        rewriteOriginal = nil
        rewriteError = nil
        rewriteRange = nil
    }

    // MARK: - Word Inspector

    func openInspectorForSelection() {
        guard let pick = singleWordSelection else { return }
        openInspector(word: pick.word, range: pick.range)
    }

    func openInspector(word: String, range: NSRange) {
        inspectorSynonymsTask?.cancel()
        inspectorWord = word
        inspectorRange = range
        inspectorSynonyms = []
        inspectorSynonymsError = nil

        Task { @MainActor in
            let prosody = await Task.detached(priority: .userInitiated) {
                ProsodyAnalyzer.analyzeWord(word)
            }.value
            let matches = await Task.detached(priority: .userInitiated) {
                ProsodyAnalyzer.findRhymes(for: word)
            }.value
            guard inspectorWord == word else { return }
            inspectorProsody = prosody
            inspectorMatches = matches
        }

        fetchInspectorSynonyms(word: word, range: range)
    }

    func retryInspectorSynonyms() {
        guard let word = inspectorWord, let range = inspectorRange else { return }
        fetchInspectorSynonyms(word: word, range: range)
    }

    private func fetchInspectorSynonyms(word: String, range: NSRange) {
        inspectorSynonymsTask?.cancel()
        inspectorSynonymsError = nil
        inspectorSynonymsLoading = true
        let lineContext = currentLine(for: range)
        let provider = selectedProvider
        let apiKey = currentApiKey
        let modelId = selectedModel.id
        inspectorSynonymsTask = Task { @MainActor in
            defer { self.inspectorSynonymsLoading = false }
            do {
                let results = try await aiService.getSynonyms(
                    provider: provider,
                    apiKey: apiKey,
                    modelId: modelId,
                    word: word,
                    lineContext: lineContext
                )
                guard !Task.isCancelled, self.inspectorWord == word else { return }
                self.inspectorSynonyms = results
            } catch is CancellationError {
                // ignored
            } catch {
                guard !Task.isCancelled else { return }
                self.inspectorSynonymsError = error.localizedDescription
            }
        }
    }

    private func currentLine(for range: NSRange) -> String {
        let ns = lyrics as NSString
        guard range.location <= ns.length else { return "" }
        let safeLoc = min(range.location, ns.length)
        let safeEnd = min(range.location + range.length, ns.length)
        let prefix = ns.substring(with: NSRange(location: 0, length: safeLoc))
        let lineStartOffset: Int
        if let lastNewline = prefix.range(of: "\n", options: .backwards)?.upperBound {
            lineStartOffset = prefix.distance(from: prefix.startIndex, to: lastNewline)
        } else {
            lineStartOffset = 0
        }
        let lineEndOffset: Int
        if safeEnd >= ns.length {
            lineEndOffset = ns.length
        } else {
            let suffix = ns.substring(with: NSRange(location: safeEnd, length: ns.length - safeEnd))
            if let nextNewline = suffix.range(of: "\n")?.lowerBound {
                lineEndOffset = safeEnd + suffix.distance(from: suffix.startIndex, to: nextNewline)
            } else {
                lineEndOffset = ns.length
            }
        }
        guard lineStartOffset <= lineEndOffset, lineEndOffset <= ns.length else { return "" }
        return ns.substring(with: NSRange(location: lineStartOffset, length: lineEndOffset - lineStartOffset))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func applyInspectorReplacement(_ replacement: String) {
        guard let range = inspectorRange else { return }
        let ns = lyrics as NSString
        guard range.location + range.length <= ns.length else {
            dismissInspector()
            return
        }
        let updated = ns.replacingCharacters(in: range, with: replacement)
        lyrics = updated
        let newCursor = range.location + (replacement as NSString).length
        cursorPosition = newCursor
        selectedRange = NSRange(location: newCursor, length: 0)
        dismissInspector()
        triggerAutoSave()
    }

    func dismissInspector() {
        inspectorSynonymsTask?.cancel()
        inspectorSynonymsTask = nil
        inspectorWord = nil
        inspectorRange = nil
        inspectorProsody = nil
        inspectorMatches = nil
        inspectorSynonyms = []
        inspectorSynonymsLoading = false
        inspectorSynonymsError = nil
        selectedRange = NSRange(location: selectedRange.location + selectedRange.length, length: 0)
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

    func moveProjectToTrash(_ project: SongProject) {
        guard let context = modelContext else { return }
        autoSaveTask?.cancel()
        removeExistingTrashEntry(id: project.id, in: context)

        let trashedProject = TrashedSongProject(project: project)
        context.insert(trashedProject)
        if currentProjectId == project.id {
            clearEditorAfterProjectDelete()
        }
        context.delete(project)
        try? context.save()
        scheduleTrashPurge()
    }

    func restoreTrashedProject(_ trashedProject: TrashedSongProject) {
        guard let context = modelContext else { return }
        let restoredProject = trashedProject.restoredProject()
        removeExistingProject(id: restoredProject.id, in: context)
        context.insert(restoredProject)
        context.delete(trashedProject)
        try? context.save()
        scheduleTrashPurge()
    }

    func permanentlyDeleteTrashedProject(_ trashedProject: TrashedSongProject) {
        guard let context = modelContext else { return }
        context.delete(trashedProject)
        try? context.save()
        scheduleTrashPurge()
    }

    func purgeExpiredTrashedProjects() {
        guard let context = modelContext else { return }
        let now = Date()
        let descriptor = FetchDescriptor<TrashedSongProject>(
            predicate: #Predicate<TrashedSongProject> { $0.deleteAfter <= now }
        )
        guard let expiredProjects = try? context.fetch(descriptor), !expiredProjects.isEmpty else {
            scheduleTrashPurge()
            return
        }
        for project in expiredProjects {
            context.delete(project)
        }
        try? context.save()
        scheduleTrashPurge()
    }

    private func scheduleTrashPurge() {
        trashSchedulerTask?.cancel()
        guard let context = modelContext else { return }
        let now = Date()
        var descriptor = FetchDescriptor<TrashedSongProject>(
            predicate: #Predicate<TrashedSongProject> { $0.deleteAfter > now },
            sortBy: [SortDescriptor(\.deleteAfter, order: .forward)]
        )
        descriptor.fetchLimit = 1
        guard let nextProject = try? context.fetch(descriptor).first else { return }

        let delay = max(nextProject.deleteAfter.timeIntervalSinceNow, 0)
        trashSchedulerTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.trashSchedulerTask = nil
            self?.purgeExpiredTrashedProjects()
        }
    }

    private func removeExistingProject(id: String, in context: ModelContext) {
        let projectId = id
        let descriptor = FetchDescriptor<SongProject>(
            predicate: #Predicate<SongProject> { $0.id == projectId }
        )
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
        }
    }

    private func removeExistingTrashEntry(id: String, in context: ModelContext) {
        let projectId = id
        let descriptor = FetchDescriptor<TrashedSongProject>(
            predicate: #Predicate<TrashedSongProject> { $0.id == projectId }
        )
        if let existing = try? context.fetch(descriptor).first {
            context.delete(existing)
        }
    }

    private func clearEditorAfterProjectDelete() {
        title = ""
        lyrics = ""
        theme = ""
        cursorPosition = 0
        currentProjectId = nil
        suggestions = []
        errorMessage = nil
        saveStatus = .idle
    }

    func positionSeededProsodyCursorForUITests() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-seed-prosody-song") else { return }
        if let range = lyrics.range(of: "follow music") {
            cursorPosition = lyrics.distance(from: lyrics.startIndex, to: range.lowerBound)
        } else {
            cursorPosition = max(lyrics.count - 1, 0)
        }
    }

    private func seedTrashProjectForUITestsIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-seed-trash-song"),
              !didSeedTrashProjectForUITests,
              let context = modelContext else {
            return
        }

        didSeedTrashProjectForUITests = true
        let seedId = "ui-trash-song"
        let projectDescriptor = FetchDescriptor<SongProject>(
            predicate: #Predicate<SongProject> { $0.id == seedId }
        )
        let trashDescriptor = FetchDescriptor<TrashedSongProject>(
            predicate: #Predicate<TrashedSongProject> { $0.id == seedId }
        )

        if let trashedProject = try? context.fetch(trashDescriptor).first {
            context.delete(trashedProject)
        }

        let project: SongProject
        if let existingProject = try? context.fetch(projectDescriptor).first {
            project = existingProject
        } else {
            project = SongProject(id: seedId)
            context.insert(project)
        }
        project.title = "UI Trash Song"
        project.lyrics = "yellow music"
        project.theme = ""
        project.updatedAt = Date()
        try? context.save()

        title = project.title
        lyrics = project.lyrics
        theme = project.theme
        cursorPosition = project.lyrics.count
        currentProjectId = project.id
        suggestions = []
        errorMessage = nil
        saveStatus = .saved
        showWelcome = false
        showProjectsSheet = false
    }

    func importProject(_ exported: SongProjectExport) {
        guard let context = modelContext else { return }
        let project = SongProject(
            id: UUID().uuidString,
            title: exported.title.isEmpty ? "Imported Song" : exported.title,
            lyrics: exported.lyrics,
            theme: exported.theme,
            updatedAt: Date()
        )
        context.insert(project)
        try? context.save()

        title = project.title
        lyrics = project.lyrics
        theme = project.theme
        cursorPosition = project.lyrics.count
        currentProjectId = project.id
        suggestions = []
        errorMessage = nil
        saveStatus = .saved
        showWelcome = false
        showProjectsSheet = false
    }

    func snapshotForExport() -> SongProject {
        SongProject(
            id: currentProjectId ?? UUID().uuidString,
            title: title.isEmpty ? "Untitled Song" : title,
            lyrics: lyrics,
            theme: theme,
            updatedAt: Date()
        )
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
        if key.isEmpty {
            keychainStore.deleteKey(provider: provider.rawValue)
        } else {
            keychainStore.setKey(provider: provider.rawValue, key: key)
        }
        apiKeyPresence[provider.rawValue] = !key.isEmpty
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
