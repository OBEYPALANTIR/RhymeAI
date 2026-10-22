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
}

/// Memo changes that must record their metadata before the file moves.
@MainActor
protocol RecordingPublishing: AnyObject {
    /// Moves a finished recording or imported audio from staging into the memo folder.
    func publishFinished(_ staged: URL, projectId: String, preferredName: String, origin: Recording.Origin) throws -> URL
    func renameRecording(at url: URL, to target: URL) throws
    func trashRecording(at url: URL, to trashURL: URL, trashedAt: Date) throws
    func untrashRecording(_ trashed: TrashedVoiceMemo, to target: URL) throws
}

/// Keeps the `Recording` rows (iCloud) and the memo files in step. Owned by the
/// app, independent of Drive: it runs at launch, when iCloud delivers changes,
/// and after any memo change. Rows are the truth: a row without its file gets
/// the file written from its audio; a file without a row is a memo from before
/// this version (imported once) or one whose row was removed on another device
/// (it moves to the recordings Trash, never deleted). Every local change
/// (finish, import, rename, trash, restore from Trash, restore from a backup)
/// writes the row first, with the pending move, then moves the file, so an
/// interrupted change is completed on the next run. Recordings over
/// `SyncRecording.maxBytes` stay files only and are counted.
@MainActor
final class RecordingLibrary: RecordingPublishing {
    struct Result: Equatable {
        var oversizedCount = 0
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

    init(memosRoot: URL = RecordingFiles.memosRoot(), trashRoot: URL = RecordingFiles.memosTrashRoot(), defaults: UserDefaults) {
        self.memosRoot = memosRoot
        self.trashRoot = trashRoot
        self.defaults = defaults
    }

    /// Live memo paths ("projectId/fileName") that had a row on this device.
    private var mirrored: [String: String] {
        get { defaults.dictionary(forKey: Self.mirroredPathsKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.mirroredPathsKey) }
    }

    func forgetMirroredKeys() {
        defaults.removeObject(forKey: Self.mirroredPathsKey)
    }

    private func url(of row: Recording) -> URL? { row.fileURL(memosRoot: memosRoot, trashRoot: trashRoot) }

    @discardableResult
    func reconcile(context: ModelContext) throws -> Result {
        // An in-memory library is empty at every launch; treating its missing rows
        // as removals would trash every memo, so it only ever adds.
        let allowRemovals = !context.container.configurations.contains { $0.isStoredInMemoryOnly }
        let known = mirrored
        let firstImportDone = defaults.bool(forKey: Self.firstImportDoneKey)
        let deletions = try context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.deletion)
        let rows = try context.fetch(FetchDescriptor<Recording>()).sorted(by: { $0.id < $1.id })
        // Finish moves a row recorded but did not see through, before looking at files.
        for row in rows {
            guard let pending = row.pendingFrom, let target = url(of: row) else { continue }
            if !FileManager.default.fileExists(atPath: target.path), FileManager.default.fileExists(atPath: pending) {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.moveItem(at: URL(fileURLWithPath: pending), to: target)
            }
            row.pendingFrom = nil
        }
        let files = try scan(abortingIfMissing: !known.isEmpty)
        var result = Result()
        var filesToRemove: [URL] = []

        var live: [String: Recording] = [:]
        for row in rows {
            // Local application of tombstones newer than the recording.
            if deletions.contains(where: { $0.covers(projectId: row.projectId, recordingId: row.id, fileName: row.fileName, at: row.precedenceTime) }) {
                if let file = url(of: row) { filesToRemove.append(file) }
                context.delete(row)
                continue
            }
            guard row.trashedAt == nil else {
                try materialize(row)
                continue
            }
            let path = "\(row.projectId)/\(row.fileName)"
            if let owner = live[path] {
                // Two rows claim one name. The same audio converges on the lowest id;
                // different audio keeps both, the later under a free name.
                if owner.sha256 == row.sha256 {
                    context.delete(row)
                    continue
                }
                row.fileName = try freeName(row.fileName, projectId: row.projectId, taken: Set(live.keys))
            }
            live["\(row.projectId)/\(row.fileName)"] = row
        }

        for (path, row) in live {
            if let file = files[path] {
                try refreshIfChanged(row, from: file.url)
            } else {
                try materialize(row)
            }
        }

        var trashMoves: [(from: URL, projectId: String, fileName: String)] = []
        for (path, file) in files where live[path] == nil {
            if deletions.contains(where: { $0.covers(projectId: file.projectId, recordingId: "", fileName: file.fileName, at: RecordingFiles.modificationDate(file.url)) }) {
                continue
            }
            if known[path] != nil, allowRemovals {
                trashMoves.append((file.url, file.projectId, file.fileName))
                continue
            }
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard Int64(size) <= SyncRecording.maxBytes else {
                result.oversizedCount += 1
                continue
            }
            let audio = try Data(contentsOf: file.url)
            let modified = RecordingFiles.modificationDate(file.url)
            // Memos from before this version are stamped once with their file date;
            // one that appears later without passing through the library is stamped now.
            // A memo from before v4 gets the id every device derives for it.
            let id = firstImportDone ? UUID().uuidString.lowercased()
                : RecordingBackupManifest.legacyRecordingId(projectId: file.projectId, fileName: file.fileName, sha256: RecordingBackupManifest.sha256Hex(audio))
            let row = Recording(id: id, projectId: file.projectId, fileName: file.fileName, audio: audio, recordedAt: modified,
                                uploadedAt: firstImportDone ? max(modified, Date()) : modified)
            context.insert(row)
            live[path] = row
        }

        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        for file in filesToRemove {
            try? RecordingFiles.removeItemIfPresent(at: file, within: file.path.hasPrefix(trashRoot.path) ? trashRoot : memosRoot)
        }
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
        return result
    }

