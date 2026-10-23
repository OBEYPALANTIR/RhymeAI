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

    @Test func aRepairedTimeIsMarkedOnlyWhenItIsOne() async throws {
        let sha = String(repeating: "a", count: 64)
        var repaired = SyncRecording(id: "r", projectId: "song", fileName: "take.m4a", bytes: 1, sha256: sha, uploadedAt: Date(timeIntervalSince1970: 20))
        repaired.precedenceRepaired = true
        let plain = SyncRecording(id: "p", projectId: "song", fileName: "take.m4a", bytes: 1, sha256: sha, uploadedAt: Date(timeIntervalSince1970: 10))
        let song = SyncSongProject(id: "song", title: "", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 5), precedenceRepaired: true)
        let blob = SyncBlob(projects: [song], recordings: [plain, repaired], savedAt: Date(timeIntervalSince1970: 30))
        let text = try #require(String(data: try blob.encodedManifest(), encoding: .utf8))
        #expect(text.components(separatedBy: "\"precedenceRepaired\":true").count == 3)
        let decoded = try SyncBlob.decodeManifest(try blob.encodedManifest())
        #expect(decoded == blob)
        // Two repairs: the smaller stands; a recorded time beats a repair (A37).
        var later = repaired
        later.uploadedAt = Date(timeIntervalSince1970: 40)
        #expect(try SyncMerger.gather([SyncBlob(recordings: [repaired]), SyncBlob(recordings: [later])]).recordings.first?.uploadedAt == Date(timeIntervalSince1970: 20))
        var recorded = later
        recorded.precedenceRepaired = false
        #expect(try SyncMerger.gather([SyncBlob(recordings: [recorded]), SyncBlob(recordings: [repaired])]).recordings.first?.uploadedAt == Date(timeIntervalSince1970: 40))
    }

    @Test func aSongAndItsTrashEntryWithRepairedTimesKeepTheSmallerInBothOrders() async throws {
        func song(_ seconds: TimeInterval, repaired: Bool) -> SyncSongProject {
            SyncSongProject(id: "s", title: "S", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: seconds), precedenceRepaired: repaired)
        }
        func trash(_ seconds: TimeInterval, repaired: Bool) -> SyncTrashedSongProject {
            let at = Date(timeIntervalSince1970: seconds)
            return SyncTrashedSongProject(id: "s", title: "S", lyrics: "", theme: "", updatedAt: at, deletedAt: at,
                                          deleteAfter: at.addingTimeInterval(trashRetentionInterval), trashedAtRepaired: repaired)
        }
        func activeWins(_ project: SyncSongProject, _ trashed: SyncTrashedSongProject) throws -> Bool {
            let one = try SyncMerger.merge(local: SyncBlob(projects: [project]), remote: SyncBlob(trashed: [trashed]))
            let two = try SyncMerger.merge(local: SyncBlob(trashed: [trashed]), remote: SyncBlob(projects: [project]))
            #expect(one.projects == two.projects && one.trashed == two.trashed, "both orders agree")
            #expect(one.projects.count + one.trashed.count == 1)
            return !one.projects.isEmpty
        }
        // Both repaired: the smaller time wins.
        #expect(try activeWins(song(100, repaired: true), trash(200, repaired: true)))
        #expect(try !activeWins(song(200, repaired: true), trash(100, repaired: true)))
        // A recorded time beats a repaired one, whatever the times.
        #expect(try !activeWins(song(900, repaired: true), trash(100, repaired: false)))
        #expect(try activeWins(song(100, repaired: false), trash(900, repaired: true)))
        // Neither repaired: the later wins.
        #expect(try activeWins(song(200, repaired: false), trash(100, repaired: false)))
        // A38: each time with its own flag. A Trash entry whose edit time was repaired
        // but whose deletion time (100) is real beats a song edited at 50.
        let zeroEdit = SyncTrashedSongProject(id: "s", title: "S", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 0),
                                              deletedAt: Date(timeIntervalSince1970: 100), deleteAfter: Date(timeIntervalSince1970: 100).addingTimeInterval(trashRetentionInterval),
                                              precedenceRepaired: true)
        #expect(try !activeWins(song(50, repaired: false), zeroEdit))
    }

    @Test func aTrashEntryCarriesItsTwoRepairFlagsUnderTheirOwnKeys() async throws {
        let at = Date(timeIntervalSince1970: 100)
        let trash = SyncTrashedSongProject(id: "t", title: "T", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 50), deletedAt: at,
                                           deleteAfter: at.addingTimeInterval(trashRetentionInterval), trashedAtRepaired: true)
        let blob = SyncBlob(trashed: [trash])
        let text = try #require(String(data: try blob.encodedManifest(), encoding: .utf8))
        #expect(text.contains("\"trashedAtRepaired\":true") && !text.contains("\"precedenceRepaired\""))
        let decoded = try #require(SyncBlob.decodeManifest(try blob.encodedManifest()).trashed.first)
        #expect(decoded.trashedAtRepaired && !decoded.precedenceRepaired)
        // Two repaired deletion times: the smaller stands, whichever comes first.
        var later = trash
        later.deletedAt = Date(timeIntervalSince1970: 300)
        for (first, second) in [(trash, later), (later, trash)] {
            let merged = try SyncMerger.merge(local: SyncBlob(trashed: [first]), remote: SyncBlob(trashed: [second]))
            #expect(merged.trashed.map(\.deletedAt) == [at])
        }
    }

    @Test func aCorrectlyHashedManifestWithoutATimeIsReadAsUnknown() async throws {
        let audio = Data([1])
        let blob = SyncBlob(
            projects: [SyncSongProject(id: "p", title: "P", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 5))],
            recordings: [SyncRecording(id: "r", projectId: "p", fileName: "take.m4a", bytes: 1, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 5))]
        )
        func rehashed(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var fields = try #require(try JSONSerialization.jsonObject(with: try blob.encodedManifest()) as? [String: Any])
            fields.removeValue(forKey: "manifestSha256")
            change(&fields)
            fields["manifestSha256"] = CanonicalJSON.sha256Hex(try JSONValue(any: fields))
            return try JSONSerialization.data(withJSONObject: fields)
        }
        let absent = try rehashed { fields in
            var recordings = fields["recordings"] as! [[String: Any]]
            recordings[0].removeValue(forKey: "uploadedAt")
            fields["recordings"] = recordings
            var projects = fields["projects"] as! [[String: Any]]
            projects[0].removeValue(forKey: "updatedAt")
            fields["projects"] = projects
        }
        let decoded = try SyncBlob.decodeManifest(absent)
        #expect(decoded.recordings.first?.uploadedAt.epochMilliseconds == 0 && decoded.projects.first?.updatedAt.epochMilliseconds == 0)
        // A value of the wrong type is still refused.
        let wrong = try rehashed { fields in
            var recordings = fields["recordings"] as! [[String: Any]]
            recordings[0]["uploadedAt"] = "yesterday"
            fields["recordings"] = recordings
        }
        #expect(throws: SyncManifestError.damaged) { _ = try SyncBlob.decodeManifest(wrong) }
    }

    static let sharedArchiveNames = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("shared/fixtures/archive-names-v1.json")

    @Test func archiveNamesMatchTheSharedFixture() async throws {
        let url = try #require(Bundle(for: FixtureToken.self).url(forResource: "archive-names-v1", withExtension: "json"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        let recordings = try cases.map { item in
            SyncRecording(id: try #require(item["id"] as? String), projectId: try #require(item["projectId"] as? String),
                          fileName: try #require(item["displayName"] as? String), bytes: 1, sha256: String(repeating: "a", count: 64),
                          uploadedAt: Date(millisecondsSince1970: try #require((item["precedenceTime"] as? NSNumber)?.int64Value)))
        }
        let names = RecordingBackupManifest.exportNames(recordings)
        for (item, entry) in zip(cases, recordings) {
            #expect("recordings/\(entry.projectId)/\(names[entry.id] ?? "")" == item["archivePath"] as? String)
        }
    }

    /// The copy here is the shared fixture byte for byte, once the shared one is in this checkout.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: SyncManifestV4Tests.sharedArchiveNames.path)))
    func archiveNamesFixtureCopyMatchesTheSharedOne() async throws {
        let copy = try #require(Bundle(for: FixtureToken.self).url(forResource: "archive-names-v1", withExtension: "json"))
        #expect(try Data(contentsOf: copy) == Data(contentsOf: Self.sharedArchiveNames))
    }

    @Test func archiveNamesFollowTheSharedRule() async throws {
        func names(_ entries: [(String, TimeInterval, String)]) -> [String] {
            let recordings = entries.map { SyncRecording(id: $0.0, projectId: "p", fileName: $0.2, bytes: 1, sha256: String(repeating: "a", count: 64),
                                                         uploadedAt: Date(timeIntervalSince1970: $0.1)) }
            let allocated = RecordingBackupManifest.exportNames(recordings)
            return entries.map { allocated[$0.0]! }
        }
        // Nothing is reserved ahead of its turn.
        #expect(names([("a", 1, "take.m4a"), ("b", 2, "take.m4a"), ("c", 3, "take 2.m4a")]) == ["take.m4a", "take 2.m4a", "take 2 2.m4a"])
        // Visited by time, then id byte-wise.
        #expect(names([("b", 1, "take.m4a"), ("a", 1, "take.m4a")]) == ["take 2.m4a", "take.m4a"])
        // A case-only or normalization-only difference is the same name.
        #expect(names([("a", 1, "Take.m4a"), ("b", 2, "take.m4a")]) == ["Take.m4a", "take 2.m4a"])
        #expect(names([("a", 1, "Caf\u{E9}.m4a"), ("b", 2, "Cafe\u{301}.m4a")]) == ["Caf\u{E9}.m4a", "Cafe\u{301} 2.m4a"])
        // Separators and leading dots become "_".
        #expect(names([("a", 1, "a/b\\c.m4a"), ("b", 2, "..hidden.m4a")]) == ["a_b_c.m4a", "__hidden.m4a"])
        // Truncated to 240 bytes of UTF-8 without splitting a code point, suffix included.
        let long = String(repeating: "\u{E9}", count: 200) + ".m4a"
        let cut = names([("a", 1, long), ("b", 2, long)])
        #expect(cut.allSatisfy { $0.utf8.count <= 240 && $0.hasSuffix(".m4a") })
        #expect(cut[0].utf8.count == 240 && cut[1].hasSuffix(" 2.m4a") && cut[1].utf8.count == 240)
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
    /// Tests: "projectId/displayName".
    var key: String { "\(projectId)/\(displayName)" }
}

extension SyncRecording {
    /// Test entries: id derived from project and name, uploaded 2023-11-14 unless a test says otherwise.
    init(projectId: String, fileName: String, bytes: Int64, sha256: String, uploadedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.init(id: "\(projectId)~\(fileName)", projectId: projectId, fileName: fileName, bytes: bytes, sha256: sha256, uploadedAt: uploadedAt)
    }
}

/// Recording files are `<id>.<ext>` (A36) and rows hold everything else.
@MainActor
struct RecordingLibraryTests {
    typealias Store = (container: ModelContainer, root: URL, trash: URL, library: RecordingLibrary)

    /// A library over a fresh store, checked once (changes need a successful check, A33).
    private func makeStore(onDisk: Bool = true) async throws -> Store {
        let store = try makeUncheckedStore(onDisk: onDisk)
        try await store.library.reconcile(context: store.container.mainContext)
        store.library.context = store.container.mainContext
        return store
    }

    private func makeUncheckedStore(onDisk: Bool) throws -> Store {
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

    @discardableResult
    private func write(_ data: Data, _ projectId: String, _ fileName: String, root: URL, modified: TimeInterval? = nil) throws -> URL {
        let folder = root.appendingPathComponent(projectId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try data.write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path) }
        return url
    }

    private func stage(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)/take.m4a")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func names(_ folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    private func derivedId(_ projectId: String, _ name: String, _ data: Data) -> String {
        RecordingBackupManifest.legacyRecordingId(projectId: projectId, fileName: name, sha256: RecordingBackupManifest.sha256Hex(data))
    }

    private func uuid() -> String { UUID().uuidString.lowercased() }

    @Test func filesFromBeforeA36MoveToTheirIdsAndKeepTheirNamesAsMetadata() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root, modified: 1_000)
        try write(Data([2]), "song", "5000__old.m4a", root: store.trash, modified: 900)

        try await store.library.reconcile(context: context)
        try await store.library.reconcile(context: context)

        let rows = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Recording>()).map { ($0.displayName, $0) })
        let take = try #require(rows["take.m4a"])
        let old = try #require(rows["old.m4a"])
        #expect(take.id == derivedId("song", "take.m4a", Data([1])) && take.trashedAt == nil && take.uploadedAt == Date(timeIntervalSince1970: 1_000))
        #expect(old.id == derivedId("song", "old.m4a", Data([2])) && old.trashedAt == Date(timeIntervalSince1970: 5))
        #expect(names(store.root.appendingPathComponent("song")) == ["\(take.id).m4a"])
        #expect(names(store.trash.appendingPathComponent("song")) == ["\(old.id).m4a"])
        #expect(try store.library.trashedRecordings(in: context).map(\.originalName) == ["old.m4a"])
        #expect(try store.library.liveRecordings(in: context).map(\.displayName) == ["take.m4a"])
    }

    @Test func aMigrationTargetHoldingOtherBytesIsLeftAloneAndReported() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = derivedId("song", "take.m4a", Data([1]))
        let legacy = try write(Data([1]), "song", "take.m4a", root: store.root)
        let target = try write(Data([9]), "song", "\(id).m4a", root: store.root)

        // The same on every run: nothing moves, nothing takes the id, both are reported.
        for _ in 0..<2 {
            let result = try await store.library.reconcile(context: context)
            #expect(Set(result.needsAttention.map(\.lastPathComponent)) == ["take.m4a", "\(id).m4a"])
            #expect(try Data(contentsOf: legacy) == Data([1]) && Data(contentsOf: target) == Data([9]))
            #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        }
    }

    @Test func aRecordingWhoseIdPlaceHoldsOtherBytesKeepsItsRecord() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = derivedId("song", "take.m4a", Data([1]))
        // Its row (from iCloud) and its file under the old name; other bytes at its id's place.
        context.insert(Recording(id: id, projectId: "song", displayName: "take.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10),
                                 uploadedAt: Date(timeIntervalSince1970: 10), origin: .migrated))
        // An older tombstone: the recording's own time keeps protecting it.
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "take.m4a", deletedAt: 5_000))
        try context.save()
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try write(Data([9]), "song", "\(id).m4a", root: store.root)

        for _ in 0..<3 { try await store.library.reconcile(context: context) }

        let rows = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0) })
        let row = try #require(rows[id])
        #expect(row.displayName == "take.m4a" && row.uploadedAt == Date(timeIntervalSince1970: 10) && row.audio == Data([1]) && row.trashedAt == nil)
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/\(id).m4a")) == Data([1]))
        // The other bytes are a recording of their own; nothing was deleted.
        #expect(rows.values.contains { $0.id != id && $0.audio == Data([9]) })
        let folder = store.root.appendingPathComponent("song")
        #expect(Set(try names(folder).map { try Data(contentsOf: folder.appendingPathComponent($0)) }) == [Data([1]), Data([9])])
    }

    @Test func aRowFromAnotherDeviceIsWrittenToItsId() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = uuid()
        context.insert(Recording(id: id, projectId: "song", displayName: "remote.m4a", audio: Data([7, 7]), recordedAt: Date()))
        try context.save()
        try await store.library.reconcile(context: context)
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/\(id).m4a")) == Data([7, 7]))
    }

    @Test func renamingChangesOnlyTheNameAndNamesMayRepeat() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let first = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let second = try store.library.publishFinished(try stage(Data([2])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        #expect(first != second && RecordingFiles.storedId(of: first) != nil && RecordingFiles.storedId(of: second) != nil)

        try store.library.renameRecording(at: first, to: "Verse.m4a")
        try await store.library.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(Set(rows.map(\.displayName)) == ["Verse.m4a", "take.m4a"])
        #expect(rows.first { $0.displayName == "Verse.m4a" }?.displayNameChanged == true)
        #expect(names(store.root.appendingPathComponent("song")) == [first.lastPathComponent, second.lastPathComponent])
    }

    @Test func trashAndRestoreMoveOnlyBetweenFoldersUnderTheId() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let live = try store.library.publishFinished(try stage(Data([3])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let trashed = try store.library.trashRecording(at: live, trashedAt: Date(timeIntervalSince1970: 50))
        #expect(trashed.url == store.trash.appendingPathComponent("song/\(live.lastPathComponent)") && trashed.originalName == "take.m4a")
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(try store.library.trashedRecordings(in: context).map(\.url) == [trashed.url])

        let restored = try store.library.untrashRecording(trashed)
        #expect(restored == live && FileManager.default.fileExists(atPath: live.path))
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).first?.trashedAt == nil)
    }

    /// A recording whose row was removed on another device, detached here to the Trash.
    private func detached() async throws -> (store: Store, id: String, destination: URL) {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = uuid()
        context.insert(Recording(id: id, projectId: "song", displayName: "kept.m4a", audio: Data([5]), recordedAt: Date(timeIntervalSince1970: 10)))
        try context.save()
        try await store.library.reconcile(context: context)
        for row in try context.fetch(FetchDescriptor<Recording>()) { context.delete(row) }
        try context.save()
        try await store.library.reconcile(context: context)
        return (store, id, store.trash.appendingPathComponent("song/\(id).m4a"))
    }

    @Test func aRecordingRemovedElsewhereIsDetachedAndRestoredUnderItsId() async throws {
        let (store, id, destination) = try await detached()
        let context = store.container.mainContext
        #expect(try Data(contentsOf: destination) == Data([5]))
        let trashed = try #require(store.library.trashedRecordings(in: context).first)
        #expect(trashed.recordingId == id && trashed.originalName == "kept.m4a")
        #expect(try store.library.identityForDeletion(of: trashed, in: context).id == id)

        _ = try store.library.untrashRecording(trashed)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.id == id && row.displayName == "kept.m4a" && row.uploadedAt == Date(timeIntervalSince1970: 10))
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/\(id).m4a").path))
    }

    @Test func aLaterTombstoneStillReachesADetachedRecording() async throws {
        let (store, id, destination) = try await detached()
        let context = store.container.mainContext
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "kept.m4a", deletedAt: 4_000_000_000_000))
        try context.save()
        try await store.library.reconcile(context: context)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try store.library.trashedRecordings(in: context).isEmpty)
        #expect(names(RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("song")).contains("\(id).m4a"))
    }

    @Test func changedDetachedBytesAreTakenInUnderTheirOwnIdentity() async throws {
        let (store, id, destination) = try await detached()
        let context = store.container.mainContext
        try Data([6]).write(to: destination)
        try await store.library.reconcile(context: context)

        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.id != id && row.audio == Data([6]) && row.trashedAt != nil)
        #expect(try RecordingFiles.readPendingMoves(for: store.root).detach.isEmpty)
        let trashed = try #require(store.library.trashedRecordings(in: context).first)
        #expect(try store.library.identityForDeletion(of: trashed, in: context).id == row.id)
    }

    @Test func otherBytesAtARemovedRecordingsPlaceAreARecordingOfTheirOwn() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = uuid()
        context.insert(Recording(id: id, projectId: "song", displayName: "take.m4a", audio: Data([1, 1]), recordedAt: Date(timeIntervalSince1970: 10)))
        try context.save()
        try await store.library.reconcile(context: context)
        for row in try context.fetch(FetchDescriptor<Recording>()) { context.delete(row) }
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "take.m4a", deletedAt: 4_000_000_000_000))
        try context.save()
        // Same length, same inode, date put back: only a fresh hash tells them apart.
        let place = store.root.appendingPathComponent("song/\(id).m4a")
        let before = try RecordingFiles.facts(place)
        let handle = try FileHandle(forWritingTo: place)
        try handle.write(contentsOf: Data([2, 2]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: before.modified], ofItemAtPath: place.path)

        try await store.library.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.count == 1 && rows[0].id != id && rows[0].audio == Data([2, 2]))
        #expect(try store.library.trashedRecordings(in: context).isEmpty)
    }

    @Test func copiesOfOneIdentityAreOneRecordingWhateverTheOrder() async throws {
        func device(trashFirst: Bool) async throws -> (id: String, trashed: Bool, time: Date, live: Set<String>, quarantined: Set<String>) {
            let store = try await makeStore()
            let context = store.container.mainContext
            if trashFirst {
                try write(Data([1]), "song", "5000__take.m4a", root: store.trash, modified: 500)
                try await store.library.reconcile(context: context)
                try write(Data([1]), "song", "take.m4a", root: store.root, modified: 1_000)
            } else {
                try write(Data([1]), "song", "take.m4a", root: store.root, modified: 1_000)
                try write(Data([1]), "song", "5000__take.m4a", root: store.trash, modified: 500)
            }
            try await store.library.reconcile(context: context)
            let rows = try context.fetch(FetchDescriptor<Recording>())
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            return (row.id, row.trashedAt != nil, row.precedenceTime, names(store.root.appendingPathComponent("song")),
                    names(RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("song")))
        }
        let together = try await device(trashFirst: false)
        let apart = try await device(trashFirst: true)
        #expect(together.id == apart.id && !together.trashed && !apart.trashed)
        // Its time is the earliest file time among the copies (A26).
        #expect(together.time == Date(timeIntervalSince1970: 500) && apart.time == Date(timeIntervalSince1970: 500))
        #expect(together.live == ["\(together.id).m4a"] && together.quarantined == ["\(together.id).m4a"])
    }

    @Test func aDeletedOldRecordingIsNotBroughtBackByALaterCopy() async throws {
        let id = derivedId("song", "take.m4a", Data([3]))
        // In the Trash, stamped at 10 s; a tombstone at 20 s; then a live copy dated 30 s.
        let store = try await makeStore()
        let context = store.container.mainContext
        try write(Data([3]), "song", "10000__take.m4a", root: store.trash, modified: 10)
        try await store.library.reconcile(context: context)
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "take.m4a", deletedAt: 20_000))
        try context.save()
        try write(Data([3]), "song", "take.m4a", root: store.root, modified: 30)
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(names(store.root.appendingPathComponent("song")).isEmpty)

        // The same with the bytes of the earlier copy past one pass's budget (finding 4).
        let fresh = try await makeStore()
        fresh.library.adoptionBudget = 1
        let freshContext = fresh.container.mainContext
        freshContext.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "take.m4a", deletedAt: 20_000))
        try freshContext.save()
        try write(Data([3]), "song", "take.m4a", root: fresh.root, modified: 30)
        try write(Data([3]), "song", "10000__take.m4a", root: fresh.trash, modified: 10)
        try await fresh.library.reconcile(context: freshContext)
        #expect(try freshContext.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(names(fresh.root.appendingPathComponent("song")).isEmpty && names(fresh.trash.appendingPathComponent("song")).isEmpty)
    }

    @Test func adoptionGoesThroughABoundedBudgetAndReportsWhatIsLeft() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        store.library.adoptionBudget = 1
        for index in 0..<4 { try write(Data([UInt8(index), 9]), "song", "take \(index).m4a", root: store.root) }
        let result = try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 4 && result.pendingAdoption == 0)

        // More than one run's passes can take: what is left is reported and taken next time.
        for index in 0..<70 { try write(Data([UInt8(index), 7]), "many", "take \(index).m4a", root: store.root) }
        let partial = try await store.library.reconcile(context: context)
        #expect(partial.pendingAdoption > 0 && store.library.pendingAdoption > 0)
        let rest = try await store.library.reconcile(context: context)
        #expect(rest.pendingAdoption == 0)
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 74)
    }

    @Test func changesWaitForASuccessfulCheckAndAVerifiedSource() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let live = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let record = RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("pending-moves.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: record)
        await #expect(throws: (any Error).self) { try await store.library.reconcile(context: context) }
        #expect(throws: RecordingLibraryError.notChecked) { try store.library.renameRecording(at: live, to: "renamed.m4a") }
        #expect(throws: RecordingLibraryError.notChecked) { _ = try store.library.publishFinished(try stage(Data([2])), projectId: "song", preferredName: "new.m4a", origin: .recorded) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.displayName) == ["take.m4a"])

        try FileManager.default.removeItem(at: record)
        try await store.library.reconcile(context: context)
        try Data([9]).write(to: live)
        #expect(throws: RecordingLibraryError.notVerified) { try store.library.renameRecording(at: live, to: "renamed.m4a") }
        #expect(throws: RecordingLibraryError.notVerified) { _ = try store.library.trashRecording(at: live, trashedAt: Date()) }
    }

    @Test func anUnreadableQuarantineRecordSuspendsAdoptionAndTheLists() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        let record = RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("pending-moves.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: record)

        await #expect(throws: (any Error).self) { try await store.library.reconcile(context: context) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(RecordingFiles.pendingQuarantine(for: store.root) == nil)
        #expect(throws: (any Error).self) { _ = try store.library.liveRecordings(in: context) }

        try FileManager.default.removeItem(at: record)
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
    }

    @Test func anUnreadableFolderOrFileChangesNothing() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        context.insert(SyncDeletionRecord(projectId: "song", deletedAt: 4_000_000_000_000))
        try context.save()
        try write(Data([1]), "song", "a.m4a", root: store.root)
        let unreadable = try write(Data([2]), "song", "b.m4a", root: store.root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        await #expect(throws: (any Error).self) { try await store.library.reconcile(context: context) }

        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/a.m4a").path))
        #expect(!store.library.lastRunSucceeded)
    }

    @Test func aMissingMemoRootWithKnownRecordingsAborts() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try await store.library.reconcile(context: context)
        try FileManager.default.moveItem(at: store.root, to: store.root.deletingLastPathComponent().appendingPathComponent("moved-aside"))
        await #expect(throws: RecordingLibraryError.scanFailed) { try await store.library.reconcile(context: context) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
    }

    @Test func aFailedSaveLeavesFilesAndRowsAsTheyWere() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let live = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        store.library.save = { _ in throw CocoaError(.fileWriteUnknown) }
        #expect(throws: CocoaError.self) { _ = try store.library.trashRecording(at: live, trashedAt: Date()) }
        #expect(FileManager.default.fileExists(atPath: live.path))
        let staged = try stage(Data([2]))
        #expect(throws: CocoaError.self) { _ = try store.library.publishFinished(staged, projectId: "song", preferredName: "new.m4a", origin: .recorded) }
        #expect(FileManager.default.fileExists(atPath: staged.path))
        store.library.save = { try $0.save() }
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.displayName) == ["take.m4a"])
    }

    @Test func anInterruptedMoveIsFinishedOnTheNextRun() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let live = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        // Trashed elsewhere (the row says Trash), the file still here.
        row.trashedAt = Date(timeIntervalSince1970: 60)
        try context.save()
        try await store.library.reconcile(context: context)
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(try Data(contentsOf: store.trash.appendingPathComponent("song/\(live.lastPathComponent)")) == Data([1]))
        #expect(row.pendingFrom == nil)
    }

    @Test func aMoveNeverReliesOnACachedDigest() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = uuid()
        context.insert(Recording(id: id, projectId: "song", displayName: "take.m4a", audio: Data([1, 1]), recordedAt: Date(timeIntervalSince1970: 10)))
        try context.save()
        try await store.library.reconcile(context: context)
        try await store.library.reconcile(context: context)
        let place = store.root.appendingPathComponent("song/\(id).m4a")
        let before = try RecordingFiles.facts(place)
        let handle = try FileHandle(forWritingTo: place)
        try handle.write(contentsOf: Data([2, 2]))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: before.modified], ofItemAtPath: place.path)
        // Trashed on another device while the row remains.
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        row.trashedAt = Date(timeIntervalSince1970: 70)
        try context.save()

        try await store.library.reconcile(context: context)

        // The row's audio is written to its Trash place from the row; the other bytes stay theirs.
        #expect(try Data(contentsOf: store.trash.appendingPathComponent("song/\(id).m4a")) == Data([1, 1]))
        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.count == 2 && rows.first { $0.id != id }?.audio == Data([2, 2]))
    }

    @Test func aRecordedMoveNeverTakesBytesItWasNotDecidedOn() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let path = try write(Data([1]), "song", "take.m4a", root: store.root)
        try RecordingFiles.setPendingQuarantine([RecordingFiles.canonicalPath(path)], for: store.root)
        try Data([7, 7]).write(to: path)
        try await store.library.reconcile(context: context)
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.audio) == [Data([7, 7])])
        #expect(try RecordingFiles.readPendingMoves(for: store.root).quarantine.isEmpty)
    }

    @Test func aFileWithoutATimeIsStampedFirstSeenAndNotDecidedByAnOlderTombstone() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        try write(Data([4]), "song", "old.m4a", root: store.root, modified: 0)
        let id = derivedId("song", "old.m4a", Data([4]))
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "old.m4a", deletedAt: 1_000))
        try context.save()
        try await store.library.reconcile(context: context)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.id == id && row.precedenceTime.epochMilliseconds > 1_000 && row.precedenceRepaired)
    }

    @Test func aSongDeletionWritesRecordingTombstonesOnlyAsTheirOwnType() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        context.insert(SyncDeletionRecord(projectId: "song", deletedAt: 4_000_000_000_000))
        try context.save()
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try write(Data([2]), "song", "1000__trashed.m4a", root: store.trash)
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<SyncDeletionRecord>()).allSatisfy { $0.fileName == nil })
        #expect(Set(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).map(\.recordingId))
                == [derivedId("song", "take.m4a", Data([1])), derivedId("song", "trashed.m4a", Data([2]))])
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
    }

    @Test func anInvalidTombstoneStopsTheCheckBeforeAnyBytesAreTouched() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        try write(Data([1]), "song", "take.m4a", root: store.root)
        try await store.library.reconcile(context: context)
        context.insert(SyncRecordingDeletion(projectId: "../song", recordingId: "", fileName: "take.m4a", deletedAt: 4_000_000_000_000))
        try context.save()
        #expect(throws: (any Error).self) { _ = try DeletionStore.all(in: context) }
        await #expect(throws: (any Error).self) { try await store.library.reconcile(context: context) }
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
        #expect(!store.library.lastRunSucceeded)
    }

    @Test func aDraftsCopiesAreTakenInUnderTheirIdsAndNames() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = uuid()
        let copy = try write(Data([8]), "draft", "\(id).m4a", root: store.root)
        try store.library.expectCopies([(copy, id, "Chorus idea.m4a", RecordingBackupManifest.sha256Hex(Data([8])))])
        try await store.library.reconcile(context: context)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.id == id && row.displayName == "Chorus idea.m4a" && row.projectId == "draft")
        #expect(try RecordingFiles.readPendingMoves(for: store.root).adopt.isEmpty)
    }

    @Test func aManifestEntryLandsOnDiskUnderItsIdWithItsNameAsMetadata() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let audio = Data([4, 2])
        let entry = SyncRecording(id: "0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b", projectId: "song", fileName: "take.m4a", bytes: 2,
                                  sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 5))
        var staged: [URL] = []
        store.library.save = { context in
            staged += try context.fetch(FetchDescriptor<Recording>()).compactMap(\.pendingFrom).map { URL(fileURLWithPath: $0) }
            try context.save()
        }
        #expect(try store.library.commitRestored(audio, entry: entry, origin: .restored, context: context))
        // Staged under its id too.
        #expect(staged.map(\.lastPathComponent) == ["0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b.m4a"])
        #expect(staged.first?.deletingLastPathComponent().lastPathComponent == "recording-staging")
        #expect(names(store.root.appendingPathComponent("song")) == ["0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b.m4a"])
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.id == entry.id && row.displayName == "take.m4a" && !row.displayNameChanged)
        try await store.library.reconcile(context: context)
        #expect(names(store.root.appendingPathComponent("song")) == ["0f8e2d4c-6b1a-4e9d-8c7b-5a3f2e1d0c9b.m4a"])
    }

    @Test func duplicateRowsOfOneIdSettleTheirTimeBeforeOneIsKept() async throws {
        // tA < tombstone < tB, in both arrangements of names (the kept copy is "a").
        for (aTime, bTime) in [(10.0, 30.0), (30.0, 10.0)] {
            let store = try await makeStore()
            let context = store.container.mainContext
            let id = uuid()
            for (name, seconds) in [("a.m4a", aTime), ("b.m4a", bTime)] {
                let row = Recording(id: id, projectId: "song", displayName: name, audio: Data([1]), recordedAt: Date(timeIntervalSince1970: seconds),
                                    uploadedAt: Date(timeIntervalSince1970: seconds))
                row.precedenceRepaired = true
                context.insert(row)
            }
            context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "a.m4a", deletedAt: 20_000))
            try context.save()
            try await store.library.reconcile(context: context)
            #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty, "the smaller repair (10 s) loses to the deletion at 20 s")
        }
        // A recorded time beats a repair, whichever copy is kept.
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = uuid()
        let repaired = Recording(id: id, projectId: "song", displayName: "a.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10),
                                 uploadedAt: Date(timeIntervalSince1970: 10))
        repaired.precedenceRepaired = true
        context.insert(repaired)
        context.insert(Recording(id: id, projectId: "song", displayName: "b.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 30),
                                 uploadedAt: Date(timeIntervalSince1970: 30)))
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "a.m4a", deletedAt: 20_000))
        try context.save()
        try await store.library.reconcile(context: context)
        let kept = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(kept.uploadedAt == Date(timeIntervalSince1970: 30) && !kept.precedenceRepaired)
    }

    @Test func copiesOfOneRecordingShareTheBytesReadForAnyOfThem() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let audio = Data(repeating: 7, count: 100)
        // Five Trash copies; the newest (the canonical one) is last in path order.
        for ms in [1_000, 2_000, 3_000, 4_000, 5_000] { try write(audio, "song", "\(ms)__take.m4a", root: store.trash, modified: 50) }
        store.library.adoptionBudget = 200
        let result = try await store.library.reconcile(context: context)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.trashedAt == Date(timeIntervalSince1970: 5) && result.pendingAdoption == 0 && !store.library.adoptionStalled)
    }

    @Test func aRunThatTakesNothingInStopsAndTheReportedFileCanBeKeptSeparately() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = derivedId("song", "a.m4a", Data([1]))
        let legacy = try write(Data([1]), "song", "a.m4a", root: store.root)
        let squatter = try write(Data([9]), "song", "\(id).m4a", root: store.root)
        try write(Data([5]), "song", "z.m4a", root: store.root)
        store.library.adoptionBudget = 1
        for _ in 0..<2 {
            let result = try await store.library.reconcile(context: context)
            #expect(store.library.adoptionStalled && result.pendingAdoption > 0)
            #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        }
        #expect(Set(store.library.needsAttention.map(\.lastPathComponent)) == ["a.m4a", "\(id).m4a"])

        // Kept separately: the squatter gets an id of its own, then everything is taken in.
        let kept = try store.library.keepSeparately(squatter)
        #expect(RecordingFiles.storedId(of: kept) != id)
        for _ in 0..<3 { try await store.library.reconcile(context: context) }
        let rows = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Recording>()).map { ($0.audio, $0) })
        #expect(rows.count == 3 && rows[Data([1])]?.id == id && rows[Data([1])]?.displayName == "a.m4a")
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/\(id).m4a")) == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: legacy.path) && !store.library.adoptionStalled)
    }

    @Test func aZeroTimeTrashFileGetsATrashTimeWhenTakenIn() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        try write(Data([3]), "song", "0__take.m4a", root: store.trash, modified: 0)
        let before = Date().addingTimeInterval(-1)
        try await store.library.reconcile(context: context)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(try #require(row.trashedAt) >= before)
        #expect(try store.library.trashedRecordings(in: context).allSatisfy { $0.deleteAfter > Date().addingTimeInterval(trashRetentionInterval - 60) })
    }

    @Test func interruptedOversizedMovesAreFinishedFromTheirJournal() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let big = Data(repeating: 4, count: Int(SyncRecording.maxBytes) + 1)
        let live = try store.library.publishFinished(try stage(big), projectId: "song", preferredName: "long.m4a", origin: .recorded)
        let id = try #require(RecordingFiles.storedId(of: live))
        // Trash journalled, then the app stopped before the move.
        var entry = try #require(OversizedRecordings.read(for: store.root)[id])
        entry.trashedAt = 9_000
        entry.source = live.path
        entry.completed = false
        entry.bytes = Int64(big.count)
        try OversizedRecordings.record(id: id, entry: entry, for: store.root)
        try await store.library.reconcile(context: context)
        let trashPlace = store.trash.appendingPathComponent("song/\(id).m4a")
        #expect(FileManager.default.fileExists(atPath: trashPlace.path) && !FileManager.default.fileExists(atPath: live.path))
        #expect(try OversizedRecordings.read(for: store.root)[id]?.completed == true)
        #expect(try store.library.trashedRecordings(in: context).map(\.recordingId) == [id])

        // A journal whose source holds other bytes moves nothing.
        entry.trashedAt = nil
        entry.source = trashPlace.path
        entry.completed = false
        entry.sha256 = String(repeating: "0", count: 64)
        try OversizedRecordings.record(id: id, entry: entry, for: store.root)
        try await store.library.reconcile(context: context)
        #expect(FileManager.default.fileExists(atPath: trashPlace.path))
        #expect(try OversizedRecordings.read(for: store.root)[id]?.completed == false)
    }

    @Test func symbolicLinksAreNeverRecordingsAndNothingOutsideIsMoved() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(uuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("private.m4a")
        try Data([8]).write(to: target)
        // A linked file in a song folder, and a linked song folder.
        let folder = store.root.appendingPathComponent("song", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.m4a"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("linked-song"), withDestinationURL: outside)
        // A move record naming the outside file, and a deletion that would cover it.
        try RecordingFiles.setPendingQuarantine([RecordingFiles.canonicalPath(target)], for: store.root)
        context.insert(SyncDeletionRecord(projectId: "song", deletedAt: 4_000_000_000_000))
        try context.save()

        try await store.library.reconcile(context: context)
        try await store.library.reconcile(context: context)

        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(try Data(contentsOf: target) == Data([8]))
        #expect(names(RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("song")).isEmpty)
        #expect(!RecordingFiles.isRecordingFile(folder.appendingPathComponent("link.m4a"), in: [store.root]))
        #expect(throws: (any Error).self) { try RecordingFiles.quarantine(target, recordingId: "x", memosRoot: store.root, trashRoot: store.trash) }
    }

    @Test func aStagedFileLeftUnderTheSameIdIsUsedOnlyWithTheSameBytes() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let audio = Data([6, 6])
        let id = uuid()
        let staging = RecordingFiles.stagingRoot(for: store.root)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let leftover = staging.appendingPathComponent("\(id).m4a")
        try Data([0, 0]).write(to: leftover)
        let entry = SyncRecording(id: id, projectId: "song", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 5))
        #expect(throws: SyncValidationError.invalidRecording) { try store.library.commitRestored(audio, entry: entry, origin: .restored, context: context) }
        #expect(try Data(contentsOf: leftover) == Data([0, 0]), "never replaced")
        try FileManager.default.removeItem(at: leftover)
        try audio.write(to: leftover)
        #expect(try store.library.commitRestored(audio, entry: entry, origin: .restored, context: context))
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/\(id).m4a")) == audio)
    }

    @Test func restoredAudioMustMatchItsDeclaredLength() async throws {
        let store = try await makeStore()
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
        return (try #require(try OpenRecordingSnapshot(projectId: "song", recordingsRoot: root, displayNames: ["a.m4a": "Verse.m4a"])), root)
    }

    @Test func copiesAreNewRecordingsNamedByTheirIdsAndARepeatFindsThem() async throws {
        let (snapshot, root) = try makeSnapshot()
        let copies = try snapshot.copy(to: "copy")
        #expect(copies.count == 2 && copies.allSatisfy { RecordingFiles.storedId(of: $0.url) == $0.recordingId })
        #expect(Set(copies.map(\.displayName)) == ["Verse.m4a", "b.m4a"])
        let again = try snapshot.copy(to: "copy")
        #expect(Set(again.map(\.recordingId)) == Set(copies.map(\.recordingId)))
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("copy").path)).count == 2)
    }

    @Test func rollbackRemovesOnlyItsOwnUnchangedFiles() async throws {
        let (snapshot, root) = try makeSnapshot()
        let destination = root.appendingPathComponent("copy", isDirectory: true)
        let copies = try snapshot.copy(to: "copy")
        let replaced = try #require(copies.first { $0.displayName == "b.m4a" }).url
        // Something replaced one copy and added another file before the rollback.
        try FileManager.default.removeItem(at: replaced)
        try Data([7]).write(to: replaced)
        try Data([8]).write(to: destination.appendingPathComponent("c.m4a"))

        snapshot.removeCopy(for: "copy")

        #expect(try Data(contentsOf: replaced) == Data([7]))
        #expect(try Data(contentsOf: destination.appendingPathComponent("c.m4a")) == Data([8]))
        #expect((try FileManager.default.contentsOfDirectory(atPath: destination.path)).count == 2)
    }
}
