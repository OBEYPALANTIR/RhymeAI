#if os(macOS)
import AppKit

/// Holds Quit while the open song's unsaved edit cannot be saved, so it is not
/// lost silently: the writer chooses to try again, keep the app open, or quit.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var viewModel: EditorViewModel?
    /// Quit was allowed: the window's close save stays quiet from here on.
    @MainActor static private(set) var isTerminating = false

    enum FailedSaveChoice {
        case tryAgain
        case keepOpen
        case quitAnyway
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = Self.terminateReply(viewModel: viewModel, ask: Self.askAfterFailedSave)
        if reply == .terminateNow { Self.isTerminating = true }
        return reply
    }

    /// Saves the open song's unsaved edit; while that fails, asks what to do.
    @MainActor
    static func terminateReply(viewModel: EditorViewModel?, ask: (String) -> FailedSaveChoice) -> NSApplication.TerminateReply {
        guard let viewModel else { return .terminateNow }
        while !viewModel.saveUnsavedEdit() {
            switch ask(viewModel.errorMessage ?? "Couldn't save this song. Your edits remain open.") {
            case .tryAgain: continue
            case .keepOpen: return .terminateCancel
            case .quitAnyway: return .terminateNow
            }
        }
        return .terminateNow
    }

    @MainActor
    private static func askAfterFailedSave(_ reason: String) -> FailedSaveChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Your Song Couldn't Be Saved"
        alert.informativeText = "\(reason) If you quit now, the changes since the last save are lost."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Don't Quit")
        alert.addButton(withTitle: "Quit Anyway")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .tryAgain
        case .alertSecondButtonReturn: return .keepOpen
        default: return .quitAnyway
        }
    }
}
#endif
