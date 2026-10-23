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

    @Test func aTombstoneIsComparedWithTheTrashDeletionTimeOnly() async throws {
        // Deleted for real at 100 s; edit time missing, repaired to 300 s; tombstone at 200 s.
        let trash = SyncTrashedSongProject(id: "t", title: "T", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 300),
                                           deletedAt: Date(timeIntervalSince1970: 100), deleteAfter: Date(timeIntervalSince1970: 100).addingTimeInterval(trashRetentionInterval),
                                           precedenceRepaired: true)
        let tombstone = SyncDeletion(projectId: "t", deletedAt: 200_000)
        for (local, remote) in [(SyncBlob(trashed: [trash]), SyncBlob(deletions: [tombstone])), (SyncBlob(deletions: [tombstone]), SyncBlob(trashed: [trash]))] {
            let merged = try SyncMerger.merge(local: local, remote: remote)
            #expect(merged.trashed.isEmpty && merged.deletions == [tombstone])
        }
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

    @Test func archiveNamesTakeOnlyAShortExtension() async throws {
        // A 246-byte name whose text after its last dot is 241 bytes: all stem, cut to 240.
        let long = "abcd." + String(repeating: "x", count: 241)
        #expect(long.utf8.count == 246)
        let first = RecordingBackupManifest.archiveName(long, number: nil)
        let second = RecordingBackupManifest.archiveName(long, number: 2)
        #expect(first.utf8.count == 240 && first.hasPrefix("abcd.xxx"))
        #expect(second.utf8.count == 240 && second.hasSuffix(" 2"))
        // A name ending in a dot has no extension.
        #expect(RecordingBackupManifest.archiveName("take.", number: 2) == "take. 2")
        // A 16-byte extension still counts; a 17-byte one does not.
        #expect(RecordingBackupManifest.archiveName("a." + String(repeating: "e", count: 16), number: 2) == "a 2." + String(repeating: "e", count: 16))
        #expect(RecordingBackupManifest.archiveName("a." + String(repeating: "e", count: 17), number: 2) == "a." + String(repeating: "e", count: 17) + " 2")
        // The stem never goes below one code point.
        #expect(RecordingBackupManifest.archiveName("\u{1F3B5}.m4a", number: 2) == "\u{1F3B5} 2.m4a")
    }

    @Test func aRecordedTombstoneBeatsARepairedTimeAndTrashCopiesSettleEachTime() async throws {
        let trash = SyncTrashedSongProject(id: "t", title: "T", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 10),
                                           deletedAt: Date(timeIntervalSince1970: 300), deleteAfter: Date(timeIntervalSince1970: 300).addingTimeInterval(trashRetentionInterval),
                                           trashedAtRepaired: true)
        let tombstone = SyncDeletion(projectId: "t", deletedAt: 200_000)
        #expect(try SyncMerger.merge(local: SyncBlob(trashed: [trash]), remote: SyncBlob(deletions: [tombstone])).trashed.isEmpty)
        let song = SyncSongProject(id: "s", title: "S", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 300), precedenceRepaired: true)
        #expect(try SyncMerger.merge(local: SyncBlob(projects: [song]), remote: SyncBlob(deletions: [SyncDeletion(projectId: "s", deletedAt: 200_000)])).projects.isEmpty)

        // Two Trash copies: deletion time and edit time settled apart.
        let a = SyncTrashedSongProject(id: "m", title: "A", lyrics: "a", theme: "", updatedAt: Date(timeIntervalSince1970: 500),
                                       deletedAt: Date(timeIntervalSince1970: 100), deleteAfter: Date(timeIntervalSince1970: 100).addingTimeInterval(trashRetentionInterval),
                                       precedenceRepaired: true)
        let b = SyncTrashedSongProject(id: "m", title: "B", lyrics: "b", theme: "", updatedAt: Date(timeIntervalSince1970: 400),
                                       deletedAt: Date(timeIntervalSince1970: 300), deleteAfter: Date(timeIntervalSince1970: 300).addingTimeInterval(trashRetentionInterval),
                                       trashedAtRepaired: true)
        for (first, second) in [(a, b), (b, a)] {
            let merged = try #require(SyncMerger.merge(local: SyncBlob(trashed: [first]), remote: SyncBlob(trashed: [second])).trashed.first)
            #expect(merged.deletedAt == Date(timeIntervalSince1970: 100) && !merged.trashedAtRepaired)
            #expect(merged.updatedAt == Date(timeIntervalSince1970: 400) && !merged.precedenceRepaired && merged.title == "B")
            #expect(merged.deleteAfter == Date(timeIntervalSince1970: 100).addingTimeInterval(trashRetentionInterval))
        }
    }

    @Test func anEmptyRecordingIsNeverOne() async throws {
        let empty = SyncRecording(id: "e", projectId: "p", fileName: "take.m4a", bytes: 0, sha256: RecordingBackupManifest.sha256Hex(Data()), uploadedAt: Date(timeIntervalSince1970: 5))
        #expect(throws: (any Error).self) { try empty.validate() }
        #expect(throws: (any Error).self) { _ = try SyncBlob(recordings: [empty]).encodedManifest() }
    }

    @Test func aDisplayNameIsMetadataNotAPath() async throws {
        for name in ["../verse/idea.m4a", "no extension", "line\nbreak", String(repeating: "\u{E9}", count: 512)] {
            #expect(throws: Never.self) { try SyncIdentity.validateDisplayName(name) }
        }
        for name in ["", "nul\u{0}.m4a", String(repeating: "a", count: 1025)] {
            #expect(throws: (any Error).self) { try SyncIdentity.validateDisplayName(name) }
        }
        // File names from before A36 keep the strict rule.
        #expect(throws: (any Error).self) { try SyncIdentity.validateFileName("../verse/idea.m4a") }
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

    /// The same on-disk store, files and settings opened afresh, as after the app was
    /// killed: nothing held in memory by the earlier container or library carries over.
    private func reopen(_ store: Store) throws -> Store {
        let scratch = store.root.deletingLastPathComponent()
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let configuration = ModelConfiguration(schema: schema, url: scratch.appendingPathComponent("library.store"), cloudKitDatabase: .none)
        let library = RecordingLibrary(memosRoot: store.root, trashRoot: store.trash,
                                       defaults: UserDefaults(suiteName: "RecordingLibraryTests-\(scratch.lastPathComponent)")!)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        library.context = container.mainContext
        return (container, store.root, store.trash, library)
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
        // The next run is after a relaunch (T6.26).
        let relaunched = try reopen(store)
        try await relaunched.library.reconcile(context: relaunched.container.mainContext)
        #expect(!FileManager.default.fileExists(atPath: live.path))
        #expect(try Data(contentsOf: store.trash.appendingPathComponent("song/\(live.lastPathComponent)")) == Data([1]))
        #expect(try relaunched.container.mainContext.fetch(FetchDescriptor<Recording>()).map(\.pendingFrom) == [nil])
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

    @Test func aFileWithoutATimeLosesToARecordedTombstone() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        try write(Data([4]), "song", "old.m4a", root: store.root, modified: 0)
        let id = derivedId("song", "old.m4a", Data([4]))
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "old.m4a", deletedAt: 1_000))
        try context.save()
        try await store.library.reconcile(context: context)
        // A38: its first-seen time is a repair, and a recorded tombstone beats a repair.
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(names(RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("song")) == ["\(id).m4a"])
        // Without a tombstone it is stamped first-seen and marked.
        try write(Data([5]), "song", "new.m4a", root: store.root, modified: 0)
        try await store.library.reconcile(context: context)
        let row = try #require(context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.precedenceTime.epochMilliseconds > 0 && row.precedenceRepaired)
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
        // Without a deletion: the smaller repair (10 s) is the one kept, whichever copy survives (T6.34).
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
            try context.save()
            try await store.library.reconcile(context: context)
            let kept = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
            #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
            #expect(kept.uploadedAt == Date(timeIntervalSince1970: 10) && kept.precedenceRepaired)
        }
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
        // Finished after a relaunch, from the record alone (T6.38).
        let relaunched = try reopen(store)
        try await relaunched.library.reconcile(context: relaunched.container.mainContext)
        let trashPlace = store.trash.appendingPathComponent("song/\(id).m4a")
        #expect(FileManager.default.fileExists(atPath: trashPlace.path) && !FileManager.default.fileExists(atPath: live.path))
        #expect(try OversizedRecordings.read(for: store.root)[id]?.completed == true)
        #expect(try relaunched.library.trashedRecordings(in: relaunched.container.mainContext).map(\.recordingId) == [id])
        try await store.library.reconcile(context: context)

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
        #expect(throws: (any Error).self) { try RecordingFiles.quarantine(target, to: RecordingFiles.quarantineDestination(for: target, recordingId: "x", memosRoot: store.root), sha256: RecordingFiles.sha256(of: target), bytes: 1, memosRoot: store.root, trashRoot: store.trash) }
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

    @Test func aPendingRenameSurvivesTheCollapseOfDuplicateRows() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = uuid()
        context.insert(Recording(id: id, projectId: "song", displayName: "a.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10)))
        let renamed = Recording(id: id, projectId: "song", displayName: "z.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10))
        renamed.displayNameChanged = true
        context.insert(renamed)
        try context.save()
        try await store.library.reconcile(context: context)
        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(rows.count == 1 && rows[0].displayName == "z.m4a" && rows[0].displayNameChanged)
    }

    @Test func aKilledMigrationOrQuarantineMoveIsFinishedFromItsRecord() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        // Migration: the row and its source were saved, then the app stopped before the rename.
        let legacy = try write(Data([1]), "song", "take.m4a", root: store.root)
        let id = derivedId("song", "take.m4a", Data([1]))
        let row = Recording(id: id, projectId: "song", displayName: "take.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10))
        row.pendingFrom = legacy.path
        context.insert(row)
        try context.save()
        // Quarantine: recorded, then the app stopped before the move.
        let covered = try write(Data([2]), "other", "\(uuid()).m4a", root: store.root)
        var moves = try RecordingFiles.readPendingMoves(for: store.root)
        moves.quarantine.append(.init(path: RecordingFiles.canonicalPath(covered), sha256: RecordingBackupManifest.sha256Hex(Data([2])), recordingId: "gone"))
        try RecordingFiles.writePendingMoves(moves, for: store.root)

        // The next run is after a relaunch (T6.42).
        let relaunched = try reopen(store)
        try await relaunched.library.reconcile(context: relaunched.container.mainContext)

        let reopenedRow = try #require(try relaunched.container.mainContext.fetch(FetchDescriptor<Recording>()).first { $0.id == id })
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/\(id).m4a")) == Data([1]) && reopenedRow.pendingFrom == nil)
        #expect(!FileManager.default.fileExists(atPath: legacy.path) && !FileManager.default.fileExists(atPath: covered.path))
        #expect(names(RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("other")) == ["gone.m4a"])
        #expect(try RecordingFiles.readPendingMoves(for: store.root).quarantine.isEmpty)
    }

    @Test func movesNeverFollowALinkedDestinationFolder() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(uuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // Quarantine: its song folder is a link.
        let file = try write(Data([3]), "song", "\(uuid()).m4a", root: store.root)
        let quarantine = RecordingFiles.quarantineRoot(for: store.root)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: quarantine.appendingPathComponent("song"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try RecordingFiles.quarantine(file, to: RecordingFiles.quarantineDestination(for: file, recordingId: "x", memosRoot: store.root), sha256: RecordingFiles.sha256(of: file), bytes: 1, memosRoot: store.root, trashRoot: store.trash) }
        // A recorded detach whose Trash song folder became a link.
        let id = uuid()
        let source = try write(Data([4]), "tune", "\(id).m4a", root: store.root)
        try FileManager.default.createDirectory(at: store.trash, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.trash.appendingPathComponent("tune"), withDestinationURL: outside)
        var moves = try RecordingFiles.readPendingMoves(for: store.root)
        moves.detach.append(.init(recordingId: id, source: RecordingFiles.canonicalPath(source),
                                  destination: store.trash.appendingPathComponent("tune/\(id).m4a").path,
                                  sha256: RecordingBackupManifest.sha256Hex(Data([4])), displayName: "take.m4a", at: 10_000, detachedAt: 20_000))
        try RecordingFiles.writePendingMoves(moves, for: store.root)
        try? await store.library.reconcile(context: context)

        #expect(names(outside).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path) && FileManager.default.fileExists(atPath: source.path))
    }

    @Test func emptyFilesAndEmptyAudioAreNeverTakenIn() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        try write(Data(), "song", "empty.m4a", root: store.root)
        try await store.library.reconcile(context: context)
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        let entry = SyncRecording(id: uuid(), projectId: "song", fileName: "take.m4a", bytes: 0, sha256: RecordingBackupManifest.sha256Hex(Data()), uploadedAt: Date(timeIntervalSince1970: 5))
        #expect(throws: (any Error).self) { try store.library.commitRestored(Data(), entry: entry, origin: .restored, context: context) }
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

/// Round 13 audit regressions: bytes are never lost to a row or file decision.
extension RecordingLibraryTests {
    /// Every file's bytes under the quarantine folder.
    private func quarantined(_ store: Store) -> [Data] {
        let root = RecordingFiles.quarantineRoot(for: store.root)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .compactMap { try? Data(contentsOf: $0) }
    }

    /// BLOCKER 5 (T1.38): rows of one id with different audio are both kept and reported.
    @Test func rowsOfOneIdWithDifferentAudioAreBothKeptAndReported() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = uuid()
        context.insert(Recording(id: id, projectId: "song", displayName: "a.m4a", audio: Data([1, 1]), recordedAt: Date(timeIntervalSince1970: 1_000)))
        context.insert(Recording(id: id, projectId: "song", displayName: "b.m4a", audio: Data([2, 2, 2]), recordedAt: Date(timeIntervalSince1970: 2_000)))
        try context.save()

        try await store.library.reconcile(context: context)
        try await store.library.reconcile(context: context)

        let rows = try context.fetch(FetchDescriptor<Recording>())
        #expect(Set(rows.map(\.audio)) == [Data([1, 1]), Data([2, 2, 2])])
        #expect(store.library.identityConflicts.count == 1)
    }

    /// BLOCKER 6 (T1.40): a row a newer tombstone removes before its audio reached
    /// this device has the audio written to quarantine first.
    @Test func aTombstonedRowWhoseAudioIsOnNoDiskIsQuarantinedBeforeItGoes() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = uuid()
        context.insert(Recording(id: id, projectId: "song", displayName: "take.m4a", audio: Data([7, 7, 7]), recordedAt: Date(timeIntervalSince1970: 1_000)))
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "take.m4a", deletedAt: 5_000_000))
        try context.save()

        try await store.library.reconcile(context: context)

        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(quarantined(store).contains(Data([7, 7, 7])))
        #expect(names(store.root.appendingPathComponent("song")).isEmpty)
    }

    /// BLOCKER 7 (T1.42): a song tombstone keeps the audio of rows that are on no disk.
    @Test func aSongTombstoneKeepsTheAudioOfRowsOnNoDisk() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        context.insert(Recording(projectId: "song", displayName: "take.m4a", audio: Data([5, 4]), recordedAt: Date(timeIntervalSince1970: 1_000)))
        try context.save()

        let removed = try store.library.tombstoneRecordings(ofProject: "song", deletedAt: 5_000_000, in: context)
        try context.save()

        #expect(removed.count == 1)
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).count == 1)
        #expect(quarantined(store) == [Data([5, 4])])
    }

    /// BLOCKER 12 (T3.1): a pre-A20 row (no upload time) keeps its real recorded
    /// time, so an older tombstone does not remove it and a newer one does.
    @Test func aRowFromBeforeUploadTimesKeepsItsRecordedTimeAsReal() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let row = Recording(projectId: "song", displayName: "take.m4a", audio: Data([3, 3]), recordedAt: Date(timeIntervalSince1970: 2_000))
        row.uploadedAt = nil
        context.insert(row)
        let id = row.id
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "take.m4a", deletedAt: 1_000_000))
        try context.save()

        try await store.library.reconcile(context: context)

        let kept = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        #expect(kept.uploadedAt == Date(timeIntervalSince1970: 2_000))
        #expect(!kept.precedenceRepaired)
    }

    /// T1.24/A36: a move never replaces a file at its destination, even one that
    /// appears between the check and the rename.
    @Test func aVerifiedMoveNeverReplacesAFileAtItsDestination() async throws {
        let store = try await makeStore()
        let source = try write(Data([1, 2]), "song", "\(uuid()).m4a", root: store.root)
        let target = try write(Data([9]), "song", "\(uuid()).m4a", root: store.root)

        #expect(throws: (any Error).self) {
            try RecordingFiles.verifiedMove(source, to: target, sha256: RecordingBackupManifest.sha256Hex(Data([1, 2])), bytes: 2, within: [store.root])
        }
        #expect(try Data(contentsOf: source) == Data([1, 2]))
        #expect(try Data(contentsOf: target) == Data([9]))
        // Bytes that changed since they were recorded are not moved either.
        let free = store.root.appendingPathComponent("song/\(uuid()).m4a")
        #expect(throws: (any Error).self) {
            try RecordingFiles.verifiedMove(source, to: free, sha256: RecordingBackupManifest.sha256Hex(Data([8, 8])), bytes: 2, within: [store.root])
        }
        #expect(!FileManager.default.fileExists(atPath: free.path))
    }

    /// T4.1–T4.6: a change made while another task holds the gate fails as busy and
    /// changes nothing; it succeeds once the gate is released.
    @Test func aChangeWhileTheGateIsHeldIsRefusedAsBusy() async throws {
        let store = try await makeStore()
        try write(Data([4, 4]), "song", "take.m4a", root: store.root)
        try await store.library.reconcile(context: store.container.mainContext)
        let live = try #require(store.library.liveRecordings(in: store.container.mainContext).first).url
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let (release, leave) = AsyncStream<Void>.makeStream()
        let holder = Task { @MainActor in
            await store.library.withGate {
                enter.yield()
                for await _ in release { break }
            }
        }
        for await _ in entered { break }

        #expect(throws: RecordingLibraryError.busy) { _ = try store.library.trashRecording(at: live, trashedAt: Date()) }
        #expect(FileManager.default.fileExists(atPath: live.path))

        leave.yield()
        await holder.value
        _ = try store.library.trashRecording(at: live, trashedAt: Date())
        #expect(!FileManager.default.fileExists(atPath: live.path))
    }

    /// T6.1: the move hook is called with the recording's id before its file moves,
    /// whoever starts the move.
    @Test func theMoveHookNamesTheRecordingBeforeItsFileMoves() async throws {
        let store = try await makeStore()
        try write(Data([6, 1]), "song", "take.m4a", root: store.root)
        try await store.library.reconcile(context: store.container.mainContext)
        let row = try #require(try store.container.mainContext.fetch(FetchDescriptor<Recording>()).first)
        let live = try #require(store.library.liveRecordings(in: store.container.mainContext).first).url
        var seen: [(Set<String>, Bool)] = []
        store.library.willMove = { ids, files in seen.append((ids, files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })) }

        _ = try store.library.trashRecording(at: live, trashedAt: Date())

        #expect(seen.contains { $0.0.contains(row.id) && $0.1 }, "stopped by id while the file was still in place")
    }
}

