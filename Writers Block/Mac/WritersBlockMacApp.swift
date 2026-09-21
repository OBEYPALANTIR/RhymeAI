import AppKit
import SwiftUI
import SwiftData

@main
struct WritersBlockMacApp: App {
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var delegate
    @StateObject private var editor = EditorViewModel(backupService: BackupService.shared)
    @AppStorage(AppAppearanceStyle.storageKey) private var appearanceRaw = AppAppearanceStyle.ink.rawValue
    private let container: ModelContainer?

    init() {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        container = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil, cloudKitDatabase: .none)])
    }

    var body: some Scene {
        Window("Writers Block", id: "workspace") {
            if let container {
                MacWorkspaceView()
                    .modelContainer(container)
                    .environmentObject(editor)
                    .preferredColorScheme(AppAppearanceStyle.resolve(appearanceRaw).preferredColorScheme)
                    .task { delegate.editor = editor }
            } else {
                ContentUnavailableView("Library unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text("Your library could not be opened. Close and reopen Writers Block to try again."))
            }
        }
        .defaultSize(width: 1160, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Song") {
                    if editor.saveCurrentProject() { editor.newProject() }
                }.keyboardShortcut("n")
                Button("Save Song") { editor.saveCurrentProject() }.keyboardShortcut("s")
            }
            CommandMenu("Song") {
                Button("UnBlock") { editor.showAssistantSheet = true; editor.getSuggestions() }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Cancel Generation") { editor.cancelSuggestions(); editor.dismissRewrite() }.keyboardShortcut(".")
                ForEach(RewriteAction.allCases) { action in
                    Button(action.label) { editor.requestRewrite(action) }.disabled(editor.selectedRange.length == 0 || editor.rewriteLoading)
                }
            }
        }
        Settings { MacSettingsView().environmentObject(editor) }
    }
}

final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var editor: EditorViewModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard editor?.saveCurrentProject() != false else { return .terminateCancel }
        editor?.voiceMemoService.stopRecording()
        editor?.voiceMemoService.stopPlayback()
        return .terminateNow
    }
}
