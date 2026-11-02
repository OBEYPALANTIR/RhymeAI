import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appAppearanceStyle) private var appearance
    /// One Liners opened by a shortcut, widget, control or link, over whatever is on screen.
    @State private var oneLinersRoute: OneLinersRoute?

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
        .onChange(of: OneLinerRouter.shared.pending, initial: true) { _, _ in
            guard let action = OneLinerRouter.shared.take([.record, .type, .open]) else { return }
            oneLinersRoute = OneLinersRoute(action: action)
        }
        .fullScreenCover(item: $oneLinersRoute) { route in
            OneLinersView(onDismiss: { oneLinersRoute = nil }, initialCapture: route.capture)
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

#Preview {
    ContentView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: [SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self, OneLiner.self, TrashedOneLiner.self], inMemory: true)
}
