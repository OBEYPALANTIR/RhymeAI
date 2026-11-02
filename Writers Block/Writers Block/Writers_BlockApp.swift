import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import SwiftData
import CloudKit
import CoreData
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


#if canImport(UIKit)
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
#endif

@main
struct Writers_BlockApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(ModelDownloadAppDelegate.self) private var downloadDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearanceStyle.storageKey)
    private var appearanceRawValue = AppAppearanceStyle.ink.rawValue
    @StateObject private var viewModel = EditorViewModel(
        backupService: BackupService.shared,
        recordingLibrary: BackupService.shared.library,
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
        #if DEBUG
        CloudKitSchemaInitializer.runIfRequested()
        #endif
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

    static let editorWindowID = "editor"

    var body: some Scene {
        WindowGroup(id: Self.editorWindowID) {
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
            .modifier(appEnvironment)
            .safeAreaInset(edge: .top) {
                persistenceDegradedBanner
            }
            .task {
                UITestFlags.seedCustomGGUFModelIfRequested()
                UITestFlags.seedInstalledGGUFModelIfRequested()
                persistenceState.refreshCloudSyncStatus()
            }
            .task {
                // After the first frames, so launch is not competing with it.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await RhymeIndex.warmUpInBackground()
            }
            // iCloud delivered changes: new or removed recordings get their files.
            .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange).receive(on: RunLoop.main)) { _ in
                Task { await viewModel.reconcileRecordings() }
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
        #if os(macOS)
        .defaultSize(width: 1160, height: 780)
        .commands { MacAppCommands(viewModel: viewModel) }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .frame(minWidth: RhymeAITokens.Layout.assistantReadableWidth, idealWidth: 520, minHeight: 560)
                .modifier(appEnvironment)
        }
        #endif
    }

    /// The objects and appearance every scene's root view reads.
    private var appEnvironment: AppEnvironmentModifier {
        AppEnvironmentModifier(
            viewModel: viewModel,
            persistenceState: persistenceState,
            ggufDownloadManager: ggufDownloadManager,
            appearance: appearance,
            appearanceBinding: appearanceBinding
        )
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
            SyncRecordingDeletion.self,
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
        if !ProcessInfo.processInfo.arguments.contains("--ui-test-local-store"), hasCloudKitEntitlement {
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

extension Writers_BlockApp {
    /// A Mac build signed without a provisioning profile (a local run) has no
    /// iCloud entitlement, and CloudKit then traps instead of throwing, so the
    /// library opens local-only. iOS always carries the entitlement.
    fileprivate static var hasCloudKitEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        return (services as? [String])?.contains("CloudKit") == true
        #else
        return true
        #endif
    }
}

private struct AppEnvironmentModifier: ViewModifier {
    let viewModel: EditorViewModel
    let persistenceState: AppPersistenceState
    let ggufDownloadManager: GGUFDownloadManager
    let appearance: AppAppearanceStyle
    let appearanceBinding: Binding<AppAppearanceStyle>

    func body(content: Content) -> some View {
        content
            .environmentObject(viewModel)
            .environmentObject(persistenceState)
            .environmentObject(ggufDownloadManager)
            .environment(\.appAppearanceStyle, appearance)
            .environment(\.appAppearanceBinding, appearanceBinding)
            .preferredColorScheme(appearance.preferredColorScheme)
            .tint(appearance.palette.action)
            .modifier(UITestDynamicTypeSizeModifier())
    }
}

#if os(macOS)
/// Menu bar commands for the Mac app, on the same view model actions the
/// editor's buttons use.
private struct MacAppCommands: Commands {
    @ObservedObject var viewModel: EditorViewModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.unblockAction) private var unblockAction

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Song") {
                showEditorWindow()
                viewModel.newProject()
            }
            .keyboardShortcut("n")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { viewModel.flushCurrentDraft(checkpoint: true) }
                .keyboardShortcut("s")
        }
        CommandMenu("Song") {
            Button("UnBlock") { unblockAction?.perform() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(unblockAction == nil || viewModel.lyrics.isEmpty || viewModel.isLoading)
            Button("Cancel Generation") {
                viewModel.cancelSuggestions()
                viewModel.dismissRewrite()
            }
            .keyboardShortcut(".")
            .disabled(!viewModel.isLoading && !viewModel.hasActiveRewrite)
            Divider()
            ForEach(RewriteAction.allCases) { action in
                Button(action.label) { viewModel.requestRewrite(action) }
                    .disabled(viewModel.selectedRange.length == 0 || viewModel.hasActiveRewrite)
            }
        }
    }

    /// The editor is one window on the shared view model: bring it back if it
    /// is open or minimized, and open it again only after it was closed.
    private func showEditorWindow() {
        let editor = NSApp.windows.first { window in
            window.identifier?.rawValue.hasPrefix(Writers_BlockApp.editorWindowID) == true
                && (window.isVisible || window.isMiniaturized)
        }
        if let editor {
            if editor.isMiniaturized { editor.deminiaturize(nil) }
            editor.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: Writers_BlockApp.editorWindowID)
        }
    }
}
#endif

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
    #if canImport(UIKit)
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
    #else
    // A Mac app keeps running in the background; there is nothing to request.
    init(name: String) {}
    func end() {}
    #endif
}
