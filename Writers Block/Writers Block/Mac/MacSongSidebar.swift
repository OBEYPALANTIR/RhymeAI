#if os(macOS)
import SwiftUI
import SwiftData

/// The window's sidebar: New Song, the songs most recent first with the
/// drawer's search, and the One Liners, Templates and Trash entries.
struct MacSongSidebar: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @EnvironmentObject private var workspace: MacWorkspaceModel
    @Environment(\.appAppearanceStyle) private var appearance
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]
    @State private var searchText = ""

    var body: some View {
        List(selection: selection) {
            Section {
                Label("One Liners", systemImage: "text.quote")
                    .tag(SidebarItem.oneLiners)
                Button {
                    viewModel.showTemplatesSheet = true
                } label: {
                    Label("Templates", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                Label("Trash", systemImage: "trash")
                    .tag(SidebarItem.trash)
            }

            Section("Songs") {
                let songs = SongProject.matching(projects, searchText: searchText)
                if songs.isEmpty {
                    Text(searchText.isEmpty ? "No songs yet" : "No matching songs")
                        .foregroundStyle(appearance.palette.secondaryInk)
                }
                ForEach(songs) { project in
                    MacSongRow(project: project)
                        .tag(SidebarItem.song(project.id))
                        .contextMenu { rowMenu(project) }
                }
            }
        }
        .listStyle(.sidebar)
        // Delete on the selected song: the right-click Move to Trash.
        .onDeleteCommand {
            if case .song(let id) = selection.wrappedValue, let project = projects.first(where: { $0.id == id }) {
                viewModel.moveProjectToTrash(project)
            }
        }
        .scrollContentBackground(.hidden)
        .background(appearance.palette.surfaceHigh)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search songs")
        .safeAreaInset(edge: .top, spacing: 0) {
            Button {
                newSong()
            } label: {
                Label("New Song", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, RhymeAITokens.Spacing.sm)
            .padding(.vertical, RhymeAITokens.Spacing.xs)
            .accessibilityIdentifier("macNewSong")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice = viewModel.projectDeletionNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(appearance.palette.warning)
                    .padding(RhymeAITokens.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private enum SidebarItem: Hashable {
        case song(String)
        case oneLiners
        case trash
    }

    /// The row for what the detail pane shows. Picking a song opens it
    /// through the drawer's path.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                switch workspace.detail {
                case .oneLiners: .oneLiners
                case .trash: .trash
                case .editor: viewModel.showWelcome ? nil : viewModel.currentProjectId.map(SidebarItem.song)
                }
            },
            set: { item in
                switch item {
                case .song(let id):
                    workspace.detail = .editor
                    guard id != viewModel.currentProjectId || viewModel.showWelcome,
                          let project = projects.first(where: { $0.id == id }) else { return }
                    viewModel.loadProject(project)
                case .oneLiners:
                    workspace.detail = .oneLiners
                case .trash:
                    workspace.detail = .trash
                case nil:
                    break
                }
            }
        )
    }

    @ViewBuilder
    private func rowMenu(_ project: SongProject) -> some View {
        Button("Open") { open(project) }
        Button("Export…") {
            open(project)
            if !viewModel.lyrics.isEmpty { viewModel.showExportSheet = true }
        }
        .disabled(project.lyrics.isEmpty)
        Divider()
        Button("Move to Trash", role: .destructive) { viewModel.moveProjectToTrash(project) }
    }

    private func open(_ project: SongProject) {
        workspace.detail = .editor
        if project.id != viewModel.currentProjectId || viewModel.showWelcome {
            viewModel.loadProject(project)
        }
    }

    private func newSong() {
        workspace.detail = .editor
        viewModel.newProject()
    }
}

private struct MacSongRow: View {
    @Environment(\.appAppearanceStyle) private var appearance
    let project: SongProject

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
            Text(project.title.isEmpty ? "Untitled Song" : project.title)
                .lineLimit(1)
            HStack(spacing: RhymeAITokens.Spacing.xs) {
                Text(project.updatedAt, style: .date)
                Text("·").accessibilityHidden(true)
                Text("\(SyllableCounter.wordCount(project.lyrics)) words")
            }
            .font(.caption)
            .foregroundStyle(appearance.palette.secondaryInk)
            .lineLimit(1)
        }
        .padding(.vertical, RhymeAITokens.Spacing.xxs)
    }
}
#endif
