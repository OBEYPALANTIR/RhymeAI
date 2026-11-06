import Foundation
import SwiftData
import Testing
@testable import Writers_Block

@MainActor
struct OneLinersSnapshotTests {
    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self,
            Recording.self, OneLiner.self, TrashedOneLiner.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// A store that writes its snapshot into a temporary folder of its own.
    private static func makeStore(_ container: ModelContainer) -> (OneLinersStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        var store = OneLinersStore(context: container.mainContext, audioRoot: folder.appendingPathComponent("audio", isDirectory: true))
        store.snapshotURL = folder.appendingPathComponent("one-liners-snapshot.json")
        return (store, store.snapshotURL!)
    }

    @Test
    func snapshotFollowsAddTrashAndRestore() throws {
        // Given
        let container = try Self.makeContainer()
        let (store, url) = Self.makeStore(container)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try store.add(text: "Found the Lord in a gas station bathroom", now: start)
        try store.add(text: "Nobody warned me love was a layaway plan", now: start.addingTimeInterval(60))
        try store.add(text: "Half a heart still beats on time", now: start.addingTimeInterval(120))

        // When
        let newest = try store.add(text: "Every mile marker says your name", now: start.addingTimeInterval(180))

        // Then: four lines, the newest three, newest first
        let added = try #require(OneLinersSnapshot.read(from: url))
        #expect(added.count == 4)
        #expect(added.lines.map(\.text) == [
            "Every mile marker says your name",
            "Half a heart still beats on time",
            "Nobody warned me love was a layaway plan",
        ])
        #expect(added.lines.first?.id == newest.id)
        #expect(added.lines.first?.createdAt == start.addingTimeInterval(180))
        #expect(added.lines.allSatisfy { !$0.hasAudio })

        // When
        let trashed = try store.trash(newest)

        // Then: the next line moves up and the oldest comes back into view
        let afterTrash = try #require(OneLinersSnapshot.read(from: url))
        #expect(afterTrash.count == 3)
        #expect(afterTrash.lines.map(\.text) == [
            "Half a heart still beats on time",
            "Nobody warned me love was a layaway plan",
            "Found the Lord in a gas station bathroom",
        ])

        // When
        try store.restore(trashed)

        // Then
        let afterRestore = try #require(OneLinersSnapshot.read(from: url))
        #expect(afterRestore == added)
    }

    @Test
    func snapshotMarksAudioAndCarriesTheAppearance() throws {
        // Given
        let container = try Self.makeContainer()
        let (store, url) = Self.makeStore(container)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.pendingRoot, withIntermediateDirectories: true)
        let take = store.pendingRoot.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("take".utf8).write(to: take)

        // When
        try store.add(text: "", take: take, audioDuration: 3)

        // Then
        let snapshot = try #require(OneLinersSnapshot.read(from: url))
        #expect(snapshot.count == 1)
        #expect(snapshot.lines.first?.hasAudio == true)
        let stored = AppAppearanceStyle.resolve(UserDefaults.standard.string(forKey: AppAppearanceStyle.storageKey))
        #expect(snapshot.appearance == stored.rawValue)
    }

    @Test
    func failedSaveLeavesTheSnapshotAsItWas() throws {
        // Given
        let container = try Self.makeContainer()
        let (made, url) = Self.makeStore(container)
        var store = made
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try store.add(text: "Half a heart still beats on time")
        let before = try #require(OneLinersSnapshot.read(from: url))
        store.saveContext = { _ in throw CocoaError(.fileWriteUnknown) }

        // When
        #expect(throws: CocoaError.self) { try store.add(text: "Never saved") }

        // Then
        #expect(OneLinersSnapshot.read(from: url) == before)
    }

    @Test
    func publishSkipsAnUnchangedSnapshot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = OneLinersSnapshot(count: 1, lines: [], appearance: "paper")
        #expect(try snapshot.publish(to: url))
        #expect(try !snapshot.publish(to: url))
        #expect(OneLinersSnapshot.read(from: url) == snapshot)
    }
}
