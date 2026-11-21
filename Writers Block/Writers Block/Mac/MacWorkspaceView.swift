#if os(macOS)
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The Mac window: songs in the sidebar, the open song (or One Liners, or
/// Trash) in the detail pane, and the assistant as a trailing inspector.
/// The song, its AI and its sheets are the iOS editor's, through the shared
/// view model and the shared editor pieces.
struct MacWorkspaceView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    /// The narrowest the detail pane gets, so hiding the sidebar cannot squeeze a page
    /// to nothing (One Liners alone went to 147pt). No wider than the pane already is at
    /// the window's minimum with the sidebar shown (667 - 220), so that minimum stays.
    static let detailMinWidth: CGFloat = 440

    var body: some View {
        NavigationSplitView(columnVisibility: $workspace.sidebarVisibility) {
            MacSongSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailPane
                .frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                .background(appearance.palette.canvas)
                .inspector(isPresented: assistantPresented) {
                    // No close button in the panel: the toolbar and View menu show and hide it.
                    AssistantPanelView(isInline: true)
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
                }
                .toolbar { MacWorkspaceToolbar() }
                .toolbarBackground(appearance.palette.canvas, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
                .navigationTitle(windowTitle)
                .fileImporter(
                    isPresented: $workspace.audioImporterPresented,
                    allowedContentTypes: EditorViewModel.importableAudioTypes,
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case .success(let urls): workspace.importRecordings(urls, into: viewModel)
                    case .failure(let error): workspace.reportPickerFailure(error)
                    }
                }
        }
        .foregroundStyle(appearance.palette.primaryInk)
        .fileImporter(isPresented: $workspace.songImporterPresented, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): workspace.importSongs([url], into: viewModel)
            case .failure(let error): workspace.reportPickerFailure(error)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            switch MacDropRoute.route(urls, songOpen: workspace.songOpen(in: viewModel)) {
            case .songs(let urls):
                workspace.importSongs(urls, into: viewModel)
                return true
            case .recordings(let audio):
                workspace.importRecordings(audio, into: viewModel)
                return true
            case .none:
                return false
            }
        }
        .modifier(EditorSheetsModifier(recordingSong: $workspace.recordingSong))
        .sheet(isPresented: $viewModel.showTemplatesSheet) {
            TemplatesView()
                .frame(minWidth: 520, idealWidth: 600, minHeight: 560, idealHeight: 680)
                .environmentObject(viewModel)
        }
        .sheet(item: Binding(
            get: { viewModel.firstRunRestoreOffer },
            set: { if $0 == nil { viewModel.firstRunRestoreOffer = nil } }
        )) { offer in
            FirstRunRestoreSheet(offer: offer)
                .environmentObject(viewModel)
        }
        .alert(
            "Import Failed",
            isPresented: Binding(get: { workspace.importError != nil }, set: { if !$0 { workspace.importError = nil } }),
            presenting: workspace.importError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .alert(
            "Couldn't Save",
            isPresented: Binding(get: { workspace.saveError != nil }, set: { if !$0 { workspace.saveError = nil } }),
            presenting: workspace.saveError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        // Record with microphone access denied: the iOS mic button's alert,
        // which the Mac's Recordings menu has no button to carry.
        .alert("Microphone Access Denied", isPresented: Bindable(viewModel.voiceMemoService).permissionDenied) {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow microphone access in System Settings to record melody ideas.")
        }
        // Settings is its own window on the Mac; the shared code asks for it
        // through the iOS sheet flag.
        .onChange(of: viewModel.showSettingsSheet, initial: true) { _, show in
            guard show else { return }
            viewModel.showSettingsSheet = false
            openSettings()
        }
        .onChange(of: viewModel.editorOpen) { _, _ in workspace.detail = .editor }
        .onOpenURL { url in
            if let action = OneLinerPendingAction(url: url) { OneLinerRouter.shared.request(action) }
        }
        .onChange(of: OneLinerRouter.shared.pending, initial: true) { _, _ in showOneLinersIfRequested() }
        .onChange(of: viewModel.firstRunRestoreOffer == nil) { _, _ in showOneLinersIfRequested() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.purgeExpiredTrashedProjects() }
        }
        .onAppear {
            // Once per context: every assignment starts the recordings launch pass.
            if viewModel.modelContext !== modelContext { viewModel.modelContext = modelContext }
            workspace.windowOpen = true
            if UITestFlags.isEnabled(UITestFlags.openSettings) { openSettings() }
            if UITestFlags.isEnabled(UITestFlags.openTemplates) { viewModel.showTemplatesSheet = true }
            if UITestFlags.isEnabled(UITestFlags.openOneLiners) { workspace.detail = .oneLiners }
        }
        // Closing the window runs a waiting autosave now rather than after its
        // one-second wait; that save failing, or a last save that had failed, is
        // reported. Quitting saves through MacAppDelegate, which holds Quit then.
        .onDisappear {
            workspace.windowOpen = false
            guard !MacAppDelegate.isTerminating, !viewModel.savePendingEdit() else { return }
            reportUnsavedSongAfterClose()
        }
    }

    /// The window is gone, and its Save Failed control with it: the failure is
    /// reported in an alert that can bring the window back to retry.
    private func reportUnsavedSongAfterClose() {
        let reason = viewModel.errorMessage ?? "Couldn't save this song. Your edits remain open."
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Your Song Couldn't Be Saved"
            alert.informativeText = "\(reason) Reopen the window to try saving again."
            alert.addButton(withTitle: "Reopen Window")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                MacEditorWindow.bringForward(openWindow: openWindow)
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch workspace.detail {
        case .editor:
            if viewModel.showWelcome {
                MacEmptyState()
            } else {
                MacEditorDetail()
            }
        case .oneLiners:
            OneLinersView(onDismiss: { workspace.detail = .editor }, takesRequests: true)
        case .trash:
            TrashBinView(onDismiss: { workspace.detail = .editor })
        }
    }

    /// The open song's name, as a Mac document window shows it.
    private var windowTitle: String {
        guard workspace.detail == .editor, !viewModel.showWelcome else { return "Writers Block" }
        return viewModel.title.isEmpty ? "Untitled Song" : viewModel.title
    }

    /// Shown while a song is open, the writer wants it, and Focus is off.
    private var assistantPresented: Binding<Bool> {
        Binding(
            get: { workspace.showsAssistant && workspace.songOpen(in: viewModel) && !workspace.isFocusMode },
            set: { if !$0 { workspace.showsAssistant = false } }
        )
    }

    /// One Liners requested by a link, shortcut or menu: the iOS root's rule,
    /// with the detail pane in place of the full-screen cover.
    private func showOneLinersIfRequested() {
        let step = ContentView.oneLinersCoverStep(
            handler: OneLinerRouter.shared.handler(screenPresented: workspace.detail == .oneLiners),
            restoreOfferShown: viewModel.firstRunRestoreOffer != nil,
            sheetShown: viewModel.showTemplatesSheet
        )
        switch step {
        case .present:
            workspace.detail = .oneLiners
        case .closeSheetsFirst:
            viewModel.showTemplatesSheet = false
            workspace.detail = .oneLiners
        case .wait, .none:
            break
        }
    }
}

