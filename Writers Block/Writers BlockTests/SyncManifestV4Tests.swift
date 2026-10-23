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

    @Test func canonicalFormAndHashMatchTheFixture() async throws {
        let fixture = try fixture()
        var fields = fixture.manifest
        #expect(fields.removeValue(forKey: "manifestSha256") as? String == fixture.hash)

        let value = try JSONValue(any: fields)

        #expect(CanonicalJSON.string(value) == fixture.canonical)
        #expect(CanonicalJSON.sha256Hex(value) == fixture.hash)
    }

    @Test func fixtureDecodesAndReencodesToTheSameHash() async throws {
        let fixture = try fixture()

        let blob = try SyncBlob.decodeManifest(fixture.manifestData)

        #expect(blob.platform == "android")
        #expect(blob.projects.map(\.title) == ["Café Nights", "Plain Song"])
        #expect(blob.projects[0].lyrics == "She said \"stay\" — I said \"why?\"\nNeon on the rain, 夜 again")
        // Every precedence time keeps its milliseconds.
        #expect(blob.projects[0].updatedAt.epochMilliseconds == 1_792_702_770_417)
        #expect(blob.trashed.map(\.title) == ["Old Draft"])
        #expect(blob.trashed[0].deletedAt.epochMilliseconds == 1_791_793_800_250)
        #expect(blob.recordings.map(\.id) == ["0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", "7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2"])
        #expect(blob.recordings.map(\.driveName) == ["rec_0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", "rec_7d6c5b4a-3e2f-4a1b-9c8d-e7f6a5b4c3d2"])
        #expect(blob.recordings.map(\.fileName) == ["memo_20261022_205500.m4a", "memo_20261021_091000.m4a"])
        #expect(blob.recordings.map(\.uploadedAt.epochMilliseconds) == [1_792_702_805_123, 1_792_573_960_908])
        #expect(blob.deletions == [
            SyncDeletion(projectId: "5b0c9a7e-1f2d-4c3b-8a6e-0d9f8e7c6b5a", recordingId: "b2a1c3d4-e5f6-4789-8abc-def012345678",
                         fileName: "memo_20261001_090000.m4a", deletedAt: 1_790_935_200_501),
            SyncDeletion(projectId: "e5f6a7b8-c9d0-4e1f-8a2b-3c4d5e6f7a8b", fileName: nil, deletedAt: 1_792_089_900_077),
        ])
        #expect(SyncBlob.formatSavedAt(blob.savedAt) == "2026-10-22T21:03:11.123Z")
        #expect(blob.manifestSha256 == fixture.hash)
        #expect(CanonicalJSON.string(blob.jsonValue) == fixture.canonical)
        let written = try blob.encodedManifest()
        #expect(String(decoding: written, as: UTF8.self) == fixture.uploadedBytes)
        #expect(try SyncBlob.decodeManifest(written) == blob)
    }

    @Test func recordingsFromBeforeV4GetTheIdEveryDeviceDerives() async {
        // Java's UUID.nameUUIDFromBytes over the same string gives this value.
        #expect(RecordingBackupManifest.legacyRecordingId(projectId: "old-song", fileName: "take.m4a", sha256: String(repeating: "ab", count: 32))
                == "b51b24cd-da93-393e-974b-0bd4efe9e243")
        #expect(RecordingBackupManifest.legacyRecordingId(projectId: "old-song", fileName: "take.m4a", sha256: String(repeating: "AB", count: 32))
                == "b51b24cd-da93-393e-974b-0bd4efe9e243")
    }

    @Test func escapingCoversOnlyQuotesBackslashesAndControls() async {
        let value = JSONValue.object([
            "b": .string("tab\there \"q\" back\\slash /slash é 🎵 \u{1}\u{1f}\r\n"),
            "a": .array([.int(-3), .null, .bool(true)]),
            "é": .int(1),
            "Z": .int(2),
        ])

        #expect(CanonicalJSON.string(value) == #"{"Z":2,"a":[-3,null,true],"b":"tab\there \"q\" back\\slash /slash é 🎵 \u0001\u001f\r\n","é":1}"#)
    }

    @Test func aChangedCharacterIsRefusedAsDamaged() async throws {
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

    @Test func aNewerVersionIsRefusedEvenWithAValidHash() async throws {
        var fields = try fixture().manifest
        fields.removeValue(forKey: "manifestSha256")
        fields["version"] = 5
        fields["manifestSha256"] = CanonicalJSON.sha256Hex(try JSONValue(any: fields))

        #expect(throws: SyncManifestError.newerVersion(5)) {
            _ = try SyncBlob.decodeManifest(try JSONSerialization.data(withJSONObject: fields))
        }
    }

    @Test func prettyPrintedManifestsAreAccepted() async throws {
        let fixture = try fixture()
        let pretty = try JSONSerialization.data(withJSONObject: fixture.manifest, options: [.prettyPrinted, .withoutEscapingSlashes])

        #expect(try SyncBlob.decodeManifest(pretty).manifestSha256 == fixture.hash)
    }
}

