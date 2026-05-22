import SwiftUI
import SwiftData

@main
struct Writers_BlockApp: App {
    @StateObject private var viewModel = EditorViewModel()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SongProject.self,
            TrashedSongProject.self,
        ])
        let isUITestInMemoryStore = ProcessInfo.processInfo.arguments.contains("--ui-test-in-memory-store")
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isUITestInMemoryStore)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
        .modelContainer(sharedModelContainer)
    }
}
