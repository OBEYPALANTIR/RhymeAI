import Foundation
import SwiftData

@Model
final class SongProject {
    @Attribute(.unique) var id: String
    var title: String
    var lyrics: String
    var theme: String
    var updatedAt: Date

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
