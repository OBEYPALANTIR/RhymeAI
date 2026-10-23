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
    var fileName: String = ""
    var sha256: String = ""
    var bytes: Int64 = 0
    var recordedAt: Date = Date()
    /// The precedence time a tombstone is judged against, persisted once and
    /// never re-derived from the file: finish time for a new recording, the
    /// backup's time for restored or imported audio, the old entry's time for
    /// migrated audio, the file's date for a memo from before this version.
    var uploadedAt: Date?
    /// recorded, restored, imported or migrated.
    var origin: String = Origin.recorded.rawValue
    /// Set while the recording sits in the recordings Trash; it names the Trash file.
    var trashedAt: Date?
    /// A file move this row is waiting for (the source path), written before the
    /// move so an interrupted one is finished on the next run.
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
        self.audio = audio
        self.bytes = Int64(audio.count)
        self.sha256 = RecordingBackupManifest.sha256Hex(audio)
        self.recordedAt = recordedAt
        self.uploadedAt = uploadedAt ?? recordedAt
        self.origin = origin.rawValue
    }

    var precedenceTime: Date { uploadedAt ?? recordedAt }

    var syncEntry: SyncRecording {
        SyncRecording(id: id, projectId: projectId, fileName: fileName, bytes: bytes, sha256: sha256, uploadedAt: precedenceTime)
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
}

extension RecordingLibraryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .scanFailed: return "A recordings folder could not be read, so nothing was changed. Writers Block will try again."
        case .unavailable: return "The library is not open yet, so the recording could not be saved."
        case .noFreeName: return "No free name fits for this recording."
        case .finalizeFailed: return "The recording was saved, but its record could not be finished. Writers Block will finish it on the next try."
        case .takeMissing: return "This recording's audio is no longer on this device."
        }
    }
}

/// Memo changes that must record their metadata before the file moves.
@MainActor
protocol RecordingPublishing: AnyObject {
    /// Moves a finished recording or imported audio from staging into the memo folder.
    /// `id` names a take already promised to the user (A27): publishing it again
    /// once it has a row is a success, not a second recording. `finishedAt` is the
    /// take's recorded finish time, its precedence time (A31).
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
/// and after any memo change. Rows are the truth. A run first reads every
/// folder and file (and hashes every file within the cap) and throws before
/// changing anything. A row's audio is located only by its id and verified
/// bytes (its pending source, its own path, or a path this device verified for
/// its id), never by size, date or a claimed path. Files no row holds are
/// adopted with the id every device derives for them; copies of one identity are
/// one recording (A26). Names in a song converge (A30): the earlier recording
/// keeps a name, the other takes "<stem> 2<ext>". Rows are saved before any file
/// moves; files then move through a parking folder, so swaps cannot clobber one
/// another. Audio a winning deletion covers goes to quarantine (A28). Recordings
/// over `SyncRecording.maxBytes` stay files only and are counted.
@MainActor
final class RecordingLibrary: RecordingPublishing {
    struct Result: Equatable {
        var oversizedCount = 0
        /// Live and Trash files over the cap, which stay on this device only.
        var oversizedFiles: [URL] = []
    }

    static let shared = RecordingLibrary(defaults: .standard)

    private static let mirroredPathsKey = "recording-library-verified-paths"
    private static let detachedTrashKey = "recording-library-detached-trash"
    let memosRoot: URL
    let trashRoot: URL
    private let defaults: UserDefaults
    /// The open library, for memo changes made outside a reconcile.
    var context: ModelContext?
    /// The library save; tests substitute a failing one.
    var save: (ModelContext) throws -> Void = { try $0.save() }
    private(set) var oversizedCount = 0
    private(set) var oversizedFiles: [URL] = []

    init(memosRoot: URL = RecordingFiles.memosRoot(), trashRoot: URL = RecordingFiles.memosTrashRoot(), defaults: UserDefaults) {
        self.memosRoot = memosRoot
        self.trashRoot = trashRoot
        self.defaults = defaults
    }

