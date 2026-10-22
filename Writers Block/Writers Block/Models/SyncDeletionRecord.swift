import Foundation
import SwiftData

@Model
final class SyncDeletionRecord {
    var projectId: String = ""
    /// The deleted recording's id; nil for a song tombstone or one from before ids.
    var recordingId: String?
    var fileName: String?
    var deletedAt: Int64 = 0

    init(projectId: String, recordingId: String? = nil, fileName: String? = nil, deletedAt: Int64) {
        self.projectId = projectId
        self.recordingId = recordingId
        self.fileName = fileName
        self.deletedAt = deletedAt
    }

    convenience init(deletion: SyncDeletion) {
        self.init(
            projectId: deletion.projectId,
            recordingId: deletion.recordingId,
            fileName: deletion.fileName,
            deletedAt: deletion.deletedAt
        )
    }

    var deletion: SyncDeletion {
        SyncDeletion(
            projectId: projectId,
            recordingId: recordingId,
            fileName: fileName,
            deletedAt: deletedAt
        )
    }
}