extension RecordingSnapshotCopyTests {
    /// BLOCKER 1 and 13 (T1.29, T5.25): a destination holding other bytes is never
    /// skipped; the copy takes a fresh id, so every recording reaches the song.
    @Test func aConflictingDestinationGivesTheCopyAFreshIdInsteadOfSkippingIt() async throws {
        let (snapshot, root) = try makeSnapshot()
        let derived = RecordingBackupManifest.legacyRecordingId(projectId: "copy", fileName: "a.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([1])))
        let squatter = root.appendingPathComponent("copy/\(RecordingFiles.storedName(id: derived, displayName: "Verse.m4a"))")
        try FileManager.default.createDirectory(at: squatter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9]).write(to: squatter)

        let copies = try snapshot.copy(to: "copy")

        #expect(copies.count == 2)
        let verse = try #require(copies.first { $0.displayName == "Verse.m4a" })
        #expect(try verse.recordingId != derived && Data(contentsOf: verse.url) == Data([1]))
        #expect(try Data(contentsOf: squatter) == Data([9]))
    }

    /// BLOCKER 2 (T1.32): the snapshot is removed only once every recording in it
    /// is held elsewhere with its exact bytes.
    @Test func theSnapshotIsKeptUntilEveryRecordingInItIsPreserved() async throws {
        let (snapshot, root) = try makeSnapshot()
        let folder = OpenRecordingSnapshot.stagingRoot(for: root).appendingPathComponent(snapshot.folderName)
        // The originals are gone (the song was deleted meanwhile): the snapshot is the only copy.
        try FileManager.default.removeItem(at: root.appendingPathComponent("song"))

        #expect(!snapshot.discard())
        #expect(FileManager.default.fileExists(atPath: folder.path))

        try snapshot.copy(to: "copy")
        #expect(snapshot.discard())
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

/// Round 13 (T3): state written by earlier builds, as literal serialized fixtures.
extension SyncManifestV4Tests {
    /// T3.6: a v4 manifest from before A21 lists recordings without ids and with an
    /// ISO-8601 upload time; each gets the id every device derives.
    @Test func aV4ManifestWithoutRecordingIdsDerivesTheLegacyIds() async throws {
        let sha = String(repeating: "ab", count: 32)
        let literal = """
        {"version":4,"savedAt":"2025-01-02T03:04:05.006Z","savedByClientId":"old-device","platform":"ios",
         "projects":[{"id":"song","title":"Song","lyrics":"","theme":"","updatedAt":1700000000000}],
         "trashed":[],
         "recordings":[{"projectId":"song","fileName":"take.m4a","bytes":3,"sha256":"\(sha)","uploadedAt":"2024-06-01T12:00:00.250Z"}],
         "deletions":[]}
        """
        var fields = try #require(try JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: Any])
        fields["manifestSha256"] = CanonicalJSON.sha256Hex(try JSONValue(any: fields))

        let blob = try SyncBlob.decodeManifest(try JSONSerialization.data(withJSONObject: fields))

        let recording = try #require(blob.recordings.first)
        #expect(recording.id == RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "take.m4a", sha256: sha))
        #expect(recording.uploadedAt.epochMilliseconds == 1_717_243_200_250)
    }
}

extension SyncManifestV4Tests {
    /// T3.15: a Trash entry in the flat shape pre-Drive iOS builds wrote decodes,
    /// and is written back in the nested shape.
    @Test func aFlatTrashEntryFromAnEarlyBuildDecodes() async throws {
        let literal = #"{"id":"t","title":"Old","lyrics":"cut verse","theme":"","updatedAt":1700000000000,"deletedAt":1700000100000,"deleteAfter":1702592100000}"#
        let trash = try JSONDecoder().decode(SyncTrashedSongProject.self, from: Data(literal.utf8))
        #expect(trash.id == "t" && trash.lyrics == "cut verse")
        #expect(trash.updatedAt.epochMilliseconds == 1_700_000_000_000 && trash.deletedAt.epochMilliseconds == 1_700_000_100_000)
        let nested = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(trash)) as? [String: Any])
        #expect(Set(nested.keys) == ["project", "deletedAt", "deleteAfter"])
    }
}

