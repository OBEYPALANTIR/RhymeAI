#if os(macOS)
import SwiftUI

/// Menu bar commands for the Mac app, on the same view model actions the
/// window's controls use. Each item is disabled when it cannot act.
struct MacAppCommands: Commands {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject var workspace: MacWorkspaceModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let state = MacCommandState(viewModel: viewModel, workspace: workspace)

        CommandGroup(replacing: .newItem) {
            Button("New Song") {
                showEditorWindow()
                workspace.detail = .editor
                viewModel.newProject()
            }
            .keyboardShortcut("n")
            Button("New One Liner") {
                showEditorWindow()
                OneLinerRouter.shared.request(.type)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { viewModel.flushCurrentDraft(checkpoint: true) }
                .keyboardShortcut("s")
                .disabled(!state.songOpen)
        }
        CommandGroup(replacing: .importExport) {
            Button("Import Song…") {
                showEditorWindow()
                workspace.songImporterPresented = true
            }
            Button("Import Audio…") { workspace.audioImporterPresented = true }
                .disabled(!state.songOpen)
            Divider()
            Button("Export…") { viewModel.showExportSheet = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!state.canExport)
        }

        // The lyric history, as the toolbar's Undo and Redo.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { viewModel.undoLyrics() }
                .keyboardShortcut("z")
                .disabled(!state.canUndo)
            Button("Redo") { viewModel.redoLyrics() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!state.canRedo)
        }

        CommandGroup(replacing: .sidebar) {
            Button(workspace.sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
                workspace.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(!workspace.windowOpen)
            Button(workspace.assistantVisible ? "Hide Assistant" : "Show Assistant") {
                workspace.toggleAssistant()
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .disabled(!state.songOpen)
            Divider()
            Toggle("Color Rhymes", isOn: Binding(
                get: { viewModel.isRhymeHighlightEnabled },
                set: { viewModel.saveIsRhymeHighlightEnabled($0) }
            ))
            .disabled(!state.songOpen)
            Toggle("Underline Syllables", isOn: Binding(
                get: { viewModel.isSyllableColoringEnabled },
                set: { viewModel.saveIsSyllableColoringEnabled($0) }
            ))
            .disabled(!state.songOpen)
            Toggle("Focus", isOn: $workspace.isFocusMode)
                .disabled(!state.songOpen)
            Divider()
        }

        CommandMenu("Song") {
            Button("Suggest Next Line") { workspace.suggestNextLine(viewModel) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!state.canSuggest)
            Button("Cancel Generation") {
                viewModel.cancelSuggestions()
                viewModel.dismissRewrite()
            }
            .keyboardShortcut(".")
            .disabled(!state.canCancelGeneration)
            Divider()
            ForEach(RewriteAction.allCases) { action in
                Button(action.label) { viewModel.requestRewrite(action) }
                    .disabled(!state.canRewrite)
            }
            Divider()
            Button("Word Inspector") { viewModel.openInspectorForSelection() }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(!state.canInspectWord)
            Button("Notebook") { viewModel.showNotebook = true }
                .disabled(!state.songOpen)
            Button("Recordings") { workspace.showRecordings(for: viewModel) }
                .disabled(!state.songOpen)
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
