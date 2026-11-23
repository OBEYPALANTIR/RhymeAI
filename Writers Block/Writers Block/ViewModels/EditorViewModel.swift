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
    func restoreNow(modelContext: ModelContext, draftHandoff: BackupDraftHandoff) async throws
    func backupInBackgroundIfPossible(modelContext: ModelContext) async
    func migrateLegacyBackup(passphrase: String, modelContext: ModelContext) async throws
    func remoteBackupSummary() async throws -> RemoteBackupSummary?
    func probeRevisions() async throws -> [BackupRevision]
    func recoverRevision(_ revision: BackupRevision, modelContext: ModelContext) async throws
    func exportArchive(modelContext: ModelContext, now: Date) throws -> (fileName: String, data: Data)
    func importArchive(_ data: Data, modelContext: ModelContext) async throws
    func importArchive(_ data: Data, modelContext: ModelContext, draftHandoff: BackupDraftHandoff) async throws
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
    func probeRevisions() async throws -> [BackupRevision] { [] }
    func recoverRevision(_ revision: BackupRevision, modelContext: ModelContext) async throws {}
    func exportArchive(modelContext: ModelContext, now: Date) throws -> (fileName: String, data: Data) {
        throw BackupError.notConfigured
    }
    func importArchive(_ data: Data, modelContext: ModelContext) async throws {}
    func restoreNow(modelContext: ModelContext, draftHandoff: BackupDraftHandoff) async throws {
        try await restoreNow(modelContext: modelContext)
    }
    func importArchive(_ data: Data, modelContext: ModelContext, draftHandoff: BackupDraftHandoff) async throws {
        try await importArchive(data, modelContext: modelContext)
    }
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
    nonisolated struct Take: Codable, Equatable, Sendable {
        let fileName: String
        let displayName: String
        let bytes: Int64
        let sha256: String
        var origin: SyncRecording? = nil

        func recordingID(for projectId: String) -> String {
            RecordingBackupManifest.legacyRecordingId(projectId: projectId, fileName: fileName, sha256: sha256)
        }

        func matches(_ url: URL) throws -> Bool {
            try RecordingFiles.facts(url).size == bytes && RecordingFiles.sha256(of: url) == sha256
        }
    }

    private let recordingsRoot: URL
    private let snapshotFolder: URL
    private var expectedTakes: [Take]?
    private(set) var recoveryRecordingIDs: [String: String] = [:]

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
    init?(existingFolderNamed folderName: String, recordingsRoot: URL, expectedTakes: [Take]? = nil,
          recoveryRecordingIDs: [String: String] = [:]) {
        guard UUID(uuidString: folderName) != nil else { return nil }
        let folder = Self.stagingRoot(for: recordingsRoot).appendingPathComponent(folderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        self.recordingsRoot = recordingsRoot
        snapshotFolder = folder
        self.expectedTakes = expectedTakes
        self.recoveryRecordingIDs = recoveryRecordingIDs
    }

    nonisolated static func stagingRoot(for recordingsRoot: URL) -> URL {
        recordingsRoot.deletingLastPathComponent()
            .appendingPathComponent("recording-recovery", isDirectory: true)
    }

    var folderName: String { snapshotFolder.lastPathComponent }

    /// Files `copy(to:)` created, by destination song, with each file's identity
    /// at creation. Rollback removes only those, and only if still the same file.
    private var createdCopies: [String: (folder: URL?, files: [(url: URL, identity: [AnyHashable]?, sha256: String)])] = [:]

    /// Copies the snapshot's recordings into the song's memo folder as new
    /// recordings: each copy is `<id>.<ext>` with an id derived from the song, the
    /// source and its bytes, so a repeated copy finds the earlier one. Returns the
    /// copies for the library to take in under those ids and names. A file already
    /// there is never replaced or removed.
    /// True when the snapshot's names record exists but could not be read (T3.49):
    /// the copies then carry their file names, and the damage is reported.
    private(set) var namesDamaged = false

    /// The display names kept beside the snapshot: absent (snapshots from before A36
    /// have none) is no names; present but unreadable is reported, not taken for absence.
    private func displayNames() -> [String: String] {
        let file = snapshotFolder.appendingPathComponent(Self.namesFile)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let data = try? Data(contentsOf: file), let names = try? JSONDecoder().decode([String: String].self, from: data) else {
            namesDamaged = true
            return [:]
        }
        return names
    }

    private func audioFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: snapshotFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { RecordingFiles.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readTakes() throws -> [Take] {
        let names = displayNames()
        return try audioFiles().map { file in
            let name = file.lastPathComponent
            return Take(fileName: name, displayName: names[name] ?? name,
                        bytes: try RecordingFiles.facts(file).size, sha256: try RecordingFiles.sha256(of: file))
        }
    }

    func takesForRecovery() throws -> [Take] {
        if let expectedTakes { return expectedTakes }
        let takes = try readTakes()
        guard !takes.isEmpty else { throw RecordingLibraryError.takeMissing }
        expectedTakes = takes
        return takes
    }

    @discardableResult
    func copy(to projectId: String, verifyDestination: Bool = false, alreadyVerified: Set<String> = [],
              persistRecordingIDs: (([String: String]) throws -> Void)? = nil,
              expecting expect: (([(url: URL, recordingId: String, displayName: String, sha256: String)]) throws -> Void)? = nil)
        throws -> [(url: URL, recordingId: String, displayName: String, sha256: String)] {
        let fileManager = FileManager.default
        let destination = try RecordingFiles.projectURL(projectId: projectId, memosRoot: recordingsRoot)
        let createdFolder = !fileManager.fileExists(atPath: destination.path)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var created: [(url: URL, identity: [AnyHashable]?, sha256: String)] = []
        var copies: [(url: URL, recordingId: String, displayName: String, sha256: String)] = []
        do {
            let observed = try readTakes()
            let takes: [Take]
            if verifyDestination {
                let expected = expectedTakes ?? observed
                takes = expected.filter { !alreadyVerified.contains($0.recordingID(for: projectId)) }
                guard !expected.isEmpty, takes.allSatisfy(observed.contains) else {
                    throw RecordingLibraryError.notVerified
                }
            } else {
                takes = observed
            }
            // Each copy's identity is chosen, and handed to the library as an intent,
            // before any byte is copied (T1.29). A destination holding other bytes is
            // never skipped: the copy takes a fresh id instead, so every recording in
            // the snapshot reaches the song (BLOCKER 1).
            var planned: [(take: Take, target: URL, recordingId: String, existing: Bool)] = []
            var recordingIDs = recoveryRecordingIDs
            for take in takes {
                let originalID = take.recordingID(for: projectId)
                var id = recordingIDs[originalID] ?? originalID
                var target = destination.appendingPathComponent(RecordingFiles.storedName(id: id, displayName: take.displayName))
                var existing = false
                if fileManager.fileExists(atPath: target.path) {
                    if try take.matches(target) {
                        // Copied by an earlier attempt: taken in as it is.
                        existing = true
                    } else {
                        id = UUID().uuidString.lowercased()
                        target = destination.appendingPathComponent(RecordingFiles.storedName(id: id, displayName: take.displayName))
                        if verifyDestination { recordingIDs[originalID] = id }
                    }
                }
                planned.append((take, target, id, existing))
            }
            if recordingIDs != recoveryRecordingIDs {
                guard let persistRecordingIDs else { throw RecordingLibraryError.notVerified }
                try persistRecordingIDs(recordingIDs)
                recoveryRecordingIDs = recordingIDs
            }
            try expect?(planned.map { ($0.target, $0.recordingId, $0.take.displayName, $0.take.sha256) })
            for item in planned {
                copies.append((item.target, item.recordingId, item.take.displayName, item.take.sha256))
                if !item.existing {
                    // Refuses an existing destination, so a file that appeared meanwhile is kept.
                    let source = snapshotFolder.appendingPathComponent(item.take.fileName)
                    try fileManager.copyItem(at: source, to: item.target)
                    created.append((item.target, Self.identity(of: item.target), item.take.sha256))
                }
                if verifyDestination, try !item.take.matches(item.target) { throw RecordingLibraryError.notVerified }
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

    nonisolated private static func remove(_ files: [(url: URL, identity: [AnyHashable]?, sha256: String)], folder: URL?) {
        for file in files {
            // Only the file this copy created, still holding the copied bytes (its
            // source stays in the snapshot): one put there since is left alone (T1.30).
            guard let identity = file.identity, identity == Self.identity(of: file.url),
                  (try? RecordingFiles.sha256(of: file.url)) == file.sha256 else { continue }
            try? FileManager.default.removeItem(at: file.url)
        }
        // A folder this copy created goes too, but only once nothing else is in it.
        if let folder { rmdir(folder.path) } // only when empty
    }

    /// Removes the snapshot only when every recording in it is preserved elsewhere:
    /// a file with its exact bytes in the memo, Trash or quarantine folders (a copy it
    /// made, or the original). Otherwise it is kept (BLOCKER 2) and false is returned.
    @discardableResult
    func discard() -> Bool {
        guard Self.isPreserved(snapshotFolder, recordingsRoot: recordingsRoot) else { return false }
        try? FileManager.default.removeItem(at: snapshotFolder)
        return true
    }

    /// Every audio file in `folder` has a file with the same length and digest in
    /// the memo, Trash or quarantine folders; anything unreadable counts as not.
    nonisolated static func isPreserved(_ folder: URL, recordingsRoot: URL) -> Bool {
        let fileManager = FileManager.default
        guard let sources = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter({ RecordingFiles.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
        let roots = [recordingsRoot, recordingsRoot.deletingLastPathComponent().appendingPathComponent("voice-memos-trash", isDirectory: true),
                     RecordingFiles.quarantineRoot(for: recordingsRoot)]
        var bySize: [Int64: [URL]] = [:]
        for root in roots {
            guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                if let size = try? RecordingFiles.facts(file).size { bySize[size, default: []].append(file) }
            }
        }
        for source in sources {
            guard let size = try? RecordingFiles.facts(source).size, let digest = try? RecordingFiles.sha256(of: source) else { return false }
            guard (bySize[size] ?? []).contains(where: { (try? RecordingFiles.sha256(of: $0)) == digest }) else { return false }
        }
        return true
    }
}

/// The open draft as last typed while a backup or restore held the library.
/// Kept in a file outside the SwiftData store so the text survives the app
/// being killed before the operation reconciles it.
nonisolated private struct DraftRecoveryRecord: Codable, Sendable {
    struct Owner: Codable, Equatable, Sendable {
        let projectId: String
        let row: PersistentIdentifier
        let time: Date
        let repaired: Bool

        @MainActor init(_ song: SongProject) {
            projectId = song.id
            row = song.persistentModelID
            time = song.updatedAt
            repaired = song.precedenceRepaired
        }
    }

    struct Attempt: Codable, Sendable {
        let id: UUID
        let projectId: String
        let row: PersistentIdentifier?
        let store: String
        let anchor: DefaultHistoryToken?

        var author: String { "draft-recovery:\(id.uuidString)" }

        @MainActor init(id: UUID = UUID(), projectId: String, row: PersistentIdentifier?, source: PersistentIdentifier?,
                        in context: ModelContext) throws {
            // The current save can still seal its receipt when history is
            // temporarily unavailable. A later retry cannot infer rollback
            // from an attempt without a verified history anchor.
            let history = (try? context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())) ?? []
            guard let store = row?.storeIdentifier ?? source?.storeIdentifier ?? history.last?.storeIdentifier else {
                throw RecordingLibraryError.notVerified
            }
            self.id = id
            self.projectId = projectId
            self.row = row
            self.store = store
            anchor = history.last { $0.storeIdentifier == store }?.token
        }

        /// Nil is a proved uncommitted attempt. Missing history or a nonqualifying
        /// tagged change cannot authorize another write.
        @MainActor func committedRow(in context: ModelContext, projects: [SongProject]) throws -> SongProject? {
            let history = try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
            let local = history.filter { $0.storeIdentifier == store }
            let changes = local.filter { $0.author == author }.flatMap(\.changes)
            if changes.isEmpty {
                guard let anchor, local.contains(where: { $0.token == anchor }) else {
                    throw RecordingLibraryError.notVerified
                }
                return nil
            }
            let ids = Set(changes.compactMap { change -> PersistentIdentifier? in
                switch change {
                case .insert where row == nil: return change.changedPersistentIdentifier
                case .update where change.changedPersistentIdentifier == row: return change.changedPersistentIdentifier
                default: return nil
                }
            })
            let matching = projects.filter { $0.id == projectId && ids.contains($0.persistentModelID) }
            guard matching.count == 1, let saved = matching.first else { throw RecordingLibraryError.notVerified }
            return saved
        }
    }

    var projectId: String?
    var title: String
    var lyrics: String
    var theme: String
    var baselineTitle: String
    var baselineLyrics: String
    var baselineTheme: String
    var savedAt: Date
    /// The id reserved for a separate copy of these exact words.
    var separateCopyId: String?
    /// The service may have committed this exact draft under the general rescue title.
    var committedCopyTitle: String?
    /// Folder under `recording-recovery` holding the open song's recordings as
    /// they were when the operation began, if it had any.
    var recordingSnapshotFolder: String?
    var recordingTakes: [OpenRecordingSnapshot.Take]?
    /// Alternate recording IDs, keyed by the deterministic ID for the destination song.
    var recordingIDs: [String: String]?
    var sourceRow: PersistentIdentifier?
    var attempt: Attempt?
    var owner: Owner?
    var suppressedRecordingIDs: Set<String>?

    func write(to file: URL) throws {
        try JSONEncoder().encode(self).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
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
            if lyrics != oldValue {
                clearInsertionFeedback()
                // A request answers the lyrics and cursor it was built from
                // (Android cancels on text and selection changes too).
                cancelSuggestions()
                scheduleCountRefresh()
            }
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
            if cursorPosition != oldValue { cancelSuggestions() }
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
    /// Any assignment turns `suggestionsFailed` off; only the suggestions
    /// failure path turns it back on, right after setting its message.
    @Published var errorMessage: String? {
        didSet { suggestionsFailed = false }
    }
    /// True while the error shown was set by the latest suggestions request's
    /// failure. `errorMessage` also carries editor errors, so on iOS the
    /// assistant only offers "Try again" and scrolls to the error when this is
    /// set; the Mac panel still does both for any local error.
    @Published private(set) var suggestionsFailed = false
    /// The request whose stream ended on its own with its lines still listed.
    /// Cleared when a request starts and on every cancel, so Stop, Settings
    /// changes, navigation, errors and lines used before the end never leave it set.
    @Published private(set) var completedSuggestionsRequestID: UUID?

    // MARK: - Rhyme Settings

    // Rhyme options shape the request, so changing one mid-stream drops it,
    // as the Android setters do; lines already shown stay.
    @Published var rhymeType: RhymeType = .perfect {
        didSet {
            if rhymeType != oldValue { cancelSuggestions() }
        }
    }
    @Published var rhymeScheme: RhymeScheme = .aabb {
        didSet {
            if rhymeScheme != oldValue { cancelSuggestions() }
            scheduleDerivedStateRefresh()
        }
    }
    @Published var customRhymeScheme: String = "" {
        didSet {
            if customRhymeScheme != oldValue { cancelSuggestions() }
            scheduleDerivedStateRefresh()
        }
    }
    @Published var rhymeComplexity: RhymeComplexity = .moderate {
        didSet {
            if rhymeComplexity != oldValue { cancelSuggestions() }
        }
    }
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
    private(set) var countTask: Task<Void, Never>?
    /// Waits out the rhyme context's debounce; tests hold it to show the header counts never wait on it.
    var derivedStateDebounce: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Counts the header's words and syllables, or nil once its task is cancelled; tests substitute a slow or instant one.
    var countLyrics: @Sendable (String) -> (words: Int, syllables: Int)? = { lyrics in
        guard let syllables = SyllableCounter.cancellableLyricSyllableCount(lyrics) else { return nil }
        return (SyllableCounter.lyricWordCount(lyrics), syllables)
    }
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
        Self.singleWord(in: lyrics, range: selectedRange)
    }

    /// The text in `range` when it is one word: two or more letters or
    /// apostrophes. The Word Inspector looks up only such a range.
    static func singleWord(in lyrics: String, range: NSRange) -> (word: String, range: NSRange)? {
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

    @Published var currentProjectId: String? {
        // Every other way the editor's song changes leaves it not loaded from a known row.
        didSet { loadedProjectRow = nil }
    }
    /// The stored row whose words the editor holds (loaded, created or last saved to), so two
    /// rows sharing one song id (a restore on two devices, then sync) are told apart.
    /// Read by the Mac sidebar.
    @Published private(set) var loadedProjectRow: PersistentIdentifier?

    /// The editor now holds this stored row's words.
    /// Assigns only what changed, so a save that keeps the same row publishes nothing.
    private func bindEditor(to project: SongProject) {
        if currentProjectId != project.id { currentProjectId = project.id }
        if loadedProjectRow != project.persistentModelID { loadedProjectRow = project.persistentModelID }
        loadedProjectWords = OpenDraft(title: project.title, lyrics: project.lyrics, theme: project.theme)
    }
    /// The bound row's words when it was bound, to tell edits apart once that row is gone.
    private var loadedProjectWords: OpenDraft?

    /// The stored row the open song's words belong to: the bound one; else the first with the
    /// song's id when none is bound, or when `adoptingAnother` (a restore reconcile, which reads
    /// that row's words before claiming it). With unique ids and the row in place, the one row.
    private func storedProject(id: String, in context: ModelContext, adoptingAnother: Bool = true) throws -> SongProject? {
        let rows = try context.fetch(FetchDescriptor<SongProject>(predicate: #Predicate { $0.id == id }))
        if let bound = rows.first(where: { $0.persistentModelID == loadedProjectRow }) { return bound }
        return loadedProjectRow == nil || adoptingAnother ? rows.first : nil
    }
    @Published var saveStatus: SaveStatus = .idle

    /// One song opened or started in the editor. `newProject` and `loadProject`
    /// issue a fresh token so the writing column can cross-fade once per open;
    /// an unsaved song's first autosave keeps its token and does not re-fade.
    struct EditorOpen: Hashable {
        let id = UUID()
        /// New Song moves focus to the title field; opening a saved song keeps its restored cursor.
        let isNewSong: Bool
    }
    @Published private(set) var editorOpen = EditorOpen(isNewSong: false)

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
    /// "Back up now" with no songs here while Drive has this many: asks before merging.
    @Published var emptyBackupConfirmation: Int?
    /// "Recover an earlier backup": Drive's kept manifest revisions, nil until listed.
    @Published private(set) var backupRevisions: [BackupRevision]?
    /// A chosen revision waiting for "Recover"; nothing on Drive changes before that.
    @Published var recoveryToConfirm: BackupRevision?
    /// Recordings over 16 MiB that stay on this device (not in iCloud or Drive).
    @Published private(set) var oversizedRecordingCount = 0
    /// Files the recordings check left alone because another file holds their place
    /// (both are kept); shown in Settings with a way to keep each separately.
    @Published private(set) var recordingsNeedingAttention: [URL] = []
    /// The last check left recordings it could not read in; reported, not re-run.
    @Published private(set) var recordingAdoptionStalled = false
    /// What the last check reported beyond the files above (T3, T5): damaged state
    /// set aside, ids held with other bytes, row audio that could not be written,
    /// files left waiting, and files that cannot be a recording here. Shown in Settings.
    @Published private(set) var recordingNotes: [String] = []
    /// The move record or a tombstone is damaged: the check cannot run until it is
    /// repaired from Settings (T5.2, T5.24).
    @Published private(set) var recordingRecordsDamaged = false
    /// Where audio imports stage their copies (tests point it elsewhere).
    var importRoot: URL = VoiceMemoService.defaultImportRoot
    /// True while the recordings could not be checked: recording lists show
    /// nothing and nothing plays until a check succeeds (A33).
    @Published private(set) var recordingListsSuspended = false
    /// The launch check of the recordings, awaited by tests.
    private(set) var recordingsLaunchTask: Task<Void, Never>?
    /// Launch checks of the recordings still running (a context set twice starts
    /// two): expiry asked for meanwhile is left to them, which run it once one succeeds.
    private var recordingsLaunchChecksRunning = 0
    private let recordingLibrary: RecordingLibrary?
    private var automaticBackupTask: Task<Void, Never>?
    private var automaticBackupFailures = 0
    private var automaticBackupRerunRequested = false
    private var firstRunCheckedThisLaunch = false
    /// Drive's song count while automatic backups wait for a restore (BackupGate).
    private var backupPausedForRestore: Int?
    /// Why the last automatic run could not tell whether it may upload (it uploaded nothing).
    private var backupGateFailure: String?
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
                recordingsLaunchChecksRunning += 1
                // Each check acts only on the context it started with: one replaced
                // meanwhile leaves deletions and expiry to the check of its successor.
                let checkedContext = modelContext
                recordingsLaunchTask = Task { [weak self] in
                    guard let self else { return }
                    // Audio an interrupted restore, import or recovery left staged goes now;
                    // anything a row or the staging journal claims stays (T1.7).
                    if let library = self.recordingLibrary, let context = checkedContext, self.modelContext === context {
                        await library.withGate {
                            // Again once the gate is held: a context set while this waited claims staging this one cannot see.
                            if self.modelContext === context { library.clearStaging(context: context) }
                        }
                    }
                    var checked = false
                    if self.modelContext === checkedContext { checked = await self.reconcileRecordings() }
                    self.recordingsLaunchChecksRunning -= 1
                    guard checked, let checkedContext, self.modelContext === checkedContext else { return }
                    self.applyPersistedDeletions()
                    self.purgeExpiredTrashedProjects()
                    await self.recoverPendingDraftAudio(in: checkedContext)
                    await self.voiceMemoService.retryPendingTakes()
                    // Imports a killed app left are published or disposed of (T1.21).
                    if let library = self.recordingLibrary {
                        let kept = await VoiceMemoService.recoverImports(publisher: library, importRoot: self.importRoot)
                        if !kept.isEmpty {
                            self.recordingNotes.append("Imports that were interrupted are kept on this device: \(kept.joined(separator: ", ")).")
                        }
                    }
                }
            }
            recoverInterruptedDraftIfNeeded()
            seedTrashProjectForUITestsIfNeeded()
            seedFailedTakeForUITestsIfNeeded()
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
    /// The song that was open when `autoSaveTask` was scheduled.
    private var autoSaveProjectId: String?
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
        // Playback stops by recording id (and by file) right before any move or deletion.
        recordingLibrary?.willMove = { [weak self] ids, files in self?.voiceMemoService.stopPlayback(ids: ids, files: files) }
        refreshCloudBackupState()
    }

    deinit {
        trashSchedulerTask?.cancel()
        autoSaveTask?.cancel()
        automaticBackupTask?.cancel()
        rewriteTask?.cancel()
        suggestionsTask?.cancel()
        derivedStateTask?.cancel()
        countTask?.cancel()
        inspectorSynonymsTask?.cancel()
        inspectorAnalysisTask?.cancel()
        // Stop any in-progress recording or playback so AVAudioSession is
        // deactivated before the service is released.
        voiceMemoService.stopRecording()
        voiceMemoService.stopPlayback()
    }

    // MARK: - Rhyme Context

    private nonisolated struct LyricsDerivedState: Sendable {
        let rhymeContext: RhymeContext
    }

    /// The header counts follow every edit with no debounce: the previous
    /// counts stay on screen until the new text's are ready, never zero.
    /// Each edit cancels the count still running for the text before it.
    private func scheduleCountRefresh() {
        countTask?.cancel()
        let lyrics = self.lyrics
        let count = countLyrics
        countTask = Task { @MainActor [weak self] in
            let work = Task.detached(priority: .userInitiated) { count(lyrics) }
            let counts = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard let counts, !Task.isCancelled, let self, self.lyrics == lyrics,
                  counts.words != self.wordCount || counts.syllables != self.syllableCount else { return }
            self.objectWillChange.send()
            self.wordCount = counts.words
            self.syllableCount = counts.syllables
        }
    }

    private func scheduleDerivedStateRefresh() {
        derivedStateTask?.cancel()
        let debounce = derivedStateDebounce
        derivedStateTask = Task { @MainActor [weak self] in
            try? await debounce(.milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            let lyrics = self.lyrics
            let cursorPosition = self.cursorPosition
            let rhymeScheme = self.activeRhymeScheme
            let derived = await Task.detached(priority: .userInitiated) {
                LyricsDerivedState(
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
                        self.suggestionsFailed = true
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
                self.suggestionsFailed = true
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
        // A finished request's failure stays on screen (with its iOS heading)
        // through caret moves and edits; a new request or another message retires it.
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
        editorOpen = EditorOpen(isNewSong: true)
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
            discardSnapshot(nextRecordingSnapshot)
            return
        }
        cancelEditorAIWork()
        autoSaveTask?.cancel()
        title = project.title
        lyrics = project.lyrics
        theme = project.theme
        cursorPosition = 0
        bindEditor(to: project)
        editorOpen = EditorOpen(isNewSong: false)
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
        // The flush cancels the open song's pending autosave; trashing another song leaves it running.
        if currentProjectId == project.id, !flushCurrentDraft(checkpoint: true) { return false }
        guard let context = modelContext else { return false }

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

    /// Returns the restored song, which the Trash's toast can open, or nil
    /// when the save failed and the song stays in Trash.
    @discardableResult
    func restoreTrashedProject(_ trashedProject: TrashedSongProject) -> SongProject? {
        guard let context = modelContext else { return nil }
        let restoredProject = trashedProject.restoredProject()
        removeExistingProjects(id: restoredProject.id, in: context)
        context.insert(restoredProject)
        removeExistingTrashEntries(id: restoredProject.id, in: context)
        do {
            try saveModelContext(context)
        } catch {
            context.rollback()
            errorMessage = "Couldn't restore this song. It remains in Trash."
            return nil
        }
        scheduleTrashPurge()
        return restoredProject
    }

    @discardableResult
    func permanentlyDeleteTrashedProject(_ trashedProject: TrashedSongProject) -> Bool {
        guard let context = modelContext else { return false }
        // Its recordings must have been recovered and adopted, so each one gets its tombstone.
        guard recordingsChecked() else { return false }
        let projectId = trashedProject.id
        let plan: [RecordingFiles.DeletionPlan.Item]
        do {
            // Every file of the song is one the check verified, each with its digest and
            // length, before anything changes (T1.1).
            plan = try recordingLibrary?.songDeletionPlan(projectId, in: context) ?? []
            let deletedAt = Date()
            try upsertPermanentDeletion(projectId: projectId, deletedAt: deletedAt, in: context)
            // Each recording gets its own tombstone in the same save (A21).
            _ = try recordingLibrary?.tombstoneRecordings(ofProject: projectId, deletedAt: deletedAt.epochMilliseconds, in: context)
            context.delete(trashedProject)
            try saveModelContext(context)
        } catch {
            context.rollback()
            errorMessage = "Couldn't permanently delete this song. It remains in Trash."
            return false
        }
        stopPlaybackOfSong(projectId)
        removeSongFiles(projectId, plan: plan, message: "This song was permanently deleted, but some of its local recordings were kept because they changed. Writers Block will retry.")
        do { try companionStore.remove(projectId) } catch { companionError = "Could not remove this song’s local notebook." }
        scheduleTrashPurge()
        return true
    }

    /// The song's verified files go (each only while it holds the planned bytes),
    /// then its empty folders. Without the library nothing proves the bytes, so no
    /// file is removed (T1.4).
    private func removeSongFiles(_ projectId: String, plan: [RecordingFiles.DeletionPlan.Item], message: String) {
        guard let recordingLibrary else { return }
        if let kept = try? recordingLibrary.deleteSongFiles(projectId, plan: plan), kept.isEmpty { return }
        errorMessage = message
    }

    func purgeExpiredTrashedProjects() {
        guard let context = modelContext else { return }
        // One liners hold no song recordings, so they expire before the recordings check.
        try? OneLinersStore(context: context).purgeExpired()
        // Housekeeping asked for before the launch check ran (scene activation, the
        // Trash timer) is left to that check, which expires once it succeeds; it is
        // not reported as a refused deletion the user never asked for.
        guard recordingsLaunchChecksRunning == 0 else { return }
        // Expiry deletes recordings: only once they are recovered and adopted.
        guard recordingsChecked() else { return }
        // Deadlines are fixed first, also for rows iCloud delivered since launch (T2.50).
        normalizeTrashDeadlines(in: context)
        let now = Date()
        let expiredMemos = trashedRecordings().filter { $0.deleteAfter <= now }
        // Every Trash copy of a song is resolved first (A38: deletion time and edit
        // time settled apart, each with its flag), so a newer copy is never expired
        // because an older copy of the same id is due (T2.45).
        let trashCopies = Dictionary(grouping: (try? context.fetch(FetchDescriptor<TrashedSongProject>())) ?? [], by: \.id)
        let resolvedTrash = SyncMerger.mergeTrash(local: trashCopies.values.joined().map { SyncTrashedSongProject(trashed: $0) }, remote: [])
        // Chosen on the normalized deadline: a row without a deletion time is never
        // expired, and a repaired deletion time's deadline is that time plus retention (A37).
        let dueProjects = resolvedTrash.filter {
            $0.deleteAfter <= now && $0.deletedAt.epochMilliseconds > 0
                && (!$0.trashedAtRepaired || $0.deletedAt.addingTimeInterval(trashRetentionInterval) <= now)
        }.sorted { $0.id < $1.id }
        // A Trash entry is expired only after it is resolved against a live copy of the
        // same song (A38: the song's edit time against the Trash deletion time); stale
        // Trash copies beside a newer song just go, with no tombstone and no files (T2.45).
        // Every active copy of a song is resolved too (A37: an edit beats a repair, of
        // two edits the later), so a newer copy is what the Trash entry meets.
        let activeCopies = Dictionary(grouping: (try? context.fetch(FetchDescriptor<SongProject>())) ?? [], by: \.id)
        let active = Dictionary(SyncMerger.mergeProjects(local: activeCopies.values.joined().map { SyncSongProject(project: $0) }, remote: [])
            .map { ($0.id, $0) }) { first, _ in first }
        var stale: [TrashedSongProject] = []
        let resolvedDue = dueProjects.filter { trash in
            guard let song = active[trash.id] else { return true }
            if SyncMerger.activeWins(song, over: trash) {
                stale += trashCopies[trash.id] ?? []
                return false
            }
            return true
        }
        // A song whose folders hold a file the check has not verified (for example a
        // recording waiting for its place) is kept for a later attempt; the others go,
        // each with the plan of its verified files.
        var plans: [String: [RecordingFiles.DeletionPlan.Item]] = [:]
        let expiredProjects = resolvedDue.filter { project in
            guard let recordingLibrary else { return true }
            guard let plan = try? recordingLibrary.songDeletionPlan(project.id, in: context) else { return false }
            plans[project.id] = plan
            return true
        }
        if expiredProjects.count < resolvedDue.count {
            let kept = resolvedDue.count - expiredProjects.count
            errorMessage = "\(kept) expired \(kept == 1 ? "song was" : "songs were") kept in Trash because \(kept == 1 ? "its" : "their") recordings are not all checked yet."
        }
        if !stale.isEmpty {
            stale.forEach(context.delete)
            try? saveModelContext(context)
        }
        guard !expiredProjects.isEmpty || !expiredMemos.isEmpty else {
            scheduleTrashPurge()
            return
        }
        let projectIDs = expiredProjects.map(\.id)
        do {
            // A41: a repaired active copy the Trash entry beat is kept in the song
            // recovery folder first, read back; a failure stops expiry before anything
            // changes.
            let recoveryRoot = recordingLibrary?.memosRoot ?? RecordingFiles.memosRoot()
            for projectId in projectIDs {
                for song in activeCopies[projectId] ?? [] where song.precedenceRepaired {
                    try SongRecoveryStore.keep(.init(project: SyncSongProject(project: song)), memosRoot: recoveryRoot)
                }
            }
            var resolvedAway: [(url: URL, sha256: String, recordingId: String)] = []
            for projectId in projectIDs {
                try upsertPermanentDeletion(projectId: projectId, deletedAt: now, in: context)
                let removed = try recordingLibrary?.tombstoneRecordings(ofProject: projectId, deletedAt: now.epochMilliseconds, in: context) ?? []
                if let library = recordingLibrary, !(activeCopies[projectId] ?? []).isEmpty {
                    // The song met an active copy, so this is a resolution, not only an
                    // expiry: the recordings it removes go to quarantine (never unlinked),
                    // and nothing else in its folders is unlinked.
                    for row in removed {
                        if let file = row.fileURL(memosRoot: library.memosRoot, trashRoot: library.trashRoot), (try? RecordingFiles.exists(file)) == true {
                            resolvedAway.append((file, row.sha256, row.id))
                        }
                    }
                    plans[projectId] = []
                }
                // Superseded live copies of an expired song go with it.
                (activeCopies[projectId] ?? []).forEach(context.delete)
            }
            var memoProofs: [(TrashedVoiceMemo, String, Int64)] = []
            for memo in expiredMemos {
                try tombstoneTrashedMemo(memo, deletedAt: now, in: context)
                memoProofs.append((memo, try RecordingFiles.sha256(of: memo.url), try RecordingFiles.facts(memo.url).size))
            }
            for projectId in projectIDs { (trashCopies[projectId] ?? []).forEach(context.delete) }
            if let library = recordingLibrary, !resolvedAway.isEmpty {
                try library.saveRecordingMoves(quarantine: resolvedAway, in: context) { try saveModelContext(context) }
            } else {
                try saveModelContext(context)
            }
            projectIDs.forEach(stopPlaybackOfSong)
            for projectId in projectIDs {
                removeSongFiles(projectId, plan: plans[projectId] ?? [], message: "Expired writing was removed, but some local recordings were kept because they changed. Writers Block will retry.")
            }
            for projectId in projectIDs { try companionStore.remove(projectId) }
            for (memo, sha, bytes) in memoProofs {
                _ = deleteTrashedFile(memo, sha256: sha, bytes: bytes)
            }
        } catch {
            context.rollback()
            errorMessage = "Couldn't finish removing expired Trash items. They were kept for the next attempt."
        }
        scheduleTrashPurge()
    }

    func permanentlyDeleteTrashedMemo(_ trashed: TrashedVoiceMemo) -> Bool {
        guard let context = modelContext, recordingsChecked() else { return false }
        let proof: (sha: String, bytes: Int64)
        do {
            try tombstoneTrashedMemo(trashed, deletedAt: Date(), in: context)
            // The bytes the deletion is for, recorded with it (T1.25).
            proof = (try RecordingFiles.sha256(of: trashed.url), try RecordingFiles.facts(trashed.url).size)
            try saveModelContext(context)
        } catch {
            context.rollback()
            voiceMemoService.lastError = "Couldn't permanently delete this recording. It remains in Trash."
            return false
        }
        return deleteTrashedFile(trashed, sha256: proof.sha, bytes: proof.bytes)
    }

    /// Unlinks a trashed recording's file only while it holds the recorded bytes,
    /// stopping its playback by id first (T1.25).
    private func deleteTrashedFile(_ trashed: TrashedVoiceMemo, sha256: String, bytes: Int64) -> Bool {
        if let recordingLibrary {
            do {
                try recordingLibrary.deleteTrashedFile(trashed, sha256: sha256, bytes: bytes)
                return true
            } catch {
                voiceMemoService.lastError = "Couldn't remove the local recording file because it changed. It was kept; Writers Block will retry."
                return false
            }
        }
        return voiceMemoService.permanentlyDeleteTrashedMemo(trashed, sha256: sha256, bytes: bytes)
    }

    /// A32/A37/A38 on the song rows: a missing edit or deletion time gets the time
    /// first seen here, marked as a repair, and a repaired deletion time always sets
    /// the Trash deadline. True when anything changed (the caller saves).
    private func repairSongTimes(in context: ModelContext) throws -> Bool {
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
        return repaired
    }

    /// Fixes the song times iCloud may have delivered since launch, before anything
    /// is expired or scheduled (T2.50).
    private func normalizeTrashDeadlines(in context: ModelContext) {
        if (try? repairSongTimes(in: context)) == true { try? saveModelContext(context) }
    }

    private func applyPersistedDeletions() {
        guard let context = modelContext else { return }
        do {
            // A32: songs without a time get the time first seen here, saved on the rows
            // before any tombstone is compared, whether or not there are tombstones.
            let repaired = try repairSongTimes(in: context)
            if repaired { try saveModelContext(context) }
            let deletions = try SyncMerger.mergeDeletions(DeletionStore.all(in: context))
            guard !deletions.isEmpty else { return }
            // A tombstone removes a song only when it is newer than the song's last change,
            // or that time is a repair (A38: a recorded time beats a repaired one).
            let tombstones = Dictionary(deletions.filter(\.isSongTombstone).map { ($0.projectId, $0.deletedAt) }) { max($0, $1) }
            // An edit to the open song typed before this launch-time work ran (the
            // editor is usable at once) is saved first: its new time then stands
            // against the tombstone instead of the edit being lost with the song.
            // If that save fails nothing is deleted and the editor keeps the draft; the
            // tombstones are applied again on the next check.
            if let open = currentProjectId, tombstones[open] != nil {
                guard activeCloudEditorOperation == nil, flushCurrentDraft() else {
                    errorMessage = "Couldn't save the open song before applying deletions from another device. Your edits remain open; Writers Block will retry."
                    return
                }
            }
            var deletedProjects = Set(tombstones.keys)
            let memosRoot = recordingLibrary?.memosRoot ?? RecordingFiles.memosRoot()
            for project in try context.fetch(FetchDescriptor<SongProject>()) where tombstones[project.id] != nil {
                if project.precedenceRepaired || tombstones[project.id]! > project.updatedAt.epochMilliseconds {
                    // A41: a song removed against a repaired time is kept first.
                    if project.precedenceRepaired { try SongRecoveryStore.keep(.init(project: SyncSongProject(project: project)), memosRoot: memosRoot) }
                    context.delete(project)
                } else {
                    deletedProjects.remove(project.id)
                }
            }
            for project in try context.fetch(FetchDescriptor<TrashedSongProject>()) where tombstones[project.id] != nil {
                // A38: a tombstone against the Trash entry's deletion time only.
                if project.trashedAtRepaired || tombstones[project.id]! > project.deletedAt.epochMilliseconds {
                    if project.trashedAtRepaired || project.precedenceRepaired {
                        try SongRecoveryStore.keep(.init(trashed: SyncTrashedSongProject(trashed: project)), memosRoot: memosRoot)
                    }
                    context.delete(project)
                } else {
                    deletedProjects.remove(project.id)
                }
            }
            // The deleted songs' recordings (adopted by the library just before) get
            // their own tombstones in the same save; only their files go.
            var removedFiles: [(url: URL, sha256: String, recordingId: String)] = []
            for projectId in deletedProjects {
                for row in try recordingLibrary?.tombstoneRecordings(ofProject: projectId, deletedAt: tombstones[projectId] ?? 0, in: context) ?? [] {
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
            if let open = currentProjectId, deletedProjects.contains(open) { clearEditorAfterProjectDelete() }
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

    /// True while a timer waits for the next Trash expiry.
    var hasScheduledTrashPurge: Bool { trashSchedulerTask != nil }

    /// Also called after a one liner goes to Trash, so its expiry gets a timer.
    func scheduleTrashPurge() {
        trashSchedulerTask?.cancel()
        guard let context = modelContext else { return }
        normalizeTrashDeadlines(in: context)
        let now = Date()
        var descriptor = FetchDescriptor<TrashedSongProject>(
            predicate: #Predicate<TrashedSongProject> { $0.deleteAfter > now },
            sortBy: [SortDescriptor(\.deleteAfter, order: .forward)]
        )
        descriptor.fetchLimit = 1
        let nextProjectExpiry = (try? context.fetch(descriptor).first)?.deleteAfter
        // Already-expired recordings were purged above; only future expiries count.
        let nextMemoExpiry = trashedRecordings().map(\.deleteAfter).min().flatMap { $0 > now ? $0 : nil }
        let nextOneLinerExpiry = OneLinersStore(context: context).nextExpiry(after: now)
        guard let nextExpiry = [nextProjectExpiry, nextMemoExpiry, nextOneLinerExpiry].compactMap({ $0 }).min() else { return }

        let delay = max(nextExpiry.timeIntervalSinceNow, 0)
        trashSchedulerTask = Task { @MainActor [weak self] in
            // Duration-based sleep — manual Double→UInt64 nanosecond math overflows
            // for far-future dates and would fire the purge immediately.
            try? await Task.sleep(for: .seconds(delay))
            // A cancelled timer was replaced; it must not clear the newer one.
            guard !Task.isCancelled else { return }
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
        bindEditor(to: project)
        suggestions = []
        errorMessage = nil
        saveStatus = .saved
        showWelcome = false
        showProjectsSheet = false
    }

    private func seedFailedTakeForUITestsIfNeeded() {
        guard UITestFlags.isEnabled(UITestFlags.seedFailedTake), UITestFlags.isEnabled(UITestFlags.inMemoryStore),
              let context = modelContext, currentProjectId == nil else { return }
        let project = SongProject(id: "ui-failed-take-song", title: "UI Failed Take", lyrics: "kept words")
        context.insert(project)
        try? context.save()
        let take = RecordingFiles.recorderStagingURL(for: project.id, takeId: "0c0ffee0-0000-4000-8000-000000000001", root: voiceMemoService.stagingRoot)
        try? FileManager.default.removeItem(at: take.deletingLastPathComponent())
        try? FileManager.default.createDirectory(at: take.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not audio".utf8).write(to: take)
        try? Data().write(to: take.deletingLastPathComponent().appendingPathComponent(RecordingFiles.failedTakeMarker))
        voiceMemoService.refreshPendingTakes()
        loadProject(project)
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
        bindEditor(to: project)
        resetCompanionPosition()
        suggestions = []
        errorMessage = nil
        saveStatus = .saved
        showWelcome = false
        showProjectsSheet = false
        resetLyricsHistory()
        trackSelectedDraftDuringCloudOperation()
        // A different song is on screen, as after loadProject.
        editorOpen = EditorOpen(isNewSong: false)
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
        errorMessage = nil
        saveStatus = .idle
        showWelcome = false
        showTemplatesSheet = false
        resetLyricsHistory()
        trackSelectedDraftDuringCloudOperation(isUnsaved: true)
        editorOpen = EditorOpen(isNewSong: false)
        triggerAutoSave()
    }

    func goToStartMenu() {
        guard flushCurrentDraft(checkpoint: true) || openRowVanishedUnedited() else { return }
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
        bindEditor(to: project)
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
        autoSaveProjectId = projectIdAtTrigger
        autoSaveTask = Task { @MainActor [weak self] in
            // A cancelled task leaves every state alone, even one cancelled before it first ran.
            guard let self, !Task.isCancelled else { return }
            // Finished: no autosave is pending. A replaced or stopped task was cancelled and leaves it.
            defer { if !Task.isCancelled { autoSaveTask = nil } }
            guard !emptiedDraftNeedsNoSave else {
                saveStatus = .idle
                return
            }
            saveStatus = .saving

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            runAutoSave(projectIdAtTrigger: projectIdAtTrigger)
        }
    }

    /// The autosave once its wait is over; Mac close and quit run it early.
    /// False when the write was refused.
    @discardableResult
    private func runAutoSave(projectIdAtTrigger: String?) -> Bool {
        // The editor switched projects (or cleared) during the debounce —
        // saving now would write into the wrong project or create an empty one.
        guard currentProjectId == projectIdAtTrigger, !emptiedDraftNeedsNoSave else {
            saveStatus = .idle
            return true
        }
        return persistCurrentDraft(checkpoint: false)
    }

    /// An emptied editor has nothing to save, unless it holds a stored song whose row a lookup
    /// does not find: erasing that song is a refused edit, which Close and Quit must see.
    private var emptiedDraftNeedsNoSave: Bool {
        guard title.isEmpty, lyrics.isEmpty, theme.isEmpty else { return false }
        guard let id = currentProjectId, let context = modelContext else { return true }
        return (try? storedProject(id: id, in: context, adoptingAnother: false)) != nil
    }

    /// Leaving the editor (Open, New, import, template, Start Menu) without writing: its bound
    /// row is confirmed gone and it holds that row's words unchanged, so there is nothing to keep.
    /// A failed lookup proves nothing. Saves also read it, only to report such a refusal as idle.
    private func openRowVanishedUnedited() -> Bool {
        guard activeCloudEditorOperation == nil, let id = currentProjectId, let row = loadedProjectRow,
              let words = loadedProjectWords, let context = modelContext,
              let rows = try? context.fetch(FetchDescriptor<SongProject>(predicate: #Predicate { $0.id == id })),
              !rows.contains(where: { $0.persistentModelID == row }) else { return false }
        let title = words.title.isEmpty ? Self.untitledProjectTitle : words.title
        return OpenDraft(title: title, lyrics: words.lyrics, theme: words.theme) == openDraft
    }

    /// A backup or restore holds the library; saves wait for it to finish and the
    /// open song's edits go to its recovery copy meanwhile.
    var cloudOperationHoldsEditor: Bool { activeCloudEditorOperation != nil }

    /// Closing the Mac window and quitting: the waiting autosave fires now. With none
    /// waiting nothing is written, and a failed last save is reported, not retried.
    /// False when the open song's edits are not saved.
    func savePendingEdit() -> Bool {
        if let task = autoSaveTask, !task.isCancelled {
            task.cancel()
            autoSaveTask = nil
            runAutoSave(projectIdAtTrigger: autoSaveProjectId)
        }
        // A refused edit is .failed; a vanished row with nothing edited is not.
        return saveStatus != .failed
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
        let saved: SongProject
        do {
            if let id = currentProjectId {
                // A save never writes over another row that took the open one's song id.
                guard let project = try storedProject(id: id, in: context, adoptingAnother: false) else {
                    // The open row is gone: nothing is saved. Unedited, nothing has failed either.
                    if openRowVanishedUnedited() {
                        saveStatus = .idle
                        return false
                    }
                    saveStatus = .failed
                    errorMessage = "This song is no longer in the library. Your edits remain open."
                    return false
                }
                if project.title != normalizedProjectTitle() || project.lyrics != lyrics || project.theme != theme {
                    project.title = normalizedProjectTitle()
                    project.lyrics = lyrics
                    project.theme = theme
                    project.updatedAt = Date()
                    project.precedenceRepaired = false  // an edit beats a repair (A37)
                }
                saved = project
            } else {
                let project = makeUntitledSongProject()
                try copyRecordings(of: pendingRecordingRecovery, to: project.id)
                context.insert(project)
                createdProjectID = project.id
                saved = project
            }
            try saveModelContext(context)
            // After the save, so a new row's identity is its stored one.
            bindEditor(to: saved)
            if createdProjectID != nil {
                discardSnapshot(pendingRecordingRecovery)
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
        // The notebook sheet shows only companionError, so a failed song save
        // must be reported here or the sheet clears the unsaved line.
        let notKept = "Could not keep this line because the song did not save. Try again."
        guard flushCurrentDraft() else { companionError = notKept; return }
        if currentProjectId == nil, modelContext != nil { _ = ensureProjectForRecording() }
        guard let id = currentProjectId else { companionError = notKept; return }
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
    private func copyRecordings(of snapshot: OpenRecordingSnapshot?, to projectId: String,
                                verifyDestination: Bool = false, alreadyVerified: Set<String> = [],
                                persistRecordingIDs: (([String: String]) throws -> Void)? = nil) throws {
        guard let snapshot else { return }
        // The library records each copy's identity before its bytes are copied (T1.29).
        try snapshot.copy(to: projectId, verifyDestination: verifyDestination, alreadyVerified: alreadyVerified,
                          persistRecordingIDs: persistRecordingIDs) { [weak self] planned in
            try self?.recordingLibrary?.expectCopies(planned)
        }
        if snapshot.namesDamaged {
            recordingNotes.append("The names of recordings from an interrupted edit could not be read; they were copied under their file names.")
        }
    }

    /// Discards a draft snapshot only when every recording in it is preserved; one
    /// that is not is kept on this device and reported (BLOCKER 2, 13).
    private func discardSnapshot(_ snapshot: OpenRecordingSnapshot?) {
        guard let snapshot else { return }
        if let url = draftRecoveryURL {
            guard let needed = Self.snapshotNamesNeededByRecovery(in: url.deletingLastPathComponent()),
                  !needed.contains(snapshot.folderName) else { return }
        }
        guard !snapshot.discard() else { return }
        let note = "Recordings from an interrupted edit are kept on this device because not all of them are in a song yet."
        if !recordingNotes.contains(note) { recordingNotes.append(note) }
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
        let read = RepairRegistry.read(defaults, key: Self.firstSeenKey)
        if read.damaged { errorMessage = "Saved song times were damaged; they were set aside and kept for diagnosis." }
        var seen = read.times
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
        // What a tombstone without a time names is kept and not played (T5.24), a file
        // with no row (over the cap) by its id too.
        guard let held = try? recordingLibrary.held(in: modelContext) else { return false }
        guard let row = rows.first(where: { $0.fileURL(memosRoot: recordingLibrary.memosRoot, trashRoot: recordingLibrary.trashRoot).map(RecordingFiles.canonicalPath) == path }) else {
            // A file over the cap: its id, song and display name come from its record,
            // so a hold by its name (from before ids) matches too.
            let id = RecordingFiles.storedId(of: url)
            guard let ledger = try? OversizedRecordings.read(for: recordingLibrary.memosRoot) else { return false }
            let entry = id.flatMap { ledger[$0] }
            return !held.contains(projectId: entry?.projectId ?? url.deletingLastPathComponent().lastPathComponent, recordingId: id,
                                  displayName: entry?.fileName ?? url.lastPathComponent)
        }
        guard !held.contains(projectId: row.projectId, recordingId: row.id, displayName: row.displayName) else { return false }
        // A row just delivered may not have its time fixed yet: it is fixed and kept
        // now, as a repair, so it never plays against a tombstone that beats it (T2.55).
        if recordingLibrary.establishTimes(row) { try? saveModelContext(modelContext) }
        return !deletions.contains { $0.covers(projectId: row.projectId, recordingId: row.id, sha256: row.sha256, at: row.precedenceTime, repaired: row.precedenceIsRepair) }
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
            recordingRecordsDamaged = false
            recordingNotes = recordingNotes(from: recordingLibrary)
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
            // A damaged move record or tombstone has a repair in Settings (T5.2, T5.24).
            recordingRecordsDamaged = (error as? RecordingLibraryError) == .journalDamaged || error is SyncValidationError
                || (try? DeletionStore.all(in: modelContext)) == nil
            // Lists and playback follow the failure too (A33).
            recordingListsSuspended = true
            voiceMemoService.recordingsChanged()
            return false
        }
    }

    private func recordingNotes(from library: RecordingLibrary) -> [String] {
        var notes = library.stateIssues
        if let context = modelContext, let undated = try? DeletionStore.undated(in: context), !undated.isEmpty {
            let named = undated.map { $0.recordingId.map { "recording \($0)" } ?? $0.fileName.map { "\($0)" } ?? "song \($0.projectId)" }
            notes.append("\(undated.count) deletion \(undated.count == 1 ? "record has" : "records have") no time, so what \(undated.count == 1 ? "it names is" : "they name is") kept as it is and not shown until a deletion with a time arrives: \(named.sorted().joined(separator: ", ")).")
        }
        if !library.identityConflicts.isEmpty {
            notes.append("\(library.identityConflicts.count) \(library.identityConflicts.count == 1 ? "recording is" : "recordings are") held twice with different audio; both copies are kept: \(library.identityConflicts.joined(separator: ", ")).")
        }
        if !library.unmaterialized.isEmpty {
            notes.append("\(library.unmaterialized.count) \(library.unmaterialized.count == 1 ? "recording" : "recordings") could not be written to this device; the audio stays in the library: \(library.unmaterialized.joined(separator: ", ")).")
        }
        // Each file by where it is kept: its recordings folder, song folder and name (T5.9).
        func location(_ url: URL) -> String { url.pathComponents.suffix(3).joined(separator: "/") }
        if !library.deferredFiles.isEmpty {
            notes.append("Waiting to be read into the library: \(library.deferredFiles.map(location).joined(separator: ", ")).")
        }
        let unrecognized = library.skippedFiles + library.unrecognizedFiles()
        if !unrecognized.isEmpty {
            notes.append("Files in the recordings folders that are not recordings here are left where they are: \(unrecognized.map(location).joined(separator: ", ")).")
        }
        return notes
    }

    /// Repairs damaged recording records so the check can run again (T5.2, T5.24):
    /// a move record that cannot be read is set aside (kept for diagnosis; every file
    /// stays where it is; a record from an earlier build is upgraded instead), and
    /// tombstones naming nothing that can be found are set aside. A tombstone without
    /// a usable time is never given one (A41): it stays and keeps the recordings
    /// paused, and Settings says so (`DeletionStore.repairInvalid`). Then the
    /// recordings are checked again.
    func repairRecordingRecords() async {
        guard let recordingLibrary, let modelContext else { return }
        let suspended: Int
        do {
            let root = recordingLibrary.memosRoot
            try? RecordingFiles.upgradePendingMoves(for: root, now: Date().epochMilliseconds) { _ in "Recording.m4a" }
            if (try? RecordingFiles.readPendingMoves(for: root)) == nil {
                _ = try RecordingFiles.setAsidePendingMoves(for: root)
            }
            suspended = try DeletionStore.repairInvalid(in: modelContext,
                                                        setAside: RecordingFiles.quarantineRoot(for: root).appendingPathComponent("invalid-tombstones.json")).suspended
        } catch {
            errorMessage = "Couldn't repair the recordings records. Everything is kept as it is."
            return
        }
        _ = await reconcileRecordings()
        if suspended > 0 {
            recordingNotes.append("Nothing was deleted: \(suspended) deletion \(suspended == 1 ? "record without a time is" : "records without a time are") kept as \(suspended == 1 ? "it is" : "they are") and never given one.")
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
        } else if let remoteSongs = backupPausedForRestore {
            backupStatus = .failed(reason: Self.backupPausedText(remoteSongs: remoteSongs), lastBackupAt: backupService.lastBackupAt)
        } else if let reason = backupGateFailure {
            backupStatus = .failed(reason: reason, lastBackupAt: backupService.lastBackupAt)
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
        backupPausedForRestore = nil
        backupGateFailure = nil
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
        guard let localSongs = localSongCount(context) else { return }
        if !afterConnecting {
            guard localSongs == 0 else { return }
        }
        guard let summary = try? await backupService.remoteBackupSummary(), summary.songs > 0 else { return }
        automaticBackupTask?.cancel()
        automaticBackupTask = nil
        firstRunRestoreOffer = FirstRunRestoreOffer(songs: summary.songs, recordings: summary.recordings)
        // However the offer is dismissed, automatic backups stay paused until a restore.
        if case .pausedForRestore(let remoteSongs) = BackupGate.decide(localSongCount: localSongs, remoteSongCount: summary.songs, interactive: false, userConfirmed: false) {
            backupPausedForRestore = remoteSongs
        }
        refreshCloudBackupState()
    }

    /// Songs in the library, active or in Trash (a Trash-only library is not a fresh
    /// device); nil when the library cannot be read.
    private func localSongCount(_ context: ModelContext) -> Int? {
        guard let songs = try? context.fetchCount(FetchDescriptor<SongProject>()),
              let trashed = try? context.fetchCount(FetchDescriptor<TrashedSongProject>()) else { return nil }
        return songs + trashed
    }

    /// The gate for this device and Drive; Drive is only asked while the library is
    /// empty. Throws, with the reason, when the library or Drive's song count cannot
    /// be read: an automatic run then uploads nothing and shows why.
    private func backupGate(_ context: ModelContext, interactive: Bool, userConfirmed: Bool) async throws -> BackupGate {
        if firstRunRestoreOffer != nil, !interactive {
            return BackupGate.decide(localSongCount: 0, remoteSongCount: 0, interactive: false, userConfirmed: false, restoreOfferPending: true)
        }
        guard let localSongs = localSongCount(context) else { throw BackupError.network("Couldn't read the songs on this device.") }
        guard localSongs == 0, let backupService else { return .proceed }
        let remoteSongs = try await backupService.remoteBackupSummary()?.songs ?? 0
        return BackupGate.decide(localSongCount: localSongs, remoteSongCount: remoteSongs, interactive: interactive, userConfirmed: userConfirmed)
    }

    static func backupPausedText(remoteSongs: Int) -> String {
        "Backup paused: this device has no songs and Drive has \(remoteSongs) \(remoteSongs == 1 ? "song" : "songs"). Restore to continue."
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
        guard let backupService, backupService.isConnected, let context = modelContext, firstRunRestoreOffer == nil else { return }
        // A first song here ends the pause: this run backs it up (the gate looks again when it starts).
        if backupPausedForRestore != nil, (localSongCount(context) ?? 0) > 0 { backupPausedForRestore = nil }
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

    /// With no songs here and songs on Drive, asks first (`emptyBackupConfirmation`)
    /// and runs only once `confirmedEmptyMerge` is passed.
    func backUpNow(confirmedEmptyMerge: Bool = false) async {
        emptyBackupConfirmation = nil
        if let context = modelContext, canRunCloudBackup {
            do {
                if case .confirmEmptyMerge(let remoteSongs) = try await backupGate(context, interactive: true, userConfirmed: confirmedEmptyMerge) {
                    emptyBackupConfirmation = remoteSongs
                    return
                }
            } catch {
                cloudBackupLastResultIsError = true
                cloudBackupStatusText = "Backup canceled: couldn't check the Google Drive backup. \(cloudBackupErrorDescription(error))"
                return
            }
        }
        await runCloudEditorOperation(
            noun: "Backup",
            changesLibrary: false,
            success: "Backup complete.",
            separateDraft: "Backup complete. Your edits were saved as a separate local draft; back up again to include them."
        ) { service, context, _ in
            try await service.backupNow(modelContext: context)
        }
    }

    func restoreBackupNow() async {
        await runCloudEditorOperation(
            noun: "Restore",
            success: "Restore complete. Projects, trash, and missing recordings were restored.",
            separateDraft: "Restore complete. Your open edits were saved as a separate local draft."
        ) { service, context, handoff in
            try await service.restoreNow(modelContext: context, draftHandoff: handoff)
        }
        voiceMemoService.recordingsChanged()
    }

    /// Lists the backup's earlier versions kept by Drive, newest first.
    func loadBackupRevisions() async {
        guard let backupService, cloudBackupConnected else { return }
        backupRevisions = nil
        do {
            backupRevisions = try await backupService.probeRevisions()
        } catch {
            backupRevisions = []
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = "Couldn't list earlier backups: \(cloudBackupErrorDescription(error))"
        }
    }

    /// Recovers a revision the user confirmed: Drive keeps it forever, then its songs
    /// that are not on this device are added as new songs.
    func recoverBackupRevision(_ revision: BackupRevision) async {
        recoveryToConfirm = nil
        await runCloudEditorOperation(
            noun: "Recovery",
            success: "",
            separateDraft: "Recovery complete. Your open edits were saved as a separate local draft."
        ) { service, context, _ in
            try await service.recoverRevision(revision, modelContext: context)
        }
        voiceMemoService.recordingsChanged()
        // The recovered songs go into the next backup.
        scheduleAutomaticBackup()
    }

    static func revisionDate(_ revision: BackupRevision) -> String {
        revision.modifiedAt?.formatted(.dateTime.month(.abbreviated).day().hour().minute()) ?? "an unknown date"
    }

    /// "Nov 1, 3:14 PM · 2 KB · Kept": its content is read only once it is recovered.
    static func revisionLabel(_ revision: BackupRevision) -> String {
        [revisionDate(revision), revision.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }, revision.keptForever ? "Kept" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Opens the older encrypted backup with a passphrase typed once; it is not kept.
    func migrateLegacyBackup(passphrase: String) async {
        await runCloudEditorOperation(
            noun: "Migration",
            changesLibrary: false,
            success: "",
            separateDraft: "Your open edits were saved as a separate local draft."
        ) { service, context, _ in
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
        ) { service, context, handoff in
            try await service.importArchive(data, modelContext: context, draftHandoff: handoff)
        }
        // Imported recordings are files, which no library save announces.
        voiceMemoService.recordingsChanged()
        scheduleAutomaticBackup()
    }

    /// A backup file the file picker could not read or the save panel could not
    /// write, shown in the backup status line. Cancelling the panel is not one.
    func reportBackupFileFailure(_ message: String, _ error: Error) {
        guard (error as? CocoaError)?.code != .userCancelled else { return }
        cloudBackupLastResultIsError = true
        cloudBackupStatusText = message
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
        action: (CloudBackupServicing, ModelContext, BackupDraftHandoff) async throws -> Void
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
            cloudBackupIsWorking = false
            refreshCloudBackupState()
            finishAutomaticBackupRun()
        }

        var failure: Error?
        let handoff = activeCloudEditorOperation?.draftHandoff ?? BackupDraftHandoff()
        do {
            try await action(backupService, context, handoff)
        } catch {
            failure = error
        }
        let copyNote = handoff.outcome?.copies.isEmpty == false ? "Displaced lyrics were kept locally." : nil
        let recoveredDraft = changesLibrary ? reconcileOpenDraftAfterCloudOperation(in: context) : false
        finishCloudEditorOperation()
        if changesLibrary, let url = draftRecoveryURL, (try? parkedDrafts(beside: url).isEmpty) == false {
            if await reconcileRecordings(), modelContext === context {
                applyPersistedDeletions()
                await recoverPendingDraftAudio(in: context)
            }
        }
        guard let recovered = recoveredDraft else {
            cloudBackupLastResultIsError = true
            cloudBackupStatusText = [
                "\(noun) finished, but recovery of the open draft could not be completed.",
                copyNote, failure.map(cloudBackupErrorDescription)
            ].compactMap { $0 }.joined(separator: " ")
            return
        }
        if let failure {
            cloudBackupLastResultIsError = true
            let reason = cloudBackupErrorDescription(failure)
            // Most reasons already end in a full stop; add one only when missing.
            cloudBackupStatusText = "\(noun) failed: \(reason)\(reason.hasSuffix(".") ? "" : ".") Your open edits remain in the local library."
            if let copyNote { cloudBackupStatusText += " \(copyNote)" }
            return
        }
        automaticBackupFailures = 0
        backupPausedForRestore = nil
        backupGateFailure = nil
        let report = backupService.lastReport
        cloudBackupLastResultIsError = !(report?.damagedRecordings.isEmpty ?? true) || !(report?.missingRecordings.isEmpty ?? true)
        cloudBackupStatusText = [recovered ? separateDraft : success, recovered ? nil : copyNote, reportNote(report)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func reportNote(_ report: BackupReport?) -> String? {
        guard let report else { return nil }
        var notes: [String] = []
        if report.migratedLegacyBackup {
            notes.append("Your older encrypted backup was moved to the new format.")
        }
        if report.recoveredSongs > 0 || report.recoveredRecordings > 0 || report.songsAlreadyHere > 0 || report.songsInBackupTrash > 0
            || report.songsDeletedSince > 0 || report.recordingsDeletedSince > 0 || report.songsHeldWithoutDate > 0 || report.recordingsHeldWithoutDate > 0
            || !report.missingRecordings.isEmpty {
            func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
            notes.append("Recovered \(count(report.recoveredSongs, "song")) and \(count(report.recoveredRecordings, "recording")). \(report.songsAlreadyHere) already here.")
            if report.songsInBackupTrash > 0 {
                notes.append("\(count(report.songsInBackupTrash, "song")) \(report.songsInBackupTrash == 1 ? "is" : "are") in the Google Drive backup's Trash; Restore from backup brings \(report.songsInBackupTrash == 1 ? "it" : "them") to this device's Trash.")
            }
            if report.songsDeletedSince + report.recordingsDeletedSince > 0 {
                notes.append("\(count(report.songsDeletedSince, "song")) and \(count(report.recordingsDeletedSince, "recording")) recovered before and deleted since \(report.songsDeletedSince + report.recordingsDeletedSince == 1 ? "was" : "were") not brought back.")
            }
            if report.songsHeldWithoutDate + report.recordingsHeldWithoutDate > 0 {
                notes.append("\(count(report.songsHeldWithoutDate, "song")) and \(count(report.recordingsHeldWithoutDate, "recording")) \(report.songsHeldWithoutDate + report.recordingsHeldWithoutDate == 1 ? "is" : "are") held by a deletion record without a date and \(report.songsHeldWithoutDate + report.recordingsHeldWithoutDate == 1 ? "was" : "were") not brought back.")
            }
        }
        if !report.missingRecordings.isEmpty {
            let count = report.missingRecordings.count
            notes.append("\(count) \(count == 1 ? "recording" : "recordings") could not come back because \(count == 1 ? "its" : "their") audio is no longer on Google Drive: \(report.missingRecordings.joined(separator: ", ")).")
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
        if !report.recoveredRepairedSongs.isEmpty {
            let count = report.recoveredRepairedSongs.count
            notes.append("\(count) \(count == 1 ? "song was" : "songs were") deleted on another device while \(count == 1 ? "its" : "their") time here was unknown; a copy is kept on this device: \(report.recoveredRepairedSongs.joined(separator: ", ")).")
        }
        if !report.deferredRepairedCleanup.isEmpty {
            let count = report.deferredRepairedCleanup.count
            notes.append("\(count) deleted \(count == 1 ? "recording's" : "recordings'") audio is kept on Google Drive because \(count == 1 ? "its" : "their") time was unknown: \(report.deferredRepairedCleanup.joined(separator: ", ")).")
        }
        if report.retainedLegacyObjects > 0 || report.unresolvedCleanup > 0 {
            notes.append("\(report.retainedLegacyObjects + report.unresolvedCleanup) older Drive \(report.retainedLegacyObjects + report.unresolvedCleanup == 1 ? "file was" : "files were") kept because \(report.retainedLegacyObjects + report.unresolvedCleanup == 1 ? "it" : "they") could not be matched to a backed-up copy.")
        }
        if report.cleanupDeferred {
            notes.append("Deleted audio on Google Drive was not cleaned up because its cleanup record could not be read; nothing was removed.")
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

        func reservation(row: PersistentIdentifier, id: String) -> BackupPendingDraft {
            BackupPendingDraft(sourceRowID: row, title: title, lyrics: lyrics, theme: theme, copyID: id)
        }
    }

    private final class CloudEditorOperation {
        var currentBaseline: OpenDraft
        var currentHadPendingEdit: Bool
        var recordingProjectId: String?
        var savedSeparateOutgoingDraft = false
        let draftHandoff = BackupDraftHandoff()
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
        guard let project = try storedProject(id: id, in: context) else { return nil }
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
        let operation = CloudEditorOperation(
            currentBaseline: openDraft,
            currentHadPendingEdit: hadPendingEdit,
            recordingProjectId: currentProjectId,
            recordingSnapshot: recordingSnapshot
        )
        activeCloudEditorOperation = operation
        operation.draftHandoff.pendingDraft = { [weak self, weak operation] in
            guard let self, let operation, let row = self.loadedProjectRow else { return nil }
            let draft = self.openDraft
            guard operation.currentHadPendingEdit || draft != operation.currentBaseline else { return nil }
            return draft.reservation(row: row, id: operation.separateDraftID)
        }
        operation.draftHandoff.replaceReservation = { [weak self, weak operation] id in
            guard let self, let operation else { throw CocoaError(.fileWriteUnknown) }
            operation.separateDraftID = id
            // The replacement has to reach the journal before the service saves the song.
            guard self.updateDraftRecoveryCopy() else { throw CocoaError(.fileWriteUnknown) }
        }
        operation.draftHandoff.prepareCommit = { [weak self] id, context in
            try self?.prepareDraftCommit(id: id, row: nil, in: context)?.author
        }
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
        guard let operation = activeCloudEditorOperation else {
            return flushCurrentDraft(checkpoint: checkpoint) || openRowVanishedUnedited()
        }
        autoSaveTask?.cancel()
        let draft = openDraft
        guard operation.currentHadPendingEdit || draft != operation.currentBaseline else { return true }
        guard let context = modelContext else { return false }
        var committed: SongProject?
        do {
            let row = loadedProjectRow
            committed = try committedCopy(for: draft, row: row, operation: operation, in: context)
            _ = try keepCloudDraft(draft, row: row, committed: &committed, operation: operation, in: context)
            operation.savedSeparateOutgoingDraft = true
            operation.separateDraftID = UUID().uuidString
            if pendingRecordingRecovery === operation.recordingSnapshot {
                pendingRecordingRecovery = nil
            }
            discardSnapshot(operation.recordingSnapshot)
            operation.recordingSnapshot = nil
            return true
        } catch {
            context.rollback()
            if let committed {
                updateDraftRecoveryCopy(committedCopy: committed)
                deferDraftRecoveryCopy()
                bindEditor(to: committed)
                operation.currentBaseline = openDraft
                operation.currentHadPendingEdit = false
                operation.recordingProjectId = committed.id
                operation.recordingSnapshot = nil
                operation.savedSeparateOutgoingDraft = true
                saveStatus = .saved
                errorMessage = "Your draft was saved. Its recordings are still in recovery."
            } else {
                errorMessage = "Could not save this draft before switching songs. Your edits remain open."
            }
            return false
        }
    }

    private func committedCopy(for draft: OpenDraft, row: PersistentIdentifier?, operation: CloudEditorOperation,
                               in context: ModelContext) throws -> SongProject? {
        guard let row, let receipt = operation.draftHandoff.outcome?.copies.first(where: {
            draft.reservation(row: row, id: operation.separateDraftID).matches($0.source, rowID: $0.sourceRowID)
        }), case .song(let id) = receipt.destination else { return nil }
        let rows = try context.fetch(FetchDescriptor<SongProject>(predicate: #Predicate { $0.id == id }))
        guard let saved = rows.first, rows.count == 1,
              saved.lyrics == draft.lyrics, saved.theme == draft.theme,
              saved.title == draft.title || saved.title == "\(draft.title) (before restore)" else { return nil }
        return saved
    }

    private func keepCloudDraft(_ draft: OpenDraft, row: PersistentIdentifier?, committed: inout SongProject?,
                                operation: CloudEditorOperation, in context: ModelContext) throws -> SongProject {
        if committed == nil, operation.draftHandoff.outcome?.copies.contains(where: {
            $0.destination == .song(operation.separateDraftID)
        }) == true {
            operation.separateDraftID = UUID().uuidString
            guard updateDraftRecoveryCopy() else { throw CocoaError(.fileWriteUnknown) }
        }
        let id = committed?.id ?? operation.separateDraftID
        do {
            if let committed {
                if committed.title != draft.title {
                    committed.title = draft.title
                    try saveModelContext(context)
                }
                if try parkCommittedDraft(committed) { return committed }
                try copyRecordings(of: operation.recordingSnapshot, to: id, verifyDestination: true,
                                   persistRecordingIDs: { ids in
                    guard self.updateDraftRecoveryCopy(committedCopy: committed, recordingIDs: ids) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                })
                return committed
            }
            let attempt = try prepareDraftCommit(id: id, row: nil, in: context)
            if attempt == nil { try copyRecordings(of: operation.recordingSnapshot, to: id) }
            let recovered = SongProject(id: id, title: draft.title, lyrics: draft.lyrics, theme: draft.theme)
            let author = context.author
            if let attempt { context.author = attempt.author }
            do {
                defer { context.author = author }
                context.insert(recovered)
                try saveModelContext(context)
            }
            committed = recovered
            if let row {
                operation.draftHandoff.savedDrafts.append(draft.reservation(row: row, id: recovered.id))
            }
            if attempt != nil { _ = try parkCommittedDraft(recovered) }
            return recovered
        } catch {
            operation.recordingSnapshot?.removeCopy(for: id)
            throw error
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
            discardSnapshot(oldSnapshot)
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
            discardSnapshot(snapshot)
        }
        activeCloudEditorOperation = nil
        if projectDeletionNotice != nil { projectDeletionNotice = nil }
    }

    private func reconcileOpenDraftAfterCloudOperation(in context: ModelContext) -> Bool? {
        let recovered = reconcileOpenDraft(in: context)
        // On failure the edits exist only in the open editor, so the recovery
        // file stays until a later save succeeds.
        if recovered != nil { deferOrRemoveDraftRecoveryCopy() }
        return recovered
    }

    // MARK: Draft recovery file

    /// False only when the copy was needed and could not be written.
    @discardableResult
    private func updateDraftRecoveryCopy(committedCopy: SongProject? = nil, recordingIDs: [String: String]? = nil) -> Bool {
        guard let operation = activeCloudEditorOperation else { return true }
        let draft = openDraft
        let baseline = operation.currentBaseline
        guard operation.currentHadPendingEdit || draft != baseline else {
            deferOrRemoveDraftRecoveryCopy()
            return true
        }
        var kept = committedCopy
        if kept == nil, let outcome = operation.draftHandoff.outcome {
            if let context = modelContext,
               let saved = try? self.committedCopy(for: draft, row: loadedProjectRow, operation: operation, in: context) {
                operation.separateDraftID = saved.id
                kept = saved
            } else if outcome.copies.contains(where: { $0.destination == .song(operation.separateDraftID) }) {
                operation.separateDraftID = UUID().uuidString
            }
        }
        guard draftRecoveryUsable, let url = draftRecoveryURL else { return true }
        do {
            var previous = try readActiveDraftRecovery()
            if let old = previous, (old.attempt != nil || old.owner != nil),
               (old.title != draft.title || old.lyrics != draft.lyrics || old.theme != draft.theme
                || old.recordingSnapshotFolder != operation.recordingSnapshot?.folderName) {
                try parkDraftRecovery(at: url)
                previous = nil
            }
            var takes = try operation.recordingSnapshot?.takesForRecovery()
            if takes != nil, let context = modelContext, let projectId = operation.recordingProjectId {
                let rows = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.projectId == projectId }))
                takes = takes?.map { take in
                    var take = take
                    take.origin = rows.first { $0.storedName == take.fileName && $0.sha256 == take.sha256 }?.syncEntry
                        ?? previous?.recordingTakes?.first { $0.fileName == take.fileName && $0.sha256 == take.sha256 }?.origin
                    return take
                }
            }
            var record = DraftRecoveryRecord(
                projectId: committedCopy == nil ? currentProjectId : operation.recordingProjectId,
                title: draft.title, lyrics: draft.lyrics, theme: draft.theme,
                baselineTitle: baseline.title, baselineLyrics: baseline.lyrics, baselineTheme: baseline.theme,
                savedAt: Date(),
                separateCopyId: kept?.id ?? operation.separateDraftID,
                committedCopyTitle: kept.flatMap { $0.title == draft.title ? nil : $0.title },
                recordingSnapshotFolder: operation.recordingSnapshot?.folderName,
                recordingTakes: takes,
                recordingIDs: recordingIDs ?? operation.recordingSnapshot?.recoveryRecordingIDs
            )
            record.sourceRow = previous?.sourceRow ?? loadedProjectRow
            record.attempt = previous?.attempt
            record.owner = previous?.owner
            if let committedCopy, takes != nil { record.owner = .init(committedCopy) }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Readable while the device is locked: the background backup writes here.
            try record.write(to: url)
            return true
        } catch {
            // The edit is still in the open editor and is reconciled when the
            // operation ends; only the kill protection is missing for it. An
            // earlier copy may remain on disk: it holds older text of the same
            // draft, which launch recovery applies by the same rules.
            return false
        }
    }

    private func readActiveDraftRecovery() throws -> DraftRecoveryRecord? {
        guard draftRecoveryUsable, let url = draftRecoveryURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(DraftRecoveryRecord.self, from: Data(contentsOf: url))
    }

    private func prepareDraftCommit(id: String, row: PersistentIdentifier?, in context: ModelContext) throws -> DraftRecoveryRecord.Attempt? {
        guard activeCloudEditorOperation?.recordingSnapshot != nil, let url = draftRecoveryURL, draftRecoveryUsable else { return nil }
        guard updateDraftRecoveryCopy(), var record = try readActiveDraftRecovery() else { throw CocoaError(.fileWriteUnknown) }
        let attempt = try DraftRecoveryRecord.Attempt(projectId: id, row: row, source: record.sourceRow, in: context)
        record.attempt = attempt
        try record.write(to: url)
        return attempt
    }

    private func parkCommittedDraft(_ song: SongProject) throws -> Bool {
        guard activeCloudEditorOperation?.recordingSnapshot != nil, let url = draftRecoveryURL, draftRecoveryUsable else { return false }
        guard updateDraftRecoveryCopy(committedCopy: song), try readActiveDraftRecovery()?.owner?.row == song.persistentModelID else {
            throw CocoaError(.fileWriteUnknown)
        }
        try parkDraftRecovery(at: url)
        return true
    }

    private func parkDraftRecovery(at url: URL) throws {
        let retry = url.deletingLastPathComponent().appendingPathComponent("unrecovered-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: url, to: retry)
    }

    /// Removes only the file this session writes; copies left by earlier
    /// sessions have other names and are removed by their own recovery.
    private func removeDraftRecoveryCopy() {
        guard draftRecoveryUsable, let url = draftRecoveryURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func deferDraftRecoveryCopy() {
        guard draftRecoveryUsable, let url = draftRecoveryURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try parkDraftRecovery(at: url)
        } catch {
            // Protect the file from later saves even if it could not be renamed.
            draftRecoveryUsable = false
        }
    }

    private func deferOrRemoveDraftRecoveryCopy() {
        do {
            if let record = try readActiveDraftRecovery(), record.owner != nil || record.attempt != nil {
                deferDraftRecoveryCopy()
            } else {
                removeDraftRecoveryCopy()
            }
        } catch {
            deferDraftRecoveryCopy()
        }
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
        let library = recordingLibrary
        recordingSnapshotSweepTask = Task { @MainActor in
            // The hashing runs off the main actor; the final check and every deletion
            // run under the library's gate, so no recording change interleaves (T1.33, T4.5).
            let candidates = await Task.detached(priority: .utility) {
                EditorViewModel.redundantRecordingSnapshots(snapshots, recordingsRoot: recordingsRoot, recoveryFolder: recoveryFolder)
            }.value
            guard !candidates.isEmpty else { return }
            let removeChecked = {
                guard let stillNeeded = EditorViewModel.snapshotNamesNeededByRecovery(in: recoveryFolder) else { return }
                for snapshot in candidates where !stillNeeded.contains(snapshot.lastPathComponent)
                    && OpenRecordingSnapshot.isPreserved(snapshot, recordingsRoot: recordingsRoot) {
                    try? FileManager.default.removeItem(at: snapshot)
                }
            }
            if let library { await library.withGate { removeChecked() } } else { removeChecked() }
        }
    }

    /// Written inside a snapshot that was hashed and found to hold audio with no
    /// live duplicate. It lists the snapshot's files and sizes; while they are
    /// unchanged the snapshot is kept without hashing it again on every launch.
    nonisolated static let recordingSnapshotCheckedMarkerName = ".checked-only-copy.json"

    /// Snapshot folder names that recovery files still need, or nil when a
    /// recovery file cannot be read and so may name any of them.
    nonisolated static func snapshotNamesNeededByRecovery(in recoveryFolder: URL) -> Set<String>? {
        var names = Set<String>()
        // A recovery folder that cannot be listed may name any snapshot: nothing is
        // swept (T3.50). One that does not exist names none.
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: recoveryFolder, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            files = []
        } catch {
            return nil
        }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(DraftRecoveryRecord.self, from: data) else { return nil }
            if let name = record.recordingSnapshotFolder { names.insert(name) }
        }
        return names
    }

    /// Snapshots no recovery file needs whose every file has a live copy with the
    /// same bytes: candidates, checked again under the gate before they go.
    nonisolated private static func redundantRecordingSnapshots(
        _ snapshots: [URL], recordingsRoot: URL, recoveryFolder: URL
    ) -> [URL] {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        guard let needed = snapshotNamesNeededByRecovery(in: recoveryFolder) else { return [] }

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
                candidates.append(snapshot)
            } else if !hashingFailed, let data = try? JSONEncoder().encode(sizes) {
                try? data.write(to: marker, options: .atomic)
            }
        }
        return candidates
    }

    private func recoverDraft(from file: URL, in context: ModelContext) {
        let fileManager = FileManager.default
        guard let data = try? Data(contentsOf: file) else { return }
        guard var record = try? JSONDecoder().decode(DraftRecoveryRecord.self, from: data) else {
            let unreadable = file.deletingLastPathComponent().appendingPathComponent("unreadable-\(file.lastPathComponent)")
            try? fileManager.moveItem(at: file, to: unreadable)
            return
        }
        if record.owner != nil { return }
        let inventoried = record.recordingTakes != nil
        let draft = OpenDraft(title: record.title, lyrics: record.lyrics, theme: record.theme)
        let baseline = OpenDraft(title: record.baselineTitle, lyrics: record.baselineLyrics, theme: record.baselineTheme)
        var copiedSnapshot: OpenRecordingSnapshot?
        var copiedID: String?
        do {
            let projects = try context.fetch(FetchDescriptor<SongProject>())
            let trashed = try context.fetch(FetchDescriptor<TrashedSongProject>())
            func content(_ song: SongProject) -> OpenDraft {
                OpenDraft(title: song.title, lyrics: song.lyrics, theme: song.theme)
            }
            if let attempt = record.attempt, let committed = try attempt.committedRow(in: context, projects: projects) {
                record.owner = .init(committed)
                try record.write(to: file)
                return
            }

            let originals = projects.filter { $0.id == record.projectId }
            let stored = inventoried
                ? originals.count == 1 && (record.sourceRow == nil || originals.first?.persistentModelID == record.sourceRow)
                    ? originals.first : nil
                : originals.first
            var separateID = record.separateCopyId ?? UUID().uuidString
            let separateProjects = projects.filter { $0.id == separateID }
            let separateTrash = trashed.filter { $0.id == separateID }
            let snapshot = recoverySnapshot(for: record)
            let exactOriginal = stored.flatMap { content($0) == draft ? $0 : nil }
            if !inventoried, exactOriginal != nil || !separateProjects.isEmpty || !separateTrash.isEmpty {
                try? fileManager.removeItem(at: file)
                discardSnapshot(snapshot)
                return
            }

            // Inventories written before owner receipts were introduced remain
            // readable. Only an exact, unique pre-existing copy can be admitted.
            if inventoried {
                let exactCopy = record.sourceRow == nil ? separateProjects.first {
                    $0.lyrics == draft.lyrics && $0.theme == draft.theme
                        && ($0.title == draft.title || $0.title == record.committedCopyTitle)
                } : nil
                if let saved = exactOriginal ?? exactCopy {
                    let owners = projects.filter { $0.id == saved.id }.count + trashed.filter { $0.id == saved.id }.count
                    guard owners == 1 else { throw RecordingLibraryError.notVerified }
                    if saved.title != draft.title {
                        saved.title = draft.title
                        try saveModelContext(context)
                    }
                    record.owner = .init(saved)
                    try record.write(to: file)
                    return
                }
                if record.sourceRow == nil, !separateTrash.isEmpty {
                    // No durable predecessor to follow through Trash/Restore.
                    throw RecordingLibraryError.notVerified
                }
            }

            let inPlace = stored.flatMap { song in
                content(song) == baseline && (song.updatedAt <= record.savedAt || song.precedenceRepaired)
                    && !libraryIsCloudBacked(context.container) ? song : nil
            }
            let recovered: SongProject
            if let inPlace {
                recovered = inPlace
            } else {
                if inventoried {
                    let occupied = Set(projects.map(\.id) + trashed.map(\.id) + (try DeletionStore.all(in: context)).map(\.projectId))
                    while occupied.contains(separateID) { separateID = UUID().uuidString }
                    record.separateCopyId = separateID
                } else {
                    try copyRecordings(of: snapshot, to: separateID)
                    copiedSnapshot = snapshot
                    copiedID = separateID
                }
                recovered = SongProject(id: separateID, title: draft.title, lyrics: draft.lyrics, theme: draft.theme,
                                        updatedAt: record.savedAt)
            }
            let previousAuthor = context.author
            defer { context.author = previousAuthor }
            if inventoried {
                let targetRow = inPlace?.persistentModelID
                let attempt: DraftRecoveryRecord.Attempt
                if let prior = record.attempt, prior.projectId == recovered.id, prior.row == targetRow {
                    attempt = prior
                } else {
                    attempt = try DraftRecoveryRecord.Attempt(id: record.attempt?.id ?? UUID(), projectId: recovered.id,
                        row: targetRow, source: record.sourceRow ?? originals.first?.persistentModelID, in: context)
                    if let previous = record.attempt {
                        for sibling in try parkedDrafts(beside: file) where sibling != file {
                            guard let bytes = try? Data(contentsOf: sibling),
                                  var duplicate = try? JSONDecoder().decode(DraftRecoveryRecord.self, from: bytes),
                                  duplicate.attempt?.id == previous.id, duplicate.owner == nil,
                                  duplicate.projectId == record.projectId, duplicate.sourceRow == record.sourceRow,
                                  duplicate.title == draft.title, duplicate.lyrics == draft.lyrics,
                                  duplicate.theme == draft.theme else { continue }
                            duplicate.attempt = attempt
                            duplicate.separateCopyId = record.separateCopyId
                            try duplicate.write(to: sibling)
                        }
                    }
                }
                record.attempt = attempt
                try record.write(to: file)
                context.author = attempt.author
            }
            if let inPlace {
                inPlace.title = draft.title
                inPlace.lyrics = draft.lyrics
                inPlace.theme = draft.theme
                inPlace.updatedAt = record.savedAt
                inPlace.precedenceRepaired = false
            } else {
                context.insert(recovered)
            }
            try saveModelContext(context)
            context.author = previousAuthor
            if inventoried {
                record.owner = .init(recovered)
                try record.write(to: file)
            } else {
                try? fileManager.removeItem(at: file)
                discardSnapshot(snapshot)
            }
            loadProject(recovered)
            saveStatus = .saved
        } catch {
            context.rollback()
            if let copiedID { copiedSnapshot?.removeCopy(for: copiedID) }
            errorMessage = "Could not finish recovering the song you were editing. The draft was kept and will be retried. You can copy it from Settings → Backup."
        }
    }

    private func recoverySnapshot(for record: DraftRecoveryRecord) -> OpenRecordingSnapshot? {
        guard let name = record.recordingSnapshotFolder, let root = backupService?.recordingRecoveryRoot else { return nil }
        return OpenRecordingSnapshot(existingFolderNamed: name, recordingsRoot: root)
    }

    private func parkedDrafts(beside url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("unrecovered-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The writer can export a journal without authorizing automatic text replay.
    struct InterruptedDraft: Identifiable {
        let id: URL
        let title: String
        let text: String
        let recordings: [URL]
    }

    var interruptedDrafts: [InterruptedDraft] {
        guard let url = draftRecoveryURL, let parked = try? parkedDrafts(beside: url) else { return [] }
        return parked.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(DraftRecoveryRecord.self, from: data) else { return nil }
            var recordings: [URL] = []
            if let snapshot = recoverySnapshot(for: record), let root = backupService?.recordingRecoveryRoot {
                let staging = OpenRecordingSnapshot.stagingRoot(for: root)
                let folder = staging.appendingPathComponent(snapshot.folderName)
                recordings = (record.recordingTakes ?? []).compactMap { take in
                    let path = folder.appendingPathComponent(take.fileName)
                    guard take.fileName == path.lastPathComponent,
                          RecordingFiles.isRecordingFile(path, in: [staging]) else { return nil }
                    return path
                }
            }
            return InterruptedDraft(id: file, title: record.title, text: record.lyrics, recordings: recordings)
        }
    }

    private func recoverPendingDraftAudio(in context: ModelContext) async {
        guard let url = draftRecoveryURL, let library = recordingLibrary,
              let files = try? parkedDrafts(beside: url), !files.isEmpty else { return }
        await library.withGate {
            for file in files where modelContext === context {
                do {
                    try await recoverDraftAudio(from: file, using: library, in: context)
                } catch {
                    errorMessage = "Some recordings are still in draft recovery and will be retried the next time the app opens."
                }
            }
        }
    }

    private func recoverDraftAudio(from file: URL, using library: RecordingLibrary, in context: ModelContext) async throws {
        guard let data = try? Data(contentsOf: file),
              var record = try? JSONDecoder().decode(DraftRecoveryRecord.self, from: data),
              let owner = record.owner, let takes = record.recordingTakes else { return }
        let root = library.memosRoot
        let projectId = owner.projectId
        let snapshot = recoverySnapshot(for: record)
        let staging = OpenRecordingSnapshot.stagingRoot(for: root)
        let folder = snapshot.map { staging.appendingPathComponent($0.folderName) }
        let links = try parkedDrafts(beside: file).filter { $0 != file }.compactMap { url -> (URL, DraftRecoveryRecord)? in
            guard let bytes = try? Data(contentsOf: url),
                  let other = try? JSONDecoder().decode(DraftRecoveryRecord.self, from: bytes),
                  other.owner?.row == owner.row, other.projectId == record.projectId else { return nil }
            return (url, other)
        }

        var incomplete = false
        for take in takes {
            let key = take.recordingID(for: projectId)
            if record.suppressedRecordingIDs?.contains(key) == true { continue }
            do {
                try library.requireChecked(context)
                let deletions = try DeletionStore.all(in: context)
                let songs = try context.fetch(FetchDescriptor<SongProject>(predicate: #Predicate { $0.id == projectId }))
                let trash = try context.fetch(FetchDescriptor<TrashedSongProject>(predicate: #Predicate { $0.id == projectId }))
                if !songs.contains(where: { $0.persistentModelID == owner.row }), trash.isEmpty, deletions.contains(where: {
                    $0.isSongTombstone && $0.projectId == projectId && $0.wins(over: owner.time, repaired: owner.repaired)
                }) {
                    record.suppressedRecordingIDs = Set(takes.map { $0.recordingID(for: projectId) })
                    try record.write(to: file)
                    break
                }
                guard songs.count == 1, trash.isEmpty, let song = songs.first,
                      song.persistentModelID == owner.row,
                      !deletions.contains(where: {
                          $0.isSongTombstone && $0.projectId == projectId && $0.wins(over: song.updatedAt, repaired: song.precedenceRepaired)
                      }) else { throw RecordingLibraryError.notVerified }

                let relevant = links.filter { link in link.1.recordingTakes?.contains(where: {
                    $0.fileName == take.fileName && $0.bytes == take.bytes && $0.sha256 == take.sha256
                }) == true }
                let aliases = Set(([record.recordingIDs?[key]] + relevant.map { $0.1.recordingIDs?[key] })
                    .compactMap { $0 }.filter { UUID(uuidString: $0) != nil })
                guard aliases.count <= 1 else { throw RecordingLibraryError.notVerified }
                var id = aliases.first ?? key
                let original = take.origin?.id ?? URL(fileURLWithPath: take.fileName).deletingPathExtension().lastPathComponent
                let sourceProjectId = record.projectId ?? projectId
                let sourceRecordingId = UUID(uuidString: original) != nil ? original : take.recordingID(for: sourceProjectId)
                let binding = RecordingFiles.PendingMoves.Adopt.DraftBinding(
                    projectId: projectId, row: owner.row, sourceProjectId: sourceProjectId,
                    sourceRecordingId: sourceRecordingId, originalId: key, bytes: take.bytes,
                    precedenceTime: take.origin?.uploadedAt ?? record.savedAt,
                    precedenceRepaired: take.origin?.precedenceRepaired ?? true
                )
                let rows = try context.fetch(FetchDescriptor<Recording>())

                if deletions.contains(where: { deletion in
                    guard !deletion.isSongTombstone, !binding.isSourceSongCascade(deletion, among: deletions) else { return false }
                    if let origin = take.origin, deletion.covers(origin) { return true }
                    let addresses = [(projectId, id), (projectId, key), (sourceProjectId, sourceRecordingId)]
                    return addresses.contains { project, recording in
                        let row = rows.first { $0.projectId == project && $0.id == recording && $0.sha256 == take.sha256 }
                        return deletion.covers(projectId: project, recordingId: recording, sha256: take.sha256,
                            at: row?.precedenceTime ?? take.origin?.uploadedAt ?? record.savedAt,
                            repaired: row?.precedenceIsRepair ?? take.origin?.precedenceRepaired ?? true)
                    }
                }) {
                    record.suppressedRecordingIDs = (record.suppressedRecordingIDs ?? []).union([key])
                    try record.write(to: file)
                    continue
                }
                // Keep a proved original in place and an already-adopted copy under its chosen ID.
                let matching = rows.filter {
                    $0.projectId == projectId && ($0.id == id || (record.projectId == projectId && $0.id == original))
                    && $0.sha256 == take.sha256 && $0.bytes == take.bytes
                }
                if matching.contains(where: { row in
                    guard let path = row.fileURL(memosRoot: root, trashRoot: library.trashRoot) else { return false }
                    return (try? take.matches(path)) == true
                }) {
                    if let alias = aliases.first {
                        try saveDraftRecordingAlias(alias, for: key, record: &record, file: file, links: relevant)
                    }
                    continue
                }
                let oversizedOccupant = try OversizedRecordings.read(for: root)[id]
                if let entry = oversizedOccupant, entry.completed != false, entry.projectId == projectId {
                    let base = entry.trashedAt == nil ? root : library.trashRoot
                    let path = try RecordingFiles.localURL(projectId: projectId,
                        fileName: RecordingFiles.storedName(id: id, displayName: entry.fileName), memosRoot: base)
                    if (try? take.matches(path)) == true { continue }
                }

                var target = try RecordingFiles.localURL(projectId: projectId,
                    fileName: RecordingFiles.storedName(id: id, displayName: take.displayName), memosRoot: root)
                let moves = try RecordingFiles.readPendingMoves(for: root)
                let planned = moves.adopt.first {
                    $0.recordingId == id && $0.sha256 == take.sha256 && $0.path == RecordingFiles.canonicalPath(target)
                }
                let idOccupied = rows.contains { $0.id == id }
                if try RecordingFiles.exists(target), planned != nil, !idOccupied, (try? take.matches(target)) == true {
                    try await library.reconcile(context: context)
                } else {
                    guard let folder, take.fileName == URL(fileURLWithPath: take.fileName).lastPathComponent else {
                        throw RecordingLibraryError.takeMissing
                    }
                    let source = folder.appendingPathComponent(take.fileName)
                    guard RecordingFiles.isRecordingFile(source, in: [staging]),
                          (try? take.matches(source)) == true else { throw RecordingLibraryError.takeMissing }
                    if try idOccupied || oversizedOccupant != nil || RecordingFiles.exists(target) {
                        id = UUID().uuidString.lowercased()
                        target = try RecordingFiles.localURL(projectId: projectId,
                            fileName: RecordingFiles.storedName(id: id, displayName: take.displayName), memosRoot: root)
                    }
                    if id != key { try saveDraftRecordingAlias(id, for: key, record: &record, file: file, links: relevant) }
                    let temporary = folder.appendingPathComponent(".recovery-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try FileManager.default.copyItem(at: source, to: temporary)
                    if take.bytes > SyncRecording.maxBytes {
                        guard try take.matches(temporary) else { throw RecordingLibraryError.notVerified }
                        _ = try library.publishFinished(temporary, projectId: projectId, preferredName: take.displayName,
                            origin: .recorded, id: id, finishedAt: take.origin?.uploadedAt, draftBinding: binding)
                    } else {
                        if planned?.draftBinding != binding || id != (aliases.first ?? key) {
                            try library.expectCopies([(target, id, take.displayName, take.sha256)], draftBinding: binding)
                        }
                        try RecordingFiles.verifiedMove(temporary, to: target, sha256: take.sha256, bytes: take.bytes, within: [root, folder])
                    }
                    try await library.reconcile(context: context)
                }
                guard modelContext === context else { return }
                let adopted = try context.fetch(FetchDescriptor<Recording>()).contains {
                    $0.id == id && $0.projectId == projectId && $0.sha256 == take.sha256 && $0.bytes == take.bytes
                }
                let oversized = try take.bytes > SyncRecording.maxBytes
                    && OversizedRecordings.read(for: root)[id]?.completed == true
                guard adopted || oversized, (try? take.matches(target)) == true else { throw RecordingLibraryError.notVerified }
            } catch {
                // A missing take cannot prevent later takes in this same journal from being adopted.
                incomplete = true
                continue
            }
        }
        guard try !incomplete && draftAudioIsComplete(record, using: library, in: context) else {
            errorMessage = "Some recordings are still in draft recovery and will be retried the next time the app opens."
            return
        }
        try FileManager.default.removeItem(at: file)
        if let snapshot, let needed = Self.snapshotNamesNeededByRecovery(in: file.deletingLastPathComponent()),
           !needed.contains(snapshot.folderName) {
            discardSnapshot(snapshot)
        }
    }

    private func saveDraftRecordingAlias(_ id: String, for key: String, record: inout DraftRecoveryRecord, file: URL,
                                         links: [(URL, DraftRecoveryRecord)]) throws {
        if record.recordingIDs?[key] != id {
            record.recordingIDs = (record.recordingIDs ?? [:]).merging([key: id]) { _, new in new }
            try record.write(to: file)
        }
        for (url, _) in links {
            var shared = try JSONDecoder().decode(DraftRecoveryRecord.self, from: Data(contentsOf: url))
            guard shared.recordingIDs?[key] != id else { continue }
            shared.recordingIDs = (shared.recordingIDs ?? [:]).merging([key: id]) { _, new in new }
            try shared.write(to: url)
        }
    }

    private func draftAudioIsComplete(_ record: DraftRecoveryRecord, using library: RecordingLibrary,
                                      in context: ModelContext) throws -> Bool {
        guard let owner = record.owner, let takes = record.recordingTakes else { return false }
        let id = owner.projectId
        let pending = takes.filter { record.suppressedRecordingIDs?.contains($0.recordingID(for: id)) != true }
        if pending.isEmpty { return true }
        let live = try context.fetch(FetchDescriptor<SongProject>(predicate: #Predicate { $0.id == id }))
        let trash = try context.fetch(FetchDescriptor<TrashedSongProject>(predicate: #Predicate { $0.id == id }))
        guard live.count == 1, live.first?.persistentModelID == owner.row, trash.isEmpty else { return false }
        let rows = try context.fetch(FetchDescriptor<Recording>(predicate: #Predicate { $0.projectId == id }))
        let oversized = try OversizedRecordings.read(for: library.memosRoot)
        return try pending.allSatisfy { take in
            let expected = take.recordingID(for: id)
            let alias = record.recordingIDs?[expected] ?? expected
            if rows.contains(where: { row in
                guard row.id == alias || (id == record.projectId && row.storedName == take.fileName),
                      row.sha256 == take.sha256, row.bytes == take.bytes,
                      let path = row.fileURL(memosRoot: library.memosRoot, trashRoot: library.trashRoot) else { return false }
                return (try? take.matches(path)) == true
            }) { return true }
            guard let entry = oversized[alias], entry.completed != false, entry.projectId == id else { return false }
            let root = entry.trashedAt == nil ? library.memosRoot : library.trashRoot
            let path = try RecordingFiles.localURL(projectId: id,
                fileName: RecordingFiles.storedName(id: alias, displayName: entry.fileName), memosRoot: root)
            return (try? take.matches(path)) == true
        }
    }

    private func reconcileOpenDraft(in context: ModelContext) -> Bool? {
        guard let operation = activeCloudEditorOperation else { return nil }
        autoSaveTask?.cancel()
        let draft = openDraft
        let edited = operation.currentHadPendingEdit || draft != operation.currentBaseline
        // The row the editor held, before the lookup can fall back to another under its song id.
        let boundRow = loadedProjectRow
        var committedRecovery: SongProject?

        do {
            guard operation.recordingProjectId == currentProjectId else {
                throw CocoaError(.fileReadUnknown)
            }
            let stored = try currentProjectId.flatMap { try storedDraft(id: $0, in: context) }
            // Edits go into the row they were made on; if that one is gone they are recovered separately.
            let originalKept = boundRow != nil && stored?.0.persistentModelID == boundRow
            // Every branch below leaves the editor with this row's words, or a new row's.
            if let stored { bindEditor(to: stored.0) }
            if edited {
                if originalKept, let stored, stored.1 == draft {
                    committedRecovery = stored.0
                    _ = try parkCommittedDraft(stored.0)
                    if saveStatus == .saving || saveStatus == .failed { saveStatus = .saved }
                    return operation.savedSeparateOutgoingDraft
                }
                if originalKept, let stored, stored.1 == operation.currentBaseline {
                    let attempt = try prepareDraftCommit(id: stored.0.id, row: stored.0.persistentModelID, in: context)
                    stored.0.title = draft.title
                    stored.0.lyrics = draft.lyrics
                    stored.0.theme = draft.theme
                    stored.0.updatedAt = Date()
                    stored.0.precedenceRepaired = false
                    let author = context.author
                    if let attempt { context.author = attempt.author }
                    do {
                        defer { context.author = author }
                        try saveModelContext(context)
                    }
                    committedRecovery = stored.0
                    if attempt != nil { _ = try parkCommittedDraft(stored.0) }
                    bindEditor(to: stored.0)
                    saveStatus = .saved
                    return operation.savedSeparateOutgoingDraft
                }
                committedRecovery = try committedCopy(for: draft, row: boundRow, operation: operation, in: context)
                let recovered = try keepCloudDraft(draft, row: boundRow, committed: &committedRecovery, operation: operation, in: context)
                discardSnapshot(operation.recordingSnapshot)
                operation.recordingSnapshot = nil
                cancelEditorAIWork()
                bindEditor(to: recovered)
                title = recovered.title
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
            if let committedRecovery {
                // The text already belongs to this song. Keep the audio recovery file
                // separate from ordinary saves so they cannot discard the retry.
                bindEditor(to: committedRecovery)
                updateDraftRecoveryCopy(committedCopy: committedRecovery)
                deferDraftRecoveryCopy()
                operation.recordingSnapshot = nil
                saveStatus = .saved
                errorMessage = "The draft was saved. Its recordings could not be recovered and will be retried the next time the app opens."
                return nil
            }
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
        // Restore first: nothing uploads from an empty library over a Drive backup with songs.
        let gate: BackupGate
        do {
            gate = try await backupGate(context, interactive: false, userConfirmed: false)
            backupGateFailure = nil
        } catch {
            // Nothing uploads while it is unknown whether this run may; the reason shows
            // with Retry, and the run is tried again after the usual backoff.
            backupGateFailure = "Backup waiting: couldn't check the Google Drive backup. \(cloudBackupErrorDescription(error))"
            cloudBackupIsWorking = false
            automaticBackupFailures += 1
            refreshCloudBackupState()
            scheduleAutomaticBackup()
            return
        }
        if gate != .proceed {
            if case .pausedForRestore(let remoteSongs) = gate { backupPausedForRestore = remoteSongs }
            cloudBackupIsWorking = false
            refreshCloudBackupState()
            // A change saved meanwhile (a first song) gets its own run.
            if automaticBackupRerunRequested {
                automaticBackupRerunRequested = false
                scheduleAutomaticBackup()
            }
            return
        }
        backupPausedForRestore = nil
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