extension RecordingLibraryTests {
    /// A move record as an earlier build wrote it, byte for byte.
    private func writeMoveRecord(_ literal: String, root: URL) throws {
        let url = RecordingFiles.quarantineRoot(for: root).appendingPathComponent("pending-moves.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(literal.utf8).write(to: url)
    }

    /// T3.20–T3.22: move records in each earlier shape (cbc39e1 paths; c725690 paths
    /// with detaches; 89a9aa5–a25a2c3 paths with digests) are upgraded with their
    /// proof and replayed: the file goes to quarantine with its bytes.
    @Test(arguments: [0, 1, 2])
    func moveRecordsFromEarlierBuildsAreUpgradedAndReplayed(shape: Int) async throws {
        let store = try makeUncheckedStore(onDisk: true)
        let context = store.container.mainContext
        let audio = Data([2, 4, 6])
        let file = try write(audio, "song", "take.m4a", root: store.root)
        let path = RecordingFiles.canonicalPath(file)
        let sha = RecordingBackupManifest.sha256Hex(audio)
        try writeMoveRecord([
            #"["\#(path)"]"#,
            #"{"quarantine":["\#(path)"],"detach":[]}"#,
            #"{"quarantine":[{"path":"\#(path)","sha256":"\#(sha)"}],"detach":[]}"#,
        ][shape], root: store.root)

        try await store.library.reconcile(context: context)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(quarantined(store) == [audio])
        #expect(try RecordingFiles.readPendingMoves(for: store.root).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
    }

    /// T3.21: a three-field detach (c725690) is finished under its id, in the
    /// recordings Trash, with a repaired time.
    @Test func aThreeFieldDetachFromAnEarlierBuildIsFinished() async throws {
        let store = try makeUncheckedStore(onDisk: true)
        let context = store.container.mainContext
        let file = try write(Data([1, 3]), "song", "take.m4a", root: store.root)
        let id = uuid()
        let destination = store.trash.appendingPathComponent("song/1700000000000__take.m4a")
        try writeMoveRecord(#"{"quarantine":[],"detach":[{"recordingId":"\#(id)","source":"\#(RecordingFiles.canonicalPath(file))","destination":"\#(destination.path)"}]}"#,
                            root: store.root)

        try await store.library.reconcile(context: context)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        // Listed in the recordings Trash under its id, with a repaired time (A37).
        let trashed = try #require(try store.library.trashedRecordings(in: context).first { $0.recordingId == id })
        #expect(try trashed.originalName == "take.m4a" && Data(contentsOf: trashed.url) == Data([1, 3]))
        #expect(try RecordingFiles.readPendingMoves(for: store.root).detach.map(\.repaired) == [true])
    }

    /// T3.24–T3.26: an oversized record without a digest takes its proof from the
    /// file it stands for (then moves it to its id); with no such file it is unresolved.
    @Test func oversizedRecordsWithoutProofAreHydratedOrMarkedUnresolved() async throws {
        let store = try makeUncheckedStore(onDisk: true)
        let context = store.container.mainContext
        let big = Data(repeating: 5, count: Int(SyncRecording.maxBytes) + 1)
        try write(big, "song", "long.m4a", root: store.root)
        let found = uuid(), lost = uuid()
        let ledger = store.root.deletingLastPathComponent().appendingPathComponent("oversized-recordings.json")
        try Data(#"{"\#(found)":{"projectId":"song","fileName":"long.m4a","finishedAt":0},"\#(lost)":{"projectId":"song","fileName":"gone.m4a","finishedAt":1700000000000}}"#.utf8)
            .write(to: ledger)

        try await store.library.reconcile(context: context)

        let entries = try OversizedRecordings.read(for: store.root)
        let hydrated = try #require(entries[found])
        #expect(hydrated.sha256 == RecordingBackupManifest.sha256Hex(big) && hydrated.bytes == Int64(big.count))
        #expect(hydrated.finishedAt > 0 && hydrated.repaired == true && hydrated.unresolved == nil)
        #expect(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("song/\(found).m4a").path))
        #expect(entries[lost]?.unresolved == true)
    }

    /// T3.37–T3.40: earlier registries and claims become current state: a synced
    /// claim that differs marks the row renamed, and the old keys go.
    @Test func earlierClaimsAndRegistriesAreCarriedOverOnce() async throws {
        let store = try makeUncheckedStore(onDisk: true)
        let context = store.container.mainContext
        let row = Recording(projectId: "song", displayName: "take.m4a", audio: Data([7]), recordedAt: Date(timeIntervalSince1970: 1_000))
        row.legacyClaimedName = "Chorus idea.m4a"
        context.insert(row)
        try context.save()
        let defaults = try #require(UserDefaults(suiteName: "RecordingLibraryTests-\(store.root.deletingLastPathComponent().lastPathComponent)"))
        defaults.set([row.id: "take.m4a"], forKey: "backup-synced-claims")
        defaults.set(["song/old.m4a"], forKey: "recording-library-mirrored-keys")

        try await store.library.reconcile(context: context)

        let kept = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        #expect(kept.displayName == "Chorus idea.m4a" && kept.legacyClaimedName.isEmpty && kept.displayNameChanged)
        #expect(defaults.object(forKey: "backup-synced-claims") == nil)
        #expect(defaults.object(forKey: "recording-library-mirrored-keys") == nil)
    }
}

/// Round 14: each byte transition, interrupted or challenged at its boundary by the
/// production code itself (a hook at the primitive), then replayed after a reopen.
extension RecordingLibraryTests {
    private func scratch(_ store: Store) -> URL { store.root.deletingLastPathComponent() }

    /// A published take in "song", with its row.
    private func published(_ data: Data, in store: Store) throws -> (url: URL, id: String) {
        let url = try store.library.publishFinished(try stage(data), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        return (url, try #require(RecordingFiles.storedId(of: url)))
    }

    /// T1.13, T6.26: a row move (trashed elsewhere) stops the id, records its source
    /// on the row before the move, and is finished after a crash at either window.
    @Test(arguments: [RecordingFiles.BoundaryHooks.Point.beforeCheck, .afterPrimitive])
    func aRowMoveKilledAtItsBoundaryIsFinishedAfterARelaunch(window: RecordingFiles.BoundaryHooks.Point) async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let take = try published(Data([1, 2]), in: store)
        let row = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        row.trashedAt = Date(timeIntervalSince1970: 60)
        try context.save()
        let stopped = HookBox<Set<String>>([])
        store.library.willMove = { ids, _ in stopped.value.formUnion(ids) }
        let seen = HookBox<(stopped: Bool, pendingSaved: Bool)?>(nil)
        let crashed = HookBox(false)
        try? await withBoundaryHook(scope: scratch(store), { point, source, _ in
            guard point == window, source.lastPathComponent == take.url.lastPathComponent else { return }
            if crashed.value { throw SimulatedCrash() }
            crashed.value = true
            seen.value = (stopped.value.contains(take.id), true)
            throw SimulatedCrash()
        }) {
            try await store.library.reconcile(context: context)
        }
        #expect(crashed.value && seen.value?.stopped == true, "playback of the id was stopped before the primitive")
        // What the production run saved before the crash names the move's source.
        let relaunched = try reopen(store)
        let saved = try #require(try relaunched.container.mainContext.fetch(FetchDescriptor<Recording>()).first)
        #expect(saved.pendingFrom.map { RecordingFiles.canonicalPath(URL(fileURLWithPath: $0)) } == RecordingFiles.canonicalPath(take.url))

        try await relaunched.library.reconcile(context: relaunched.container.mainContext)

        #expect(!FileManager.default.fileExists(atPath: take.url.path))
        #expect(try Data(contentsOf: store.trash.appendingPathComponent("song/\(take.id).m4a")) == Data([1, 2]))
        #expect(try relaunched.container.mainContext.fetch(FetchDescriptor<Recording>()).map(\.pendingFrom) == [nil])
    }

    /// T1.13: bytes that change at the boundary are not moved; they stay where they are.
    @Test func aRowMoveKeepsBytesThatChangeAtItsBoundary() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let take = try published(Data([1, 2]), in: store)
        try #require(try context.fetch(FetchDescriptor<Recording>()).first).trashedAt = Date(timeIntervalSince1970: 60)
        try context.save()

        try await withBoundaryHook(scope: scratch(store), { point, source, _ in
            guard point == .beforeCheck, source.lastPathComponent == take.url.lastPathComponent else { return }
            try Data([9, 9]).write(to: source)
        }) {
            try await store.library.reconcile(context: context)
        }

        #expect(try Data(contentsOf: take.url) == Data([9, 9]))
        #expect(!FileManager.default.fileExists(atPath: store.trash.appendingPathComponent("song/\(take.id).m4a").path))
    }

    /// T1.6: a file that appears at the destination after the check and before the
    /// rename is never replaced.
    @Test func aDestinationThatAppearsAtTheBoundaryIsNeverReplaced() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let take = try published(Data([1, 2]), in: store)
        try #require(try context.fetch(FetchDescriptor<Recording>()).first).trashedAt = Date(timeIntervalSince1970: 60)
        try context.save()
        let place = store.trash.appendingPathComponent("song/\(take.id).m4a")

        let result = try await withBoundaryHook(scope: scratch(store), { point, _, target in
            guard point == .beforeCheck, let target, target.lastPathComponent == place.lastPathComponent else { return }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([7]).write(to: target)
        }) {
            try await store.library.reconcile(context: context)
        }

        #expect(try Data(contentsOf: place) == Data([7]))
        #expect(try Data(contentsOf: take.url) == Data([1, 2]))
        #expect(result.needsAttention.map(RecordingFiles.canonicalPath).contains(RecordingFiles.canonicalPath(take.url)))
    }

    /// T1.5, T1.14, T6.42: a quarantine is recorded by the run with its id,
    /// destination and length before the move; after a crash at the move the replay
    /// uses that record, and checks the bytes again at the boundary.
    @Test(arguments: [false, true])
    func aQuarantineKilledAtItsMoveIsReplayedFromItsRecord(bytesChange: Bool) async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let take = try published(Data([3, 4]), in: store)
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: take.id, fileName: "take.m4a", deletedAt: Date().epochMilliseconds + 60_000))
        try context.save()
        let crashed = HookBox(false)

        try await withBoundaryHook(scope: scratch(store), { point, source, _ in
            // Once crashed, the process is gone: every later step there fails too.
            guard point == .beforeCheck, source.lastPathComponent == take.url.lastPathComponent else { return }
            crashed.value = true
            throw SimulatedCrash()
        }) {
            _ = try? await store.library.reconcile(context: context)
        }

        #expect(crashed.value)
        let record = try #require(try RecordingFiles.readPendingMoves(for: store.root).quarantine.first)
        #expect(record.recordingId == take.id && record.bytes == 2 && record.destination != nil)
        #expect(FileManager.default.fileExists(atPath: take.url.path))
        if bytesChange { try Data([5, 5]).write(to: take.url) }

        let relaunched = try reopen(store)
        try await relaunched.library.reconcile(context: relaunched.container.mainContext)

        let destination = URL(fileURLWithPath: try #require(record.destination))
        if bytesChange {
            #expect(try Data(contentsOf: take.url) == Data([5, 5]), "other bytes are never moved on the record's say")
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        } else {
            #expect(!FileManager.default.fileExists(atPath: take.url.path))
            #expect(try Data(contentsOf: destination) == Data([3, 4]))
        }
        #expect(try RecordingFiles.readPendingMoves(for: store.root).quarantine.isEmpty)
    }

    /// T1.15: a recording removed elsewhere is detached to the Trash under its id; a
    /// crash at the move leaves the record with its length, the replay stops the id
    /// and refuses a source whose length changed.
    @Test(arguments: [false, true])
    func aDetachKilledAtItsMoveIsReplayedOnlyForItsOwnBytes(lengthChanges: Bool) async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let take = try published(Data([6, 6]), in: store)
        // Removed on another device: the row goes, the file is still here.
        context.delete(try #require(try context.fetch(FetchDescriptor<Recording>()).first))
        try context.save()
        let crashed = HookBox(false)
        try await withBoundaryHook(scope: scratch(store), { point, source, _ in
            // Once crashed, the process is gone: every later step there fails too.
            guard point == .beforeCheck, source.lastPathComponent == take.url.lastPathComponent else { return }
            crashed.value = true
            throw SimulatedCrash()
        }) {
            _ = try? await store.library.reconcile(context: context)
        }
        let record = try #require(try RecordingFiles.readPendingMoves(for: store.root).detach.first)
        #expect(crashed.value && record.recordingId == take.id && record.bytes == 2)
        if lengthChanges { try Data([6, 6, 6]).write(to: take.url) }

        let relaunched = try reopen(store)
        let stopped = HookBox<Set<String>>([])
        relaunched.library.willMove = { ids, _ in stopped.value.formUnion(ids) }
        try await relaunched.library.reconcile(context: relaunched.container.mainContext)

        let destination = URL(fileURLWithPath: record.destination)
        if lengthChanges {
            #expect(try Data(contentsOf: take.url) == Data([6, 6, 6]))
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        } else {
            #expect(stopped.value.contains(take.id))
            #expect(try Data(contentsOf: destination) == Data([6, 6]))
            #expect(try relaunched.library.trashedRecordings(in: relaunched.container.mainContext).map(\.recordingId) == [take.id])
        }
    }

    /// T1.9, T1.10, T1.12: a row whose audio is on no disk is written out: staged as
    /// `partial/<id>.<ext>` with the partial-to-staged move journalled first, then the
    /// row records its staged source and the id is stopped before the final move.
    @Test func materializationRecordsEveryStepBeforeItsMove() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let row = Recording(projectId: "song", displayName: "take.m4a", audio: Data([8, 8]), recordedAt: Date(timeIntervalSince1970: 10))
        context.insert(row)
        try context.save()
        let id = row.id
        let stopped = HookBox<Set<String>>([])
        store.library.willMove = { ids, _ in stopped.value.formUnion(ids) }
        let partialStep = HookBox<(name: String, folder: String, journalled: Bool)?>(nil)
        let finalStep = HookBox<(stopped: Bool, source: String)?>(nil)
        let root = store.root

        try await withBoundaryHook(scope: scratch(store), { point, source, target in
            guard point == .beforeCheck, let target else { return }
            if source.deletingLastPathComponent().lastPathComponent == "partial" {
                let journal = try RecordingFiles.readStagingJournal(for: root)
                partialStep.value = (source.lastPathComponent, source.deletingLastPathComponent().lastPathComponent,
                                     journal.moves.contains { $0.recordingId == id && $0.destination == RecordingFiles.canonicalPath(target) && $0.bytes == 2 })
            } else if target.lastPathComponent == "\(id).m4a" {
                finalStep.value = (stopped.value.contains(id), source.path)
            }
        }) {
            try await store.library.reconcile(context: context)
        }

        #expect(partialStep.value?.name == "\(id).m4a" && partialStep.value?.journalled == true)
        #expect(finalStep.value?.stopped == true)
        // The run saved the staged source on the row before the move (read from disk).
        let source = try #require(finalStep.value?.source)
        #expect(URL(fileURLWithPath: source).lastPathComponent == "\(id).m4a")
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/\(id).m4a")) == Data([8, 8]))
        #expect(try RecordingFiles.readStagingJournal(for: store.root).moves.isEmpty)
    }

    /// T1.20: publication stops the id before the take's file moves.
    @Test func publicationStopsTheIdBeforeTheTakeMoves() async throws {
        let store = try await makeStore()
        let stopped = HookBox<Set<String>>([])
        store.library.willMove = { ids, _ in stopped.value.formUnion(ids) }
        let atMove = HookBox<Bool?>(nil)
        let staged = try stage(Data([2, 2]))
        let id = uuid()
        try await withBoundaryHook(scope: staged.deletingLastPathComponent(), { point, source, _ in
            guard point == .beforeCheck else { return }
            atMove.value = stopped.value.contains(id)
        }) {
            _ = try store.library.publishFinished(staged, projectId: "song", preferredName: "take.m4a", origin: .recorded, id: id, finishedAt: Date(timeIntervalSince1970: 5))
        }
        #expect(atMove.value == true)
    }

    /// T1.1, T6: a song's file deletion is planned (path, digest, length) before the
    /// unlink; after a crash there the plan is finished on the next run.
    @Test func aSongDeletionKilledBeforeItsUnlinkIsFinishedFromThePlan() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let take = try published(Data([4, 4]), in: store)
        let plan = try store.library.songDeletionPlan("song", in: context)
        // As a permanent deletion does: the rows go in the save before the files.
        try context.fetch(FetchDescriptor<Recording>()).forEach(context.delete)
        try context.save()
        let crashed = HookBox(false)
        try await withBoundaryHook(scope: scratch(store), { point, source, target in
            guard point == .beforeCheck, target == nil else { return }
            crashed.value = true
            throw SimulatedCrash()
        }) {
            _ = try store.library.deleteSongFiles("song", plan: plan)
        }
        #expect(crashed.value && FileManager.default.fileExists(atPath: take.url.path))
        #expect(try RecordingFiles.readDeletionPlan(for: store.root).items.map(\.bytes) == [2])

        let relaunched = try reopen(store)
        try await relaunched.library.reconcile(context: relaunched.container.mainContext)

        #expect(!FileManager.default.fileExists(atPath: take.url.path))
        #expect(try RecordingFiles.readDeletionPlan(for: store.root).items.isEmpty)
    }

    /// T1.1, T1.2, T1.25: bytes that change right before the unlink are kept, for a
    /// song's files and for a recordings Trash entry.
    @Test func aDeletionKeepsBytesThatChangeRightBeforeTheUnlink() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let take = try published(Data([4, 4]), in: store)
        let plan = try store.library.songDeletionPlan("song", in: context)
        let replace: @Sendable (RecordingFiles.BoundaryHooks.Point, URL, URL?) throws -> Void = { point, source, target in
            guard point == .beforeCheck, target == nil else { return }
            try Data([0, 1]).write(to: source)
        }
        let kept = try await withBoundaryHook(scope: scratch(store), replace) { try store.library.deleteSongFiles("song", plan: plan) }
        #expect(kept.map(RecordingFiles.canonicalPath) == [RecordingFiles.canonicalPath(take.url)])
        #expect(try Data(contentsOf: take.url) == Data([0, 1]))

        // A recordings Trash entry, deleted with the proof of the bytes it held.
        let other = try published(Data([5, 5, 5]), in: store)
        try await store.library.reconcile(context: context)
        let trashed = try store.library.trashRecording(at: other.url, trashedAt: Date())
        let sha = try RecordingFiles.sha256(of: trashed.url)
        try await withBoundaryHook(scope: scratch(store), replace) {
            #expect(throws: RecordingLibraryError.notVerified) { try store.library.deleteTrashedFile(trashed, sha256: sha, bytes: 3) }
        }
        #expect(try Data(contentsOf: trashed.url) == Data([0, 1]))
    }
}

