import Foundation
import Darwin
import SwiftData
import Testing
@testable import Writers_Block

struct LyricsExporterTests {

    @Test func txtExportUsesUntitledFallbackAndPreservesLyrics() throws {
        let project = SongProject(
            title: "",
            lyrics: "  cafe moon\nnaive glow",
            theme: "",
            updatedAt: Date(timeIntervalSince1970: 1_780_374_654)
        )

        let txt = try #require(String(data: LyricsExporter.data(for: project, format: .txt), encoding: .utf8))

        #expect(txt == "Untitled\n\n  cafe moon\nnaive glow")
    }

    @Test func txtExportIncludesThemeWhenPresent() throws {
        let project = SongProject(
            title: "Midnight Notes",
            lyrics: "[Verse]\nquiet road",
            theme: "late-night resolve",
            updatedAt: Date(timeIntervalSince1970: 1_780_374_654)
        )

        let txt = try #require(String(data: LyricsExporter.data(for: project, format: .txt), encoding: .utf8))

        #expect(txt == "Midnight Notes\nTheme: late-night resolve\n\n[Verse]\nquiet road")
    }

    @Test func lrcExportPreservesLeadingWhitespaceAndStripsTrailingWhitespace() throws {
        let project = SongProject(
            title: "Cafe",
            lyrics: "  cafe moon  \n\n[Verse]\n\tnaive glow\t",
            theme: "ignored by lrc",
            updatedAt: Date(timeIntervalSince1970: 1_780_374_654)
        )

        let lrc = try #require(String(data: LyricsExporter.data(for: project, format: .lrc), encoding: .utf8))

        #expect(lrc == """
        [ti:Cafe]
        [ar:Unknown]
        [al:RhymeAI]
        [length:00:00.00]

        [00:00.00]  cafe moon

        [00:00.00][Verse]
        [00:00.00]	naive glow

        """)
    }

    @Test func jsonExportRoundTripsProjectFields() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_780_374_654)
        let project = SongProject(
            id: "song-1",
            title: "Signal",
            lyrics: "line one\nline two",
            theme: "clear signal",
            updatedAt: updatedAt
        )

        let decoded = try LyricsExporter.decodeJsonExport(LyricsExporter.data(for: project, format: .json))

        #expect(decoded.id == "song-1")
        #expect(decoded.title == "Signal")
        #expect(decoded.lyrics == "line one\nline two")
        #expect(decoded.theme == "clear signal")
        #expect(decoded.updatedAt == updatedAt)
    }

    @Test func pdfExportProducesPdfBytes() throws {
        let project = SongProject(
            title: "Long Sheet",
            lyrics: (1...80).map { "line \($0) with enough words to exercise page wrapping" }.joined(separator: "\n"),
            theme: "print check",
            updatedAt: Date(timeIntervalSince1970: 1_780_374_654)
        )

        let pdf = try LyricsExporter.data(for: project, format: .pdf)
        let header = try #require(String(data: pdf.prefix(4), encoding: .utf8))

        #expect(!pdf.isEmpty)
        #expect(header == "%PDF")
    }

    @Test func boundedURLImportAcceptsExactLimitAndRejectsOverflow() async throws {
        let folder = try importTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("project.json")
        var data = try importTestData()
        data.append(Data(repeating: 0x20, count: LyricsExporter.maximumProjectImportBytes - data.count))
        try data.write(to: url)
        let exported = try await LyricsExporter.decodeJsonExport(from: url)
        #expect(exported.title == "Imported test song")
        #expect(exported.lyrics == "Keep this lyric")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(LyricsExporter.maximumProjectImportBytes + 1))
        try handle.close()
        await #expect(throws: LyricsExporter.ImportError.fileTooLarge) {
            try await LyricsExporter.decodeJsonExport(from: url)
        }
    }

    @Test func boundedURLImportRejectsDirectoriesAndFIFOsWithoutReading() async throws {
        let folder = try importTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: LyricsExporter.ImportError.notARegularFile) {
            try await LyricsExporter.decodeJsonExport(from: folder)
        }
        let fifo = folder.appendingPathComponent("pipe.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: LyricsExporter.ImportError.notARegularFile) {
            try await LyricsExporter.decodeJsonExport(from: fifo)
        }
    }

    @Test func boundedURLImportRejectsChangedAndReplacedFiles() async throws {
        let folder = try importTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("project.json")
        var data = try importTestData()
        data.append(Data(repeating: 0x20, count: 128 * 1_024))
        for mutation in ["truncate", "overwrite", "replace", "grow"] {
            try data.write(to: url)
            let expected: LyricsExporter.ImportError = mutation == "grow" ? .fileTooLarge : .fileChanged
            await #expect(throws: expected) {
                try await LyricsExporter.decodeJsonExport(from: url) { count in
                    #expect(!Thread.isMainThread)
                    guard count == 64 * 1_024 else { return }
                    if mutation == "replace" {
                        let replacement = url.appendingPathExtension("replacement")
                        try Data("{}".utf8).write(to: replacement)
                        #expect(rename(replacement.path, url.path) == 0)
                    } else {
                        let handle = try FileHandle(forWritingTo: url)
                        defer { try? handle.close() }
                        switch mutation {
                        case "truncate": try handle.truncate(atOffset: 64 * 1_024)
                        case "grow": try handle.truncate(atOffset: UInt64(LyricsExporter.maximumProjectImportBytes + 1))
                        default:
                            try handle.seek(toOffset: 10)
                            try handle.write(contentsOf: Data("x".utf8))
                        }
                    }
                }
            }
        }
    }

    @Test func boundedURLImportCancellationAndErrorsPreserveCurrentSong() async throws {
        let folder = try importTestFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("project.json")
        try importTestData().write(to: url)
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let original = SongProject(id: "existing-song", title: "Existing song", lyrics: "Unchanged lyric")
        context.insert(original)
        try context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore())
        viewModel.modelContext = context
        viewModel.loadProject(original)
        let started = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            let exported = try await LyricsExporter.decodeJsonExport(from: url) { _ in
                started.continuation.yield(())
                var iterator = resume.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            try Task.checkCancellation()
            return viewModel.importProject(exported)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        resume.continuation.yield(())
        await #expect(throws: CancellationError.self) { try await task.value }
        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LyricsExporter.decodeJsonExport(from: url)
        }
        await #expect(throws: CancellationError.self) { try await alreadyCancelled.value }
        try Data("not JSON".utf8).write(to: url)
        await #expect(throws: DecodingError.self) { try await LyricsExporter.decodeJsonExport(from: url) }
        await #expect(throws: (any Error).self) {
            try await LyricsExporter.decodeJsonExport(from: folder.appendingPathComponent("missing.json"))
        }
        #expect(viewModel.currentProjectId == "existing-song")
        #expect(viewModel.lyrics == "Unchanged lyric")
        #expect(try context.fetchCount(FetchDescriptor<SongProject>()) == 1)
        #expect(original.lyrics == "Unchanged lyric")
        withExtendedLifetime(container) {}
    }

    private func importTestFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func importTestData() throws -> Data {
        try LyricsExporter.data(for: SongProject(id: "import-test", title: "Imported test song", lyrics: "Keep this lyric"), format: .json)
    }
}
