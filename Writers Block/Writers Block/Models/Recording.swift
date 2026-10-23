import Foundation
import SwiftData

/// A voice memo in the library, so recordings sync through iCloud with the
/// songs. Its `id` is the recording's identity everywhere (Drive file
/// `rec_<id>`, manifest, tombstones); a rename changes only `fileName`.
/// Playback works on the files under `RecordingFiles.memosRoot()` (or the
/// recordings Trash while `trashedAt` is set); `RecordingLibrary` keeps the
/// files in step with the rows, which are the source of truth.
@Model
final class Recording {
    // See SongProject.swift: CloudKit needs property defaults and no unique attributes.
    var id: String = ""
    var projectId: String = ""
    /// The file name allocated in the song (A30); see `claimedName`.
    var fileName: String = ""
    /// The name this recording asks for (given when it was made, renamed or
    /// restored). When several recordings of a song claim one name, the earliest
    /// keeps it and the others are allocated "<stem> 2<ext>", 3, … in `fileName`.
    /// Empty on rows from before it existed: the claim is then `fileName`.
    var claimedName: String = ""
    var sha256: String = ""
    var bytes: Int64 = 0
    var recordedAt: Date = Date()
    /// The precedence time a tombstone is judged against, persisted once and
    /// never re-derived from the file: finish time for a new recording, the
    /// backup's time for restored or imported audio, the old entry's time for
    /// migrated audio, the earliest file date for a memo from before this
    /// version, or the time it was first seen when none was recorded (A32).
    var uploadedAt: Date?
    /// recorded, restored, imported or migrated.
    var origin: String = Origin.recorded.rawValue
    /// Set while the recording sits in the recordings Trash; it names the Trash file.
    var trashedAt: Date?
    /// Where this row's audio is while a move is under way (a staging or parking
    /// file, or its old name), written before the move; only a file there holding
    /// the row's bytes is ever taken for its audio.
    var pendingFrom: String?
    @Attribute(.externalStorage) var audio: Data = Data()

    enum Origin: String {
        case recorded, restored, imported, migrated
    }

    /// `sha256`, when given, is the audio's digest already verified off the main actor.
    init(id: String = UUID().uuidString.lowercased(), projectId: String, fileName: String, audio: Data, recordedAt: Date,
         uploadedAt: Date? = nil, origin: Origin = .recorded, sha256: String? = nil) {
        self.id = id
        self.projectId = projectId
        self.fileName = fileName
        self.claimedName = fileName
        self.audio = audio
        self.bytes = Int64(audio.count)
        self.sha256 = sha256 ?? RecordingBackupManifest.sha256Hex(audio)
        self.recordedAt = recordedAt
        self.uploadedAt = uploadedAt ?? recordedAt
        self.origin = origin.rawValue
    }

    var precedenceTime: Date { uploadedAt ?? recordedAt }

    var claim: String { claimedName.isEmpty ? fileName : claimedName }

    var syncEntry: SyncRecording {
        SyncRecording(id: id, projectId: projectId, fileName: fileName, bytes: bytes, sha256: sha256, uploadedAt: precedenceTime,
                      claimedName: claim == fileName ? nil : claim)
    }

    /// Where this recording's file lives: the memo folder, or the Trash while trashed.
    func fileURL(memosRoot: URL, trashRoot: URL) -> URL? {
        if let trashedAt {
            let stamp = trashedAt.epochMilliseconds
            return trashRoot.appendingPathComponent(projectId, isDirectory: true)
                .appendingPathComponent("\(stamp)\(RecordingFiles.trashNameSeparator)\(fileName)")
        }
        return try? RecordingFiles.localURL(projectId: projectId, fileName: fileName, memosRoot: memosRoot)
    }
}

enum RecordingLibraryError: Error, Equatable {
    /// A memo folder or file could not be read; nothing was changed.
    case scanFailed
    /// The library is not open, so the change could not be recorded.
    case unavailable
    /// No free name fits the file-name limit.
    case noFreeName
    /// The audio moved into place but its record could not be finished; the
    /// recording stands and is finished on the next run (A31).
    case finalizeFailed
    /// A take promised by id has neither a row nor its audio: nothing can be saved.
    case takeMissing
    /// The recordings have not been checked successfully (or the tombstones or the
    /// move record cannot be read), so nothing is changed until they are (A33).
    case notChecked
    /// The file is not the recording its name says (its bytes differ).
    case notVerified
}

extension RecordingLibraryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .scanFailed: return "A recordings folder could not be read, so nothing was changed. Writers Block will try again."
        case .unavailable: return "The library is not open yet, so the recording could not be saved."
        case .noFreeName: return "No free name fits for this recording."
        case .finalizeFailed: return "The recording was saved, but its record could not be finished. Writers Block will finish it on the next try."
        case .takeMissing: return "This recording's audio is no longer on this device."
        case .notChecked: return "Your recordings are being checked, so nothing was changed. Try again in a moment."
        case .notVerified: return "This recording changed on this device, so nothing was changed. Try again in a moment."
        }
    }
}

/// Memo changes that must record their metadata before the file moves.
@MainActor
protocol RecordingPublishing: AnyObject {
    /// Moves a finished recording or imported audio from staging into the memo folder.
    /// `id` names a take already promised to the user (A27): publishing it again
    /// once it is published is a success, not a second recording. `finishedAt` is
    /// the take's recorded finish time, its precedence time (A31).
    func publishFinished(_ staged: URL, projectId: String, preferredName: String, origin: Recording.Origin, id: String?, finishedAt: Date?) throws -> URL
    func renameRecording(at url: URL, to target: URL) throws
    func trashRecording(at url: URL, to trashURL: URL, trashedAt: Date) throws
    func untrashRecording(_ trashed: TrashedVoiceMemo, to target: URL) throws
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
/// A run reads every folder, file and move record off the main actor: files
/// rows may hold are hashed (a digest cache, keyed by path, size, date and inode
/// and kept only for a row that still holds that digest, skips re-hashing),
/// and files no row may hold are read once with their digest, for adoption.
/// On the main actor it re-lists and re-stats everything and commits only if
/// nothing changed. Only a row's id and verified bytes place its audio. Files no
/// row holds are adopted with the id every device derives for them; copies of
/// one identity are one recording whose precedence time is fixed (first-seen
/// when missing) before any tombstone is compared (A26, A32). Names converge
/// from claims (A30/A34). Rows are saved before files move; moves go through a
/// parking folder; moves to quarantine or to the recordings Trash are recorded,
/// with the digest they were decided on, before the save that decides them.
/// Restoring a row's missing file is written and verified off the main actor.
/// Every memo or Trash file move goes through `willMove` first. Changes made
/// outside a run require the complete check (A33).
@MainActor
final class RecordingLibrary: RecordingPublishing {
    struct Result: Equatable {
        var oversizedCount = 0
        /// Live and Trash files over the cap, which stay on this device only.
        var oversizedFiles: [URL] = []
    }

