#if os(macOS)
import AppKit
import SwiftData
import Testing
@testable import Writers_Block

@MainActor
struct MacResignActiveSaveTests {
    @Test func resigningActiveCommitsTheQueuedLyricsBeforeTheTimerRuns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try autoreleasepool {
            let schema = Schema([SongProject.self, TrashedSongProject.self])
            let configuration = ModelConfiguration(
                schema: schema,
                url: folder.appendingPathComponent("library.store"),
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            context.autosaveEnabled = false
            let song = SongProject(id: "resign-active-song", title: "Draft", lyrics: "before", theme: "")
            context.insert(song)
            try context.save()

            let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore())
            viewModel.modelContext = context
            defer { viewModel.modelContext = nil }
            viewModel.loadProject(song)
            viewModel.onLyricsChanged("before and after")
            viewModel.triggerAutoSave()

            let descriptor = FetchDescriptor<SongProject>()
            let lyricsBeforeResign = try ModelContext(container).fetch(descriptor).map(\.lyrics)
            #expect(lyricsBeforeResign == ["before"])

            let delegate = MacAppDelegate()
            delegate.viewModel = viewModel
            let lifecycle: any NSApplicationDelegate = delegate
            lifecycle.applicationDidResignActive?(Notification(name: NSApplication.didResignActiveNotification))

            // A fresh context reads the committed row without yielding to the autosave task.
            let lyricsAfterResign = try ModelContext(container).fetch(descriptor).map(\.lyrics)
            #expect(lyricsAfterResign == ["before and after"])
        }
    }
}
#endif
