import Foundation
import SwiftData

@Model
final class SongProject {
    // NOTE: id is unique application-side. CloudKit-backed SwiftData stores
    // reject @Attribute(.unique), so uniqueness is enforced by the upsert
    // logic in EditorViewModel rather than the schema. Property defaults
    // are also required by CloudKit so that historical records sync cleanly.
    var id: String = ""
    var title: String = ""
    var lyrics: String = ""
    var theme: String = ""
    var updatedAt: Date = Date()

    init(
        id: String = UUID().uuidString,
        title: String = "",
        lyrics: String = "",
        theme: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.lyrics = lyrics
        self.theme = theme
        self.updatedAt = updatedAt
    }
}