extension RecordingLibraryTests {
    /// SHOULD 5 (T1.7): a staging record that cannot be read clears nothing; the
    /// staged audio it may name stays, and the damage is reported.
    @Test func anUnreadableStagingRecordClearsNothing() async throws {
        let store = try await makeStore()
        let staging = RecordingFiles.stagingRoot(for: store.root)
        let partial = staging.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let id = uuid()
        try Data([1, 1]).write(to: partial.appendingPathComponent("\(id).m4a"))
        try Data([2, 2]).write(to: staging.appendingPathComponent("\(id).m4a"))
        try Data("{\"moves\":[{\"recordingId\":".utf8).write(to: staging.appendingPathComponent("journal.json"))

        store.library.clearStaging(context: store.container.mainContext)
        try await store.library.reconcile(context: store.container.mainContext)
        store.library.clearStaging(context: store.container.mainContext)

        #expect(try Data(contentsOf: partial.appendingPathComponent("\(id).m4a")) == Data([1, 1]))
        #expect(try Data(contentsOf: staging.appendingPathComponent("\(id).m4a")) == Data([2, 2]))
        #expect(store.library.stateIssues.contains { $0.contains("staged copies are kept") })
    }
}

/// Round 14: times, earlier state, gate and reports, each failing if its fix is undone.
extension RecordingLibraryTests {
    private func suite(_ store: Store) -> UserDefaults {
        UserDefaults(suiteName: "RecordingLibraryTests-\(store.root.deletingLastPathComponent().lastPathComponent)")!
    }

