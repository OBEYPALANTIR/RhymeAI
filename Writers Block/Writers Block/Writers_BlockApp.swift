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
        let modelConfiguration: ModelConfiguration
        if isUITestInMemoryStore {
            modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.ShaydeTree.Writers-Block")
            )
        }

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
