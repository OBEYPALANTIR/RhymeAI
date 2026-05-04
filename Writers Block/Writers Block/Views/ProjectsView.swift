import SwiftUI
import SwiftData

struct ProjectsView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]

    var body: some View {
        NavigationStack {
            List {
                // New Song button
                Button {
                    viewModel.newProject()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "plus")
                            .foregroundStyle(.indigo)
                        Text("Create New Song")
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.indigo.opacity(0.1))

                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No Saved Songs", systemImage: "music.note")
                    } description: {
                        Text("Your songs will appear here once you start writing.")
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(projects, id: \.id) { project in
                        Button {
                            viewModel.loadProject(project)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.title.isEmpty ? "Untitled Song" : project.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    HStack(spacing: 8) {
                                        Text(project.updatedAt, style: .date)
                                        Text("·")
                                        Text("\(SyllableCounter.wordCount(project.lyrics)) words")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if viewModel.currentProjectId == project.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.indigo)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(
                            viewModel.currentProjectId == project.id
                                ? Color.indigo.opacity(0.1)
                                : Color.clear
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.deleteProject(project)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Song Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ProjectsView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: SongProject.self, inMemory: true)
}
