#if DEBUG
import CloudKit
import CoreData
import Foundation
import SwiftData
import os

/// Creates every record type in the CloudKit Development schema at once.
/// SwiftData mirroring only creates a record type when the first record of
/// that type is pushed, so the Development schema stays incomplete until a
/// Debug build on a device signed into iCloud launches with
/// `--initialize-cloudkit-schema`. Deploy Development to Production in
/// CloudKit Console afterwards. Uses a throwaway store; the real one is untouched.
enum CloudKitSchemaInitializer {
    static let launchArgument = "--initialize-cloudkit-schema"
    static let containerIdentifier = "iCloud.ShaydeTree.Writers-Block"

    /// Must match the `Schema` in `Writers_BlockApp.makeModelContainer()`.
    static let modelTypes: [any PersistentModel.Type] = [
        SongProject.self,
        TrashedSongProject.self,
        SyncDeletionRecord.self,
        SyncRecordingDeletion.self,
        Recording.self,
    ]

    static func makeManagedObjectModel() -> NSManagedObjectModel? {
        NSManagedObjectModel.makeManagedObjectModel(for: modelTypes)
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        let logger = Logger(subsystem: "ShaydeTree.Writers-Block", category: "storage")
        do {
            try initializeSchema()
            logger.notice("CloudKit schema initialized for \(containerIdentifier, privacy: .public)")
            print("CLOUDKIT_SCHEMA_INIT: ok")
        } catch {
            logger.error("CloudKit schema initialization failed: \(error)")
            // NSError descriptions span lines; keep the stdout marker greppable.
            let oneLine = String(describing: error).split(whereSeparator: \.isNewline).joined(separator: " ")
            print("CLOUDKIT_SCHEMA_INIT: failed \(oneLine)")
        }
    }

    private struct ModelUnavailable: Error, CustomStringConvertible {
        var description: String { "NSManagedObjectModel could not be built from the SwiftData models" }
    }

    private struct CleanupFailed: Error, CustomStringConvertible {
        let initialization: Result<Void, Error>
        let cleanup: Error
        let leftover: URL
        var description: String {
            let outcome = switch initialization {
            case .success: "initialization ok"
            case .failure(let error): "initialization failed: \(error)"
            }
            return "\(outcome); temporary store cleanup failed: \(cleanup); leftover at \(leftover.path)"
        }
    }

    private static func initializeSchema() throws {
        guard let model = makeManagedObjectModel() else { throw ModelUnavailable() }
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudKitSchemaInit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let container = NSPersistentCloudKitContainer(name: "SchemaInit", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeDirectory.appendingPathComponent("SchemaInit.sqlite"))
        let options = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
        options.databaseScope = .private
        description.cloudKitContainerOptions = options
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        let initialization = Result {
            if let loadError { throw loadError }
            try container.initializeCloudKitSchema(options: [])
        }

        // Detach before deleting so the coordinator has released the SQLite files
        // (including -wal/-shm). A cleanup failure is reported, never hidden, and
        // the initialization outcome travels with it.
        do {
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try coordinator.remove(store)
            }
            try FileManager.default.removeItem(at: storeDirectory)
        } catch {
            throw CleanupFailed(initialization: initialization, cleanup: error, leftover: storeDirectory)
        }
        try initialization.get()
    }
}
#endif
