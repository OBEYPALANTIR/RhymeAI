import SwiftUI
import SwiftData

struct ContentView: View {
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
        .rhymeAnimation(.easeInOut(duration: 0.3), value: viewModel.showWelcome)
        .onAppear {
            viewModel.modelContext = modelContext
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
        .sheet(isPresented: $viewModel.showSettingsSheet) {
            SettingsView()
                .frame(
                    minWidth: horizontalSizeClass == .regular ? 420 : nil,
                    idealWidth: horizontalSizeClass == .regular ? 520 : nil,
                    minHeight: horizontalSizeClass == .regular ? 560 : nil
                )
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: [SongProject.self, TrashedSongProject.self], inMemory: true)
}
