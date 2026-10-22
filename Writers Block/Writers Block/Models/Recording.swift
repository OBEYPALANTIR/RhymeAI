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
    @Attribute(.externalStorage) var audio: Data = Data()

    init(projectId: String, fileName: String, audio: Data, recordedAt: Date) {
        self.id = UUID().uuidString
        self.projectId = projectId
        self.fileName = fileName
        self.audio = audio
        self.bytes = Int64(audio.count)
        self.sha256 = RecordingBackupManifest.sha256Hex(audio)
        self.recordedAt = recordedAt
    }

    var key: String { "\(projectId)/\(fileName)" }
    /// Not yet on Drive: `uploadedAt` is when it was recorded until a backup uploads it.
    var syncEntry: SyncRecording { SyncRecording(projectId: projectId, fileName: fileName, bytes: bytes, sha256: sha256, uploadedAt: recordedAt) }
}

/// Keeps the `Recording` rows and the memo files in step, in both directions.
///
/// A file with no row is imported (the first run imports every existing memo).
/// A row with no file was either removed here (trashed, renamed, deleted) or
/// arrived from another device through iCloud; the keys this device has already
/// mirrored tell the two apart. A mirrored file whose row disappeared was
/// removed on another device and moves to the recordings Trash, never deleted.
/// Recordings over `SyncRecording.maxBytes` stay files only.
enum RecordingLibrary {
    struct Result: Equatable {
        var oversizedCount = 0
    }

    private static let mirroredKeysKey = "recording-library-mirrored-keys"

    @discardableResult
    static func reconcile(
        context: ModelContext,
        memosRoot: URL,
        trashRoot: URL = RecordingFiles.memosTrashRoot(),
        defaults: UserDefaults
    ) throws -> Result {
        // An in-memory library is empty at every launch; treating its missing rows
        // as removals would trash every memo, so it only ever adds.
        let allowRemovals = !context.container.configurations.contains { $0.isStoredInMemoryOnly }
        var mirrored = Set(defaults.stringArray(forKey: mirroredKeysKey) ?? [])
        var result = Result()

        let deletions = try context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.deletion)
        func isDeleted(_ projectId: String, _ fileName: String, changedAt: Date) -> Bool {
            deletions.contains { $0.covers(projectId: projectId, fileName: fileName, modifiedAt: changedAt) }
        }

        var rowsByKey: [String: Recording] = [:]
        for row in try context.fetch(FetchDescriptor<Recording>()).sorted(by: { $0.id < $1.id }) {
            // Two devices that imported the same memo converge on the lowest id.
            if rowsByKey[row.key] != nil || isDeleted(row.projectId, row.fileName, changedAt: row.recordedAt) {
                context.delete(row)
            } else {
                rowsByKey[row.key] = row
            }
        }

        var files: [String: (projectId: String, fileName: String, url: URL)] = [:]
        let projectFolders = (try? FileManager.default.contentsOfDirectory(
            at: memosRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        for folder in projectFolders {
            let projectId = folder.lastPathComponent
            guard (try? SyncIdentity.validateProjectId(projectId)) != nil else { continue }
            for (fileName, url) in (try? RecordingBackupManifest.scanFiles(projectId: projectId, memosRoot: memosRoot)) ?? []
            where !isDeleted(projectId, fileName, changedAt: RecordingFiles.modificationDate(url)) {
                files["\(projectId)/\(fileName)"] = (projectId, fileName, url)
            }
        }

        for (key, row) in rowsByKey where files[key] == nil {
            if mirrored.contains(key) {
                if allowRemovals {
                    context.delete(row)
                    mirrored.remove(key)
                }
                continue
            }
            // New from another device: write the file, but only if the audio is intact.
            guard RecordingBackupManifest.sha256Hex(row.audio) == row.sha256,
                  let target = try? RecordingFiles.localURL(projectId: row.projectId, fileName: row.fileName, memosRoot: memosRoot) else { continue }
            if try RecordingFiles.commitIfAbsent(row.audio, to: target, modifiedAt: row.recordedAt) {
                mirrored.insert(key)
            }
        }

        for (key, file) in files where rowsByKey[key] == nil {
            if mirrored.contains(key), allowRemovals {
                // Removed on another device. Recoverable from Trash for 30 days.
                let folder = trashRoot.appendingPathComponent(file.projectId, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let stamp = Int64((Date().timeIntervalSince1970 * 1000).rounded())
                try FileManager.default.moveItem(
                    at: file.url,
                    to: folder.appendingPathComponent("\(stamp)\(RecordingFiles.trashNameSeparator)\(file.fileName)")
                )
                mirrored.remove(key)
                continue
            }
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard Int64(size) <= SyncRecording.maxBytes else {
                result.oversizedCount += 1
                continue
            }
            let audio = try Data(contentsOf: file.url)
            let recordedAt = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            context.insert(Recording(projectId: file.projectId, fileName: file.fileName, audio: audio, recordedAt: recordedAt))
            mirrored.insert(key)
        }

        try context.save()
        defaults.set(Array(mirrored).sorted(), forKey: mirroredKeysKey)
        return result
    }

    static func forgetMirroredKeys(defaults: UserDefaults) {
        defaults.removeObject(forKey: mirroredKeysKey)
    }
}
