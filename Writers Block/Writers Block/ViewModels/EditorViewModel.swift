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
            scheduleDerivedStateRefresh()
        }
    }
    @Published var theme: String = ""
    @Published var cursorPosition: Int = 0 {
        didSet {
            scheduleDerivedStateRefresh()
        }
    }

    // MARK: - AI State

    @Published var suggestions: [SuggestedLine] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    // MARK: - Rhyme Settings

    @Published var rhymeType: RhymeType = .perfect
    @Published var rhymeScheme: RhymeScheme = .aabb {
        didSet {
            scheduleDerivedStateRefresh()
        }
    }
    @Published var customRhymeScheme: String = "" {
        didSet {
            scheduleDerivedStateRefresh()
        }
    }
    @Published var rhymeComplexity: RhymeComplexity = .moderate
    // These six are persisted to UserDefaults so the user's editor preferences
    // survive app restarts. Defaults match the previous hard-coded in-memory values.
    // Keys use an "editor." prefix to namespace them away from provider/model keys.
    @Published var useWholeSongContext: Bool = false
    @Published var isHighlightEnabled: Bool = true
    @Published var isSyllableColoringEnabled: Bool = true
    @Published var isStressPreviewEnabled: Bool = false
    @Published var isRhymeHighlightEnabled: Bool = false
    @Published var isBeatGridEnabled: Bool = false
    @Published var beatGridBpm: Int = 90

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
    private var derivedStateTask: Task<Void, Never>?
    private var rewriteRejectedCandidates: Set<String> = []

    // MARK: - Word Inspector

    @Published var inspectorWord: String?
    @Published var inspectorRange: NSRange?
    @Published var inspectorProsody: WordProsody?
    @Published var inspectorMatches: RhymeMatches?
    @Published var inspectorSynonyms: [String] = []
    @Published var inspectorSynonymsLoading: Bool = false
    @Published var inspectorSynonymsError: String?
    private var inspectorSynonymsTask: Task<Void, Never>?
    private var inspectorAnalysisTask: Task<Void, Never>?

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

    // MARK: - Voice Memos

    let voiceMemoService = VoiceMemoService()

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
    private static let untitledProjectTitle = "Untitled Song"
    private static let importedProjectTitle = "Imported Song"

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
        let runningUITestInMemory = UITestFlags.isEnabled(UITestFlags.inMemoryStore)
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

        if runningUITestInMemory {
            // Stray provider/model defaults can outlive the app container
            // (cfprefsd caching, or a simulator-level preference domain written
            // via `simctl spawn defaults write`) and silently reroute UI tests
            // to another provider. Writing the baseline — not removing — is what
            // shadows those merged fallback domains.
            UserDefaults.standard.set(AIProvider.gemini.rawValue, forKey: "selectedProvider")
            UserDefaults.standard.set(AIModel.default.rawValue, forKey: "selectedModel")
        }

        let providerRaw = UserDefaults.standard.string(forKey: "selectedProvider") ?? AIProvider.gemini.rawValue
        selectedProvider = AIProvider(rawValue: providerRaw) ?? .gemini
        let modelRaw = UserDefaults.standard.string(forKey: "selectedModel") ?? AIModel.default.rawValue
        if let savedModel = AIModel(rawValue: modelRaw), savedModel.provider == selectedProvider {
            selectedModel = savedModel
        } else {
            selectedModel = AIModel.models(for: selectedProvider).first ?? .default
        }

        // Restore editor toggle states. Booleans default false when the key is absent,
        // which matches the desired default for all except isHighlightEnabled and
        // isSyllableColoringEnabled — those default true, so we treat a missing key
        // as "never set" and leave the in-memory default in place rather than reading
        // the UserDefaults zero-value.
        useWholeSongContext = UserDefaults.standard.bool(forKey: "editor.useWholeSongContext")
        if UserDefaults.standard.object(forKey: "editor.isHighlightEnabled") != nil {
            isHighlightEnabled = UserDefaults.standard.bool(forKey: "editor.isHighlightEnabled")
        }
        if UserDefaults.standard.object(forKey: "editor.isSyllableColoringEnabled") != nil {
            isSyllableColoringEnabled = UserDefaults.standard.bool(forKey: "editor.isSyllableColoringEnabled")
        }
        isStressPreviewEnabled = UserDefaults.standard.bool(forKey: "editor.isStressPreviewEnabled")
        isRhymeHighlightEnabled = UserDefaults.standard.bool(forKey: "editor.isRhymeHighlightEnabled")
        isBeatGridEnabled = UserDefaults.standard.bool(forKey: "editor.isBeatGridEnabled")

        _ = ApiKeyMigration.apply(legacyDefaults: .standard, secure: resolvedStore)
        let secured = resolvedStore.allKeys()
        for provider in AIProvider.allCases {
            apiKeyPresence[provider.rawValue] = (secured[provider.rawValue] ?? "").isEmpty == false
        }

        if UITestFlags.isEnabled(UITestFlags.seedProsodySong) {
            let seededLyrics = "[Verse]\nyellow music\nfollow music\nmellow music"
            title = "UI Prosody Song"
            lyrics = seededLyrics
            positionSeededProsodyCursorForUITests()
            seedRewriteLoadingForUITestsIfNeeded()
            isStressPreviewEnabled = UITestFlags.isEnabled(UITestFlags.enableStressPreview)
            showWelcome = false
            showAssistantSheet = UITestFlags.isEnabled(UITestFlags.openAssistant)
        }

        if UITestFlags.isEnabled(UITestFlags.seedRewriteSelection) {
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
        autoSaveTask?.cancel()
        rewriteTask?.cancel()
        suggestionsTask?.cancel()
        derivedStateTask?.cancel()
        inspectorSynonymsTask?.cancel()
        inspectorAnalysisTask?.cancel()
        // Stop any in-progress recording or playback so AVAudioSession is
        // deactivated before the service is released.
        voiceMemoService.stopRecording()
        voiceMemoService.stopPlayback()
    }

    // MARK: - Rhyme Context

    private func scheduleDerivedStateRefresh() {
        derivedStateTask?.cancel()
        derivedStateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refreshLyricsDerivedState()
        }
    }

    private func refreshLyricsDerivedState() {
        wordCount = SyllableCounter.wordCount(lyrics)
        syllableCount = SyllableCounter.countText(lyrics)
        refreshRhymeContext()
    }

    private func refreshRhymeContext() {
        rhymeContext = computeRhymeContext()
    }

    /// `cursorPosition` comes from UITextView in UTF-16 units, but the String
    /// operations in this file count Characters (grapheme clusters). Convert once
    /// at the boundary so emoji/CJK lyrics don't skew offsets; snaps to the nearest
    /// preceding grapheme boundary when the offset lands inside a cluster.
    static func characterOffset(forUTF16Offset offset: Int, in text: String) -> Int {
        var clamped = min(max(offset, 0), text.utf16.count)
        while clamped > 0 {
            if let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: clamped, limitedBy: text.utf16.endIndex),
               let characterIndex = utf16Index.samePosition(in: text) {
                return text.distance(from: text.startIndex, to: characterIndex)
            }
            clamped -= 1
        }
        return 0
    }

    func computeRhymeContext() -> RhymeContext {
        guard !lyrics.isEmpty else {
            return RhymeContext.emptyContext(currentLetter: String(activeRhymeScheme.first ?? Character("A")))
        }

        let pos = Self.characterOffset(forUTF16Offset: cursorPosition, in: lyrics)
        let rawLines = lyrics.components(separatedBy: "\n")
        let sectionMap = SectionMap(lyrics: lyrics)

        // Determine which full-document line index the cursor sits on.
        let textBeforeCursor = String(lyrics.prefix(pos))
        let globalCursorLineIndex = textBeforeCursor.components(separatedBy: "\n").count - 1

        let sectionContext = Self.sectionContext(
            forLineIndex: globalCursorLineIndex,
            sectionMap: sectionMap,
            rawLines: rawLines
        )
        let currentSection = sectionContext.currentSection
        let sectionOrdinal = sectionContext.sectionOrdinal
        let firstChorusLines = sectionContext.firstChorusLines

        let textIndex = lyrics.index(lyrics.startIndex, offsetBy: pos)
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
            !Self.isSectionHeader(line) && !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count - 1
        let effectiveLineIndex = max(lyricLinePosition, 0)

        let schemeLetters = Array(activeRhymeScheme)
        guard !schemeLetters.isEmpty else {
            return RhymeContext(targetLine: nil, currentLetter: "A", stanzaLines: stanzaLines, currentLineIndex: rawCursorLineIndex, currentSection: currentSection, sectionOrdinal: sectionOrdinal, firstChorusLines: firstChorusLines)
        }

        let currentLetter = String(schemeLetters[effectiveLineIndex % schemeLetters.count])

        let targetLine = Self.targetLine(
            in: stanzaLines,
            before: rawCursorLineIndex,
            matching: currentLetter,
            schemeLetters: schemeLetters
        )

        return RhymeContext(
            targetLine: targetLine,
            currentLetter: currentLetter,
            stanzaLines: stanzaLines,
            currentLineIndex: rawCursorLineIndex,
            currentSection: currentSection,
            sectionOrdinal: sectionOrdinal,
            firstChorusLines: firstChorusLines
        )
    }

    private struct RhymeSectionContext {
        let currentSection: SongSection
        let sectionOrdinal: Int
        let firstChorusLines: [String]?
    }

    private static func sectionContext(
        forLineIndex lineIndex: Int,
        sectionMap: SectionMap,
        rawLines: [String]
    ) -> RhymeSectionContext {
        let sectionRef = sectionMap.sectionAt(lineIndex: lineIndex)
        let currentSection = sectionRef?.type ?? .unknown
        let sectionOrdinal = sectionRef?.ordinal ?? 1
        let firstChorusLines: [String]?
        if currentSection == .chorus, sectionOrdinal >= 2 {
            firstChorusLines = sectionMap.lines(forFirstOf: .chorus, in: rawLines)
        } else {
            firstChorusLines = nil
        }

        return RhymeSectionContext(
            currentSection: currentSection,
            sectionOrdinal: sectionOrdinal,
            firstChorusLines: firstChorusLines
        )
    }

    private static func targetLine(
        in stanzaLines: [String],
        before rawCursorLineIndex: Int,
        matching currentLetter: String,
        schemeLetters: [Character]
    ) -> String? {
        var targetLine: String?
        var lyricCount = 0
        for i in stanzaLines.indices {
            if i >= rawCursorLineIndex { break }

            let line = stanzaLines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isSectionHeader(line) || line.isEmpty { continue }

            let letter = String(schemeLetters[lyricCount % schemeLetters.count])
            if letter == currentLetter {
                targetLine = line
            }
            lyricCount += 1
        }
        return targetLine
    }

    private static func isSectionHeader(_ line: String) -> Bool {
        SectionMap.headerTitle(line.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    // Keep for backward compatibility — some callers use this directly.
    private func sectionHeaderTitle(_ line: String) -> String? {
        SectionMap.headerTitle(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Rewrite path needs a quick section lookup without full context computation.
    private func currentSongSection(in lyrics: String, cursorPosition: Int) -> SongSection {
        let safePosition = min(max(cursorPosition, 0), lyrics.count)
        let rawLines = lyrics.components(separatedBy: "\n")
        let textBeforeCursor = String(lyrics.prefix(safePosition))
        let cursorLineIndex = textBeforeCursor.components(separatedBy: "\n").count - 1
        return SectionMap(lyrics: lyrics).sectionAt(lineIndex: cursorLineIndex)?.type
            ?? (rawLines.prefix(cursorLineIndex + 1)
                .compactMap { SectionMap.headerTitle($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .last.map(SongSection.fromHeader) ?? .unknown)
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
            sectionOrdinal: context.sectionOrdinal,
            firstChorusLines: context.firstChorusLines,
            complexity: rhymeComplexity,
            useWholeSongContext: useWholeSongContext
        )

        // Compute tier per emitted line using the same filter the streaming
        // path uses, so the badge always agrees with what was held/passed.
        let filter = RhymeLineFilter(targetLine: context.targetLine, rhymeType: rhymeType)

        // Hook-repeat: end words from first chorus used to flag "hook" badge
        // variant on subsequent choruses.
        let firstChorusEndWordSet: Set<String> = {
            guard context.currentSection == .chorus, context.sectionOrdinal >= 2,
                  let lines = context.firstChorusLines else { return [] }
            return Set(lines.compactMap { line -> String? in
                let w = RhymeConstraint.lineEndWord(line)
                return w.isEmpty ? nil : w
            })
        }()

        suggestionsTask = Task { @MainActor in
            defer { self.isLoading = false }
            do {
                var emittedSuggestion = false
                for try await text in stream {
                    emittedSuggestion = true
                    let tier = filter?.tier(of: text) ?? 0
                    let endWord = RhymeConstraint.lineEndWord(text)
                    let isHookRepeat = !firstChorusEndWordSet.isEmpty && firstChorusEndWordSet.contains(endWord)
                    self.suggestions.append(SuggestedLine(text: text, tier: tier, isHookRepeat: isHookRepeat))
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

        rewriteRejectedCandidates = []
        beginRewrite(action: action, range: range, original: original)
    }

    private func selectedRangeForRewriteRequest() -> NSRange {
        guard selectedRange.length == 0,
              UITestFlags.isEnabled(UITestFlags.seedRewriteSelection),
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

        beginRewrite(
            action: action,
            range: range,
            original: original,
            rejectedCandidates: rewritePreview.map { Set([$0]) } ?? []
        )
    }

    private func beginRewrite(
        action: RewriteAction,
        range: NSRange,
        original: String,
        rejectedCandidates: Set<String> = []
    ) {
        rewriteTask?.cancel()
        rewriteAction = action
        rewriteOriginal = original
        rewriteRange = range
        rewriteRejectedCandidates.formUnion(rejectedCandidates)
        rewriteRejectedCandidates.insert(original)
        rewritePreview = nil
        rewriteError = nil
        rewriteLoading = true
        let fullLyrics = lyrics
        let currentSection = currentSongSection(
            in: fullLyrics,
            cursorPosition: Self.characterOffset(forUTF16Offset: range.location, in: fullLyrics)
        )
        let rejectedForRequest = rewriteRejectedCandidates

        rewriteTask = Task { @MainActor in
            do {
                let result = try await aiService.getRewrite(
                    provider: selectedProvider,
                    apiKey: currentApiKey,
                    modelId: selectedModel.id,
                    action: action,
                    fullLyrics: fullLyrics,
                    selection: original,
                    currentSection: currentSection,
                    // AIService walks lyrics by Characters; range.location is UTF-16.
                    selectionStart: Self.characterOffset(forUTF16Offset: range.location, in: fullLyrics),
                    rejectedCandidates: rejectedForRequest
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
        rewriteRejectedCandidates = []
    }

    // MARK: - Word Inspector

    func openInspectorForSelection() {
        guard let pick = singleWordSelection else { return }
        openInspector(word: pick.word, range: pick.range)
    }

    func openInspector(word: String, range: NSRange) {
        inspectorSynonymsTask?.cancel()
        inspectorAnalysisTask?.cancel()
        inspectorWord = word
        inspectorRange = range
        inspectorProsody = nil
        inspectorMatches = nil
        inspectorSynonyms = []
        inspectorSynonymsError = nil

        inspectorAnalysisTask = Task { @MainActor in
            let prosody = await Task.detached(priority: .userInitiated) {
                ProsodyAnalyzer.analyzeWord(word)
            }.value
            let matches = await Task.detached(priority: .userInitiated) {
                ProsodyAnalyzer.findRhymes(for: word)
            }.value
            guard !Task.isCancelled, inspectorWord == word else { return }
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
        inspectorAnalysisTask?.cancel()
        inspectorAnalysisTask = nil
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
        let pos = Self.characterOffset(forUTF16Offset: cursorPosition, in: lyrics)
        let beforeIndex = lyrics.index(lyrics.startIndex, offsetBy: pos)
        let before = String(lyrics[lyrics.startIndex..<beforeIndex])
        let after = String(lyrics[beforeIndex..<lyrics.endIndex])

        let needsNewline = !before.isEmpty && !before.hasSuffix("\n")
        let insertText = (needsNewline ? "\n" : "") + suggestion + "\n"

        lyrics = before + insertText + after
        // cursorPosition is a UTF-16 offset (UITextView units).
        cursorPosition = before.utf16.count + insertText.utf16.count
        suggestions = []
        triggerAutoSave()
    }

    // MARK: - Project Management

    func newProject() {
        autoSaveTask?.cancel()
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
        autoSaveTask?.cancel()
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

        let trashedProject = TrashedSongProject(project: project)
        removeExistingTrashEntries(id: project.id, in: context)
        context.insert(trashedProject)
        if currentProjectId == project.id {
            clearEditorAfterProjectDelete()
        }
        removeExistingProjects(id: project.id, in: context)
        try? context.save()
        scheduleTrashPurge()
    }

    func restoreTrashedProject(_ trashedProject: TrashedSongProject) {
        guard let context = modelContext else { return }
        let restoredProject = trashedProject.restoredProject()
        removeExistingProjects(id: restoredProject.id, in: context)
        context.insert(restoredProject)
        removeExistingTrashEntries(id: restoredProject.id, in: context)
        try? context.save()
        scheduleTrashPurge()
    }

    func permanentlyDeleteTrashedProject(_ trashedProject: TrashedSongProject) {
        guard let context = modelContext else { return }
        let projectId = trashedProject.id
        context.delete(trashedProject)
        try? context.save()
        // Remove the memo folder so orphaned audio doesn't accumulate on disk.
        VoiceMemoService.deleteMemosFolder(for: projectId)
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
            let projectId = project.id
            context.delete(project)
            // Remove memo audio alongside the SwiftData row so nothing lingers.
            VoiceMemoService.deleteMemosFolder(for: projectId)
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
            // Duration-based sleep — manual Double→UInt64 nanosecond math overflows
            // for far-future dates and would fire the purge immediately.
            try? await Task.sleep(for: .seconds(delay))
            self?.trashSchedulerTask = nil
            self?.purgeExpiredTrashedProjects()
        }
    }

    private func removeExistingProjects(id: String, in context: ModelContext) {
        let projectId = id
        let descriptor = FetchDescriptor<SongProject>(
            predicate: #Predicate<SongProject> { $0.id == projectId }
        )
        guard let existingProjects = try? context.fetch(descriptor) else { return }
        for existing in existingProjects {
            context.delete(existing)
        }
    }

    private func removeExistingTrashEntries(id: String, in context: ModelContext) {
        let projectId = id
        let descriptor = FetchDescriptor<TrashedSongProject>(
            predicate: #Predicate<TrashedSongProject> { $0.id == projectId }
        )
        guard let existingProjects = try? context.fetch(descriptor) else { return }
        for existing in existingProjects {
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
        guard UITestFlags.isEnabled(UITestFlags.seedProsodySong) else { return }
        if let range = lyrics.range(of: "follow music") {
            cursorPosition = lyrics.utf16.distance(from: lyrics.utf16.startIndex, to: range.lowerBound)
        } else {
            cursorPosition = max(lyrics.utf16.count - 1, 0)
        }
    }

    func seedRewriteLoadingForUITestsIfNeeded() {
        guard UITestFlags.isEnabled(UITestFlags.seedRewriteLoading),
              let range = rewriteSelectionSeedRange() else { return }
        let original = (lyrics as NSString).substring(with: range)
        selectedRange = range
        rewriteAction = .rephrase
        rewriteOriginal = original
        rewriteRange = range
        rewritePreview = nil
        rewriteError = nil
        rewriteLoading = true
    }

    private func seedTrashProjectForUITestsIfNeeded() {
        guard UITestFlags.isEnabled(UITestFlags.seedTrashSong),
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
        cursorPosition = project.lyrics.utf16.count
        currentProjectId = project.id
        suggestions = []
        errorMessage = nil
        saveStatus = .saved
        showWelcome = false
        showProjectsSheet = false
    }

    func importProject(_ exported: SongProjectExport) {
        guard let context = modelContext else { return }
        let project = makeImportedProject(from: exported)
        context.insert(project)
        try? context.save()

        title = project.title
        lyrics = project.lyrics
        theme = project.theme
        cursorPosition = project.lyrics.utf16.count
        currentProjectId = project.id
        suggestions = []
        errorMessage = nil
        saveStatus = .saved
        showWelcome = false
        showProjectsSheet = false
    }

    func snapshotForExport() -> SongProject {
        makeUntitledSongProject(id: currentProjectId ?? UUID().uuidString)
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

    /// A recording needs a project folder before any lyrics exist (people hum
    /// the melody first). Creates and persists an Untitled project on demand.
    func ensureProjectForRecording() -> String {
        if let projectId = currentProjectId { return projectId }
        let project = makeUntitledSongProject()
        if let context = modelContext {
            context.insert(project)
            try? context.save()
        }
        currentProjectId = project.id
        showWelcome = false
        return project.id
    }

    func triggerAutoSave() {
        autoSaveTask?.cancel()
        let projectIdAtTrigger = currentProjectId
        autoSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !title.isEmpty || !lyrics.isEmpty || !theme.isEmpty else {
                saveStatus = .idle
                return
            }
            saveStatus = .saving

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            // The editor switched projects (or cleared) during the debounce —
            // saving now would write into the wrong project or create an empty one.
            guard currentProjectId == projectIdAtTrigger,
                  !title.isEmpty || !lyrics.isEmpty || !theme.isEmpty else {
                saveStatus = .idle
                return
            }

            guard let context = modelContext else {
                saveStatus = .idle
                return
            }

            if let projectId = currentProjectId {
                let descriptor = FetchDescriptor<SongProject>(
                    predicate: #Predicate<SongProject> { $0.id == projectId }
                )
                if let existing = try? context.fetch(descriptor).first {
                    existing.title = normalizedProjectTitle()
                    existing.lyrics = lyrics
                    existing.theme = theme
                    existing.updatedAt = Date()
                }
            } else {
                let project = makeUntitledSongProject()
                context.insert(project)
                currentProjectId = project.id
            }

            try? context.save()
            saveStatus = .saved
        }
    }

    private func normalizedProjectTitle() -> String {
        title.isEmpty ? Self.untitledProjectTitle : title
    }

    private func makeUntitledSongProject(
        id: String = UUID().uuidString,
        updatedAt: Date = Date()
    ) -> SongProject {
        SongProject(
            id: id,
            title: normalizedProjectTitle(),
            lyrics: lyrics,
            theme: theme,
            updatedAt: updatedAt
        )
    }

    private func makeImportedProject(from exported: SongProjectExport) -> SongProject {
        SongProject(
            id: UUID().uuidString,
            title: exported.title.isEmpty ? Self.importedProjectTitle : exported.title,
            lyrics: exported.lyrics,
            theme: exported.theme,
            updatedAt: Date()
        )
    }

    // MARK: - Settings

    func saveApiKey(provider: AIProvider, key: String) {
        if key.isEmpty {
            keychainStore.deleteKey(provider: provider.rawValue)
            apiKeyPresence[provider.rawValue] = false
            return
        }
        let stored = keychainStore.setKey(provider: provider.rawValue, key: key)
        if !stored {
            errorMessage = "Couldn't save the \(provider.displayName) API key to the Keychain. Try again after unlocking the device."
        }
        apiKeyPresence[provider.rawValue] = stored
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

    // MARK: - Editor Toggle Persistence

    func saveUseWholeSongContext(_ value: Bool) {
        useWholeSongContext = value
        UserDefaults.standard.set(value, forKey: "editor.useWholeSongContext")
    }

    func saveIsHighlightEnabled(_ value: Bool) {
        isHighlightEnabled = value
        UserDefaults.standard.set(value, forKey: "editor.isHighlightEnabled")
    }

    func saveIsSyllableColoringEnabled(_ value: Bool) {
        isSyllableColoringEnabled = value
        UserDefaults.standard.set(value, forKey: "editor.isSyllableColoringEnabled")
    }

    func saveIsStressPreviewEnabled(_ value: Bool) {
        isStressPreviewEnabled = value
        UserDefaults.standard.set(value, forKey: "editor.isStressPreviewEnabled")
    }

    func saveIsRhymeHighlightEnabled(_ value: Bool) {
        isRhymeHighlightEnabled = value
        UserDefaults.standard.set(value, forKey: "editor.isRhymeHighlightEnabled")
    }

    func saveIsBeatGridEnabled(_ value: Bool) {
        isBeatGridEnabled = value
        UserDefaults.standard.set(value, forKey: "editor.isBeatGridEnabled")
    }
}
