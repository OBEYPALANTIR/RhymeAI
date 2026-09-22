import Foundation
import SwiftData
import Testing
@testable import Writers_Block

struct WritingCompanionTests {
    @MainActor @Test func emptyLegacySongAndAtomicReadback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WritingCompanionStore(directory: directory)
        #expect(try store.read("legacy") == WritingCompanion())
        var state = WritingCompanion()
        state.keep("  another line  ")
        state.position = WritingPosition(location: 3, length: 2, scrollY: 340)
        state.checkpoint(title: "A", lyrics: "old lyric", theme: "night", force: true)
        try store.write(state, for: "song/with/path")
        #expect(try WritingCompanionStore(directory: directory).read("song/with/path") == state)
        try store.remove("song/with/path")
        #expect(try store.read("song/with/path") == WritingCompanion())
    }

    @Test func alternatesTrimDeduplicateAndBoundRetention() {
        var state = WritingCompanion()
        state.keep("  line  ")
        state.keep("line")
        state.keep(" \n ")
        #expect(state.alternates.map(\.text) == ["line"])
        for index in 0..<60 { state.keep("alternate \(index)") }
        #expect(state.alternates.count == 50)
        #expect(state.alternates.first?.text == "alternate 59")
    }

    @Test func versionsRespectIntervalDeduplicationAndBound() {
        var state = WritingCompanion()
        let date = Date(timeIntervalSince1970: 500)
        state.checkpoint(title: "A", lyrics: "first", theme: "", now: date)
        state.checkpoint(title: "A", lyrics: "second", theme: "", now: date.addingTimeInterval(299))
        #expect(state.versions.count == 1)
        state.checkpoint(title: "A", lyrics: "second", theme: "", now: date.addingTimeInterval(300))
        state.checkpoint(title: "A", lyrics: "first", theme: "", force: true)
        #expect(state.versions.count == 2)
        for index in 0..<25 { state.checkpoint(title: "A", lyrics: "version \(index)", theme: "", force: true) }
        #expect(state.versions.count == 20)
    }

    @Test func previewSkipsHeadersAndPositionUsesUTF16() {
        #expect(WritingCompanion.lyricPreview("\n[Verse 1]\n\n  First lyric\nsecond") == "First lyric")
        #expect(WritingCompanion.lyricPreview("[Chorus]\n\n") == nil)
        #expect(WritingPosition(location: 3, length: 20, scrollY: -4).clamped(to: "🌙abc") == WritingPosition(location: 3, length: 2, scrollY: 0))
        #expect(WritingPosition(location: -1, length: -1, scrollY: .infinity).clamped(to: "abc") == WritingPosition())
    }

    @MainActor @Test func missingProjectStopsSwitch() throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let model = EditorViewModel(keychainStore: InMemoryKeychainStore(), companionStore: WritingCompanionStore(inMemory: true))
        model.modelContext = context
        model.newProject()
        model.lyrics = "Keep this draft"
        model.currentProjectId = "missing"
        model.newProject()
        #expect(model.lyrics == "Keep this draft")
        #expect(model.currentProjectId == "missing")
        #expect(model.companionError != nil)
    }

    @MainActor @Test func switchingFlushesDraftRestoresPositionAndVersions() throws {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = WritingCompanionStore(inMemory: true)
        let model = EditorViewModel(keychainStore: InMemoryKeychainStore(), companionStore: store)
        model.modelContext = context
        model.newProject()
        model.title = "First"
        model.lyrics = "🌙 first draft"
        model.selectedRange = NSRange(location: 3, length: 5)
        model.editorScrollY = 420
        model.triggerAutoSave()
        model.newProject()
        let first = try #require(context.fetch(FetchDescriptor<SongProject>()).first)
        #expect(first.lyrics == "🌙 first draft")
        model.loadProject(first)
        #expect(model.selectedRange == NSRange(location: 3, length: 5))
        #expect(model.editorScrollY == 420)
        let version = try #require(model.companion.versions.first)
        model.lyrics = "new draft"
        model.restoreVersion(version)
        #expect(model.lyrics == "🌙 first draft")
        #expect(model.companion.versions.contains { $0.lyrics == "new draft" })
        let updated = first.updatedAt
        model.selectedRange = NSRange(location: 0, length: 0)
        model.flushCurrentDraft()
        #expect(first.updatedAt == updated)
        model.lyrics = "unsaved trash draft"
        model.moveProjectToTrash(first)
        #expect(try store.read(first.id).versions.count >= 2)
        let trashed = try #require(context.fetch(FetchDescriptor<TrashedSongProject>()).first)
        #expect(trashed.lyrics == "unsaved trash draft")
        model.permanentlyDeleteTrashedProject(trashed)
        #expect(try store.read(first.id) == WritingCompanion())
        model.newProject()
        model.keepAlternate("An idea before the song")
        #expect(model.currentProjectId != nil)
        #expect(model.companion.alternates.first?.text == "An idea before the song")
        model.title = "Title only"
        model.flushCurrentDraft(checkpoint: true)
        #expect(model.companion.versions.first?.title == "Title only")
    }
}
