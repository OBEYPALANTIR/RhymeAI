import Foundation
import SwiftData

/// A voice memo's audio in the library, so recordings sync through iCloud with
/// the songs. Playback and recording still work on the files under
/// `RecordingFiles.memosRoot()`; `RecordingLibrary` keeps the two in step.
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
    /// backup's time for restored or imported audio, the file's date for a memo
    /// from before this version (stamped at first sight).
    var uploadedAt: Date?
    /// recorded, restored, imported or migrated.
    var origin: String = Origin.recorded.rawValue
    @Attribute(.externalStorage) var audio: Data = Data()

    enum Origin: String {
        case recorded, restored, imported, migrated
    }

    init(projectId: String, fileName: String, audio: Data, recordedAt: Date, uploadedAt: Date? = nil, origin: Origin = .recorded) {
        self.id = UUID().uuidString
        self.projectId = projectId
        self.fileName = fileName
        self.audio = audio
        self.bytes = Int64(audio.count)
        self.sha256 = RecordingBackupManifest.sha256Hex(audio)
        self.recordedAt = recordedAt
        self.uploadedAt = uploadedAt ?? recordedAt
        self.origin = origin.rawValue
    }

    var key: String { "\(projectId)/\(fileName)" }
    var syncEntry: SyncRecording {
        SyncRecording(projectId: projectId, fileName: fileName, bytes: bytes, sha256: sha256, uploadedAt: uploadedAt ?? recordedAt)
    }
}

enum RecordingLibraryError: Error, Equatable {
    /// A memo folder could not be listed; nothing was changed.
    case scanFailed
}

/// Keeps the `Recording` rows (which sync through iCloud) and the memo files
/// in step, in both directions. Owned by the app, independent of Drive: it runs
/// at launch, when iCloud delivers changes, and when a memo is finalised,
/// imported, renamed, trashed or restored. A Drive backup only reads its rows.
///
/// A finished file with no row is imported. A row with no file was either
/// removed here or arrived from another device; the keys this device has
/// mirrored tell the two apart. A mirrored file whose row disappeared was
/// removed on another device and moves to the recordings Trash, never deleted.
/// The file being recorded is never read. Recordings over `SyncRecording.maxBytes`
/// stay files only and are counted.
@MainActor
final class RecordingLibrary {
    struct Result: Equatable {
        var oversizedCount = 0
    }

    static let shared = RecordingLibrary(defaults: .standard)

    private static let mirroredKeysKey = "recording-library-mirrored-keys"
    private static let firstImportDoneKey = "recording-library-first-import-done"
    let memosRoot: URL
    let trashRoot: URL
    private let defaults: UserDefaults
    /// Files still being written (the active recorder); left alone until finalised.
    var filesInProgress: () -> Set<URL> = { [] }
    /// The library save; tests substitute a failing one.
    var save: (ModelContext) throws -> Void = { try $0.save() }
    private(set) var oversizedCount = 0

    init(memosRoot: URL = RecordingFiles.memosRoot(), trashRoot: URL = RecordingFiles.memosTrashRoot(), defaults: UserDefaults) {
        self.memosRoot = memosRoot
        self.trashRoot = trashRoot
        self.defaults = defaults
    }