    /// Live memo paths verified to hold a row's audio here, with that row's id
    /// and precedence time (epoch ms). Written only after a verified operation.
    private var mirrored: [String: (id: String, at: Int64)] {
        get {
            let raw = defaults.dictionary(forKey: Self.mirroredPathsKey) as? [String: [String: Any]] ?? [:]
            return raw.compactMapValues { entry -> (id: String, at: Int64)? in
                guard let id = entry["id"] as? String, let at = (entry["at"] as? NSNumber)?.int64Value else { return nil }
                return (id, at)
            }
        }
        set { defaults.set(newValue.mapValues { ["id": $0.id, "at": NSNumber(value: $0.at)] as [String: Any] }, forKey: Self.mirroredPathsKey) }
    }

    /// Trash entries made here for recordings removed on another device; never adopted again.
    private var detachedTrash: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.detachedTrashKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.detachedTrashKey) }
    }

    func forgetMirroredKeys() {
        defaults.removeObject(forKey: Self.mirroredPathsKey)
    }

    private func url(of row: Recording) -> URL? { row.fileURL(memosRoot: memosRoot, trashRoot: trashRoot) }

    private func markMirrored(_ row: Recording, removing old: URL? = nil) {
        var paths = mirrored
        if let old { paths[RecordingFiles.canonicalPath(old)] = nil }
        if row.trashedAt == nil, let target = url(of: row) {
            paths[RecordingFiles.canonicalPath(target)] = (row.id, row.precedenceTime.epochMilliseconds)
        }
        mirrored = paths
    }

    // MARK: Reconcile

    /// A file as one read pass saw it.
    private struct DiskFile {
        let url: URL
        let path: String
        let projectId: String
        /// The recording's name: the file name, or a Trash entry's original name.
        let fileName: String
        let trashedAt: Date?
        let size: Int64
        let modified: Date
        /// Nil over the cap: such a file is never hashed or adopted.
        let sha256: String?
        var oversized: Bool { sha256 == nil }
    }

    private static func inspect(_ url: URL, projectId: String, fileName: String, trashedAt: Date?) throws -> DiskFile {
        let facts = try RecordingFiles.facts(url)
        let digest = facts.size > SyncRecording.maxBytes ? nil : try RecordingFiles.sha256(of: url)
        return DiskFile(url: url, path: RecordingFiles.canonicalPath(url), projectId: projectId, fileName: fileName, trashedAt: trashedAt,
                        size: facts.size, modified: facts.modified, sha256: digest)
    }

    /// Canonical copy first: a live copy, else the newest Trash time, ties by file name (A26).
    private static func rank(_ trashedAt: Date?, _ name: String) -> (Int, Int64, String) {
        (trashedAt == nil ? 0 : 1, -(trashedAt?.epochMilliseconds ?? 0), name)
    }

    /// All or nothing: every read happens before any change, and a failure rolls
    /// back this run's row changes, so no deletion, expiry or tombstone that
    /// depends on adoption is applied (A26).
    @discardableResult
    func reconcile(context: ModelContext) throws -> Result {
        // Changes the caller already made are saved first (a successful run would
        // save them anyway), so a rollback only undoes this run's own changes.
        if context.hasChanges { try save(context) }
        do {
            return try reconcileOnce(context: context)
        } catch {
            context.rollback()
            throw error
        }
    }

    private func reconcileOnce(context: ModelContext) throws -> Result {
        // An in-memory library is empty at every launch; treating its missing rows
        // as removals would trash every memo, so it only ever adds.
        let allowRemovals = !context.container.configurations.contains { $0.isStoredInMemoryOnly }
        let known = mirrored
        let detached = detachedTrash

        // 1. One pass of reads. Unreadable intents, folders or files throw here.
        let hidden = try RecordingFiles.readPendingQuarantine(for: memosRoot)
        let liveFiles = try scan(abortingIfMissing: !known.isEmpty).filter { !hidden.contains($0.path) }
        let trashFiles = try scanTrash().filter { !hidden.contains($0.path) }
        let deletions = try context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.deletion)
        let allRows = try context.fetch(FetchDescriptor<Recording>()).sorted { $0.id < $1.id }
        var byPath: [String: DiskFile] = [:]
        for file in liveFiles + trashFiles { byPath[file.path] = file }
        for row in allRows {
            guard let pending = row.pendingFrom else { continue }
            let source = URL(fileURLWithPath: pending)
            let path = RecordingFiles.canonicalPath(source)
            if byPath[path] == nil, !hidden.contains(path), try RecordingFiles.exists(source) {
                byPath[path] = try Self.inspect(source, projectId: row.projectId, fileName: row.fileName, trashedAt: nil)
            }
        }

        // 2. Where each row's audio is, by its id and verified bytes.
        func located(_ row: Recording) -> DiskFile? {
            var places: [String] = []
            if let pending = row.pendingFrom { places.append(RecordingFiles.canonicalPath(URL(fileURLWithPath: pending))) }
            if let own = url(of: row) { places.append(RecordingFiles.canonicalPath(own)) }
            places += known.filter { $0.value.id == row.id }.map(\.key).sorted()
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

        // 3. Deletions that win by time remove rows; a song deletion leaves each
        //    recording its own tombstone in this save; their audio goes to quarantine.
        var kept: [Recording] = []
        for row in rows {
            guard let tombstone = deletions.first(where: { $0.covers(projectId: row.projectId, recordingId: row.id, sha256: row.sha256, at: row.precedenceTime) }) else {
                kept.append(row)
                continue
            }
            if tombstone.isSongTombstone {
                try Self.upsertTombstone(SyncDeletion(projectId: row.projectId, recordingId: row.id, fileName: row.fileName, deletedAt: tombstone.deletedAt), in: context)
            }
            if let file = location[ObjectIdentifier(row)] { toQuarantine.append(file.url) }
            context.delete(row)
        }

        // 4. Files no row holds.
        var result = Result()
        var trashMoves: [DiskFile] = []
        var candidates: [(row: Recording, file: DiskFile)] = []
        let keptById = Dictionary(kept.map { ($0.id, $0) }) { first, _ in first }
        for file in (liveFiles + trashFiles) where !claimed.contains(file.path) {
            if file.oversized {
                result.oversizedCount += 1
                result.oversizedFiles.append(file.url)
                continue
            }
            if file.trashedAt == nil, let mirror = known[file.path], allowRemovals {
                if let row = keptById[mirror.id] {
                    // A second copy of a recording held elsewhere is not a new recording.
                    if row.sha256 == file.sha256 {
                        toQuarantine.append(file.url)
                        continue
                    }
                } else {
                    // Its row was removed on another device: to the recordings Trash, or
                    // to quarantine when a deletion of it wins here by time (A28).
                    let covered = deletions.contains { $0.covers(projectId: file.projectId, recordingId: mirror.id, sha256: file.sha256 ?? "", at: Date(millisecondsSince1970: mirror.at)) }
                    if covered { toQuarantine.append(file.url) } else { trashMoves.append(file) }
                    continue
                }
            }
            if file.trashedAt != nil, detached.contains(file.path) { continue }
            guard (try? SyncIdentity.validateFileName(file.fileName)) != nil else { continue }
            let row = try adopt(file)
            if try applyCovering(deletions, to: row, file: file.url, in: context, quarantining: &toQuarantine) { continue }
            candidates.append((row, file))
        }

        // 5. One legacy identity is one recording (A26): the canonical copy is chosen
        //    over every copy, the existing row's included, whatever order they came
        //    in. A row's precedence time is stamped once, as the earliest file time
        //    among the copies seen then, and never changes (A20).
        for (id, group) in Dictionary(grouping: candidates, by: { $0.row.id }).sorted(by: { $0.key < $1.key }) {
            let ordered = group.sorted { Self.rank($0.file.trashedAt, $0.file.url.lastPathComponent) < Self.rank($1.file.trashedAt, $1.file.url.lastPathComponent) }
            let best = ordered[0]
            if let existing = keptById[id] {
                let current = location[ObjectIdentifier(existing)]
                let currentName = (current?.url ?? url(of: existing))?.lastPathComponent ?? existing.fileName
                if Self.rank(existing.trashedAt, currentName) <= Self.rank(best.file.trashedAt, best.file.url.lastPathComponent) {
                    toQuarantine += group.map(\.file.url)
                    continue
                }
                if let current { toQuarantine.append(current.url) }
                existing.fileName = best.row.fileName
                existing.trashedAt = best.row.trashedAt
                location[ObjectIdentifier(existing)] = best.file
            } else {
                best.row.uploadedAt = group.compactMap(\.row.uploadedAt).min()
                context.insert(best.row)
                kept.append(best.row)
                location[ObjectIdentifier(best.row)] = best.file
            }
            toQuarantine += ordered.dropFirst().map(\.file.url)
        }

        // 6. Names converge (A30): in each song the earlier recording keeps a name
        //    (ties by the smaller id); the other takes "<stem> 2<ext>", then 3, …
        let reserved = Set(liveFiles.filter(\.oversized).map { "\($0.projectId)/\($0.fileName)" })
        for (projectId, songRows) in Dictionary(grouping: kept.filter { $0.trashedAt == nil }, by: \.projectId) {
            var taken = Set<String>()
            for row in songRows.sorted(by: { ($0.precedenceTime, $0.id) < ($1.precedenceTime, $1.id) }) {
                var name = row.fileName
                var number = 2
                while taken.contains(name) || reserved.contains("\(projectId)/\(name)") || (try? SyncIdentity.validateFileName(name)) == nil {
                    guard number < 1000 else { throw RecordingLibraryError.noFreeName }
                    name = RecordingFiles.numberedName(row.fileName, number)
                    number += 1
                }
                taken.insert(name)
                if row.fileName != name { row.fileName = name }
            }
        }

        // 7. The plan: each row's audio moves from where it is to its place, or is
        //    written from the row. The row records where its audio is now.
        var moves: [(row: Recording, from: URL, to: URL)] = []
        var writes: [(row: Recording, to: URL)] = []
        var inPlace: [Recording] = []
        for row in kept {
            guard let target = url(of: row) else { continue }
            if let source = location[ObjectIdentifier(row)] {
                if source.path == RecordingFiles.canonicalPath(target) {
                    if row.pendingFrom != nil { row.pendingFrom = nil }
                    inPlace.append(row)
                } else {
                    row.pendingFrom = source.url.path
                    moves.append((row, source.url, target))
                }
            } else {
                if row.pendingFrom != nil { row.pendingFrom = nil }
                writes.append((row, target))
            }
        }

        // 8. Commit the rows (with quarantine intents), then move files.
        try saveQuarantining(toQuarantine, in: context) { try save(context) }
        var detachedNow = detached
        for file in trashMoves {
            let folder = trashRoot.appendingPathComponent(file.projectId, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("\(Date().epochMilliseconds)\(RecordingFiles.trashNameSeparator)\(file.fileName)")
            try FileManager.default.moveItem(at: file.url, to: destination)
            detachedNow.insert(RecordingFiles.canonicalPath(destination))
        }
        detachedTrash = detachedNow
        // Moves go through a parking folder so a swap of names never overwrites.
        let parking = RecordingFiles.parkingRoot(for: memosRoot)
        if !moves.isEmpty { try FileManager.default.createDirectory(at: parking, withIntermediateDirectories: true) }
        var parked: [(row: Recording, at: URL, to: URL)] = []
        for move in moves {
            let spot = parking.appendingPathComponent("\(UUID().uuidString.lowercased()).\(move.from.pathExtension)")
            try FileManager.default.moveItem(at: move.from, to: spot)
            move.row.pendingFrom = spot.path
            parked.append((move.row, spot, move.to))
        }
        if !parked.isEmpty { try save(context) }
        var verified = inPlace
        for item in parked {
            // Something took its place meanwhile: it stays parked, recorded, for the next run.
            guard try !RecordingFiles.exists(item.to) else { continue }
            try FileManager.default.createDirectory(at: item.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: item.at, to: item.to)
            item.row.pendingFrom = nil
            verified.append(item.row)
        }
        for write in writes {
            guard try !RecordingFiles.exists(write.to), RecordingBackupManifest.sha256Hex(write.row.audio) == write.row.sha256 else { continue }
            try RecordingFiles.commitIfAbsent(write.row.audio, sha256: write.row.sha256, to: write.to, memosRoot: memosRoot, modifiedAt: write.row.recordedAt)
            verified.append(write.row)
        }
        if context.hasChanges { try save(context) }
        mirrored = Dictionary(verified.filter { $0.trashedAt == nil }.compactMap { row in
            url(of: row).map { (RecordingFiles.canonicalPath($0), (id: row.id, at: row.precedenceTime.epochMilliseconds)) }
        }) { first, _ in first }
        oversizedCount = result.oversizedCount
        oversizedFiles = result.oversizedFiles
        return result
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

    /// A newly adopted file a stored deletion already covers by time: its file goes
    /// to quarantine after the save, and a song deletion leaves it a tombstone by
    /// its id in that save.
    private func applyCovering(_ deletions: [SyncDeletion], to row: Recording, file: URL, in context: ModelContext,
                               quarantining toQuarantine: inout [URL]) throws -> Bool {
        guard let tombstone = deletions.first(where: { $0.covers(projectId: row.projectId, recordingId: row.id, sha256: row.sha256, at: row.precedenceTime) }) else {
            return false
        }
        if tombstone.isSongTombstone {
            try Self.upsertTombstone(SyncDeletion(projectId: row.projectId, recordingId: row.id, fileName: row.fileName, deletedAt: tombstone.deletedAt), in: context)
        }
        toQuarantine.append(file)
        return true
    }

    /// Quarantine moves are recorded before the save that removes their rows,
    /// made after it, and finished at the next start if interrupted (A28).
    func saveQuarantining(_ files: [URL], in context: ModelContext, save: () throws -> Void) throws {
        let paths = Set(files.map(RecordingFiles.canonicalPath))
        let before = try RecordingFiles.readPendingQuarantine(for: memosRoot)
        if !paths.isEmpty { try RecordingFiles.setPendingQuarantine(before.union(paths), for: memosRoot) }
        do {
            try save()
        } catch {
            if !paths.isEmpty { try? RecordingFiles.setPendingQuarantine(before, for: memosRoot) }
            throw error
        }
        finishPendingQuarantine(in: context)
    }

    /// Moves each recorded file to quarantine unless it holds the audio of a row
    /// that still names it (its save never landed). Only confirmed absence ends a
    /// record; a move that fails, or a file that cannot be read, stays recorded.
    func finishPendingQuarantine(in context: ModelContext) {
        guard let pending = try? RecordingFiles.readPendingQuarantine(for: memosRoot), !pending.isEmpty,
              let rows = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        let referenced = Dictionary(rows.compactMap { row in url(of: row).map { (RecordingFiles.canonicalPath($0), row.sha256) } }) { first, _ in first }
        var remaining = Set<String>()
        for path in pending {
            let file = URL(fileURLWithPath: path)
            do {
                guard try RecordingFiles.exists(file) else { continue }
                if let sha = referenced[path], try RecordingFiles.sha256(of: file) == sha { continue }
                try RecordingFiles.quarantine(file, memosRoot: memosRoot)
            } catch {
                remaining.insert(path)
            }
        }
        try? RecordingFiles.setPendingQuarantine(remaining, for: memosRoot)
    }

    private static func isRow(_ row: Recording, of memo: TrashedVoiceMemo) -> Bool {
        row.projectId == memo.projectId && row.fileName == memo.originalName
            && row.trashedAt?.epochMilliseconds == memo.deletedAt.epochMilliseconds
    }

    // MARK: Changes that record the row before the file moves

    func publishFinished(_ staged: URL, projectId: String, preferredName: String, origin: Recording.Origin, id: String?, finishedAt: Date?) throws -> URL {
        if let id, let context, let existing = try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == id }) {
            // Already published (an earlier attempt got that far): success. The staged
            // copy goes only when it is the very same audio.
            if try RecordingFiles.exists(staged), try RecordingFiles.sha256(of: staged) == existing.sha256 { try? FileManager.default.removeItem(at: staged) }
            guard let published = url(of: existing) else { throw RecordingLibraryError.unavailable }
            return published
        }
        if id != nil, try !RecordingFiles.exists(staged) { throw RecordingLibraryError.takeMissing }
        let folder = try RecordingFiles.projectURL(projectId: projectId, memosRoot: memosRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard try RecordingFiles.facts(staged).size <= SyncRecording.maxBytes else {
            // Too large for iCloud and Drive: it stays a local file.
            let target = RecordingFiles.restoredURL(originalName: preferredName, folder: folder)
            try SyncIdentity.validateFileName(target.lastPathComponent)
            try FileManager.default.moveItem(at: staged, to: target)
            return target
        }
        guard let context else { throw RecordingLibraryError.unavailable }
        let audio = try Data(contentsOf: staged)
        let name = try freeName(preferredName, projectId: projectId, taken: liveNames(projectId: projectId, in: context))
        let finished = finishedAt.map { Date(millisecondsSince1970: $0.epochMilliseconds) } ?? Date(millisecondsSince1970: Date().epochMilliseconds)
        let row = Recording(id: id ?? UUID().uuidString.lowercased(), projectId: projectId, fileName: name, audio: audio,
                            recordedAt: finished, uploadedAt: finished, origin: origin)
        return try commit(row, movingFrom: staged, in: context)
    }

    /// Restored or imported audio: written only if this device has neither the
    /// id nor a newer tombstone for it, under a free name, with the backup's time.
    /// The bytes must match the entry's hash and declared size, within the cap.
    @discardableResult
    func commitRestored(_ audio: Data, entry: SyncRecording, origin: Recording.Origin, context: ModelContext) throws -> Bool {
        guard Int64(audio.count) == entry.bytes, RecordingBackupManifest.sha256Hex(audio) == entry.sha256 else {
            throw SyncValidationError.invalidRecording
        }
        guard Int64(audio.count) <= SyncRecording.maxBytes,
              try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == entry.id }) == nil,
              // A deletion made here while the restore ran wins if it is newer.
              try !context.fetch(FetchDescriptor<SyncDeletionRecord>()).contains(where: { $0.deletion.covers(entry) }) else { return false }
        let staging = RecordingFiles.stagingRoot(for: memosRoot)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        try audio.write(to: staged, options: .atomic)
        guard let written = try? Data(contentsOf: staged), written.count == audio.count,
              RecordingBackupManifest.sha256Hex(written) == entry.sha256 else { throw SyncValidationError.invalidRecording }
        let row = Recording(id: entry.id, projectId: entry.projectId, fileName: entry.fileName, audio: audio,
                            recordedAt: entry.uploadedAt, uploadedAt: entry.uploadedAt, origin: origin)
        if try liveNames(projectId: entry.projectId, in: context).contains(entry.fileName) {
            // The name is held: the row claims it with its audio parked, and the
            // reconcile that follows every restore and import settles it (A30).
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
        guard let context, let row = try liveRow(at: url, in: context) else {
            try FileManager.default.moveItem(at: url, to: target)
            return
        }
        let previous = row.fileName
        row.fileName = target.lastPathComponent
        try recordIntent(row, from: url, in: context) { row.fileName = previous }
    }

    func trashRecording(at url: URL, to trashURL: URL, trashedAt: Date) throws {
        guard let context, let row = try liveRow(at: url, in: context) else {
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
        var row = try context.fetch(FetchDescriptor<Recording>()).first { Self.isRow($0, of: trashed) }
        if row == nil {
            // A Trash entry from before v4 is adopted (derived id, its file date) before it moves.
            let file = try Self.inspect(trashed.url, projectId: trashed.projectId, fileName: trashed.originalName, trashedAt: trashed.deletedAt)
            guard !file.oversized else {
                try FileManager.default.moveItem(at: trashed.url, to: target)
                return
            }
            let adopted = try adopt(file)
            guard try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == adopted.id }) == nil else {
                try FileManager.default.moveItem(at: trashed.url, to: target)
                return
            }
            context.insert(adopted)
            row = adopted
        }
        guard let row else { return }
        let previous = (row.trashedAt, row.fileName)
        row.trashedAt = nil
        row.fileName = target.lastPathComponent
        try recordIntent(row, from: trashed.url, in: context) { (row.trashedAt, row.fileName) = previous }
    }

    /// Song deletion: each of its recordings older than the deletion gets its own
    /// tombstone by id, in the caller's transaction, and its row goes.
    static func tombstoneRecordings(ofProject projectId: String, deletedAt: Int64, in context: ModelContext) throws -> [Recording] {
        let rows = try context.fetch(FetchDescriptor<Recording>()).filter {
            $0.projectId == projectId && $0.precedenceTime.epochMilliseconds < deletedAt
        }
        for row in rows {
            try upsertTombstone(SyncDeletion(projectId: projectId, recordingId: row.id, fileName: row.fileName, deletedAt: deletedAt), in: context)
            context.delete(row)
        }
        return rows
    }

    static func upsertTombstone(_ deletion: SyncDeletion, in context: ModelContext) throws {
        try deletion.validate()
        let records = try context.fetch(FetchDescriptor<SyncDeletionRecord>())
        if let existing = records.first(where: { $0.deletion.identity == deletion.identity }) {
            existing.deletedAt = max(existing.deletedAt, deletion.deletedAt)
        } else {
            context.insert(SyncDeletionRecord(deletion: deletion))
        }
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
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            revert()
            row.pendingFrom = nil
            try? save(context)
            throw error
        }
        markMirrored(row, removing: source)
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
            markMirrored(row)
            row.pendingFrom = nil
            do { try save(context) } catch { throw RecordingLibraryError.finalizeFailed }
            return target
        }
        context.delete(row)
        try? save(context)
        throw RecordingLibraryError.noFreeName
    }

    private func liveRow(at url: URL, in context: ModelContext) throws -> Recording? {
        let projectId = url.deletingLastPathComponent().lastPathComponent
        let name = url.lastPathComponent
        return try context.fetch(FetchDescriptor<Recording>()).first { $0.projectId == projectId && $0.fileName == name && $0.trashedAt == nil }
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

    /// Live memo files, read and hashed. A folder or file that cannot be read
    /// aborts the run: a failed scan must never look like deleted recordings.
    private func scan(abortingIfMissing: Bool) throws -> [DiskFile] {
        // Only a root the file system confirms missing is an empty library.
        guard try RecordingFiles.exists(memosRoot) else {
            if abortingIfMissing { throw RecordingLibraryError.scanFailed }
            return []
        }
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: memosRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        } catch {
            throw RecordingLibraryError.scanFailed
        }
        var files: [DiskFile] = []
        for folder in folders {
            let projectId = folder.lastPathComponent
            guard (try? SyncIdentity.validateProjectId(projectId)) != nil else { continue }
            do {
                for (fileName, url) in try RecordingBackupManifest.scanFiles(projectId: projectId, memosRoot: memosRoot) {
                    files.append(try Self.inspect(url, projectId: projectId, fileName: fileName, trashedAt: nil))
                }
            } catch {
                throw RecordingLibraryError.scanFailed
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Recordings Trash entries, read and hashed, on every run (A26).
    private func scanTrash() throws -> [DiskFile] {
        do {
            return try RecordingFiles.readableTrashedMemos(in: trashRoot).map {
                try Self.inspect($0.url, projectId: $0.projectId, fileName: $0.originalName, trashedAt: $0.deletedAt)
            }.sorted { $0.path < $1.path }
        } catch {
            throw RecordingLibraryError.scanFailed
        }
    }

    /// Every live and Trash file over the cap, read now (A29).
    func oversizedInventory() throws -> [URL] {
        let live = try scan(abortingIfMissing: false).filter(\.oversized).map(\.url)
        return live + (try scanTrash().filter(\.oversized).map(\.url))
    }
}