    static let shared = RecordingLibrary(defaults: .standard)

    private static let mirroredPathsKey = "recording-library-verified-paths"
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
    /// by further passes of the same run (finding 9).
    var adoptionBudget: Int64 = 64 * 1024 * 1024
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(memosRoot: URL = RecordingFiles.memosRoot(), trashRoot: URL = RecordingFiles.memosTrashRoot(), defaults: UserDefaults) {
        self.memosRoot = memosRoot
        self.trashRoot = trashRoot
        self.defaults = defaults
    }

    /// A live path verified to hold a row's audio here: that row's id, precedence
    /// time and digest. Written only after a verified operation.
    struct Verified: Equatable {
        let id: String
        let at: Int64
        let sha256: String
    }

    private var mirrored: [String: Verified] {
        get {
            let raw = defaults.dictionary(forKey: Self.mirroredPathsKey) as? [String: [String: Any]] ?? [:]
            return raw.compactMapValues { entry in
                guard let id = entry["id"] as? String, let at = (entry["at"] as? NSNumber)?.int64Value,
                      let sha = entry["sha256"] as? String else { return nil }
                return Verified(id: id, at: at, sha256: sha)
            }
        }
        set {
            defaults.set(newValue.mapValues { ["id": $0.id, "at": NSNumber(value: $0.at), "sha256": $0.sha256] as [String: Any] },
                         forKey: Self.mirroredPathsKey)
        }
    }

    /// The digest a row holds at a path, by path; a hint to skip re-hashing, never
    /// proof, and only offered while that row still exists with that digest.
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

    private static let claimAdoptionsKey = "recording-library-claim-adoptions"

    /// A35: claims a backup accepted from the manifest for recordings held here,
    /// taken by the next reconcile; a rename here in the meantime cancels its own.
    private(set) var claimAdoptions: [String: String] {
        get { defaults.dictionary(forKey: Self.claimAdoptionsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.claimAdoptionsKey) }
    }

    func adoptClaims(_ claims: [String: String]) {
        guard !claims.isEmpty else { return }
        claimAdoptions.merge(claims) { _, new in new }
    }

    /// Tests: what a reinstall or cleared settings leaves.
    func forgetClaimAdoptions() {
        defaults.removeObject(forKey: Self.claimAdoptionsKey)
    }

    func forgetMirroredKeys() {
        defaults.removeObject(forKey: Self.mirroredPathsKey)
        defaults.removeObject(forKey: Self.digestCacheKey)
    }

    private func url(of row: Recording) -> URL? { row.fileURL(memosRoot: memosRoot, trashRoot: trashRoot) }

    private func aboutToMove(_ files: [URL]) {
        guard !files.isEmpty else { return }
        willMove?(files)
        files.forEach { atMoveBoundary?($0) }
    }

    /// Records a verified live path for a row whose audio was just placed there.
    private func markVerified(_ row: Recording, removing old: URL? = nil) {
        var paths = mirrored
        if let old { paths[RecordingFiles.canonicalPath(old)] = nil }
        if row.trashedAt == nil, let target = url(of: row) {
            paths[RecordingFiles.canonicalPath(target)] = Verified(id: row.id, at: row.precedenceTime.epochMilliseconds, sha256: row.sha256)
        }
        mirrored = paths
    }

    // MARK: Reading, off the main actor

    /// A file as one read pass saw it.
    nonisolated struct DiskFile: Sendable {
        let url: URL
        let path: String
        let projectId: String
        /// The recording's name: the file name, or a Trash entry's original name.
        let fileName: String
        let trashedAt: Date?
        let size: Int64
        let modified: Date
        let inode: UInt64
        /// Nil over the cap: such a file is never hashed or adopted.
        let sha256: String?
        /// True when `sha256` came from the digest cache (a hint): such a digest
        /// never justifies moving the file (finding 3).
        let fromCache: Bool
        /// The bytes, for a file no row's digest accounts for, within the pass's
        /// memory budget; nil past the budget (adopted on a later pass).
        let audio: Data?
        var oversized: Bool { sha256 == nil }
    }

    nonisolated struct ReadRequest: Sendable {
        let memosRoot: URL
        let trashRoot: URL
        let abortingIfMissing: Bool
        let cache: [String: CachedDigest]
        let sources: [(path: String, projectId: String, fileName: String)]
        /// Per path, the digests rows expect there (place, pending source, verified path).
        let expected: [String: Set<String>]
        /// Paths whose cached digest must not be used this pass.
        let uncached: Set<String>
        /// Bytes kept in memory for adoption in one pass; the rest wait for the next.
        let audioBudget: Int64
    }

    nonisolated struct ReadPass: Sendable {
        let moves: RecordingFiles.PendingMoves
        let live: [DiskFile]
        let trash: [DiskFile]
        /// Pending sources outside the scanned folders (staging, parking).
        let sources: [DiskFile]
        /// Files recorded for quarantine or detaching, hashed freshly for replay.
        let recorded: [DiskFile]
        /// Files no row accounts for whose bytes did not fit the budget.
        let deferred: Int
    }

    /// Reads one file. Digests are streamed (no file is held for hashing); a file
    /// no row's digest accounts for is then read whole for adoption, within the
    /// budget, and checked against its streamed digest.
    nonisolated private static func inspect(_ url: URL, projectId: String, fileName: String, trashedAt: Date?,
                                            request: ReadRequest, budget: inout Int64, deferred: inout Int, forReplay: Bool = false) throws -> DiskFile {
        let facts = try RecordingFiles.facts(url)
        let path = RecordingFiles.canonicalPath(url)
        var digest: String?
        var cached = false
        var audio: Data?
        if facts.size <= SyncRecording.maxBytes {
            if !forReplay, !request.uncached.contains(path), let hint = request.cache[path], hint.size == facts.size, hint.inode == facts.inode,
               hint.modified == facts.modified.timeIntervalSince1970 {
                digest = hint.sha256
                cached = true
            } else {
                digest = try RecordingFiles.sha256(of: url)
            }
            if !forReplay, let digest, request.expected[path]?.contains(digest) != true {
                if facts.size <= budget {
                    let bytes = try Data(contentsOf: url)
                    // Changed between the two reads: the pass stops rather than guess.
                    guard RecordingBackupManifest.sha256Hex(bytes) == digest else { throw RecordingLibraryError.scanFailed }
                    budget -= facts.size
                    audio = bytes
                } else {
                    deferred += 1
                }
            }
        }
        return DiskFile(url: url, path: path, projectId: projectId, fileName: fileName, trashedAt: trashedAt, size: facts.size,
                        modified: facts.modified, inode: facts.inode, sha256: digest, fromCache: cached, audio: audio)
    }

