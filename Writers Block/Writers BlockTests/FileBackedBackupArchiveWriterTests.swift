import Foundation
import SwiftData
import Testing
@testable import Writers_Block

// Import and manifest assertions in BackupCoreTests consume the completed ZIP as Data.
extension BackupExportFile {
    var data: Data {
        get throws { try withExtendedLifetime(self) { try Data(contentsOf: url) } }
    }
}

extension BackupCoreTests {
    @MainActor
    @Test func exportChecksActualBodySizeWhenRecordingMetadataFits() async throws {
        let harness = try await makeHarness()
        let budget = BackupArchive.Budget(entryBytes: 8192, totalBytes: 32768)
        harness.context.insert(SongProject(id: "song", title: "Session"))
        let recording = Recording(projectId: "song", displayName: "take.m4a",
                                  audio: Data(repeating: 1, count: budget.entryBytes + 1), recordedAt: Date())
        recording.bytes = 1
        harness.context.insert(recording)
        try harness.context.save()
        #expect(throws: BackupError.exportTooLarge) {
            try harness.service.exportArchive(modelContext: harness.context, budget: budget)
        }
    }

    @MainActor
    @Test func exportStagesRecordingsWithinOneBodyOfWorkingMemory() async throws {
        final class BodyLease: Sendable {}
        let harness = try await makeHarness()
        let project = SongProject(id: "song", title: "Session", lyrics: "words")
        harness.context.insert(project)
        let bodyBudget = 128 * 1024
        for index in 1...3 {
            let audio = Data(repeating: UInt8(index), count: bodyBudget)
            harness.context.insert(Recording(id: "id-\(index)", projectId: project.id, displayName: "take-\(index).m4a",
                                             audio: audio, recordedAt: Date(), sha256: RecordingBackupManifest.sha256Hex(audio)))
        }
        try harness.context.save()

        weak var previousBody: BodyLease?
        var bytesRead = 0
        let export = try harness.service.exportArchive(modelContext: harness.context, budget: .production) { row in
            #expect(previousBody == nil, "Reading another body would exceed the working-memory budget")
            let lease = BodyLease()
            previousBody = lease
            let audio = row.audio
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: audio.count, alignment: 1)
            audio.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: audio.count)
            bytesRead += audio.count
            return Data(bytesNoCopy: buffer, count: audio.count, deallocator: .custom { [lease] pointer, _ in
                withExtendedLifetime(lease) { pointer.deallocate() }
            })
        }
        #expect(bytesRead == 3 * bodyBudget)
        #expect(previousBody == nil)

        let directory = export.url.deletingLastPathComponent()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [export.fileName])
        let written = try Data(contentsOf: export.url)
        // savedAt is assigned during export. Use those exact serialized manifest bytes.
        let manifest = try #require(BackupArchive.unzip(written)["manifest.json"])
        var members = [("manifest.json", manifest),
                       ("songs/Session.txt", try LyricsExporter.data(for: project, format: .txt)),
                       ("songs/song.json", try LyricsExporter.data(for: project, format: .json))]
        for index in 1...3 {
            members.append(("recordings/song/take-\(index).m4a", Data(repeating: UInt8(index), count: bodyBudget)))
        }
        #expect(try BackupArchive.zip(members) == written)
        export.removeTemporaryFiles()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

struct FileBackedBackupArchiveWriterTests {
    private let mebibyte = 1024 * 1024

