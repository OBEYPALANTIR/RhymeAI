import Foundation
import SwiftData

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

    convenience init(deletion: SyncDeletion) {
        self.init(
            projectId: deletion.projectId,
            fileName: deletion.fileName,
            deletedAt: deletion.deletedAt
        )
    }

    var deletion: SyncDeletion {
        SyncDeletion(
            projectId: projectId,
            fileName: fileName,
            deletedAt: deletedAt
        )
    }
}