    /// Every read of a run. Any failure throws: a failed read must never look
    /// like a missing recording.
    nonisolated private static func read(_ request: ReadRequest) throws -> ReadPass {
        let moves = try RecordingFiles.readPendingMoves(for: request.memosRoot)
        let hidden = moves.adoptionHidden
        var budget = request.audioBudget
        var deferred = 0
        var live: [DiskFile] = []
        if try RecordingFiles.exists(request.memosRoot) {
            for (projectId, fileName, url) in try liveListing(request.memosRoot) where !hidden.contains(RecordingFiles.canonicalPath(url)) {
                live.append(try inspect(url, projectId: projectId, fileName: fileName, trashedAt: nil, request: request, budget: &budget, deferred: &deferred))
            }
        } else if request.abortingIfMissing {
            throw RecordingLibraryError.scanFailed
        }
        var trash: [DiskFile] = []
        for memo in try RecordingFiles.readableTrashedMemos(in: request.trashRoot) where !hidden.contains(RecordingFiles.canonicalPath(memo.url)) {
            trash.append(try inspect(memo.url, projectId: memo.projectId, fileName: memo.originalName, trashedAt: memo.deletedAt,
                                     request: request, budget: &budget, deferred: &deferred))
        }
        let known = Set((live + trash).map(\.path))
        var sources: [DiskFile] = []
        for source in request.sources where !known.contains(source.path) && !hidden.contains(source.path) {
            let url = URL(fileURLWithPath: source.path)
            if try RecordingFiles.exists(url) {
                sources.append(try inspect(url, projectId: source.projectId, fileName: source.fileName, trashedAt: nil,
                                           request: request, budget: &budget, deferred: &deferred))
            }
        }
        // Recorded moves are verified at replay against digests taken here.
        var recorded: [DiskFile] = []
        for path in moves.quarantine.map(\.path) + moves.detach.flatMap({ [$0.source, $0.destination] }).filter({ !$0.isEmpty }) {
            let url = URL(fileURLWithPath: path)
            if try RecordingFiles.exists(url) {
                recorded.append(try inspect(url, projectId: url.deletingLastPathComponent().lastPathComponent, fileName: url.lastPathComponent,
                                            trashedAt: nil, request: request, budget: &budget, deferred: &deferred, forReplay: true))
            }
        }
        return ReadPass(moves: moves, live: live.sorted { $0.path < $1.path }, trash: trash.sorted { $0.path < $1.path },
                        sources: sources, recorded: recorded, deferred: deferred)
    }

    /// Live memo files by project, listed; a folder that cannot be listed throws.
    nonisolated private static func liveListing(_ memosRoot: URL) throws -> [(String, String, URL)] {
        var listing: [(String, String, URL)] = []
        for folder in try FileManager.default.contentsOfDirectory(at: memosRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            let projectId = folder.lastPathComponent
            guard (try? SyncIdentity.validateProjectId(projectId)) != nil else { continue }
            for (fileName, url) in try RecordingBackupManifest.scanFiles(projectId: projectId, memosRoot: memosRoot) {
                listing.append((projectId, fileName, url))
            }
        }
        return listing
    }

    /// The validated commit boundary: the folders, files and move record are as
    /// the read saw them (same names, sizes, dates and inodes).
    private func stillAsRead(_ pass: ReadPass) throws -> Bool {
        guard try RecordingFiles.readPendingMoves(for: memosRoot) == pass.moves else { return false }
        let hidden = pass.moves.adoptionHidden
        let livePaths = try RecordingFiles.exists(memosRoot)
            ? Set(try Self.liveListing(memosRoot).map { RecordingFiles.canonicalPath($0.2) }).subtracting(hidden) : []
        let trashPaths = Set(try RecordingFiles.readableTrashedMemos(in: trashRoot).map { RecordingFiles.canonicalPath($0.url) }).subtracting(hidden)
        guard livePaths == Set(pass.live.map(\.path)), trashPaths == Set(pass.trash.map(\.path)) else { return false }
        for file in pass.live + pass.trash + pass.sources + pass.recorded {
            guard try RecordingFiles.exists(file.url) else { return false }
            let facts = try RecordingFiles.facts(file.url)
            guard facts.size == file.size, facts.modified == file.modified, facts.inode == file.inode else { return false }
        }
        return true
    }

    // MARK: Reconcile

