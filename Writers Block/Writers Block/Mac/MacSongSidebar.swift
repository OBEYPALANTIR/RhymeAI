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
                let songs = visibleSongs
                if songs.isEmpty {
                    Text(searchText.isEmpty ? "No songs yet" : "No matching songs")
                        .foregroundStyle(appearance.palette.secondaryInk)
                }
                ForEach(songs) { project in
                    MacSongRow(project: project)
                        .tag(SidebarItem.song(project.persistentModelID))
                        .contextMenu { rowMenu(project) }
                }
            }
        }
        .listStyle(.sidebar)
        // Delete on the selected row: the right-click Move to Trash. A song the
        // search hides is never selected, so never deleted, even when it is the open one.
        .onDeleteCommand {
            guard case .song(let row) = selection.wrappedValue,
                  let project = visibleSongs.first(where: { $0.persistentModelID == row }) else { return }
            viewModel.moveProjectToTrash(project)
        }
        .scrollContentBackground(.hidden)
        .background(appearance.palette.surfaceHigh)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search songs")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let notice = viewModel.projectDeletionNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(appearance.palette.warning)
                        .padding(RhymeAITokens.Spacing.sm)
                }
                // The sidebar's bottom bar, as Mac source lists put their add button.
                Rectangle()
                    .fill(appearance.palette.outline)
                    .frame(height: RhymeAITokens.Spacing.hairline)
                Button {
                    newSong()
                } label: {
                    Label("New Song", systemImage: "plus")
                        .frame(minHeight: RhymeAITokens.Touch.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(appearance.palette.primaryInk)
                .help("New Song")
                .padding(.horizontal, RhymeAITokens.Spacing.sm)
                .padding(.vertical, RhymeAITokens.Spacing.xxs)
                .accessibilityIdentifier("macNewSong")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(appearance.palette.surfaceHigh)
        }
    }

    private enum SidebarItem: Hashable {
        case song(PersistentIdentifier)
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
                case .editor: openRow.map { SidebarItem.song($0.persistentModelID) }
                }
            },
            set: { item in
                switch item {
                case .song(let row):
                    workspace.detail = .editor
                    guard let project = visibleSongs.first(where: { $0.persistentModelID == row }) else { return }
                    workspace.openSong(project, in: viewModel)
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
        Button("Open") { workspace.openSong(project, in: viewModel) }
        Divider()
        Button("Move to Trash", role: .destructive) { viewModel.moveProjectToTrash(project) }
    }

    private var visibleSongs: [SongProject] { SongProject.matching(projects, searchText: searchText) }

    private var openRow: SongProject? {
        viewModel.showWelcome ? nil : Self.openRow(loaded: viewModel.loadedProjectRow, openID: viewModel.currentProjectId, in: visibleSongs)
    }

    /// The shown row the editor was loaded from; none when the search hides it. Only a
    /// song not loaded from a row (a new song after its first save) falls back to its id.
    static func openRow(loaded: PersistentIdentifier?, openID: String?, in songs: [SongProject]) -> SongProject? {
        if let loaded { return songs.first { $0.persistentModelID == loaded } }
        return openID.flatMap { id in songs.first { $0.id == id } }
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
