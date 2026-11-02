import Foundation
import SwiftData

@Model
final class TrashedOneLiner {
    // See OneLiner: CloudKit-compatible defaults, uniqueness enforced by OneLinersStore.
    var id: String = ""
    var text: String = ""
    var createdAt: Date = Date()
    var audioFileName: String?
    var audioDuration: Double = 0
    var usedInProjectId: String?
    var deletedAt: Date = Date()
    var deleteAfter: Date = Date()

    init(oneLiner: OneLiner, deletedAt: Date = Date()) {
        id = oneLiner.id
        text = oneLiner.text
        createdAt = oneLiner.createdAt
        audioFileName = oneLiner.audioFileName
        audioDuration = oneLiner.audioDuration
        usedInProjectId = oneLiner.usedInProjectId
        self.deletedAt = deletedAt
        deleteAfter = deletedAt.addingTimeInterval(trashRetentionInterval)
    }

    func restoredOneLiner() -> OneLiner {
        OneLiner(
            id: id,
            text: text,
            createdAt: createdAt,
            audioFileName: audioFileName,
            audioDuration: audioDuration,
            usedInProjectId: usedInProjectId
        )
    }
}