    /// Canonical copy first: a live copy, else the newest Trash time, ties by file name (A26).
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
            // A pass adopts what fits its memory budget; further passes take the rest.
            for _ in 0..<64 {
                let rows = try context.fetch(FetchDescriptor<Recording>())
                let byId = Dictionary(rows.map { ($0.id, $0.sha256) }) { first, _ in first }
                var expected: [String: Set<String>] = [:]
                for row in rows {
                    var places = [url(of: row).map(RecordingFiles.canonicalPath), row.pendingFrom.map { RecordingFiles.canonicalPath(URL(fileURLWithPath: $0)) }].compactMap { $0 }
                    places += mirrored.filter { $0.value.id == row.id }.map(\.key)
                    for place in places { expected[place, default: []].insert(row.sha256) }
                }
                let request = ReadRequest(
                    memosRoot: memosRoot, trashRoot: trashRoot, abortingIfMissing: !mirrored.isEmpty,
                    // Only for a row that still holds that digest (finding 3).
                    cache: digestCache.filter { byId[$0.value.id] == $0.value.sha256 },
                    sources: rows.compactMap { row in row.pendingFrom.map { (RecordingFiles.canonicalPath(URL(fileURLWithPath: $0)), row.projectId, row.fileName) } },
                    expected: expected, uncached: uncached, audioBudget: adoptionBudget
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
                    guard let staged = try await Task.detached(priority: .utility, operation: { () throws -> URL? in
                        guard RecordingBackupManifest.sha256Hex(audio) == sha else { return nil }
                        return try RecordingFiles.stageVerified(audio, sha256: sha, in: staging, modifiedAt: modified)
                    }).value else { continue }
                    defer { try? FileManager.default.removeItem(at: staged) }
                    guard write.row.modelContext != nil, !write.row.isDeleted, write.row.sha256 == sha,
                          url(of: write.row).map(RecordingFiles.canonicalPath) == RecordingFiles.canonicalPath(write.to),
                          try RecordingFiles.readPendingMoves(for: memosRoot) == movesAfterCommit,
                          try !DeletionStore.all(in: context).contains(where: { $0.covers(projectId: write.row.projectId, recordingId: write.row.id, sha256: sha, at: write.row.precedenceTime) }),
                          try !RecordingFiles.exists(write.to) else { continue }
                    try FileManager.default.createDirectory(at: write.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    do {
                        try FileManager.default.moveItem(at: staged, to: write.to)
                    } catch CocoaError.fileWriteFileExists {
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
                let moreToMove = openCount > 0 && openCount != previousOpen
                previousOpen = openCount
                guard moreToAdopt || moreToMove else { return plan.result }
                uncached = []
            }
            if let lastResult { return lastResult }
            throw RecordingLibraryError.scanFailed
        } catch {
            context.rollback()
            lastRunSucceeded = false
            throw error
        }
    }

    private struct Plan {
        var result: Result
        var verified: [(row: Recording, file: (size: Int64, modified: Date, inode: UInt64))]
        var writes: [(row: Recording, to: URL)]
        var adopted: Int
        var adoptedClaims: [String]
    }

    private enum Replan: Error {
        case freshDigests(Set<String>)
    }



    private func finish(_ plan: Plan) {
        var paths: [String: Verified] = [:]
        var cache: [String: CachedDigest] = [:]
        for (row, facts) in plan.verified {
            guard let target = url(of: row) else { continue }
            let path = RecordingFiles.canonicalPath(target)
            cache[path] = CachedDigest(id: row.id, size: facts.size, modified: facts.modified.timeIntervalSince1970, inode: facts.inode, sha256: row.sha256)
            if row.trashedAt == nil { paths[path] = Verified(id: row.id, at: row.precedenceTime.epochMilliseconds, sha256: row.sha256) }
        }
        mirrored = paths
        digestCache = cache
        var adoptions = claimAdoptions
        for id in plan.adoptedClaims { adoptions[id] = nil }
        claimAdoptions = adoptions
        oversizedCount = plan.result.oversizedCount
        oversizedFiles = plan.result.oversizedFiles
    }

    private func commit(_ pass: ReadPass, context: ModelContext) throws -> Plan {
        // An in-memory library is empty at every launch; treating its missing rows
        // as removals would trash every memo, so it only ever adds.
        let allowRemovals = !context.container.configurations.contains { $0.isStoredInMemoryOnly }
        let known = mirrored
        // Tombstones are read (and validated) before anything else; a failure stops the run (A33).
        let deletions = try DeletionStore.all(in: context)
        let allRows = try context.fetch(FetchDescriptor<Recording>()).sorted { $0.id < $1.id }

        // 1. Precedence times are fixed before anything is compared (A32): a row
        //    without one gets the time it was first seen here, stored at once.
        for row in allRows where (row.uploadedAt?.epochMilliseconds ?? 0) <= 0 { row.uploadedAt = firstSeen(row.id) }

        var byPath: [String: DiskFile] = [:]
        for file in pass.live + pass.trash + pass.sources { byPath[file.path] = file }
        let knownById = Dictionary(grouping: known, by: { $0.value.id })

        // 2. Where each row's audio is: its pending source, its own path, or a path
        //    verified for its id here, and only where the bytes are the row's.
        func located(_ row: Recording) -> DiskFile? {
            var places: [String] = []
            if let pending = row.pendingFrom { places.append(RecordingFiles.canonicalPath(URL(fileURLWithPath: pending))) }
            if let own = url(of: row) { places.append(RecordingFiles.canonicalPath(own)) }
            places += (knownById[row.id] ?? []).map(\.key).sorted()
            return places.lazy.compactMap { byPath[$0] }.first { $0.sha256 == row.sha256 }
        }
        var rows: [Recording] = []
        var extras: [Recording] = []
        for (_, same) in Dictionary(grouping: allRows, by: \.id).sorted(by: { $0.key < $1.key }) {
            // The same id twice is one recording; its canonical copy is kept (A26).
            let ordered = same.sorted { Self.rank($0.trashedAt, url(of: $0)?.lastPathComponent ?? $0.fileName) < Self.rank($1.trashedAt, url(of: $1)?.lastPathComponent ?? $1.fileName) }
            rows.append(ordered[0])
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
        var toQuarantine: [(url: URL, sha256: String)] = []
        func quarantine(_ file: DiskFile) {
            if let sha = file.sha256 { toQuarantine.append((file.url, sha)) }
        }
        for extra in extras {
            if let file = located(extra), !claimed.contains(file.path) {
                claimed.insert(file.path)
                quarantine(file)
            }
            context.delete(extra)
        }
        let rowsById = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }

        // 3. Files no row holds.
        var result = Result()
        var detaches: [RecordingFiles.PendingMoves.Detach] = []
        var candidates: [(row: Recording, file: DiskFile)] = []
        for file in pass.live + pass.trash where !claimed.contains(file.path) {
            if file.oversized {
                result.oversizedCount += 1
                result.oversizedFiles.append(file.url)
                continue
            }
            // A path this device verified for a recording counts as that recording's
            // only while its bytes (hashed now, finding 3) are the same; other bytes
            // are a recording of their own.
            if file.trashedAt == nil, allowRemovals, let mirror = known[file.path], mirror.sha256 == file.sha256 {
                if rowsById[mirror.id] != nil {
                    // A second copy of a recording held elsewhere.
                    quarantine(file)
                } else {
                    // Its row was removed on another device: to the recordings Trash, or
                    // to quarantine when a deletion of it wins here by time (A28).
                    let covered = deletions.contains { $0.covers(projectId: file.projectId, recordingId: mirror.id, sha256: file.sha256 ?? "", at: Date(millisecondsSince1970: mirror.at)) }
                    if covered {
                        quarantine(file)
                    } else {
                        detaches.append(.init(recordingId: mirror.id, source: file.path,
                                              destination: RecordingFiles.canonicalPath(detachDestination(for: file)), sha256: mirror.sha256))
                    }
                }
                continue
            }
            guard (try? SyncIdentity.validateFileName(file.fileName)) != nil else { continue }
            // Past this pass's memory budget: adopted by the next pass.
            guard file.audio != nil else { continue }
            candidates.append((try adopt(file), file))
        }

        // 4. One identity is one recording (A26). All copies of it, and its row if
        //    there is one, are gathered; its precedence time is the row's, or the
        //    earliest time among the copies (first-seen for a copy without one); the
        //    canonical copy is chosen (a live copy first, else the newest Trash
        //    time, ties by file name).
        var newRows: [Recording] = []
        var copiesOf: [ObjectIdentifier: [DiskFile]] = [:]
        for (id, group) in Dictionary(grouping: candidates, by: { $0.row.id }).sorted(by: { $0.key < $1.key }) {
            let ordered = group.sorted { Self.rank($0.file.trashedAt, $0.file.url.lastPathComponent) < Self.rank($1.file.trashedAt, $1.file.url.lastPathComponent) }
            let best = ordered[0]
            if let existing = rowsById[id] {
                let current = location[ObjectIdentifier(existing)]
                let currentName = (current?.url ?? url(of: existing))?.lastPathComponent ?? existing.fileName
                if Self.rank(existing.trashedAt, currentName) <= Self.rank(best.file.trashedAt, best.file.url.lastPathComponent) {
                    copiesOf[ObjectIdentifier(existing), default: []] += group.map(\.file)
                    continue
                }
                if let current { copiesOf[ObjectIdentifier(existing), default: []].append(current) }
                existing.fileName = best.row.fileName
                existing.trashedAt = best.row.trashedAt
                location[ObjectIdentifier(existing)] = best.file
                copiesOf[ObjectIdentifier(existing), default: []] += ordered.dropFirst().map(\.file)
            } else {
                best.row.uploadedAt = group.compactMap(\.row.uploadedAt).min()
                location[ObjectIdentifier(best.row)] = best.file
                copiesOf[ObjectIdentifier(best.row), default: []] += ordered.dropFirst().map(\.file)
                newRows.append(best.row)
            }
        }

        // 5. Deletions are resolved once, by time against the fixed precedence time.
        //    A song deletion leaves each recording its own tombstone in this save; the
        //    audio and every copy go to quarantine.
        var kept: [Recording] = []
        for row in rows + newRows {
            let copies = copiesOf[ObjectIdentifier(row)] ?? []
            guard let tombstone = deletions.first(where: { $0.covers(projectId: row.projectId, recordingId: row.id, sha256: row.sha256, at: row.precedenceTime) }) else {
                kept.append(row)
                copies.forEach(quarantine)
                continue
            }
            if tombstone.isSongTombstone {
                try DeletionStore.upsert(SyncDeletion(projectId: row.projectId, recordingId: row.id, fileName: row.fileName, deletedAt: tombstone.deletedAt), in: context)
            }
            if let file = location[ObjectIdentifier(row)] { quarantine(file) }
            copies.forEach(quarantine)
            if rowsById[row.id] === row { context.delete(row) }
        }
        for row in newRows where kept.contains(where: { $0 === row }) { context.insert(row) }

        // A35: claims accepted from the manifest by a backup are taken here.
        let adoptions = claimAdoptions
        var adoptedClaims: [String] = []
        for row in kept where adoptions[row.id] != nil {
            if row.claim != adoptions[row.id]! { row.claimedName = adoptions[row.id]! }
            adoptedClaims.append(row.id)
        }

        // 6. Names converge (A30): within a song, the earliest recording claiming a
        //    name (ties by the smaller id) gets it; the others are allocated
        //    "<claim stem> 2<ext>", 3, … in that order. A function of the set of
        //    claims, not of the order they arrived in.
        let reserved = Set(pass.live.filter(\.oversized).map { "\($0.projectId)/\($0.fileName)" })
        for (projectId, songRows) in Dictionary(grouping: kept.filter { $0.trashedAt == nil }, by: \.projectId) {
            let ordered = songRows.sorted { ($0.precedenceTime, $0.id) < ($1.precedenceTime, $1.id) }
            func usable(_ name: String, _ taken: Set<String>) -> Bool {
                !taken.contains(name) && !reserved.contains("\(projectId)/\(name)") && (try? SyncIdentity.validateFileName(name)) != nil
            }
            var taken = Set<String>()
            var allocated: [ObjectIdentifier: String] = [:]
            for row in ordered where usable(row.claim, taken) {
                taken.insert(row.claim)
                allocated[ObjectIdentifier(row)] = row.claim
            }
            for row in ordered where allocated[ObjectIdentifier(row)] == nil {
                var number = 2
                var name = RecordingFiles.numberedName(row.claim, number)
                while !usable(name, taken) {
                    number += 1
                    guard number < 1000 else { throw RecordingLibraryError.noFreeName }
                    name = RecordingFiles.numberedName(row.claim, number)
                }
                taken.insert(name)
                allocated[ObjectIdentifier(row)] = name
            }
            for row in ordered where row.fileName != allocated[ObjectIdentifier(row)] { row.fileName = allocated[ObjectIdentifier(row)]! }
        }

        // 7. The plan: each row's audio moves from where it is to its place, or is
        //    written from the row. The row records where its audio is now.
        var moves: [(row: Recording, from: DiskFile, to: URL)] = []
        var writes: [(row: Recording, to: URL)] = []
        var verified: [(row: Recording, file: (size: Int64, modified: Date, inode: UInt64))] = []
        for row in kept {
            guard let target = url(of: row) else { continue }
            if let source = location[ObjectIdentifier(row)] {
                if source.path == RecordingFiles.canonicalPath(target) {
                    if row.pendingFrom != nil { row.pendingFrom = nil }
                    verified.append((row, (source.size, source.modified, source.inode)))
                } else {
                    row.pendingFrom = source.url.path
                    moves.append((row, source, target))
                }
            } else {
                if row.pendingFrom != nil { row.pendingFrom = nil }
                writes.append((row, target))
            }
        }

        // A move relies on ownership, so its source's digest must be fresh, not cached.
        let cachedSources = Set(moves.filter(\.from.fromCache).map(\.from.path))
        if !cachedSources.isEmpty { throw Replan.freshDigests(cachedSources) }

        // 8. Commit the rows with the moves recorded, then move files.
        var fresh: [String: DiskFile] = [:]
        for file in pass.live + pass.trash + pass.sources + pass.recorded where !file.fromCache { fresh[file.path] = file }
        try saveRecordingMoves(quarantine: toQuarantine, detach: detaches, in: context, fresh: fresh) { try save(context) }
        // Moves go through a parking folder so a swap of names never overwrites.
        let parking = RecordingFiles.parkingRoot(for: memosRoot)
        if !moves.isEmpty { try FileManager.default.createDirectory(at: parking, withIntermediateDirectories: true) }
        aboutToMove(moves.map(\.from.url))
        var parked: [(row: Recording, at: URL, to: URL)] = []
        for move in moves {
            let spot = parking.appendingPathComponent("\(UUID().uuidString.lowercased()).\(move.from.url.pathExtension)")
            try FileManager.default.moveItem(at: move.from.url, to: spot)
            move.row.pendingFrom = spot.path
            parked.append((move.row, spot, move.to))
        }
        if !parked.isEmpty { try save(context) }
        for item in parked {
            // Something took its place meanwhile: it stays parked, recorded, for the next run.
            guard try !RecordingFiles.exists(item.to) else { continue }
            try FileManager.default.createDirectory(at: item.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: item.at, to: item.to)
            item.row.pendingFrom = nil
            verified.append((item.row, try RecordingFiles.facts(item.to)))
        }
        if context.hasChanges { try save(context) }
        return Plan(result: result, verified: verified, writes: writes, adopted: newRows.count, adoptedClaims: adoptedClaims)
    }

    /// Where a file of a recording removed on another device goes in the Trash.
    private func detachDestination(for file: DiskFile) -> URL {
        let folder = trashRoot.appendingPathComponent(file.projectId, isDirectory: true)
        var stamp = Date().epochMilliseconds
        var destination = folder.appendingPathComponent("\(stamp)\(RecordingFiles.trashNameSeparator)\(file.fileName)")
        while (try? RecordingFiles.exists(destination)) != false {
            stamp += 1
            destination = folder.appendingPathComponent("\(stamp)\(RecordingFiles.trashNameSeparator)\(file.fileName)")
        }
        return destination
    }

    /// A file no row holds, from the bytes the read pass verified: the id every
    /// device derives for it and its file time, or the time it was first seen when
    /// the file has none (A20/A21/A32).
    private func adopt(_ file: DiskFile) throws -> Recording {
        guard let sha = file.sha256, let audio = file.audio else { throw RecordingLibraryError.scanFailed }
        let id = RecordingBackupManifest.legacyRecordingId(projectId: file.projectId, fileName: file.fileName, sha256: sha)
        let time = file.modified.epochMilliseconds > 0 ? file.modified : firstSeen(id)
        let row = Recording(id: id, projectId: file.projectId, fileName: file.fileName, audio: audio, recordedAt: time, uploadedAt: time, sha256: sha)
        row.trashedAt = file.trashedAt.map { Date(millisecondsSince1970: $0.epochMilliseconds) }
        return row
    }

    /// Moves to quarantine and detached Trash moves are recorded, each with the
    /// digest it was decided on, before the save that decides them; made after it,
    /// and finished at the next run if interrupted (A28, finding 4).
    func saveRecordingMoves(quarantine files: [(url: URL, sha256: String)], detach: [RecordingFiles.PendingMoves.Detach] = [], in context: ModelContext,
                            fresh: [String: DiskFile]? = nil, save: () throws -> Void) throws {
        let before = try RecordingFiles.readPendingMoves(for: memosRoot)
        var moves = before
        var paths = Set(before.quarantine.map(\.path))
        for file in files where paths.insert(RecordingFiles.canonicalPath(file.url)).inserted {
            moves.quarantine.append(.init(path: RecordingFiles.canonicalPath(file.url), sha256: file.sha256))
        }
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
    /// recording's digest; the record keeps that place so it is never adopted.
    /// Other bytes drop the record (they are adopted on their own). Anything not
    /// freshly read stays recorded for the next run.
    func finishPendingMoves(in context: ModelContext, fresh: [String: DiskFile]) {
        guard var moves = try? RecordingFiles.readPendingMoves(for: memosRoot), moves != RecordingFiles.PendingMoves(),
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
                try RecordingFiles.quarantine(file, memosRoot: memosRoot)
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
                        guard try !RecordingFiles.exists(destination) else { return entry }
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: source, to: destination)
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
        try? RecordingFiles.writePendingMoves(moves, for: memosRoot)
    }

    private static func isRow(_ row: Recording, of memo: TrashedVoiceMemo) -> Bool {
        row.projectId == memo.projectId && row.fileName == memo.originalName
            && row.trashedAt?.epochMilliseconds == memo.deletedAt.epochMilliseconds
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

    /// The row a live file belongs to, by its name and verified bytes.
    private func verifiedRow(at url: URL, in context: ModelContext) throws -> Recording? {
        let projectId = url.deletingLastPathComponent().lastPathComponent
        let name = url.lastPathComponent
        guard let row = try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.projectId == projectId && $0.fileName == name && $0.trashedAt == nil }) else {
            return nil
        }
        guard try RecordingFiles.sha256(of: url) == row.sha256 else { throw RecordingLibraryError.notVerified }
        return row
    }

