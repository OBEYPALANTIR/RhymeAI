import Foundation
import SwiftData
import Testing
@testable import Writers_Block

/// The v4 manifest's canonical form and hash, pinned by a copy of
/// shared/fixtures/sync-manifest-v4.json (Android checks the copy matches).
struct SyncManifestV4Tests {
    private final class FixtureToken {}

    private struct Fixture {
        var manifestData: Data
        var manifest: [String: Any]
        var canonical: String
        var hash: String
        var uploadedBytes: String
    }

    private func fixture() throws -> Fixture {
        let url = try #require(Bundle(for: FixtureToken.self).url(forResource: "sync-manifest-v4", withExtension: "json"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let manifest = try #require(root["manifest"] as? [String: Any])
        return Fixture(
            manifestData: try JSONSerialization.data(withJSONObject: manifest),
            manifest: manifest,
            canonical: try #require(root["canonical"] as? String),
            hash: try #require(root["manifestSha256"] as? String),
            uploadedBytes: try #require(root["uploadedBytes"] as? String)
        )
    }

    @Test func canonicalFormAndHashMatchTheFixture() throws {
        let fixture = try fixture()
        var fields = fixture.manifest
        #expect(fields.removeValue(forKey: "manifestSha256") as? String == fixture.hash)

        let value = try JSONValue(any: fields)

        #expect(CanonicalJSON.string(value) == fixture.canonical)
        #expect(CanonicalJSON.sha256Hex(value) == fixture.hash)
    }

    @Test func fixtureDecodesAndReencodesToTheSameHash() throws {
        let fixture = try fixture()

        let blob = try SyncBlob.decodeManifest(fixture.manifestData)

        #expect(blob.platform == "android")
        #expect(blob.projects.map(\.title) == ["Café Nights", "Plain Song"])
        #expect(blob.projects[0].lyrics == "She said \"stay\" — I said \"why?\"\nNeon on the rain, 夜 again")
        #expect(blob.projects[0].updatedAt == Date(timeIntervalSince1970: 1_792_702_770))
        #expect(blob.trashed.map(\.title) == ["Old Draft"])
        #expect(blob.trashed[0].deletedAt == Date(timeIntervalSince1970: 1_791_793_800))
        #expect(blob.recordings.map(\.fileName) == ["memo_20261022_205500.m4a", "memo_20261021_091000.m4a"])
        #expect(blob.recordings.map { SyncBlob.formatSavedAt($0.uploadedAt) } == ["2026-10-22T21:00:05Z", "2026-10-21T09:12:40Z"])
        #expect(blob.deletions == [
            SyncDeletion(projectId: "5b0c9a7e-1f2d-4c3b-8a6e-0d9f8e7c6b5a", fileName: "memo_20261001_090000.m4a", deletedAt: 1_790_935_200_000),
            SyncDeletion(projectId: "e5f6a7b8-c9d0-4e1f-8a2b-3c4d5e6f7a8b", fileName: nil, deletedAt: 1_792_089_900_000),
        ])
        #expect(SyncBlob.formatSavedAt(blob.savedAt) == "2026-10-22T21:03:11Z")
        #expect(blob.manifestSha256 == fixture.hash)
        #expect(CanonicalJSON.string(blob.jsonValue) == fixture.canonical)
        let written = try blob.encodedManifest()
        #expect(String(decoding: written, as: UTF8.self) == fixture.uploadedBytes)
        #expect(try SyncBlob.decodeManifest(written) == blob)
    }

    @Test func escapingCoversOnlyQuotesBackslashesAndControls() {
        let value = JSONValue.object([
            "b": .string("tab\there \"q\" back\\slash /slash é 🎵 \u{1}\u{1f}\r\n"),
            "a": .array([.int(-3), .null, .bool(true)]),
            "é": .int(1),
            "Z": .int(2),
        ])

        #expect(CanonicalJSON.string(value) == #"{"Z":2,"a":[-3,null,true],"b":"tab\there \"q\" back\\slash /slash é 🎵 \u0001\u001f\r\n","é":1}"#)
    }

    @Test func aChangedCharacterIsRefusedAsDamaged() throws {
        let fixture = try fixture()
        var manifest = fixture.manifest
        var projects = try #require(manifest["projects"] as? [[String: Any]])
        projects[1]["lyrics"] = "Line one\nLine tw0"
        manifest["projects"] = projects

        #expect(throws: SyncManifestError.damaged) {
            _ = try SyncBlob.decodeManifest(try JSONSerialization.data(withJSONObject: manifest))
        }
        var missingHash = fixture.manifest
        missingHash.removeValue(forKey: "manifestSha256")
        #expect(throws: SyncManifestError.damaged) {
            _ = try SyncBlob.decodeManifest(try JSONSerialization.data(withJSONObject: missingHash))
        }
    }

    @Test func aNewerVersionIsRefusedEvenWithAValidHash() throws {
        var fields = try fixture().manifest
        fields.removeValue(forKey: "manifestSha256")
        fields["version"] = 5
        fields["manifestSha256"] = CanonicalJSON.sha256Hex(try JSONValue(any: fields))

        #expect(throws: SyncManifestError.newerVersion(5)) {
            _ = try SyncBlob.decodeManifest(try JSONSerialization.data(withJSONObject: fields))
        }
    }

    @Test func prettyPrintedManifestsAreAccepted() throws {
        let fixture = try fixture()
        let pretty = try JSONSerialization.data(withJSONObject: fixture.manifest, options: [.prettyPrinted, .withoutEscapingSlashes])

        #expect(try SyncBlob.decodeManifest(pretty).manifestSha256 == fixture.hash)
    }
}

