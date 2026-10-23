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

    init(id: String = UUID().uuidString.lowercased(), projectId: String, fileName: String, audio: Data, recordedAt: Date,
         uploadedAt: Date? = nil, origin: Origin = .recorded) {
        self.id = id
        self.projectId = projectId
        self.fileName = fileName
        self.claimedName = fileName
        self.audio = audio
        self.bytes = Int64(audio.count)
        self.sha256 = RecordingBackupManifest.sha256Hex(audio)
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
/// A run reads every folder, file and move record off the main actor (hashing
/// files; a digest cache keyed by path, size, date and inode only skips
/// re-hashing a file a row already holds), then, on the main actor, checks
/// that nothing changed since the read before committing. Only a row's id and
/// verified bytes place its audio. Files no row holds are adopted with the id
/// every device derives for them; copies of one identity are one recording
/// whose precedence time is fixed before any tombstone is compared (A26, A32).
/// Names in a song converge (A30). Rows are saved before files move; moves go
/// through a parking folder; moves to quarantine or to the recordings Trash
/// are recorded before the save that decides them. Changes made outside a run
/// require the last run to have succeeded and the tombstones and move record
/// to read now (A33).
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

    /// Digests of files rows hold, by path; a hint to skip re-hashing, never proof.
    nonisolated struct CachedDigest: Sendable, Equatable {
        let size: Int64
        let modified: Double
        let inode: UInt64
        let sha256: String
    }

    private var digestCache: [String: CachedDigest] {
        get {
            let raw = defaults.dictionary(forKey: Self.digestCacheKey) as? [String: [String: Any]] ?? [:]
            return raw.compactMapValues { entry in
                guard let size = (entry["size"] as? NSNumber)?.int64Value, let modified = (entry["modified"] as? NSNumber)?.doubleValue,
                      let inode = (entry["inode"] as? NSNumber)?.uint64Value, let sha = entry["sha256"] as? String else { return nil }
                return CachedDigest(size: size, modified: modified, inode: inode, sha256: sha)
            }
        }
        set {
            defaults.set(newValue.mapValues {
                ["size": NSNumber(value: $0.size), "modified": NSNumber(value: $0.modified), "inode": NSNumber(value: $0.inode), "sha256": $0.sha256] as [String: Any]
            }, forKey: Self.digestCacheKey)
        }
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
    nonisolated struct DiskFile: Sendable, Equatable {
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
        var oversized: Bool { sha256 == nil }
    }

    nonisolated struct ReadRequest: Sendable {
        let memosRoot: URL
        let trashRoot: URL
        let abortingIfMissing: Bool
        let cache: [String: CachedDigest]
        let sources: [(path: String, projectId: String, fileName: String)]
    }

    nonisolated struct ReadPass: Sendable {
        let moves: RecordingFiles.PendingMoves
        let live: [DiskFile]
        let trash: [DiskFile]
        /// Pending sources outside the scanned folders (staging, parking).
        let sources: [DiskFile]
    }

    nonisolated private static func inspect(_ url: URL, projectId: String, fileName: String, trashedAt: Date?,
                                            cache: [String: CachedDigest]) throws -> DiskFile {
        let facts = try RecordingFiles.facts(url)
        let path = RecordingFiles.canonicalPath(url)
        var digest: String?
        if facts.size <= SyncRecording.maxBytes {
            if let hint = cache[path], hint.size == facts.size, hint.inode == facts.inode,
               hint.modified == facts.modified.timeIntervalSince1970 {
                digest = hint.sha256
            } else {
                digest = try RecordingFiles.sha256(of: url)
            }
        }
        return DiskFile(url: url, path: path, projectId: projectId, fileName: fileName, trashedAt: trashedAt,
                        size: facts.size, modified: facts.modified, inode: facts.inode, sha256: digest)
    }

    /// Every read of a run. Any failure throws: a failed read must never look
    /// like a missing recording.
    nonisolated private static func read(_ request: ReadRequest) throws -> ReadPass {
        let moves = try RecordingFiles.readPendingMoves(for: request.memosRoot)
        let hidden = moves.adoptionHidden
        var live: [DiskFile] = []
        if try RecordingFiles.exists(request.memosRoot) {
            for (projectId, fileName, url) in try liveListing(request.memosRoot) where !hidden.contains(RecordingFiles.canonicalPath(url)) {
                live.append(try inspect(url, projectId: projectId, fileName: fileName, trashedAt: nil, cache: request.cache))
            }
        } else if request.abortingIfMissing {
            throw RecordingLibraryError.scanFailed
        }
        var trash: [DiskFile] = []
        for memo in try RecordingFiles.readableTrashedMemos(in: request.trashRoot) where !hidden.contains(RecordingFiles.canonicalPath(memo.url)) {
            trash.append(try inspect(memo.url, projectId: memo.projectId, fileName: memo.originalName, trashedAt: memo.deletedAt, cache: request.cache))
        }
        let known = Set((live + trash).map(\.path))
        var sources: [DiskFile] = []
        for source in request.sources where !known.contains(source.path) && !hidden.contains(source.path) {
            let url = URL(fileURLWithPath: source.path)
            if try RecordingFiles.exists(url) {
                sources.append(try inspect(url, projectId: source.projectId, fileName: source.fileName, trashedAt: nil, cache: request.cache))
            }
        }
        return ReadPass(moves: moves, live: live.sorted { $0.path < $1.path }, trash: trash.sorted { $0.path < $1.path }, sources: sources)
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
        for file in pass.live + pass.trash + pass.sources {
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
            for _ in 0..<3 {
                let rows = try context.fetch(FetchDescriptor<Recording>())
                let request = ReadRequest(
                    memosRoot: memosRoot, trashRoot: trashRoot, abortingIfMissing: !mirrored.isEmpty, cache: digestCache,
                    sources: rows.compactMap { row in row.pendingFrom.map { (RecordingFiles.canonicalPath(URL(fileURLWithPath: $0)), row.projectId, row.fileName) } }
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
                guard try stillAsRead(pass) else { continue }
                let result = try commit(pass, context: context)
                lastRunSucceeded = true
                return result
            }
            throw RecordingLibraryError.scanFailed
        } catch {
            context.rollback()
            lastRunSucceeded = false
            throw error
        }
    }

    private func commit(_ pass: ReadPass, context: ModelContext) throws -> Result {
        // An in-memory library is empty at every launch; treating its missing rows
        // as removals would trash every memo, so it only ever adds.
        let allowRemovals = !context.container.configurations.contains { $0.isStoredInMemoryOnly }
        let known = mirrored
        // Tombstones are read before anything else; a failed read stops the run (A33).
        let deletions = try DeletionStore.all(in: context)
        let allRows = try context.fetch(FetchDescriptor<Recording>()).sorted { $0.id < $1.id }
        let now = Date(millisecondsSince1970: Date().epochMilliseconds)

        // 1. Precedence times are fixed before anything is compared (A32).
        for row in allRows where (row.uploadedAt?.epochMilliseconds ?? 0) <= 0 { row.uploadedAt = now }

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
        var toQuarantine: [URL] = []
        for extra in extras {
            if let file = located(extra), !claimed.contains(file.path) {
                claimed.insert(file.path)
                toQuarantine.append(file.url)
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
            // only while its bytes are the same; other bytes are a recording of their own.
            if file.trashedAt == nil, allowRemovals, let mirror = known[file.path], mirror.sha256 == file.sha256 {
                if rowsById[mirror.id] != nil {
                    // A second copy of a recording held elsewhere.
                    toQuarantine.append(file.url)
                } else {
                    // Its row was removed on another device: to the recordings Trash, or
                    // to quarantine when a deletion of it wins here by time (A28).
                    let covered = deletions.contains { $0.covers(projectId: file.projectId, recordingId: mirror.id, sha256: file.sha256 ?? "", at: Date(millisecondsSince1970: mirror.at)) }
                    if covered {
                        toQuarantine.append(file.url)
                    } else {
                        detaches.append(.init(recordingId: mirror.id, source: file.path, destination: RecordingFiles.canonicalPath(detachDestination(for: file))))
                    }
                }
                continue
            }
            guard (try? SyncIdentity.validateFileName(file.fileName)) != nil else { continue }
            candidates.append((try adopt(file), file))
        }

        // 4. One identity is one recording (A26). All copies of it, and its row if
        //    there is one, are gathered; its precedence time is the row's, or the
        //    earliest file time among the copies; the canonical copy is chosen
        //    (a live copy first, else the newest Trash time, ties by file name).
        var newRows: [Recording] = []
        var copiesOf: [ObjectIdentifier: [URL]] = [:]
        for (id, group) in Dictionary(grouping: candidates, by: { $0.row.id }).sorted(by: { $0.key < $1.key }) {
            let ordered = group.sorted { Self.rank($0.file.trashedAt, $0.file.url.lastPathComponent) < Self.rank($1.file.trashedAt, $1.file.url.lastPathComponent) }
            let best = ordered[0]
            if let existing = rowsById[id] {
                let current = location[ObjectIdentifier(existing)]
                let currentName = (current?.url ?? url(of: existing))?.lastPathComponent ?? existing.fileName
                if Self.rank(existing.trashedAt, currentName) <= Self.rank(best.file.trashedAt, best.file.url.lastPathComponent) {
                    copiesOf[ObjectIdentifier(existing), default: []] += group.map(\.file.url)
                    continue
                }
                if let current { copiesOf[ObjectIdentifier(existing), default: []].append(current.url) }
                existing.fileName = best.row.fileName
                existing.trashedAt = best.row.trashedAt
                location[ObjectIdentifier(existing)] = best.file
                copiesOf[ObjectIdentifier(existing), default: []] += ordered.dropFirst().map(\.file.url)
            } else {
                best.row.uploadedAt = group.compactMap(\.row.uploadedAt).min()
                location[ObjectIdentifier(best.row)] = best.file
                copiesOf[ObjectIdentifier(best.row), default: []] += ordered.dropFirst().map(\.file.url)
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
                toQuarantine += copies
                continue
            }
            if tombstone.isSongTombstone {
                try DeletionStore.upsert(SyncDeletion(projectId: row.projectId, recordingId: row.id, fileName: row.fileName, deletedAt: tombstone.deletedAt), in: context)
            }
            if let file = location[ObjectIdentifier(row)] { toQuarantine.append(file.url) }
            toQuarantine += copies
            if rowsById[row.id] === row { context.delete(row) }
        }
        for row in newRows where kept.contains(where: { $0 === row }) { context.insert(row) }

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
        var inPlace: [(row: Recording, file: DiskFile)] = []
        for row in kept {
            guard let target = url(of: row) else { continue }
            if let source = location[ObjectIdentifier(row)] {
                if source.path == RecordingFiles.canonicalPath(target) {
                    if row.pendingFrom != nil { row.pendingFrom = nil }
                    inPlace.append((row, source))
                } else {
                    row.pendingFrom = source.url.path
                    moves.append((row, source, target))
                }
            } else {
                if row.pendingFrom != nil { row.pendingFrom = nil }
                writes.append((row, target))
            }
        }

        // 8. Commit the rows with the moves recorded, then move files.
        try saveRecordingMoves(quarantine: toQuarantine, detach: detaches, in: context) { try save(context) }
        var verified: [(row: Recording, file: (size: Int64, modified: Date, inode: UInt64))] = inPlace.map { ($0.row, ($0.file.size, $0.file.modified, $0.file.inode)) }
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
        for write in writes {
            guard try !RecordingFiles.exists(write.to), RecordingBackupManifest.sha256Hex(write.row.audio) == write.row.sha256 else { continue }
            try RecordingFiles.commitIfAbsent(write.row.audio, sha256: write.row.sha256, to: write.to, memosRoot: memosRoot, modifiedAt: write.row.recordedAt)
            verified.append((write.row, try RecordingFiles.facts(write.to)))
        }
        if context.hasChanges { try save(context) }

        var paths: [String: Verified] = [:]
        var cache: [String: CachedDigest] = [:]
        for (row, facts) in verified {
            guard let target = url(of: row) else { continue }
            let path = RecordingFiles.canonicalPath(target)
            cache[path] = CachedDigest(size: facts.size, modified: facts.modified.timeIntervalSince1970, inode: facts.inode, sha256: row.sha256)
            if row.trashedAt == nil { paths[path] = Verified(id: row.id, at: row.precedenceTime.epochMilliseconds, sha256: row.sha256) }
        }
        mirrored = paths
        digestCache = cache
        oversizedCount = result.oversizedCount
        oversizedFiles = result.oversizedFiles
        return result
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

    /// A file no row holds: the id every device derives for it and its file time (A20/A21).
    private func adopt(_ file: DiskFile) throws -> Recording {
        let audio = try Data(contentsOf: file.url)
        // Changed since the read pass: the run stops rather than guess.
        guard RecordingBackupManifest.sha256Hex(audio) == file.sha256 else { throw RecordingLibraryError.scanFailed }
        let id = RecordingBackupManifest.legacyRecordingId(projectId: file.projectId, fileName: file.fileName, sha256: RecordingBackupManifest.sha256Hex(audio))
        let row = Recording(id: id, projectId: file.projectId, fileName: file.fileName, audio: audio, recordedAt: file.modified, uploadedAt: file.modified)
        row.trashedAt = file.trashedAt.map { Date(millisecondsSince1970: $0.epochMilliseconds) }
        return row
    }

    /// Moves to quarantine and detached Trash moves are recorded before the save
    /// that decides them, made after it, and finished at the next run if
    /// interrupted (A28, finding 4).
    func saveRecordingMoves(quarantine files: [URL], detach: [RecordingFiles.PendingMoves.Detach] = [], in context: ModelContext,
                            save: () throws -> Void) throws {
        let before = try RecordingFiles.readPendingMoves(for: memosRoot)
        var moves = before
        moves.quarantine = Array(Set(before.quarantine).union(files.map(RecordingFiles.canonicalPath))).sorted()
        moves.detach += detach
        if moves != before { try RecordingFiles.writePendingMoves(moves, for: memosRoot) }
        do {
            try save()
        } catch {
            if moves != before { try? RecordingFiles.writePendingMoves(before, for: memosRoot) }
            throw error
        }
        finishPendingMoves(in: context)
    }

    /// Finishes recorded moves. A file to quarantine goes unless it holds the audio
    /// of a row that still names it (its save never landed). A detached file goes
    /// to its Trash place; the record keeps that place so it is never adopted.
    /// Only confirmed absence ends a record; anything uncertain stays recorded.
    func finishPendingMoves(in context: ModelContext) {
        guard var moves = try? RecordingFiles.readPendingMoves(for: memosRoot), moves != RecordingFiles.PendingMoves(),
              let rows = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        let referenced = Dictionary(rows.compactMap { row in url(of: row).map { (RecordingFiles.canonicalPath($0), row.sha256) } }) { first, _ in first }
        aboutToMove((moves.quarantine + moves.detach.map(\.source).filter { !$0.isEmpty }).map { URL(fileURLWithPath: $0) })
        var remaining: [String] = []
        for path in moves.quarantine {
            let file = URL(fileURLWithPath: path)
            do {
                guard try RecordingFiles.exists(file) else { continue }
                if let sha = referenced[path], try RecordingFiles.sha256(of: file) == sha { continue }
                try RecordingFiles.quarantine(file, memosRoot: memosRoot)
            } catch {
                remaining.append(path)
            }
        }
        moves.quarantine = remaining
        moves.detach = moves.detach.compactMap { entry in
            var entry = entry
            do {
                if !entry.source.isEmpty {
                    let source = URL(fileURLWithPath: entry.source)
                    if try RecordingFiles.exists(source) {
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

    // MARK: Changes that record the row before the file moves

    /// The gate for every change made outside a run (A33): the last run succeeded,
    /// and the tombstones and the move record read now.
    private func requireChecked(_ context: ModelContext) throws {
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
            // An oversized take published earlier.
            return try RecordingFiles.localURL(projectId: entry.projectId, fileName: entry.fileName, memosRoot: memosRoot)
        }
        if id != nil, try !RecordingFiles.exists(staged) { throw RecordingLibraryError.takeMissing }
        let folder = try RecordingFiles.projectURL(projectId: projectId, memosRoot: memosRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let finished = finishedAt.map { Date(millisecondsSince1970: $0.epochMilliseconds) } ?? Date(millisecondsSince1970: Date().epochMilliseconds)
        guard try RecordingFiles.facts(staged).size <= SyncRecording.maxBytes else {
            // Too large for iCloud and Drive: it stays a local file, with its id and
            // time recorded before it moves (finding 6).
            let target = RecordingFiles.restoredURL(originalName: preferredName, folder: folder)
            try SyncIdentity.validateFileName(target.lastPathComponent)
            try OversizedRecordings.record(id: id ?? UUID().uuidString.lowercased(),
                                           entry: .init(projectId: projectId, fileName: target.lastPathComponent, finishedAt: finished.epochMilliseconds),
                                           for: memosRoot)
            try FileManager.default.moveItem(at: staged, to: target)
            return target
        }
        let audio = try Data(contentsOf: staged)
        let name = try freeName(preferredName, projectId: projectId, taken: liveNames(projectId: projectId, in: context))
        let row = Recording(id: id ?? UUID().uuidString.lowercased(), projectId: projectId, fileName: name, audio: audio,
                            recordedAt: finished, uploadedAt: finished, origin: origin)
        row.claimedName = preferredName
        return try commit(row, movingFrom: staged, in: context)
    }

    /// Restored or imported audio: written only if this device has neither the
    /// id nor a newer tombstone for it, with the backup's time. It claims its
    /// name; when that name is held, its audio is parked and the run that follows
    /// every restore and import settles the name (A30). The bytes must match the
    /// entry's hash and declared size, within the cap.
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
                            recordedAt: entry.uploadedAt, uploadedAt: entry.uploadedAt, origin: origin)
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
        guard let row = try verifiedRow(at: url, in: context) else {
            aboutToMove([url])
            try FileManager.default.moveItem(at: url, to: target)
            try OversizedRecordings.renamed(from: url, to: target, for: memosRoot)
            return
        }
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
        let digest = try RecordingFiles.facts(trashed.url).size <= SyncRecording.maxBytes ? try RecordingFiles.sha256(of: trashed.url) : nil
        var row = try context.fetch(FetchDescriptor<Recording>()).first { Self.isRow($0, of: trashed) && $0.sha256 == digest }
        if row == nil {
            guard let digest else {
                try FileManager.default.moveItem(at: trashed.url, to: target)
                return
            }
            // A Trash entry from before v4 is adopted (derived id, its file date) before it moves.
            let facts = try RecordingFiles.facts(trashed.url)
            let file = DiskFile(url: trashed.url, path: RecordingFiles.canonicalPath(trashed.url), projectId: trashed.projectId, fileName: trashed.originalName,
                                trashedAt: trashed.deletedAt, size: facts.size, modified: facts.modified, inode: facts.inode, sha256: digest)
            let adopted = try adopt(file)
            guard try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == adopted.id }) == nil else {
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
/// (finding 6): a take keeps its identity and publication through a crash.
enum OversizedRecordings {
    struct Entry: Codable, Equatable {
        var projectId: String
        var fileName: String
        var finishedAt: Int64
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