    /// Permanent deletion of a Trash entry: after the complete check, the id of the
    /// recording its current bytes are (its row's when they match, else the id
    /// derived for them). A row whose file holds other bytes fails, before anything
    /// changes (finding 1).
    func identityForDeletion(of trashed: TrashedVoiceMemo, in context: ModelContext) throws -> (id: String, row: Recording?) {
        try requireChecked(context)
        let digest = try RecordingFiles.sha256(of: trashed.url)
        let candidates = try context.fetch(FetchDescriptor<Recording>()).filter { Self.isRow($0, of: trashed) }
        if let row = candidates.first(where: { $0.sha256 == digest }) { return (row.id, row) }
        guard candidates.isEmpty else { throw RecordingLibraryError.notVerified }
        // A recording removed on another device keeps its own id here (finding 2).
        let path = RecordingFiles.canonicalPath(trashed.url)
        if let entry = try RecordingFiles.readPendingMoves(for: memosRoot).detach.first(where: { $0.destination == path }) {
            guard entry.sha256 == digest else { throw RecordingLibraryError.notVerified }
            return (entry.recordingId, nil)
        }
        return (RecordingBackupManifest.legacyRecordingId(projectId: trashed.projectId, fileName: trashed.originalName, sha256: digest), nil)
    }

    /// Permanent deletion of a whole song: after the complete check, every file in
    /// its memo and Trash folders must be a row's verified bytes, a file over the
    /// cap, or a Trash entry of a recording removed elsewhere; anything else (bytes
    /// not yet checked) fails before anything changes (finding 1).
    func checkSongDeletable(_ projectId: String, in context: ModelContext) throws {
        try requireChecked(context)
        let rows = try context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == projectId }
        let held = Dictionary(rows.compactMap { row in url(of: row).map { (RecordingFiles.canonicalPath($0), row.sha256) } }) { first, _ in first }
        let detached = Dictionary(try RecordingFiles.readPendingMoves(for: memosRoot).detach.map { ($0.destination, $0.sha256) }) { first, _ in first }
        var files: [URL] = []
        let live = try RecordingFiles.projectURL(projectId: projectId, memosRoot: memosRoot)
        if try RecordingFiles.exists(live) {
            files += try FileManager.default.contentsOfDirectory(at: live, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        }
        let trash = trashRoot.appendingPathComponent(projectId, isDirectory: true)
        if try RecordingFiles.exists(trash) {
            files += try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        }
        for file in files {
            let path = RecordingFiles.canonicalPath(file)
            if let sha = detached[path] {
                // A recording removed elsewhere: only while it still holds its bytes (finding 1).
                guard try RecordingFiles.sha256(of: file) == sha else { throw RecordingLibraryError.notVerified }
                continue
            }
            if try RecordingFiles.facts(file).size > SyncRecording.maxBytes { continue }
            guard let sha = held[path], try RecordingFiles.sha256(of: file) == sha else { throw RecordingLibraryError.notVerified }
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
        let folder = try RecordingFiles.projectURL(projectId: projectId, memosRoot: memosRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let finished = finishedAt.map { Date(millisecondsSince1970: $0.epochMilliseconds) } ?? Date(millisecondsSince1970: Date().epochMilliseconds)
        guard try RecordingFiles.facts(staged).size <= SyncRecording.maxBytes else {
            // Too large for iCloud and Drive: it stays a local file. Its id, time and
            // move are journalled before it moves, and marked done after (finding 4).
            let target = RecordingFiles.restoredURL(originalName: preferredName, folder: folder)
            try SyncIdentity.validateFileName(target.lastPathComponent)
            let takeId = id ?? UUID().uuidString.lowercased()
            let entry = OversizedRecordings.Entry(projectId: projectId, fileName: target.lastPathComponent, finishedAt: finished.epochMilliseconds,
                                                  source: staged.path, completed: false, sha256: try RecordingFiles.sha256(of: staged))
            try OversizedRecordings.record(id: takeId, entry: entry, for: memosRoot)
            return try finishOversized(id: takeId, entry: entry)
        }
        let audio = try Data(contentsOf: staged)
        let name = try freeName(preferredName, projectId: projectId, taken: liveNames(projectId: projectId, in: context))
        let row = Recording(id: id ?? UUID().uuidString.lowercased(), projectId: projectId, fileName: name, audio: audio,
                            recordedAt: finished, uploadedAt: finished, origin: origin)
        row.claimedName = preferredName
        return try commit(row, movingFrom: staged, in: context)
    }

    /// Completes a journalled oversized publication: the destination must hold the
    /// file before it counts as published; an interrupted move is finished.
    private func finishOversized(id: String, entry: OversizedRecordings.Entry) throws -> URL {
        var entry = entry
        var target = try RecordingFiles.localURL(projectId: entry.projectId, fileName: entry.fileName, memosRoot: memosRoot)
        func holdsTake(_ url: URL) throws -> Bool {
            guard try RecordingFiles.exists(url) else { return false }
            guard let sha = entry.sha256 else { return true }
            return try RecordingFiles.sha256(of: url) == sha
        }
        if entry.completed == false {
            if try !holdsTake(target) {
                guard let source = entry.source.map({ URL(fileURLWithPath: $0) }), try RecordingFiles.exists(source) else {
                    throw RecordingLibraryError.takeMissing
                }
                if try RecordingFiles.exists(target) {
                    // Another file took the place: the take gets the next free name, journalled first.
                    target = RecordingFiles.restoredURL(originalName: entry.fileName, folder: target.deletingLastPathComponent())
                    try SyncIdentity.validateFileName(target.lastPathComponent)
                    entry.fileName = target.lastPathComponent
                    try OversizedRecordings.record(id: id, entry: entry, for: memosRoot)
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: target)
            }
            entry.completed = true
            entry.source = nil
            try OversizedRecordings.record(id: id, entry: entry, for: memosRoot)
        }
        // Published only when its own bytes are in place (finding 4).
        guard try holdsTake(target) else { throw RecordingLibraryError.takeMissing }
        return target
    }

    /// Restored or imported audio: written only if this device has neither the
    /// id nor a newer tombstone for it, with the backup's time. It claims its
    /// claimed name (A34); when its allocated name is held, its audio is parked and
    /// the run that follows every restore and import settles the name (A30). The
    /// bytes must match the entry's hash and declared size, within the cap.
    @discardableResult
    func commitRestored(_ audio: Data, entry: SyncRecording, origin: Recording.Origin, context: ModelContext) throws -> Bool {
        guard Int64(audio.count) == entry.bytes, RecordingBackupManifest.sha256Hex(audio) == entry.sha256 else {
            throw SyncValidationError.invalidRecording
        }
        try requireChecked(context)
        guard Int64(audio.count) <= SyncRecording.maxBytes,
              try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == entry.id }) == nil,
              // A deletion made here while the restore ran wins if it is newer.
              try !DeletionStore.all(in: context).contains(where: { $0.covers(entry) }) else { return false }
        let staging = RecordingFiles.stagingRoot(for: memosRoot)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        try audio.write(to: staged, options: .atomic)
        guard let written = try? Data(contentsOf: staged), written.count == audio.count,
              RecordingBackupManifest.sha256Hex(written) == entry.sha256 else { throw SyncValidationError.invalidRecording }
        let row = Recording(id: entry.id, projectId: entry.projectId, fileName: entry.fileName, audio: audio,
                            recordedAt: entry.uploadedAt, uploadedAt: entry.uploadedAt, origin: origin, sha256: entry.sha256)
        // A restored recording claims its claimed name, never its allocated one (A34).
        row.claimedName = entry.claim
        if try liveNames(projectId: entry.projectId, in: context).contains(entry.fileName) {
            let parking = RecordingFiles.parkingRoot(for: memosRoot)
            try FileManager.default.createDirectory(at: parking, withIntermediateDirectories: true)
            let spot = parking.appendingPathComponent("\(UUID().uuidString.lowercased()).\((entry.fileName as NSString).pathExtension)")
            try FileManager.default.moveItem(at: staged, to: spot)
            row.pendingFrom = spot.path
            context.insert(row)
            do {
                try save(context)
            } catch {
                context.rollback()
                try? FileManager.default.removeItem(at: spot)
                throw error
            }
            return true
        }
        row.fileName = try freeName(entry.fileName, projectId: entry.projectId, taken: [])
        _ = try commit(row, movingFrom: staged, in: context)
        return true
    }