    // MARK: Changes that record the row before the file moves

    func publishFinished(_ staged: URL, projectId: String, preferredName: String, origin: Recording.Origin) throws -> URL {
        let folder = try RecordingFiles.projectURL(projectId: projectId, memosRoot: memosRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(size) <= SyncRecording.maxBytes else {
            // Too large for iCloud and Drive: it stays a local file.
            let target = RecordingFiles.restoredURL(originalName: preferredName, folder: folder)
            try FileManager.default.moveItem(at: staged, to: target)
            return target
        }
        guard let context else { throw RecordingLibraryError.unavailable }
        let audio = try Data(contentsOf: staged)
        let name = try freeName(preferredName, projectId: projectId, taken: liveNames(projectId: projectId, in: context))
        let finished = Date()
        let row = Recording(projectId: projectId, fileName: name, audio: audio, recordedAt: finished, uploadedAt: finished, origin: origin)
        return try commit(row, movingFrom: staged, in: context)
    }

    /// Restored or imported audio: written only if this device has neither the
    /// id nor a newer tombstone for it, under a free name, with the backup's time.
    @discardableResult
    func commitRestored(_ audio: Data, entry: SyncRecording, origin: Recording.Origin, context: ModelContext) throws -> Bool {
        guard entry.bytes <= SyncRecording.maxBytes,
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
        let name = try freeName(entry.fileName, projectId: entry.projectId, taken: liveNames(projectId: entry.projectId, in: context))
        let row = Recording(id: entry.id, projectId: entry.projectId, fileName: name, audio: audio,
                            recordedAt: entry.uploadedAt, uploadedAt: entry.uploadedAt, origin: origin)
        _ = try commit(row, movingFrom: staged, in: context)
        return true
    }

    func renameRecording(at url: URL, to target: URL) throws {
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
        guard let context, let row = try context.fetch(FetchDescriptor<Recording>()).first(where: {
            $0.projectId == trashed.projectId && $0.fileName == trashed.originalName
                && $0.trashedAt?.epochMilliseconds == trashed.deletedAt.epochMilliseconds
        }) else {
            try FileManager.default.moveItem(at: trashed.url, to: target)
            return
        }
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
    /// A failed save fails the change with the file untouched; a failed move
    /// restores the row.
    private func recordIntent(_ row: Recording, from source: URL, in context: ModelContext, revert: () -> Void) throws {
        guard let target = url(of: row) else { throw RecordingLibraryError.unavailable }
        row.pendingFrom = source.path
        do {
            try save(context)
        } catch {
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

    private func commit(_ row: Recording, movingFrom staged: URL, in context: ModelContext) throws -> URL {
        context.insert(row)
        row.pendingFrom = staged.path
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        guard var target = url(of: row) else { throw RecordingLibraryError.unavailable }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A file that took the name meanwhile is kept; this one gets the next free name.
            while true {
                do {
                    try FileManager.default.moveItem(at: staged, to: target)
                    break
                } catch CocoaError.fileWriteFileExists {
                    row.fileName = try freeName(row.fileName, projectId: row.projectId, taken: liveNames(projectId: row.projectId, in: context).union([row.fileName]))
                    target = url(of: row) ?? target
                }
            }
        } catch {
            context.delete(row)
            try? save(context)
            throw error
        }
        row.pendingFrom = nil
        try save(context)
        updateMirrored(context: context)
        return target
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

    /// `preferred`, or "name 2.ext", "name 3.ext"… : free on disk and among live rows.
    private func freeName(_ preferred: String, projectId: String, taken: Set<String>) throws -> String {
        let folder = try RecordingFiles.projectURL(projectId: projectId, memosRoot: memosRoot)
        let stem = (preferred as NSString).deletingPathExtension
        let ext = (preferred as NSString).pathExtension
        var candidate = preferred
        var suffix = 2
        while taken.contains(candidate) || taken.contains("\(projectId)/\(candidate)")
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(stem) \(suffix).\(ext)"
            suffix += 1
        }
        try SyncIdentity.validateFileName(candidate)
        return candidate
    }

    /// Writes a row's file from its audio when it is missing; never replaces one.
    private func materialize(_ row: Recording) throws {
        guard let target = url(of: row), !FileManager.default.fileExists(atPath: target.path),
              RecordingBackupManifest.sha256Hex(row.audio) == row.sha256 else { return }
        try RecordingFiles.commitIfAbsent(row.audio, sha256: row.sha256, to: target, memosRoot: memosRoot, modifiedAt: row.recordedAt)
    }

    /// A memo changed on disk since its row was made: refresh the row.
    private func refreshIfChanged(_ row: Recording, from url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(size) != row.bytes || RecordingFiles.modificationDate(url) > row.recordedAt.addingTimeInterval(1),
              Int64(size) <= SyncRecording.maxBytes else { return }
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