extension Recording {
    /// Tests: where the live file is ("projectId/fileName").
    var key: String { "\(projectId)/\(fileName)" }
}

extension SyncRecording {
    /// Test entries: id derived from project and name, uploaded 2023-11-14 unless a test says otherwise.
    init(projectId: String, fileName: String, bytes: Int64, sha256: String, uploadedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.init(id: "\(projectId)~\(fileName)", projectId: projectId, fileName: fileName, bytes: bytes, sha256: sha256, uploadedAt: uploadedAt)
    }
}

/// Memo files and `Recording` rows kept in step.
@MainActor
struct RecordingLibraryTests {
    /// A library over a fresh store, checked once (changes need a successful check, A33).
    private func makeStore(onDisk: Bool) async throws -> (container: ModelContainer, root: URL, trash: URL, library: RecordingLibrary) {
        let store = try makeUncheckedStore(onDisk: onDisk)
        try await store.library.reconcile(context: store.container.mainContext)
        return store
    }

    private func makeUncheckedStore(onDisk: Bool) throws -> (container: ModelContainer, root: URL, trash: URL, library: RecordingLibrary) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingLibraryTests-\(UUID().uuidString)", isDirectory: true)
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
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

    @Test func importsMemosOnceThenWritesRowsFromAnotherDeviceToDisk() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1, 2, 3]), "song", "take.m4a", root: store.root)

        try await store.library.reconcile(context: context)
        try await store.library.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.map(\.key) == ["song/take.m4a"])
        #expect(rows.first?.audio == Data([1, 2, 3]))

        // A row synced in from another device becomes a file here.
        context.insert(Recording(projectId: "song", fileName: "remote.m4a", audio: Data([7, 7]), recordedAt: Date()))
        try context.save()
        try await store.library.reconcile(context: context)
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/remote.m4a")) == Data([7, 7]))
    }

    @Test func rowsAreTheTruthAndRowsRemovedElsewhereSendFilesToTrash() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "local.m4a", root: store.root)
        try write(Data([2]), "song", "elsewhere.m4a", root: store.root)
        try await store.library.reconcile(context: context)

        // A file lost outside the library comes back from its row; a row removed on
        // another device sends its file to the recordings Trash.
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("song/local.m4a"))
        for row in try context.fetch(FetchDescriptor<Recording>()) where row.fileName == "elsewhere.m4a" { context.delete(row) }
        try context.save()
        try await store.library.reconcile(context: context)

        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.fileName) == ["local.m4a"])
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/local.m4a")) == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/elsewhere.m4a").path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: store.trash.appendingPathComponent("song").path)
        #expect(trashed.count == 1 && trashed[0].hasSuffix("__elsewhere.m4a"))
    }

    @Test func anInMemoryLibraryNeverRemovesAndDuplicatesConverge() async throws {
        let store = try await makeStore(onDisk: false)
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try await store.library.reconcile(context: context)
        for row in try context.fetch(FetchDescriptor<Recording>()) { context.delete(row) }
        try context.save()

        try await store.library.reconcile(context: context)

        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/take.m4a").path))
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.key) == ["song/take.m4a"])

        // The same id twice is one recording; a distinct id with the same bytes and
        // name stays a recording of its own, under a free name.
        let id = try #require(context.fetch(FetchDescriptor<Recording>()).first?.id)
        context.insert(Recording(id: id, projectId: "song", fileName: "take.m4a", audio: Data([1]), recordedAt: Date()))
        context.insert(Recording(projectId: "song", fileName: "take.m4a", audio: Data([1]), recordedAt: Date()))
        try context.save()
        try await store.library.reconcile(context: context)
        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.fileName)) == ["take.m4a", "take 2.m4a"])
        #expect(rows.first { $0.fileName == "take.m4a" }?.id == id)
    }

    @Test func tombstonedAndOversizedMemosStayOutOfTheLibrary() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        context.insert(SyncDeletionRecord(projectId: "song", fileName: "deleted.m4a", deletedAt: 4_000_000_000_000))
        try context.save()
        try write(Data([1]), "song", "deleted.m4a", root: store.root)
        try write(Data(count: Int(SyncRecording.maxBytes) + 1), "song", "long.m4a", root: store.root)

        let result = try await store.library.reconcile(context: context)

        #expect(result.oversizedCount == 1)
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
    }

    @Test func adoptedFilesGetDerivedIdsAndNewRecordingsRandomOnes() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1, 2]), "song", "old.m4a", root: store.root)
        try await store.library.reconcile(context: context)
        store.library.context = context
        _ = try store.library.publishFinished(try stage(Data([3])), projectId: "song", preferredName: "new.m4a", origin: .recorded)

        let rows = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Recording>()).map { ($0.fileName, $0.id) })
        #expect(rows["old.m4a"] == RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "old.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([1, 2]))))
        #expect(rows["new.m4a"] != RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "new.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([3]))))
    }

    @Test func bytesChangedAtARowsPathNeverReplaceItsAudio() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1, 2, 3, 4]), "song", "take.m4a", root: store.root)
        let url = store.root.appendingPathComponent("song/take.m4a")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: url.path)
        try await store.library.reconcile(context: context)
        let id = try #require(context.fetch(FetchDescriptor<Recording>()).first?.id)

        // Same size, other bytes: a path claim, not the row's audio.
        try Data([5, 6, 7, 8]).write(to: url)
        try await store.library.reconcile(context: context)

        let rows = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0) })
        #expect(rows[id]?.audio == Data([1, 2, 3, 4]) && rows[id]?.fileName == "take.m4a")
        #expect(try Data(contentsOf: url) == Data([1, 2, 3, 4]))
        let other = try #require(rows.values.first { $0.id != id })
        #expect(other.fileName == "take 2.m4a" && other.audio == Data([5, 6, 7, 8]))
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/take 2.m4a")) == Data([5, 6, 7, 8]))
    }

    @Test func aRemoteRenameSwapKeepsEachIdsOwnBytes() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        context.insert(Recording(id: "a", projectId: "song", fileName: "foo.m4a", audio: Data([0xA, 0xA]), recordedAt: Date(timeIntervalSince1970: 1)))
        context.insert(Recording(id: "b", projectId: "song", fileName: "bar.m4a", audio: Data([0xB, 0xB]), recordedAt: Date(timeIntervalSince1970: 2)))
        try context.save()
        try await store.library.reconcile(context: context)

        // Another device swapped the names; the files here are equal in size.
        let rows = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0) })
        rows["a"]?.fileName = "bar.m4a"
        rows["a"]?.claimedName = "bar.m4a"
        rows["b"]?.fileName = "foo.m4a"
        rows["b"]?.claimedName = "foo.m4a"
        try context.save()
        try await store.library.reconcile(context: context)

        #expect(rows["a"]?.audio == Data([0xA, 0xA]) && rows["b"]?.audio == Data([0xB, 0xB]))
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/bar.m4a")) == Data([0xA, 0xA]))
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/foo.m4a")) == Data([0xB, 0xB]))
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 2)
    }

    @Test func nameCollisionsConvergeWhicheverOccupantCameFirst() async throws {
        func device(_ order: [String]) async throws -> [String: String] {
            let store = try await makeStore(onDisk: true)
            let context = store.container.mainContext
            let made = [
                "late": Recording(id: "late", projectId: "song", fileName: "take.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 2_000)),
                "early": Recording(id: "early", projectId: "song", fileName: "take.m4a", audio: Data([2]), recordedAt: Date(timeIntervalSince1970: 1_000)),
            ]
            for id in order {
                context.insert(try #require(made[id]))
                try context.save()
                try await store.library.reconcile(context: context)
            }
            // Further runs change nothing: no renaming loop.
            let settled = try context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0.fileName) }
            try await store.library.reconcile(context: context)
            #expect(try context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0.fileName) }.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }
                    == settled.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" })
            #expect(try Data(contentsOf: store.root.appendingPathComponent("song/take.m4a")) == Data([2]))
            #expect(try Data(contentsOf: store.root.appendingPathComponent("song/take 2.m4a")) == Data([1]))
            return Dictionary(uniqueKeysWithValues: settled)
        }
        let first = try await device(["late", "early"])
        let second = try await device(["early", "late"])
        #expect(first == second && first == ["early": "take.m4a", "late": "take 2.m4a"])
    }

    @Test func anUnreadableQuarantineRecordSuspendsAdoptionAndHidesTheLists() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        let record = RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("pending-moves.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: record)

        await #expect(throws: (any Error).self) { try await store.library.reconcile(context: context) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(RecordingFiles.pendingQuarantine(for: store.root) == nil)
        try write(Data([2]), "song", "1000__old.m4a", root: store.trash)
        #expect(RecordingFiles.trashedMemos(in: store.trash).isEmpty)
        #expect(FileManager.default.fileExists(atPath: record.path))

        // A missing record is simply empty.
        try FileManager.default.removeItem(at: record)
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 2)
    }

    private func stage(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)/take.m4a")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @Test func identicalBytesReimportedAfterDeletionAreANewRecording() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        store.library.context = context
        let first = try store.library.publishFinished(try stage(Data([1, 2])), projectId: "song", preferredName: "take.m4a", origin: .imported)
        let oldId = try #require(context.fetch(FetchDescriptor<Recording>()).first?.id)
        // Deleted for good: tombstoned by id, row and file gone.
        try RecordingLibrary.upsertTombstone(SyncDeletion(projectId: "song", recordingId: oldId, fileName: "take.m4a", deletedAt: Date().epochMilliseconds), in: context)
        for row in try context.fetch(FetchDescriptor<Recording>()) { context.delete(row) }
        try context.save()
        try FileManager.default.removeItem(at: first)

        _ = try store.library.publishFinished(try stage(Data([1, 2])), projectId: "song", preferredName: "take.m4a", origin: .imported)
        try await store.library.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.count == 1 && rows[0].id != oldId && rows[0].fileName == "take.m4a")
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test func aLiveAndATrashedRecordingWithOneNameKeepBothRows() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        store.library.context = context
        let live = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let trashURL = store.trash.appendingPathComponent("song/1000__take.m4a")
        try store.library.trashRecording(at: live, to: trashURL, trashedAt: Date(timeIntervalSince1970: 1))
        _ = try store.library.publishFinished(try stage(Data([2])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        try await store.library.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>()).sorted { $0.audio.first! < $1.audio.first! }
        #expect(rows.count == 2)
        #expect(rows[0].trashedAt != nil && rows[1].trashedAt == nil)
        #expect(rows.map(\.fileName) == ["take.m4a", "take.m4a"])
        #expect(try Data(contentsOf: trashURL) == Data([1]) && Data(contentsOf: live) == Data([2]))

        // Restoring it from Trash keeps its id and time, under a free name.
        let trashedRow = rows[0]
        let trashed = try #require(RecordingFiles.trashedMemos(in: store.trash).first)
        let target = RecordingFiles.restoredURL(originalName: "take.m4a", folder: live.deletingLastPathComponent())
        try store.library.untrashRecording(trashed, to: target)
        #expect(trashedRow.trashedAt == nil && trashedRow.fileName == "take 2.m4a" && trashedRow.uploadedAt == rows[0].uploadedAt)
    }

    @Test func aFailedMetadataWriteFailsTheChangeAndLeavesFilesAlone() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        store.library.context = context
        let live = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        store.library.save = { _ in throw CocoaError(.fileWriteUnknown) }

        let renamed = live.deletingLastPathComponent().appendingPathComponent("renamed.m4a")
        #expect(throws: CocoaError.self) { try store.library.renameRecording(at: live, to: renamed) }
        #expect(FileManager.default.fileExists(atPath: live.path) && !FileManager.default.fileExists(atPath: renamed.path))
        #expect(throws: CocoaError.self) { try store.library.trashRecording(at: live, to: store.trash.appendingPathComponent("song/1__take.m4a"), trashedAt: Date()) }
        #expect(FileManager.default.fileExists(atPath: live.path))
        let staged = try stage(Data([2]))
        #expect(throws: CocoaError.self) { _ = try store.library.publishFinished(staged, projectId: "song", preferredName: "new.m4a", origin: .recorded) }
        #expect(FileManager.default.fileExists(atPath: staged.path))
        let entry = SyncRecording(id: "restored", projectId: "song", fileName: "restored.m4a", bytes: 1, sha256: RecordingBackupManifest.sha256Hex(Data([3])), uploadedAt: Date(timeIntervalSince1970: 5))
        #expect(throws: CocoaError.self) { try store.library.commitRestored(Data([3]), entry: entry, origin: .restored, context: context) }
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/restored.m4a").path))

        store.library.save = { try $0.save() }
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.fileName) == ["take.m4a"])
    }

    @Test func anInterruptedMoveIsFinishedOnTheNextRun() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        store.library.context = context
        let live = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        // The rename's intent was saved, then the app stopped before the move.
        row.fileName = "renamed.m4a"
        row.claimedName = "renamed.m4a"
        row.pendingFrom = live.path
        try context.save()

        try await store.library.reconcile(context: context)

        #expect(row.pendingFrom == nil)
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/renamed.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
    }

    @Test func anUnreadableFolderAbortsWithoutRemovingAnything() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try await store.library.reconcile(context: context)
        let folder = store.root.appendingPathComponent("song")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        await #expect(throws: RecordingLibraryError.scanFailed) { try await store.library.reconcile(context: context) }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.key) == ["song/take.m4a"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("take.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: store.trash.path))
    }

    @Test func aMissingMemoRootWithKnownRecordingsAborts() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try await store.library.reconcile(context: context)
        try FileManager.default.moveItem(at: store.root, to: store.root.deletingLastPathComponent().appendingPathComponent("moved-aside"))

        await #expect(throws: RecordingLibraryError.scanFailed) { try await store.library.reconcile(context: context) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
    }

    @Test func anInterruptedSaveLeavesNothingToTrashOnTheNextRun() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        store.library.save = { _ in throw CocoaError(.fileWriteUnknown) }

        await #expect(throws: CocoaError.self) { try await store.library.reconcile(context: context) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)

        store.library.save = { try $0.save() }
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.key) == ["song/take.m4a"])
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/take.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: store.trash.path))
    }

    @Test func aMemosStampedTimeSurvivesRelaunchAndRename() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1, 2]), "song", "take.m4a", root: store.root)
        let url = store.root.appendingPathComponent("song/take.m4a")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: url.path)
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).first?.uploadedAt == Date(timeIntervalSince1970: 1_000))

        let defaults = UserDefaults(suiteName: "RecordingLibraryTests-\(store.root.deletingLastPathComponent().lastPathComponent)")!
        let relaunched = RecordingLibrary(memosRoot: store.root, trashRoot: store.trash, defaults: defaults)
        try await relaunched.reconcile(context: context)
        relaunched.context = context
        try relaunched.renameRecording(at: url, to: store.root.appendingPathComponent("song/renamed.m4a"))
        try await relaunched.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.map(\.fileName) == ["renamed.m4a"])
        #expect(rows.first?.uploadedAt == Date(timeIntervalSince1970: 1_000))
        #expect(rows.first?.origin == "recorded")
    }

    @Test func aRowArrivingWithATakenNameKeepsItsOwnBytesUnderAFreeName() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([0xB]), "song", "take.m4a", root: store.root)
        try await store.library.reconcile(context: context)
        let local = try #require(context.fetch(FetchDescriptor<Recording>()).first)

        // iCloud delivers another device's recording "a" with the same name.
        context.insert(Recording(id: "a", projectId: "song", fileName: "take.m4a", audio: Data([0xA]), recordedAt: Date()))
        try context.save()
        try await store.library.reconcile(context: context)

        let rows = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0) })
        #expect(rows.count == 2)
        #expect(rows[local.id]?.fileName == "take.m4a" && rows[local.id]?.audio == Data([0xB]))
        #expect(rows["a"]?.fileName == "take 2.m4a" && rows["a"]?.audio == Data([0xA]))
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/take.m4a")) == Data([0xB]))
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/take 2.m4a")) == Data([0xA]))
    }

    @Test func aSongDeletionAdoptsUnstampedFilesThenTombstonesThemById() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        context.insert(SyncDeletionRecord(projectId: "song", deletedAt: 4_000_000_000_000))
        try context.save()
        try write(Data([1]), "song", "live.m4a", root: store.root)
        try write(Data([2]), "song", "1000__trashed.m4a", root: store.trash)

        try await store.library.reconcile(context: context)

        let ids = Set(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).map(\.recordingId))
        #expect(ids == [
            RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "live.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([1]))),
            RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "trashed.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([2]))),
        ])
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/live.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: store.trash.appendingPathComponent("song/1000__trashed.m4a").path))
    }

    @Test func aNameTombstoneMatchesOnlyTheIdDerivedForThatName() async {
        let digest = RecordingBackupManifest.sha256Hex(Data([1]))
        let tombstone = SyncDeletion(projectId: "song", fileName: "take.m4a", deletedAt: 5_000)
        let derived = RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "take.m4a", sha256: digest)
        #expect(tombstone.covers(projectId: "song", recordingId: derived, sha256: digest, at: Date(timeIntervalSince1970: 1)))
        #expect(!tombstone.covers(projectId: "song", recordingId: "3f0c8a51-0000-4000-8000-000000000001", sha256: digest, at: Date(timeIntervalSince1970: 1)))
    }

    @Test func trashEntriesFromBeforeV4GetDerivedIdsAndTheirTrashTime() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        store.library.context = context
        try write(Data([1]), "song", "5000__old.m4a", root: store.trash)
        try await store.library.reconcile(context: context)

        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.id == RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "old.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([1]))))
        #expect(row.trashedAt == Date(timeIntervalSince1970: 5))

        // A rowless Trash entry seen later is adopted, with its derived id, before it moves.
        try write(Data([2]), "song", "6000__late.m4a", root: store.trash)
        let late = try #require(RecordingFiles.trashedMemos(in: store.trash).first { $0.originalName == "late.m4a" })
        try store.library.untrashRecording(late, to: store.root.appendingPathComponent("song/late.m4a"))
        let restored = try #require(context.fetch(FetchDescriptor<Recording>()).first { $0.fileName == "late.m4a" })
        #expect(restored.id == RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "late.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([2]))))
        #expect(restored.trashedAt == nil && restored.pendingFrom == nil)
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/late.m4a")) == Data([2]))
    }

    @Test func anInterruptedMoveOntoATakenNameSavesAFreeNameAndNeverTakesOtherBytes() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        store.library.context = context
        let live = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        row.fileName = "renamed.m4a"
        row.claimedName = "renamed.m4a"
        row.pendingFrom = live.path
        try context.save()
        // Something else, made later, took the destination before the move ran.
        try write(Data([9]), "song", "renamed.m4a", root: store.root)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: store.root.appendingPathComponent("song/renamed.m4a").path)

        try await store.library.reconcile(context: context)

        // The earlier recording keeps the name (A30); the other bytes keep theirs under "renamed 2".
        #expect(row.pendingFrom == nil && row.fileName == "renamed.m4a" && row.audio == Data([1]))
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/renamed.m4a")) == Data([1]))
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/renamed 2.m4a")) == Data([9]))
    }

    @Test func anIntentWhoseSourceHoldsOtherBytesStaysPending() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        store.library.context = context
        let live = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        let other = store.root.appendingPathComponent("song/other.m4a")
        try write(Data([7]), "song", "other.m4a", root: store.root)
        try FileManager.default.removeItem(at: live)
        row.fileName = "renamed.m4a"
        row.claimedName = "renamed.m4a"
        row.pendingFrom = other.path
        try context.save()

        try await store.library.reconcile(context: context)

        #expect(row.audio == Data([1]) && row.sha256 == RecordingBackupManifest.sha256Hex(Data([1])))
        #expect(try Data(contentsOf: other) == Data([7]))
        #expect(try context.fetch(FetchDescriptor<Recording>()).first { $0.fileName == "other.m4a" }?.id != row.id)
    }

    @Test func numberedNamesFitTheLimitAndABadUntrashTargetChangesNothing() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        store.library.context = context
        let longest = String(repeating: "x", count: 236) + ".m4a"
        let first = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: longest, origin: .recorded)
        let second = try store.library.publishFinished(try stage(Data([2])), projectId: "song", preferredName: longest, origin: .recorded)
        #expect(first.lastPathComponent == longest)
        #expect(second.lastPathComponent != longest && second.lastPathComponent.utf8.count <= 240 && second.lastPathComponent.hasSuffix(" 2.m4a"))

        try store.library.trashRecording(at: second, to: store.trash.appendingPathComponent("song/1000__\(second.lastPathComponent)"), trashedAt: Date(timeIntervalSince1970: 1))
        let trashed = try #require(RecordingFiles.trashedMemos(in: store.trash).first)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first { $0.trashedAt != nil })
        let tooLong = store.root.appendingPathComponent("song/" + String(repeating: "y", count: 300) + ".m4a")
        #expect(throws: (any Error).self) { try store.library.untrashRecording(trashed, to: tooLong) }
        #expect(row.trashedAt == Date(timeIntervalSince1970: 1) && row.fileName == second.lastPathComponent && row.pendingFrom == nil)
        #expect(FileManager.default.fileExists(atPath: trashed.url.path))
    }

    @Test func copiesOfOneOldRecordingAreOneRecordingAndTheExtraIsQuarantined() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try write(Data([1]), "song", "5000__take.m4a", root: store.trash)

        try await store.library.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.count == 1 && rows[0].trashedAt == nil && rows[0].fileName == "take.m4a")
        #expect(rows[0].id == RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "take.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([1]))))
        #expect(RecordingFiles.trashedMemos(in: store.trash).isEmpty)
        let quarantine = RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("song")
        let kept = try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
        #expect(kept.count == 1 && kept[0].lastPathComponent.hasSuffix("__5000__take.m4a"))
        #expect(try Data(contentsOf: kept[0]) == Data([1]))
    }

    @Test func theCanonicalCopyDoesNotDependOnArrivalOrder() async throws {
        func stamp(_ url: URL, _ seconds: TimeInterval) throws {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
        }
        // Both copies at once.
        let together = try await makeStore(onDisk: true)
        try write(Data([1]), "song", "take.m4a", root: together.root)
        try stamp(together.root.appendingPathComponent("song/take.m4a"), 1_000)
        try write(Data([1]), "song", "5000__take.m4a", root: together.trash)
        try stamp(together.trash.appendingPathComponent("song/5000__take.m4a"), 500)
        try await together.library.reconcile(context: together.container.mainContext)
        let a = try #require(together.container.mainContext.fetch(FetchDescriptor<Recording>()).first)

        // The Trash copy first, the live copy later.
        let apart = try await makeStore(onDisk: true)
        let context = apart.container.mainContext
        try write(Data([1]), "song", "5000__take.m4a", root: apart.trash)
        try stamp(apart.trash.appendingPathComponent("song/5000__take.m4a"), 500)
        try await apart.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).first?.trashedAt != nil)
        try write(Data([1]), "song", "take.m4a", root: apart.root)
        try stamp(apart.root.appendingPathComponent("song/take.m4a"), 1_000)
        try await apart.library.reconcile(context: context)
        let rows = try context.fetch(FetchDescriptor<Recording>())
        let b = try #require(rows.first)

        #expect(rows.count == 1)
        #expect(a.id == b.id && a.fileName == b.fileName && a.trashedAt == nil && b.trashedAt == nil)
        // Stamped once, as the earliest file time seen, and never moved after.
        #expect(a.precedenceTime == b.precedenceTime && b.precedenceTime == Date(timeIntervalSince1970: 500))
        #expect(RecordingFiles.trashedMemos(in: apart.trash).isEmpty && RecordingFiles.trashedMemos(in: together.trash).isEmpty)
        #expect(try Data(contentsOf: apart.root.appendingPathComponent("song/take.m4a")) == Data([1]))
    }

    @Test func anUnfinishedQuarantineMoveIsFinishedFirstUnlessARowStillNamesTheFile() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([1]), "song", "kept.m4a", root: store.root)
        try await store.library.reconcile(context: context)
        try write(Data([2]), "song", "deleted.m4a", root: store.root)
        let kept = store.root.appendingPathComponent("song/kept.m4a")
        let deleted = store.root.appendingPathComponent("song/deleted.m4a")
        // Recorded before a save that removed one row and never landed for the other.
        try RecordingFiles.setPendingQuarantine([RecordingFiles.canonicalPath(kept), RecordingFiles.canonicalPath(deleted)], for: store.root)
        #expect(RecordingFiles.trashedMemos(in: store.trash).isEmpty)

        try await store.library.reconcile(context: context)

        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.fileName) == ["kept.m4a"])
        #expect(FileManager.default.fileExists(atPath: kept.path) && !FileManager.default.fileExists(atPath: deleted.path))
        #expect(RecordingFiles.pendingQuarantine(for: store.root) == [])
        let quarantined = try FileManager.default.contentsOfDirectory(at: RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("song"), includingPropertiesForKeys: nil)
        #expect(quarantined.count == 1 && (try? Data(contentsOf: quarantined[0])) == Data([2]))
    }

    @Test func anUnreadableFileAbortsAdoptionAndEveryDeletionThatDependsOnIt() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        context.insert(SyncDeletionRecord(projectId: "song", deletedAt: 4_000_000_000_000))
        try context.save()
        try write(Data([1]), "song", "a.m4a", root: store.root)
        try write(Data([2]), "song", "b.m4a", root: store.root)
        let unreadable = store.root.appendingPathComponent("song/b.m4a")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        await #expect(throws: (any Error).self) { try await store.library.reconcile(context: context) }

        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).count == 1)
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/a.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: RecordingFiles.quarantineRoot(for: store.root).path))
    }

    @Test func otherBytesAtAPathVerifiedForARemovedRecordingAreARecordingOfTheirOwn() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        context.insert(Recording(id: "r", projectId: "song", fileName: "take.m4a", audio: Data([1, 1]), recordedAt: Date(timeIntervalSince1970: 10)))
        try context.save()
        try await store.library.reconcile(context: context)
        // R is removed on another device (and its deletion is known here) while
        // other bytes sit at its old path.
        for row in try context.fetch(FetchDescriptor<Recording>()) { context.delete(row) }
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: "r", fileName: "take.m4a", deletedAt: 4_000_000_000_000))
        try context.save()
        let path = store.root.appendingPathComponent("song/take.m4a")
        try Data([2, 2]).write(to: path)

        try await store.library.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.count == 1 && rows[0].id != "r" && rows[0].audio == Data([2, 2]))
        #expect(try Data(contentsOf: path) == Data([2, 2]))
        #expect(RecordingFiles.trashedMemos(in: store.trash).isEmpty)
    }

    @Test func aDeletedOldRecordingIsNotBroughtBackByALaterCopy() async throws {
        let digest = RecordingBackupManifest.sha256Hex(Data([3]))
        let id = RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "take.m4a", sha256: digest)
        // U is in the Trash, stamped at 10 s; a tombstone at 20 s; an identical live copy dated 30 s appears.
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        try write(Data([3]), "song", "10000__take.m4a", root: store.trash)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: store.trash.appendingPathComponent("song/10000__take.m4a").path)
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).first?.uploadedAt == Date(timeIntervalSince1970: 10))
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "take.m4a", deletedAt: 20_000))
        try context.save()
        try write(Data([3]), "song", "take.m4a", root: store.root)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 30)], ofItemAtPath: store.root.appendingPathComponent("song/take.m4a").path)
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/take.m4a").path))

        // No row yet: a live copy at 30 s and a Trash copy at 10 s; the earliest decides.
        let fresh = try await makeStore(onDisk: true)
        let freshContext = fresh.container.mainContext
        freshContext.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "take.m4a", deletedAt: 20_000))
        try freshContext.save()
        try write(Data([3]), "song", "take.m4a", root: fresh.root)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 30)], ofItemAtPath: fresh.root.appendingPathComponent("song/take.m4a").path)
        try write(Data([3]), "song", "10000__take.m4a", root: fresh.trash)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: fresh.trash.appendingPathComponent("song/10000__take.m4a").path)
        try await fresh.library.reconcile(context: freshContext)
        #expect(try freshContext.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(RecordingFiles.trashedMemos(in: fresh.trash).isEmpty)
    }

    @Test func changesWaitForASuccessfulCheckAndAVerifiedSource() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        store.library.context = context
        let live = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        // A move record that cannot be read: the next check fails, and changes wait.
        let record = RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("pending-moves.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: record)
        await #expect(throws: (any Error).self) { try await store.library.reconcile(context: context) }
        let renamed = store.root.appendingPathComponent("song/renamed.m4a")
        #expect(throws: RecordingLibraryError.notChecked) { try store.library.renameRecording(at: live, to: renamed) }
        #expect(throws: RecordingLibraryError.notChecked) { _ = try store.library.publishFinished(try stage(Data([2])), projectId: "song", preferredName: "new.m4a", origin: .recorded) }
        #expect(FileManager.default.fileExists(atPath: live.path) && !FileManager.default.fileExists(atPath: renamed.path))
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.fileName) == ["take.m4a"])

        // Checked again; a file whose bytes are not its row's is not renamed as that row.
        try FileManager.default.removeItem(at: record)
        try await store.library.reconcile(context: context)
        try Data([9]).write(to: live)
        #expect(throws: RecordingLibraryError.notVerified) { try store.library.renameRecording(at: live, to: renamed) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.fileName) == ["take.m4a"])
    }

    @Test func aDetachedMoveInterruptedByACrashFinishesWithoutAdoption() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        context.insert(Recording(id: "gone", projectId: "song", fileName: "take.m4a", audio: Data([5]), recordedAt: Date(timeIntervalSince1970: 10)))
        try context.save()
        try await store.library.reconcile(context: context)
        // The run that detached it recorded the move and its row's removal, then stopped.
        for row in try context.fetch(FetchDescriptor<Recording>()) { context.delete(row) }
        try context.save()
        let source = store.root.appendingPathComponent("song/take.m4a")
        let destination = store.trash.appendingPathComponent("song/50000__take.m4a")
        var moves = RecordingFiles.PendingMoves()
        moves.detach = [.init(recordingId: "gone", source: RecordingFiles.canonicalPath(source), destination: RecordingFiles.canonicalPath(destination))]
        try RecordingFiles.writePendingMoves(moves, for: store.root)

        try await store.library.reconcile(context: context)
        try await store.library.reconcile(context: context)

        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: destination) == Data([5]))
        #expect(try RecordingFiles.readPendingMoves(for: store.root).detach.map(\.source) == [""])
        #expect(RecordingFiles.trashedMemos(in: store.trash).map(\.originalName) == ["take.m4a"])
    }

    @Test func threeClaimsOfOneNameConvergeInEveryArrivalOrder() async throws {
        let made: [String: (time: TimeInterval, byte: UInt8)] = ["a": (10, 1), "b": (20, 2), "c": (30, 3)]
        let orders = [["a", "b", "c"], ["a", "c", "b"], ["b", "a", "c"], ["b", "c", "a"], ["c", "a", "b"], ["c", "b", "a"]]
        for order in orders {
            let store = try await makeStore(onDisk: true)
            let context = store.container.mainContext
            for id in order {
                let spec = try #require(made[id])
                context.insert(Recording(id: id, projectId: "song", fileName: "take.m4a", audio: Data([spec.byte]), recordedAt: Date(timeIntervalSince1970: spec.time)))
                try context.save()
                try await store.library.reconcile(context: context)
            }
            let names = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0.fileName) })
            #expect(names == ["a": "take.m4a", "b": "take 2.m4a", "c": "take 3.m4a"], "\(order)")
            #expect(try Data(contentsOf: store.root.appendingPathComponent("song/take 3.m4a")) == Data([3]))
        }
    }

    @Test func aSongDeletionWritesRecordingTombstonesOnlyAsTheirOwnType() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        context.insert(SyncDeletionRecord(projectId: "song", deletedAt: 4_000_000_000_000))
        try context.save()
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try await store.library.reconcile(context: context)
        // Builds from before ids read a deletion record with a file name as "delete that file".
        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).allSatisfy { $0.fileName == nil })
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).count == 1)
    }

    @Test func restoredAudioMustMatchItsDeclaredLength() async throws {
        let store = try await makeStore(onDisk: true)
        let context = store.container.mainContext
        let audio = Data([1, 2, 3])
        let entry = SyncRecording(id: "r", projectId: "song", fileName: "take.m4a", bytes: 4, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 5))
        #expect(throws: SyncValidationError.invalidRecording) { try store.library.commitRestored(audio, entry: entry, origin: .imported, context: context) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
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

    @Test func aFileAlreadyAtTheDestinationIsKept() async throws {
        let (snapshot, root) = try makeSnapshot()
        let destination = root.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data([9]).write(to: destination.appendingPathComponent("a.m4a"))

        try snapshot.copy(to: "copy")

        #expect(try Data(contentsOf: destination.appendingPathComponent("a.m4a")) == Data([9]))
        #expect(try Data(contentsOf: destination.appendingPathComponent("a 2.m4a")) == Data([1]))
        #expect(try Data(contentsOf: destination.appendingPathComponent("b.m4a")) == Data([2]))
    }

    @Test func rollbackRemovesOnlyItsOwnUnchangedFiles() async throws {
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
