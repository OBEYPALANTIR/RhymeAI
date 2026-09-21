import Combine
import Foundation
import SwiftData
import SwiftUI

enum SaveStatus {
    case idle, saving, saved
}

struct CloudAISharingRequest: Identifiable, Equatable {
    let id = UUID()
    let provider: AIProvider
    let purpose: String
    let scope: CloudAISharingScope
}

enum CloudAISharingScope: String {
    case selectedContext
    case wholeSong
}

@MainActor
protocol CloudBackupServicing: AnyObject {
    var isConfigured: Bool { get }
    var hasStoredPassphrase: Bool { get }
    var backgroundBackupFailureDescription: String? { get }

    func updatePassphrase(_ passphrase: String) throws
    func backupNow(modelContext: ModelContext) async throws
    func restoreNow(modelContext: ModelContext) async throws
    func backupInBackgroundIfPossible(modelContext: ModelContext) async
}

extension CloudBackupServicing {
    var backgroundBackupFailureDescription: String? { nil }
}

extension BackupService: CloudBackupServicing {}

private struct InspectorSynonymRequestIdentity: Equatable {
    let provider: AIProvider
    let modelID: String
    let sourceRevision: Int
    let credentialRevision: Int
    let localIdentity: SynonymLocalIdentity?
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
    @Published private(set) var canUndoLyrics: Bool = false
    @Published private(set) var canRedoLyrics: Bool = false

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
    private var suggestionsRequestID: UUID?
    private var rewriteRequestID: UUID?
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
    @Published var inspectorSynonymsRecovery: SynonymRecoveryAction?
    private var inspectorSynonymsTask: Task<Void, Never>?
    private var inspectorAnalysisTask: Task<Void, Never>?
    private var inspectorSynonymsRequestID = UUID()
    private var inspectorSynonymSourceRevision = 0
    private var inspectorCredentialRevisions: [String: Int] = [:]
    private var shouldOpenSettingsAfterInspectorDismissal = false

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

    @Published var selectedProvider: AIProvider = .local
    @Published var selectedModel: AIModel = .localModel
    /// Surfaces whether each provider has any key stored. The actual key values
    /// never live in observable state — they are pulled from the Keychain on
    /// demand at request time so they cannot leak via heap dumps, SwiftUI
    /// snapshots, or test fixtures.
    @Published private(set) var apiKeyPresence: [String: Bool] = [:]
    @Published var cloudAISharingRequest: CloudAISharingRequest?

    // MARK: - Cloud Backup

    @Published private(set) var cloudBackupConfigured: Bool = false
    @Published private(set) var cloudBackupHasStoredPassphrase: Bool = false
    @Published private(set) var cloudBackupIsWorking: Bool = false
    @Published private(set) var cloudBackupStatusText: String = "Google Drive backup is unavailable in this build."
    @Published private(set) var cloudBackupLastResultIsError: Bool = false

    // MARK: - Internal

    var modelContext: ModelContext? {
        didSet {
            applyPersistedDeletions()
            purgeExpiredTrashedProjects()
            seedTrashProjectForUITestsIfNeeded()
            refreshCloudBackupState()
        }
    }
    private let aiService: AIService
    private let synonymService: any SynonymProviding
    private let keychainStore: KeychainStore
    private let backupService: CloudBackupServicing?
    private let defaults: UserDefaults
    private let saveModelContext: (ModelContext) throws -> Void
    private let lyricsHistory = EditHistory<LyricsEditState>()
    private var pendingCloudAIAction: (() -> Void)?
    private var pendingCloudAIRequestID: UUID?
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

