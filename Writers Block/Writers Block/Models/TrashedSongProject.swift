import Foundation
import SwiftData

// nonisolated: read from nonisolated recordings-trash purge helpers as well as
// main-actor UI code (the project builds with -default-isolation=MainActor).
nonisolated let trashRetentionInterval: TimeInterval = 30 * 24 * 60 * 60

@Model
final class TrashedSongProject {
    // See SongProject.swift — CloudKit-backed SwiftData stores cannot use
    // @Attribute(.unique) and require property-level defaults. Uniqueness is
    // enforced by the trash-move logic.
    var id: String = ""
    var title: String = ""
    var lyrics: String = ""
    var theme: String = ""
    var updatedAt: Date = Date()
    var deletedAt: Date = Date()
    var deleteAfter: Date = Date()
    /// A38: `updatedAt` was established for a missing one (A32), not by an edit.
    /// Of two repairs the smaller time wins; an edit beats a repair and clears it.
    var precedenceRepaired: Bool = false
    /// A38: `deletedAt` was established for a missing one; `deleteAfter` follows it.
    var trashedAtRepaired: Bool = false

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
        // The edit time keeps its mark; the deletion time is a real one.
        precedenceRepaired = project.precedenceRepaired
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