extension SyncRecording {
    /// Test entries uploaded at 2023-11-14 unless a test says otherwise.
    init(projectId: String, fileName: String, bytes: Int64, sha256: String) {
        self.init(projectId: projectId, fileName: fileName, bytes: bytes, sha256: sha256, uploadedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

/// Memo files and `Recording` rows kept in step.
@MainActor
struct RecordingLibraryTests {
    private func makeStore(onDisk: Bool) throws -> (container: ModelContainer, root: URL, trash: URL, library: RecordingLibrary) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingLibraryTests-\(UUID().uuidString)", isDirectory: true)
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, Recording.self])
        let configuration = onDisk
            ? ModelConfiguration(schema: schema, url: scratch.appendingPathComponent("library.store"), cloudKitDatabase: .none)
            : ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return (
            try ModelContainer(for: schema, configurations: [configuration]),
            scratch.appendingPathComponent("voice-memos", isDirectory: true),
            scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
            RecordingLibrary(
                memosRoot: scratch.appendingPathComponent("voice-memos", isDirectory: true),
                trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
                defaults: UserDefaults(suiteName: "RecordingLibraryTests-\(scratch.lastPathComponent)")!
            )
        )
    }

    private func write(_ data: Data, _ projectId: String, _ fileName: String, root: URL) throws {
        let folder = root.appendingPathComponent(projectId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(fileName))
    }

