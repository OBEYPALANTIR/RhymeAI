import Foundation
import Testing
@testable import Writers_Block

struct GGUFImportTests {
    private func fixture(in directory: URL, count: Int) throws -> URL {
        var data = Data("GGUF".utf8)
        data.append(contentsOf: [3, 0, 0, 0])
        data.append(Data(repeating: 0, count: count - 8))
        let url = directory.appendingPathComponent("source.gguf")
        try data.write(to: url)
        return url
    }

    @Test func oversizedImportPreservesExistingModelAndLeavesNoPartial() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory, count: 40)
        let existing = directory.appendingPathComponent("existing.gguf")
        try Data("keep existing".utf8).write(to: existing)
        #expect(throws: (any Error).self) {
            try GGUFModelCatalog.importCustomFile(at: source, into: directory, maximumBytes: 32, freeSpaceReserve: 0)
        }
        #expect(try Data(contentsOf: existing) == Data("keep existing".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["existing.gguf", "source.gguf"])
    }

    @Test func insufficientSpaceDoesNotStageFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory, count: 24)
        #expect(throws: (any Error).self) {
            try GGUFModelCatalog.importCustomFile(at: source, into: directory, maximumBytes: 32, freeSpaceReserve: Int64.max)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.gguf"])
    }

    @Test func successfulImportCopiesExactBytesIntoUniqueOwnedFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory, count: 32)
        let model = try GGUFModelCatalog.importCustomFile(at: source, into: directory, maximumBytes: 32, freeSpaceReserve: 0)
        #expect(model.fileName != source.lastPathComponent)
        #expect(try Data(contentsOf: directory.appendingPathComponent(model.fileName)) == Data(contentsOf: source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func cancelledImportRemovesOnlyOwnedPartial() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(in: directory, count: 32)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GGUFModelCatalog.importCustomFile(at: source, into: directory, maximumBytes: 32, freeSpaceReserve: 0)
        }
        do { _ = try await task.value; Issue.record("Cancelled import unexpectedly completed") }
        catch is CancellationError { }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.gguf"])
    }
}
