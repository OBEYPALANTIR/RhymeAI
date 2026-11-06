import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appAppearanceStyle) private var appearance
    /// One Liners opened by a shortcut, widget, control or link, over whatever is on screen.
    @State private var oneLinersCoverPresented = false

    /// What the root does with a request for the One Liners screen.
    enum OneLinersCoverStep: Equatable {
        case present
        /// A Projects, Templates or Settings sheet is up: close it, then present.
        case closeSheetsFirst
        /// The first-run restore offer waits for an answer; present once it is gone.
        case wait
        /// Not the root's request (no request, or the screen or a capture takes it).
        case none
    }

    static func oneLinersCoverStep(handler: OneLinerRouter.Handler?, restoreOfferShown: Bool, sheetShown: Bool) -> OneLinersCoverStep {
        guard handler == .root else { return .none }
        if restoreOfferShown { return .wait }
        return sheetShown ? .closeSheetsFirst : .present
    }

    var body: some View {
        Group {
            if viewModel.showWelcome {
                WelcomeView()
                    .transition(.opacity)
            } else {
                EditorView()
                    .transition(.opacity)
            }
        }
        .rhymeAnimation(RhymeAITokens.Motion.state, value: viewModel.showWelcome)
        .onAppear {
            viewModel.modelContext = modelContext
        }
        .onOpenURL { url in
            if let action = OneLinerPendingAction(url: url) { OneLinerRouter.shared.request(action) }
        }
        .onChange(of: OneLinerRouter.shared.pending, initial: true) { _, _ in presentOneLinersIfRequested() }
        .onChange(of: viewModel.firstRunRestoreOffer == nil) { _, _ in presentOneLinersIfRequested() }
        // The screen takes the request once it is up, so a request that could not be shown stays pending.
        .fullScreenCover(isPresented: $oneLinersCoverPresented) {
            OneLinersView(onDismiss: { oneLinersCoverPresented = false }, takesRequests: true)
                .environmentObject(viewModel)
                .environment(\.appAppearanceStyle, appearance)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.purgeExpiredTrashedProjects()
            }
        }
        .sheet(isPresented: $viewModel.showProjectsSheet) {
            ProjectsView()
        }
        .sheet(isPresented: $viewModel.showTemplatesSheet) {
            TemplatesView()
        }
        // Settings presents the offer itself while it is open.
        .sheet(item: Binding(
            get: { viewModel.showSettingsSheet ? nil : viewModel.firstRunRestoreOffer },
            set: { if $0 == nil, !viewModel.showSettingsSheet { viewModel.firstRunRestoreOffer = nil } }
        )) { offer in
            FirstRunRestoreSheet(offer: offer)
        }
        .sheet(isPresented: $viewModel.showSettingsSheet) {
            SettingsView()
                .frame(
                    minWidth: horizontalSizeClass == .regular ? RhymeAITokens.Layout.assistantReadableWidth : nil,
                    idealWidth: horizontalSizeClass == .regular ? 520 : nil,
                    minHeight: horizontalSizeClass == .regular ? 560 : nil
                )
        }
    }
}

extension ContentView {
    private func presentOneLinersIfRequested() {
        let step = Self.oneLinersCoverStep(
            handler: OneLinerRouter.shared.handler(screenPresented: oneLinersCoverPresented),
            restoreOfferShown: viewModel.firstRunRestoreOffer != nil,
            sheetShown: viewModel.showProjectsSheet || viewModel.showTemplatesSheet || viewModel.showSettingsSheet
        )
        switch step {
        case .present:
            oneLinersCoverPresented = true
        case .closeSheetsFirst:
            viewModel.showProjectsSheet = false
            viewModel.showTemplatesSheet = false
            viewModel.showSettingsSheet = false
            // shortcut: a fixed wait for the sheet to finish closing; a presentation started sooner is refused.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                presentOneLinersIfRequested()
            }
        case .wait, .none:
            break
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: [SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self, OneLiner.self, TrashedOneLiner.self], inMemory: true)
}
