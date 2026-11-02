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

    private static func age(_ url: URL, by interval: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-interval)], ofItemAtPath: url.path)
    }

    /// What another context on the same container reads: only what was saved.
    private static func savedSong(_ id: String, in container: ModelContainer) throws -> SongProject? {
        try ModelContext(container).fetch(FetchDescriptor<SongProject>(predicate: #Predicate { $0.id == id })).first
    }

    /// Lets a test fail the editor's saves after the song is open.
    private final class SaveSwitch {
        var fails = false
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
        let failure = #expect(throws: OneLinerSaveFailure.self) {
            try store.add(text: "Half a heart still beats on time", take: take, audioDuration: 3)
        }

        // Then: the take is back where the capture sheet holds it, and no row was made
        #expect(failure?.takeNowAt == take)
        #expect(Self.exists(take))
        #expect(!Self.exists(store.audioURL(fileName: take.lastPathComponent)))
        #expect(try container.mainContext.fetch(FetchDescriptor<OneLiner>()).isEmpty)
    }

    @Test
    func aFailedMoveBackReportsWhereTheTakeIsAndARetryAdoptsIt() throws {
        // Given: the save fails, and so does moving the take back to pending
        let container = try Self.makeContainer()
        var store = try Self.makeStore(container)
        defer { try? FileManager.default.removeItem(at: store.audioRoot) }
        let take = try Self.pendingTake(store, "stranded.m4a")
        var moves = 0
        store.moveItem = { from, to in
            moves += 1
            if moves > 1 { throw SaveFailed() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        store.saveContext = { _ in throw SaveFailed() }

        // When
        let failure = #expect(throws: OneLinerSaveFailure.self) {
            try store.add(text: "kept", take: take, audioDuration: 2)
        }

        // Then
        let adopted = store.audioURL(fileName: "stranded.m4a")
        #expect(failure?.takeNowAt == adopted)
        #expect(Self.exists(adopted))

        // When: the retry starts from where the take really is
        store.saveContext = { try $0.save() }
        let line = try store.add(text: "kept", take: try #require(failure?.takeNowAt), audioDuration: 2)

        // Then
        #expect(line.audioFileName == "stranded.m4a")
        #expect(Self.exists(adopted))
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

        // Then: in the editor and in the saved store, without waiting for autosave
        #expect(editor.lyrics == "first line\nmiddle line\nlast line")
        #expect(try Self.savedSong(song.id, in: container)?.lyrics == "first line\nmiddle line\nlast line")
        #expect(line.usedInProjectId == song.id)
        // One undoable edit, like an inserted suggestion.
        editor.undoLyrics()
        #expect(editor.lyrics == "first line\nlast line")
    }

    @Test
    func aFailedSaveOfTheOpenSongPutsTheSongAndTheMarkerBack() throws {
        // Given
        let container = try Self.makeContainer()
        let store = OneLinersStore(context: container.mainContext)
        let song = SongProject(title: "Night Train", lyrics: "first line\nlast line")
        container.mainContext.insert(song)
        try container.mainContext.save()
        let saves = SaveSwitch()
        let editor = EditorViewModel(saveModelContext: { context in
            if saves.fails { throw SaveFailed() }
            try context.save()
        })
        editor.modelContext = container.mainContext
        editor.loadProject(song)
        editor.cursorPosition = ("first line" as NSString).length
        let line = try store.add(text: "middle line")
        let snapshot = (song.lyrics, song.updatedAt, song.precedenceRepaired)
        saves.fails = true

        // When
        #expect(throws: OneLinersStoreError.songNotSaved) {
            try store.sendToSong(line, project: song, editor: editor)
        }

        // Then: the store holds the song as it was, and the line is not marked used
        let saved = try #require(try Self.savedSong(song.id, in: container))
        #expect((saved.lyrics, saved.updatedAt, saved.precedenceRepaired) == snapshot)
        let lineId = line.id
        let savedLine = try #require(try ModelContext(container).fetch(FetchDescriptor<OneLiner>(predicate: #Predicate { $0.id == lineId })).first)
        #expect(savedLine.usedInProjectId == nil)
        #expect(editor.lyrics == "first line\nlast line")
    }

    @Test
    func trashingALineSchedulesTheTrashPurge() throws {
        // Given
        let container = try Self.makeContainer()
        let editor = EditorViewModel()
        editor.modelContext = container.mainContext
        var store = OneLinersStore(context: container.mainContext)
        store.onTrashed = { editor.scheduleTrashPurge() }
        let line = try store.add(text: "Half a heart still beats on time")
        #expect(!editor.hasScheduledTrashPurge)

        // When
        try store.trash(line)

        // Then
        #expect(editor.hasScheduledTrashPurge)
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
    func aFailedPermanentDeleteKeepsTheRowAndItsAudio() throws {
        // Given
        let container = try Self.makeContainer()
        var store = try Self.makeStore(container)
        defer { try? FileManager.default.removeItem(at: store.audioRoot) }
        let line = try store.add(text: "kept", take: try Self.pendingTake(store, "kept.m4a"), audioDuration: 2)
        let trashed = try store.trash(line)
        let audio = store.audioURL(fileName: "kept.m4a")
        store.saveContext = { _ in throw SaveFailed() }

        // When
        #expect(throws: SaveFailed.self) { try store.permanentlyDelete(trashed) }

        // Then: still restorable, with its take
        #expect(Self.exists(audio))
        #expect(try container.mainContext.fetch(FetchDescriptor<TrashedOneLiner>()).count == 1)

        // When
        store.saveContext = { try $0.save() }
        try store.permanentlyDelete(trashed)

        // Then: the set-aside copy goes once the row's removal is saved
        #expect(!Self.exists(audio))
        #expect(!Self.exists(store.deletingRoot.appendingPathComponent("kept.m4a")))
    }

    @Test
    func reconcileNeverDeletesMainFolderAudioAndRecoversInterruptedDeletes() throws {
        // Given
        let container = try Self.makeContainer()
        let store = try Self.makeStore(container)
        defer { try? FileManager.default.removeItem(at: store.audioRoot) }
        try FileManager.default.createDirectory(at: store.deletingRoot, withIntermediateDirectories: true)
        // A take no row names yet, as while iCloud fills the store again.
        let orphan = store.audioURL(fileName: "still-syncing.m4a")
        try Data("take".utf8).write(to: orphan)
        try Self.age(orphan, by: 30 * 24 * 60 * 60)
        // A delete that set its audio aside and stopped before its save: the row survives.
        try store.add(text: "kept", take: try Self.pendingTake(store, "interrupted.m4a"))
        let interrupted = store.deletingRoot.appendingPathComponent("interrupted.m4a")
        try FileManager.default.moveItem(at: store.audioURL(fileName: "interrupted.m4a"), to: interrupted)
        // A finished delete whose set-aside copy was left behind.
        let leftover = store.deletingRoot.appendingPathComponent("deleted.m4a")
        try Data("take".utf8).write(to: leftover)
        try Self.age(leftover, by: 8 * 24 * 60 * 60)
        let recordingNow = try Self.pendingTake(store, "recording-now.m4a")
        let abandoned = try Self.pendingTake(store, "left-behind.m4a")
        try Self.age(abandoned, by: 2 * 24 * 60 * 60)

        // When
        try store.reconcileAudioFiles()

        // Then
        #expect(Self.exists(orphan))
        #expect(Self.exists(store.audioURL(fileName: "interrupted.m4a")))
        #expect(!Self.exists(interrupted))
        #expect(!Self.exists(leftover))
        #expect(Self.exists(recordingNow))
        #expect(!Self.exists(abandoned))
    }
}
