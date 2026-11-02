import Foundation
import SwiftData
import Testing
@testable import Writers_Block

@MainActor
struct OneLinersStoreTests {
    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self,
            Recording.self, OneLiner.self, TrashedOneLiner.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @Test
    func addSearchTrashAndRestore() throws {
        // Given
        let container = try Self.makeContainer()
        let store = OneLinersStore(context: container.mainContext)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try store.add(text: "Found the Lord in a gas station bathroom", now: start)
        try store.add(text: "  Every mile marker says your name \n", now: start.addingTimeInterval(60))
        let newest = try store.add(text: "Half a heart still beats on time", now: start.addingTimeInterval(120))

        // Then: newest first, text trimmed, search ignores case
        #expect(try store.all().map(\.text) == [
            "Half a heart still beats on time",
            "Every mile marker says your name",
            "Found the Lord in a gas station bathroom",
        ])
        #expect(try store.search("LORD").map(\.text) == ["Found the Lord in a gas station bathroom"])
        #expect(try store.search("  ").count == 3)
        #expect(try store.search("chorus").isEmpty)

        // When
        let trashed = try store.trash(newest)

        // Then
        #expect(try store.all().count == 2)
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedOneLiner>()).map(\.id) == [trashed.id])
        #expect(trashed.deleteAfter == trashed.deletedAt.addingTimeInterval(trashRetentionInterval))

        // When
        let restored = try store.restore(trashed)

        // Then
        #expect(restored.text == "Half a heart still beats on time")
        #expect(restored.createdAt == start.addingTimeInterval(120))
        #expect(try store.all().count == 3)
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedOneLiner>()).isEmpty)
    }

    @Test
    func savingCachesProsodyForTheLine() throws {
        // Given
        let container = try Self.makeContainer()
        let store = OneLinersStore(context: container.mainContext)

        // When
        let line = try store.add(text: "Found the Lord in a gas station bathroom")

        // Then
        #expect(line.syllableCount == 10)
        #expect(line.stressPattern.count == line.syllableCount)
        #expect(!line.rhymeKeys.isEmpty)
        #expect(!line.primaryRhymeKey.isEmpty)
        #expect(OneLinersView.prosodyBadge(line).hasPrefix("10 syl · "))
    }

    @Test
    func sendingToAClosedSongAppendsALastLineAndMarksItUsed() throws {
        // Given
        let container = try Self.makeContainer()
        let store = OneLinersStore(context: container.mainContext)
        let song = SongProject(title: "Night Train", lyrics: "Left the porch light on for no one")
        container.mainContext.insert(song)
        let line = try store.add(text: "Every mile marker says your name")

        // When
        try store.sendToSong(line, project: song, editor: nil)

        // Then
        #expect(song.lyrics == "Left the porch light on for no one\nEvery mile marker says your name")
        #expect(line.usedInProjectId == song.id)
        #expect(try store.all().count == 1)  // used lines stay in the pool
        #expect(OneLinersStore.appendingLine("x", to: "") == "x")
        #expect(OneLinersStore.appendingLine("x", to: "a\n") == "a\nx")
    }

    @Test
    func sendingToTheOpenSongInsertsAtTheCursor() throws {
        // Given
        let container = try Self.makeContainer()
        let store = OneLinersStore(context: container.mainContext)
        let song = SongProject(title: "Night Train", lyrics: "first line\nlast line")
        container.mainContext.insert(song)
        try container.mainContext.save()
        let editor = EditorViewModel()
        editor.modelContext = container.mainContext
        editor.loadProject(song)
        editor.cursorPosition = ("first line" as NSString).length
        let line = try store.add(text: "middle line")

        // When
        try store.sendToSong(line, project: song, editor: editor)

        // Then
        #expect(editor.lyrics == "first line\nmiddle line\nlast line")
        #expect(line.usedInProjectId == song.id)
        // One undoable edit, like an inserted suggestion.
        editor.undoLyrics()
        #expect(editor.lyrics == "first line\nlast line")
    }

    @Test
    func permanentDeleteAndExpiryRemoveTheAudioFile() throws {
        // Given
        let container = try Self.makeContainer()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("one-liners-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OneLinersStore(context: container.mainContext, audioRoot: root)
        try Data("take".utf8).write(to: store.audioURL(fileName: "a.m4a"))
        try Data("take".utf8).write(to: store.audioURL(fileName: "b.m4a"))
        let first = try store.add(text: "", audioFileName: "a.m4a", audioDuration: 4)
        let second = try store.add(text: "kept a while", audioFileName: "b.m4a", audioDuration: 11)
        let deletedAt = Date()
        let firstTrashed = try store.trash(first, now: deletedAt)
        try store.trash(second, now: deletedAt)

        // When
        try store.permanentlyDelete(firstTrashed)
        try store.purgeExpired(now: deletedAt.addingTimeInterval(trashRetentionInterval - 1))

        // Then: deleted forever goes now; the other waits out its 30 days
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(fileName: "a.m4a").path))
        #expect(FileManager.default.fileExists(atPath: store.audioURL(fileName: "b.m4a").path))
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedOneLiner>()).count == 1)

        // When
        try store.purgeExpired(now: deletedAt.addingTimeInterval(trashRetentionInterval))

        // Then
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(fileName: "b.m4a").path))
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedOneLiner>()).isEmpty)
    }
}