/// The open song: title, counts, lyrics and the rewrite chips at the reading
/// width, the iOS writing column without the iPad bar.
struct MacEditorDetail: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var lyricsEditorIsFocused = false
    @State private var focusedNewSongOpen: EditorViewModel.EditorOpen?
    @FocusState private var titleFocusedOpen: EditorViewModel.EditorOpen?
    @State private var accessoryHeight: CGFloat = EditorViewConstants.EditorLayout.noAccessoryHeight

    var body: some View {
        let showsChipBar = RewriteAccessoryBar.showsChipBar(
            viewModel: viewModel,
            isFocusMode: workspace.isFocusMode,
            assistantSheetActive: false
        )
        EditorWritingColumn(
            isFocusMode: workspace.isFocusMode,
            sidePadding: RhymeAITokens.Rhythm.section,
            bottomOverlayHeight: RewriteAccessoryBar.selectionAvoidanceInset(
                viewModel: viewModel,
                showsChipBar: showsChipBar,
                accessoryHeight: accessoryHeight
            ),
            lyricsEditorIsFocused: $lyricsEditorIsFocused,
            scrollPosition: $scrollPosition,
            focusedNewSongOpen: $focusedNewSongOpen,
            titleFocusedOpen: $titleFocusedOpen,
            listKeepsFocusOnOpen: workspace.sidebarSelectedOpen == viewModel.editorOpen
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RewriteAccessoryBar(isHidden: false, showsChipBar: showsChipBar, height: $accessoryHeight)
                .frame(maxWidth: RhymeAITokens.Layout.editorMaxWidth)
                .padding(.horizontal, RhymeAITokens.Spacing.md)
                .padding(.bottom, RhymeAITokens.Spacing.sm)
        }
        // Within this pane only a new open re-creates the lyrics (`.id(editorOpen)`).
        // A pane built again for the same open (back from Trash or One Liners, a
        // reopened window) is no sidebar selection: its lyrics take the focus.
        .onDisappear { workspace.sidebarSelectedOpen = nil }
    }
}

/// No song open: the welcome cards' three ways in.
private struct MacEmptyState: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.appAppearanceStyle) private var appearance

    var body: some View {
        ContentUnavailableView {
            Label("No Song Open", systemImage: "square.and.pencil")
                .foregroundStyle(appearance.palette.primaryInk)
        } description: {
            Text("Start a new song, begin from a template, or catch a line in One Liners.")
                .foregroundStyle(appearance.palette.secondaryInk)
        } actions: {
            HStack(spacing: RhymeAITokens.Spacing.sm) {
                Button("New Song") { viewModel.newProject() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Templates") { viewModel.showTemplatesSheet = true }
                Button("One Liners") { workspace.detail = .oneLiners }
            }
            .controlSize(.large)
        }
        .accessibilityIdentifier("macEmptyState")
    }
}

