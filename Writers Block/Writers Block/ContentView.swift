import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
        .animation(.easeInOut(duration: 0.3), value: viewModel.showWelcome)
        .onAppear {
            viewModel.modelContext = modelContext
        }
        .sheet(isPresented: $viewModel.showProjectsSheet) {
            ProjectsView()
        }
        .sheet(isPresented: $viewModel.showTemplatesSheet) {
            TemplatesView()
        }
        .popover(isPresented: $viewModel.showSettingsSheet) {
            SettingsView()
                .frame(
                    minWidth: horizontalSizeClass == .regular ? 400 : nil,
                    minHeight: horizontalSizeClass == .regular ? 500 : nil
                )
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: SongProject.self, inMemory: true)
}