    /// T2.21, T2.26: rows of one recording in the Trash, one with a recorded Trash
    /// time and one with a repaired one, settle on the recorded time, in both orders.
    @Test(arguments: [false, true])
    func duplicateTrashRowsSettleOnTheRecordedTrashTime(recordedFirst: Bool) async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let id = uuid()
        let times: [(String, TimeInterval, Bool)] = recordedFirst ? [("a.m4a", 5_000, false), ("b.m4a", 1_000, true)] : [("a.m4a", 1_000, true), ("b.m4a", 5_000, false)]
        for (name, seconds, repaired) in times {
            let row = Recording(id: id, projectId: "song", displayName: name, audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10))
            row.trashedAt = Date(timeIntervalSince1970: seconds)
            row.trashedAtRepaired = repaired
            context.insert(row)
        }
        try context.save()

        try await store.library.reconcile(context: context)

        let kept = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        #expect(try context.fetch(FetchDescriptor<Recording>()).count == 1)
        #expect(kept.trashedAt == Date(timeIntervalSince1970: 5_000) && !kept.trashedAtRepaired)
    }

    /// T2.27: two Trash files of one identity, one named with no time and one with a
    /// recorded time, are one recording with the recorded time.
    @Test func duplicateTrashFilesTakeTheRecordedTimeOverAMissingOne() async throws {
        let store = try await makeStore()
        let zero = try write(Data([7]), "song", "0__take.m4a", root: store.trash, modified: 0)
        let timed = try write(Data([7]), "song", "5000__take.m4a", root: store.trash, modified: 0)
        _ = (zero, timed)

        try await store.library.reconcile(context: store.container.mainContext)

        let rows = try store.container.mainContext.fetch(FetchDescriptor<Recording>())
        #expect(rows.count == 1)
        #expect(rows.first?.trashedAt == Date(timeIntervalSince1970: 5) && rows.first?.trashedAtRepaired == false)
    }

    /// T2.25: a recording removed elsewhere whose verified record has no time is
    /// detached with its first-seen time as a repair, and the record stays readable.
    @Test func aRemovedRecordingWhoseRecordHasNoTimeIsDetachedWithARepairedTime() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let url = try store.library.publishFinished(try stage(Data([2, 5])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        let id = try #require(RecordingFiles.storedId(of: url))
        var registry = try #require(suite(store).dictionary(forKey: "recording-library-verified-ids") as? [String: [String: Any]])
        registry[id]?["at"] = NSNumber(value: 0)
        registry[id]?["repaired"] = false
        suite(store).set(registry, forKey: "recording-library-verified-ids")
        context.delete(try #require(try context.fetch(FetchDescriptor<Recording>()).first))
        try context.save()
        let before = Date().epochMilliseconds

        try await store.library.reconcile(context: context)
        try await store.library.reconcile(context: context)

        let detach = try #require(try RecordingFiles.readPendingMoves(for: store.root).detach.first)
        #expect(detach.recordingId == id && detach.at >= before && detach.repaired == true)
    }

    /// T2.31: a Trash file not taken in, with no time in its name or its date, keeps
    /// one first-seen time across listings and a relaunch.
    @Test func aTrashFileWithNoTimeKeepsOneTimeAcrossListingsAndRelaunch() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        // Its id is held by a row with other bytes, so it is not taken in.
        let id = uuid()
        context.insert(Recording(id: id, projectId: "song", displayName: "x.m4a", audio: Data([9]), recordedAt: Date(timeIntervalSince1970: 10)))
        try context.save()
        try await store.library.reconcile(context: context)
        try write(Data([4, 4, 4]), "other", "loose.m4a", root: store.trash, modified: 0)
        func time(_ library: RecordingLibrary, _ context: ModelContext) throws -> Date? {
            try library.trashedRecordings(in: context).first { $0.originalName == "loose.m4a" }?.deletedAt
        }
        let first = try #require(try time(store.library, context))
        try await Task.sleep(for: .milliseconds(20))
        #expect(try time(store.library, context) == first)
        let relaunched = try reopen(store)
        #expect(try time(relaunched.library, relaunched.container.mainContext) == first)
        #expect(first.epochMilliseconds > 0)
    }

    /// T2.34: a song deletion fixes and keeps an unknown recording time in the same
    /// pass (a repair, so the deletion wins, A41), while a newer recorded time stands.
    @Test func aSongDeletionFixesUnknownRecordingTimesInTheSamePass() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let unknown = Recording(projectId: "song", displayName: "old.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 0))
        unknown.uploadedAt = nil
        let newer = Recording(projectId: "song", displayName: "new.m4a", audio: Data([2]), recordedAt: Date(timeIntervalSince1970: 9_000))
        context.insert(unknown)
        context.insert(newer)
        try context.save()
        let unknownId = unknown.id
        let before = Date().epochMilliseconds

        let removed = try store.library.tombstoneRecordings(ofProject: "song", deletedAt: 5_000_000, in: context)
        try context.save()

        #expect(removed.map(\.id) == [unknownId])
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.displayName) == ["new.m4a"])
        let firstSeen = try #require(suite(store).dictionary(forKey: "recording-library-first-seen") as? [String: NSNumber])
        #expect((firstSeen[unknownId]?.int64Value ?? 0) >= before)
        #expect(try context.fetch(FetchDescriptor<SyncRecordingDeletion>()).map(\.recordingId) == [unknownId])
    }

    /// T3.23: a move record that is valid JSON with an invalid field (a relative
    /// path, a bad digest, a negative length or a zero time) stops the run; nothing moves.
    @Test(arguments: ["path", "digest", "bytes", "time"])
    func aMoveRecordWithAnInvalidFieldStopsTheRun(field: String) async throws {
        let store = try await makeStore()
        let file = try write(Data([3]), "song", "\(uuid()).m4a", root: store.root)
        let sha = RecordingBackupManifest.sha256Hex(Data([3]))
        let path = field == "path" ? "song/x.m4a" : RecordingFiles.canonicalPath(file)
        let digest = field == "digest" ? "XYZ" : sha
        let bytes = field == "bytes" ? -1 : 1
        let at = field == "time" ? 0 : 1_700_000_000_000
        let record = #"{"quarantine":[],"detach":[{"recordingId":"\#(uuid())","source":"\#(path)","destination":"\#(store.trash.path)/song/a.m4a","sha256":"\#(digest)","displayName":"a.m4a","at":\#(at),"detachedAt":1700000000000,"bytes":\#(bytes)}],"adopt":[]}"#
        let url = RecordingFiles.quarantineRoot(for: store.root).appendingPathComponent("pending-moves.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(record.utf8).write(to: url)

        await #expect(throws: RecordingLibraryError.journalDamaged) { try await store.library.reconcile(context: store.container.mainContext) }
        #expect(try Data(contentsOf: file) == Data([3]))
        #expect(try Data(contentsOf: url) == Data(record.utf8))
    }

    /// T3.30: a Trash name whose time is not a plausible time is read as no time.
    @Test func implausibleTrashNameTimesAreNoTime() async throws {
        #expect(RecordingFiles.legacyTrashName("99999999999999999999__take.m4a")?.deletedAt.epochMilliseconds == 0)
        #expect(RecordingFiles.legacyTrashName("40000000000000000__take.m4a")?.deletedAt.epochMilliseconds == 0)
        #expect(RecordingFiles.legacyTrashName("-5__take.m4a") == nil)
        #expect(RecordingFiles.legacyTrashName("1e3__take.m4a") == nil)
        #expect(RecordingFiles.legacyTrashName("1700000000000__take.m4a")?.deletedAt.epochMilliseconds == 1_700_000_000_000)
    }

    /// T3.31: a verified-recordings record of the wrong shape is set aside and
    /// reported, and removals wait: a recording removed elsewhere is not moved.
    @Test func aDamagedVerifiedRecordHoldsRemovalsBack() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let url = try store.library.publishFinished(try stage(Data([6, 1])), projectId: "song", preferredName: "take.m4a", origin: .recorded)
        suite(store).set(["not": "entries"], forKey: "recording-library-verified-ids")
        context.delete(try #require(try context.fetch(FetchDescriptor<Recording>()).first))
        try context.save()

        try await store.library.reconcile(context: context)

        #expect(try Data(contentsOf: url) == Data([6, 1]))
        #expect(try RecordingFiles.readPendingMoves(for: store.root).detach.isEmpty)
        #expect(suite(store).object(forKey: "recording-library-verified-ids.damaged") != nil)
        #expect(!store.library.stateIssues.isEmpty)
    }

    /// T3.33: a damaged first-seen record is set aside and reported, never read as empty silently.
    @Test func aDamagedFirstSeenRecordIsSetAsideAndReported() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        suite(store).set("garbage", forKey: "recording-library-first-seen")
        let row = Recording(projectId: "song", displayName: "t.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 0))
        row.uploadedAt = nil
        context.insert(row)
        try context.save()

        try await store.library.reconcile(context: context)

        #expect(suite(store).string(forKey: "recording-library-first-seen.damaged") == "garbage")
        #expect(store.library.stateIssues.contains { $0.contains("recording-library-first-seen") })
        #expect(row.precedenceRepaired && row.precedenceTime.epochMilliseconds > 0)
    }

    /// T3.37: a file an earlier build verified by path, whose row was removed
    /// elsewhere, is that recording: it goes to the Trash under the recorded id.
    @Test func anEarlierVerifiedPathKeepsItsRecordingIdentity() async throws {
        let store = try makeUncheckedStore(onDisk: true)
        let context = store.container.mainContext
        let file = try write(Data([8, 1]), "song", "take.m4a", root: store.root)
        let id = uuid()
        suite(store).set([RecordingFiles.canonicalPath(file): ["id": id, "at": NSNumber(value: 1_700_000_000_000),
                                                               "sha256": RecordingBackupManifest.sha256Hex(Data([8, 1]))]],
                         forKey: "recording-library-verified-paths")

        try await store.library.reconcile(context: context)

        #expect(try store.library.trashedRecordings(in: context).map(\.recordingId) == [id])
        #expect(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(suite(store).object(forKey: "recording-library-verified-paths") == nil)
    }

    /// T3.39: a name adoption an earlier build left waiting is applied to a row not
    /// renamed since, and not to one renamed here.
    @Test func earlierNameAdoptionsApplyOnlyToRowsNotRenamedSince() async throws {
        let store = try makeUncheckedStore(onDisk: true)
        let context = store.container.mainContext
        let plain = Recording(projectId: "song", displayName: "a.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10))
        let renamed = Recording(projectId: "song", displayName: "mine.m4a", audio: Data([2]), recordedAt: Date(timeIntervalSince1970: 10))
        renamed.displayNameChanged = true
        context.insert(plain)
        context.insert(renamed)
        try context.save()
        suite(store).set([plain.id: "Adopted.m4a", renamed.id: "Other.m4a"], forKey: "recording-library-claim-adoptions")

        try await store.library.reconcile(context: context)

        #expect(plain.displayName == "Adopted.m4a" && renamed.displayName == "mine.m4a")
        #expect(suite(store).object(forKey: "recording-library-claim-adoptions") == nil)
    }

    /// T5.5: an oversized take blocked by other bytes at its place, kept separately
    /// from its staged source: the other bytes get an id of their own, the take moves in.
    @Test func keepingABlockedOversizedTakeSeparatelyFinishesIt() async throws {
        let store = try await makeStore()
        let take = Data(repeating: 1, count: Int(SyncRecording.maxBytes) + 1)
        let staged = try stage(take)
        let id = uuid()
        let place = store.root.appendingPathComponent("song/\(id).m4a")
        try FileManager.default.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 9, count: Int(SyncRecording.maxBytes) + 1).write(to: place)
        #expect(throws: (any Error).self) {
            _ = try store.library.publishFinished(staged, projectId: "song", preferredName: "long.m4a", origin: .recorded, id: id, finishedAt: Date(timeIntervalSince1970: 3))
        }

        let target = try store.library.keepSeparately(staged)

        #expect(try target.lastPathComponent == "\(id).m4a" && Data(contentsOf: target).first == 1)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        let ledger = try OversizedRecordings.read(for: store.root)
        #expect(ledger.count == 2 && ledger.values.allSatisfy { $0.completed != false })
    }

    /// T5.7: an id-named file over the cap with no record is taken in under its id,
    /// with its digest and length recorded.
    @Test func anIdNamedOversizedFileWithoutARecordIsTakenIn() async throws {
        let store = try await makeStore()
        let id = uuid()
        let big = Data(repeating: 4, count: Int(SyncRecording.maxBytes) + 1)
        try write(big, "song", "\(id).m4a", root: store.root)

        try await store.library.reconcile(context: store.container.mainContext)

        let entry = try #require(OversizedRecordings.read(for: store.root)[id])
        #expect(entry.sha256 == RecordingBackupManifest.sha256Hex(big) && entry.bytes == Int64(big.count) && entry.completed != false)
        #expect(store.library.oversizedCount == 1)
    }

    /// T5.21: a row whose audio is not its recorded bytes cannot be written out; it
    /// is reported and the row (and its audio) stays.
    @Test func audioThatCannotBeWrittenOutIsReportedAndKept() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        context.insert(Recording(projectId: "song", displayName: "broken.m4a", audio: Data([1]), recordedAt: Date(timeIntervalSince1970: 10),
                                 sha256: RecordingBackupManifest.sha256Hex(Data([2]))))
        try context.save()

        try await store.library.reconcile(context: context)

        #expect(store.library.unmaterialized == ["broken.m4a"])
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.audio) == [Data([1])])
        #expect(names(store.root.appendingPathComponent("song")).isEmpty)
    }

    /// T4.1, T4.2: while a check is suspended in its detached work (here, writing a
    /// row's audio out), every change outside it is refused as busy and changes
    /// nothing, and a second check waits for the first.
    @Test func changesWaitForACheckSuspendedInItsDetachedWork() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let live = try store.library.publishFinished(try stage(Data([5, 5])), projectId: "song", preferredName: "keep.m4a", origin: .recorded)
        context.insert(Recording(projectId: "song", displayName: "row.m4a", audio: Data([8, 8]), recordedAt: Date(timeIntervalSince1970: 10)))
        try context.save()
        let reached = HookBox(false)
        let release = DispatchSemaphore(value: 0)
        let order = HookBox<[String]>([])

        try await withBoundaryHook(scope: store.root.deletingLastPathComponent(), { point, source, _ in
            // The partial-to-staged move runs off the main actor: the check waits here.
            guard point == .beforeCheck, source.deletingLastPathComponent().lastPathComponent == "partial", !reached.value else { return }
            reached.value = true
            release.wait()
        }) {
            let first = Task { @MainActor in
                try await store.library.reconcile(context: context)
                order.value.append("first")
            }
            while !reached.value { try await Task.sleep(for: .milliseconds(5)) }
            #expect(throws: RecordingLibraryError.busy) { _ = try store.library.trashRecording(at: live, trashedAt: Date()) }
            #expect(throws: RecordingLibraryError.busy) { try store.library.renameRecording(at: live, to: "Other") }
            #expect(throws: RecordingLibraryError.busy) {
                _ = try store.library.publishFinished(try stage(Data([1])), projectId: "song", preferredName: "x.m4a", origin: .recorded)
            }
            let second = Task { @MainActor in
                try await store.library.reconcile(context: context)
                order.value.append("second")
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(order.value.isEmpty, "the second check waits")
            release.signal()
            try await first.value
            try await second.value
        }
        #expect(order.value == ["first", "second"])
        #expect(try Data(contentsOf: live) == Data([5, 5]))
        #expect(try context.fetch(FetchDescriptor<Recording>()).map(\.displayName).sorted() == ["keep.m4a", "row.m4a"])
    }

    /// T6.38: an oversized Trash move killed after its rename and before its record
    /// was completed is finished from the record after a relaunch.
    @Test func anOversizedTrashMoveKilledAfterItsRenameIsCompletedAfterARelaunch() async throws {
        let store = try await makeStore()
        let big = Data(repeating: 6, count: Int(SyncRecording.maxBytes) + 1)
        let live = try store.library.publishFinished(try stage(big), projectId: "song", preferredName: "long.m4a", origin: .recorded)
        let id = try #require(RecordingFiles.storedId(of: live))
        try await withBoundaryHook(scope: store.root.deletingLastPathComponent(), { point, source, _ in
            if point == .afterPrimitive, source.lastPathComponent == live.lastPathComponent { throw SimulatedCrash() }
        }) {
            _ = try? store.library.trashRecording(at: live, trashedAt: Date(timeIntervalSince1970: 7))
        }
        let trashPlace = store.trash.appendingPathComponent("song/\(id).m4a")
        #expect(FileManager.default.fileExists(atPath: trashPlace.path))
        #expect(try OversizedRecordings.read(for: store.root)[id]?.completed == false)

        let relaunched = try reopen(store)
        try await relaunched.library.reconcile(context: relaunched.container.mainContext)

        #expect(try OversizedRecordings.read(for: store.root)[id]?.completed == true)
        #expect(try relaunched.library.trashedRecordings(in: relaunched.container.mainContext).map(\.recordingId) == [id])
    }
}

