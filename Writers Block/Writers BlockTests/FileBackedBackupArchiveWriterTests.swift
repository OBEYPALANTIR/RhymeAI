import Foundation
import Testing
@testable import Writers_Block

struct FileBackedBackupArchiveWriterTests {
    private let mebibyte = 1024 * 1024

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
