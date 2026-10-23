import Foundation
import SwiftData

/// A song tombstone (`fileName` nil), or a recording tombstone by name from
/// before recording ids. New recording tombstones are `SyncRecordingDeletion`
/// rows: builds from before ids read every record here with a `fileName` as
/// "delete the file with this name", so identity tombstones never go here.
@Model
final class SyncDeletionRecord {
    var projectId: String = ""
    var fileName: String?
    var deletedAt: Int64 = 0

    init(projectId: String, fileName: String? = nil, deletedAt: Int64) {
        self.projectId = projectId
        self.fileName = fileName
        self.deletedAt = deletedAt
    }

    var deletion: SyncDeletion {
        SyncDeletion(projectId: projectId, fileName: fileName, deletedAt: deletedAt)
    }
}

/// A recording tombstone by id. Its own record type, which builds from before
/// ids never read, so they cannot take it for a deletion by file name.
@Model
final class SyncRecordingDeletion {
    var projectId: String = ""
    var recordingId: String = ""
    var fileName: String = ""
    var deletedAt: Int64 = 0

    init(projectId: String, recordingId: String, fileName: String, deletedAt: Int64) {
        self.projectId = projectId
        self.recordingId = recordingId
        self.fileName = fileName
        self.deletedAt = deletedAt
    }

    var deletion: SyncDeletion {
        SyncDeletion(projectId: projectId, recordingId: recordingId, fileName: fileName.isEmpty ? nil : fileName, deletedAt: deletedAt)
    }
}

/// Every tombstone this device knows, in either record type.
enum DeletionStore {
    /// All tombstones, read and validated: a read that fails, or a tombstone that
    /// is not valid (a bad id or name, no time), throws, so no deletion or cleanup
    /// acts on them (A33).
    static func all(in context: ModelContext) throws -> [SyncDeletion] {
        let deletions = try context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.deletion)
            + context.fetch(FetchDescriptor<SyncRecordingDeletion>()).map(\.deletion)
        for deletion in deletions { try deletion.validate() }
        return deletions
    }

    /// The recovery for tombstones that do not validate (T5.24): one naming a valid
    /// song or recording but with no usable time takes the time of this repair, so it
    /// still suppresses every existing copy of what it names; one whose identity is
    /// not valid names nothing that can be found, and is set aside in `setAside`
    /// (kept for diagnosis) and removed from the store. No recording file is touched.
    @discardableResult
    static func repairInvalid(in context: ModelContext, setAside: URL, now: Date = Date()) throws -> (repaired: Int, setAside: Int) {
        var repaired = 0
        var removed: [[String: String]] = []
        func identityValid(projectId: String, recordingId: String?, fileName: String?) -> Bool {
            var probe = SyncDeletion(projectId: projectId, recordingId: recordingId, fileName: fileName, deletedAt: 1)
            if recordingId == nil, fileName?.isEmpty == true { probe.fileName = nil }
            return (try? probe.validate()) != nil
        }
        for record in try context.fetch(FetchDescriptor<SyncDeletionRecord>()) where (try? record.deletion.validate()) == nil {
            if identityValid(projectId: record.projectId, recordingId: nil, fileName: record.deletion.fileName) {
                record.deletedAt = now.epochMilliseconds
                repaired += 1
            } else {
                removed.append(["type": "song", "projectId": record.projectId, "fileName": record.fileName ?? "", "deletedAt": String(record.deletedAt)])
                context.delete(record)
            }
        }
        for record in try context.fetch(FetchDescriptor<SyncRecordingDeletion>()) where (try? record.deletion.validate()) == nil {
            if identityValid(projectId: record.projectId, recordingId: record.recordingId, fileName: record.deletion.fileName) {
                record.deletedAt = now.epochMilliseconds
                repaired += 1
            } else {
                removed.append(["type": "recording", "projectId": record.projectId, "recordingId": record.recordingId,
                                "fileName": record.fileName, "deletedAt": String(record.deletedAt)])
                context.delete(record)
            }
        }
        if !removed.isEmpty {
            var kept = (try? JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: setAside))) ?? []
            kept += removed
            try FileManager.default.createDirectory(at: setAside.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(kept).write(to: setAside, options: .atomic)
        }
        if context.hasChanges { try context.save() }
        return (repaired, removed.count)
    }

    /// Stores a tombstone, keeping the newest time per identity.
    static func upsert(_ deletion: SyncDeletion, in context: ModelContext) throws {
        try deletion.validate()
        if let recordingId = deletion.recordingId {
            let records = try context.fetch(FetchDescriptor<SyncRecordingDeletion>())
            if let existing = records.first(where: { $0.deletion.identity == deletion.identity }) {
                existing.deletedAt = max(existing.deletedAt, deletion.deletedAt)
            } else {
                context.insert(SyncRecordingDeletion(projectId: deletion.projectId, recordingId: recordingId,
                                                     fileName: deletion.fileName ?? "", deletedAt: deletion.deletedAt))
            }
        } else {
            let records = try context.fetch(FetchDescriptor<SyncDeletionRecord>())
            if let existing = records.first(where: { $0.deletion.identity == deletion.identity }) {
                existing.deletedAt = max(existing.deletedAt, deletion.deletedAt)
            } else {
                context.insert(SyncDeletionRecord(projectId: deletion.projectId, fileName: deletion.fileName, deletedAt: deletion.deletedAt))
            }
        }
    }
}