    var canRunCloudBackup: Bool {
        cloudBackupConfigured && cloudBackupHasStoredPassphrase && !cloudBackupIsWorking && modelContext != nil
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

    init(
        aiService: AIService = AIService(),
        keychainStore: KeychainStore? = nil,
        backupService: CloudBackupServicing? = nil,
        synonymService: any SynonymProviding = AIService(),
        defaults: UserDefaults = .standard,
        saveModelContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        let runningUITestInMemory = UITestFlags.isEnabled(UITestFlags.inMemoryStore)
        let resolvedStore: KeychainStore = keychainStore
            ?? (runningUITestInMemory ? InMemoryKeychainStore() : SystemKeychainStore())
        self.aiService = aiService
        self.keychainStore = resolvedStore
        self.backupService = backupService
        self.synonymService = synonymService
        self.defaults = defaults
        self.saveModelContext = saveModelContext

        #if DEBUG
        if runningUITestInMemory,
           let geminiTestKey = ProcessInfo.processInfo.environment["GEMINI_TEST_KEY"],
           !geminiTestKey.isEmpty,
           resolvedStore.getKey(provider: AIProvider.gemini.rawValue).isEmpty {
            resolvedStore.setKey(provider: AIProvider.gemini.rawValue, key: geminiTestKey)
        }
        #endif

        if runningUITestInMemory {
            let arguments = ProcessInfo.processInfo.arguments
            func value(after flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag),
                      arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            let requestedProvider = value(after: "-selectedProvider")
                .flatMap(AIProvider.init(rawValue:)) ?? .local
            let requestedModel = value(after: "-selectedModel")
                .flatMap(AIModel.init(rawValue:))
                .flatMap { $0.provider == requestedProvider ? $0 : nil }
                ?? AIModel.models(for: requestedProvider).first
                ?? .localModel
            defaults.set(requestedProvider.rawValue, forKey: "selectedProvider")
            defaults.set(requestedModel.rawValue, forKey: "selectedModel")
            for provider in [AIProvider.gemini, .openai, .claude] {
                for scope in [CloudAISharingScope.selectedContext, .wholeSong] {
                    defaults.removeObject(forKey: cloudAIConsentKey(provider, scope: scope))
                }
            }
        }

        let providerRaw = defaults.string(forKey: "selectedProvider") ?? AIProvider.local.rawValue
        selectedProvider = AIProvider(rawValue: providerRaw) ?? .local
        let modelRaw = defaults.string(forKey: "selectedModel") ?? AIModel.localModel.rawValue
        if let savedModel = AIModel(rawValue: modelRaw), savedModel.provider == selectedProvider {
            selectedModel = savedModel
        } else {
            selectedModel = AIModel.models(for: selectedProvider).first ?? .localModel
        }

        // Restore editor toggle states. Booleans default false when the key is absent,
        // which matches the desired default for all except isHighlightEnabled and
        // isSyllableColoringEnabled — those default true, so we treat a missing key
        // as "never set" and leave the in-memory default in place rather than reading
        // the UserDefaults zero-value.
        useWholeSongContext = defaults.bool(forKey: "editor.useWholeSongContext")
        if defaults.object(forKey: "editor.isHighlightEnabled") != nil {
            isHighlightEnabled = defaults.bool(forKey: "editor.isHighlightEnabled")
        }
        if defaults.object(forKey: "editor.isSyllableColoringEnabled") != nil {
            isSyllableColoringEnabled = defaults.bool(forKey: "editor.isSyllableColoringEnabled")
        }
        isStressPreviewEnabled = defaults.bool(forKey: "editor.isStressPreviewEnabled")
        isRhymeHighlightEnabled = defaults.bool(forKey: "editor.isRhymeHighlightEnabled")
        isBeatGridEnabled = defaults.bool(forKey: "editor.isBeatGridEnabled")

        _ = ApiKeyMigration.apply(legacyDefaults: defaults, secure: resolvedStore)
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

        if UITestFlags.isEnabled(UITestFlags.seedLongTitleSong) {
            title = "Midnight Letters from the Far Side of the City Lights"
            lyrics = """
            [Verse]
            I trace the signal through the city light
            A silver echo keeps the windows bright
            The midnight engines turn a patient wheel
            While quiet words reveal the way I feel
            """
            currentProjectId = "ui-test-long-title-song"
            saveStatus = .saved
            isRhymeHighlightEnabled = true
            isSyllableColoringEnabled = true
            showWelcome = false
        }

        if UITestFlags.isEnabled(UITestFlags.seedRewriteSelection) {
            let seededLyrics = "yellow music\nfollow music"
            title = "UI Rewrite Song"
            lyrics = seededLyrics
            selectedRange = NSRange(location: 0, length: ("yellow music" as NSString).length)
            cursorPosition = selectedRange.location + selectedRange.length
            showWelcome = false
        }
        refreshCloudBackupState()
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
        // wordCount/syllableCount/rhymeContext are deliberately not @Published
        // (they recompute on a debounce, not per keystroke), so views must be
        // told explicitly when the batch lands — otherwise counters and the
        // assistant's target line stay stale until the next unrelated render.
        objectWillChange.send()
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
        guard authorizeCloudAI(purpose: "suggestions", action: { [weak self] in
            self?.startSuggestions()
        }) else { return }
        startSuggestions()
    }

    private func startSuggestions() {
        let context = rhymeContext
        suggestionsTask?.cancel()
        let requestID = UUID()
        suggestionsRequestID = requestID
        let projectID = currentProjectId
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
            defer {
                if self.suggestionsRequestID == requestID {
                    self.isLoading = false
                }
            }
            do {
                var emittedSuggestion = false
                for try await text in stream {
                    guard !Task.isCancelled,
                          self.suggestionsRequestID == requestID,
                          self.currentProjectId == projectID else { return }
                    emittedSuggestion = true
                    let tier = filter?.tier(of: text) ?? 0
                    let endWord = RhymeConstraint.lineEndWord(text)
                    let isHookRepeat = !firstChorusEndWordSet.isEmpty && firstChorusEndWordSet.contains(endWord)
                    self.suggestions.append(SuggestedLine(text: text, tier: tier, isHookRepeat: isHookRepeat))
                }
                if !emittedSuggestion,
                   !Task.isCancelled,
                   self.suggestionsRequestID == requestID,
                   self.currentProjectId == projectID {
                    self.errorMessage = "AI did not return suggestions. Try again."
                }
            } catch is CancellationError {
                // expected when cancelSuggestions() is invoked
            } catch {
                guard self.suggestionsRequestID == requestID,
                      self.currentProjectId == projectID else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSuggestions() {
        suggestionsTask?.cancel()
        suggestionsTask = nil
        suggestionsRequestID = nil
        isLoading = false
    }

    // MARK: - Rewrite

    func requestRewrite(_ action: RewriteAction) {
        let range = selectedRangeForRewriteRequest()
        guard range.length > 0 else { return }
        let ns = lyrics as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return }
        let original = ns.substring(with: range)
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard authorizeCloudAI(purpose: "rewrite", action: { [weak self] in
            self?.rewriteRejectedCandidates = []
            self?.beginRewrite(action: action, range: range, original: original)
        }) else { return }
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

        let rejectedCandidates = rewritePreview.map { Set([$0]) } ?? []
        guard authorizeCloudAI(purpose: "rewrite", action: { [weak self] in
            self?.beginRewrite(
                action: action,
                range: range,
                original: original,
                rejectedCandidates: rejectedCandidates
            )
        }) else { return }
        beginRewrite(action: action, range: range, original: original, rejectedCandidates: rejectedCandidates)
    }

    private func beginRewrite(
        action: RewriteAction,
        range: NSRange,
        original: String,
        rejectedCandidates: Set<String> = []
    ) {
        rewriteTask?.cancel()
        let requestID = UUID()
        rewriteRequestID = requestID
        let projectID = currentProjectId
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
        let providerForRequest = selectedProvider
        let keyForRequest = currentApiKey
        let modelForRequest = selectedModel.id
        let wholeSongForRequest = useWholeSongContext
        let credentialRevision = inspectorCredentialRevisions[providerForRequest.rawValue, default: 0]

        rewriteTask = Task { @MainActor in
            guard !Task.isCancelled, rewriteRequestID == requestID,
                  inspectorCredentialRevisions[providerForRequest.rawValue, default: 0] == credentialRevision else { return }
            do {
                let result = try await aiService.getRewrite(
                    provider: providerForRequest,
                    apiKey: keyForRequest,
                    modelId: modelForRequest,
                    action: action,
                    fullLyrics: fullLyrics,
                    selection: original,
                    currentSection: currentSection,
                    // AIService walks lyrics by Characters; range.location is UTF-16.
                    selectionStart: Self.characterOffset(forUTF16Offset: range.location, in: fullLyrics),
                    rejectedCandidates: rejectedForRequest,
                    useWholeSongContext: wholeSongForRequest
                )
                guard !Task.isCancelled,
                      rewriteRequestID == requestID,
                      currentProjectId == projectID else { return }
                rewritePreview = result
            } catch {
                guard !Task.isCancelled,
                      rewriteRequestID == requestID,
                      currentProjectId == projectID else { return }
                rewriteError = error.localizedDescription
            }
            if rewriteRequestID == requestID { rewriteLoading = false }
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
        let newCursor = range.location + (preview as NSString).length
        applyAtomicLyricsEdit(
            text: ns.replacingCharacters(in: range, with: preview),
            cursorPosition: newCursor
        )
        dismissRewrite()
        triggerAutoSave()
    }

    func dismissRewrite() {
        rewriteTask?.cancel()
        rewriteTask = nil
        rewriteRequestID = nil
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
        inspectorSynonymsRecovery = nil

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
        guard authorizeCloudAI(purpose: "synonyms", action: { [weak self] in
            self?.fetchInspectorSynonyms(word: word, range: range)
        }) else {
            inspectorSynonymsLoading = false
            return
        }
        inspectorSynonymsTask?.cancel()
        let requestID = UUID()
        inspectorSynonymsRequestID = requestID
        let projectID = currentProjectId
        inspectorSynonymsError = nil
        inspectorSynonymsRecovery = nil
        inspectorSynonymsLoading = true
        let lineContext = currentLine(for: range)
        let identity = currentInspectorSynonymIdentity
        let provider = identity.provider
        let apiKey = currentApiKey
        let modelId = identity.modelID
        let existing = inspectorSynonyms
        inspectorSynonymsTask = Task { @MainActor in
            defer {
                if self.inspectorSynonymsRequestID == requestID {
                    self.inspectorSynonymsLoading = false
                }
            }
            do {
                let results = try await synonymService.getSynonyms(
                    provider: provider,
                    apiKey: apiKey,
                    modelId: modelId,
                    word: word,
                    lineContext: lineContext,
                    excluding: existing,
                    limit: 8
                )
                guard !Task.isCancelled,
                      self.inspectorSynonymsRequestID == requestID,
                      self.currentProjectId == projectID,
                      self.inspectorWord == word,
                      self.currentInspectorSynonymIdentity == identity else { return }
                let merged = SynonymSanitizer.extract(
                    (existing + results).joined(separator: "\n"),
                    excluding: word,
                    limit: 8
                )
                self.inspectorSynonyms = merged
                if merged.count < SynonymGenerationPipeline.minimumUsefulCount {
                    self.inspectorSynonymsError = merged.isEmpty
                        ? "No safe synonyms were returned. Retry."
                        : "Only \(merged.count) safe \(merged.count == 1 ? "synonym" : "synonyms") found. Retry for more."
                    self.inspectorSynonymsRecovery = .retry
                }
            } catch is CancellationError {
                // ignored
            } catch {
                guard !Task.isCancelled,
                      self.inspectorSynonymsRequestID == requestID,
                      self.currentProjectId == projectID,
                      self.inspectorWord == word,
                      self.currentInspectorSynonymIdentity == identity else { return }
                self.inspectorSynonymsError = error.localizedDescription
                self.inspectorSynonymsRecovery = SynonymResultPresentation.recoveryAction(
                    resultCount: self.inspectorSynonyms.count,
                    error: error
                )
            }
        }
    }

    func openSettingsFromInspector() {
        shouldOpenSettingsAfterInspectorDismissal = true
        dismissInspector()
    }

    func inspectorDidDismiss() {
        guard shouldOpenSettingsAfterInspectorDismissal else { return }
        shouldOpenSettingsAfterInspectorDismissal = false
        showSettingsSheet = true
    }

    private var currentInspectorSynonymIdentity: InspectorSynonymRequestIdentity {
        InspectorSynonymRequestIdentity(
            provider: selectedProvider,
            modelID: selectedModel.id,
            sourceRevision: inspectorSynonymSourceRevision,
            credentialRevision: inspectorCredentialRevisions[selectedProvider.rawValue, default: 0],
            localIdentity: AIService.synonymLocalIdentity(provider: selectedProvider)
        )
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
        let newCursor = range.location + (replacement as NSString).length
        applyAtomicLyricsEdit(
            text: ns.replacingCharacters(in: range, with: replacement),
            cursorPosition: newCursor
        )
        dismissInspector()
        triggerAutoSave()
    }

    func dismissInspector() {
        inspectorSynonymsTask?.cancel()
        inspectorSynonymsTask = nil
        inspectorSynonymsRequestID = UUID()
        inspectorAnalysisTask?.cancel()
        inspectorAnalysisTask = nil
        inspectorWord = nil
        inspectorRange = nil
        inspectorProsody = nil
        inspectorMatches = nil
        inspectorSynonyms = []
        inspectorSynonymsLoading = false
        inspectorSynonymsError = nil
        inspectorSynonymsRecovery = nil
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

        applyAtomicLyricsEdit(
            text: before + insertText + after,
            // cursorPosition is a UTF-16 offset (UITextView units).
            cursorPosition: before.utf16.count + insertText.utf16.count
        )
        suggestions = []
        triggerAutoSave()
    }

    func onLyricsChanged(
        _ newLyrics: String,
        timestampMilliseconds: Int64 = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
    ) {
        let previous = currentLyricsEditState
        let next = LyricsEditState(
            text: newLyrics,
            cursorPosition: min(cursorPosition, newLyrics.utf16.count),
            selectedRange: clampedSelection(selectedRange, text: newLyrics)
        )
        lyricsHistory.recordUserEdit(
            previous: previous,
            current: next,
            timestampMilliseconds: timestampMilliseconds
        )
        lyrics = newLyrics
        updateLyricsHistoryAvailability()
    }

    func undoLyrics() {
        guard let previous = lyricsHistory.undo(current: currentLyricsEditState) else { return }
        applyHistoryState(previous)
    }

    func redoLyrics() {
        guard let next = lyricsHistory.redo(current: currentLyricsEditState) else { return }
        applyHistoryState(next)
    }

    private var currentLyricsEditState: LyricsEditState {
        LyricsEditState(
            text: lyrics,
            cursorPosition: min(cursorPosition, lyrics.utf16.count),
            selectedRange: clampedSelection(selectedRange, text: lyrics)
        )
    }

    private func applyAtomicLyricsEdit(text: String, cursorPosition: Int) {
        let safeCursor = min(max(cursorPosition, 0), text.utf16.count)
        let next = LyricsEditState(
            text: text,
            cursorPosition: safeCursor,
            selectedRange: NSRange(location: safeCursor, length: 0)
        )
        lyricsHistory.recordAtomicEdit(previous: currentLyricsEditState, current: next)
        lyrics = next.text
        self.cursorPosition = next.cursorPosition
        selectedRange = next.selectedRange
        updateLyricsHistoryAvailability()
    }

    private func applyHistoryState(_ state: LyricsEditState) {
        dismissRewrite()
        dismissInspector()
        lyrics = state.text
        cursorPosition = min(state.cursorPosition, state.text.utf16.count)
        selectedRange = clampedSelection(state.selectedRange, text: state.text)
        suggestions = []
        updateLyricsHistoryAvailability()
        triggerAutoSave()
    }

    private func resetLyricsHistory() {
        lyricsHistory.reset()
        updateLyricsHistoryAvailability()
    }

    private func updateLyricsHistoryAvailability() {
        canUndoLyrics = lyricsHistory.canUndo
        canRedoLyrics = lyricsHistory.canRedo
    }

    private func clampedSelection(_ range: NSRange, text: String) -> NSRange {
        let textLength = text.utf16.count
        guard range.location <= textLength,
              range.length <= textLength - range.location else {
            return NSRange(location: min(range.location, textLength), length: 0)
        }
        return range
    }

    // MARK: - Project Management

    func newProject() {
        autoSaveTask?.cancel()
        cancelEditorAIWork()
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
        resetLyricsHistory()
    }

    func loadProject(_ project: SongProject) {
        autoSaveTask?.cancel()
        cancelEditorAIWork()
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
        resetLyricsHistory()
    }

    private func cancelEditorAIWork() {
        cancelSuggestions()
        dismissRewrite()
        dismissInspector()
        pendingCloudAIAction = nil
        pendingCloudAIRequestID = nil
        cloudAISharingRequest = nil
    }

    @discardableResult
    func moveProjectToTrash(_ project: SongProject) -> Bool {
        guard let context = modelContext else { return false }
        autoSaveTask?.cancel()

        let trashedProject = TrashedSongProject(project: project)
        removeExistingTrashEntries(id: project.id, in: context)
        context.insert(trashedProject)
        let clearsCurrentEditor = currentProjectId == project.id
        removeExistingProjects(id: project.id, in: context)
        do {
            try saveModelContext(context)
        } catch {
            context.rollback()
            errorMessage = "Couldn't move this song to Trash. Your song was kept."
            return false
        }
        if clearsCurrentEditor { clearEditorAfterProjectDelete() }
        scheduleTrashPurge()
        return true
    }

    @discardableResult
    func restoreTrashedProject(_ trashedProject: TrashedSongProject) -> Bool {
        guard let context = modelContext else { return false }
        let restoredProject = trashedProject.restoredProject()
        removeExistingProjects(id: restoredProject.id, in: context)
        context.insert(restoredProject)
        removeExistingTrashEntries(id: restoredProject.id, in: context)
        do {
            try saveModelContext(context)
        } catch {
            context.rollback()
            errorMessage = "Couldn't restore this song. It remains in Trash."
            return false
        }
        scheduleTrashPurge()
        return true
    }

    @discardableResult
    func permanentlyDeleteTrashedProject(_ trashedProject: TrashedSongProject) -> Bool {
        guard let context = modelContext else { return false }
        let projectId = trashedProject.id
        do {
            try upsertPermanentDeletion(projectId: projectId, in: context)
            context.delete(trashedProject)
            try saveModelContext(context)
        } catch {
            context.rollback()
            errorMessage = "Couldn't permanently delete this song. It remains in Trash."
            return false
        }
        // Remove the memo folder so orphaned audio doesn't accumulate on disk.
        if !VoiceMemoService.deleteMemosFolder(for: projectId) {
            errorMessage = "This song was permanently deleted, but its local recordings could not be removed. Writers Block will retry cleanup."
        }
        scheduleTrashPurge()
        return true
    }

    @discardableResult
    func permanentlyDeleteTrashedMemo(_ trashed: TrashedVoiceMemo) -> Bool {
        guard let context = modelContext else { return false }
        do {
            try upsertPermanentDeletion(projectId: trashed.projectId, fileName: trashed.originalName, in: context)
            try saveModelContext(context)
        } catch {
            context.rollback()
            voiceMemoService.lastError = "Couldn't permanently delete this recording. It remains in Trash."
            return false
        }
        return voiceMemoService.permanentlyDeleteTrashedMemo(trashed)
    }

    func purgeExpiredTrashedProjects() {
        guard let context = modelContext else { return }
        let now = Date()
        let expiredMemos = VoiceMemoService.trashedMemos().filter { $0.deleteAfter <= now }
        let descriptor = FetchDescriptor<TrashedSongProject>(
            predicate: #Predicate<TrashedSongProject> { $0.deleteAfter <= now }
        )
        guard let expiredProjects = try? context.fetch(descriptor), !expiredProjects.isEmpty || !expiredMemos.isEmpty else {
            scheduleTrashPurge()
            return
        }
        let projectIDs = expiredProjects.map(\.id)
        do {
            for projectId in projectIDs {
                try upsertPermanentDeletion(projectId: projectId, deletedAt: now, in: context)
            }
            for memo in expiredMemos {
                try upsertPermanentDeletion(projectId: memo.projectId, fileName: memo.originalName, deletedAt: now, in: context)
            }
            expiredProjects.forEach(context.delete)
            try saveModelContext(context)
            for projectId in projectIDs where !VoiceMemoService.deleteMemosFolder(for: projectId) {
                errorMessage = "Expired writing was removed, but some local recordings could not be cleaned up. Writers Block will retry."
            }
            for memo in expiredMemos {
                _ = voiceMemoService.permanentlyDeleteTrashedMemo(memo)
            }
        } catch {
            context.rollback()
            errorMessage = "Couldn't finish removing expired Trash items. They were kept for the next attempt."
        }
        scheduleTrashPurge()
    }

    private func applyPersistedDeletions() {
        guard let context = modelContext else { return }
        do {
            let records = try context.fetch(FetchDescriptor<SyncDeletionRecord>())
            let deletions = try SyncMerger.mergeDeletions(records.map(\.deletion))
            guard !deletions.isEmpty else { return }
            let deletedProjects = Set(deletions.filter { $0.fileName == nil }.map(\.projectId))
            for project in try context.fetch(FetchDescriptor<SongProject>()) where deletedProjects.contains(project.id) {
                context.delete(project)
            }
            for project in try context.fetch(FetchDescriptor<TrashedSongProject>()) where deletedProjects.contains(project.id) {
                context.delete(project)
            }
            try saveModelContext(context)
            for projectId in deletedProjects {
                _ = VoiceMemoService.deleteMemosFolder(for: projectId)
            }
            for deletion in deletions {
                guard let fileName = deletion.fileName, !deletedProjects.contains(deletion.projectId) else { continue }
                voiceMemoService.deletePermanentRecordingFiles(projectId: deletion.projectId, fileName: fileName)
            }
        } catch {
            context.rollback()
            errorMessage = "Couldn't finish applying permanent deletions. Writers Block will retry."
        }
    }

    private func upsertPermanentDeletion(
        projectId: String,
        fileName: String? = nil,
        deletedAt: Date = Date(),
        in context: ModelContext
    ) throws {
        try SyncIdentity.validateProjectId(projectId)
        if let fileName { try SyncIdentity.validateFileName(fileName) }
        let timestamp = Int64((deletedAt.timeIntervalSince1970 * 1000).rounded())
        let records = try context.fetch(FetchDescriptor<SyncDeletionRecord>())
        if let existing = records.first(where: { $0.projectId == projectId && $0.fileName == fileName }) {
            existing.deletedAt = max(existing.deletedAt, timestamp)
        } else {
            context.insert(SyncDeletionRecord(projectId: projectId, fileName: fileName, deletedAt: timestamp))
        }
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
        let nextProjectExpiry = (try? context.fetch(descriptor).first)?.deleteAfter
        // Already-expired recordings were purged above; only future expiries count.
        let nextMemoExpiry = VoiceMemoService.nextTrashedMemoExpiry().flatMap { $0 > now ? $0 : nil }
        guard let nextExpiry = [nextProjectExpiry, nextMemoExpiry].compactMap({ $0 }).min() else { return }

        let delay = max(nextExpiry.timeIntervalSinceNow, 0)
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
        resetLyricsHistory()
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

    @discardableResult
    func importProject(_ exported: SongProjectExport) -> Bool {
        guard let context = modelContext else { return false }
        autoSaveTask?.cancel()
        cancelEditorAIWork()
        let project = makeImportedProject(from: exported)
        context.insert(project)
        do {
            try saveModelContext(context)
        } catch {
            context.rollback()
            errorMessage = "Couldn't save the imported song. The file was not imported."
            return false
        }

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
        resetLyricsHistory()
        return true
    }

    func snapshotForExport() -> SongProject {
        makeUntitledSongProject(id: currentProjectId ?? UUID().uuidString)
    }

    func applyTemplate(_ template: SongTemplate) {
        cancelEditorAIWork()
        title = "Untitled \(template.name)"
        theme = template.theme
        lyrics = template.lyrics
        cursorPosition = 0
        currentProjectId = nil
        suggestions = []
        saveStatus = .idle
        showWelcome = false
        showTemplatesSheet = false
        resetLyricsHistory()
        triggerAutoSave()
    }

    func goToStartMenu() {
        cancelEditorAIWork()
        showWelcome = true
    }

    // MARK: - Auto-Save

    /// A recording needs a project folder before any lyrics exist (people hum
    /// the melody first). Creates and persists an Untitled project on demand.
    func ensureProjectForRecording() -> String? {
        if let projectId = currentProjectId { return projectId }
        guard let context = modelContext else {
            errorMessage = "Couldn't create a song for this recording."
            return nil
        }
        let project = makeUntitledSongProject()
        context.insert(project)
        do {
            try saveModelContext(context)
        } catch {
            context.rollback()
            errorMessage = "Couldn't create a song for this recording."
            return nil
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
            guard currentProjectId != nil || !title.isEmpty || !lyrics.isEmpty || !theme.isEmpty else {
                saveStatus = .idle
                return
            }
            saveStatus = .saving

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }

            // The editor switched projects (or cleared) during the debounce —
            // saving now would write into the wrong project or create an empty one.
            guard currentProjectId == projectIdAtTrigger,
                  currentProjectId != nil || !title.isEmpty || !lyrics.isEmpty || !theme.isEmpty else {
                saveStatus = .idle
                return
            }

            _ = saveCurrentProject()
        }
    }

    @discardableResult
    func saveCurrentProject() -> Bool {
        autoSaveTask?.cancel()
        guard currentProjectId != nil || !title.isEmpty || !lyrics.isEmpty || !theme.isEmpty else { return true }
        guard let context = modelContext else {
            saveStatus = .idle
            return false
        }

        var createdProjectID: String?
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
            createdProjectID = project.id
        }

        do {
            try saveModelContext(context)
            if let createdProjectID { currentProjectId = createdProjectID }
            saveStatus = .saved
            return true
        } catch {
            context.rollback()
            saveStatus = .idle
            errorMessage = "Couldn't save this song. Your edits remain open."
            return false
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

    @discardableResult
    func saveApiKey(provider: AIProvider, key: String) -> Bool {
        if key.isEmpty {
            guard keychainStore.deleteKey(provider: provider.rawValue) else {
                return false
            }
            apiKeyPresence[provider.rawValue] = false
            inspectorCredentialRevisions[provider.rawValue, default: 0] &+= 1
            if provider == selectedProvider { cancelEditorAIWork() }
            return true
        }
        let stored = keychainStore.setKey(provider: provider.rawValue, key: key)
        if !stored {
            return false
        }
        apiKeyPresence[provider.rawValue] = true
        inspectorCredentialRevisions[provider.rawValue, default: 0] &+= 1
        if provider == selectedProvider { cancelEditorAIWork() }
        return true
    }

    // MARK: - Cloud Backup

    func refreshCloudBackupState() {
        cloudBackupConfigured = backupService?.isConfigured ?? false
        cloudBackupHasStoredPassphrase = backupService?.hasStoredPassphrase ?? false

        if !cloudBackupConfigured {
            cloudBackupStatusText = "Google Drive backup is not configured yet. Add the iOS OAuth client ID before backing up."
            cloudBackupLastResultIsError = true
        } else if !cloudBackupHasStoredPassphrase {
            cloudBackupStatusText = "Enter a backup passphrase to enable Google Drive backup."
            cloudBackupLastResultIsError = false
        } else if let backgroundFailure = backupService?.backgroundBackupFailureDescription, !backgroundFailure.isEmpty {
            cloudBackupStatusText = "Background backup failed: \(backgroundFailure)"
            cloudBackupLastResultIsError = true
        } else if cloudBackupStatusText == "Google Drive backup is unavailable in this build."
            || cloudBackupStatusText.contains("not configured")
            || cloudBackupStatusText.contains("Enter a backup passphrase")
            || cloudBackupStatusText.hasPrefix("Background backup failed:") {
            cloudBackupStatusText = "Ready to back up projects, trash, and recordings."
            cloudBackupLastResultIsError = false
        }
    }

    func updateCloudBackupPassphrase(_ passphrase: String) {
        // Trim exactly the ASCII space/tab/CR/LF set (not Unicode whitespace) so the
        // accepted passphrase matches Android's byte-for-byte trimming.
        let trimmed = passphrase.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        guard Self.isPortableBackupPassphrase(trimmed) else {
            cloudBackupConfigured = backupService?.isConfigured ?? false
            cloudBackupHasStoredPassphrase = backupService?.hasStoredPassphrase ?? false
            cloudBackupStatusText = "Use at least 8 characters (printable ASCII) so your backup restores on any device."
            cloudBackupLastResultIsError = true
            return
        }

        do {
            try backupService?.updatePassphrase(trimmed)
        } catch {
            cloudBackupConfigured = backupService?.isConfigured ?? false
            cloudBackupHasStoredPassphrase = backupService?.hasStoredPassphrase ?? false
            cloudBackupStatusText = (error as? LocalizedError)?.errorDescription
                ?? "Could not securely store your backup passphrase. Try again."
            cloudBackupLastResultIsError = true
            return
        }
        refreshCloudBackupState()
    }

    private static func isPortableBackupPassphrase(_ passphrase: String) -> Bool {
        guard passphrase.count >= 8 else { return false }
        return passphrase.unicodeScalars.allSatisfy { scalar in
            (0x20...0x7e).contains(Int(scalar.value))
        }
    }

    func backUpNow() async {
        guard let backupService, let context = modelContext, canRunCloudBackup else {
            refreshCloudBackupState()
            return
        }

        cloudBackupIsWorking = true
        cloudBackupLastResultIsError = false
        cloudBackupStatusText = "Encrypting backup for Google Drive..."
        defer {
            cloudBackupIsWorking = false
            cloudBackupConfigured = backupService.isConfigured
            cloudBackupHasStoredPassphrase = backupService.hasStoredPassphrase
        }

        do {
            try await backupService.backupNow(modelContext: context)
            cloudBackupStatusText = "Backup complete. Projects, trash, and recordings are encrypted in Google Drive."
        } catch {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Backup failed: \(cloudBackupErrorDescription(error))"
        }
    }

    func restoreBackupNow() async {
        guard let backupService, let context = modelContext, canRunCloudBackup else {
            refreshCloudBackupState()
            return
        }

        cloudBackupIsWorking = true
        cloudBackupLastResultIsError = false
        cloudBackupStatusText = "Restoring encrypted Google Drive backup..."
        defer {
            cloudBackupIsWorking = false
            cloudBackupConfigured = backupService.isConfigured
            cloudBackupHasStoredPassphrase = backupService.hasStoredPassphrase
        }

        do {
            try await backupService.restoreNow(modelContext: context)
            cloudBackupStatusText = "Restore complete. Projects, trash, and missing recordings were restored."
        } catch {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Restore failed: \(cloudBackupErrorDescription(error))"
        }
    }

    func runCloudBackupOnBackgroundIfPossible() async {
        refreshCloudBackupState()
        guard let backupService,
              let context = modelContext,
              cloudBackupConfigured,
              cloudBackupHasStoredPassphrase else {
            return
        }

        await backupService.backupInBackgroundIfPossible(modelContext: context)
        refreshCloudBackupState()
    }

    private func cloudBackupErrorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    func saveProvider(_ provider: AIProvider) {
        cancelEditorAIWork()
        inspectorSynonymSourceRevision &+= 1
        selectedProvider = provider
        defaults.set(provider.rawValue, forKey: "selectedProvider")
        if selectedModel.provider != provider {
            if let first = AIModel.models(for: provider).first {
                saveModel(first)
            }
        }
    }

    func saveModel(_ model: AIModel) {
        cancelEditorAIWork()
        inspectorSynonymSourceRevision &+= 1
        selectedModel = model
        defaults.set(model.rawValue, forKey: "selectedModel")
    }

    var cloudAISharingDisclosure: String {
        "Suggestions share your theme, target line, and rhyme settings. Whole Song Context also shares the full lyric. Rewrites share the selected passage and, when Whole Song Context is on, the full lyric. Synonyms share the selected word and its current line. Requests go directly to \(selectedProvider.displayName)."
    }

    func hasCloudAISharingConsent(
        for provider: AIProvider? = nil,
        scope: CloudAISharingScope? = nil
    ) -> Bool {
        let provider = provider ?? selectedProvider
        let scope = scope ?? (useWholeSongContext ? .wholeSong : .selectedContext)
        return provider == .local || defaults.bool(forKey: cloudAIConsentKey(provider, scope: scope))
    }

    func setCloudAISharingConsent(
        _ allowed: Bool,
        for provider: AIProvider? = nil,
        scope: CloudAISharingScope? = nil
    ) {
        let provider = provider ?? selectedProvider
        let scope = scope ?? (useWholeSongContext ? .wholeSong : .selectedContext)
        guard provider != .local else { return }
        defaults.set(allowed, forKey: cloudAIConsentKey(provider, scope: scope))
        if !allowed {
            cancelEditorAIWork()
        }
    }

    func approveCloudAISharing(_ request: CloudAISharingRequest) {
        guard pendingCloudAIRequestID == request.id,
              selectedProvider == request.provider,
              cloudAISharingScope(for: request.purpose) == request.scope else {
            cancelCloudAISharing()
            return
        }
        defaults.set(true, forKey: cloudAIConsentKey(request.provider, scope: request.scope))
        let action = pendingCloudAIAction
        pendingCloudAIAction = nil
        pendingCloudAIRequestID = nil
        cloudAISharingRequest = nil
        action?()
    }

    func cancelCloudAISharing() {
        pendingCloudAIAction = nil
        pendingCloudAIRequestID = nil
        cloudAISharingRequest = nil
    }

    private func authorizeCloudAI(purpose: String, action: @escaping () -> Void) -> Bool {
        guard selectedProvider != .local else { return true }
        let scope = cloudAISharingScope(for: purpose)
        guard !hasCloudAISharingConsent(scope: scope) else { return true }
        let request = CloudAISharingRequest(provider: selectedProvider, purpose: purpose, scope: scope)
        pendingCloudAIAction = action
        pendingCloudAIRequestID = request.id
        cloudAISharingRequest = request
        return false
    }

    private func cloudAISharingScope(for purpose: String) -> CloudAISharingScope {
        purpose == "synonyms" || !useWholeSongContext ? .selectedContext : .wholeSong
    }

    private func cloudAIConsentKey(_ provider: AIProvider, scope: CloudAISharingScope) -> String {
        "privacy.cloudAISharingConsent.v2.\(provider.rawValue).\(scope.rawValue)"
    }

    // MARK: - Editor Toggle Persistence

    func saveUseWholeSongContext(_ value: Bool) {
        cancelEditorAIWork()
        useWholeSongContext = value
        defaults.set(value, forKey: "editor.useWholeSongContext")
    }

    func saveIsHighlightEnabled(_ value: Bool) {
        isHighlightEnabled = value
        defaults.set(value, forKey: "editor.isHighlightEnabled")
    }

    func saveIsSyllableColoringEnabled(_ value: Bool) {
        isSyllableColoringEnabled = value
        defaults.set(value, forKey: "editor.isSyllableColoringEnabled")
    }

    func saveIsStressPreviewEnabled(_ value: Bool) {
        isStressPreviewEnabled = value
        defaults.set(value, forKey: "editor.isStressPreviewEnabled")
    }

    func saveIsRhymeHighlightEnabled(_ value: Bool) {
        isRhymeHighlightEnabled = value
        defaults.set(value, forKey: "editor.isRhymeHighlightEnabled")
    }

    func saveIsBeatGridEnabled(_ value: Bool) {
        isBeatGridEnabled = value
        defaults.set(value, forKey: "editor.isBeatGridEnabled")
    }
}