    @Test func importsMemosOnceThenWritesRowsFromAnotherDeviceToDisk() throws {
        let store = try makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1, 2, 3]), "song", "take.m4a", root: store.root)

        try store.library.reconcile(context: context)
        try store.library.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.map(\.key) == ["song/take.m4a"])
        #expect(rows.first?.audio == Data([1, 2, 3]))

        // A row synced in from another device becomes a file here.
        context.insert(Recording(projectId: "song", fileName: "remote.m4a", audio: Data([7, 7]), recordedAt: Date()))
        try context.save()
        try store.library.reconcile(context: context)
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/remote.m4a")) == Data([7, 7]))
    }

    @Test func removalsFollowWhereTheyHappened() throws {
        let store = try makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "local.m4a", root: store.root)
        try write(Data([2]), "song", "elsewhere.m4a", root: store.root)
        try store.library.reconcile(context: context)

        // Trashed here: the row goes. Removed on another device: the file moves to Trash.
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("song/local.m4a"))
        for row in try context.fetch(FetchDescriptor<Recording>()) where row.fileName == "elsewhere.m4a" { context.delete(row) }
        try context.save()
        try store.library.reconcile(context: context)

        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/elsewhere.m4a").path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: store.trash.appendingPathComponent("song").path)
        #expect(trashed.count == 1 && trashed[0].hasSuffix("__elsewhere.m4a"))
    }

    @Test func anInMemoryLibraryNeverRemovesAndDuplicatesConverge() throws {
        let store = try makeStore(onDisk: false)
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try store.library.reconcile(context: context)
        for row in try context.fetch(FetchDescriptor<Recording>()) { context.delete(row) }
        try context.save()

        try store.library.reconcile(context: context)

        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/take.m4a").path))
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.key) == ["song/take.m4a"])

        context.insert(Recording(projectId: "song", fileName: "take.m4a", audio: Data([1]), recordedAt: Date()))
        try context.save()
        try store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
    }

    @Test func tombstonedAndOversizedMemosStayOutOfTheLibrary() throws {
        let store = try makeStore(onDisk: true)
        let context = store.container.mainContext
        context.insert(SyncDeletionRecord(projectId: "song", fileName: "deleted.m4a", deletedAt: 4_000_000_000_000))
        try context.save()
        try write(Data([1]), "song", "deleted.m4a", root: store.root)
        try write(Data(count: Int(SyncRecording.maxBytes) + 1), "song", "long.m4a", root: store.root)

        let result = try store.library.reconcile(context: context)

        #expect(result.oversizedCount == 1)
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
    }

    @Test func theFileBeingRecordedIsLeftAloneAndAChangedMemoRefreshesItsRow() throws {
        let store = try makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1, 2]), "song", "take.m4a", root: store.root)
        let url = store.root.appendingPathComponent("song/take.m4a")
        store.library.filesInProgress = { [url] }

        try store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)

        try Data([1, 2, 3, 4]).write(to: url)
        store.library.filesInProgress = { [] }
        try store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.audio) == [Data([1, 2, 3, 4])])

        try Data([5, 6, 7, 8, 9]).write(to: url)
        try store.library.reconcile(context: context)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.audio == Data([5, 6, 7, 8, 9]) && row.bytes == 5 && row.sha256 == RecordingBackupManifest.sha256Hex(Data([5, 6, 7, 8, 9])))
    }

    @Test func anUnreadableFolderAbortsWithoutRemovingAnything() throws {
        let store = try makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try store.library.reconcile(context: context)
        let folder = store.root.appendingPathComponent("song")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        #expect(throws: RecordingLibraryError.scanFailed) { try store.library.reconcile(context: context) }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.key) == ["song/take.m4a"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("take.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: store.trash.path))
    }

    @Test func aMissingMemoRootWithKnownRecordingsAborts() throws {
        let store = try makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try store.library.reconcile(context: context)
        try FileManager.default.moveItem(at: store.root, to: store.root.deletingLastPathComponent().appendingPathComponent("moved-aside"))

        #expect(throws: RecordingLibraryError.scanFailed) { try store.library.reconcile(context: context) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
    }

    @Test func anInterruptedSaveLeavesNothingToTrashOnTheNextRun() throws {
        let store = try makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        store.library.save = { _ in throw CocoaError(.fileWriteUnknown) }

        #expect(throws: CocoaError.self) { try store.library.reconcile(context: context) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)

        store.library.save = { try $0.save() }
        try store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.key) == ["song/take.m4a"])
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/take.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: store.trash.path))
    }

    @Test func aMemosStampedTimeSurvivesRelaunchAndRename() throws {
        let store = try makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1, 2]), "song", "take.m4a", root: store.root)
        let url = store.root.appendingPathComponent("song/take.m4a")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: url.path)
        try store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).first?.uploadedAt == Date(timeIntervalSince1970: 1_000))

        let defaults = UserDefaults(suiteName: "RecordingLibraryTests-\(store.root.deletingLastPathComponent().lastPathComponent)")!
        let relaunched = RecordingLibrary(memosRoot: store.root, trashRoot: store.trash, defaults: defaults)
        try relaunched.reconcile(context: context)
        try FileManager.default.moveItem(at: url, to: store.root.appendingPathComponent("song/renamed.m4a"))
        try relaunched.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.map(\.fileName) == ["renamed.m4a"])
        #expect(rows.first?.uploadedAt == Date(timeIntervalSince1970: 1_000))
        #expect(rows.first?.origin == "recorded")
    }
}

/// Draft-recovery copies never remove or replace a file they did not create.
@MainActor
struct RecordingSnapshotCopyTests {
    private func makeSnapshot() throws -> (snapshot: OpenRecordingSnapshot, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotCopy-\(UUID().uuidString)/voice-memos", isDirectory: true)
        let source = root.appendingPathComponent("song", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([1]).write(to: source.appendingPathComponent("a.m4a"))
        try Data([2]).write(to: source.appendingPathComponent("b.m4a"))
        return (try #require(try OpenRecordingSnapshot(projectId: "song", recordingsRoot: root)), root)
    }

    @Test func aFileAlreadyAtTheDestinationIsKept() throws {
        let (snapshot, root) = try makeSnapshot()
        let destination = root.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data([9]).write(to: destination.appendingPathComponent("a.m4a"))

        try snapshot.copy(to: "copy")

        #expect(try Data(contentsOf: destination.appendingPathComponent("a.m4a")) == Data([9]))
        #expect(try Data(contentsOf: destination.appendingPathComponent("a 2.m4a")) == Data([1]))
        #expect(try Data(contentsOf: destination.appendingPathComponent("b.m4a")) == Data([2]))
    }

    @Test func rollbackRemovesOnlyItsOwnUnchangedFiles() throws {
        let (snapshot, root) = try makeSnapshot()
        let destination = root.appendingPathComponent("copy", isDirectory: true)
        try snapshot.copy(to: "copy")
        // Something replaced one copy and added another file before the rollback.
        try FileManager.default.removeItem(at: destination.appendingPathComponent("b.m4a"))
        try Data([7]).write(to: destination.appendingPathComponent("b.m4a"))
        try Data([8]).write(to: destination.appendingPathComponent("c.m4a"))

        snapshot.removeCopy(for: "copy")

        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.m4a").path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("b.m4a")) == Data([7]))
        #expect(try Data(contentsOf: destination.appendingPathComponent("c.m4a")) == Data([8]))
    }
}
