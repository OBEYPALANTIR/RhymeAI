import Foundation
import SwiftData

/// A voice memo in the library, so recordings sync through iCloud with the
/// songs. Its `id` is the recording's identity everywhere (Drive file
/// `rec_<id>`, manifest, tombstones) and its file name on disk (A36):
/// `<id>.<ext>` in the memo folder, or in the recordings Trash while
/// `trashedAt` is set. `displayName` is what the user sees and renames; it is
/// metadata only and never touches the file. `RecordingLibrary` keeps the files
/// in step with the rows, which are the source of truth.
@Model
final class Recording {
    // See SongProject.swift: CloudKit needs property defaults and no unique attributes.
    var id: String = ""
    var projectId: String = ""
    /// The name the user sees, with its extension (A36). Two recordings may share it.
    var displayName: String = ""
    var sha256: String = ""
    var bytes: Int64 = 0
    var recordedAt: Date = Date()
    /// The precedence time a tombstone is judged against, persisted once and
    /// never re-derived from the file: finish time for a new recording, the
    /// backup's time for restored or imported audio, the old entry's time for
    /// migrated audio, the earliest file date for a memo from before this
    /// version, or the time it was first seen when none was recorded (A32).
    var uploadedAt: Date?
    /// A37: `uploadedAt` was established for a missing time, not recorded.
    var precedenceRepaired: Bool = false
    /// A rename made here that a backup has not written yet (A36): its name goes to
    /// the manifest; otherwise the manifest's name stands.
    var displayNameChanged: Bool = false
    /// recorded, restored, imported or migrated.
    var origin: String = Origin.recorded.rawValue
    /// Set while the recording sits in the recordings Trash.
    var trashedAt: Date?
    /// Where this row's audio is while a move is under way (a staging file, the
    /// other folder, or its file from before A36), written before the move; only a
    /// file there holding the row's bytes is ever taken for its audio.
    var pendingFrom: String?
    @Attribute(.externalStorage) var audio: Data = Data()

    enum Origin: String {
        case recorded, restored, imported, migrated
    }

    /// `sha256`, when given, is the audio's digest already verified off the main actor.
    init(id: String = UUID().uuidString.lowercased(), projectId: String, displayName: String, audio: Data, recordedAt: Date,
         uploadedAt: Date? = nil, origin: Origin = .recorded, sha256: String? = nil) {
        self.id = id
        self.projectId = projectId
        self.displayName = displayName
        self.audio = audio
        self.bytes = Int64(audio.count)
        self.sha256 = sha256 ?? RecordingBackupManifest.sha256Hex(audio)
        self.recordedAt = recordedAt
        self.uploadedAt = uploadedAt ?? recordedAt
        self.origin = origin.rawValue
    }

    var precedenceTime: Date { uploadedAt ?? recordedAt }

    /// `<id>.<ext>`: the only name this recording has on disk.
    var storedName: String { RecordingFiles.storedName(id: id, displayName: displayName) }

    var syncEntry: SyncRecording {
        SyncRecording(id: id, projectId: projectId, fileName: displayName, bytes: bytes, sha256: sha256, uploadedAt: precedenceTime,
                      precedenceRepaired: precedenceRepaired)
    }

    /// Where this recording's file lives: the memo folder, or the Trash while trashed.
    func fileURL(memosRoot: URL, trashRoot: URL) -> URL? {
        guard (try? SyncIdentity.validateProjectId(projectId)) != nil else { return nil }
        return (trashedAt == nil ? memosRoot : trashRoot)
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent(storedName)
    }
}

enum RecordingLibraryError: Error, Equatable {
    /// A memo folder or file could not be read; nothing was changed.
    case scanFailed
    /// The library is not open, so the change could not be recorded.
    case unavailable
    /// The audio moved into place but its record could not be finished; the
    /// recording stands and is finished on the next run (A31).
    case finalizeFailed
    /// A take promised by id has neither a row nor its audio: nothing can be saved.
    case takeMissing
    /// The recordings have not been checked successfully (or the tombstones or the
    /// move record cannot be read), so nothing is changed until they are (A33).
    case notChecked
    /// The file is not the recording it is taken for (its bytes differ).
    case notVerified
}

extension RecordingLibraryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .scanFailed: return "A recordings folder could not be read, so nothing was changed. Writers Block will try again."
        case .unavailable: return "The library is not open yet, so the recording could not be saved."
        case .finalizeFailed: return "The recording was saved, but its record could not be finished. Writers Block will finish it on the next try."
        case .takeMissing: return "This recording's audio is no longer on this device."
        case .notChecked: return "Your recordings are being checked, so nothing was changed. Try again in a moment."
        case .notVerified: return "This recording changed on this device, so nothing was changed. Try again in a moment."
        }
    }
}

/// A recording as the lists show it: its file, its name and its time.
struct RecordingListItem: Identifiable, Equatable {
    let url: URL
    let projectId: String
    let displayName: String
    let date: Date
    var id: String { url.absoluteString }
}

/// Memo changes that must record their metadata before the file moves.
@MainActor
protocol RecordingPublishing: AnyObject {
    /// Moves a finished recording or imported audio from staging into the memo
    /// folder as `<id>.<ext>`, named `preferredName` for the user. `id` names a
    /// take already promised to the user (A27): publishing it again once it is
    /// published is a success. `finishedAt` is its finish time (A31).
    func publishFinished(_ staged: URL, projectId: String, preferredName: String, origin: Recording.Origin, id: String?, finishedAt: Date?) throws -> URL
    /// Renames for the user only: the file keeps its name (A36).
    func renameRecording(at url: URL, to displayName: String) throws
    func trashRecording(at url: URL, trashedAt: Date) throws -> TrashedVoiceMemo
    func untrashRecording(_ trashed: TrashedVoiceMemo) throws -> URL
}

extension RecordingPublishing {
    func publishFinished(_ staged: URL, projectId: String, preferredName: String, origin: Recording.Origin) throws -> URL {
        try publishFinished(staged, projectId: projectId, preferredName: preferredName, origin: origin, id: nil, finishedAt: nil)
    }
}

/// Keeps the `Recording` rows (iCloud) and the memo files in step. Owned by the
/// app, independent of Drive: it runs at launch, when iCloud delivers changes,
/// and after any memo change; runs are serialised.
///
/// Every file is `<recordingId>.<ext>` (A36): nothing is allocated or renamed on
/// disk, and the only moves are staging → live, live ⇄ Trash, live → quarantine,
/// and migrating a file from before A36 to its id. A run reads every folder,
/// file and move record off the main actor, streaming digests (a cached digest
/// may skip re-hashing for the inventory but never justifies a move), and keeps
/// the bytes of files to adopt within a memory budget. On the main actor it
/// re-lists and re-stats everything and commits only if nothing changed. Copies
/// of one identity are gathered with their row before anything is decided; the
/// precedence time is fixed first (first-seen when missing, A32); deletions are
/// resolved once. Every move is recorded before the save that decides it and
/// goes through `willMove` first. Changes made outside a run need the complete
/// check (A33).
@MainActor
final class RecordingLibrary: RecordingPublishing {
    struct Result: Equatable {
        var oversizedCount = 0
        /// Live and Trash files over the cap, which stay on this device only.
        var oversizedFiles: [URL] = []
        /// Identities whose bytes did not fit the run's passes; the next run takes them.
        var pendingAdoption = 0
        /// Files from before A36 whose id name is taken by other bytes: left in place.
        var needsAttention: [URL] = []
    }

    static let shared = RecordingLibrary(defaults: .standard)

    private static let verifiedKey = "recording-library-verified-ids"
    private static let digestCacheKey = "recording-library-digest-cache"
    private static let firstSeenKey = "recording-library-first-seen"
    let memosRoot: URL
    let trashRoot: URL
    private let defaults: UserDefaults
    /// The open library, for memo changes made outside a reconcile.
    var context: ModelContext?
    /// The library save; tests substitute a failing one.
    var save: (ModelContext) throws -> Void = { try $0.save() }
    private(set) var oversizedCount = 0
    private(set) var oversizedFiles: [URL] = []
    /// Identities still waiting to be adopted after the last run (finding 10).
    private(set) var pendingAdoption = 0
    /// True when the last run left files waiting and could take in none of them:
    /// reported, never re-run in a loop.
    private(set) var adoptionStalled = false
    private(set) var needsAttention: [URL] = []
    /// True after a run succeeded, false after one failed: changes made outside a
    /// run need it (A33).
    private(set) var lastRunSucceeded = false
    /// Called on the main actor right before memo or Trash files move, in the same
    /// turn as the move, so playback of them stops first and no Play can start in
    /// between (playback starts on the main actor too).
    var willMove: (([URL]) -> Void)?
    /// Tests: called at the move boundary, after `willMove`, for each file.
    var atMoveBoundary: ((URL) -> Void)?
    /// Bytes one read pass keeps in memory for adoption; files past it are adopted
    /// by further passes of the same run, at least one file per pass (finding 10).
    var adoptionBudget: Int64 = 64 * 1024 * 1024
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(memosRoot: URL = RecordingFiles.memosRoot(), trashRoot: URL = RecordingFiles.memosTrashRoot(), defaults: UserDefaults) {
        self.memosRoot = memosRoot
        self.trashRoot = trashRoot
        self.defaults = defaults
    }

    /// A recording this device last held with verified bytes: its precedence time
    /// (epoch ms), digest and name. A live file of an id that has since lost its
    /// row is that recording only while it holds that digest.
    struct Verified: Equatable {
        let at: Int64
        let sha256: String
        let displayName: String
        /// A37: `at` is a repaired time.
        var repaired = false
    }

    private var verified: [String: Verified] {
        get {
            let raw = defaults.dictionary(forKey: Self.verifiedKey) as? [String: [String: Any]] ?? [:]
            return raw.compactMapValues { entry in
                guard let at = (entry["at"] as? NSNumber)?.int64Value, let sha = entry["sha256"] as? String,
                      let name = entry["displayName"] as? String else { return nil }
                return Verified(at: at, sha256: sha, displayName: name, repaired: (entry["repaired"] as? Bool) ?? false)
            }
        }
        set {
            defaults.set(newValue.mapValues { ["at": NSNumber(value: $0.at), "sha256": $0.sha256, "displayName": $0.displayName, "repaired": $0.repaired] as [String: Any] },
                         forKey: Self.verifiedKey)
        }
    }

    /// The digest a row holds at a path; a hint to skip re-hashing for the
    /// inventory, offered only while that row still exists with that digest.
    nonisolated struct CachedDigest: Sendable, Equatable {
        let id: String
        let size: Int64
        let modified: Double
        let inode: UInt64
        let sha256: String
    }

