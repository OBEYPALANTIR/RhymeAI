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
    /// A memo folder could not be listed; nothing was changed.
    case scanFailed
    /// The library is not open, so the change could not be recorded.
    case unavailable
    /// No free name fits the file-name limit.
    case noFreeName
}

extension RecordingLibraryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .scanFailed: return "A recordings folder could not be read, so nothing was changed. Writers Block will try again."
        case .unavailable: return "The library is not open yet, so the recording could not be saved."
        case .noFreeName: return "No free name fits for this recording."
        }
    }
}

/// Memo changes that must record their metadata before the file moves.
@MainActor
protocol RecordingPublishing: AnyObject {
    /// Moves a finished recording or imported audio from staging into the memo folder.
    /// `id` names a take already promised to the user (A27): publishing it again
    /// once it has a row is a success, not a second recording.
    func publishFinished(_ staged: URL, projectId: String, preferredName: String, origin: Recording.Origin, id: String?) throws -> URL
    func renameRecording(at url: URL, to target: URL) throws
    func trashRecording(at url: URL, to trashURL: URL, trashedAt: Date) throws
    func untrashRecording(_ trashed: TrashedVoiceMemo, to target: URL) throws
}

/// Keeps the `Recording` rows (iCloud) and the memo files in step. Owned by the
/// app, independent of Drive: it runs at launch, when iCloud delivers changes,
/// and after any memo change. Rows are the truth and own files by id: a file
/// belongs to the row whose audio it holds (or that last mirrored it); another
/// row claiming the same name gets a free name and keeps its own bytes. A row
/// without its file gets the file written from its audio. A file no row owns is
/// adopted with the id every device derives for it (memos and Trash entries
/// from before v4), unless a row this device mirrored there was removed on
/// another device (it moves to the recordings Trash, never deleted). Every
/// local change writes the row first, with the pending move, then moves the
/// file; an interrupted change is finished, or kept for the next run, never
/// attached to other bytes. Recordings over `SyncRecording.maxBytes` stay
/// files only and are counted.
extension RecordingPublishing {
    func publishFinished(_ staged: URL, projectId: String, preferredName: String, origin: Recording.Origin) throws -> URL {
        try publishFinished(staged, projectId: projectId, preferredName: preferredName, origin: origin, id: nil)
    }
}

@MainActor
final class RecordingLibrary: RecordingPublishing {
    struct Result: Equatable {
        var oversizedCount = 0
        /// Live files over the cap, which stay on this device only.
        var oversizedFiles: [URL] = []
    }

    static let shared = RecordingLibrary(defaults: .standard)

    private static let mirroredPathsKey = "recording-library-mirrored-paths"
    private static let firstImportDoneKey = "recording-library-first-import-done"
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

    /// Live memo paths ("projectId/fileName") and the row id that had them here.
    private var mirrored: [String: String] {
        get { defaults.dictionary(forKey: Self.mirroredPathsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.mirroredPathsKey) }
    }

    func forgetMirroredKeys() {
        defaults.removeObject(forKey: Self.mirroredPathsKey)
    }

    private func url(of row: Recording) -> URL? { row.fileURL(memosRoot: memosRoot, trashRoot: trashRoot) }

    private static func hash(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map(RecordingBackupManifest.sha256Hex)
    }

