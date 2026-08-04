import SwiftUI
import SwiftData
import CloudKit
import Combine
import os

enum CloudSyncStatus: Equatable {
    case syncing
    case available
    case localOnly
    case accountUnavailable
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
            cloudSyncStatus = Self.nonCloudBackedStatus()
            return
        }

        cloudSyncStatus = FileManager.default.ubiquityIdentityToken == nil ? .accountUnavailable : .syncing

        CKContainer(identifier: cloudContainerIdentifier).accountStatus { [weak self] status, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cloudSyncStatus = Self.resolvedStatus(accountStatus: status, error: error)
            }
        }
    }

    private static func nonCloudBackedStatus() -> CloudSyncStatus {
        FileManager.default.ubiquityIdentityToken == nil ? .accountUnavailable : .localOnly
    }

    static func initialCloudSyncStatus(usesCloudBackedStore: Bool) -> CloudSyncStatus {
        guard usesCloudBackedStore else {
            return nonCloudBackedStatus()
        }
        return FileManager.default.ubiquityIdentityToken == nil ? .accountUnavailable : .syncing
    }

    private static func resolvedStatus(accountStatus: CKAccountStatus, error: Error?) -> CloudSyncStatus {
        let hasUbiquityIdentity = FileManager.default.ubiquityIdentityToken != nil
        if error != nil {
            return hasUbiquityIdentity ? .localOnly : .accountUnavailable
        }

        switch accountStatus {
        case .available:
            return hasUbiquityIdentity ? .available : .accountUnavailable
        case .noAccount, .restricted:
            return .accountUnavailable
        case .couldNotDetermine, .temporarilyUnavailable:
            return hasUbiquityIdentity ? .localOnly : .accountUnavailable
        @unknown default:
            return hasUbiquityIdentity ? .localOnly : .accountUnavailable
        }
    }
}

private struct ModelContainerBootstrap {
    let container: ModelContainer?
    let persistenceDegraded: Bool
    let cloudSyncStatus: CloudSyncStatus
    let usesCloudBackedStore: Bool
}

@main
struct Writers_BlockApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearanceStyle.storageKey)
    private var appearanceRawValue = AppAppearanceStyle.ink.rawValue
    @StateObject private var viewModel = EditorViewModel(backupService: BackupService.shared)
    @StateObject private var persistenceState: AppPersistenceState
    @StateObject private var ggufDownloadManager = GGUFDownloadManager()

    private let sharedModelContainer: ModelContainer?

    private var appearance: AppAppearanceStyle {
        AppAppearanceStyle.resolve(appearanceRawValue)
    }

    private var appearanceBinding: Binding<AppAppearanceStyle> {
        Binding(
            get: { appearance },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    init() {
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
            .environment(\.colorScheme, appearance.preferredColorScheme)
            .preferredColorScheme(appearance.preferredColorScheme)
            .tint(appearance.palette.action)
            .safeAreaInset(edge: .top) {
                persistenceDegradedBanner
            }
            .task {
                persistenceState.refreshCloudSyncStatus()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    viewModel.refreshCloudBackupState()
                    persistenceState.refreshCloudSyncStatus()
                case .background:
                    Task {
                        await viewModel.runCloudBackupOnBackgroundIfPossible()
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
        ])
        let logger = Logger(subsystem: "ShaydeTree.Writers-Block", category: "storage")

        if ProcessInfo.processInfo.arguments.contains("--ui-test-in-memory-store") {
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return ModelContainerBootstrap(
                    container: try ModelContainer(for: schema, configurations: [inMemory]),
                    persistenceDegraded: false,
                    cloudSyncStatus: .localOnly,
                    usesCloudBackedStore: false
                )
            } catch {
                logger.error("UI-test in-memory ModelContainer failed: \(error)")
                return ModelContainerBootstrap(
                    container: nil,
                    persistenceDegraded: true,
                    cloudSyncStatus: .localOnly,
                    usesCloudBackedStore: false
                )
            }
        }

        // CloudKit init can fail at runtime (signed-out iCloud, entitlement change,
        // corrupted store). Falling back keeps the app usable instead of crash-looping;
        // a CloudKit-less container still reads/writes the same local store.
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

        let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
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
