import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var showSaveIssue = false
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.purgeExpiredTrashedProjects()
            } else {
                viewModel.flushCurrentDraft(checkpoint: true)
            }
        }
        .onReceive(viewModel.$companionError) { error in
            if error != nil { showSaveIssue = true }
        }
        .alert("Save issue", isPresented: $showSaveIssue) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(viewModel.companionError ?? "Please try saving again.")
        }
        .sheet(isPresented: $viewModel.showProjectsSheet) {
            ProjectsView()
        }
        .sheet(isPresented: $viewModel.showTemplatesSheet) {
            TemplatesView()
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
        .environmentObject(GGUFDownloadManager())
        .modelContainer(for: [SongProject.self, TrashedSongProject.self], inMemory: true)
}