/// The window toolbar. The app draws the sidebar button; the split view's own is removed.
private struct MacWorkspaceToolbar: ToolbarContent {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some ToolbarContent {
        // DESIGN: no glass. macOS 26 puts a shared glass capsule behind items.
        if #available(macOS 26.0, *) {
            ToolbarItemGroup(placement: .navigation) { historyButtons }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup(placement: .primaryAction) { songButtons }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItemGroup(placement: .navigation) { historyButtons }
            ToolbarItemGroup(placement: .primaryAction) { songButtons }
        }
    }

    private var state: MacCommandState { MacCommandState(viewModel: viewModel, workspace: workspace) }

    @ViewBuilder
    private var historyButtons: some View {
        // In place of the split view's own toggle, which draws a glass circle.
        Button { workspace.toggleSidebar() } label: { Label("Sidebar", systemImage: "sidebar.leading") }
            .help(workspace.sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
        Button { viewModel.undoLyrics() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            .help("Undo")
            .disabled(!state.canUndo)
        Button { viewModel.redoLyrics() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            .help("Redo")
            .disabled(!state.canRedo)
        MacSaveFailedButton()
    }

    @ViewBuilder
    private var songButtons: some View {
        let songOpen = state.songOpen
        Menu {
            MacDisplayToggles()
        } label: {
            Label("Display", systemImage: "textformat")
        }
        .help("Display")
        .disabled(!songOpen)

        Button { viewModel.showNotebook = true } label: { Label("Notebook", systemImage: "book.closed") }
            .help("Notebook")
            .disabled(!songOpen)

        Menu {
            MacRecordingItems()
        } label: {
            Label("Recordings", systemImage: viewModel.voiceMemoService.isRecording ? "stop.circle" : "mic")
        }
        .help("Recordings")
        // Stop stays reachable while a recording runs, wherever the window is.
        .disabled(!songOpen && !viewModel.voiceMemoService.isRecording)

        Button { viewModel.showExportSheet = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .help("Export")
            .disabled(!state.canExport)

        Button { workspace.toggleAssistant() } label: { Label("Assistant", systemImage: "sidebar.trailing") }
            .help(workspace.assistantVisible ? "Hide Assistant" : "Show Assistant")
            .disabled(!songOpen)
    }
}

/// The iOS top bar's "Save failed" retry: shown only while the open song's
/// last save (autosave or File › Save) failed. Retrying is the autosave path.
private struct MacSaveFailedButton: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.appAppearanceStyle) private var appearance

    var body: some View {
        if viewModel.saveStatus == .failed {
            Button { viewModel.triggerAutoSave() } label: {
                Label {
                    Text("Save Failed")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(appearance.palette.error)
                }
                .labelStyle(.titleAndIcon)
            }
            .help("Save failed. Click to retry saving")
            .accessibilityLabel("Save failed. Retry saving")
        }
    }
}

/// Rhyme colours, syllable underlines and Focus, for the toolbar's Display
/// menu and the View menu.
struct MacDisplayToggles: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        Toggle("Color Rhymes", isOn: Binding(
            get: { viewModel.isRhymeHighlightEnabled },
            set: { viewModel.saveIsRhymeHighlightEnabled($0) }
        ))
        Toggle("Underline Syllables", isOn: Binding(
            get: { viewModel.isSyllableColoringEnabled },
            set: { viewModel.saveIsSyllableColoringEnabled($0) }
        ))
        Divider()
        Toggle("Focus", isOn: $workspace.isFocusMode)
    }
}

/// Record or stop, and the song's recordings list.
struct MacRecordingItems: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var workspace: MacWorkspaceModel

    var body: some View {
        let songOpen = workspace.songOpen(in: viewModel)
        if viewModel.voiceMemoService.isRecording {
            Button("Stop Recording") { viewModel.voiceMemoService.stopRecording() }
        } else {
            Button("Record") {
                guard let projectId = viewModel.ensureProjectForRecording() else { return }
                Task { await viewModel.voiceMemoService.startRecording(projectId: projectId) }
            }
            .disabled(!songOpen)
        }
        Button("Show Recordings") { workspace.showRecordings(for: viewModel) }
            .disabled(!songOpen)
        Button("Import Audio…") { workspace.audioImporterPresented = true }
            .disabled(!songOpen)
    }
}

/// Song › Stop Recording, for a voice memo left running with the window
/// closed or away from the song. A view so it follows the recorder.
struct MacStopRecordingCommand: View {
    let voiceMemoService: VoiceMemoService

    var body: some View {
        Button("Stop Recording") { voiceMemoService.stopRecording() }
            .disabled(!voiceMemoService.isRecording)
    }
}
#endif
