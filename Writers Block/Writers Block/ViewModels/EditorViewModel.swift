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
    var isConnected: Bool { get }
    var lastBackupAt: Date? { get }
    var hasLegacyBackupToMigrate: Bool { get }
    var lastReport: BackupReport? { get }
    var backgroundBackupFailureDescription: String? { get }
    var recordingRecoveryRoot: URL? { get }

    func connect() async throws
    func disconnect() async -> Bool
    func backupNow(modelContext: ModelContext) async throws
    func restoreNow(modelContext: ModelContext) async throws
    func backupInBackgroundIfPossible(modelContext: ModelContext) async
    func migrateLegacyBackup(passphrase: String, modelContext: ModelContext) async throws
    func remoteBackupSummary() async throws -> RemoteBackupSummary?
    func exportArchive(modelContext: ModelContext, now: Date) throws -> (fileName: String, data: Data)
    func importArchive(_ data: Data, modelContext: ModelContext) async throws
}

extension CloudBackupServicing {
    var lastBackupAt: Date? { nil }
    var hasLegacyBackupToMigrate: Bool { false }
    var lastReport: BackupReport? { nil }
    var backgroundBackupFailureDescription: String? { nil }
    var recordingRecoveryRoot: URL? { nil }
    func connect() async throws {}
    func disconnect() async -> Bool { true }
    func migrateLegacyBackup(passphrase: String, modelContext: ModelContext) async throws {}
    func remoteBackupSummary() async throws -> RemoteBackupSummary? { nil }
    func exportArchive(modelContext: ModelContext, now: Date) throws -> (fileName: String, data: Data) {
        throw BackupError.notConfigured
    }
    func importArchive(_ data: Data, modelContext: ModelContext) async throws {}
}

/// Google Drive backup as Settings shows it; the same cases on Android.
enum BackupStatus: Equatable {
    case notConnected
    case connected(lastBackupAt: Date?)
    case pending
    case backingUp
    case failed(reason: String, lastBackupAt: Date?)
}

/// "We found N songs and M recordings in your Google Drive backup."
struct FirstRunRestoreOffer: Identifiable, Equatable {
    let id = UUID()
    let songs: Int
    let recordings: Int
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

final class OpenRecordingSnapshot {
    private let recordingsRoot: URL
    private let snapshotFolder: URL

    /// The display names of the snapshot's files, kept beside them (A36: files
    /// are `<id>.<ext>`, the names are metadata).
    private static let namesFile = "names.json"

    init?(projectId: String, recordingsRoot: URL, displayNames: [String: String] = [:]) throws {
        let recordings = try RecordingBackupManifest.scanFiles(projectId: projectId, memosRoot: recordingsRoot)
        guard !recordings.isEmpty else { return nil }
        self.recordingsRoot = recordingsRoot
        snapshotFolder = Self.stagingRoot(for: recordingsRoot)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
        do {
            for recording in recordings {
                try FileManager.default.copyItem(
                    at: recording.url,
                    to: snapshotFolder.appendingPathComponent(recording.fileName)
                )
            }
            try JSONEncoder().encode(displayNames).write(to: snapshotFolder.appendingPathComponent(Self.namesFile), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: snapshotFolder)
            throw error
        }
    }

    /// Reopens the snapshot a killed session left on disk. `folderName` comes
    /// from a recovery file, so only a plain UUID is accepted as a path part.
    init?(existingFolderNamed folderName: String, recordingsRoot: URL) {
        guard UUID(uuidString: folderName) != nil else { return nil }
        let folder = Self.stagingRoot(for: recordingsRoot).appendingPathComponent(folderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        self.recordingsRoot = recordingsRoot
        snapshotFolder = folder
    }

    nonisolated static func stagingRoot(for recordingsRoot: URL) -> URL {
        recordingsRoot.deletingLastPathComponent()
            .appendingPathComponent("recording-recovery", isDirectory: true)
    }

    var folderName: String { snapshotFolder.lastPathComponent }

    /// Files `copy(to:)` created, by destination song, with each file's identity
    /// at creation. Rollback removes only those, and only if still the same file.
    private var createdCopies: [String: (folder: URL?, files: [(url: URL, identity: [AnyHashable]?)])] = [:]

    /// Copies the snapshot's recordings into the song's memo folder as new
    /// recordings: each copy is `<id>.<ext>` with an id derived from the song, the
    /// source and its bytes, so a repeated copy finds the earlier one. Returns the
    /// copies for the library to take in under those ids and names. A file already
    /// there is never replaced or removed.
    @discardableResult
    func copy(to projectId: String) throws -> [(url: URL, recordingId: String, displayName: String, sha256: String)] {
        let fileManager = FileManager.default
        let destination = try RecordingFiles.projectURL(projectId: projectId, memosRoot: recordingsRoot)
        let createdFolder = !fileManager.fileExists(atPath: destination.path)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let names = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: snapshotFolder.appendingPathComponent(Self.namesFile)))) ?? [:]
        var created: [(url: URL, identity: [AnyHashable]?)] = []
        var copies: [(url: URL, recordingId: String, displayName: String, sha256: String)] = []
        do {
            let sources = try fileManager.contentsOfDirectory(at: snapshotFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .filter { RecordingFiles.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
            for source in sources.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let digest = try RecordingFiles.sha256(of: source)
                let displayName = names[source.lastPathComponent] ?? source.lastPathComponent
                let id = RecordingBackupManifest.legacyRecordingId(projectId: projectId, fileName: source.lastPathComponent, sha256: digest)
                let target = destination.appendingPathComponent(RecordingFiles.storedName(id: id, displayName: displayName))
                if fileManager.fileExists(atPath: target.path) {
                    // Copied by an earlier attempt: taken in as it is.
                    if try RecordingFiles.sha256(of: target) == digest { copies.append((target, id, displayName, digest)) }
                    continue
                }
                // Refuses an existing destination, so a file that appeared meanwhile is kept.
                try fileManager.copyItem(at: source, to: target)
                created.append((target, Self.identity(of: target)))
                copies.append((target, id, displayName, digest))
            }
        } catch {
            Self.remove(created, folder: createdFolder ? destination : nil)
            throw error
        }
        let earlier = createdCopies[projectId]
        createdCopies[projectId] = (earlier?.folder ?? (createdFolder ? destination : nil), (earlier?.files ?? []) + created)
        return copies
    }

    /// Undoes this snapshot's copies for a song whose save failed.
    func removeCopy(for projectId: String) {
        guard let copies = createdCopies.removeValue(forKey: projectId) else { return }
        Self.remove(copies.files, folder: copies.folder)
    }

    /// File identity plus creation and change times, so a file put in its place
    /// (even reusing the inode) does not match.
    nonisolated private static func identity(of url: URL) -> [AnyHashable]? {
        var url = url
        url.removeAllCachedResourceValues()
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey, .creationDateKey, .contentModificationDateKey]),
              let identifier = values.fileResourceIdentifier as? AnyHashable else { return nil }
        return [identifier, values.creationDate, values.contentModificationDate]
    }

    nonisolated private static func remove(_ files: [(url: URL, identity: [AnyHashable]?)], folder: URL?) {
        for file in files {
            // Only the file this copy created: one put there since is left alone.
            guard let identity = file.identity, identity == Self.identity(of: file.url) else { continue }
            try? FileManager.default.removeItem(at: file.url)
        }
        // A folder this copy created goes too, but only once nothing else is in it.
        if let folder, (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: snapshotFolder)
    }
}

