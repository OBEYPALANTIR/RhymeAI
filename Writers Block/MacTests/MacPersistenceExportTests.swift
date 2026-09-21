import Foundation
import SwiftData
import PDFKit
import Testing
@testable import Writers_Block

@MainActor
struct MacPersistenceExportTests {
    @Test func saveFlushSurvivesImmediateProjectSwitch() throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let editor = EditorViewModel()
        editor.modelContext = container.mainContext
        editor.newProject()
        editor.title = "Immediate save"
        editor.onLyricsChanged("Moon 🌙\nA second line")
        editor.triggerAutoSave()
        #expect(editor.saveCurrentProject())
        editor.newProject()
        let saved = try container.mainContext.fetch(FetchDescriptor<SongProject>())
        #expect(saved.count == 1)
        #expect(saved.first?.lyrics == "Moon 🌙\nA second line")
    }

    @Test func pdfPaginatesUnicodeAndLongLyrics() throws {
        let lyrics = (0..<160).map { "Line \($0): Café in the moonlight" }.joined(separator: "\n")
        let data = try LyricsExporter.data(for: SongProject(title: "Night Song", lyrics: lyrics), format: .pdf)
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 1)
        #expect(pdf.string?.contains("Line 159") == true)
        #expect(pdf.string?.contains("Night Song") == true)
    }
}