    /// All or nothing: any failure (an unreadable file, a folder that cannot be
    /// listed) rolls back every row change, so no deletion, expiry or tombstone
    /// that depends on adoption is applied (A26).
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
        let firstImport = !defaults.bool(forKey: Self.firstImportDoneKey)
        let deletions = try context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.deletion)
        var rows = try context.fetch(FetchDescriptor<Recording>()).sorted(by: { $0.id < $1.id })

        // The same id twice (two devices adopted one old memo) is one recording.
        var byId: [String: Recording] = [:]
        for row in rows {
            if byId[row.id] != nil { context.delete(row) } else { byId[row.id] = row }
        }
        rows = rows.filter { byId[$0.id] === $0 }

        // Finish moves a row recorded but did not see through, before looking at files.
        for row in rows where row.pendingFrom != nil { try recoverPendingMove(row, in: context) }

        // Quarantine moves an earlier run recorded but did not finish come first;
        // files still waiting for one are neither adopted nor listed.
        finishPendingQuarantine(in: context)
        let hidden = RecordingFiles.pendingQuarantine(for: memosRoot)
        let files = try scan(abortingIfMissing: !known.isEmpty).filter { !hidden.contains(RecordingFiles.canonicalPath($0.value.url)) }
        let trashEntries = firstImport
            ? try RecordingFiles.readableTrashedMemos(in: trashRoot).filter { !hidden.contains(RecordingFiles.canonicalPath($0.url)) }
                .sorted { $0.url.path < $1.url.path }
            : []
        var result = Result()
        // Audio a known deletion covers, and extra copies of one recording, go to quarantine.
        var toQuarantine: [URL] = []

        // Local application of tombstones. A song tombstone that removes a recording
        // leaves that recording its own tombstone, in this save.
        var kept: [Recording] = []
        for row in rows {
            guard let tombstone = deletions.first(where: { $0.covers(projectId: row.projectId, recordingId: row.id, sha256: row.sha256, at: row.precedenceTime) }) else {
                kept.append(row)
                continue
            }
            if tombstone.isSongTombstone {
                try Self.upsertTombstone(SyncDeletion(projectId: row.projectId, recordingId: row.id, fileName: row.fileName, deletedAt: tombstone.deletedAt), in: context)
            }
            if let file = url(of: row), FileManager.default.fileExists(atPath: file.path) { toQuarantine.append(file) }
            context.delete(row)
        }

        // Ownership of each live name, decided by id and audio before any name moves.
        var live: [String: Recording] = [:]
        var displaced: [Recording] = []
        for (path, claimants) in Dictionary(grouping: kept.filter { $0.trashedAt == nil }, by: { "\($0.projectId)/\($0.fileName)" }) {
            var owner: Recording?
            if let file = files[path] {
                if claimants.count == 1, let only = claimants.first, Self.unchanged(file.url, since: only) {
                    owner = only
                } else {
                    let digest = Self.hash(file.url)
                    // The id this device had at that path first, then the audio, then that id
                    // again when the file changed on disk since (refreshed below).
                    owner = claimants.first { known[path] == $0.id && $0.sha256 == digest }
                        ?? claimants.first { $0.sha256 == digest }
                        ?? claimants.first { known[path] == $0.id }
                }
            } else {
                owner = claimants.first
            }
            if let owner { live[path] = owner }
            displaced += claimants.filter { $0 !== owner }
        }
        // A claimant that does not own the name keeps its own bytes under a free name.
        for row in displaced {
            row.fileName = try freeName(row.fileName, projectId: row.projectId, taken: Set(live.keys), files: files)
            live["\(row.projectId)/\(row.fileName)"] = row
        }

        for (path, row) in live {
            if let file = files[path] {
                try refreshIfChanged(row, from: file.url)
            } else {
                try materialize(row)
            }
        }
        for row in kept where row.trashedAt != nil { try materialize(row) }

        var trashMoves: [(from: URL, projectId: String, fileName: String)] = []
        // Files no row owns, each with the id every device derives for it.
        var candidates: [(row: Recording, file: URL)] = []
        for (path, file) in files.sorted(by: { $0.key < $1.key }) where live[path] == nil {
            if let knownId = known[path], allowRemovals {
                // Removed on another device: to the recordings Trash, or to
                // quarantine when a deletion of it is known here (A28).
                if deletions.contains(where: { $0.recordingId == knownId }) {
                    toQuarantine.append(file.url)
                } else {
                    trashMoves.append((file.url, file.projectId, file.fileName))
                }
                continue
            }
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard Int64(size) <= SyncRecording.maxBytes else {
                result.oversizedCount += 1
                result.oversizedFiles.append(file.url)
                continue
            }
            let row = try adopt(file.url, projectId: file.projectId, fileName: file.fileName, trashedAt: nil)
            if try applyCovering(deletions, to: row, file: file.url, in: context, quarantining: &toQuarantine) { continue }
            candidates.append((row, file.url))
        }
        // Trash entries from before v4 are candidates the first time (A20/A21).
        if firstImport {
            let trashedRows = kept.filter { $0.trashedAt != nil }
            for memo in trashEntries where !trashedRows.contains(where: { Self.isRow($0, of: memo) }) {
                let size = (try? memo.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard Int64(size) <= SyncRecording.maxBytes,
                      (try? SyncIdentity.validateFileName(memo.originalName)) != nil else { continue }
                let row = try adopt(memo.url, projectId: memo.projectId, fileName: memo.originalName, trashedAt: memo.deletedAt)
                if try applyCovering(deletions, to: row, file: memo.url, in: context, quarantining: &toQuarantine) { continue }
                candidates.append((row, memo.url))
            }
        }

        // One legacy identity is one recording (A26). Its canonical copy is chosen
        // over every candidate, the existing row's file included, whatever order
        // they arrived in: a live copy first, else the newest Trash time, ties by
        // file name. The row takes the canonical copy's place, time and expiry;
        // every other copy goes to quarantine.
        func rank(_ trashedAt: Date?, _ name: String) -> (Int, Int64, String) {
            (trashedAt == nil ? 0 : 1, -(trashedAt?.epochMilliseconds ?? 0), name)
        }
        let keptById = Dictionary(kept.map { ($0.id, $0) }) { first, _ in first }
        for (id, group) in Dictionary(grouping: candidates, by: { $0.row.id }).sorted(by: { $0.key < $1.key }) {
            let ordered = group.sorted { rank($0.row.trashedAt, $0.file.lastPathComponent) < rank($1.row.trashedAt, $1.file.lastPathComponent) }
            let best = ordered[0]
            if let existing = keptById[id] {
                let current = url(of: existing)
                if rank(existing.trashedAt, current?.lastPathComponent ?? existing.fileName) <= rank(best.row.trashedAt, best.file.lastPathComponent) {
                    toQuarantine += group.map(\.file)
                    continue
                }
                if existing.trashedAt == nil { live["\(existing.projectId)/\(existing.fileName)"] = nil }
                if let current, FileManager.default.fileExists(atPath: current.path) { toQuarantine.append(current) }
                existing.fileName = best.row.fileName
                existing.trashedAt = best.row.trashedAt
                existing.recordedAt = best.row.recordedAt
                existing.uploadedAt = best.row.uploadedAt
                if existing.trashedAt == nil { live["\(existing.projectId)/\(existing.fileName)"] = existing }
            } else {
                context.insert(best.row)
                if best.row.trashedAt == nil { live["\(best.row.projectId)/\(best.row.fileName)"] = best.row }
            }
            toQuarantine += ordered.dropFirst().map(\.file)
        }

        try saveQuarantining(toQuarantine, in: context) { try save(context) }
        // Removed on another device: recoverable from the recordings Trash for 30 days.
        for move in trashMoves {
            let folder = trashRoot.appendingPathComponent(move.projectId, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = Date().epochMilliseconds
            try FileManager.default.moveItem(at: move.from, to: folder.appendingPathComponent("\(stamp)\(RecordingFiles.trashNameSeparator)\(move.fileName)"))
        }
        mirrored = live.mapValues(\.id)
        defaults.set(true, forKey: Self.firstImportDoneKey)
        oversizedCount = result.oversizedCount
        oversizedFiles = result.oversizedFiles
        return result
    }

    /// A file no row owns: the id every device derives for it and its file date (A20/A21).
    private func adopt(_ file: URL, projectId: String, fileName: String, trashedAt: Date?) throws -> Recording {
        let audio = try Data(contentsOf: file)
        let modified = RecordingFiles.modificationDate(file)
        let id = RecordingBackupManifest.legacyRecordingId(projectId: projectId, fileName: fileName, sha256: RecordingBackupManifest.sha256Hex(audio))
        let row = Recording(id: id, projectId: projectId, fileName: fileName, audio: audio, recordedAt: modified, uploadedAt: modified)
        row.trashedAt = trashedAt.map { Date(millisecondsSince1970: $0.epochMilliseconds) }
        return row
    }

    /// A newly adopted file a stored deletion already covers: its file goes to
    /// quarantine after the save, and a song deletion leaves it a tombstone by its
    /// id in that save.
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
        let before = RecordingFiles.pendingQuarantine(for: memosRoot)
        if !paths.isEmpty { try RecordingFiles.setPendingQuarantine(before.union(paths), for: memosRoot) }
        do {
            try save()
        } catch {
            if !paths.isEmpty { try? RecordingFiles.setPendingQuarantine(before, for: memosRoot) }
            throw error
        }
        finishPendingQuarantine(in: context)
    }

    /// Moves each recorded file to quarantine unless a row still names it (its
    /// save never landed). A move that fails stays recorded for the next start.
    func finishPendingQuarantine(in context: ModelContext) {
        let pending = RecordingFiles.pendingQuarantine(for: memosRoot)
        guard !pending.isEmpty, let rows = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        let referenced = Set(rows.compactMap { url(of: $0).map(RecordingFiles.canonicalPath) })
        var remaining = Set<String>()
        for path in pending where !referenced.contains(path) && FileManager.default.fileExists(atPath: path) {
            do {
                try RecordingFiles.quarantine(URL(fileURLWithPath: path), memosRoot: memosRoot)
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

    /// Size and date match the row: the file is the row's audio without hashing it.
    private static func unchanged(_ url: URL, since row: Recording) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        return Int64(size) == row.bytes && RecordingFiles.modificationDate(url) <= row.recordedAt.addingTimeInterval(1)
    }

    /// An interrupted move. The source holding this row's audio is moved to the
    /// row's path, or to a free name (persisted first) when that path holds other
    /// bytes. A destination already holding the audio means the move happened.
    /// Anything else is kept pending for a later run rather than guessed at.
    private func recoverPendingMove(_ row: Recording, in context: ModelContext) throws {
        guard let pending = row.pendingFrom, let target = url(of: row) else { return }
        let source = URL(fileURLWithPath: pending)
        if FileManager.default.fileExists(atPath: target.path) {
            if Self.hash(target) == row.sha256 {
                row.pendingFrom = nil
                return
            }
            guard row.trashedAt == nil, FileManager.default.fileExists(atPath: source.path), Self.hash(source) == row.sha256 else { return }
            row.fileName = try freeName(row.fileName, projectId: row.projectId, taken: [], files: [:])
            try save(context)
            guard let freed = url(of: row) else { return }
            try FileManager.default.moveItem(at: source, to: freed)
            row.pendingFrom = nil
            return
        }
        if FileManager.default.fileExists(atPath: source.path), Self.hash(source) == row.sha256 {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: target)
            row.pendingFrom = nil
        } else if !FileManager.default.fileExists(atPath: source.path) {
            // The source is gone (a cleared staging file): the row's own audio is the recording.
            try materialize(row)
            row.pendingFrom = nil
        }
    }

    // MARK: Changes that record the row before the file moves

    func publishFinished(_ staged: URL, projectId: String, preferredName: String, origin: Recording.Origin, id: String?) throws -> URL {
        if let id, let context, let existing = try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.id == id }) {
            // Already published (an earlier attempt finished): success. The staged
            // copy goes only when it is the very same audio.
            if Self.hash(staged) == existing.sha256 { try? FileManager.default.removeItem(at: staged) }
            guard let published = url(of: existing) else { throw RecordingLibraryError.unavailable }
            return published
        }
        let folder = try RecordingFiles.projectURL(projectId: projectId, memosRoot: memosRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(size) <= SyncRecording.maxBytes else {
            // Too large for iCloud and Drive: it stays a local file.
            let target = RecordingFiles.restoredURL(originalName: preferredName, folder: folder)
            try SyncIdentity.validateFileName(target.lastPathComponent)
            try FileManager.default.moveItem(at: staged, to: target)
            return target
        }
        guard let context else { throw RecordingLibraryError.unavailable }
        let audio = try Data(contentsOf: staged)
        let name = try freeName(preferredName, projectId: projectId, taken: liveNames(projectId: projectId, in: context), files: [:])
        let finished = Date()
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
        let name = try freeName(entry.fileName, projectId: entry.projectId, taken: liveNames(projectId: entry.projectId, in: context), files: [:])
        let row = Recording(id: entry.id, projectId: entry.projectId, fileName: name, audio: audio,
                            recordedAt: entry.uploadedAt, uploadedAt: entry.uploadedAt, origin: origin)
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
            let size = (try? trashed.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard Int64(size) <= SyncRecording.maxBytes else {
                try FileManager.default.moveItem(at: trashed.url, to: target)
                return
            }
            let adopted = try adopt(trashed.url, projectId: trashed.projectId, fileName: trashed.originalName, trashedAt: trashed.deletedAt)
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
    /// change with the file untouched.
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
        row.pendingFrom = nil
        try save(context)
        updateMirrored(context: context)
    }

    /// Publishes a new row's staged audio. Each destination is saved before the
    /// move is tried; a name taken meanwhile gets the next free one, saved again.
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
                row.pendingFrom = nil
                try save(context)
                updateMirrored(context: context)
                return target
            } catch CocoaError.fileWriteFileExists {
                row.fileName = try freeName(row.fileName, projectId: row.projectId, taken: try liveNames(projectId: row.projectId, in: context).union([row.fileName]), files: [:])
                try save(context)
            } catch {
                context.delete(row)
                try? save(context)
                throw error
            }
        }
        context.delete(row)
        try? save(context)
        throw RecordingLibraryError.noFreeName
    }

    private func updateMirrored(context: ModelContext) {
        guard let rows = try? context.fetch(FetchDescriptor<Recording>()) else { return }
        mirrored = Dictionary(rows.filter { $0.trashedAt == nil }.map { ("\($0.projectId)/\($0.fileName)", $0.id) }) { first, _ in first }
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
    /// disk, among live rows (`taken` holds names or "projectId/name" paths) and in `files`.
    private func freeName(_ preferred: String, projectId: String, taken: Set<String>,
                          files: [String: (projectId: String, fileName: String, url: URL)]) throws -> String {
        let folder = try RecordingFiles.projectURL(projectId: projectId, memosRoot: memosRoot)
        func isFree(_ name: String) -> Bool {
            !taken.contains(name) && !taken.contains("\(projectId)/\(name)") && files["\(projectId)/\(name)"] == nil
                && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        if isFree(preferred), (try? SyncIdentity.validateFileName(preferred)) != nil { return preferred }
        for suffix in 2..<1000 {
            let candidate = RecordingFiles.numberedName(preferred, suffix)
            if isFree(candidate), (try? SyncIdentity.validateFileName(candidate)) != nil { return candidate }
        }
        throw RecordingLibraryError.noFreeName
    }

    /// Writes a row's file from its audio when it is missing; never replaces one.
    private func materialize(_ row: Recording) throws {
        guard let target = url(of: row), !FileManager.default.fileExists(atPath: target.path),
              RecordingBackupManifest.sha256Hex(row.audio) == row.sha256 else { return }
        try RecordingFiles.commitIfAbsent(row.audio, sha256: row.sha256, to: target, memosRoot: memosRoot, modifiedAt: row.recordedAt)
    }

    /// The owner's memo changed on disk since its row was made: refresh the row.
    private func refreshIfChanged(_ row: Recording, from url: URL) throws {
        guard !Self.unchanged(url, since: row) else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(size) <= SyncRecording.maxBytes else { return }
        let audio = try Data(contentsOf: url)
        let digest = RecordingBackupManifest.sha256Hex(audio)
        guard digest != row.sha256 else { return }
        row.audio = audio
        row.sha256 = digest
        row.bytes = Int64(audio.count)
        row.recordedAt = RecordingFiles.modificationDate(url)
        row.uploadedAt = Date()
    }

    /// Finished memo files by "projectId/fileName". A folder that cannot be read
    /// aborts the run: a failed scan must never look like deleted recordings.
    private func scan(abortingIfMissing: Bool) throws -> [String: (projectId: String, fileName: String, url: URL)] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: memosRoot.path, isDirectory: &isDirectory) else {
            if abortingIfMissing { throw RecordingLibraryError.scanFailed }
            return [:]
        }
        guard isDirectory.boolValue,
              let folders = try? FileManager.default.contentsOfDirectory(at: memosRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            throw RecordingLibraryError.scanFailed
        }
        var files: [String: (projectId: String, fileName: String, url: URL)] = [:]
        for folder in folders {
            let projectId = folder.lastPathComponent
            guard (try? SyncIdentity.validateProjectId(projectId)) != nil else { continue }
            let entries: [(fileName: String, url: URL)]
            do {
                entries = try RecordingBackupManifest.scanFiles(projectId: projectId, memosRoot: memosRoot)
            } catch {
                throw RecordingLibraryError.scanFailed
            }
            for (fileName, url) in entries {
                files["\(projectId)/\(fileName)"] = (projectId, fileName, url)
            }
        }
        return files
    }
}