    func renameRecording(at url: URL, to target: URL) throws {
        try SyncIdentity.validateFileName(target.lastPathComponent)
        guard let context else { throw RecordingLibraryError.unavailable }
        try requireChecked(context)
        if RecordingFiles.canonicalPath(url) == RecordingFiles.canonicalPath(target) {
            // The allocated name chosen on purpose: it becomes the claim, with no
            // file move (A35).
            guard let row = try verifiedRow(at: url, in: context), row.claimedName != target.lastPathComponent else { return }
            claimAdoptions[row.id] = nil
            let previous = row.claimedName
            row.claimedName = target.lastPathComponent
            do {
                try save(context)
            } catch {
                row.claimedName = previous
                throw error
            }
            return
        }
        guard let row = try verifiedRow(at: url, in: context) else {
            aboutToMove([url])
            try FileManager.default.moveItem(at: url, to: target)
            try OversizedRecordings.renamed(from: url, to: target, for: memosRoot)
            return
        }
        claimAdoptions[row.id] = nil
        let previous = (row.fileName, row.claimedName)
        row.fileName = target.lastPathComponent
        row.claimedName = target.lastPathComponent
        try recordIntent(row, from: url, in: context) { (row.fileName, row.claimedName) = previous }
    }

    func trashRecording(at url: URL, to trashURL: URL, trashedAt: Date) throws {
        guard let context else { throw RecordingLibraryError.unavailable }
        try requireChecked(context)
        guard let row = try verifiedRow(at: url, in: context) else {
            aboutToMove([url])
            try FileManager.default.moveItem(at: url, to: trashURL)
            return
        }
        row.trashedAt = Date(millisecondsSince1970: trashedAt.epochMilliseconds)
        try recordIntent(row, from: url, in: context) { row.trashedAt = nil }
    }