    private var digestCache: [String: CachedDigest] {
        get {
            let raw = defaults.dictionary(forKey: Self.digestCacheKey) as? [String: [String: Any]] ?? [:]
            return raw.compactMapValues { entry in
                guard let id = entry["id"] as? String, let size = (entry["size"] as? NSNumber)?.int64Value,
                      let modified = (entry["modified"] as? NSNumber)?.doubleValue,
                      let inode = (entry["inode"] as? NSNumber)?.uint64Value, let sha = entry["sha256"] as? String else { return nil }
                return CachedDigest(id: id, size: size, modified: modified, inode: inode, sha256: sha)
            }
        }
        set {
            defaults.set(newValue.mapValues {
                ["id": $0.id, "size": NSNumber(value: $0.size), "modified": NSNumber(value: $0.modified),
                 "inode": NSNumber(value: $0.inode), "sha256": $0.sha256] as [String: Any]
            }, forKey: Self.digestCacheKey)
        }
    }

    /// A32: the time an identity without a precedence time was first seen here,
    /// stored at once (it survives a failed run) and never changed.
    private func firstSeen(_ id: String) -> Date {
        var seen = (defaults.dictionary(forKey: Self.firstSeenKey) as? [String: NSNumber])?.mapValues(\.int64Value) ?? [:]
        if let known = seen[id] { return Date(millisecondsSince1970: known) }
        let now = Date().epochMilliseconds
        seen[id] = now
        defaults.set(seen.mapValues { NSNumber(value: $0) }, forKey: Self.firstSeenKey)
        return Date(millisecondsSince1970: now)
    }

    func forgetMirroredKeys() {
        defaults.removeObject(forKey: Self.verifiedKey)
        defaults.removeObject(forKey: Self.digestCacheKey)
    }

    private func url(of row: Recording) -> URL? { row.fileURL(memosRoot: memosRoot, trashRoot: trashRoot) }

    private func liveURL(projectId: String, storedName: String) -> URL {
        memosRoot.appendingPathComponent(projectId, isDirectory: true).appendingPathComponent(storedName)
    }

    private func trashURL(projectId: String, storedName: String) -> URL {
        trashRoot.appendingPathComponent(projectId, isDirectory: true).appendingPathComponent(storedName)
    }

    private func aboutToMove(_ files: [URL]) {
        guard !files.isEmpty else { return }
        willMove?(files)
        files.forEach { atMoveBoundary?($0) }
    }

    private func markVerified(_ row: Recording) {
        var ids = verified
        ids[row.id] = Verified(at: row.precedenceTime.epochMilliseconds, sha256: row.sha256, displayName: row.displayName, repaired: row.precedenceRepaired)
        verified = ids
    }

    // MARK: Reading, off the main actor

    /// A file as one read pass saw it.
    nonisolated struct DiskFile: Sendable {
        let url: URL
        let path: String
        let projectId: String
        /// Its name on disk.
        let name: String
        let trashed: Bool
        /// A Trash file named before A36: its deletion time and original name.
        let legacyTrash: (deletedAt: Date, originalName: String)?
        let size: Int64
        let modified: Date
        let inode: UInt64
        let oversized: Bool
        /// Nil only for a file over the cap already named by its id (never hashed).
        let sha256: String?
        /// True when `sha256` came from the digest cache: never a reason to move.
        let fromCache: Bool
        /// The bytes, for a file to adopt, within the pass's memory budget.
        let audio: Data?
        /// The id the file is named by, when it is `<uuid>.<ext>`.
        var storedId: String? { RecordingFiles.storedId(of: url) }
        /// The name it stands for: its pre-A36 name, or its Trash original name.
        var legacyName: String { legacyTrash?.originalName ?? name }
    }

    nonisolated struct ReadRequest: Sendable {
        let memosRoot: URL
        let trashRoot: URL
        let abortingIfMissing: Bool
        let cache: [String: CachedDigest]
        let sources: [(path: String, projectId: String)]
        /// Per path, the digests rows expect there.
        let expected: [String: Set<String>]
        /// Paths whose cached digest must not be used this pass.
        let uncached: Set<String>
        /// Bytes kept in memory for adoption in one pass.
        let audioBudget: Int64
    }

    nonisolated struct ReadPass: Sendable {
        let moves: RecordingFiles.PendingMoves
        let live: [DiskFile]
        let trash: [DiskFile]
        /// Pending sources outside the scanned folders (staging, files from before A36).
        let sources: [DiskFile]
        /// Files recorded for quarantine, detaching or adoption, hashed freshly.
        let recorded: [DiskFile]
        /// Files to adopt whose bytes did not fit this pass.
        let deferred: Int
    }

    private struct Budget {
        var remaining: Int64
        var loadedAny = false
        var deferred = 0
        /// Digests already read this pass: a copy with the same bytes shares them.
        var loaded = Set<String>()
    }

    /// Reads one file. Digests are streamed; a file no row's digest accounts for
    /// is then read whole for adoption within the budget (always at least one per
    /// pass, so any supported file makes progress) and checked against its digest.
    nonisolated private static func inspect(_ url: URL, projectId: String, trashed: Bool, request: ReadRequest,
                                            budget: inout Budget, forReplay: Bool = false) throws -> DiskFile {
        let facts = try RecordingFiles.facts(url)
        let path = RecordingFiles.canonicalPath(url)
        let oversized = facts.size > SyncRecording.maxBytes
        let conforming = RecordingFiles.storedId(of: url) != nil
        var digest: String?
        var cached = false
        var audio: Data?
        // An oversized file named by its id is never hashed; one from before A36 is,
        // for the id it is migrated to.
        if !oversized || !conforming || forReplay {
            if !forReplay, !oversized, !request.uncached.contains(path), let hint = request.cache[path], hint.size == facts.size,
               hint.inode == facts.inode, hint.modified == facts.modified.timeIntervalSince1970 {
                digest = hint.sha256
                cached = true
            } else {
                digest = try RecordingFiles.sha256(of: url)
            }
        }
        if !forReplay, !oversized, let digest, request.expected[path]?.contains(digest) != true, !budget.loaded.contains(digest) {
            if facts.size <= budget.remaining || !budget.loadedAny {
                let bytes = try Data(contentsOf: url)
                // Changed between the two reads: the pass stops rather than guess.
                guard RecordingBackupManifest.sha256Hex(bytes) == digest else { throw RecordingLibraryError.scanFailed }
                budget.remaining -= facts.size
                budget.loadedAny = true
                budget.loaded.insert(digest)
                audio = bytes
            } else {
                budget.deferred += 1
            }
        }
        let legacyTrash = trashed && !conforming ? RecordingFiles.legacyTrashName(url.lastPathComponent) : nil
        return DiskFile(url: url, path: path, projectId: projectId, name: url.lastPathComponent, trashed: trashed, legacyTrash: legacyTrash,
                        size: facts.size, modified: facts.modified, inode: facts.inode, oversized: oversized, sha256: digest,
                        fromCache: cached, audio: audio)
    }