    private var mirrored: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.mirroredKeysKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Self.mirroredKeysKey) }
    }

    func forgetMirroredKeys() {
        defaults.removeObject(forKey: Self.mirroredKeysKey)
    }

    @discardableResult
    func reconcile(context: ModelContext) throws -> Result {
        // An in-memory library is empty at every launch; treating its missing rows
        // as removals would trash every memo, so it only ever adds.
        let allowRemovals = !context.container.configurations.contains { $0.isStoredInMemoryOnly }
        let known = mirrored
        let firstImportDone = defaults.bool(forKey: Self.firstImportDoneKey)
        let deletions = try context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.deletion)
        // Memos a newer tombstone covers are on their way out; they are not imported.
        let files = try scan(abortingIfMissing: !known.isEmpty, deletions: deletions)
        var result = Result()

        func isDeleted(_ projectId: String, _ fileName: String, changedAt: Date) -> Bool {
            deletions.contains { $0.covers(projectId: projectId, fileName: fileName, modifiedAt: changedAt) }
        }

        var rowsByKey: [String: Recording] = [:]
        for row in try context.fetch(FetchDescriptor<Recording>()).sorted(by: { $0.id < $1.id }) {
            // Two devices that imported the same memo converge on the lowest id.
            if rowsByKey[row.key] != nil || isDeleted(row.projectId, row.fileName, changedAt: row.uploadedAt ?? row.recordedAt) {
                context.delete(row)
            } else {
                rowsByKey[row.key] = row
            }
        }

        // Bookkeeping order keeps a crash harmless: a key leaves the mirrored set
        // before its row is deleted, and joins it only after the row is saved.
        // A stale key can then only make the next run import or write a file again.
        var removedKeys = Set<String>()
        var addedKeys = Set<String>()
        var trashMoves: [(from: URL, projectId: String, fileName: String)] = []

        // Rows whose file left: kept aside so a renamed memo keeps its row and time.
        var departed: [String: Recording] = [:]
        for (key, row) in rowsByKey where files[key] == nil {
            if known.contains(key) {
                if allowRemovals {
                    departed[key] = row
                    removedKeys.insert(key)
                }
                continue
            }
            // New from another device: write the file for playback, if the audio is intact.
            guard RecordingBackupManifest.sha256Hex(row.audio) == row.sha256,
                  let target = try? RecordingFiles.localURL(projectId: row.projectId, fileName: row.fileName, memosRoot: memosRoot) else { continue }
            if try RecordingFiles.commitIfAbsent(row.audio, sha256: row.sha256, to: target, memosRoot: memosRoot, modifiedAt: row.recordedAt) {
                addedKeys.insert(key)
            }
        }

        for (key, file) in files {
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let row = rowsByKey[key] {
                // A memo changed on disk since its row was made: refresh the row.
                guard Int64(size) != row.bytes || RecordingFiles.modificationDate(file.url) > row.recordedAt.addingTimeInterval(1),
                      Int64(size) <= SyncRecording.maxBytes else { continue }
                let audio = try Data(contentsOf: file.url)
                let digest = RecordingBackupManifest.sha256Hex(audio)
                guard digest != row.sha256 else { continue }
                row.audio = audio
                row.sha256 = digest
                row.bytes = Int64(audio.count)
                row.recordedAt = RecordingFiles.modificationDate(file.url)
                // Finished again just now: that is its new precedence time.
                row.uploadedAt = Date()
                continue
            }
            if known.contains(key), allowRemovals {
                trashMoves.append((file.url, file.projectId, file.fileName))
                removedKeys.insert(key)
                continue
            }
            guard Int64(size) <= SyncRecording.maxBytes else {
                result.oversizedCount += 1
                continue
            }
            let audio = try Data(contentsOf: file.url)
            let digest = RecordingBackupManifest.sha256Hex(audio)
            if let renamed = departed.first(where: { $0.value.projectId == file.projectId && $0.value.sha256 == digest }) {
                // The same audio under a new name: a rename keeps the row and its time.
                departed.removeValue(forKey: renamed.key)
                renamed.value.fileName = file.fileName
                rowsByKey[key] = renamed.value
                addedKeys.insert(key)
                continue
            }
            let modified = RecordingFiles.modificationDate(file.url)
            // Memos from before this version are stamped with their file date once;
            // a memo finished since is stamped with the time it was picked up.
            let stamp = firstImportDone ? max(modified, Date()) : modified
            context.insert(Recording(projectId: file.projectId, fileName: file.fileName, audio: audio, recordedAt: modified, uploadedAt: stamp))
            addedKeys.insert(key)
        }
        for row in departed.values { context.delete(row) }

        mirrored = known.subtracting(removedKeys)
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
        // Removed on another device: recoverable from the recordings Trash for 30 days.
        for move in trashMoves {
            let folder = trashRoot.appendingPathComponent(move.projectId, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = Int64((Date().timeIntervalSince1970 * 1000).rounded())
            try FileManager.default.moveItem(at: move.from, to: folder.appendingPathComponent("\(stamp)\(RecordingFiles.trashNameSeparator)\(move.fileName)"))
        }
        mirrored = mirrored.union(addedKeys)
        defaults.set(true, forKey: Self.firstImportDoneKey)
        oversizedCount = result.oversizedCount
        return result
    }

    /// Writes restored audio only if its name is free and records the row with
    /// the backup's `uploadedAt`, so a later tombstone is judged against it.
    @discardableResult
    func commitRestored(_ audio: Data, entry: SyncRecording, origin: Recording.Origin, context: ModelContext) throws -> Bool {
        let target = try RecordingFiles.localURL(projectId: entry.projectId, fileName: entry.fileName, memosRoot: memosRoot)
        guard try RecordingFiles.commitIfAbsent(audio, sha256: entry.sha256, to: target, memosRoot: memosRoot, modifiedAt: entry.uploadedAt) else { return false }
        if entry.bytes <= SyncRecording.maxBytes,
           try context.fetch(FetchDescriptor<Recording>()).first(where: { $0.key == entry.key }) == nil {
            context.insert(Recording(projectId: entry.projectId, fileName: entry.fileName, audio: audio, recordedAt: entry.uploadedAt, uploadedAt: entry.uploadedAt, origin: origin))
            try save(context)
            mirrored = mirrored.union([entry.key])
        }
        return true
    }

    /// Finished memo files by key. A folder that cannot be read aborts the run:
    /// a failed scan must never look like deleted recordings.
    private func scan(abortingIfMissing: Bool, deletions: [SyncDeletion]) throws -> [String: (projectId: String, fileName: String, url: URL)] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: memosRoot.path, isDirectory: &isDirectory) else {
            if abortingIfMissing { throw RecordingLibraryError.scanFailed }
            return [:]
        }
        guard isDirectory.boolValue,
              let folders = try? FileManager.default.contentsOfDirectory(at: memosRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            throw RecordingLibraryError.scanFailed
        }
        let inProgress = Set(filesInProgress().map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
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
            for (fileName, url) in entries where !inProgress.contains(url.standardizedFileURL.resolvingSymlinksInPath().path)
                && !deletions.contains(where: { $0.covers(projectId: projectId, fileName: fileName, modifiedAt: RecordingFiles.modificationDate(url)) }) {
                files["\(projectId)/\(fileName)"] = (projectId, fileName, url)
            }
        }
        return files
    }
}
