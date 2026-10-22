import SwiftUI
import UIKit
import SwiftData
import CloudKit
import Combine
import os

/// iCloud sync for the library, with the reason when it is off.
enum CloudSyncStatus: Equatable {
    case checking
    case on
    case noAccount
    case restricted
    /// The iCloud store could not be opened, so the library is local only.
    case localOnlyFallback
    case temporarilyUnavailable
}

final class AppPersistenceState: ObservableObject {
    @Published var persistenceDegraded: Bool
    @Published var cloudSyncStatus: CloudSyncStatus

    private let usesCloudBackedStore: Bool
    private let cloudContainerIdentifier = "iCloud.ShaydeTree.Writers-Block"

    init(
        persistenceDegraded: Bool,
        cloudSyncStatus: CloudSyncStatus,
        usesCloudBackedStore: Bool
    ) {
        self.persistenceDegraded = persistenceDegraded
        self.cloudSyncStatus = cloudSyncStatus
        self.usesCloudBackedStore = usesCloudBackedStore
    }

    func refreshCloudSyncStatus() {
        guard usesCloudBackedStore else {
            cloudSyncStatus = .localOnlyFallback
            return
        }

        cloudSyncStatus = FileManager.default.ubiquityIdentityToken == nil ? .noAccount : .checking

        CKContainer(identifier: cloudContainerIdentifier).accountStatus { [weak self] status, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cloudSyncStatus = Self.resolvedStatus(accountStatus: status, error: error)
            }
        }
    }

    static func initialCloudSyncStatus(usesCloudBackedStore: Bool) -> CloudSyncStatus {
        guard usesCloudBackedStore else { return .localOnlyFallback }
        return FileManager.default.ubiquityIdentityToken == nil ? .noAccount : .checking
    }

    static func resolvedStatus(accountStatus: CKAccountStatus, error: Error?) -> CloudSyncStatus {
        if error != nil { return .temporarilyUnavailable }
        switch accountStatus {
        case .available: return .on
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .couldNotDetermine, .temporarilyUnavailable: return .temporarilyUnavailable
        @unknown default: return .temporarilyUnavailable
        }
    }
}

private struct ModelContainerBootstrap {
    let container: ModelContainer?
    let persistenceDegraded: Bool
    let cloudSyncStatus: CloudSyncStatus
    let usesCloudBackedStore: Bool
}