    /// Every supported audio file under a root, by project; a folder that cannot
    /// be listed throws.
    nonisolated private static func listing(_ root: URL) throws -> [(projectId: String, url: URL)] {
        guard try RecordingFiles.exists(root) else { return [] }
        var files: [(String, URL)] = []
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            let projectId = folder.lastPathComponent
            // A symbolic link (folder or file) is never a recording: what it points at may
            // be outside the recording folders, and nothing there is moved (finding 10).
            let kind = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard (try? SyncIdentity.validateProjectId(projectId)) != nil, kind.isDirectory == true, kind.isSymbolicLink != true else { continue }
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            where RecordingFiles.supportedAudioExtensions.contains(file.pathExtension.lowercased()) {
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                files.append((projectId, file))
            }
        }
        return files.sorted { $0.1.path < $1.1.path }
    }

    /// Every read of a run. Any failure throws: a failed read must never look
    /// like a missing recording.
    nonisolated private static func read(_ request: ReadRequest) throws -> ReadPass {
        let moves = try RecordingFiles.readPendingMoves(for: request.memosRoot)
        let hidden = moves.adoptionHidden
        var budget = Budget(remaining: request.audioBudget)
        if request.abortingIfMissing, try !RecordingFiles.exists(request.memosRoot) { throw RecordingLibraryError.scanFailed }
        var live: [DiskFile] = []
        for (projectId, url) in try listing(request.memosRoot) where !hidden.contains(RecordingFiles.canonicalPath(url)) {
            live.append(try inspect(url, projectId: projectId, trashed: false, request: request, budget: &budget))
        }
        var trash: [DiskFile] = []
        for (projectId, url) in try listing(request.trashRoot) where !hidden.contains(RecordingFiles.canonicalPath(url)) {
            trash.append(try inspect(url, projectId: projectId, trashed: true, request: request, budget: &budget))
        }
        let known = Set((live + trash).map(\.path))
        var sources: [DiskFile] = []
        for source in request.sources where !known.contains(source.path) && !hidden.contains(source.path) {
            let url = URL(fileURLWithPath: source.path)
            if try RecordingFiles.exists(url) {
                sources.append(try inspect(url, projectId: source.projectId, trashed: false, request: request, budget: &budget))
            }
        }
        // Recorded moves are verified at replay against digests taken here.
        var recorded: [DiskFile] = []
        let recordedPaths = moves.quarantine.map(\.path) + moves.detach.flatMap { [$0.source, $0.destination] }.filter { !$0.isEmpty }
        for path in recordedPaths {
            let url = URL(fileURLWithPath: path)
            if try RecordingFiles.exists(url) {
                recorded.append(try inspect(url, projectId: url.deletingLastPathComponent().lastPathComponent, trashed: false,
                                            request: request, budget: &budget, forReplay: true))
            }
        }
        return ReadPass(moves: moves, live: live, trash: trash, sources: sources, recorded: recorded, deferred: budget.deferred)
    }

    /// The validated commit boundary: the folders, files and move record are as
    /// the read saw them (same names, sizes, dates and inodes).
    private func stillAsRead(_ pass: ReadPass) throws -> Bool {
        guard try RecordingFiles.readPendingMoves(for: memosRoot) == pass.moves else { return false }
        let hidden = pass.moves.adoptionHidden
        let livePaths = Set(try Self.listing(memosRoot).map { RecordingFiles.canonicalPath($0.url) }).subtracting(hidden)
        let trashPaths = Set(try Self.listing(trashRoot).map { RecordingFiles.canonicalPath($0.url) }).subtracting(hidden)
        guard livePaths == Set(pass.live.map(\.path)), trashPaths == Set(pass.trash.map(\.path)) else { return false }
        for file in pass.live + pass.trash + pass.sources + pass.recorded {
            guard try RecordingFiles.exists(file.url) else { return false }
            let facts = try RecordingFiles.facts(file.url)
            guard facts.size == file.size, facts.modified == file.modified, facts.inode == file.inode else { return false }
        }
        return true
    }

    // MARK: Reconcile

    /// Canonical copy first: a live copy, else the newest Trash time, ties by name (A26).
    private static func rank(_ trashedAt: Date?, _ name: String) -> (Int, Int64, String) {
        (trashedAt == nil ? 0 : 1, -(trashedAt?.epochMilliseconds ?? 0), name)
    }

    private func acquire() async {
        if running {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            running = true
        }
    }

    private func release() {
        if waiting.isEmpty { running = false } else { waiting.removeFirst().resume() }
    }

    private enum Replan: Error {
        case freshDigests(Set<String>)
    }

    private struct Plan {
        var result: Result
        var verified: [(row: Recording, file: (size: Int64, modified: Date, inode: UInt64))]
        var writes: [(row: Recording, to: URL)]
        var adopted: Int
    }

    /// All or nothing: every read happens before any change, and a failure rolls
    /// back this run's row changes, so no deletion, expiry or tombstone that
    /// depends on adoption is applied (A26).
    @discardableResult
    func reconcile(context: ModelContext) async throws -> Result {
        await acquire()
        defer { release() }
        do {
            // Changes the caller already made are saved first (a successful run would
            // save them anyway), so a rollback only undoes this run's own changes.
            if context.hasChanges { try save(context) }
            var uncached = Set<String>()
            var staleReads = 0
            var replans = 0
            var lastResult: Result?
            var previousOpen = -1
            for _ in 0..<64 {
                let rows = try context.fetch(FetchDescriptor<Recording>())
                let byId = Dictionary(rows.map { ($0.id, $0.sha256) }) { first, _ in first }
                var expected: [String: Set<String>] = [:]
                var sources: [(path: String, projectId: String)] = []
                for row in rows {
                    let name = row.storedName
                    var places = [liveURL(projectId: row.projectId, storedName: name), trashURL(projectId: row.projectId, storedName: name)]
                        .map(RecordingFiles.canonicalPath)
                    if let pending = row.pendingFrom {
                        let path = RecordingFiles.canonicalPath(URL(fileURLWithPath: pending))
                        places.append(path)
                        sources.append((path, row.projectId))
                    }
                    for place in places { expected[place, default: []].insert(row.sha256) }
                }
                let request = ReadRequest(
                    memosRoot: memosRoot, trashRoot: trashRoot, abortingIfMissing: !verified.isEmpty,
                    // Only for a row that still holds that digest (finding 3).
                    cache: digestCache.filter { byId[$0.value.id] == $0.value.sha256 },
                    sources: sources, expected: expected, uncached: uncached, audioBudget: adoptionBudget
                )
                let pass: ReadPass
                do {
                    pass = try await Task.detached(priority: .utility) { try Self.read(request) }.value
                } catch let error as RecordingLibraryError {
                    throw error
                } catch {
                    // Anything that could not be read stops the run with nothing changed.
                    throw RecordingLibraryError.scanFailed
                }
                // Something changed while it was read: read again.
                guard try stillAsRead(pass) else {
                    staleReads += 1
                    guard staleReads < 3 else { throw RecordingLibraryError.scanFailed }
                    continue
                }
                var plan: Plan
                do {
                    plan = try commit(pass, context: context)
                } catch Replan.freshDigests(let paths) {
                    // A move would rely on a cached digest: read those files afresh first.
                    context.rollback()
                    replans += 1
                    guard replans < 3 else { throw RecordingLibraryError.scanFailed }
                    uncached.formUnion(paths)
                    continue
                }
                let movesAfterCommit = try RecordingFiles.readPendingMoves(for: memosRoot)
                // Missing files are written and verified off the main actor; after that
                // suspension everything the write depends on is checked again (finding 7).
                for write in plan.writes {
                    let audio = write.row.audio
                    let sha = write.row.sha256
                    let staging = RecordingFiles.stagingRoot(for: memosRoot)
                    let modified = write.row.recordedAt
                    let storedName = write.row.storedName
                    guard let staged = try await Task.detached(priority: .utility, operation: { () throws -> URL? in
                        guard RecordingBackupManifest.sha256Hex(audio) == sha else { return nil }
                        return try RecordingFiles.stageVerified(audio, sha256: sha, storedName: storedName, in: staging, modifiedAt: modified)
                    }).value else { continue }
                    defer { try? FileManager.default.removeItem(at: staged) }
                    guard write.row.modelContext != nil, !write.row.isDeleted, write.row.sha256 == sha,
                          url(of: write.row).map(RecordingFiles.canonicalPath) == RecordingFiles.canonicalPath(write.to),
                          try RecordingFiles.readPendingMoves(for: memosRoot) == movesAfterCommit,
                          try !DeletionStore.all(in: context).contains(where: { $0.covers(projectId: write.row.projectId, recordingId: write.row.id, sha256: sha, at: write.row.precedenceTime, repaired: write.row.precedenceRepaired) }),
                          try !RecordingFiles.exists(write.to) else {
                        // Its place holds other bytes: reported; the row's audio stays in its row.
                        if try RecordingFiles.exists(write.to) { plan.result.needsAttention.append(write.to) }
                        continue
                    }
                    do {
                        try RecordingFiles.safeMove(staged, to: write.to, within: [memosRoot, trashRoot])
                    } catch CocoaError.fileWriteFileExists {
                        plan.result.needsAttention.append(write.to)
                        continue
                    }
                    plan.verified.append((write.row, try RecordingFiles.facts(write.to)))
                }
                if context.hasChanges { try save(context) }
                finish(plan)
                lastRunSucceeded = true
                lastResult = plan.result
                // Files whose bytes did not fit this pass are adopted by the next one, and
                // moves recorded on cached digests are finished by one reading them afresh.
                let open = try RecordingFiles.readPendingMoves(for: memosRoot)
                let openCount = open.quarantine.count + open.detach.filter { !$0.source.isEmpty }.count
                let moreToAdopt = pass.deferred > 0 && plan.adopted > 0
                // A pass that left files waiting and took in none would only repeat itself.
                adoptionStalled = pass.deferred > 0 && plan.adopted == 0
                let moreToMove = openCount > 0 && openCount != previousOpen
                previousOpen = openCount
                guard moreToAdopt || moreToMove else {
                    pendingAdoption = plan.result.pendingAdoption
                    return plan.result
                }
                uncached = []
            }
            // Still more to take in: reported, and taken by the next run (finding 10).
            var result = lastResult ?? Result()
            result.pendingAdoption = max(result.pendingAdoption, 1)
            pendingAdoption = result.pendingAdoption
            return result
        } catch {
            context.rollback()
            lastRunSucceeded = false
            throw error
        }
    }

    private func finish(_ plan: Plan) {
        var ids = verified
        var cache: [String: CachedDigest] = [:]
        for (row, facts) in plan.verified {
            guard let target = url(of: row) else { continue }
            cache[RecordingFiles.canonicalPath(target)] = CachedDigest(id: row.id, size: facts.size, modified: facts.modified.timeIntervalSince1970,
                                                                       inode: facts.inode, sha256: row.sha256)
            ids[row.id] = Verified(at: row.precedenceTime.epochMilliseconds, sha256: row.sha256, displayName: row.displayName, repaired: row.precedenceRepaired)
        }
        // Ids verified before stay remembered: a file of one whose row is removed on
        // another device later is still recognised by its bytes.
        verified = ids
        digestCache = cache
        oversizedCount = plan.result.oversizedCount
        oversizedFiles = plan.result.oversizedFiles
        needsAttention = plan.result.needsAttention
    }

    /// A file no row holds, as an identity: the id it gets (its own when named by
    /// an id no row or tombstone knows, else the one every device derives from its
    /// name and bytes, A21), its name, its Trash time and its file time.
    private struct Candidate {
        let id: String
        let displayName: String
        let trashedAt: Date?
        let time: Date
        let file: DiskFile
    }

    private func commit(_ pass: ReadPass, context: ModelContext) throws -> Plan {
        // An in-memory library is empty at every launch; treating its missing rows
        // as removals would trash every memo, so it only ever adds.
        let allowRemovals = !context.container.configurations.contains { $0.isStoredInMemoryOnly }
        let known = verified
        // Tombstones are read (and validated) before anything else; a failure stops the run (A33).
        let deletions = try DeletionStore.all(in: context)
        let allRows = try context.fetch(FetchDescriptor<Recording>()).sorted { $0.id < $1.id }
        let registry = try OversizedRecordings.read(for: memosRoot)

        // 1. Precedence times are fixed before anything is compared (A32): a row
        //    without one gets the time it was first seen here, stored at once, and
        //    is marked as repaired (A37).
        for row in allRows where (row.uploadedAt?.epochMilliseconds ?? 0) <= 0 {
            row.uploadedAt = firstSeen(row.id)
            row.precedenceRepaired = true
        }
        // A Trash time that is missing is stamped too, so the recording gets its full
        // retention rather than expiring at once.
        for row in allRows where (row.trashedAt?.epochMilliseconds ?? 1) <= 0 {
            row.trashedAt = firstSeen("trashed:\(row.id)")
        }

        var byPath: [String: DiskFile] = [:]
        for file in pass.live + pass.trash + pass.sources { byPath[file.path] = file }

        // 2. Where each row's audio is: its own place, the other folder, or its
        //    pending source, and only where the bytes are the row's.
        func located(_ row: Recording) -> DiskFile? {
            let name = row.storedName
            var places = [url(of: row), row.trashedAt == nil ? trashURL(projectId: row.projectId, storedName: name) : liveURL(projectId: row.projectId, storedName: name)]
                .compactMap { $0 }.map(RecordingFiles.canonicalPath)
            if let pending = row.pendingFrom { places.append(RecordingFiles.canonicalPath(URL(fileURLWithPath: pending))) }
            return places.lazy.compactMap { byPath[$0] }.first { $0.sha256 == row.sha256 }
        }
        var rows: [Recording] = []
        var extras: [Recording] = []
        for (_, same) in Dictionary(grouping: allRows, by: \.id).sorted(by: { $0.key < $1.key }) {
            // The same id twice is one recording; its canonical copy is kept (A26).
            let ordered = same.sorted { Self.rank($0.trashedAt, $0.displayName) < Self.rank($1.trashedAt, $1.displayName) }
            // Its time is settled across every copy first (A37: a recorded time beats a
            // repair; otherwise the smaller wins), then the survivor takes it.
            let recorded = same.filter { !$0.precedenceRepaired }
            let winner = (recorded.isEmpty ? same : recorded).min { ($0.precedenceTime, $0.id) < ($1.precedenceTime, $1.id) }!
            let survivor = ordered[0]
            if survivor.precedenceTime != winner.precedenceTime { survivor.uploadedAt = winner.precedenceTime }
            if survivor.precedenceRepaired != winner.precedenceRepaired { survivor.precedenceRepaired = winner.precedenceRepaired }
            // A rename made here and not yet written survives on whichever copy kept it.
            if let renamed = ordered.first(where: \.displayNameChanged) {
                if survivor.displayName != renamed.displayName { survivor.displayName = renamed.displayName }
                if !survivor.displayNameChanged { survivor.displayNameChanged = true }
            }
            rows.append(survivor)
            extras += ordered.dropFirst()
        }
        var location: [ObjectIdentifier: DiskFile] = [:]
        var claimed = Set<String>()
        for row in rows.sorted(by: { ($0.precedenceTime, $0.id) < ($1.precedenceTime, $1.id) }) {
            if let file = located(row), !claimed.contains(file.path) {
                location[ObjectIdentifier(row)] = file
                claimed.insert(file.path)
            }
        }
        var toQuarantine: [(url: URL, sha256: String, recordingId: String)] = []
        for extra in extras { context.delete(extra) }
        let rowsById = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
        let journal = pass.moves
        let detachedByDestination = Dictionary(journal.detach.map { ($0.destination, $0) }) { first, _ in first }
        let adoptByPath = Dictionary(journal.adopt.map { ($0.path, $0) }) { first, _ in first }
        var retiredDetaches = Set<String>()

        // 3. Files no row holds.
        var audioByDigest: [String: Data] = [:]
        for file in pass.live + pass.trash + pass.sources { if let sha = file.sha256, let audio = file.audio { audioByDigest[sha] = audio } }
        var result = Result()
        var detaches: [RecordingFiles.PendingMoves.Detach] = []
        var candidates: [Candidate] = []
        var oversizedMigrations: [(file: DiskFile, id: String, entry: OversizedRecordings.Entry)] = []
        let tombstonedIds = Set(deletions.compactMap(\.recordingId))
        for file in pass.live + pass.trash where !claimed.contains(file.path) {
            if file.oversized {
                result.oversizedCount += 1
                result.oversizedFiles.append(file.url)
                // A file over the cap from before A36 moves to its id, kept in the local record.
                if file.storedId == nil, let sha = file.sha256, (try? SyncIdentity.validateFileName(file.legacyName)) != nil {
                    let id = RecordingBackupManifest.legacyRecordingId(projectId: file.projectId, fileName: file.legacyName, sha256: sha)
                    if registry[id] == nil {
                        oversizedMigrations.append((file, id, .init(projectId: file.projectId, fileName: file.legacyName, finishedAt: file.modified.epochMilliseconds,
                                                                    source: file.path, completed: false, sha256: sha,
                                                                    trashedAt: file.trashed ? Self.positive((file.legacyTrash?.deletedAt ?? file.modified).epochMilliseconds) ?? firstSeen("trashed:\(id)").epochMilliseconds : nil,
                                                                    bytes: file.size)))
                    }
                }
                continue
            }
            // A recording removed on another device, held here in the Trash: it keeps
            // its id while its bytes are its own, and a later tombstone still applies (finding 7).
            if file.trashed, let entry = detachedByDestination[file.path] {
                guard let sha = file.sha256 else { continue }
                if entry.sha256 == sha {
                    if deletions.contains(where: { $0.covers(projectId: file.projectId, recordingId: entry.recordingId, sha256: sha, at: Date(millisecondsSince1970: entry.at), repaired: entry.repaired ?? false) }) {
                        toQuarantine.append((file.url, sha, entry.recordingId))
                    }
                    continue
                }
                // Other bytes there now, by a fresh digest: that record is retired and
                // these are a recording of their own (finding 8).
                retiredDetaches.insert(entry.destination)
                let id = RecordingBackupManifest.legacyRecordingId(projectId: file.projectId, fileName: entry.displayName, sha256: sha)
                candidates.append(Candidate(id: id, displayName: entry.displayName, trashedAt: file.modified, time: file.modified, file: file))
                continue
            }
            // An empty file is never a recording (as recording and import refuse it).
            guard let sha = file.sha256, file.size > 0 else { continue }
            if let id = file.storedId {
                // Copies written for a draft, taken in under the identity recorded for them.
                if let entry = adoptByPath[file.path], entry.sha256 == sha, rowsById[entry.recordingId] == nil {
                    candidates.append(Candidate(id: entry.recordingId, displayName: entry.displayName, trashedAt: nil, time: file.modified, file: file))
                    continue
                }
                if !file.trashed, allowRemovals, let mirror = known[id], mirror.sha256 == sha {
                    if rowsById[id] != nil {
                        // A second copy of a recording held elsewhere.
                        toQuarantine.append((file.url, sha, id))
                    } else if deletions.contains(where: { $0.covers(projectId: file.projectId, recordingId: id, sha256: sha, at: Date(millisecondsSince1970: mirror.at), repaired: mirror.repaired) }) {
                        // Removed on another device, and a deletion of it wins here by time (A28).
                        toQuarantine.append((file.url, sha, id))
                    } else {
                        // Removed on another device: to the recordings Trash, keeping its id.
                        let destination = trashURL(projectId: file.projectId, storedName: file.name)
                        if try RecordingFiles.exists(destination) {
                            toQuarantine.append((file.url, sha, id))
                        } else {
                            detaches.append(.init(recordingId: id, source: file.path, destination: RecordingFiles.canonicalPath(destination), sha256: sha,
                                                  displayName: mirror.displayName, at: mirror.at, detachedAt: Date().epochMilliseconds,
                                                  repaired: mirror.repaired))
                        }
                    }
                    continue
                }
                // An id-named file nothing here knows: its own id, unless a row, a
                // tombstone or a verified recording already has that id with other bytes.
                if rowsById[id] == nil, !tombstonedIds.contains(id), known[id] == nil {
                    candidates.append(Candidate(id: id, displayName: "Recording.\(RecordingFiles.storedExtension(of: file.name))",
                                                trashedAt: file.trashed ? file.modified : nil, time: file.modified, file: file))
                    continue
                }
            }
            // A file from before A36 (or bytes that are not the recording its name
            // says): the id every device derives for its name and bytes (A21).
            guard (try? SyncIdentity.validateFileName(file.legacyName)) != nil else { continue }
            let id = RecordingBackupManifest.legacyRecordingId(projectId: file.projectId, fileName: file.legacyName, sha256: sha)
            candidates.append(Candidate(id: id, displayName: file.legacyName,
                                        trashedAt: file.trashed ? (file.legacyTrash?.deletedAt ?? file.modified) : nil,
                                        time: file.modified, file: file))
        }

        // 4. One identity is one recording (A26). All its copies, and its row if
        //    there is one, are gathered before anything is decided, whether or not
        //    their bytes fit this pass (finding 4). Its precedence time is the
        //    row's, or the earliest time among the copies (first-seen for one with
        //    none, A32); the deletion is resolved once against it.
        var newRows: [Recording] = []
        var rowMoves: [(row: Recording, from: DiskFile)] = []
        var deferred = 0
        for (id, found) in Dictionary(grouping: candidates, by: \.id).sorted(by: { $0.key < $1.key }) {
            let group = found
            // Different bytes under one id (a file from before A36 whose id's name holds
            // other bytes): neither takes the id; both are left alone and reported, and
            // a row of that id stays as it is (nothing is deleted, moved or merged).
            if Set(group.compactMap(\.file.sha256)).count > 1 {
                result.needsAttention += group.map(\.file.url)
                continue
            }
            let ordered = group.sorted { Self.rank($0.trashedAt, $0.file.name) < Self.rank($1.trashedAt, $1.file.name) }
            let best = ordered[0]
            let existing = rowsById[id]
            let repaired = existing == nil && group.contains { $0.time.epochMilliseconds <= 0 }
            let precedence: Date = existing?.precedenceTime
                ?? group.map { $0.time.epochMilliseconds > 0 ? $0.time : firstSeen(id) }.min()!
            let projectId = existing?.projectId ?? best.file.projectId
            if let tombstone = deletions.first(where: { $0.covers(projectId: projectId, recordingId: id, sha256: best.file.sha256 ?? "", at: precedence, repaired: existing?.precedenceRepaired ?? repaired) }) {
                if tombstone.isSongTombstone {
                    try DeletionStore.upsert(SyncDeletion(projectId: projectId, recordingId: id, fileName: existing?.displayName ?? best.displayName,
                                                          deletedAt: tombstone.deletedAt), in: context)
                }
                for copy in group { toQuarantine.append((copy.file.url, copy.file.sha256 ?? "", id)) }
                if let existing {
                    if let file = location[ObjectIdentifier(existing)] { toQuarantine.append((file.url, existing.sha256, id)) }
                    context.delete(existing)
                }
                continue
            }
            if let existing {
                if let own = location[ObjectIdentifier(existing)] {
                    // A live copy from before A36 of a recording held in the Trash: live
                    // wins whatever the order the copies arrived in (A26), and the Trash
                    // file goes with the other copies.
                    if existing.trashedAt != nil, best.trashedAt == nil, best.file.storedId == nil,
                       try !RecordingFiles.exists(liveURL(projectId: existing.projectId, storedName: existing.storedName)) {
                        existing.trashedAt = nil
                        existing.pendingFrom = best.file.url.path
                        location[ObjectIdentifier(existing)] = best.file
                        rowMoves.append((existing, best.file))
                        toQuarantine.append((own.url, existing.sha256, id))
                        for copy in ordered.dropFirst() { toQuarantine.append((copy.file.url, copy.file.sha256 ?? "", id)) }
                        continue
                    }
                    // Its own file is in place: these are copies.
                    for copy in group { toQuarantine.append((copy.file.url, copy.file.sha256 ?? "", id)) }
                    continue
                }
                // Its file is missing: the canonical copy becomes it (a live copy wins, A26),
                // unless its id's place holds other bytes: then nothing moves, the row
                // stays as it is, and the copy is reported.
                let place: URL? = best.trashedAt == nil ? liveURL(projectId: existing.projectId, storedName: existing.storedName) : url(of: existing)
                if let place, RecordingFiles.canonicalPath(place) != best.file.path, try RecordingFiles.exists(place) {
                    result.needsAttention.append(best.file.url)
                    continue
                }
                if best.trashedAt == nil { existing.trashedAt = nil }
                existing.pendingFrom = best.file.url.path
                location[ObjectIdentifier(existing)] = best.file
                rowMoves.append((existing, best.file))
                for copy in ordered.dropFirst() { toQuarantine.append((copy.file.url, copy.file.sha256 ?? "", id)) }
                continue
            }
            // A new recording needs the canonical copy's bytes; without them this pass
            // decides nothing for the identity and a later pass takes it whole.
            // Any copy read this pass with the same digest holds the same bytes (finding 5).
            guard let sha = best.file.sha256, let audio = best.file.audio ?? audioByDigest[sha] else {
                deferred += 1
                continue
            }
            let row = Recording(id: id, projectId: projectId, displayName: best.displayName, audio: audio, recordedAt: best.time,
                                uploadedAt: precedence, origin: .migrated, sha256: sha)
            row.precedenceRepaired = repaired
            // A Trash time that is missing is stamped first-seen before the row exists,
            // so no expiry ever sees it as 1970.
            row.trashedAt = best.trashedAt.map { $0.epochMilliseconds > 0 ? Date(millisecondsSince1970: $0.epochMilliseconds) : firstSeen("trashed:\(id)") }
            // Its file moves to its id; until then the row records where it is.
            if let target = url(of: row), RecordingFiles.canonicalPath(target) != best.file.path {
                if try RecordingFiles.exists(target) {
                    // Its id's name holds other bytes: left where it is, and reported.
                    result.needsAttention.append(best.file.url)
                    continue
                }
                row.pendingFrom = best.file.url.path
                rowMoves.append((row, best.file))
            }
            context.insert(row)
            newRows.append(row)
            location[ObjectIdentifier(row)] = best.file
            for copy in ordered.dropFirst() { toQuarantine.append((copy.file.url, copy.file.sha256 ?? "", id)) }
        }
        result.pendingAdoption = deferred + pass.deferred

        // 5. Rows whose deletion wins by time go (a song deletion leaves each its own
        //    tombstone in this save); their audio goes to quarantine.
        var kept: [Recording] = []
        for row in rows where !row.isDeleted {
            guard let tombstone = deletions.first(where: { $0.covers(projectId: row.projectId, recordingId: row.id, sha256: row.sha256, at: row.precedenceTime, repaired: row.precedenceRepaired) }) else {
                kept.append(row)
                continue
            }
            if tombstone.isSongTombstone {
                try DeletionStore.upsert(SyncDeletion(projectId: row.projectId, recordingId: row.id, fileName: row.displayName, deletedAt: tombstone.deletedAt), in: context)
            }
            if let file = location[ObjectIdentifier(row)] { toQuarantine.append((file.url, row.sha256, row.id)) }
            rowMoves.removeAll { $0.row === row }
            context.delete(row)
        }
        kept += newRows

        // 6. The plan: a row's file found elsewhere (the other folder, its pending
        //    source) moves to its place; a missing one is written from the row.
        var writes: [(row: Recording, to: URL)] = []
        var verifiedNow: [(row: Recording, file: (size: Int64, modified: Date, inode: UInt64))] = []
        for row in kept {
            guard let target = url(of: row) else { continue }
            if let source = location[ObjectIdentifier(row)] {
                if source.path == RecordingFiles.canonicalPath(target) {
                    if row.pendingFrom != nil { row.pendingFrom = nil }
                    verifiedNow.append((row, (source.size, source.modified, source.inode)))
                } else if !rowMoves.contains(where: { $0.row === row }) {
                    row.pendingFrom = source.url.path
                    rowMoves.append((row, source))
                }
            } else {
                if row.pendingFrom != nil { row.pendingFrom = nil }
                writes.append((row, target))
            }
        }

        // A move relies on ownership, so its source's digest must be fresh, not cached.
        let cachedSources = Set(rowMoves.filter(\.from.fromCache).map(\.from.path))
        if !cachedSources.isEmpty { throw Replan.freshDigests(cachedSources) }

        // 7. Commit the rows with the moves recorded, then move files.
        var fresh: [String: DiskFile] = [:]
        for file in pass.live + pass.trash + pass.sources + pass.recorded where !file.fromCache { fresh[file.path] = file }
        try saveRecordingMoves(quarantine: toQuarantine, detach: detaches, retire: retiredDetaches, in: context, fresh: fresh) { try save(context) }
        aboutToMove(rowMoves.map(\.from.url))
        for move in rowMoves {
            guard let target = url(of: move.row) else { continue }
            // Something took its place meanwhile: the row keeps its pending source for the next run.
            guard try !RecordingFiles.exists(target) else {
                result.needsAttention.append(move.from.url)
                continue
            }
            do {
                try RecordingFiles.safeMove(move.from.url, to: target, within: [memosRoot, trashRoot])
            } catch CocoaError.fileWriteFileExists {
                // It appeared after the check: nothing is replaced; the move stays pending.
                result.needsAttention.append(move.from.url)
                continue
            }
            move.row.pendingFrom = nil
            verifiedNow.append((move.row, try RecordingFiles.facts(target)))
        }
        if context.hasChanges { try save(context) }
        // Files over the cap from before A36: journalled, then moved to their ids.
        for migration in oversizedMigrations {
            try OversizedRecordings.record(id: migration.id, entry: migration.entry, for: memosRoot)
            if (try? finishOversized(id: migration.id, entry: migration.entry)) == nil { result.needsAttention.append(migration.file.url) }
        }
        // Interrupted oversized moves (publication, migration, Trash, restore) are
        // finished from their journal before anything is pruned; one that cannot be
        // finished yet stays recorded.
        for (id, entry) in try OversizedRecordings.read(for: memosRoot) where entry.completed == false {
            guard (try? finishOversized(id: id, entry: entry)) == nil else { continue }
            // Blocked (other bytes at its place, or its source changed): both files are
            // kept and reported; neither is listed or expired as this recording.
            let place = oversizedURL(id: id, entry: entry)
            for file in [place] + (entry.source.map { [URL(fileURLWithPath: $0)] } ?? []) where (try? RecordingFiles.exists(file)) == true {
                if !result.needsAttention.contains(file) { result.needsAttention.append(file) }
            }
        }
        try OversizedRecordings.prune(for: memosRoot) { id, entry in
            // Entries whose file is confirmed gone (deleted, or restored elsewhere) end.
            (try? RecordingFiles.exists(oversizedURL(id: id, entry: entry))) != false || entry.completed == false
        }
        return Plan(result: result, verified: verifiedNow, writes: writes, adopted: newRows.count)
    }

    /// Moves to quarantine and detached Trash moves are recorded, each with the
    /// digest it was decided on, before the save that decides them; made after it,
    /// and finished at the next run if interrupted (A28).
    func saveRecordingMoves(quarantine files: [(url: URL, sha256: String, recordingId: String)], detach: [RecordingFiles.PendingMoves.Detach] = [],
                            retire: Set<String> = [], in context: ModelContext, fresh: [String: DiskFile]? = nil,
                            save: () throws -> Void) throws {
        let before = try RecordingFiles.readPendingMoves(for: memosRoot)
        var moves = before
        var paths = Set(before.quarantine.map(\.path))
        // Only a recording file inside the memo or Trash folders is ever recorded (finding 10).
        for file in files where RecordingFiles.isRecordingFile(file.url, in: [memosRoot, trashRoot]) && paths.insert(RecordingFiles.canonicalPath(file.url)).inserted {
            moves.quarantine.append(.init(path: RecordingFiles.canonicalPath(file.url), sha256: file.sha256, recordingId: file.recordingId))
        }
        moves.detach.removeAll { retire.contains($0.destination) }
        moves.detach += detach
        if moves != before { try RecordingFiles.writePendingMoves(moves, for: memosRoot) }
        do {
            try save()
        } catch {
            if moves != before { try? RecordingFiles.writePendingMoves(before, for: memosRoot) }
            throw error
        }
        // Outside a reconcile there are no fresh digests: the next run finishes them.
        if let fresh { finishPendingMoves(in: context, fresh: fresh) }
    }

    /// Finishes recorded moves using digests the read pass took off the main
    /// actor, each still valid only if the file's size, date and inode are as read.
    /// A file to quarantine goes only while it holds the digest recorded for it, and
    /// not while a row still names it with those bytes (its save never landed). A
    /// detached file goes to its Trash place only while it holds the removed
    /// recording's digest; the record keeps that place, its id and its time. Other
    /// bytes drop the record (they are adopted on their own). Draft copies taken in
    /// end their records. Anything not freshly read stays recorded.
    func finishPendingMoves(in context: ModelContext, fresh: [String: DiskFile]) {
        guard var moves = try? RecordingFiles.readPendingMoves(for: memosRoot), !moves.isEmpty,
              let rows = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        let referenced = Dictionary(rows.compactMap { row in url(of: row).map { (RecordingFiles.canonicalPath($0), row.sha256) } }) { first, _ in first }
        func digestNow(_ path: String) throws -> String? {
            guard let seen = fresh[path], let sha = seen.sha256 else { return nil }
            let facts = try RecordingFiles.facts(URL(fileURLWithPath: path))
            return facts.size == seen.size && facts.modified == seen.modified && facts.inode == seen.inode ? sha : nil
        }
        aboutToMove((moves.quarantine.map(\.path) + moves.detach.map(\.source).filter { !$0.isEmpty }).map { URL(fileURLWithPath: $0) })
        var remaining: [RecordingFiles.PendingMoves.Quarantine] = []
        for item in moves.quarantine {
            let file = URL(fileURLWithPath: item.path)
            do {
                guard try RecordingFiles.exists(file) else { continue }
                guard let digest = try digestNow(item.path) else {
                    remaining.append(item)
                    continue
                }
                if digest != item.sha256 { continue }
                if referenced[item.path] == digest { continue }
                try RecordingFiles.quarantine(file, recordingId: item.recordingId, memosRoot: memosRoot, trashRoot: trashRoot)
            } catch {
                remaining.append(item)
            }
        }
        moves.quarantine = remaining
        moves.detach = moves.detach.compactMap { entry in
            var entry = entry
            do {
                if !entry.source.isEmpty {
                    let source = URL(fileURLWithPath: entry.source)
                    if try RecordingFiles.exists(source) {
                        guard let digest = try digestNow(entry.source) else { return entry }
                        // Other bytes at the source: not the removed recording's.
                        guard digest == entry.sha256 else { return nil }
                        let destination = URL(fileURLWithPath: entry.destination)
                        guard RecordingFiles.isRecordingFile(source, in: [memosRoot]) else { return nil }
                        guard try !RecordingFiles.exists(destination) else { return entry }
                        try RecordingFiles.safeMove(source, to: destination, within: [trashRoot])
                    }
                    entry.source = ""
                }
                // Restored or deleted from the Trash since: nothing left to keep out.
                if try !RecordingFiles.exists(URL(fileURLWithPath: entry.destination)) { return nil }
            } catch {
                return entry
            }
            return entry
        }
        let ids = Set(rows.map(\.id))
        moves.adopt = moves.adopt.filter { entry in
            !ids.contains(entry.recordingId) && (try? RecordingFiles.exists(URL(fileURLWithPath: entry.path))) != false
        }
        try? RecordingFiles.writePendingMoves(moves, for: memosRoot)
    }

    // MARK: The check every change outside a run needs

    /// The complete check (A33): the last run succeeded, and the tombstones (read
    /// and validated) and the move record read now.
    func requireChecked(_ context: ModelContext) throws {
        guard lastRunSucceeded else { throw RecordingLibraryError.notChecked }
        do {
            _ = try DeletionStore.all(in: context)
            _ = try RecordingFiles.readPendingMoves(for: memosRoot)
        } catch {
            throw RecordingLibraryError.notChecked
        }
    }

    /// The row a file belongs to: the one it is named by, with its bytes verified now.
    private func verifiedRow(at url: URL, trashed: Bool, in context: ModelContext) throws -> Recording? {
        let path = RecordingFiles.canonicalPath(url)
        guard let row = try context.fetch(FetchDescriptor<Recording>()).first(where: {
            ($0.trashedAt != nil) == trashed && self.url(of: $0).map(RecordingFiles.canonicalPath) == path
        }) else { return nil }
        guard try RecordingFiles.sha256(of: url) == row.sha256 else { throw RecordingLibraryError.notVerified }
        return row
    }

    private func detachEntry(at url: URL) throws -> RecordingFiles.PendingMoves.Detach? {
        let path = RecordingFiles.canonicalPath(url)
        return try RecordingFiles.readPendingMoves(for: memosRoot).detach.first { $0.destination == path && $0.source.isEmpty }
    }

    // MARK: What the lists show

    /// Live recordings, newest first: rows, files over the cap, and files left
    /// for attention. Nothing hidden by a recorded move is listed (A28).
    func liveRecordings(projectId: String? = nil, in context: ModelContext) throws -> [RecordingListItem] {
        let hidden = try RecordingFiles.readPendingMoves(for: memosRoot).listingHidden
        var items: [RecordingListItem] = []
        var listed = Set<String>()
        for row in try context.fetch(FetchDescriptor<Recording>()) where row.trashedAt == nil && (projectId == nil || row.projectId == projectId) {
            guard let file = url(of: row), try RecordingFiles.exists(file), !hidden.contains(RecordingFiles.canonicalPath(file)) else { continue }
            listed.insert(RecordingFiles.canonicalPath(file))
            items.append(.init(url: file, projectId: row.projectId, displayName: row.displayName, date: row.recordedAt))
        }
        for (id, entry) in try OversizedRecordings.read(for: memosRoot) where entry.trashedAt == nil && (projectId == nil || entry.projectId == projectId) {
            let file = oversizedURL(id: id, entry: entry)
            guard try oversizedHolds(entry, at: file), listed.insert(RecordingFiles.canonicalPath(file)).inserted else { continue }
            items.append(.init(url: file, projectId: entry.projectId, displayName: entry.fileName, date: Date(millisecondsSince1970: entry.finishedAt)))
        }
        let blocked = try blockedPaths()
        for (folderProject, file) in try Self.listing(memosRoot) where projectId == nil || folderProject == projectId {
            let path = RecordingFiles.canonicalPath(file)
            guard !listed.contains(path), !hidden.contains(path), !blocked.contains(path) else { continue }
            items.append(.init(url: file, projectId: folderProject, displayName: file.lastPathComponent, date: try RecordingFiles.facts(file).modified))
        }
        return items.sorted { $0.date == $1.date ? $0.url.path < $1.url.path : $0.date > $1.date }
    }

    /// The recordings Trash, newest deletion first: rows, recordings removed on
    /// another device, files over the cap, and files left for attention.
    func trashedRecordings(in context: ModelContext) throws -> [TrashedVoiceMemo] {
        let moves = try RecordingFiles.readPendingMoves(for: memosRoot)
        let hidden = moves.listingHidden
        var items: [TrashedVoiceMemo] = []
        var listed = Set<String>()
        for row in try context.fetch(FetchDescriptor<Recording>()) where row.trashedAt != nil {
            guard let file = url(of: row), try RecordingFiles.exists(file), !hidden.contains(RecordingFiles.canonicalPath(file)) else { continue }
            listed.insert(RecordingFiles.canonicalPath(file))
            items.append(TrashedVoiceMemo(url: file, projectId: row.projectId, originalName: row.displayName, deletedAt: row.trashedAt!, recordingId: row.id))
        }
        for entry in moves.detach where entry.source.isEmpty {
            let file = URL(fileURLWithPath: entry.destination)
            guard try RecordingFiles.exists(file), listed.insert(entry.destination).inserted else { continue }
            items.append(TrashedVoiceMemo(url: file, projectId: file.deletingLastPathComponent().lastPathComponent, originalName: entry.displayName,
                                          deletedAt: Date(millisecondsSince1970: entry.detachedAt), recordingId: entry.recordingId))
        }
        for (id, entry) in try OversizedRecordings.read(for: memosRoot) where entry.trashedAt != nil {
            let file = oversizedURL(id: id, entry: entry)
            guard try oversizedHolds(entry, at: file), listed.insert(RecordingFiles.canonicalPath(file)).inserted else { continue }
            items.append(TrashedVoiceMemo(url: file, projectId: entry.projectId, originalName: entry.fileName,
                                          deletedAt: Date(millisecondsSince1970: entry.trashedAt!), recordingId: id))
        }
        let blocked = try blockedPaths()
        for (projectId, file) in try Self.listing(trashRoot) {
            let path = RecordingFiles.canonicalPath(file)
            guard !listed.contains(path), !hidden.contains(path), !blocked.contains(path) else { continue }
            let legacy = RecordingFiles.legacyTrashName(file.lastPathComponent)
            let modified = try RecordingFiles.facts(file).modified
            // A file not taken in yet never counts as expired by a missing time.
            let deletedAt = [legacy?.deletedAt, modified].compactMap { $0 }.first { $0.epochMilliseconds > 0 } ?? Date()
            items.append(TrashedVoiceMemo(url: file, projectId: projectId, originalName: legacy?.originalName ?? file.lastPathComponent,
                                          deletedAt: deletedAt))
        }
        return items.sorted { $0.deletedAt > $1.deletedAt }
    }

    // MARK: Deletion checks

    /// Permanent deletion of a Trash entry: after the complete check, the id of the
    /// recording its current bytes are: its row's when they match, a recording
    /// removed elsewhere by its own recorded id while it holds its bytes, a file
    /// over the cap by its recorded id, else the id derived for them. A row whose
    /// file holds other bytes fails before anything changes.
    func identityForDeletion(of trashed: TrashedVoiceMemo, in context: ModelContext) throws -> (id: String, row: Recording?) {
        try requireChecked(context)
        if let id = trashed.recordingId, let entry = try OversizedRecordings.read(for: memosRoot)[id],
           RecordingFiles.canonicalPath(oversizedURL(id: id, entry: entry)) == RecordingFiles.canonicalPath(trashed.url) {
            // Only the recording's own bytes, by digest and length (finding 2).
            guard try oversizedHolds(entry, at: trashed.url, digest: true) else { throw RecordingLibraryError.notVerified }
            return (id, nil)
        }
        let digest = try RecordingFiles.sha256(of: trashed.url)
        if let row = try verifiedRow(at: trashed.url, trashed: true, in: context) { return (row.id, row) }
        if let entry = try detachEntry(at: trashed.url) {
            guard entry.sha256 == digest else { throw RecordingLibraryError.notVerified }
            return (entry.recordingId, nil)
        }
        if let id = RecordingFiles.storedId(of: trashed.url),
           try context.fetch(FetchDescriptor<Recording>()).contains(where: { $0.id == id }) {
            throw RecordingLibraryError.notVerified
        }
        return (RecordingBackupManifest.legacyRecordingId(projectId: trashed.projectId, fileName: trashed.originalName, sha256: digest), nil)
    }

    /// Permanent deletion of a whole song: after the complete check, every file in
    /// its memo and Trash folders must be a row's verified bytes, a file over the
    /// cap, or a recording removed elsewhere still holding its recorded bytes;
    /// anything else fails before anything changes (finding 1).
    /// What an export leaves out, by kind (finding 7): recordings in the recordings
    /// Trash, files the library has not taken in (or reported), recordings over the
    /// cap, and how many quarantined files there are.
    func exportOmissions(in context: ModelContext) throws -> (trashed: [String], notTakenIn: [String], oversized: [String], quarantined: Int) {
        let rows = try context.fetch(FetchDescriptor<Recording>())
        var held = Set(rows.compactMap { url(of: $0).map(RecordingFiles.canonicalPath) })
        let registry = try OversizedRecordings.read(for: memosRoot)
        for (id, entry) in registry { held.insert(RecordingFiles.canonicalPath(oversizedURL(id: id, entry: entry))) }
        for entry in try RecordingFiles.readPendingMoves(for: memosRoot).detach { held.insert(entry.destination) }
        var notTakenIn = needsAttention.map(\.lastPathComponent)
        for (_, file) in try Self.listing(memosRoot) + Self.listing(trashRoot) where !held.contains(RecordingFiles.canonicalPath(file)) {
            if !notTakenIn.contains(file.lastPathComponent) { notTakenIn.append(file.lastPathComponent) }
        }
        let quarantineRoot = RecordingFiles.quarantineRoot(for: memosRoot)
        let quarantined = (FileManager.default.enumerator(at: quarantineRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { RecordingFiles.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }.count
        return (try trashedRecordings(in: context).map(\.originalName), notTakenIn, registry.values.map(\.fileName).sorted(), quarantined)
    }

    /// Files a blocked move left (reported, and the places and sources of unfinished
    /// oversized moves): never listed, played or expired until resolved.
    private func blockedPaths() throws -> Set<String> {
        var paths = Set(needsAttention.map(RecordingFiles.canonicalPath))
        for (id, entry) in try OversizedRecordings.read(for: memosRoot) where entry.completed == false {
            paths.insert(RecordingFiles.canonicalPath(oversizedURL(id: id, entry: entry)))
            if let source = entry.source { paths.insert(RecordingFiles.canonicalPath(URL(fileURLWithPath: source))) }
        }
        return paths
    }

    /// An oversized entry's file is listed, deleted or expired only when its move is
    /// complete and the file has the recorded length (and, for deletion, digest).
    private func oversizedHolds(_ entry: OversizedRecordings.Entry, at file: URL, digest: Bool = false) throws -> Bool {
        guard entry.completed != false, try RecordingFiles.exists(file) else { return false }
        if let bytes = entry.bytes, try RecordingFiles.facts(file).size != bytes { return false }
        if digest { return try entry.sha256.map { try RecordingFiles.sha256(of: file) == $0 } ?? false }
        return true
    }

    func checkSongDeletable(_ projectId: String, in context: ModelContext) throws {
        try requireChecked(context)
        let oversized = Dictionary(try OversizedRecordings.read(for: memosRoot).filter { $0.value.projectId == projectId }
            .map { (RecordingFiles.canonicalPath(oversizedURL(id: $0.key, entry: $0.value)), $0.value) }) { first, _ in first }
        let rows = try context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == projectId }
        let held = Dictionary(rows.compactMap { row in url(of: row).map { (RecordingFiles.canonicalPath($0), row.sha256) } }) { first, _ in first }
        let detached = Dictionary(try RecordingFiles.readPendingMoves(for: memosRoot).detach.map { ($0.destination, $0.sha256) }) { first, _ in first }
        for (folderProject, file) in try Self.listing(memosRoot) + Self.listing(trashRoot) where folderProject == projectId {
            let path = RecordingFiles.canonicalPath(file)
            if try RecordingFiles.facts(file).size > SyncRecording.maxBytes {
                // Only a registered recording's own bytes go with the song.
                guard let entry = oversized[path], try oversizedHolds(entry, at: file, digest: true) else { throw RecordingLibraryError.notVerified }
                continue
            }
            guard let sha = held[path] ?? detached[path], try RecordingFiles.sha256(of: file) == sha else { throw RecordingLibraryError.notVerified }
        }
    }

    // MARK: Changes that record the row before the file moves

    func publishFinished(_ staged: URL, projectId: String, preferredName: String, origin: Recording.Origin, id: String?, finishedAt: Date?) throws -> URL {
        guard let context else { throw RecordingLibraryError.unavailable }
        try requireChecked(context)
        if let id, let existing = try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == id }) {
            // Already published (an earlier attempt got that far): success. The staged
            // copy goes only when it is the very same audio.
            if try RecordingFiles.exists(staged), try RecordingFiles.sha256(of: staged) == existing.sha256 { try? FileManager.default.removeItem(at: staged) }
            guard let published = url(of: existing) else { throw RecordingLibraryError.unavailable }
            return published
        }
        if let id, let entry = try OversizedRecordings.read(for: memosRoot)[id] {
            return try finishOversized(id: id, entry: entry)
        }
        if id != nil, try !RecordingFiles.exists(staged) { throw RecordingLibraryError.takeMissing }
        try SyncIdentity.validateProjectId(projectId)
        try SyncIdentity.validateDisplayName(preferredName)
        let finished = finishedAt.map { Date(millisecondsSince1970: $0.epochMilliseconds) } ?? Date(millisecondsSince1970: Date().epochMilliseconds)
        let recordingId = id ?? UUID().uuidString.lowercased()
        guard try RecordingFiles.facts(staged).size <= SyncRecording.maxBytes else {
            // Too large for iCloud and Drive: it stays a local file. Its id, name, time
            // and move are journalled before it moves, and marked done after.
            let entry = OversizedRecordings.Entry(projectId: projectId, fileName: preferredName, finishedAt: finished.epochMilliseconds,
                                                  source: staged.path, completed: false, sha256: try RecordingFiles.sha256(of: staged),
                                                  bytes: try RecordingFiles.facts(staged).size)
            try OversizedRecordings.record(id: recordingId, entry: entry, for: memosRoot)
            return try finishOversized(id: recordingId, entry: entry)
        }
        let audio = try Data(contentsOf: staged)
        let row = Recording(id: recordingId, projectId: projectId, displayName: preferredName, audio: audio,
                            recordedAt: finished, uploadedAt: finished, origin: origin)
        return try commit(row, movingFrom: staged, in: context)
    }

    private func oversizedURL(id: String, entry: OversizedRecordings.Entry) -> URL {
        let name = RecordingFiles.storedName(id: id, displayName: entry.fileName)
        return entry.trashedAt == nil ? liveURL(projectId: entry.projectId, storedName: name) : trashURL(projectId: entry.projectId, storedName: name)
    }

    /// Completes a journalled oversized publication or migration: its file is
    /// published only when its own bytes are at its id's place (finding 4); an
    /// interrupted move is finished; another file there keeps the take waiting.
    /// Moves an oversized recording to the place `entry` describes: its bytes are
    /// verified, the move (source, digest, length and the state it moves to) is
    /// journalled, then made and marked done, so a crash anywhere is finished by
    /// the next run (finding 6).
    private func moveOversized(id: String, entry: OversizedRecordings.Entry, from source: URL) throws -> URL {
        var entry = entry
        let sha = try RecordingFiles.sha256(of: source)
        if let known = entry.sha256, known != sha { throw RecordingLibraryError.notVerified }
        entry.sha256 = sha
        entry.bytes = try RecordingFiles.facts(source).size
        entry.source = source.path
        entry.completed = false
        let before = try OversizedRecordings.read(for: memosRoot)[id]
        try OversizedRecordings.record(id: id, entry: entry, for: memosRoot)
        do {
            return try finishOversized(id: id, entry: entry)
        } catch {
            // Nothing moved: the record goes back to what it was.
            if try RecordingFiles.exists(source), let before { try? OversizedRecordings.record(id: id, entry: before, for: memosRoot) }
            throw error
        }
    }

    nonisolated private static func positive(_ milliseconds: Int64) -> Int64? { milliseconds > 0 ? milliseconds : nil }

    private func finishOversized(id: String, entry: OversizedRecordings.Entry) throws -> URL {
        var entry = entry
        let target = oversizedURL(id: id, entry: entry)
        func holdsTake(_ url: URL) throws -> Bool {
            guard try RecordingFiles.exists(url) else { return false }
            guard let sha = entry.sha256 else { return true }
            return try RecordingFiles.sha256(of: url) == sha
        }
        if entry.completed == false {
            if try !holdsTake(target) {
                guard try !RecordingFiles.exists(target) else { throw RecordingLibraryError.notVerified }
                guard let source = entry.source.map({ URL(fileURLWithPath: $0) }), try RecordingFiles.exists(source) else {
                    throw RecordingLibraryError.takeMissing
                }
                // Only the journalled bytes move: digest and length are checked first.
                if let sha = entry.sha256, try RecordingFiles.sha256(of: source) != sha { throw RecordingLibraryError.notVerified }
                if let bytes = entry.bytes, try RecordingFiles.facts(source).size != bytes { throw RecordingLibraryError.notVerified }
                aboutToMove([source])
                try RecordingFiles.safeMove(source, to: target, within: [memosRoot, trashRoot])
            }
            entry.completed = true
            entry.source = nil
            try OversizedRecordings.record(id: id, entry: entry, for: memosRoot)
        }
        guard try holdsTake(target) else { throw RecordingLibraryError.takeMissing }
        return target
    }

    /// Restored or imported audio: written only if this device has neither the
    /// id nor a newer tombstone for it, as `<id>.<ext>`, named by the entry and with
    /// the backup's time. The bytes must match the entry's hash and declared size,
    /// within the cap.
    @discardableResult
    func commitRestored(_ audio: Data, entry: SyncRecording, origin: Recording.Origin, context: ModelContext) throws -> Bool {
        guard !audio.isEmpty, Int64(audio.count) == entry.bytes, RecordingBackupManifest.sha256Hex(audio) == entry.sha256 else {
            throw SyncValidationError.invalidRecording
        }
        try requireChecked(context)
        guard Int64(audio.count) <= SyncRecording.maxBytes,
              try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == entry.id }) == nil,
              // A deletion made here while the restore ran wins if it is newer.
              try !DeletionStore.all(in: context).contains(where: { $0.covers(entry) }) else { return false }
        let staging = RecordingFiles.stagingRoot(for: memosRoot)
        let staged = try RecordingFiles.stageVerified(audio, sha256: entry.sha256, storedName: RecordingFiles.storedName(id: entry.id, displayName: entry.fileName),
                                                      in: staging, modifiedAt: entry.uploadedAt)
        defer { try? FileManager.default.removeItem(at: staged) }
        let row = Recording(id: entry.id, projectId: entry.projectId, displayName: entry.fileName, audio: audio,
                            recordedAt: entry.uploadedAt, uploadedAt: entry.uploadedAt, origin: origin, sha256: entry.sha256)
        row.precedenceRepaired = entry.precedenceRepaired
        _ = try commit(row, movingFrom: staged, in: context)
        return true
    }

    func renameRecording(at url: URL, to displayName: String) throws {
        try SyncIdentity.validateDisplayName(displayName)
        guard let context else { throw RecordingLibraryError.unavailable }
        try requireChecked(context)
        if let row = try verifiedRow(at: url, trashed: false, in: context) {
            guard row.displayName != displayName else { return }
            let previous = (row.displayName, row.displayNameChanged)
            row.displayName = displayName
            row.displayNameChanged = true
            do {
                try save(context)
            } catch {
                (row.displayName, row.displayNameChanged) = previous
                throw error
            }
            markVerified(row)
            return
        }
        // A file over the cap keeps its name in its local record.
        guard let id = RecordingFiles.storedId(of: url), var entry = try OversizedRecordings.read(for: memosRoot)[id] else {
            throw RecordingLibraryError.notVerified
        }
        entry.fileName = displayName
        try OversizedRecordings.record(id: id, entry: entry, for: memosRoot)
    }

    func trashRecording(at url: URL, trashedAt: Date) throws -> TrashedVoiceMemo {
        guard let context else { throw RecordingLibraryError.unavailable }
        try requireChecked(context)
        let stamp = Date(millisecondsSince1970: trashedAt.epochMilliseconds)
        if let row = try verifiedRow(at: url, trashed: false, in: context) {
            row.trashedAt = stamp
            try recordIntent(row, from: url, in: context) { row.trashedAt = nil }
            return TrashedVoiceMemo(url: self.url(of: row)!, projectId: row.projectId, originalName: row.displayName, deletedAt: stamp, recordingId: row.id)
        }
        guard let id = RecordingFiles.storedId(of: url), var entry = try OversizedRecordings.read(for: memosRoot)[id] else {
            throw RecordingLibraryError.notVerified
        }
        entry.trashedAt = stamp.epochMilliseconds
        let target = try moveOversized(id: id, entry: entry, from: url)
        return TrashedVoiceMemo(url: target, projectId: entry.projectId, originalName: entry.fileName, deletedAt: stamp, recordingId: id)
    }

    func untrashRecording(_ trashed: TrashedVoiceMemo) throws -> URL {
        guard let context else { throw RecordingLibraryError.unavailable }
        try requireChecked(context)
        if let row = try verifiedRow(at: trashed.url, trashed: true, in: context) {
            let previous = row.trashedAt
            row.trashedAt = nil
            try recordIntent(row, from: trashed.url, in: context) { row.trashedAt = previous }
            return url(of: row)!
        }
        if let id = RecordingFiles.storedId(of: trashed.url), var entry = try OversizedRecordings.read(for: memosRoot)[id], entry.trashedAt != nil {
            entry.trashedAt = nil
            return try moveOversized(id: id, entry: entry, from: trashed.url)
        }
        // A recording removed on another device keeps its id, name and time (finding 7).
        guard let entry = try detachEntry(at: trashed.url) else { throw RecordingLibraryError.notVerified }
        let audio = try Data(contentsOf: trashed.url)
        guard RecordingBackupManifest.sha256Hex(audio) == entry.sha256,
              try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == entry.recordingId }) == nil else {
            throw RecordingLibraryError.notVerified
        }
        let at = Date(millisecondsSince1970: entry.at)
        let row = Recording(id: entry.recordingId, projectId: trashed.projectId, displayName: entry.displayName, audio: audio,
                            recordedAt: at, uploadedAt: at, origin: .restored, sha256: entry.sha256)
        row.precedenceRepaired = entry.repaired ?? false
        context.insert(row)
        try recordIntent(row, from: trashed.url, in: context) { context.delete(row) }
        var moves = try RecordingFiles.readPendingMoves(for: memosRoot)
        moves.detach.removeAll { $0.destination == entry.destination }
        try RecordingFiles.writePendingMoves(moves, for: memosRoot)
        return url(of: row)!
    }

    /// Keeps a file the library reported (its id's place held other bytes) as a
    /// recording of its own under a new id, with its name; nothing is replaced or
    /// deleted, and the next run takes the other file in (finding 9).
    @discardableResult
    func keepSeparately(_ url: URL) throws -> URL {
        guard let context else { throw RecordingLibraryError.unavailable }
        try requireChecked(context)
        let trashed = RecordingFiles.isRecordingFile(url, in: [trashRoot])
        guard trashed || RecordingFiles.isRecordingFile(url, in: [memosRoot]) else { throw RecordingLibraryError.notVerified }
        let facts = try RecordingFiles.facts(url)
        let id = UUID().uuidString.lowercased()
        let legacy = trashed ? RecordingFiles.legacyTrashName(url.lastPathComponent) : nil
        let name = RecordingFiles.storedId(of: url) == nil ? (legacy?.originalName ?? url.lastPathComponent)
            : "Recording.\(RecordingFiles.storedExtension(of: url.lastPathComponent))"
        let time = facts.modified.epochMilliseconds > 0 ? Date(millisecondsSince1970: facts.modified.epochMilliseconds) : firstSeen(id)
        let trashTime = trashed ? ((legacy?.deletedAt).flatMap { $0.epochMilliseconds > 0 ? $0 : nil } ?? Date(millisecondsSince1970: Date().epochMilliseconds)) : nil
        if facts.size > SyncRecording.maxBytes {
            // Over the cap: a local record of its own, its move journalled (finding 9).
            let entry = OversizedRecordings.Entry(projectId: url.deletingLastPathComponent().lastPathComponent, fileName: name, finishedAt: time.epochMilliseconds,
                                                  trashedAt: trashTime?.epochMilliseconds)
            let target = try moveOversized(id: id, entry: entry, from: url)
            needsAttention.removeAll { RecordingFiles.canonicalPath($0) == RecordingFiles.canonicalPath(url) }
            return target
        }
        let audio = try Data(contentsOf: url)
        let row = Recording(id: id, projectId: url.deletingLastPathComponent().lastPathComponent, displayName: name, audio: audio,
                            recordedAt: time, uploadedAt: time, origin: .migrated, sha256: RecordingBackupManifest.sha256Hex(audio))
        row.precedenceRepaired = facts.modified.epochMilliseconds <= 0
        row.trashedAt = trashTime
        let target = try commit(row, movingFrom: url, in: context)
        needsAttention.removeAll { RecordingFiles.canonicalPath($0) == RecordingFiles.canonicalPath(url) }
        return target
    }

    /// A draft's copied recordings, written outside the library as `<newId>.<ext>`:
    /// recorded so the next reconcile takes them in with their names.
    func expectCopies(_ copies: [(url: URL, recordingId: String, displayName: String, sha256: String)]) throws {
        guard !copies.isEmpty else { return }
        var moves = try RecordingFiles.readPendingMoves(for: memosRoot)
        moves.adopt += copies.map { .init(path: RecordingFiles.canonicalPath($0.url), recordingId: $0.recordingId, displayName: $0.displayName, sha256: $0.sha256) }
        try RecordingFiles.writePendingMoves(moves, for: memosRoot)
    }

    /// The display names of a song's recordings, by their file names (for a draft snapshot).
    func displayNames(projectId: String, in context: ModelContext) throws -> [String: String] {
        var names: [String: String] = [:]
        for row in try context.fetch(FetchDescriptor<Recording>()) where row.projectId == projectId { names[row.storedName] = row.displayName }
        for (id, entry) in try OversizedRecordings.read(for: memosRoot) where entry.projectId == projectId {
            names[RecordingFiles.storedName(id: id, displayName: entry.fileName)] = entry.fileName
        }
        return names
    }

    /// Song deletion: each of its recordings older than the deletion gets its own
    /// tombstone by id, in the caller's transaction, and its row goes.
    static func tombstoneRecordings(ofProject projectId: String, deletedAt: Int64, in context: ModelContext) throws -> [Recording] {
        let rows = try context.fetch(FetchDescriptor<Recording>()).filter {
            $0.projectId == projectId && ($0.precedenceRepaired || $0.precedenceTime.epochMilliseconds < deletedAt)
        }
        for row in rows {
            try DeletionStore.upsert(SyncDeletion(projectId: projectId, recordingId: row.id, fileName: row.displayName, deletedAt: deletedAt), in: context)
            context.delete(row)
        }
        return rows
    }

    static func upsertTombstone(_ deletion: SyncDeletion, in context: ModelContext) throws {
        try DeletionStore.upsert(deletion, in: context)
    }

    // MARK: Helpers

    /// Saves the row with the move it is about to make, makes it, then clears it.
    /// Any failure before the move restores the row; a failed save fails the
    /// change with the file untouched. After the move the row stands.
    private func recordIntent(_ row: Recording, from source: URL, in context: ModelContext, revert: () -> Void) throws {
        guard let target = url(of: row) else {
            revert()
            throw RecordingLibraryError.unavailable
        }
        row.pendingFrom = source.path
        do {
            try save(context)
        } catch {
            revert()
            row.pendingFrom = nil
            context.rollback()
            throw error
        }
        do {
            aboutToMove([source])
            try RecordingFiles.safeMove(source, to: target, within: [memosRoot, trashRoot])
        } catch {
            revert()
            row.pendingFrom = nil
            try? save(context)
            throw error
        }
        markVerified(row)
        row.pendingFrom = nil
        do { try save(context) } catch { throw RecordingLibraryError.finalizeFailed }
    }

    /// Publishes a new row's staged audio to `<id>.<ext>`: the row is saved with
    /// the move first. A failure before the move removes the row; after it, the
    /// row stands (A31).
    private func commit(_ row: Recording, movingFrom staged: URL, in context: ModelContext) throws -> URL {
        guard let target = url(of: row) else { throw RecordingLibraryError.unavailable }
        context.insert(row)
        row.pendingFrom = staged.path
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        do {
            try RecordingFiles.safeMove(staged, to: target, within: [memosRoot, trashRoot])
        } catch {
            context.delete(row)
            try? save(context)
            throw error
        }
        markVerified(row)
        row.pendingFrom = nil
        do { try save(context) } catch { throw RecordingLibraryError.finalizeFailed }
        return target
    }

    /// Every live and Trash file over the cap, listed off the main actor (A29).
    func oversizedInventory() async throws -> [URL] {
        let memosRoot = memosRoot
        let trashRoot = trashRoot
        return try await Task.detached(priority: .utility) {
            let files = try Self.listing(memosRoot).map(\.url) + Self.listing(trashRoot).map(\.url)
            return try files.filter { try RecordingFiles.facts($0).size > SyncRecording.maxBytes }
        }.value
    }
}