extension RecordingSnapshotCopyTests {
    /// T1.30: copies a killed session made are taken in under the ids recorded for
    /// them, after a relaunch, and are not removed.
    @Test func copiesOfAKilledSessionAreTakenInUnderTheirIds() async throws {
        let (snapshot, root) = try makeSnapshot()
        let scratch = root.deletingLastPathComponent()
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        func open() throws -> (ModelContainer, RecordingLibrary) {
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: scratch.appendingPathComponent("library.store"), cloudKitDatabase: .none)])
            let library = RecordingLibrary(memosRoot: root, trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
                                           defaults: UserDefaults(suiteName: "SnapshotCopy-\(scratch.lastPathComponent)")!)
            library.context = container.mainContext
            return (container, library)
        }
        let (container, library) = try open()
        try await library.reconcile(context: container.mainContext)
        let copies = try snapshot.copy(to: "copy", expecting: library.expectCopies)
        // The session is killed here: no save, no rollback.

        let (reopened, relaunched) = try open()
        try await relaunched.reconcile(context: reopened.mainContext)

        let rows = try reopened.mainContext.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == "copy" }
        #expect(Set(rows.map(\.id)) == Set(copies.map(\.recordingId)))
        #expect(Set(rows.map(\.displayName)) == ["Verse.m4a", "b.m4a"])
        for copy in copies { #expect(FileManager.default.fileExists(atPath: copy.url.path)) }
    }

    /// T3.49: a names record that is present but unreadable is reported, not taken
    /// for absence; the copies carry their file names.
    @Test(arguments: [false, true])
    func anUnreadableNamesRecordIsReported(cannotBeOpened: Bool) async throws {
        let (snapshot, root) = try makeSnapshot()
        let names = OpenRecordingSnapshot.stagingRoot(for: root).appendingPathComponent(snapshot.folderName).appendingPathComponent("names.json")
        if cannotBeOpened {
            // Present, but it cannot be read at all.
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: names.path)
        } else {
            try Data("{not json".utf8).write(to: names)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: names.path) }

        let copies = try snapshot.copy(to: "copy")

        #expect(snapshot.namesDamaged)
        #expect(Set(copies.map(\.displayName)) == ["a.m4a", "b.m4a"])
    }

    /// T3.50: a recovery folder that cannot be listed names every snapshot (nothing is
    /// swept); one that does not exist names none.
    @Test func aRecoveryFolderThatCannotBeListedKeepsEverySnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Recovery-\(UUID().uuidString)", isDirectory: true)
        #expect(EditorViewModel.snapshotNamesNeededByRecovery(in: folder) == [])
        // A file where the folder should be cannot be listed as a folder.
        try Data([0]).write(to: folder)
        #expect(EditorViewModel.snapshotNamesNeededByRecovery(in: folder) == nil)
    }
}

