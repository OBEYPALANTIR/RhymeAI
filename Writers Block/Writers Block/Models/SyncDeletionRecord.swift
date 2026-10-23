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