/// The open draft as last typed while a backup or restore held the library.
/// Kept in a file outside the SwiftData store so the text survives the app
/// being killed before the operation reconciles it.
nonisolated private struct DraftRecoveryRecord: Codable, Sendable {
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
    /// Folder under `recording-recovery` holding the open song's recordings as
    /// they were when the operation began, if it had any.
    var recordingSnapshotFolder: String?
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
    /// Editor line the cursor is on, so on-device trimming keeps the stanza being written.
    var cursorLineIndex: Int? = nil
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
            guard theme != oldValue else { return }
            // The theme field stays editable while a request runs, so a theme edit
            // drops in-flight AI work and its results, as Android onThemeChanged does.
            cancelEditorAIWork()
            suggestions = []
            errorMessage = nil
            triggerAutoSave()
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
    /// The request whose stream ended on its own with its lines still listed.
    /// Cleared when a request starts and on every cancel, so Stop, Settings
    /// changes, navigation, errors and lines used before the end never leave it set.
    @Published private(set) var completedSuggestionsRequestID: UUID?

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
    // survive app restarts. Keys use an "editor." prefix to namespace them away
    // from provider/model keys. Whole Song Context defaults on (Android parity).
    @Published var useWholeSongContext: Bool = true
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
    @Published private(set) var cloudBackupConnected: Bool = false
    @Published private(set) var cloudBackupIsWorking: Bool = false
    @Published private(set) var backupStatus: BackupStatus = .notConnected
    /// An older passphrase-encrypted backup is on Drive and waits for its passphrase.
    @Published private(set) var legacyBackupNeedsPassphrase: Bool = false
    @Published var firstRunRestoreOffer: FirstRunRestoreOffer?
    /// Recordings over 16 MiB that stay on this device (not in iCloud or Drive).
    @Published private(set) var oversizedRecordingCount = 0
    /// Files the recordings check left alone because another file holds their place
    /// (both are kept); shown in Settings with a way to keep each separately.
    @Published private(set) var recordingsNeedingAttention: [URL] = []
    /// The last check left recordings it could not read in; reported, not re-run.
    @Published private(set) var recordingAdoptionStalled = false
    /// True while the recordings could not be checked: recording lists show
    /// nothing and nothing plays until a check succeeds (A33).
    @Published private(set) var recordingListsSuspended = false
    /// The launch check of the recordings, awaited by tests.
    private(set) var recordingsLaunchTask: Task<Void, Never>?
    private let recordingLibrary: RecordingLibrary?
    private var automaticBackupTask: Task<Void, Never>?
    private var automaticBackupFailures = 0
    private var automaticBackupRerunRequested = false
    private var firstRunCheckedThisLaunch = false
    /// Quiet period after the last saved change before an automatic backup.
    var automaticBackupDebounce: TimeInterval = BackupSchedule.debounce
    /// Waits out a debounce or backoff delay; tests substitute a clock they advance.
    var automaticBackupSleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    private var activeCloudEditorOperation: CloudEditorOperation?
    private var pendingRecordingRecovery: OpenRecordingSnapshot?
    /// Why the last `beginCloudEditorOperation` refused, when it has a reason
    /// more specific than the caller's default message.
    private var cloudOperationRefusalReason: String?
    private let draftRecoveryURL: URL?
    private let libraryIsCloudBacked: (ModelContainer) -> Bool
    private var didAttemptDraftRecovery = false
    private var recordingSnapshotSweepTask: Task<Void, Never>?
    /// True once this session may write and remove its own recovery file: the
    /// library is on disk and any file left by an earlier session was set aside.
    private var draftRecoveryUsable = false
    /// The outcome of the last backup action, shown under the status line; empty when there is nothing to say.
    @Published private(set) var cloudBackupStatusText: String = ""
    @Published private(set) var cloudBackupLastResultIsError: Bool = false

    // MARK: - Internal

    // ModelContext does not keep its ModelContainer alive, and SwiftData traps when a
    // context is used after its container is gone. A pending autosave can outlive the
    // caller that owned the container, so hold it for as long as the context is set.
    private var modelContainer: ModelContainer?

    var modelContext: ModelContext? {
        didSet {
            modelContainer = modelContext?.container
            // Recordings are recovered and adopted first; deletions and expiry wait
            // for that to succeed, so none of them meets a recording without its row.
            if recordingLibrary == nil || modelContext == nil {
                applyPersistedDeletions()
                purgeExpiredTrashedProjects()
            } else {
                // The recordings are checked off the main actor first; deletions and
                // expiry wait for that to succeed (A33).
                recordingsLaunchTask = Task { [weak self] in
                    guard let self, await self.reconcileRecordings() else { return }
                    self.applyPersistedDeletions()
                    self.purgeExpiredTrashedProjects()
                    await self.voiceMemoService.retryPendingTakes()
                }
            }
            recoverInterruptedDraftIfNeeded()
            seedTrashProjectForUITestsIfNeeded()
            refreshCloudBackupState()
            Task { await checkFirstRunRestoreOffer(afterConnecting: false) }
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
        cloudBackupConfigured && cloudBackupConnected && !cloudBackupIsWorking && modelContext != nil
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

    private let persistModelContext: (ModelContext) throws -> Void

    /// Every library save goes through here, so a saved change starts the backup countdown.
    private func saveModelContext(_ context: ModelContext) throws {
        let changed = context.hasChanges
        try persistModelContext(context)
        if changed { scheduleAutomaticBackup() }
    }

    init(aiService: AIService = AIService(), keychainStore: KeychainStore? = nil, backupService: CloudBackupServicing? = nil, recordingLibrary: RecordingLibrary? = nil, companionStore: WritingCompanionStore? = nil, synonymService: (any SynonymProviding)? = nil, defaults: UserDefaults = .standard, draftRecoveryURL: URL? = nil, libraryIsCloudBacked: ((ModelContainer) -> Bool)? = nil, saveModelContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.aiService = aiService
        self.synonymService = synonymService ?? aiService
        self.defaults = defaults
        self.persistModelContext = saveModelContext
        let runningUITestInMemory = UITestFlags.isEnabled(UITestFlags.inMemoryStore)
        let resolvedStore: KeychainStore = keychainStore
            ?? (runningUITestInMemory ? InMemoryKeychainStore() : SystemKeychainStore())
        self.companionStore = companionStore ?? WritingCompanionStore(inMemory: runningUITestInMemory || keychainStore != nil)
        self.keychainStore = resolvedStore
        self.backupService = backupService
        self.recordingLibrary = recordingLibrary
        self.libraryIsCloudBacked = libraryIsCloudBacked ?? { container in
            container.configurations.contains { $0.cloudKitContainerIdentifier != nil }
        }
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
        if UITestFlags.scriptedSuggestionsEnabled() {
            // The scripted stream stands in for the on-device provider, which
            // asks for no sharing consent, so a request runs straight through.
            // Not persisted: the choice lasts only for this launch.
            selectedProvider = .local
        }
        let modelRaw = defaults.string(forKey: "selectedModel") ?? AIModel.default.rawValue
        if let savedModel = AIModel(rawValue: modelRaw), savedModel.provider == selectedProvider {
            selectedModel = savedModel
        } else {
            selectedModel = AIModel.models(for: selectedProvider).first ?? .default
        }

        // Restore editor toggle states. Booleans default false when the key is absent,
        // which matches the desired default for all except useWholeSongContext,
        // isHighlightEnabled and isSyllableColoringEnabled — those default true, so
        // we treat a missing key as "never set" and leave the in-memory default in
        // place rather than reading the UserDefaults zero-value. An explicitly saved
        // false is still respected.
        if defaults.object(forKey: "editor.useWholeSongContext") != nil {
            useWholeSongContext = defaults.bool(forKey: "editor.useWholeSongContext")
        }
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
        voiceMemoService.onFilesChanged = { [weak self] in
            Task { [weak self] in await self?.reconcileRecordings() }
            self?.scheduleAutomaticBackup()
        }
        voiceMemoService.publisher = recordingLibrary
        if let recordingLibrary { voiceMemoService.trashRoot = recordingLibrary.trashRoot }
        voiceMemoService.playbackAllowed = { [weak self] url in self?.isPlayableRecording(url) ?? true }
        voiceMemoService.playbackIdentity = { [weak self] url in self?.recordingIdentity(url) }
        recordingLibrary?.willMove = { [weak self] files in self?.voiceMemoService.stopPlayback(ifPlayingAnyOf: files) }
        refreshCloudBackupState()
    }

    deinit {
        trashSchedulerTask?.cancel()
        autoSaveTask?.cancel()
        automaticBackupTask?.cancel()
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
        // The context describes the line a suggestion will be inserted as, not the cursor's line.
        let placement = NextLinePlacement(lyrics: lyrics, cursorCharacterOffset: pos)
        let rawLines = placement.lines
        let sectionMap = SectionMap(lyrics: lyrics)

        let sectionContext = Self.sectionContext(
            forLineIndex: placement.cursorLineIndex,
            sectionMap: sectionMap,
            rawLines: rawLines
        )
        let schemeLetters = Array(activeRhymeScheme)

        return RhymeContext(
            targetLine: placement.anchorLine(scheme: schemeLetters),
            currentLetter: placement.letter(scheme: schemeLetters).map { String($0) } ?? "A",
            stanzaLines: placement.stanzaRows,
            currentLineIndex: placement.rowIndex,
            currentSection: sectionContext.currentSection,
            sectionOrdinal: sectionContext.sectionOrdinal,
            firstChorusLines: sectionContext.firstChorusLines
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
        completedSuggestionsRequestID = nil

        // Debug UI tests and simulator QA can answer from a scripted stream
        // (`--ui-test-scripted-suggestions`); everything below is unchanged.
        let stream = scriptedSuggestionStreamForUITests() ?? aiService.streamSuggestions(
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
            useWholeSongContext: input.useWholeSongContext,
            cursorLineIndex: input.cursorLineIndex
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
                if !Task.isCancelled, self.suggestionsRequestID == requestID {
                    if !emittedSuggestion {
                        self.errorMessage = "AI did not return suggestions. Try again."
                    } else if !self.suggestions.isEmpty {
                        // Lines can be used or cleared while the stream finishes
                        // (an inserted line clears the list); only results still
                        // on screen count as a completion.
                        self.completedSuggestionsRequestID = requestID
                    }
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
            stanzaLines: context.existingStanzaLines,
            targetRhymeLine: context.targetLine,
            rhymeType: rhymeType,
            rhymeScheme: activeRhymeScheme,
            currentLetter: context.currentLetter,
            currentSection: context.currentSection,
            sectionOrdinal: context.sectionOrdinal,
            firstChorusLines: context.firstChorusLines,
            complexity: rhymeComplexity,
            useWholeSongContext: useWholeSongContext,
            cursorLineIndex: NextLinePlacement(
                lyrics: lyrics,
                cursorCharacterOffset: Self.characterOffset(forUTF16Offset: cursorPosition, in: lyrics)
            ).cursorLineIndex
        )
    }

    func suggestionInputForTest() -> AISuggestionInput {
        makeSuggestionInput()
    }

    func suggestionsRequestIDForTest() -> UUID? {
        suggestionsRequestID
    }

    /// Debug builds only: the deterministic stream UI tests and simulator QA
    /// use in place of a provider, so the Assistant's real loading, arrival
    /// and cancellation states can be held and replayed.
    private func scriptedSuggestionStreamForUITests() -> AsyncThrowingStream<String, Error>? {
        #if DEBUG
        guard UITestFlags.scriptedSuggestionsEnabled() else { return nil }
        return UITestFlags.scriptedSuggestionStream()
        #else
        return nil
        #endif
    }

    func cancelSuggestions() {
        suggestionsTask?.cancel()
        suggestionsTask = nil
        suggestionsRequestID = nil
        completedSuggestionsRequestID = nil
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
                self.inspectorSynonymsError = SynonymResultPresentation.message(for: error)
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
        // Same placement the rhyme context was computed for: a blank cursor line is
        // filled, otherwise the suggestion becomes a new line after the cursor's line.
        let pos = Self.characterOffset(forUTF16Offset: cursorPosition, in: lyrics)
        let insertion = NextLinePlacement(lyrics: lyrics, cursorCharacterOffset: pos).inserting(suggestion)

        // cursorPosition is a UTF-16 offset (UITextView units).
        applyAtomicLyricsEdit(text: insertion.text, cursorPosition: insertion.cursor)
        insertedLineRange = insertion.insertedRange
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
                    projectId: project.id, recordingsRoot: root, displayNames: recordingDisplayNames(project.id)
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

    /// Why the last `moveProjectToTrash` was refused, for the song lists. Kept
    /// out of `errorMessage`, which the assistant panel treats as an AI failure,
    /// and cleared when the backup or restore that caused it ends.
    @Published private(set) var projectDeletionNotice: String?

    @discardableResult
    func moveProjectToTrash(_ project: SongProject) -> Bool {
        if activeCloudEditorOperation != nil {
            projectDeletionNotice = "This song can be moved to Trash once the backup or restore finishes."
            return false
        }
        if projectDeletionNotice != nil { projectDeletionNotice = nil }
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
        // Its recordings must have been recovered and adopted, so each one gets its tombstone.
        guard recordingsChecked() else { return false }
        let projectId = trashedProject.id
        do {
            // Every file of the song is one the check verified, before anything changes.
            try recordingLibrary?.checkSongDeletable(projectId, in: context)
            let deletedAt = Date()
            try upsertPermanentDeletion(projectId: projectId, deletedAt: deletedAt, in: context)
            // Each recording gets its own tombstone in the same save (A21).
            _ = try RecordingLibrary.tombstoneRecordings(ofProject: projectId, deletedAt: deletedAt.epochMilliseconds, in: context)
            context.delete(trashedProject)
            try saveModelContext(context)
        } catch {
            context.rollback()
            errorMessage = "Couldn't permanently delete this song. It remains in Trash."
            return false
        }
        // Remove the memo folder so orphaned audio doesn't accumulate on disk.
        stopPlaybackOfSong(projectId)
        if !RecordingFiles.deleteMemosFolder(for: projectId) {
            errorMessage = "This song was permanently deleted, but its local recordings could not be removed. Writers Block will retry cleanup."
        }
        do { try companionStore.remove(projectId) } catch { companionError = "Could not remove this song’s local notebook." }
        scheduleTrashPurge()
        return true
    }

    func purgeExpiredTrashedProjects() {
        guard let context = modelContext else { return }
        // Expiry deletes recordings: only once they are recovered and adopted.
        guard recordingsChecked() else { return }
        let now = Date()
        let expiredMemos = trashedRecordings().filter { $0.deleteAfter <= now }
        let descriptor = FetchDescriptor<TrashedSongProject>(
            predicate: #Predicate<TrashedSongProject> { $0.deleteAfter <= now }
        )
        // Chosen on the normalized deadline: a row without a deletion time is never
        // expired, and a repaired row's deadline is its repaired time plus retention (A37).
        let dueProjects = ((try? context.fetch(descriptor)) ?? []).filter {
            $0.deletedAt.epochMilliseconds > 0 && (!$0.trashedAtRepaired || $0.deletedAt.addingTimeInterval(trashRetentionInterval) <= now)
        }
        // A song whose folders hold a file the check has not verified (for example a
        // recording waiting for its place) is kept for a later attempt; the others go.
        let expiredProjects = dueProjects.filter { project in
            guard let recordingLibrary else { return true }
            return (try? recordingLibrary.checkSongDeletable(project.id, in: context)) != nil
        }
        if expiredProjects.count < dueProjects.count {
            let kept = dueProjects.count - expiredProjects.count
            errorMessage = "\(kept) expired \(kept == 1 ? "song was" : "songs were") kept in Trash because \(kept == 1 ? "its" : "their") recordings are not all checked yet."
        }
        guard !expiredProjects.isEmpty || !expiredMemos.isEmpty else {
            scheduleTrashPurge()
            return
        }
        let projectIDs = expiredProjects.map(\.id)
        do {
            for projectId in projectIDs {
                try upsertPermanentDeletion(projectId: projectId, deletedAt: now, in: context)
                _ = try RecordingLibrary.tombstoneRecordings(ofProject: projectId, deletedAt: now.epochMilliseconds, in: context)
            }
            for memo in expiredMemos {
                try tombstoneTrashedMemo(memo, deletedAt: now, in: context)
            }
            expiredProjects.forEach(context.delete)
            try saveModelContext(context)
            projectIDs.forEach(stopPlaybackOfSong)
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
        guard let context = modelContext, recordingsChecked() else { return false }
        do {
            try tombstoneTrashedMemo(trashed, deletedAt: Date(), in: context)
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
            // A32: songs without a time get the time first seen here, saved on the rows
            // before any tombstone is compared, whether or not there are tombstones.
            var repaired = false
            // A37: each repair is marked, and the Trash deadline follows a repaired deletion time.
            for project in try context.fetch(FetchDescriptor<SongProject>()) where project.updatedAt.epochMilliseconds <= 0 {
                project.updatedAt = firstSeenTime("project:\(project.id)")
                project.precedenceRepaired = true
                repaired = true
            }
            for project in try context.fetch(FetchDescriptor<TrashedSongProject>()) {
                if project.updatedAt.epochMilliseconds <= 0 {
                    project.updatedAt = firstSeenTime("project:\(project.id)")
                    project.precedenceRepaired = true
                    repaired = true
                }
                if project.deletedAt.epochMilliseconds <= 0 {
                    project.deletedAt = firstSeenTime("trashed:\(project.id)")
                    project.trashedAtRepaired = true
                    repaired = true
                }
                // A repaired deletion time always sets the deadline.
                let deadline = project.deletedAt.addingTimeInterval(trashRetentionInterval)
                if project.trashedAtRepaired, project.deleteAfter != deadline {
                    project.deleteAfter = deadline
                    repaired = true
                }
            }
            if repaired { try saveModelContext(context) }
            let deletions = try SyncMerger.mergeDeletions(DeletionStore.all(in: context))
            guard !deletions.isEmpty else { return }
            // A tombstone removes a song only when it is newer than the song's last change,
            // or that time is a repair (A38: a recorded time beats a repaired one).
            let tombstones = Dictionary(deletions.filter(\.isSongTombstone).map { ($0.projectId, $0.deletedAt) }) { max($0, $1) }
            var deletedProjects = Set(tombstones.keys)
            for project in try context.fetch(FetchDescriptor<SongProject>()) where tombstones[project.id] != nil {
                if project.precedenceRepaired || tombstones[project.id]! > project.updatedAt.epochMilliseconds {
                    context.delete(project)
                } else {
                    deletedProjects.remove(project.id)
                }
            }
            for project in try context.fetch(FetchDescriptor<TrashedSongProject>()) where tombstones[project.id] != nil {
                // A38: a tombstone against the Trash entry's deletion time only.
                if project.trashedAtRepaired || tombstones[project.id]! > project.deletedAt.epochMilliseconds {
                    context.delete(project)
                } else {
                    deletedProjects.remove(project.id)
                }
            }
            // The deleted songs' recordings (adopted by the library just before) get
            // their own tombstones in the same save; only their files go.
            var removedFiles: [(url: URL, sha256: String, recordingId: String)] = []
            for projectId in deletedProjects {
                for row in try RecordingLibrary.tombstoneRecordings(ofProject: projectId, deletedAt: tombstones[projectId] ?? 0, in: context) {
                    if let library = recordingLibrary, let file = row.fileURL(memosRoot: library.memosRoot, trashRoot: library.trashRoot) {
                        removedFiles.append((file, row.sha256, row.id))
                    }
                }
            }
            // Their audio leaves the memo folders and the Trash for quarantine (A28).
            if let library = recordingLibrary {
                try library.saveRecordingMoves(quarantine: removedFiles, in: context) { try saveModelContext(context) }
            } else {
                try saveModelContext(context)
            }
            for projectId in deletedProjects {
                do { try companionStore.remove(projectId) } catch { companionError = "Could not remove this song’s local notebook." }
            }
            // Individual recording tombstones are applied by the library from stored times.
            Task { [weak self] in await self?.reconcileRecordings() }
        } catch {
            context.rollback()
            errorMessage = "Couldn't finish applying permanent deletions. Writers Block will retry."
        }
    }

    private func upsertPermanentDeletion(
        projectId: String,
        recordingId: String? = nil,
        fileName: String? = nil,
        deletedAt: Date = Date(),
        in context: ModelContext
    ) throws {
        try RecordingLibrary.upsertTombstone(
            SyncDeletion(projectId: projectId, recordingId: recordingId, fileName: fileName, deletedAt: deletedAt.epochMilliseconds),
            in: context
        )
    }

    /// A trashed recording deleted for good: tombstoned by its id (by name if it
    /// never had a row) and its row removed, in the caller's save.
    private func tombstoneTrashedMemo(_ trashed: TrashedVoiceMemo, deletedAt: Date, in context: ModelContext) throws {
        if let recordingLibrary {
            // The complete check, and the id of the bytes there now (finding 1).
            let identity = try recordingLibrary.identityForDeletion(of: trashed, in: context)
            try upsertPermanentDeletion(projectId: trashed.projectId, recordingId: identity.id, fileName: trashed.originalName, deletedAt: deletedAt, in: context)
            if let row = identity.row { context.delete(row) }
            return
        }
        // Without the library (tests of the editor alone): the id derived from its bytes.
        let recordingId = try trashed.recordingId ?? RecordingBackupManifest.legacyRecordingId(
            projectId: trashed.projectId, fileName: trashed.originalName, sha256: RecordingFiles.sha256(of: trashed.url)
        )
        try upsertPermanentDeletion(projectId: trashed.projectId, recordingId: recordingId, fileName: trashed.originalName, deletedAt: deletedAt, in: context)
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
        let nextMemoExpiry = trashedRecordings().map(\.deleteAfter).min().flatMap { $0 > now ? $0 : nil }
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
        // End of the first lyric line: the next line is then the second "A" of AABB,
        // so the Target Line card shows "yellow music".
        if let range = lyrics.range(of: "yellow music") {
            cursorPosition = lyrics.utf16.distance(from: lyrics.utf16.startIndex, to: range.upperBound)
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
        project.precedenceRepaired = false  // an edit beats a repair (A37)
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
            // The library is held by the backup or restore, so this edit cannot be
            // saved yet. Write it to the recovery file now: a kill before the
            // operation reconciles must not lose it. If that write fails the edit
            // has no protection, so show the retry control instead of the spinner;
            // retrying comes back here.
            saveStatus = updateDraftRecoveryCopy() ? .saving : .failed
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
                    project.precedenceRepaired = false
        project.precedenceRepaired = false  // an edit beats a repair (A37)
                }
            } else {
                let project = makeUntitledSongProject()
                try copyRecordings(of: pendingRecordingRecovery, to: project.id)
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

    // MARK: - Recordings library

    /// A song's recordings' names by file name, for a draft snapshot (A36).
    private func recordingDisplayNames(_ projectId: String) -> [String: String] {
        guard let recordingLibrary, let modelContext else { return [:] }
        return (try? recordingLibrary.displayNames(projectId: projectId, in: modelContext)) ?? [:]
    }

    /// Copies a draft snapshot's recordings to a song as new recordings, recorded
    /// for the library to take in with their names.
    private func copyRecordings(of snapshot: OpenRecordingSnapshot?, to projectId: String) throws {
        guard let copies = try snapshot?.copy(to: projectId) else { return }
        try recordingLibrary?.expectCopies(copies)
    }

    /// What the song's recordings list shows (A36: names come from the rows).
    func recordingItems(projectId: String? = nil) -> [RecordingListItem] {
        guard !recordingListsSuspended else { return [] }
        guard let recordingLibrary, let modelContext else { return [] }
        return (try? recordingLibrary.liveRecordings(projectId: projectId, in: modelContext)) ?? []
    }

    /// What the recordings Trash shows.
    func trashedRecordings() -> [TrashedVoiceMemo] {
        guard !recordingListsSuspended else { return [] }
        guard let recordingLibrary, let modelContext else { return [] }
        return (try? recordingLibrary.trashedRecordings(in: modelContext)) ?? []
    }

    /// Retry for takes waiting to be saved: the library is brought up to date
    /// first, so a take published before an interruption counts as saved.
    func retryPendingRecordings() {
        Task { [weak self] in
            guard let self, await self.reconcileRecordings() else { return }
            await self.voiceMemoService.retryPendingTakes()
        }
    }

    /// The last check of the recordings succeeded and the tombstones read now:
    /// required before a deletion or expiry changes recordings (A33).
    func recordingsChecked() -> Bool {
        guard let recordingLibrary, let modelContext else { return true }
        // The complete check: last run, tombstones and move record (A33).
        guard (try? recordingLibrary.requireChecked(modelContext)) != nil else {
            errorMessage = "Your recordings are being checked, so nothing was deleted. Try again in a moment."
            return false
        }
        return true
    }

    private static let firstSeenKey = "editor-first-seen-times"

    /// A32: the time something without a time was first seen here, kept and never changed.
    private func firstSeenTime(_ key: String) -> Date {
        var seen = (defaults.dictionary(forKey: Self.firstSeenKey) as? [String: NSNumber])?.mapValues(\.int64Value) ?? [:]
        if let known = seen[key] { return Date(millisecondsSince1970: known) }
        let now = Date().epochMilliseconds
        seen[key] = now
        defaults.set(seen.mapValues { NSNumber(value: $0) }, forKey: Self.firstSeenKey)
        return Date(millisecondsSince1970: now)
    }

    /// Stops playback of anything in a song's memo or Trash folder before they go.
    private func stopPlaybackOfSong(_ projectId: String) {
        let roots = recordingLibrary.map { [$0.memosRoot, $0.trashRoot] } ?? [RecordingFiles.memosRoot(), RecordingFiles.memosTrashRoot()]
        let folders = roots.map { RecordingFiles.canonicalPath($0.appendingPathComponent(projectId, isDirectory: true)) + "/" }
        voiceMemoService.stopPlayback(ifPlayingWithin: folders)
    }

    /// A verified identity for what plays: the id of the row whose bytes the file
    /// holds, else the file itself (its path and inode). Nil when the file cannot
    /// be read; such a file does not play.
    func recordingIdentity(_ url: URL) -> String? {
        guard let recordingLibrary, let modelContext,
              let rows = try? modelContext.fetch(FetchDescriptor<Recording>()),
              let facts = try? RecordingFiles.facts(url) else { return nil }
        let path = RecordingFiles.canonicalPath(url)
        if let row = rows.first(where: { $0.fileURL(memosRoot: recordingLibrary.memosRoot, trashRoot: recordingLibrary.trashRoot).map(RecordingFiles.canonicalPath) == path }),
           (try? RecordingFiles.sha256(of: url)) == row.sha256 {
            return row.id
        }
        return "file:\(path)@\(facts.inode)"
    }

    /// A recording a winning deletion covers is not played (A28): nothing plays
    /// while the recordings cannot be checked, nor a file that is gone or waiting
    /// for quarantine, nor one whose row a stored deletion covers by time.
    func isPlayableRecording(_ url: URL) -> Bool {
        guard let recordingLibrary, let modelContext else { return true }
        guard !recordingListsSuspended else { return false }
        let path = RecordingFiles.canonicalPath(url)
        guard let hidden = RecordingFiles.pendingQuarantine(for: recordingLibrary.memosRoot), !hidden.contains(path),
              (try? RecordingFiles.exists(url)) == true else { return false }
        guard let rows = try? modelContext.fetch(FetchDescriptor<Recording>()),
              let deletions = try? DeletionStore.all(in: modelContext) else { return false }
        guard let row = rows.first(where: { $0.fileURL(memosRoot: recordingLibrary.memosRoot, trashRoot: recordingLibrary.trashRoot).map(RecordingFiles.canonicalPath) == path }) else { return true }
        return !deletions.contains { $0.covers(projectId: row.projectId, recordingId: row.id, sha256: row.sha256, at: row.precedenceTime, repaired: row.precedenceRepaired) }
    }

    /// Brings `Recording` rows (iCloud) and memo files in step. Runs at launch, when
    /// iCloud delivers changes, and after any memo change; independent of Drive.
    /// A failed scan changes nothing and is retried on the next trigger.
    /// False when the recordings could not be brought in step; the reason is shown.
    @discardableResult
    func reconcileRecordings() async -> Bool {
        guard let recordingLibrary, let modelContext else { return true }
        recordingLibrary.context = modelContext
        do {
            try await recordingLibrary.reconcile(context: modelContext)
            oversizedRecordingCount = recordingLibrary.oversizedCount
            recordingsNeedingAttention = recordingLibrary.needsAttention
            recordingAdoptionStalled = recordingLibrary.adoptionStalled
            recordingListsSuspended = false
            voiceMemoService.recordingsChanged()
            // Files left for a later run (finding 10) are taken by another run, but
            // only while runs make progress; a stalled run is reported instead.
            if recordingLibrary.pendingAdoption > 0, !recordingLibrary.adoptionStalled {
                Task { [weak self] in await self?.reconcileRecordings() }
            }
            return true
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = "Couldn't bring your recordings up to date: \(reason)"
            // Lists and playback follow the failure too (A33).
            recordingListsSuspended = true
            voiceMemoService.recordingsChanged()
            return false
        }
    }

    /// Keeps a reported file as a recording of its own under a new id; the other
    /// file then takes its place on the next check. Nothing is replaced or deleted.
    func keepRecordingSeparately(_ url: URL) async {
        guard let recordingLibrary, let modelContext else { return }
        recordingLibrary.context = modelContext
        do {
            try recordingLibrary.keepSeparately(url)
        } catch {
            errorMessage = "Couldn't keep that recording separately. Both files are still on this device."
        }
        _ = await reconcileRecordings()
    }

    /// "Song title · file name" for a reported file.
    func attentionLabel(for url: URL) -> String {
        let projectId = url.deletingLastPathComponent().lastPathComponent
        let title = (try? modelContext?.fetch(FetchDescriptor<SongProject>(predicate: #Predicate { $0.id == projectId })).first?.title) ?? nil
        return "\(title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled song") · \(url.lastPathComponent)"
    }

    // MARK: - Cloud Backup

    func refreshCloudBackupState() {
        cloudBackupConfigured = backupService?.isConfigured ?? false
        cloudBackupConnected = backupService?.isConnected ?? false
        legacyBackupNeedsPassphrase = backupService?.hasLegacyBackupToMigrate ?? false
        guard let backupService, cloudBackupConnected else {
            backupStatus = .notConnected
            return
        }
        if cloudBackupIsWorking {
            backupStatus = .backingUp
        } else if let failure = backupService.backgroundBackupFailureDescription {
            backupStatus = .failed(reason: failure, lastBackupAt: backupService.lastBackupAt)
        } else if automaticBackupTask != nil {
            backupStatus = .pending
        } else {
            backupStatus = .connected(lastBackupAt: backupService.lastBackupAt)
        }
    }

    func connectGoogleDrive() async {
        guard let backupService, cloudBackupConfigured, !cloudBackupConnected else { return }
        do {
            try await backupService.connect()
        } catch {
            refreshCloudBackupState()
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Could not connect Google Drive: \(cloudBackupErrorDescription(error))"
            return
        }
        cloudBackupStatusText = ""
        cloudBackupLastResultIsError = false
        refreshCloudBackupState()
        await checkFirstRunRestoreOffer(afterConnecting: true)
        scheduleAutomaticBackup()
    }

    /// Revokes the Google grant and clears this device's backup state. Backups stop.
    func disconnectGoogleDrive() async {
        guard let backupService, !cloudBackupIsWorking else { return }
        automaticBackupTask?.cancel()
        automaticBackupTask = nil
        automaticBackupFailures = 0
        automaticBackupRerunRequested = false
        firstRunRestoreOffer = nil
        let revoked = await backupService.disconnect()
        refreshCloudBackupState()
        cloudBackupLastResultIsError = !revoked
        cloudBackupStatusText = revoked
            ? "Disconnected from Google Drive."
            : "Disconnected on this device, but Google still lists the app; remove it at myaccount.google.com/permissions"
    }

    /// Offers the Drive backup to a device that has none of it yet: after
    /// connecting, or at launch when connected with an empty library. Never restores by itself.
    func checkFirstRunRestoreOffer(afterConnecting: Bool) async {
        guard let backupService, backupService.isConnected, let context = modelContext,
              firstRunRestoreOffer == nil, afterConnecting || !firstRunCheckedThisLaunch else { return }
        firstRunCheckedThisLaunch = true
        if !afterConnecting {
            let songs = (try? context.fetchCount(FetchDescriptor<SongProject>())) ?? 0
            let trashed = (try? context.fetchCount(FetchDescriptor<TrashedSongProject>())) ?? 0
            guard songs + trashed == 0 else { return }
        }
        guard let summary = try? await backupService.remoteBackupSummary(), summary.songs > 0 else { return }
        automaticBackupTask?.cancel()
        automaticBackupTask = nil
        firstRunRestoreOffer = FirstRunRestoreOffer(songs: summary.songs, recordings: summary.recordings)
        refreshCloudBackupState()
    }

    func acceptFirstRunRestore() async {
        firstRunRestoreOffer = nil
        await restoreBackupNow()
    }

    func declineFirstRunRestore() {
        firstRunRestoreOffer = nil
        refreshCloudBackupState()
    }

    /// Starts the quiet-period countdown to an automatic backup. Runs coalesce:
    /// a change during a run asks for one more run after it.
    func scheduleAutomaticBackup() {
        guard let backupService, backupService.isConnected, modelContext != nil, firstRunRestoreOffer == nil else { return }
        if cloudBackupIsWorking {
            automaticBackupRerunRequested = true
            return
        }
        automaticBackupTask?.cancel()
        let delay = max(automaticBackupDebounce, BackupSchedule.retryDelay(afterFailures: automaticBackupFailures))
        let sleep = automaticBackupSleep
        automaticBackupTask = Task { @MainActor [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            automaticBackupTask = nil
            await runCloudBackupOnBackgroundIfPossible()
        }
        refreshCloudBackupState()
    }

    func backUpNow() async {
        await runCloudEditorOperation(
            noun: "Backup",
            changesLibrary: false,
            success: "Backup complete.",
            separateDraft: "Backup complete. Your edits were saved as a separate local draft; back up again to include them."
        ) { service, context in
            try await service.backupNow(modelContext: context)
        }
    }

    func restoreBackupNow() async {
        await runCloudEditorOperation(
            noun: "Restore",
            success: "Restore complete. Projects, trash, and missing recordings were restored.",
            separateDraft: "Restore complete. Your open edits were saved as a separate local draft."
        ) { service, context in
            try await service.restoreNow(modelContext: context)
        }
        voiceMemoService.recordingsChanged()
    }

    /// Opens the older encrypted backup with a passphrase typed once; it is not kept.
    func migrateLegacyBackup(passphrase: String) async {
        await runCloudEditorOperation(
            noun: "Migration",
            changesLibrary: false,
            success: "",
            separateDraft: "Your open edits were saved as a separate local draft."
        ) { service, context in
            try await service.migrateLegacyBackup(passphrase: passphrase, modelContext: context)
        }
    }

    /// Merges an exported zip or a v4 `manifest.json` into the library.
    func importBackupFile(_ data: Data) async {
        await runCloudEditorOperation(
            noun: "Import",
            requiresDrive: false,
            success: "Import complete. Songs from the file were merged into your library.",
            separateDraft: "Import complete. Your open edits were saved as a separate local draft."
        ) { service, context in
            try await service.importArchive(data, modelContext: context)
        }
        // Imported recordings are files, which no library save announces.
        voiceMemoService.recordingsChanged()
        scheduleAutomaticBackup()
    }

    /// The "Export all songs" zip, after saving the open song.
    func exportAllSongs() -> (fileName: String, data: Data)? {
        guard let backupService, let context = modelContext, !cloudBackupIsWorking, flushCurrentDraft() else {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Export failed: save the open song and try again."
            return nil
        }
        do {
            let archive = try backupService.exportArchive(modelContext: context, now: Date())
            cloudBackupLastResultIsError = false
            cloudBackupStatusText = reportNote(backupService.lastReport) ?? ""
            return archive
        } catch {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Export failed: \(cloudBackupErrorDescription(error))"
            return nil
        }
    }

    /// Runs a backup-family action while the library is held, then reconciles the open draft.
    /// `changesLibrary` is false for backups: they only read the library, so the
    /// open song is saved first and the editor stays free while they run.
    private func runCloudEditorOperation(
        noun: String,
        requiresDrive: Bool = true,
        changesLibrary: Bool = true,
        success: String,
        separateDraft: String,
        action: (CloudBackupServicing, ModelContext) async throws -> Void
    ) async {
        guard let backupService, let context = modelContext,
              requiresDrive ? canRunCloudBackup : !cloudBackupIsWorking else {
            refreshCloudBackupState()
            return
        }
        guard changesLibrary ? beginCloudEditorOperation(in: context) : flushCurrentDraft() else {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "\(noun) canceled. "
                + (cloudOperationRefusalReason ?? "Save the open song before retrying; your edits remain open.")
            return
        }
        automaticBackupTask?.cancel()
        automaticBackupTask = nil
        cloudBackupIsWorking = true
        cloudBackupLastResultIsError = false
        cloudBackupStatusText = ""
        refreshCloudBackupState()
        defer {
            finishCloudEditorOperation()
            cloudBackupIsWorking = false
            refreshCloudBackupState()
            finishAutomaticBackupRun()
        }

        var failure: Error?
        do {
            try await action(backupService, context)
        } catch {
            failure = error
        }
        guard let recovered = changesLibrary ? reconcileOpenDraftAfterCloudOperation(in: context) : false else {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "\(noun) finished, but the open draft could not be saved. Keep this editor open and retry saving."
            return
        }
        if let failure {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "\(noun) failed: \(cloudBackupErrorDescription(failure)). Your open edits remain in the local library."
            return
        }
        automaticBackupFailures = 0
        let report = backupService.lastReport
        cloudBackupLastResultIsError = !(report?.damagedRecordings.isEmpty ?? true)
        cloudBackupStatusText = [recovered ? separateDraft : success, reportNote(report)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func reportNote(_ report: BackupReport?) -> String? {
        guard let report else { return nil }
        var notes: [String] = []
        if report.migratedLegacyBackup {
            notes.append("Your older encrypted backup was moved to the new format.")
        }
        if !report.damagedRecordings.isEmpty {
            let count = report.damagedRecordings.count
            notes.append("\(count) \(count == 1 ? "recording" : "recordings") did not match the backup and \(count == 1 ? "was" : "were") not restored: \(report.damagedRecordings.joined(separator: ", ")).")
        }
        if report.unmovedLegacyRecordings > 0 {
            let count = report.unmovedLegacyRecordings
            notes.append("\(count) older \(count == 1 ? "recording" : "recordings") could not be moved; the older backup is kept.")
        }
        if !report.localDigestConflicts.isEmpty {
            let count = report.localDigestConflicts.count
            notes.append("\(count) \(count == 1 ? "recording here holds" : "recordings here hold") different audio than the backup lists for \(count == 1 ? "it" : "them"); both are kept: \(report.localDigestConflicts.joined(separator: ", ")).")
        }
        if !report.notUploadedConflicts.isEmpty {
            let count = report.notUploadedConflicts.count
            notes.append("\(count) \(count == 1 ? "recording was" : "recordings were") not uploaded because Google Drive holds different audio for \(count == 1 ? "it" : "them").")
        }
        if !report.conflictingDriveObjects.isEmpty {
            let count = report.conflictingDriveObjects.count
            notes.append("\(count) Drive \(count == 1 ? "copy holds" : "copies hold") other audio under a recording's id and \(count == 1 ? "was" : "were") left in place.")
        }
        if !report.leftOutRecordings.isEmpty {
            let count = report.leftOutRecordings.count
            notes.append("\(count) \(count == 1 ? "recording was" : "recordings were") not included: \(report.leftOutRecordings.joined(separator: ", ")).")
        }
        if report.quarantinedNotExported > 0 || report.takesWaitingNotExported > 0 {
            notes.append("Quarantined audio (\(report.quarantinedNotExported)) and recordings waiting to be saved (\(report.takesWaitingNotExported)) are never exported.")
        }
        if report.oversizedRecordings > 0 {
            let count = report.oversizedRecordings
            notes.append("\(count) \(count == 1 ? "recording is" : "recordings are") over 16 MB and \(count == 1 ? "stays" : "stay") on this device only.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// After any run: back off after an automatic failure, or run again for changes saved meanwhile.
    private func finishAutomaticBackupRun() {
        guard backupService?.isConnected == true else { return }
        if backupService?.backgroundBackupFailureDescription != nil {
            automaticBackupFailures += 1
            automaticBackupRerunRequested = false
            scheduleAutomaticBackup()
        } else if automaticBackupRerunRequested {
            automaticBackupRerunRequested = false
            scheduleAutomaticBackup()
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
        cloudOperationRefusalReason = nil
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
                recordingSnapshot = try OpenRecordingSnapshot(projectId: id, recordingsRoot: root, displayNames: recordingDisplayNames(id))
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
        // An edit that was pending when the operation begins needs its recovery
        // copy from the start: the operation may replace the song, and nothing
        // rewrites the copy unless the user types again. Without it, do not
        // start. The edit is already saved in the library by the flush above.
        guard updateDraftRecoveryCopy() else {
            finishCloudEditorOperation()
            cloudOperationRefusalReason = "A safety copy of the open song could not be written. Free up storage and try again; your edits are saved."
            return false
        }
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
            try copyRecordings(of: operation.recordingSnapshot, to: recoveredID)
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
        if projectDeletionNotice != nil { projectDeletionNotice = nil }
    }

    private func reconcileOpenDraftAfterCloudOperation(in context: ModelContext) -> Bool? {
        let recovered = reconcileOpenDraft(in: context)
        // On failure the edits exist only in the open editor, so the recovery
        // file stays until a later save succeeds.
        if recovered != nil { removeDraftRecoveryCopy() }
        return recovered
    }

    // MARK: Draft recovery file

    /// False only when the copy was needed and could not be written.
    @discardableResult
    private func updateDraftRecoveryCopy() -> Bool {
        guard draftRecoveryUsable, let url = draftRecoveryURL,
              let operation = activeCloudEditorOperation else { return true }
        let draft = openDraft
        let baseline = operation.currentBaseline
        guard operation.currentHadPendingEdit || draft != baseline else {
            removeDraftRecoveryCopy()
            return true
        }
        let record = DraftRecoveryRecord(
            projectId: currentProjectId,
            title: draft.title, lyrics: draft.lyrics, theme: draft.theme,
            baselineTitle: baseline.title, baselineLyrics: baseline.lyrics, baselineTheme: baseline.theme,
            savedAt: Date(),
            separateCopyId: operation.separateDraftID,
            recordingSnapshotFolder: operation.recordingSnapshot?.folderName
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Readable while the device is locked: the background backup writes here.
            try JSONEncoder().encode(record).write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            // The edit is still in the open editor and is reconciled when the
            // operation ends; only the kill protection is missing for it. An
            // earlier copy may remain on disk: it holds older text of the same
            // draft, which launch recovery applies by the same rules.
            return false
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
        startRecordingSnapshotSweep(recoveryFolder: folder)
    }

    /// A session killed mid-operation leaves its recording snapshot behind. One
    /// that a recovery file still names is kept for that recovery. Any other is
    /// removed only when every file in it has a live recording with the same
    /// name and the same SHA-256, so the only copy of audio is never deleted;
    /// snapshots that fail that check, or cannot be hashed, are left in place.
    /// Such a snapshot does not say which song it came from, so a match in any
    /// song's recordings counts.
    ///
    /// Hashing audio can take long, so it runs off the main actor on file URLs
    /// only. It starts after launch recovery has used the snapshots it needs,
    /// and looks only at the folders present now: snapshots this session takes
    /// later belong to its own operations.
    private func startRecordingSnapshotSweep(recoveryFolder: URL) {
        guard let recordingsRoot = backupService?.recordingRecoveryRoot else { return }
        let stagingRoot = OpenRecordingSnapshot.stagingRoot(for: recordingsRoot)
        guard let snapshots = try? FileManager.default.contentsOfDirectory(
            at: stagingRoot, includingPropertiesForKeys: nil
        ), !snapshots.isEmpty else { return }
        recordingSnapshotSweepTask = Task.detached(priority: .utility) {
            EditorViewModel.removeRedundantRecordingSnapshots(
                snapshots, recordingsRoot: recordingsRoot, recoveryFolder: recoveryFolder
            )
        }
    }

    /// Written inside a snapshot that was hashed and found to hold audio with no
    /// live duplicate. It lists the snapshot's files and sizes; while they are
    /// unchanged the snapshot is kept without hashing it again on every launch.
    nonisolated static let recordingSnapshotCheckedMarkerName = ".checked-only-copy.json"

    /// Snapshot folder names that recovery files still need, or nil when a
    /// recovery file cannot be read and so may name any of them.
    nonisolated private static func snapshotNamesNeededByRecovery(in recoveryFolder: URL) -> Set<String>? {
        var names = Set<String>()
        let files = (try? FileManager.default.contentsOfDirectory(at: recoveryFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(DraftRecoveryRecord.self, from: data) else { return nil }
            if let name = record.recordingSnapshotFolder { names.insert(name) }
        }
        return names
    }

    nonisolated private static func removeRedundantRecordingSnapshots(
        _ snapshots: [URL], recordingsRoot: URL, recoveryFolder: URL
    ) {
        let fileManager = FileManager.default
        guard let needed = snapshotNamesNeededByRecovery(in: recoveryFolder) else { return }

        func size(_ url: URL) -> Int? {
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
        var liveByName: [String: [URL]] = [:]
        for projectFolder in (try? fileManager.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil)) ?? [] {
            for recording in (try? fileManager.contentsOfDirectory(at: projectFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                liveByName[recording.lastPathComponent, default: []].append(recording)
            }
        }

        for snapshot in snapshots where !needed.contains(snapshot.lastPathComponent) {
            // Only the audio counts (the names file beside it is metadata).
            guard let files = (try? fileManager.contentsOfDirectory(
                at: snapshot, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles
            ))?.filter({ RecordingFiles.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }) else { continue }
            var sizes: [String: Int] = [:]
            for file in files {
                guard let bytes = size(file) else { break }
                sizes[file.lastPathComponent] = bytes
            }
            guard sizes.count == files.count else { continue }

            let marker = snapshot.appendingPathComponent(recordingSnapshotCheckedMarkerName)
            if let data = try? Data(contentsOf: marker),
               let checked = try? JSONDecoder().decode([String: Int].self, from: data),
               checked == sizes {
                continue
            }

            var hashingFailed = false
            let redundant = files.allSatisfy { file in
                // Size only narrows the candidates; the hash decides.
                guard let digest = try? GGUFModelCatalog.fileSHA256(at: file) else {
                    hashingFailed = true
                    return false
                }
                return (liveByName[file.lastPathComponent] ?? []).contains { live in
                    size(live) == sizes[file.lastPathComponent]
                        && (try? GGUFModelCatalog.fileSHA256(at: live)) == digest
                }
            }
            if redundant {
                // A recovery file may have been written while this was hashing.
                guard let stillNeeded = snapshotNamesNeededByRecovery(in: recoveryFolder),
                      !stillNeeded.contains(snapshot.lastPathComponent) else { continue }
                try? fileManager.removeItem(at: snapshot)
            } else if !hashingFailed, let data = try? JSONEncoder().encode(sizes) {
                try? data.write(to: marker, options: .atomic)
            }
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
        var recoveredCopyID: String?
        var copiedSnapshot: OpenRecordingSnapshot?
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
            // The open song's recordings as they were when the operation began.
            let recordingSnapshot: OpenRecordingSnapshot? = {
                guard let name = record.recordingSnapshotFolder,
                      let root = backupService?.recordingRecoveryRoot else { return nil }
                return OpenRecordingSnapshot(existingFolderNamed: name, recordingsRoot: root)
            }()
            if savedInPlace || savedSeparately {
                // The song that owns the text was saved, with its recordings.
                try? fileManager.removeItem(at: file)
                recordingSnapshot?.discard()
                return
            }
            let recovered: SongProject
            // A CloudKit-backed library may not have downloaded another device's
            // newer version of this song yet, and that sync does not compare
            // `updatedAt`. Writing into the song now could replace those edits,
            // so only a local-only library is updated in place.
            if let stored, content(stored) == baseline, stored.updatedAt <= record.savedAt,
               !libraryIsCloudBacked(context.container) {
                stored.title = draft.title
                stored.lyrics = draft.lyrics
                stored.theme = draft.theme
                // The time the text was typed, so timestamp merges rank it as that edit.
                stored.updatedAt = record.savedAt
                stored.precedenceRepaired = false
                recovered = stored
            } else {
                // The song was replaced, deleted, or changed after this copy was
                // written, or may be about to be by sync. Keep both: never write
                // old text over a newer row.
                // No song owns this id (checked above). Recordings already under it
                // were left by an attempt killed before its save; they are kept and
                // only missing copies are added.
                copiedSnapshot = recordingSnapshot
                try copyRecordings(of: recordingSnapshot, to: separateID)
                recoveredCopyID = separateID
                recovered = SongProject(
                    id: separateID, title: draft.title, lyrics: draft.lyrics, theme: draft.theme,
                    updatedAt: record.savedAt
                )
                context.insert(recovered)
            }
            try saveModelContext(context)
            try? fileManager.removeItem(at: file)
            // Only after the song that owns the recordings is saved.
            recordingSnapshot?.discard()
            loadProject(recovered)
            saveStatus = .saved
        } catch {
            context.rollback()
            if let recoveredCopyID { copiedSnapshot?.removeCopy(for: recoveredCopyID) }
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
                    if saveStatus == .saving || saveStatus == .failed { saveStatus = .saved }
                    return operation.savedSeparateOutgoingDraft
                }
                if let stored, stored.1 == operation.currentBaseline {
                    stored.0.title = draft.title
                    stored.0.lyrics = draft.lyrics
                    stored.0.theme = draft.theme
                    stored.0.updatedAt = Date()
                    stored.0.precedenceRepaired = false
                    try saveModelContext(context)
                    saveStatus = .saved
                    return operation.savedSeparateOutgoingDraft
                }
                let recoveredID = operation.separateDraftID
                try copyRecordings(of: operation.recordingSnapshot, to: recoveredID)
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
            if saveStatus == .saving || saveStatus == .failed {
                saveStatus = currentProjectId == nil ? .idle : .saved
            }
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

    /// The automatic run: on the debounce after a save, on retry, and when the
    /// app moves to the background. Failures are recorded, not thrown.
    /// The automatic run: on the debounce after a change, on retry, and when the
    /// app moves to the background. A backup only reads the library, so the
    /// editor stays free. Failures are recorded, not thrown.
    func runCloudBackupOnBackgroundIfPossible() async {
        refreshCloudBackupState()
        guard let backupService,
              let context = modelContext,
              cloudBackupConfigured,
              cloudBackupConnected,
              firstRunRestoreOffer == nil,
              !cloudBackupIsWorking else {
            return
        }
        guard flushCurrentDraft() else {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Background backup canceled. Your open draft could not be saved."
            return
        }
        // After the flush, whose save would start another countdown: this run includes it.
        automaticBackupTask?.cancel()
        automaticBackupTask = nil
        cloudBackupIsWorking = true
        refreshCloudBackupState()
        await backupService.backupInBackgroundIfPossible(modelContext: context)
        cloudBackupIsWorking = false
        refreshCloudBackupState()
        if backupService.backgroundBackupFailureDescription == nil {
            automaticBackupFailures = 0
            cloudBackupLastResultIsError = !(backupService.lastReport?.damagedRecordings.isEmpty ?? true)
            cloudBackupStatusText = reportNote(backupService.lastReport) ?? ""
        }
        finishAutomaticBackupRun()
    }

    #if DEBUG
    func waitForPendingAutoSaveForTesting() async {
        await autoSaveTask?.value
    }

    func waitForRecordingSnapshotSweepForTesting() async {
        await recordingSnapshotSweepTask?.value
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