extension RecordingLibraryTests {
    /// T1.11: a staged copy is removed only while it holds the bytes it was staged
    /// with, checked right before the unlink.
    @Test func unstagingKeepsBytesThatChangeRightBeforeTheUnlink() async throws {
        let store = try await makeStore()
        let staged = try RecordingFiles.stageVerified(Data([1, 2]), sha256: RecordingBackupManifest.sha256Hex(Data([1, 2])), recordingId: uuid(),
                                                      storedName: "\(uuid()).m4a", memosRoot: store.root, modifiedAt: Date())
        try await withBoundaryHook(scope: store.root.deletingLastPathComponent(), { point, source, target in
            if point == .beforeCheck, target == nil { try Data([9, 9]).write(to: source) }
        }) {
            RecordingFiles.unstage(staged, sha256: RecordingBackupManifest.sha256Hex(Data([1, 2])), bytes: 2)
        }
        #expect(try Data(contentsOf: staged) == Data([9, 9]))
        RecordingFiles.unstage(staged, sha256: RecordingBackupManifest.sha256Hex(Data([9, 9])), bytes: 2)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    /// A row whose name arrived empty gets a name and keeps its audio.
    @Test func aRowWithAnEmptyNameGetsOne() async throws {
        let store = try await makeStore()
        let context = store.container.mainContext
        let row = Recording(projectId: "song", displayName: "", audio: Data([3]), recordedAt: Date(timeIntervalSince1970: 10))
        context.insert(row)
        try context.save()

        try await store.library.reconcile(context: context)

        #expect(row.displayName == "Recording.m4a")
        #expect(try Data(contentsOf: store.root.appendingPathComponent("song/\(row.id).m4a")) == Data([3]))
    }
}
