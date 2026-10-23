import Foundation
import SwiftData
import Testing
@testable import Writers_Block

/// The `Recording` entity as builds before A36 stored it (T6.8): the file name as
/// `fileName`, the owner's chosen name as `claimedName`, no repair flags, and no
/// upload time on rows from before A20.
enum HistoricalRecordingSchema: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Recording.self] }

    @Model
    final class Recording {
        var id: String = ""
        var projectId: String = ""
        var fileName: String = ""
        var claimedName: String = ""
        var sha256: String = ""
        var bytes: Int64 = 0
        var recordedAt: Date = Date()
        var uploadedAt: Date?
        var origin: String = "recorded"
        var trashedAt: Date?
        @Attribute(.externalStorage) var audio: Data = Data()

        init(id: String, projectId: String, fileName: String, claimedName: String, audio: Data, recordedAt: Date) {
            self.id = id
            self.projectId = projectId
            self.fileName = fileName
            self.claimedName = claimedName
            self.audio = audio
            self.bytes = Int64(audio.count)
            self.sha256 = RecordingBackupManifest.sha256Hex(audio)
            self.recordedAt = recordedAt
        }
    }
}

@MainActor
struct HistoricalStoreTests {
    /// A store written by the historical schema opens under the current one: the
    /// chosen name becomes the display name, the recorded time stays real (A20,
    /// BLOCKER 12), and the audio reaches its `<id>.<ext>` file.
    @Test func aStoreFromBeforeA36OpensWithItsNamesTimesAndAudio() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("HistoricalStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent("library.store")
        let id = UUID().uuidString.lowercased()
        let audio = Data([9, 8, 7])
        do {
            let schema = Schema([HistoricalRecordingSchema.Recording.self])
            let old = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            old.mainContext.insert(HistoricalRecordingSchema.Recording(id: id, projectId: "song", fileName: "take.m4a", claimedName: "Verse idea.m4a",
                                                                       audio: audio, recordedAt: Date(timeIntervalSince1970: 2_000)))
            try old.mainContext.save()
        }

        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        let context = container.mainContext
        let memos = scratch.appendingPathComponent("voice-memos", isDirectory: true)
        let library = RecordingLibrary(memosRoot: memos, trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true),
                                       defaults: UserDefaults(suiteName: "HistoricalStore-\(scratch.lastPathComponent)")!)
        library.context = context
        // An older tombstone does not remove it: its recorded time is real.
        context.insert(SyncRecordingDeletion(projectId: "song", recordingId: id, fileName: "take.m4a", deletedAt: 1_000_000))
        try context.save()

        try await library.reconcile(context: context)

        let row = try #require(try context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.id == id && row.displayName == "Verse idea.m4a" && row.legacyClaimedName.isEmpty)
        #expect(row.uploadedAt == Date(timeIntervalSince1970: 2_000) && !row.precedenceRepaired && !row.trashedAtRepaired)
        #expect(try Data(contentsOf: memos.appendingPathComponent("song/\(id).m4a")) == audio)
    }
}
