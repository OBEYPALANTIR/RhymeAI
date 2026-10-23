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
    /// Every tombstone with a time, read and validated: a read that fails, or a
    /// tombstone whose id or name is not valid, throws, so no deletion or cleanup acts
    /// on them (A33). One with a valid identity but no time is not among them: it is
    /// held apart (`undated`), scoped to what it names (T5.24).
    static func all(in context: ModelContext) throws -> [SyncDeletion] {
        var valid: [SyncDeletion] = []
        for deletion in try records(in: context) where !isUndated(deletion) {
            try deletion.validate()
            valid.append(deletion)
        }
        return valid
    }

    /// Tombstones that name a valid song or recording but have no time (T5.24). Their
    /// time is never invented (A41); what they name is neither deleted nor brought
    /// back, and is not listed or played, until a tombstone of the same identity with
    /// a time supersedes them (`upsert`).
    static func undated(in context: ModelContext) throws -> [SyncDeletion] {
        try records(in: context).filter(isUndated)
    }

    private static func records(in context: ModelContext) throws -> [SyncDeletion] {
        try context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.deletion)
            + context.fetch(FetchDescriptor<SyncRecordingDeletion>()).map(\.deletion)
    }

    private static func isUndated(_ deletion: SyncDeletion) -> Bool {
        guard deletion.deletedAt <= 0 else { return false }
        var probe = deletion
        probe.deletedAt = 1
        return (try? probe.validate()) != nil
    }

    /// The recovery for tombstones that do not validate (T5.24). A tombstone's time
    /// is never invented (A41): one naming a valid song or recording but with no
    /// usable time stays as it is, held to what it names (`undated`), and is
    /// counted as `suspended`. One whose identity is not valid names nothing that can
    /// be found, so it is set aside in `setAside` (kept for diagnosis) and removed
    /// from the store. Nothing else is deleted and no recording file is touched.
    @discardableResult
    static func repairInvalid(in context: ModelContext, setAside: URL) throws -> (suspended: Int, setAside: Int) {
        var suspended = 0
        var removed: [[String: String]] = []
        func identityValid(projectId: String, recordingId: String?, fileName: String?) -> Bool {
            var probe = SyncDeletion(projectId: projectId, recordingId: recordingId, fileName: fileName, deletedAt: 1)
            if recordingId == nil, fileName?.isEmpty == true { probe.fileName = nil }
            return (try? probe.validate()) != nil
        }
        for record in try context.fetch(FetchDescriptor<SyncDeletionRecord>()) where (try? record.deletion.validate()) == nil {
            if identityValid(projectId: record.projectId, recordingId: nil, fileName: record.deletion.fileName) {
                suspended += 1
            } else {
                removed.append(["type": "song", "projectId": record.projectId, "fileName": record.fileName ?? "", "deletedAt": String(record.deletedAt)])
                context.delete(record)
            }
        }
        for record in try context.fetch(FetchDescriptor<SyncRecordingDeletion>()) where (try? record.deletion.validate()) == nil {
            if identityValid(projectId: record.projectId, recordingId: record.recordingId, fileName: record.deletion.fileName) {
                suspended += 1
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
        return (suspended, removed.count)
    }

    /// Stores a tombstone, keeping the newest time per identity. Every record of that
    /// identity takes it, so one without a time is superseded, and duplicates go.
    static func upsert(_ deletion: SyncDeletion, in context: ModelContext) throws {
        try deletion.validate()
        if let recordingId = deletion.recordingId {
            let matching = try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).filter { $0.deletion.identity == deletion.identity }
            if let first = matching.first {
                first.deletedAt = max(matching.map(\.deletedAt).max() ?? 0, deletion.deletedAt)
                matching.dropFirst().forEach(context.delete)
            } else {
                context.insert(SyncRecordingDeletion(projectId: deletion.projectId, recordingId: recordingId,
                                                     fileName: deletion.fileName ?? "", deletedAt: deletion.deletedAt))
            }
        } else {
            let matching = try context.fetch(FetchDescriptor<SyncDeletionRecord>()).filter { $0.deletion.identity == deletion.identity }
            if let first = matching.first {
                first.deletedAt = max(matching.map(\.deletedAt).max() ?? 0, deletion.deletedAt)
                matching.dropFirst().forEach(context.delete)
            } else {
                context.insert(SyncDeletionRecord(projectId: deletion.projectId, fileName: deletion.fileName, deletedAt: deletion.deletedAt))
            }
        }
    }
}
