import Combine
import Foundation
import SwiftData
import SwiftUI

enum SaveStatus {
    case idle, saving, saved, failed
}

@MainActor
protocol CloudBackupServicing: AnyObject {
    var isConfigured: Bool { get }
    var hasStoredPassphrase: Bool { get }
    var backgroundBackupFailureDescription: String? { get }
    var recordingRecoveryRoot: URL? { get }

    func updatePassphrase(_ passphrase: String) throws
    func backupNow(modelContext: ModelContext) async throws
    func restoreNow(modelContext: ModelContext) async throws
    func backupInBackgroundIfPossible(modelContext: ModelContext) async
}

extension CloudBackupServicing {
    var backgroundBackupFailureDescription: String? { nil }
    var recordingRecoveryRoot: URL? { nil }
}

extension BackupService: CloudBackupServicing {}

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

private final class OpenRecordingSnapshot {
    private let recordingsRoot: URL
    private let snapshotFolder: URL

    init?(projectId: String, recordingsRoot: URL) throws {
        let recordings = try RecordingBackupManifest.scan(projectIds: [projectId], memosRoot: recordingsRoot)
        guard !recordings.isEmpty else { return nil }
        self.recordingsRoot = recordingsRoot
        let stagingRoot = recordingsRoot.deletingLastPathComponent()
            .appendingPathComponent("recording-recovery", isDirectory: true)
        snapshotFolder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
        do {
            for recording in recordings {
                try FileManager.default.copyItem(
                    at: recording.localURL,
                    to: snapshotFolder.appendingPathComponent(recording.entry.fileName)
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: snapshotFolder)
            throw error
        }
    }

    func copy(to projectId: String) throws {
        let destination = try RecordingFiles.projectURL(projectId: projectId, memosRoot: recordingsRoot)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(
            at: recordingsRoot, withIntermediateDirectories: true
        )
        do {
            try FileManager.default.copyItem(at: snapshotFolder, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func removeCopy(for projectId: String) {
        guard let destination = try? RecordingFiles.projectURL(projectId: projectId, memosRoot: recordingsRoot) else { return }
        try? FileManager.default.removeItem(at: destination)
    }

    func discard() {
        try? FileManager.default.removeItem(at: snapshotFolder)
    }
}

/// The open draft as last typed while a backup or restore held the library.
/// Kept in a file outside the SwiftData store so the text survives the app
/// being killed before the operation reconciles it.
private struct DraftRecoveryRecord: Codable {
    var projectId: String?
    var title: String
    var lyrics: String
    var theme: String
    var baselineTitle: String
    var baselineLyrics: String
    var baselineTheme: String
    var savedAt: Date
    /// The id the interrupted operation would give this draft if it had to be
    /// saved as a separate song. A song with this id means it already was.
    var separateCopyId: String?
}

private struct InspectorSynonymRequestIdentity: Equatable {
    let provider: AIProvider
    let modelID: String
    let sourceRevision: Int
    let credentialRevision: Int
    let localIdentity: SynonymLocalIdentity?
}

struct AISuggestionInput {
    let provider: AIProvider
    let apiKey: String
    let modelID: String
    let theme: String
    let lyrics: String
    let stanzaLines: [String]
    let targetRhymeLine: String?
    let rhymeType: RhymeType
    let rhymeScheme: String
    let currentLetter: String
    let currentSection: SongSection
    let sectionOrdinal: Int
    let firstChorusLines: [String]?
    let complexity: RhymeComplexity
    let useWholeSongContext: Bool
}

final class EditorViewModel: ObservableObject {

    // MARK: - Editor State

    @Published var title: String = ""
    @Published var lyrics: String = "" {
        didSet {
            if lyrics != oldValue { clearInsertionFeedback() }
            scheduleDerivedStateRefresh()
        }
    }
    @Published var theme: String = "" {
        didSet {
            if theme != oldValue { triggerAutoSave() }
        }
    }
    @Published var cursorPosition: Int = 0 {
        didSet {
            scheduleDerivedStateRefresh()
        }
    }
    @Published private(set) var canUndoLyrics: Bool = false
    @Published private(set) var canRedoLyrics: Bool = false
    @Published private(set) var insertedLineRange: NSRange?
    @Published private(set) var insertionFeedbackID: UUID?
    private var insertionFeedbackText: String?

    func clearInsertionFeedback() {
        guard insertionFeedbackID != nil || insertedLineRange != nil else { return }
        insertedLineRange = nil
        insertionFeedbackID = nil
        insertionFeedbackText = nil
    }

    func clearInsertionHighlight() {
        insertedLineRange = nil
    }

    func undoInsertedLine() {
        guard insertionFeedbackID != nil, lyrics == insertionFeedbackText else { return }
        undoLyrics()
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

    @Published var selectedRange: NSRange = NSRange(location: 0, length: 0) {
        didSet { schedulePositionSave() }
    }
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
    private var inspectorSynonymsRequestID: UUID?
    private var inspectorSynonymSourceRevision = 0
    private var inspectorCredentialRevisions: [String: Int] = [:]
    private var shouldOpenSettingsAfterInspectorDismissal = false
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

    @Published var companion = WritingCompanion()
    @Published var showNotebook = false
    @Published var companionError: String?
    @Published var positionRestoreID = UUID()
    var editorScrollY: Double = 0
    private var positionSaveTask: Task<Void, Never>?
    private let companionStore: WritingCompanionStore
    private var companionReadable = true

    // MARK: - Settings

    @Published var selectedProvider: AIProvider = .local
    @Published var selectedModel: AIModel = .localModel
    /// Surfaces whether each provider has any key stored. The actual key values
    /// never live in observable state — they are pulled from the Keychain on
    /// demand at request time so they cannot leak via heap dumps, SwiftUI
    /// snapshots, or test fixtures.
    @Published private(set) var apiKeyPresence: [String: Bool] = [:]

    // MARK: - Cloud Backup

    @Published private(set) var cloudBackupConfigured: Bool = false
    @Published private(set) var cloudBackupHasStoredPassphrase: Bool = false
    @Published private(set) var cloudBackupIsWorking: Bool = false
    private var activeCloudEditorOperation: CloudEditorOperation?
    private var pendingRecordingRecovery: OpenRecordingSnapshot?
    private let draftRecoveryURL: URL?
    private var didAttemptDraftRecovery = false
    /// True once this session may write and remove its own recovery file: the
    /// library is on disk and any file left by an earlier session was set aside.
    private var draftRecoveryUsable = false
    @Published private(set) var cloudBackupStatusText: String = "Google Drive backup is unavailable in this build."
    @Published private(set) var cloudBackupLastResultIsError: Bool = false

    // MARK: - Internal

    // ModelContext does not keep its ModelContainer alive, and SwiftData traps when a
    // context is used after its container is gone. A pending autosave can outlive the
    // caller that owned the container, so hold it for as long as the context is set.
    private var modelContainer: ModelContainer?

    var modelContext: ModelContext? {
        didSet {
            modelContainer = modelContext?.container
            applyPersistedDeletions()
            purgeExpiredTrashedProjects()
            recoverInterruptedDraftIfNeeded()
            seedTrashProjectForUITestsIfNeeded()
            refreshCloudBackupState()
        }
    }
    private let aiService: AIService
    private let synonymService: any SynonymProviding
    private let defaults: UserDefaults
    @Published var cloudAISharingRequest: CloudAISharingRequest?
    private var pendingCloudAIAction: (() -> Void)?
    private var pendingCloudAIRequestID: UUID?
    private let keychainStore: KeychainStore
    private let backupService: CloudBackupServicing?
    private let lyricsHistory = EditHistory<LyricsEditState>()
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

    private let saveModelContext: (ModelContext) throws -> Void

    init(aiService: AIService = AIService(), keychainStore: KeychainStore? = nil, backupService: CloudBackupServicing? = nil, companionStore: WritingCompanionStore? = nil, synonymService: (any SynonymProviding)? = nil, defaults: UserDefaults = .standard, draftRecoveryURL: URL? = nil, saveModelContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.aiService = aiService
        self.synonymService = synonymService ?? aiService
        self.defaults = defaults
        self.saveModelContext = saveModelContext
        let runningUITestInMemory = UITestFlags.isEnabled(UITestFlags.inMemoryStore)
        let resolvedStore: KeychainStore = keychainStore
            ?? (runningUITestInMemory ? InMemoryKeychainStore() : SystemKeychainStore())
        self.companionStore = companionStore ?? WritingCompanionStore(inMemory: runningUITestInMemory || keychainStore != nil)
        self.keychainStore = resolvedStore
        self.backupService = backupService
        if let draftRecoveryURL {
            self.draftRecoveryURL = draftRecoveryURL
        } else if runningUITestInMemory || keychainStore != nil {
            self.draftRecoveryURL = nil
        } else {
            self.draftRecoveryURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("DraftRecovery", isDirectory: true)
                .appendingPathComponent("open-draft.json")
        }

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
        let modelRaw = defaults.string(forKey: "selectedModel") ?? AIModel.default.rawValue
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

        if UITestFlags.isEnabled(UITestFlags.seedRewriteSelection) {
            let seededLyrics = "yellow music\nfollow music"
            title = "UI Rewrite Song"
            lyrics = seededLyrics
            selectedRange = NSRange(location: 0, length: ("yellow music" as NSString).length)
            cursorPosition = selectedRange.location + selectedRange.length
            showWelcome = false
        }
        if UITestFlags.isEnabled(UITestFlags.seedSuggestions) {
            title = "UI Suggestion Song"
            lyrics = "An opening line"
            cursorPosition = lyrics.utf16.count
            selectedRange = NSRange(location: cursorPosition, length: 0)
            suggestions = [SuggestedLine(text: "A quiet light carries me home", tier: 0)]
            isSyllableColoringEnabled = true
            showWelcome = false
        }
        if UITestFlags.isEnabled(UITestFlags.forceSaveFailed) {
            saveStatus = .failed
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

    private nonisolated struct LyricsDerivedState: Sendable {
        let wordCount: Int
        let syllableCount: Int
        let rhymeContext: RhymeContext
    }

    private func scheduleDerivedStateRefresh() {
        derivedStateTask?.cancel()
        derivedStateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            let lyrics = self.lyrics
            let cursorPosition = self.cursorPosition
            let rhymeScheme = self.activeRhymeScheme
            let derived = await Task.detached(priority: .userInitiated) {
                LyricsDerivedState(
                    wordCount: SyllableCounter.lyricWordCount(lyrics),
                    syllableCount: SyllableCounter.lyricSyllableCount(lyrics),
                    rhymeContext: Self.computeRhymeContext(
                        lyrics: lyrics,
                        cursorPosition: cursorPosition,
                        activeRhymeScheme: rhymeScheme
                    )
                )
            }.value
            guard !Task.isCancelled,
                  self.lyrics == lyrics,
                  self.cursorPosition == cursorPosition,
                  self.activeRhymeScheme == rhymeScheme else {
                return
            }
            self.objectWillChange.send()
            self.wordCount = derived.wordCount
            self.syllableCount = derived.syllableCount
            self.rhymeContext = derived.rhymeContext
        }
    }

    /// `cursorPosition` comes from UITextView in UTF-16 units, but the String
    /// operations in this file count Characters (grapheme clusters). Convert once
    /// at the boundary so emoji/CJK lyrics don't skew offsets; snaps to the nearest
    /// preceding grapheme boundary when the offset lands inside a cluster.
    nonisolated static func characterOffset(forUTF16Offset offset: Int, in text: String) -> Int {
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
        Self.computeRhymeContext(
            lyrics: lyrics,
            cursorPosition: cursorPosition,
            activeRhymeScheme: activeRhymeScheme
        )
    }

    nonisolated private static func computeRhymeContext(
        lyrics: String,
        cursorPosition: Int,
        activeRhymeScheme: String
    ) -> RhymeContext {
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

        let cursorLineIndex = min(max(globalCursorLineIndex, 0), rawLines.count - 1)
        let isBlankLine: (Int) -> Bool = { index in
            rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let stanzaStartLine = rawLines.indices.prefix(cursorLineIndex)
            .last(where: isBlankLine)
            .map { $0 + 1 } ?? 0
        let stanzaEndLine: Int
        if isBlankLine(cursorLineIndex) {
            stanzaEndLine = cursorLineIndex + 1
        } else {
            stanzaEndLine = rawLines.indices.dropFirst(cursorLineIndex + 1)
                .first(where: isBlankLine) ?? rawLines.endIndex
        }
        let stanzaLines = Array(rawLines[stanzaStartLine..<stanzaEndLine])

        // Determine the raw cursor line, then map only real lyric lines to the rhyme scheme.
        let rawCursorLineIndex = cursorLineIndex - stanzaStartLine
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

    private nonisolated struct RhymeSectionContext {
        let currentSection: SongSection
        let sectionOrdinal: Int
        let firstChorusLines: [String]?
    }

    nonisolated private static func sectionContext(
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

    nonisolated private static func targetLine(
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

    nonisolated private static func isSectionHeader(_ line: String) -> Bool {
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
        let input = makeSuggestionInput()
        suggestionsTask?.cancel()
        let requestID = UUID()
        suggestionsRequestID = requestID
        // Navigation and provider changes invalidate this request through cancelEditorAIWork().
        // The first autosave can assign a project ID while generation is in flight.
        isLoading = true
        errorMessage = nil
        suggestions = []

        let stream = aiService.streamSuggestions(
            provider: input.provider,
            apiKey: input.apiKey,
            modelId: input.modelID,
            theme: input.theme,
            lyrics: input.lyrics,
            stanzaLines: input.stanzaLines,
            targetRhymeLine: input.targetRhymeLine,
            rhymeType: input.rhymeType,
            rhymeScheme: input.rhymeScheme,
            currentLetter: input.currentLetter,
            currentSection: input.currentSection,
            sectionOrdinal: input.sectionOrdinal,
            firstChorusLines: input.firstChorusLines,
            complexity: input.complexity,
            useWholeSongContext: input.useWholeSongContext
        )

        // Compute tier per emitted line using the same filter the streaming
        // path uses, so the badge always agrees with what was held/passed.
        let filter = RhymeLineFilter(targetLine: input.targetRhymeLine, rhymeType: input.rhymeType)

        // Hook-repeat: end words from first chorus used to flag "hook" badge
        // variant on subsequent choruses.
        let firstChorusEndWordSet: Set<String> = {
            guard input.currentSection == .chorus, input.sectionOrdinal >= 2,
                  let lines = input.firstChorusLines else { return [] }
            return Set(lines.compactMap { line -> String? in
                let w = RhymeConstraint.lineEndWord(line)
                return w.isEmpty ? nil : w
            })
        }()

        suggestionsTask = Task { @MainActor in
            defer {
                if self.suggestionsRequestID == requestID { self.isLoading = false }
            }
            do {
                var emittedSuggestion = false
                for try await text in stream {
                    guard !Task.isCancelled, self.suggestionsRequestID == requestID else { return }
                    emittedSuggestion = true
                    let tier = filter?.tier(of: text) ?? 0
                    let endWord = RhymeConstraint.lineEndWord(text)
                    let isHookRepeat = !firstChorusEndWordSet.isEmpty && firstChorusEndWordSet.contains(endWord)
                    self.suggestions.append(SuggestedLine(text: text, tier: tier, isHookRepeat: isHookRepeat))
                }
                if !emittedSuggestion, !Task.isCancelled, self.suggestionsRequestID == requestID {
                    self.errorMessage = "AI did not return suggestions. Try again."
                }
            } catch is CancellationError {
                // expected when cancelSuggestions() is invoked
            } catch {
                guard self.suggestionsRequestID == requestID else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func makeSuggestionInput() -> AISuggestionInput {
        let context = computeRhymeContext()
        return AISuggestionInput(
            provider: selectedProvider,
            apiKey: currentApiKey,
            modelID: selectedModel.id,
            theme: theme,
            lyrics: lyrics,
            stanzaLines: context.stanzaLines,
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
    }

    func suggestionInputForTest() -> AISuggestionInput {
        makeSuggestionInput()
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
            defer {
                if rewriteRequestID == requestID { rewriteLoading = false }
            }
            do {
                try Task.checkCancellation()
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
                    rejectedCandidates: rejectedForRequest,
                    useWholeSongContext: useWholeSongContext
                )
                guard !Task.isCancelled, rewriteRequestID == requestID else { return }
                rewritePreview = result
            } catch {
                guard !Task.isCancelled, rewriteRequestID == requestID else { return }
                rewriteError = error.localizedDescription
            }
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
                      self.inspectorRange == range,
                      self.currentLine(for: range) == lineContext,
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
                      self.inspectorRange == range,
                      self.currentLine(for: range) == lineContext,
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

    func currentLine(for range: NSRange) -> String {
        // UITextView ranges are UTF-16; stay in NSString offsets throughout.
        let ns = lyrics as NSString
        guard range.location <= ns.length else { return "" }
        let safeLoc = min(range.location, ns.length)
        let safeEnd = min(range.location + range.length, ns.length)
        let previousNewline = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: safeLoc))
        let lineStartOffset = previousNewline.location == NSNotFound ? 0 : NSMaxRange(previousNewline)
        let nextNewline = ns.range(of: "\n", options: [], range: NSRange(location: safeEnd, length: ns.length - safeEnd))
        let lineEndOffset = nextNewline.location == NSNotFound ? ns.length : nextNewline.location
        guard lineStartOffset <= lineEndOffset else { return "" }
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
        if cloudAISharingRequest?.purpose == "synonyms" { cancelCloudAISharing() }
        inspectorSynonymsRequestID = nil
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
        insertedLineRange = NSRange(location: before.utf16.count + (needsNewline ? 1 : 0), length: suggestion.utf16.count)
        insertionFeedbackText = lyrics
        insertionFeedbackID = UUID()
        suggestions = []
        triggerAutoSave()
    }

    func insertSection(_ label: String) {
        let insertion = SectionMap.insertHeader(label, in: lyrics, cursor: cursorPosition)
        applyAtomicLyricsEdit(text: insertion.text, cursorPosition: insertion.cursor)
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
        clearInsertionFeedback()
        guard let previous = lyricsHistory.undo(current: currentLyricsEditState) else { return }
        applyHistoryState(previous)
    }

    func redoLyrics() {
        clearInsertionFeedback()
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
        clearInsertionFeedback()
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
        clearInsertionFeedback()
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

    func cancelEditorAIWork() {
        cancelCloudAISharing()
        cancelSuggestions()
        dismissRewrite()
        dismissInspector()
    }

    // MARK: - Project Management

    func newProject() {
        guard preserveOutgoingDraftBeforeNavigation(checkpoint: true) else { return }
        cancelEditorAIWork()
        autoSaveTask?.cancel()
        title = ""
        lyrics = ""
        theme = ""
        cursorPosition = 0
        currentProjectId = nil
        resetCompanionPosition()
        suggestions = []
        errorMessage = nil
        saveStatus = .idle
        showWelcome = false
        showProjectsSheet = false
        resetLyricsHistory()
        trackSelectedDraftDuringCloudOperation()
    }

    func loadProject(_ project: SongProject) {
        let nextRecordingSnapshot: OpenRecordingSnapshot?
        do {
            if activeCloudEditorOperation != nil,
               let root = backupService?.recordingRecoveryRoot {
                nextRecordingSnapshot = try OpenRecordingSnapshot(
                    projectId: project.id, recordingsRoot: root
                )
            } else {
                nextRecordingSnapshot = nil
            }
        } catch {
            errorMessage = "Could not protect this song's recordings. Switching songs was canceled."
            return
        }
        guard preserveOutgoingDraftBeforeNavigation(checkpoint: true) else {
            nextRecordingSnapshot?.discard()
            return
        }
        cancelEditorAIWork()
        autoSaveTask?.cancel()
        title = project.title
        lyrics = project.lyrics
        theme = project.theme
        cursorPosition = 0
        currentProjectId = project.id
        restoreCompanionPosition()
        suggestions = []
        errorMessage = nil
        saveStatus = .idle
        showWelcome = false
        showProjectsSheet = false
        resetLyricsHistory()
        trackSelectedDraftDuringCloudOperation(recordingSnapshot: nextRecordingSnapshot)
    }

    static let projectDeletionBlockedText = "This song can be moved to Trash once the backup or restore finishes."

    /// Why `moveProjectToTrash` refuses right now, for the list that asked. Kept
    /// out of `errorMessage`, which the assistant panel treats as an AI failure.
    var projectDeletionBlockedMessage: String? {
        activeCloudEditorOperation != nil ? Self.projectDeletionBlockedText : nil
    }

    @discardableResult
    func moveProjectToTrash(_ project: SongProject) -> Bool {
        if activeCloudEditorOperation != nil { return false }
        if currentProjectId == project.id, !flushCurrentDraft(checkpoint: true) { return false }
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
        if !RecordingFiles.deleteMemosFolder(for: projectId) {
            errorMessage = "This song was permanently deleted, but its local recordings could not be removed. Writers Block will retry cleanup."
        }
        do { try companionStore.remove(projectId) } catch { companionError = "Could not remove this song’s local notebook." }
        scheduleTrashPurge()
        return true
    }

    func purgeExpiredTrashedProjects() {
        guard let context = modelContext else { return }
        let now = Date()
        let expiredMemos = RecordingFiles.trashedMemos().filter { $0.deleteAfter <= now }
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
            for projectId in projectIDs where !RecordingFiles.deleteMemosFolder(for: projectId) {
                errorMessage = "Expired writing was removed, but some local recordings could not be cleaned up. Writers Block will retry."
            }
            for projectId in projectIDs { try companionStore.remove(projectId) }
            for memo in expiredMemos {
                _ = voiceMemoService.permanentlyDeleteTrashedMemo(memo)
            }
        } catch {
            context.rollback()
            errorMessage = "Couldn't finish removing expired Trash items. They were kept for the next attempt."
        }
        scheduleTrashPurge()
    }

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
                _ = RecordingFiles.deleteMemosFolder(for: projectId)
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
        let nextMemoExpiry = RecordingFiles.nextTrashedMemoExpiry().flatMap { $0 > now ? $0 : nil }
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
        cancelEditorAIWork()
        title = ""
        lyrics = ""
        theme = ""
        cursorPosition = 0
        currentProjectId = nil
        resetCompanionPosition()
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
        guard let context = modelContext, preserveOutgoingDraftBeforeNavigation(checkpoint: true) else { return false }
        autoSaveTask?.cancel()
        cancelEditorAIWork()
        let project = makeImportedProject(from: exported)
        context.insert(project)
        do { try saveModelContext(context) }
        catch {
            context.rollback()
            errorMessage = "Couldn't save the imported song. The file was not imported."
            return false
        }
        cancelEditorAIWork()

        title = project.title
        lyrics = project.lyrics
        theme = project.theme
        cursorPosition = project.lyrics.utf16.count
        currentProjectId = project.id
        resetCompanionPosition()
        suggestions = []
        errorMessage = nil
        saveStatus = .saved
        showWelcome = false
        showProjectsSheet = false
        resetLyricsHistory()
        trackSelectedDraftDuringCloudOperation()
        return true
    }

    func snapshotForExport() -> SongProject {
        makeUntitledSongProject(id: currentProjectId ?? UUID().uuidString)
    }

    func applyTemplate(_ template: SongTemplate) {
        guard preserveOutgoingDraftBeforeNavigation(checkpoint: true) else { return }
        cancelEditorAIWork()
        title = "Untitled \(template.name)"
        theme = template.theme
        lyrics = template.lyrics
        cursorPosition = 0
        currentProjectId = nil
        resetCompanionPosition()
        suggestions = []
        saveStatus = .idle
        showWelcome = false
        showTemplatesSheet = false
        resetLyricsHistory()
        trackSelectedDraftDuringCloudOperation(isUnsaved: true)
        triggerAutoSave()
    }

    func goToStartMenu() {
        guard flushCurrentDraft(checkpoint: true) else { return }
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
        if activeCloudEditorOperation != nil {
            saveStatus = .saving
            // The library is held by the backup or restore, so this edit cannot be
            // saved yet. Write it to the recovery file now: a kill before the
            // operation reconciles must not lose it.
            updateDraftRecoveryCopy()
            return
        }
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

            _ = persistCurrentDraft(checkpoint: false)
        }
    }

    @discardableResult
    func flushCurrentDraft(checkpoint: Bool = false) -> Bool {
        guard activeCloudEditorOperation == nil else { return false }
        autoSaveTask?.cancel()
        positionSaveTask?.cancel()
        guard !showWelcome || currentProjectId != nil else { return true }
        return persistCurrentDraft(checkpoint: checkpoint)
    }

    private func persistCurrentDraft(checkpoint: Bool) -> Bool {
        guard activeCloudEditorOperation == nil else { return false }
        guard currentProjectId != nil || !title.isEmpty || !lyrics.isEmpty || !theme.isEmpty else { return true }
        guard let context = modelContext else {
            saveStatus = .failed
            errorMessage = "Couldn't save this song. Your edits remain open."
            return false
        }
        var createdProjectID: String?
        do {
            if let id = currentProjectId {
                let descriptor = FetchDescriptor<SongProject>(predicate: #Predicate { $0.id == id })
                guard let project = try context.fetch(descriptor).first else {
                    saveStatus = .idle
                    errorMessage = "This song is no longer in the library. Your edits remain open."
                    return false
                }
                if project.title != normalizedProjectTitle() || project.lyrics != lyrics || project.theme != theme {
                    project.title = normalizedProjectTitle()
                    project.lyrics = lyrics
                    project.theme = theme
                    project.updatedAt = Date()
                }
            } else {
                let project = makeUntitledSongProject()
                try pendingRecordingRecovery?.copy(to: project.id)
                context.insert(project)
                createdProjectID = project.id
            }
            try saveModelContext(context)
            if let createdProjectID { currentProjectId = createdProjectID }
            if createdProjectID != nil {
                pendingRecordingRecovery?.discard()
                pendingRecordingRecovery = nil
            }
            saveStatus = .saved
            removeDraftRecoveryCopy()
            saveCompanion(checkpoint: checkpoint)
            return true
        } catch {
            context.rollback()
            if let createdProjectID { pendingRecordingRecovery?.removeCopy(for: createdProjectID) }
            // .failed keeps the editor's retry control visible; the edits are still in memory.
            saveStatus = .failed
            errorMessage = "Couldn't save this song. Your edits remain open."
            return false
        }
    }

    func saveCompanion(checkpoint: Bool) {
        guard companionReadable else { return }
        guard let id = currentProjectId else { return }
        var next = companion
        next.position = WritingPosition(location: selectedRange.location, length: selectedRange.length, scrollY: editorScrollY).clamped(to: lyrics)
        if !title.isEmpty || !lyrics.isEmpty || !theme.isEmpty {
            next.checkpoint(title: normalizedProjectTitle(), lyrics: lyrics, theme: theme, force: checkpoint)
        }
        persistCompanion(next, id: id)
    }

    private func persistCompanion(_ next: WritingCompanion, id: String) {
        guard companionReadable else { return }
        do {
            try companionStore.write(next, for: id)
            companion = next
            companionError = nil
        } catch { companionError = "Could not save the song notebook. Your current lyrics are unchanged. Try again." }
    }

    func schedulePositionSave() {
        positionSaveTask?.cancel()
        guard currentProjectId != nil else { return }
        positionSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            saveCompanion(checkpoint: false)
        }
    }

    func updateEditorScroll(_ y: Double) {
        editorScrollY = max(0, y)
        schedulePositionSave()
    }

    private func resetCompanionPosition() {
        positionSaveTask?.cancel()
        companion = WritingCompanion()
        companionReadable = true
        companionError = nil
        selectedRange = NSRange(location: 0, length: 0)
        editorScrollY = 0
        positionRestoreID = UUID()
    }

    private func restoreCompanionPosition() {
        resetCompanionPosition()
        guard let id = currentProjectId else { return }
        do { companion = try companionStore.read(id) }
        catch {
            companionReadable = false
            companionError = "Could not read this song’s notebook. Its saved lyrics are still available."
        }
        let position = companion.position.clamped(to: lyrics)
        selectedRange = NSRange(location: position.location, length: position.length)
        cursorPosition = position.location + position.length
        editorScrollY = position.scrollY
        positionRestoreID = UUID()
    }

    func keepAlternate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard flushCurrentDraft() else { return }
        if currentProjectId == nil, modelContext != nil { _ = ensureProjectForRecording() }
        guard let id = currentProjectId else { return }
        var next = companion
        next.keep(trimmed)
        persistCompanion(next, id: id)
    }

    var selectedLyrics: String {
        let position = WritingPosition(location: selectedRange.location, length: selectedRange.length).clamped(to: lyrics)
        return (lyrics as NSString).substring(with: NSRange(location: position.location, length: position.length))
    }

    func removeAlternate(_ alternate: KeptLyric) {
        guard let id = currentProjectId else { return }
        var next = companion
        next.alternates.removeAll { $0.id == alternate.id }
        persistCompanion(next, id: id)
    }

    func restoreVersion(_ version: DraftVersion) {
        guard flushCurrentDraft(checkpoint: true), companionError == nil else { return }
        title = version.title
        theme = version.theme
        applyAtomicLyricsEdit(text: version.lyrics, cursorPosition: 0)
        editorScrollY = 0
        positionRestoreID = UUID()
        flushCurrentDraft()
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
            return true
        }
        let stored = keychainStore.setKey(provider: provider.rawValue, key: key)
        if !stored {
            return false
        }
        apiKeyPresence[provider.rawValue] = true
        inspectorCredentialRevisions[provider.rawValue, default: 0] &+= 1
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
        guard beginCloudEditorOperation(in: context) else {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Backup canceled. Save the open song before retrying; your edits remain open."
            return
        }

        cloudBackupIsWorking = true
        cloudBackupLastResultIsError = false
        cloudBackupStatusText = "Encrypting backup for Google Drive..."
        defer {
            finishCloudEditorOperation()
            cloudBackupIsWorking = false
            cloudBackupConfigured = backupService.isConfigured
            cloudBackupHasStoredPassphrase = backupService.hasStoredPassphrase
        }

        var backupFailure: Error?
        do {
            try await backupService.backupNow(modelContext: context)
        } catch {
            backupFailure = error
        }
        guard let recovered = reconcileOpenDraftAfterCloudOperation(in: context) else {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Backup finished, but the open draft could not be saved. Keep this editor open and retry saving."
            return
        }
        if let backupFailure {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Backup failed: \(cloudBackupErrorDescription(backupFailure)). Your open edits remain in the local library."
        } else if recovered {
            cloudBackupStatusText = "Backup complete. Your edits were saved as a separate local draft; back up again to include them."
        } else {
            cloudBackupStatusText = "Backup complete. Projects, trash, and recordings are encrypted in Google Drive."
        }
    }

    private struct OpenDraft: Equatable {
        let title: String
        let lyrics: String
        let theme: String
    }

    private final class CloudEditorOperation {
        var currentBaseline: OpenDraft
        var currentHadPendingEdit: Bool
        var recordingProjectId: String?
        var savedSeparateOutgoingDraft = false
        /// The id for the next draft this operation saves as a separate song.
        /// The recovery file records it so a relaunch can tell that happened.
        var separateDraftID = UUID().uuidString
        var recordingSnapshot: OpenRecordingSnapshot?

        init(currentBaseline: OpenDraft, currentHadPendingEdit: Bool,
             recordingProjectId: String?, recordingSnapshot: OpenRecordingSnapshot?) {
            self.currentBaseline = currentBaseline
            self.currentHadPendingEdit = currentHadPendingEdit
            self.recordingProjectId = recordingProjectId
            self.recordingSnapshot = recordingSnapshot
        }
    }

    private var openDraft: OpenDraft {
        OpenDraft(title: normalizedProjectTitle(), lyrics: lyrics, theme: theme)
    }

    private func storedDraft(id: String, in context: ModelContext) throws -> (SongProject, OpenDraft)? {
        let descriptor = FetchDescriptor<SongProject>(predicate: #Predicate { $0.id == id })
        guard let project = try context.fetch(descriptor).first else { return nil }
        return (project, OpenDraft(title: project.title, lyrics: project.lyrics, theme: project.theme))
    }

    private func beginCloudEditorOperation(in context: ModelContext) -> Bool {
        guard activeCloudEditorOperation == nil else { return false }
        let draft = openDraft
        let hadPendingEdit: Bool
        do {
            if let id = currentProjectId {
                hadPendingEdit = try storedDraft(id: id, in: context)?.1 != draft
            } else {
                hadPendingEdit = !title.isEmpty || !lyrics.isEmpty || !theme.isEmpty
            }
        } catch {
            errorMessage = "Could not read the open song. Your edits remain open."
            return false
        }
        guard flushCurrentDraft() else { return false }
        let recordingSnapshot: OpenRecordingSnapshot?
        do {
            if let id = currentProjectId, let root = backupService?.recordingRecoveryRoot {
                recordingSnapshot = try OpenRecordingSnapshot(projectId: id, recordingsRoot: root)
            } else {
                recordingSnapshot = pendingRecordingRecovery
            }
        } catch {
            errorMessage = "Could not protect the open song's recordings. Backup was canceled."
            return false
        }
        activeCloudEditorOperation = CloudEditorOperation(
            currentBaseline: openDraft,
            currentHadPendingEdit: hadPendingEdit,
            recordingProjectId: currentProjectId,
            recordingSnapshot: recordingSnapshot
        )
        updateDraftRecoveryCopy()
        return true
    }

    private func preserveOutgoingDraftBeforeNavigation(checkpoint: Bool = false) -> Bool {
        guard let operation = activeCloudEditorOperation else { return flushCurrentDraft(checkpoint: checkpoint) }
        autoSaveTask?.cancel()
        let draft = openDraft
        guard operation.currentHadPendingEdit || draft != operation.currentBaseline else { return true }
        guard let context = modelContext else { return false }
        let recoveredID = operation.separateDraftID
        do {
            try operation.recordingSnapshot?.copy(to: recoveredID)
            let recovered = SongProject(id: recoveredID, title: draft.title, lyrics: draft.lyrics, theme: draft.theme)
            context.insert(recovered)
            try saveModelContext(context)
            operation.savedSeparateOutgoingDraft = true
            operation.separateDraftID = UUID().uuidString
            if pendingRecordingRecovery === operation.recordingSnapshot {
                pendingRecordingRecovery = nil
            }
            operation.recordingSnapshot?.discard()
            operation.recordingSnapshot = nil
            return true
        } catch {
            context.rollback()
            operation.recordingSnapshot?.removeCopy(for: recoveredID)
            errorMessage = "Could not save this draft before switching songs. Your edits remain open."
            return false
        }
    }

    private func trackSelectedDraftDuringCloudOperation(
        isUnsaved: Bool = false,
        recordingSnapshot: OpenRecordingSnapshot? = nil
    ) {
        guard let operation = activeCloudEditorOperation else { return }
        if let oldSnapshot = operation.recordingSnapshot,
           oldSnapshot !== recordingSnapshot,
           oldSnapshot !== pendingRecordingRecovery {
            oldSnapshot.discard()
        }
        operation.currentBaseline = openDraft
        operation.currentHadPendingEdit = isUnsaved
        operation.recordingProjectId = currentProjectId
        operation.recordingSnapshot = recordingSnapshot
        updateDraftRecoveryCopy()
    }

    private func finishCloudEditorOperation() {
        if let snapshot = activeCloudEditorOperation?.recordingSnapshot,
           snapshot !== pendingRecordingRecovery {
            snapshot.discard()
        }
        activeCloudEditorOperation = nil
    }

    func restoreBackupNow() async {
        guard let backupService, let context = modelContext, canRunCloudBackup else {
            refreshCloudBackupState()
            return
        }
        guard beginCloudEditorOperation(in: context) else {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Restore canceled. Save the open song before retrying; your edits remain open."
            return
        }

        cloudBackupIsWorking = true
        cloudBackupLastResultIsError = false
        cloudBackupStatusText = "Restoring encrypted Google Drive backup..."
        defer {
            finishCloudEditorOperation()
            cloudBackupIsWorking = false
            cloudBackupConfigured = backupService.isConfigured
            cloudBackupHasStoredPassphrase = backupService.hasStoredPassphrase
        }

        var restoreFailure: Error?
        do {
            try await backupService.restoreNow(modelContext: context)
        } catch {
            restoreFailure = error
        }
        guard let recovered = reconcileOpenDraftAfterCloudOperation(in: context) else {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Restore finished, but the open draft could not be saved. Keep this editor open and retry saving."
            return
        }
        if let restoreFailure {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Restore failed: \(cloudBackupErrorDescription(restoreFailure)). Your open edits remain in the local library."
        } else if recovered {
            cloudBackupStatusText = "Restore complete. Your open edits were saved as a separate local draft."
        } else {
            cloudBackupStatusText = "Restore complete. Projects, trash, and missing recordings were restored."
        }
    }

    private func reconcileOpenDraftAfterCloudOperation(in context: ModelContext) -> Bool? {
        let recovered = reconcileOpenDraft(in: context)
        // On failure the edits exist only in the open editor, so the recovery
        // file stays until a later save succeeds.
        if recovered != nil { removeDraftRecoveryCopy() }
        return recovered
    }

    // MARK: Draft recovery file

    private func updateDraftRecoveryCopy() {
        guard draftRecoveryUsable, let url = draftRecoveryURL,
              let operation = activeCloudEditorOperation else { return }
        let draft = openDraft
        let baseline = operation.currentBaseline
        guard operation.currentHadPendingEdit || draft != baseline else {
            removeDraftRecoveryCopy()
            return
        }
        let record = DraftRecoveryRecord(
            projectId: currentProjectId,
            title: draft.title, lyrics: draft.lyrics, theme: draft.theme,
            baselineTitle: baseline.title, baselineLyrics: baseline.lyrics, baselineTheme: baseline.theme,
            savedAt: Date(),
            separateCopyId: operation.separateDraftID
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Readable while the device is locked: the background backup writes here.
            try JSONEncoder().encode(record).write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            // The edit is still in the open editor and is reconciled when the
            // operation ends; only the kill protection is missing for it.
        }
    }

    /// Removes only the file this session writes; copies left by earlier
    /// sessions have other names and are removed by their own recovery.
    private func removeDraftRecoveryCopy() {
        guard draftRecoveryUsable, let url = draftRecoveryURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private var isLibraryStoredOnDisk: Bool {
        guard let container = modelContext?.container else { return false }
        return !container.configurations.contains { $0.isStoredInMemoryOnly }
    }

    /// Runs once, when the library first becomes available after launch. A
    /// recovery file found then was left by a backup or restore that never
    /// reconciled the open draft, so apply the same rules reconciliation uses.
    private func recoverInterruptedDraftIfNeeded() {
        guard !didAttemptDraftRecovery, activeCloudEditorOperation == nil,
              let url = draftRecoveryURL, let context = modelContext else { return }
        didAttemptDraftRecovery = true
        // An in-memory library (the fallback when the real one cannot be opened,
        // and test launches) is discarded at exit. Recovering into it would lose
        // the text, so leave the files alone for a launch with the real library.
        guard isLibraryStoredOnDisk else { return }
        let fileManager = FileManager.default
        let folder = url.deletingLastPathComponent()
        // Set the earlier session's file aside under its own name before this
        // session can write or remove `url`, so a failed recovery is never
        // overwritten or deleted by this session's saves and operations.
        if fileManager.fileExists(atPath: url.path) {
            let aside = folder.appendingPathComponent("unrecovered-\(UUID().uuidString).json")
            do {
                try fileManager.moveItem(at: url, to: aside)
            } catch {
                return
            }
        }
        draftRecoveryUsable = true
        let unrecovered = ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("unrecovered-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in unrecovered {
            recoverDraft(from: file, in: context)
        }
    }

    private func recoverDraft(from file: URL, in context: ModelContext) {
        let fileManager = FileManager.default
        guard let data = try? Data(contentsOf: file) else { return }
        guard let record = try? JSONDecoder().decode(DraftRecoveryRecord.self, from: data) else {
            // Not readable by this build, but it may still hold text. Keep it under
            // a name that is not retried rather than deleting it.
            let unreadable = file.deletingLastPathComponent()
                .appendingPathComponent("unreadable-\(file.lastPathComponent)")
            try? fileManager.moveItem(at: file, to: unreadable)
            return
        }
        let draft = OpenDraft(title: record.title, lyrics: record.lyrics, theme: record.theme)
        let baseline = OpenDraft(
            title: record.baselineTitle, lyrics: record.baselineLyrics, theme: record.baselineTheme
        )
        do {
            let projects = try context.fetch(FetchDescriptor<SongProject>())
            func content(_ project: SongProject) -> OpenDraft {
                OpenDraft(title: project.title, lyrics: project.lyrics, theme: project.theme)
            }
            let stored = record.projectId.flatMap { id in projects.first { $0.id == id } }
            let separateID = record.separateCopyId ?? UUID().uuidString
            // The text already reached the library (the kill came after the save
            // but before the file was removed): nothing to recover. Only the
            // interrupted song itself, or the separate song saved under the id
            // recorded for this draft, counts. An unrelated song with the same
            // text does not: identical songs are legitimate.
            let trashedIDs = try context.fetch(FetchDescriptor<TrashedSongProject>()).map(\.id)
            let savedInPlace = stored.map { content($0) == draft } ?? false
            let savedSeparately = projects.contains { $0.id == separateID } || trashedIDs.contains(separateID)
            if savedInPlace || savedSeparately {
                try? fileManager.removeItem(at: file)
                return
            }
            let recovered: SongProject
            if let stored, content(stored) == baseline, stored.updatedAt <= record.savedAt {
                stored.title = draft.title
                stored.lyrics = draft.lyrics
                stored.theme = draft.theme
                stored.updatedAt = record.savedAt
                recovered = stored
            } else {
                // The song was replaced, deleted, or changed after this copy was
                // written. Keep both: never write old text over a newer row.
                recovered = SongProject(id: separateID, title: draft.title, lyrics: draft.lyrics, theme: draft.theme)
                context.insert(recovered)
            }
            try saveModelContext(context)
            try? fileManager.removeItem(at: file)
            loadProject(recovered)
            saveStatus = .saved
        } catch {
            context.rollback()
            errorMessage = "Could not recover the song you were editing during the last backup. It will be retried the next time the app opens."
        }
    }

    private func reconcileOpenDraft(in context: ModelContext) -> Bool? {
        guard let operation = activeCloudEditorOperation else { return nil }
        autoSaveTask?.cancel()
        let draft = openDraft
        let edited = operation.currentHadPendingEdit || draft != operation.currentBaseline

        do {
            guard operation.recordingProjectId == currentProjectId else {
                throw CocoaError(.fileReadUnknown)
            }
            let stored = try currentProjectId.flatMap { try storedDraft(id: $0, in: context) }
            if edited {
                if stored?.1 == draft {
                    if saveStatus == .saving { saveStatus = .saved }
                    return operation.savedSeparateOutgoingDraft
                }
                if let stored, stored.1 == operation.currentBaseline {
                    stored.0.title = draft.title
                    stored.0.lyrics = draft.lyrics
                    stored.0.theme = draft.theme
                    stored.0.updatedAt = Date()
                    try saveModelContext(context)
                    saveStatus = .saved
                    return operation.savedSeparateOutgoingDraft
                }
                let recoveredID = operation.separateDraftID
                try operation.recordingSnapshot?.copy(to: recoveredID)
                let recovered = SongProject(id: recoveredID, title: draft.title, lyrics: draft.lyrics, theme: draft.theme)
                context.insert(recovered)
                do {
                    try saveModelContext(context)
                } catch {
                    operation.recordingSnapshot?.removeCopy(for: recoveredID)
                    throw error
                }
                operation.recordingSnapshot?.discard()
                operation.recordingSnapshot = nil
                cancelEditorAIWork()
                currentProjectId = recovered.id
                saveStatus = .saved
                showWelcome = false
                return true
            }

            if let stored, stored.1 != draft {
                cancelEditorAIWork()
                title = stored.0.title
                lyrics = stored.0.lyrics
                theme = stored.0.theme
                selectedRange = NSRange(location: 0, length: 0)
                cursorPosition = 0
                suggestions = []
                errorMessage = nil
                saveStatus = .saved
                resetLyricsHistory()
            } else if stored == nil, currentProjectId != nil {
                clearEditorAfterProjectDelete()
                selectedRange = NSRange(location: 0, length: 0)
                showWelcome = true
            }
            if saveStatus == .saving { saveStatus = currentProjectId == nil ? .idle : .saved }
            return operation.savedSeparateOutgoingDraft
        } catch {
            context.rollback()
            pendingRecordingRecovery = operation.recordingSnapshot
            // A merged row may now own the old ID. Keep the visible draft detached
            // so a later autosave or flush cannot overwrite that remote winner.
            cancelEditorAIWork()
            currentProjectId = nil
            showWelcome = false
            saveStatus = .idle
            errorMessage = "Could not reconcile the backup with your open song. Your edits remain open."
            return nil
        }
    }

    func runCloudBackupOnBackgroundIfPossible() async {
        refreshCloudBackupState()
        guard let backupService,
              let context = modelContext,
              cloudBackupConfigured,
              cloudBackupHasStoredPassphrase,
              !cloudBackupIsWorking else {
            return
        }
        guard beginCloudEditorOperation(in: context) else {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Background backup canceled. Your open draft could not be saved."
            return
        }
        cloudBackupIsWorking = true
        await backupService.backupInBackgroundIfPossible(modelContext: context)
        let recovered = reconcileOpenDraftAfterCloudOperation(in: context)
        finishCloudEditorOperation()
        cloudBackupIsWorking = false
        refreshCloudBackupState()
        if recovered == nil {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Background backup finished, but the open draft could not be saved. Keep this editor open."
        } else if recovered == true, !cloudBackupLastResultIsError {
            cloudBackupStatusText = "Background backup finished. Your edits were saved as a separate local draft; back up again to include them."
        }
    }

    #if DEBUG
    func waitForPendingAutoSaveForTesting() async {
        await autoSaveTask?.value
    }
    #endif

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
