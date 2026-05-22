import Foundation
import SwiftData

let trashRetentionInterval: TimeInterval = 30 * 24 * 60 * 60

@Model
final class TrashedSongProject {
    @Attribute(.unique) var id: String
    var title: String
    var lyrics: String
    var theme: String
    var updatedAt: Date
    var deletedAt: Date
    var deleteAfter: Date

    init(
        id: String,
        title: String,
        lyrics: String,
        theme: String,
        updatedAt: Date,
        deletedAt: Date = Date(),
        deleteAfter: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.lyrics = lyrics
        self.theme = theme
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.deleteAfter = deleteAfter ?? deletedAt.addingTimeInterval(trashRetentionInterval)
    }

    convenience init(project: SongProject, deletedAt: Date = Date()) {
        self.init(
            id: project.id,
            title: project.title,
            lyrics: project.lyrics,
            theme: project.theme,
            updatedAt: project.updatedAt,
            deletedAt: deletedAt
        )
    }

    func restoredProject() -> SongProject {
        SongProject(
            id: id,
            title: title,
            lyrics: lyrics,
            theme: theme,
            updatedAt: Date()
        )
    }
}