/// Ids, names and times of recordings over the cap, which have no row: a file
/// over the cap is `<id>.<ext>` like any other, and this record keeps what a row
/// would (A29, A36). A publication or migration is journalled (its source, its
/// digest, not yet completed) before the move.
enum OversizedRecordings {
    struct Entry: Codable, Equatable {
        var projectId: String
        /// Its display name.
        var fileName: String
        var finishedAt: Int64
        /// The file while the move is under way.
        var source: String?
        /// False until the file is in place; nil (older entries) means done.
        var completed: Bool?
        /// The bytes' digest: a file at its place counts only if it holds these.
        var sha256: String?
        /// Set while it is in the recordings Trash (epoch ms).
        var trashedAt: Int64?
        /// The bytes' length, checked with the digest before a move.
        var bytes: Int64?
    }

    private static func url(for memosRoot: URL) -> URL {
        memosRoot.deletingLastPathComponent().appendingPathComponent("oversized-recordings.json")
    }

    static func read(for memosRoot: URL) throws -> [String: Entry] {
        let file = url(for: memosRoot)
        guard try RecordingFiles.exists(file) else { return [:] }
        return try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))
    }

    static func record(id: String, entry: Entry, for memosRoot: URL) throws {
        var entries = try read(for: memosRoot)
        entries[id] = entry
        try write(entries, for: memosRoot)
    }

    /// Keeps only the entries `keep` says still stand.
    static func prune(for memosRoot: URL, keep: (String, Entry) -> Bool) throws {
        let entries = try read(for: memosRoot)
        let kept = entries.filter { keep($0.key, $0.value) }
        if kept.count != entries.count { try write(kept, for: memosRoot) }
    }

    private static func write(_ entries: [String: Entry], for memosRoot: URL) throws {
        try FileManager.default.createDirectory(at: memosRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url(for: memosRoot), options: .atomic)
    }
}
