import Foundation
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
}
