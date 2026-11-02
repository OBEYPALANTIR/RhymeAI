import Foundation
import SwiftData
import Testing
@testable import Writers_Block

@MainActor
struct OneLinersStoreTests {
    private struct SaveFailed: Error {}

    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self,
            Recording.self, OneLiner.self, TrashedOneLiner.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// A store over its own temporary audio folder, removed by the caller.
    private static func makeStore(_ container: ModelContainer) throws -> OneLinersStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("one-liners-\(UUID().uuidString)", isDirectory: true)
        let store = OneLinersStore(context: container.mainContext, audioRoot: root)
        try FileManager.default.createDirectory(at: store.pendingRoot, withIntermediateDirectories: true)
        return store
    }

    /// A finished take waiting in the pending folder, as the capture sheet leaves it.
    private static func pendingTake(_ store: OneLinersStore, _ name: String = "\(UUID().uuidString).m4a") throws -> URL {
        let url = store.pendingRoot.appendingPathComponent(name)
        try Data("take".utf8).write(to: url)
        return url
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
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
        #expect(OneLinersView.prosodyBadge(line) == "10 syl · bathroom")

        // When: new words recompute the cache
        try store.updateText(line, to: "Half a heart still beats on time ")

        // Then
        #expect(line.text == "Half a heart still beats on time")
        #expect(line.syllableCount == 7)
        #expect(OneLinersView.prosodyBadge(line) == "7 syl · time")
    }

    @Test
    func audioUsedMarkerAndProsodySurviveTrashAndRestore() throws {
        // Given
        let container = try Self.makeContainer()
        let store = try Self.makeStore(container)
        defer { try? FileManager.default.removeItem(at: store.audioRoot) }
        let take = try Self.pendingTake(store, "take.m4a")
        let line = try store.add(text: "You kept the ring and gave me back the rain", take: take, audioDuration: 11)
        try store.markUsed(line, projectId: "song-1")
        let before = (line.text, line.audioFileName, line.audioDuration, line.usedInProjectId)
        let prosody = (line.syllableCount, line.rhymeKeys, line.stressPattern)

        // When
        let restored = try store.restore(try store.trash(line))

        // Then
        #expect(!Self.exists(take))
        #expect(Self.exists(store.audioURL(fileName: "take.m4a")))
        #expect(before == (restored.text, restored.audioFileName, restored.audioDuration, restored.usedInProjectId))
        #expect(prosody == (restored.syllableCount, restored.rhymeKeys, restored.stressPattern))
    }

    @Test
    func aFailedSaveKeepsTheTakeAndAddsNothing() throws {
        // Given
        let container = try Self.makeContainer()
        var store = try Self.makeStore(container)
        defer { try? FileManager.default.removeItem(at: store.audioRoot) }
        store.saveContext = { _ in throw SaveFailed() }
        let take = try Self.pendingTake(store)

        // When
        #expect(throws: SaveFailed.self) {
            try store.add(text: "Half a heart still beats on time", take: take, audioDuration: 3)
        }

        // Then: the take is back where the capture sheet holds it, and no row was made
        #expect(Self.exists(take))
        #expect(!Self.exists(store.audioURL(fileName: take.lastPathComponent)))
        #expect(try container.mainContext.fetch(FetchDescriptor<OneLiner>()).isEmpty)
    }

    @Test
    func aFailedTrashOrEditKeepsTheLineAsItWas() throws {
        // Given
        let container = try Self.makeContainer()
        var store = OneLinersStore(context: container.mainContext)
        let line = try store.add(text: "Found the Lord in a gas station bathroom")
        store.saveContext = { _ in throw SaveFailed() }

        // When
        #expect(throws: SaveFailed.self) { try store.trash(line) }
        #expect(throws: SaveFailed.self) { try store.updateText(line, to: "Half a heart") }

        // Then
        #expect(try store.all().map(\.text) == ["Found the Lord in a gas station bathroom"])
        #expect(line.syllableCount == 10)
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedOneLiner>()).isEmpty)
    }

    @Test
    func restoreDropsEveryTrashCopyAndAStrayCopyNeverDeletesLiveAudio() throws {
        // Given: a line in Trash twice, as two offline devices could leave it
        let container = try Self.makeContainer()
        let store = try Self.makeStore(container)
        defer { try? FileManager.default.removeItem(at: store.audioRoot) }
        let line = try store.add(text: "Every mile marker says your name", take: try Self.pendingTake(store, "mile.m4a"), audioDuration: 4)
        let audio = store.audioURL(fileName: "mile.m4a")
        let trashed = try store.trash(line)
        container.mainContext.insert(TrashedOneLiner(oneLiner: trashed.restoredOneLiner()))
        try container.mainContext.save()

        // When
        try store.restore(trashed)

        // Then
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedOneLiner>()).isEmpty)

        // Given: a stray Trash copy arrives later beside the live line
        let live = try #require(try store.all().first)
        let stray = TrashedOneLiner(oneLiner: live)
        container.mainContext.insert(stray)
        try container.mainContext.save()

        // When
        try store.permanentlyDelete(stray)

        // Then: the copy goes, the audio the live line plays stays
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedOneLiner>()).isEmpty)
        #expect(Self.exists(audio))
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
    func aFailedSendToAClosedSongChangesNeitherTheSongNorTheLine() throws {
        // Given
        let container = try Self.makeContainer()
        var store = OneLinersStore(context: container.mainContext)
        let song = SongProject(title: "Night Train", lyrics: "first")
        container.mainContext.insert(song)
        let line = try store.add(text: "second")
        store.saveContext = { _ in throw SaveFailed() }

        // When
        #expect(throws: SaveFailed.self) { try store.sendToSong(line, project: song, editor: nil) }

        // Then
        #expect(song.lyrics == "first")
        #expect(line.usedInProjectId == nil)
    }

    @Test
    func anAudioOnlyLineHasNoWordsToSend() throws {
        // Given
        let container = try Self.makeContainer()
        let store = OneLinersStore(context: container.mainContext)
        let song = SongProject(title: "Night Train", lyrics: "first")
        container.mainContext.insert(song)
        let line = try store.add(text: "", audioDuration: 4)

        // When
        #expect(throws: OneLinersStoreError.noWords) { try store.sendToSong(line, project: song, editor: nil) }

        // Then
        #expect(song.lyrics == "first")
        #expect(line.usedInProjectId == nil)
    }

    @Test
    func sendingToTheOpenSongInsertsAtTheCursorAndSavesTheSong() throws {
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

        // Then: in the editor and in the saved song, without waiting for autosave
        #expect(editor.lyrics == "first line\nmiddle line\nlast line")
        let songId = song.id
        let saved = try #require(try container.mainContext.fetch(FetchDescriptor<SongProject>(predicate: #Predicate { $0.id == songId })).first)
        #expect(saved.lyrics == "first line\nmiddle line\nlast line")
        #expect(line.usedInProjectId == song.id)
        // One undoable edit, like an inserted suggestion.
        editor.undoLyrics()
        #expect(editor.lyrics == "first line\nlast line")
    }

    @Test
    func permanentDeleteAndExpiryRemoveTheAudioFile() throws {
        // Given
        let container = try Self.makeContainer()
        let store = try Self.makeStore(container)
        defer { try? FileManager.default.removeItem(at: store.audioRoot) }
        let first = try store.add(text: "", take: try Self.pendingTake(store, "a.m4a"), audioDuration: 4)
        let second = try store.add(text: "kept a while", take: try Self.pendingTake(store, "b.m4a"), audioDuration: 11)
        let deletedAt = Date()
        let firstTrashed = try store.trash(first, now: deletedAt)
        try store.trash(second, now: deletedAt)

        // When
        try store.permanentlyDelete(firstTrashed)
        try store.purgeExpired(now: deletedAt.addingTimeInterval(trashRetentionInterval - 1))

        // Then: deleted forever goes now; the other waits out its 30 days
        #expect(!Self.exists(store.audioURL(fileName: "a.m4a")))
        #expect(Self.exists(store.audioURL(fileName: "b.m4a")))
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedOneLiner>()).count == 1)
        #expect(store.nextExpiry(after: deletedAt) == deletedAt.addingTimeInterval(trashRetentionInterval))

        // When
        try store.purgeExpired(now: deletedAt.addingTimeInterval(trashRetentionInterval))

        // Then
        #expect(!Self.exists(store.audioURL(fileName: "b.m4a")))
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedOneLiner>()).isEmpty)
    }

    @Test
    func reconcileRemovesAudioNoRowNamesAndAbandonedTakes() throws {
        // Given
        let container = try Self.makeContainer()
        let store = try Self.makeStore(container)
        defer { try? FileManager.default.removeItem(at: store.audioRoot) }
        let orphan = store.audioURL(fileName: "deleted-elsewhere.m4a")
        try Data("take".utf8).write(to: orphan)
        let oldTake = try Self.pendingTake(store, "left-behind.m4a")

        // When: an empty store (as after an iCloud account change) keeps every file
        try store.reconcileAudioFiles()

        // Then
        #expect(Self.exists(orphan))

        // Given
        try store.add(text: "kept", take: try Self.pendingTake(store, "kept.m4a"))
        let trashed = try store.add(text: "trashed", take: try Self.pendingTake(store, "trashed.m4a"))
        try store.trash(trashed)

        // When
        try store.reconcileAudioFiles(now: Date().addingTimeInterval(OneLinersStore.abandonedTakeAge + 60))

        // Then
        #expect(!Self.exists(orphan))
        #expect(Self.exists(store.audioURL(fileName: "kept.m4a")))
        #expect(Self.exists(store.audioURL(fileName: "trashed.m4a")))
        #expect(!Self.exists(oldTake))

        // When: a take being recorded now is younger than a day
        let current = try Self.pendingTake(store, "current.m4a")
        try store.reconcileAudioFiles()

        // Then
        #expect(Self.exists(current))
    }
}