    func untrashRecording(_ trashed: TrashedVoiceMemo, to target: URL) throws {
        // Validated before anything changes.
        try SyncIdentity.validateFileName(target.lastPathComponent)
        guard let context else { throw RecordingLibraryError.unavailable }
        try requireChecked(context)
        let facts = try RecordingFiles.facts(trashed.url)
        let digest = facts.size <= SyncRecording.maxBytes ? try RecordingFiles.sha256(of: trashed.url) : nil
        var row = try context.fetch(FetchDescriptor<Recording>()).first { Self.isRow($0, of: trashed) && $0.sha256 == digest }
        if row == nil {
            guard let digest else {
                aboutToMove([trashed.url])
                try FileManager.default.moveItem(at: trashed.url, to: target)
                return
            }
            // A Trash entry from before v4 is adopted (derived id, its file date) before it moves.
            let file = DiskFile(url: trashed.url, path: RecordingFiles.canonicalPath(trashed.url), projectId: trashed.projectId, fileName: trashed.originalName,
                                trashedAt: trashed.deletedAt, size: facts.size, modified: facts.modified, inode: facts.inode, sha256: digest,
                                fromCache: false, audio: try Data(contentsOf: trashed.url))
            guard RecordingBackupManifest.sha256Hex(file.audio ?? Data()) == digest else { throw RecordingLibraryError.notVerified }
            let adopted = try adopt(file)
            guard try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == adopted.id }) == nil else {
                aboutToMove([trashed.url])
                try FileManager.default.moveItem(at: trashed.url, to: target)
                return
            }
            context.insert(adopted)
            row = adopted
        }
        guard let row else { return }
        let previous = (row.trashedAt, row.fileName, row.claimedName)
        row.trashedAt = nil
        row.fileName = target.lastPathComponent
        row.claimedName = target.lastPathComponent
        try recordIntent(row, from: trashed.url, in: context) { (row.trashedAt, row.fileName, row.claimedName) = previous }
    }

    /// Song deletion: each of its recordings older than the deletion gets its own
    /// tombstone by id, in the caller's transaction, and its row goes.
    static func tombstoneRecordings(ofProject projectId: String, deletedAt: Int64, in context: ModelContext) throws -> [Recording] {
        let rows = try context.fetch(FetchDescriptor<Recording>()).filter {
            $0.projectId == projectId && $0.precedenceTime.epochMilliseconds < deletedAt
        }
        for row in rows {
            try DeletionStore.upsert(SyncDeletion(projectId: projectId, recordingId: row.id, fileName: row.fileName, deletedAt: deletedAt), in: context)
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
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            aboutToMove([source])
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            revert()
            row.pendingFrom = nil
            try? save(context)
            throw error
        }
        markVerified(row, removing: source)
        row.pendingFrom = nil
        do { try save(context) } catch { throw RecordingLibraryError.finalizeFailed }
    }

    /// Publishes a new row's staged audio. Each destination is saved before the
    /// move is tried; a name taken meanwhile gets the next free one, saved again.
    /// A failure before the move removes the row; after it, the row stands (A31).
    private func commit(_ row: Recording, movingFrom staged: URL, in context: ModelContext) throws -> URL {
        context.insert(row)
        row.pendingFrom = staged.path
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        for _ in 0..<100 {
            guard let target = url(of: row) else { break }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: staged, to: target)
            } catch CocoaError.fileWriteFileExists {
                row.fileName = try freeName(row.fileName, projectId: row.projectId, taken: try liveNames(projectId: row.projectId, in: context).union([row.fileName]))
                try save(context)
                continue
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
        context.delete(row)
        try? save(context)
        throw RecordingLibraryError.noFreeName
    }

    private func liveNames(projectId: String, in context: ModelContext) throws -> Set<String> {
        Set(try context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == projectId && $0.trashedAt == nil }.map(\.fileName))
    }

    /// `preferred`, or "name 2.ext", "name 3.ext"… within the name limit: free on
    /// disk and among live rows.
    private func freeName(_ preferred: String, projectId: String, taken: Set<String>) throws -> String {
        let folder = try RecordingFiles.projectURL(projectId: projectId, memosRoot: memosRoot)
        func isFree(_ name: String) throws -> Bool {
            try !taken.contains(name) && !RecordingFiles.exists(folder.appendingPathComponent(name))
        }
        if try isFree(preferred), (try? SyncIdentity.validateFileName(preferred)) != nil { return preferred }
        for suffix in 2..<1000 {
            let candidate = RecordingFiles.numberedName(preferred, suffix)
            if try isFree(candidate), (try? SyncIdentity.validateFileName(candidate)) != nil { return candidate }
        }
        throw RecordingLibraryError.noFreeName
    }

    /// Every live and Trash file over the cap, listed off the main actor (A29).
    func oversizedInventory() async throws -> [URL] {
        let memosRoot = memosRoot
        let trashRoot = trashRoot
        return try await Task.detached(priority: .utility) {
            var files: [URL] = []
            if try RecordingFiles.exists(memosRoot) {
                files += try Self.liveListing(memosRoot).map(\.2)
            }
            files += try RecordingFiles.readableTrashedMemos(in: trashRoot).map(\.url)
            return try files.filter { try RecordingFiles.facts($0).size > SyncRecording.maxBytes }
        }.value
    }
}

/// Ids, names and finish times of recordings over the cap, which have no row
/// (finding 6): a take keeps its identity and publication through a crash. A
/// publication is journalled (its source, not yet completed) before the move.
enum OversizedRecordings {
    struct Entry: Codable, Equatable {
        var projectId: String
        var fileName: String
        var finishedAt: Int64
        /// The staged file while the move is under way.
        var source: String?
        /// False until the file is in place; nil (older entries) means done.
        var completed: Bool?
        /// The take's digest: an existing destination counts only if it holds these bytes.
        var sha256: String?
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
        try JSONEncoder().encode(entries).write(to: url(for: memosRoot), options: .atomic)
    }

    /// Keeps an entry's name when its file is renamed.
    static func renamed(from old: URL, to new: URL, for memosRoot: URL) throws {
        var entries = try read(for: memosRoot)
        let projectId = old.deletingLastPathComponent().lastPathComponent
        guard let id = entries.first(where: { $0.value.projectId == projectId && $0.value.fileName == old.lastPathComponent })?.key else { return }
        entries[id]?.fileName = new.lastPathComponent
        try JSONEncoder().encode(entries).write(to: url(for: memosRoot), options: .atomic)
    }
}