final class ModelDownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == GGUFDownloadManager.backgroundIdentifier else {
            completionHandler()
            return
        }
        GGUFDownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct Writers_BlockApp: App {
    @UIApplicationDelegateAdaptor(ModelDownloadAppDelegate.self) private var downloadDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearanceStyle.storageKey)
    private var appearanceRawValue = AppAppearanceStyle.ink.rawValue
    @StateObject private var viewModel = EditorViewModel(
        backupService: BackupService.shared,
        defaults: UITestFlags.editorDefaults()
    )
    @StateObject private var persistenceState: AppPersistenceState
    @StateObject private var ggufDownloadManager = GGUFDownloadManager.shared

    private let sharedModelContainer: ModelContainer?

    private var appearance: AppAppearanceStyle {
        AppAppearanceStyle.resolve(appearanceRawValue)
    }

    private var appearanceBinding: Binding<AppAppearanceStyle> {
        Binding(
            get: { appearance },
            set: { newAppearance in
                guard newAppearance != appearance else { return }
                appearanceRawValue = newAppearance.rawValue
            }
        )
    }

    init() {
        RetiredPreferences.remove()
        let bootstrap = Self.makeModelContainer()
        _persistenceState = StateObject(
            wrappedValue: AppPersistenceState(
                persistenceDegraded: bootstrap.persistenceDegraded,
                cloudSyncStatus: bootstrap.cloudSyncStatus,
                usesCloudBackedStore: bootstrap.usesCloudBackedStore
            )
        )
        sharedModelContainer = bootstrap.container
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let sharedModelContainer {
                    ContentView()
                        .modelContainer(sharedModelContainer)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(appearance.palette.warning)
                        Text("Your library couldn't be opened; changes won't be saved this session.")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(appearance.palette.primaryInk)
                    .background(appearance.palette.canvas)
                }
            }
            .environmentObject(viewModel)
            .environmentObject(persistenceState)
            .environmentObject(ggufDownloadManager)
            .environment(\.appAppearanceStyle, appearance)
            .environment(\.appAppearanceBinding, appearanceBinding)
            .preferredColorScheme(appearance.preferredColorScheme)
            .tint(appearance.palette.action)
            .modifier(UITestDynamicTypeSizeModifier())
            .safeAreaInset(edge: .top) {
                persistenceDegradedBanner
            }
            .task {
                UITestFlags.seedCustomGGUFModelIfRequested()
                persistenceState.refreshCloudSyncStatus()
            }
            .task {
                // After the first frames, so launch is not competing with it.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await RhymeIndex.warmUpInBackground()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    viewModel.refreshCloudBackupState()
                    persistenceState.refreshCloudSyncStatus()
                case .background:
                    // Back up now rather than at the end of a pending countdown.
                    // Ask for run time past the move to the background so the backup
                    // can finish and reconcile the open draft instead of being
                    // suspended part-way. The system may still end it early.
                    let assertion = BackgroundTaskAssertion(name: "Cloud backup")
                    Task {
                        await viewModel.runCloudBackupOnBackgroundIfPossible()
                        assertion.end()
                    }
                default:
                    break
                }
            }
        }
    }

    @ViewBuilder
    private var persistenceDegradedBanner: some View {
        if persistenceState.persistenceDegraded {
            Label(
                "Your library couldn't be opened; changes won't be saved this session.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(appearance.palette.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(appearance.palette.primaryInk)
            .background(appearance.palette.surface)
        }
    }

    private static func makeModelContainer() -> ModelContainerBootstrap {
        let schema = Schema([
            SongProject.self,
            TrashedSongProject.self,
            SyncDeletionRecord.self,
            Recording.self,
        ])
        let logger = Logger(subsystem: "ShaydeTree.Writers-Block", category: "storage")

        let isHostedUnitTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if ProcessInfo.processInfo.arguments.contains("--ui-test-in-memory-store") || isHostedUnitTest {
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            do {
                return ModelContainerBootstrap(
                    container: try ModelContainer(for: schema, configurations: [inMemory]),
                    persistenceDegraded: false,
                    cloudSyncStatus: .localOnlyFallback,
                    usesCloudBackedStore: false
                )
            } catch {
                logger.error("UI-test in-memory ModelContainer failed: \(error)")
                return ModelContainerBootstrap(
                    container: nil,
                    persistenceDegraded: true,
                    cloudSyncStatus: .localOnlyFallback,
                    usesCloudBackedStore: false
                )
            }
        }

        // CloudKit init can fail at runtime (signed-out iCloud, entitlement change,
        // corrupted store). Falling back keeps the app usable instead of crash-looping;
        // a CloudKit-less container still reads/writes the same local store.
        // The unsigned persistent UI-test bundle cannot initialize CloudKit's
        // asynchronous store setup. Keep its relaunch test local to its own app data.
        if !ProcessInfo.processInfo.arguments.contains("--ui-test-local-store") {
            let cloudKit = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.ShaydeTree.Writers-Block")
            )
            do {
                return ModelContainerBootstrap(
                    container: try ModelContainer(for: schema, configurations: [cloudKit]),
                    persistenceDegraded: false,
                    cloudSyncStatus: AppPersistenceState.initialCloudSyncStatus(usesCloudBackedStore: true),
                    usesCloudBackedStore: true
                )
            } catch {
                logger.error("CloudKit ModelContainer failed, falling back to local-only: \(error)")
            }
        }

        let localOnly = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        do {
            return ModelContainerBootstrap(
                container: try ModelContainer(for: schema, configurations: [localOnly]),
                persistenceDegraded: false,
                cloudSyncStatus: AppPersistenceState.initialCloudSyncStatus(usesCloudBackedStore: false),
                usesCloudBackedStore: false
            )
        } catch {
            logger.error("Local ModelContainer failed, falling back to in-memory: \(error)")
        }

        let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        do {
            return ModelContainerBootstrap(
                container: try ModelContainer(for: schema, configurations: [inMemory]),
                persistenceDegraded: true,
                cloudSyncStatus: AppPersistenceState.initialCloudSyncStatus(usesCloudBackedStore: false),
                usesCloudBackedStore: false
            )
        } catch {
            logger.error("In-memory ModelContainer failed; showing degraded launch screen: \(error)")
            return ModelContainerBootstrap(
                container: nil,
                persistenceDegraded: true,
                cloudSyncStatus: AppPersistenceState.initialCloudSyncStatus(usesCloudBackedStore: false),
                usesCloudBackedStore: false
            )
        }
    }
}

private struct UITestDynamicTypeSizeModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if UITestFlags.isEnabled(UITestFlags.accessibilityTextSize) {
            content.environment(\.dynamicTypeSize, .accessibility3)
        } else {
            content
        }
    }
}

@MainActor
private final class BackgroundTaskAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
