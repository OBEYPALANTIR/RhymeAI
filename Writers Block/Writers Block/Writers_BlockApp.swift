import SwiftUI
import SwiftData
import os

@main
struct Writers_BlockApp: App {
    @StateObject private var viewModel = EditorViewModel()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SongProject.self,
            TrashedSongProject.self,
        ])
        if ProcessInfo.processInfo.arguments.contains("--ui-test-in-memory-store") {
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return try ModelContainer(for: schema, configurations: [inMemory])
            } catch {
                fatalError("Could not create UI-test ModelContainer: \(error)")
            }
        }

        let logger = Logger(subsystem: "ShaydeTree.Writers-Block", category: "storage")

        // CloudKit init can fail at runtime (signed-out iCloud, entitlement change,
        // corrupted store). Falling back keeps the app usable instead of crash-looping;
        // a CloudKit-less container still reads/writes the same local store.
        let cloudKit = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private("iCloud.ShaydeTree.Writers-Block")
        )
        do {
            return try ModelContainer(for: schema, configurations: [cloudKit])
        } catch {
            logger.error("CloudKit ModelContainer failed, falling back to local-only: \(error)")
        }

        let localOnly = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [localOnly])
        } catch {
            logger.error("Local ModelContainer failed, falling back to in-memory: \(error)")
        }

        let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [inMemory])
        } catch {
            fatalError("Could not create any ModelContainer: \(error)")
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
