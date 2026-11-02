import Foundation
import SwiftData

/// A stray lyric line kept apart from any song until the writer sends it to one.
@Model
final class OneLiner {
    // See SongProject.swift: CloudKit-backed SwiftData stores cannot use
    // @Attribute(.unique) and require property-level defaults.
    var id: String = ""
    var text: String = ""
    var createdAt: Date = Date()
    /// File name under `OneLinersStore.audioRoot`; nil for a typed line.
    var audioFileName: String?
    var audioDuration: Double = 0
    /// The song the line was sent to. A plain id, so deleting the song never touches the line.
    var usedInProjectId: String?
    // Prosody cache, recomputed whenever the text is saved.
    var syllableCount: Int = 0
    /// End-word rhyme keys (phones, last stressed vowel first), joined by `|`.
    var rhymeKeys: String = ""
    /// One digit per syllable: 0 unstressed, 1 primary, 2 secondary.
    var stressPattern: String = ""

    init(
        id: String = UUID().uuidString,
        text: String = "",
        createdAt: Date = Date(),
        audioFileName: String? = nil,
        audioDuration: Double = 0,
        usedInProjectId: String? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.audioFileName = audioFileName
        self.audioDuration = audioDuration
        self.usedInProjectId = usedInProjectId
        refreshProsody()
    }

    /// The first end-word rhyme key, lowercased for the row badge; empty when the word has none.
    var primaryRhymeKey: String {
        rhymeKeys.split(separator: "|").first.map { $0.lowercased() } ?? ""
    }

    func refreshProsody() {
        let line = ProsodyAnalyzer.analyzeLine(text)
        syllableCount = line.syllableCount
        stressPattern = line.stressPattern.map(String.init).joined()
        rhymeKeys = RhymePhonetics.rhymeKeys(for: RhymeConstraint.lineEndWord(text)).joined(separator: "|")
    }
}