    @Test func liveExportUsesTheDedicatedTemporaryRoot() throws {
        let export = try BackupExportFile(now: Date())
        try Data([1]).write(to: export.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("writersblock-export", isDirectory: true)
        #expect(export.url.deletingLastPathComponent().deletingLastPathComponent() == root)
        // Access the launch hook's root again while the save sheet owns the file.
        #expect(BackupExportFile.temporaryRoot == root)
        #expect(try export.data == Data([1]))
    }

    @Test func launchRemovesAbandonedExportsAndPreservesOtherTemporaryFolders() throws {
        let temporaryDirectory = try scratch()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let root = temporaryDirectory.appendingPathComponent("writersblock-export", isDirectory: true)
        let abandoned = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data([1]).write(to: abandoned.appendingPathComponent("WritersBlock-backup-2026-11-23.zip"))
        let unrelated = temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)

        #expect(BackupExportFile.prepareTemporaryRoot(in: temporaryDirectory) == root)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func releasingAnExportRemovesOnlyItsOwnDirectory() throws {
        let now = Date()
        let other = try BackupExportFile(now: now)
        let directory: URL
        do {
            let export = try BackupExportFile(now: now)
            directory = export.url.deletingLastPathComponent()
            #expect(export.fileName == other.fileName && export.url != other.url)
            try Data([1]).write(to: export.url)
            try FileManager.default.copyItem(at: export.url, to: other.url)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try other.data == Data([1]))
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zip-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Members whose bodies differ from each other at every size.
    private func makeMembers(_ sizes: [Int]) -> [(path: String, data: Data)] {
        sizes.enumerated().map { index, size in
            ("recordings/song/take-\(index).m4a", Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* (2 * index + 1) &+ 7 * index) }))
        }
    }

    private func files(_ members: [(path: String, data: Data)], in directory: URL) throws -> [(path: String, source: URL)] {
        try members.enumerated().map { index, member in
            let url = directory.appendingPathComponent("source-\(index).bin")
            try member.data.write(to: url)
            return (member.path, url)
        }
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test func fileWriterMatchesTheDataWriterByteForByteAndReadsBack() async throws {
        let sources = try scratch(), output = try scratch()
        defer { try? FileManager.default.removeItem(at: sources); try? FileManager.default.removeItem(at: output) }
        let members = makeMembers([mebibyte, 3, 0, 70_000]) + [("songs/Ünïcode name.txt", Data("words".utf8))]
        let destination = output.appendingPathComponent("backup.zip")

        try BackupArchive.zip(try files(members, in: sources), to: destination)

        let written = try Data(contentsOf: destination)
        #expect(written == (try BackupArchive.zip(members)))
        let read = try BackupArchive.unzip(written)
        #expect(read.count == members.count)
        for member in members { #expect(read[member.path] == member.data) }
        #expect(try contents(of: output) == ["backup.zip"])

        // A second run publishes over the existing archive.
        let fewer = Array(members.prefix(2))
        try BackupArchive.zip(try files(fewer, in: sources), to: destination)
        #expect(try Data(contentsOf: destination) == (try BackupArchive.zip(fewer)))
        #expect(try contents(of: output) == ["backup.zip"])
    }

    @Test func fileWriterAcceptsTheExactBudgetAndRefusesOneByteOverWithoutAFile() async throws {
        let sources = try scratch(), output = try scratch()
        defer { try? FileManager.default.removeItem(at: sources); try? FileManager.default.removeItem(at: output) }
        let budget = BackupArchive.Budget(entryBytes: 8 * 1024, totalBytes: 24 * 1024)
        let fresh = output.appendingPathComponent("fresh.zip")
        let existing = output.appendingPathComponent("existing.zip")
        try Data("previous".utf8).write(to: existing)

        let overEntry = try files(makeMembers([8 * 1024 + 1]), in: sources)
        #expect(throws: BackupArchiveError.tooLarge) { try BackupArchive.zip(overEntry, to: fresh, budget: budget) }
        let overTotal = try files(makeMembers([8 * 1024, 8 * 1024, 8 * 1024, 1]), in: sources)
        #expect(throws: BackupArchiveError.tooLarge) { try BackupArchive.zip(overTotal, to: fresh, budget: budget) }
        #expect(throws: BackupArchiveError.tooLarge) { try BackupArchive.zip(overTotal, to: existing, budget: budget) }
        #expect(try contents(of: output) == ["existing.zip"])
        #expect(try Data(contentsOf: existing) == Data("previous".utf8))

        let exact = Array(overTotal.prefix(3))
        try BackupArchive.zip(exact, to: fresh, budget: budget)
        #expect(try BackupArchive.unzip(try Data(contentsOf: fresh), budget: budget).count == 3)
    }

    @Test func failureMidwayLeavesNoPartialArchiveAndNoTemporaryFile() async throws {
        let sources = try scratch(), output = try scratch()
        defer { try? FileManager.default.removeItem(at: sources); try? FileManager.default.removeItem(at: output) }
        let entries = try files(makeMembers([mebibyte, mebibyte, mebibyte, mebibyte]), in: sources)
        let fresh = output.appendingPathComponent("fresh.zip")
        let existing = output.appendingPathComponent("existing.zip")
        try Data("previous".utf8).write(to: existing)

        // The third source cannot be opened, after two members are already written.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: entries[2].source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: entries[2].source.path) }
        #expect(throws: (any Error).self) { try BackupArchive.zip(entries, to: fresh) }
        #expect(throws: (any Error).self) { try BackupArchive.zip(entries, to: existing) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: entries[2].source.path)

        // A read failing partway through the third member.
        struct Injected: Error {}
        var bytesRead = 0
        #expect(throws: Injected.self) {
            try BackupArchive.zip(entries, to: existing) { handle, count in
                if bytesRead >= 2 * mebibyte + BackupArchive.chunkBytes { throw Injected() }
                let chunk = try handle.read(upToCount: count)
                bytesRead += chunk?.count ?? 0
                return chunk
            }
        }
        #expect(bytesRead == 2 * mebibyte + BackupArchive.chunkBytes)

        #expect(try contents(of: output) == ["existing.zip"])
        #expect(try Data(contentsOf: existing) == Data("previous".utf8))
    }

    @Test func fileWriterNeverReadsAWholeMemberAtOnce() async throws {
        let sources = try scratch(), output = try scratch()
        defer { try? FileManager.default.removeItem(at: sources); try? FileManager.default.removeItem(at: output) }
        let members = makeMembers([mebibyte, mebibyte, mebibyte, mebibyte])
        let destination = output.appendingPathComponent("backup.zip")
        // The Data writer holds every body and the whole archive at once.
        #expect((try BackupArchive.zip(members)).count > 4 * mebibyte)

        var largest = 0, total = 0
        try BackupArchive.zip(try files(members, in: sources), to: destination) { handle, count in
            let chunk = try handle.read(upToCount: count)
            largest = max(largest, chunk?.count ?? 0)
            total += chunk?.count ?? 0
            return chunk
        }

        #expect(largest > 0 && largest <= BackupArchive.chunkBytes && largest < mebibyte)
        #expect(total == 4 * mebibyte)
        let read = try BackupArchive.unzip(try Data(contentsOf: destination))
        for member in members { #expect(read[member.path] == member.data) }
    }

    @Test func aNameTooLongForTheZipFieldIsRefusedInsteadOfTrapping() async throws {
        let sources = try scratch(), output = try scratch()
        defer { try? FileManager.default.removeItem(at: sources); try? FileManager.default.removeItem(at: output) }
        let empty = sources.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        let destination = output.appendingPathComponent("backup.zip")
        let tooLong = String(repeating: "n", count: Int(UInt16.max) + 1)

        #expect(throws: BackupArchiveError.tooLarge) { try BackupArchive.zip([(tooLong, Data())]) }
        #expect(throws: BackupArchiveError.tooLarge) { try BackupArchive.zip([(tooLong, empty)], to: destination) }
        #expect(try contents(of: output) == [])

        // The longest name the field can hold is still written, the same by both writers.
        let longest = String(repeating: "n", count: Int(UInt16.max))
        try BackupArchive.zip([(longest, empty)], to: destination)
        #expect(try Data(contentsOf: destination) == (try BackupArchive.zip([(longest, Data())])))
    }

    @Test func aDestinationThatCannotBeReplacedIsLeftInPlace() async throws {
        let sources = try scratch(), output = try scratch()
        defer { try? FileManager.default.removeItem(at: sources); try? FileManager.default.removeItem(at: output) }
        let entries = try files(makeMembers([3]), in: sources)
        // A locked archive: replacing it is refused at publication, after the temporary file is complete.
        let locked = output.appendingPathComponent("locked.zip")
        try Data("previous".utf8).write(to: locked)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        // A folder with content where the archive would go.
        let folder = output.appendingPathComponent("folder.zip", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("inside.txt"))

        #expect(throws: (any Error).self) { try BackupArchive.zip(entries, to: locked) }
        #expect(throws: (any Error).self) { try BackupArchive.zip(entries, to: folder) }

        #expect(try contents(of: output) == ["folder.zip", "locked.zip"])
        #expect(try Data(contentsOf: locked) == Data("previous".utf8))
        #expect(try Data(contentsOf: folder.appendingPathComponent("inside.txt")) == Data("keep".utf8))
    }

    @Test func theLongestValidDestinationNameIsWritten() async throws {
        let sources = try scratch(), output = try scratch()
        defer { try? FileManager.default.removeItem(at: sources); try? FileManager.default.removeItem(at: output) }
        let members = makeMembers([3])
        // 255 bytes, the longest file name the volume accepts.
        let destination = output.appendingPathComponent(String(repeating: "a", count: 251) + ".zip")

        try BackupArchive.zip(try files(members, in: sources), to: destination)

        #expect(try Data(contentsOf: destination) == (try BackupArchive.zip(members)))
        #expect(try contents(of: output) == [destination.lastPathComponent])
    }
}
