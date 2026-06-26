import Foundation
import SwiftData
import SwiftUI

struct TrashBinView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TrashedSongProject.deletedAt, order: .reverse) private var trashedProjects: [TrashedSongProject]
    @State private var selectedIds: Set<String> = []
    @State private var confirmPermanentDelete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onDismiss: (() -> Void)? = nil

    private var trashIds: [String] {
        trashedProjects.map(\.id)
    }

    private var selectedProjects: [TrashedSongProject] {
        trashedProjects.filter { selectedIds.contains($0.id) }
    }

    private var allSelected: Bool {
        !trashedProjects.isEmpty && selectedIds.count == trashedProjects.count
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                if trashedProjects.isEmpty {
                    emptyState
                } else {
                    trashList
                }
            }
        }
        .navigationBarHidden(true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomActionBar
        }
        .onAppear {
            viewModel.purgeExpiredTrashedProjects()
            pruneSelection()
        }
        .onChange(of: trashIds) { _, _ in
            pruneSelection()
        }
        .alert("Delete forever?", isPresented: $confirmPermanentDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Forever", role: .destructive) {
                let projects = selectedProjects
                projects.forEach(viewModel.permanentlyDeleteTrashedProject)
                clearSelectionWithFeedback()
            }
        } message: {
            Text("\(selectedIds.count) selected song\(selectedIds.count == 1 ? "" : "s") will be permanently deleted. This cannot be undone.")
        }
    }

    private var topBar: some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            Button {
                dismissView()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.rhymePress)
            .accessibilityLabel("Back to songs")

            Text("Trash")
                .font(.title2.weight(.semibold))

            Spacer()

            Image(systemName: "square.grid.2x2")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, RhymeAITokens.Spacing.md)
        .padding(.top, RhymeAITokens.Spacing.md)
        .padding(.bottom, RhymeAITokens.Spacing.sm)
        .background(.ultraThinMaterial)
        .overlay(Divider().opacity(0.18), alignment: .bottom)
    }

    private var trashList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                selectionHeader

                ForEach(trashedProjects, id: \.id) { project in
                    trashRow(project)
                }
            }
            .padding(.top, RhymeAITokens.Spacing.sm)
            .padding(.bottom, RhymeAITokens.Spacing.xxl)
        }
        .scrollContentBackground(.hidden)
    }

    private var selectionHeader: some View {
        Button {
            withRhymeAnimation(RhymeAITokens.Motion.feedback, reduceMotion: reduceMotion) {
                selectedIds = allSelected ? [] : Set(trashIds)
            }
        } label: {
            HStack {
                Text("All items")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                selectionCircle(selected: allSelected)
            }
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .padding(.horizontal, RhymeAITokens.Spacing.md)
        }
        .buttonStyle(.rhymePress)
        .accessibilityLabel(allSelected ? "Deselect all trash items" : "Select all trash items")
    }

    private func trashRow(_ project: TrashedSongProject) -> some View {
        let selected = selectedIds.contains(project.id)

        return Button {
            toggleSelection(project.id)
        } label: {
            HStack(spacing: RhymeAITokens.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: RhymeAITokens.Radius.sm, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))

                    Image(systemName: "doc.text")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: RhymeAITokens.Touch.comfortable, height: RhymeAITokens.Touch.comfortable)

                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                    Text(project.title.isEmpty ? "Untitled Song" : project.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(SyllableCounter.wordCount(project.lyrics)) words · \(trashRemainingText(deleteAfter: project.deleteAfter))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: RhymeAITokens.Spacing.sm)

                selectionCircle(selected: selected)
            }
            .frame(minHeight: 76)
            .padding(.horizontal, RhymeAITokens.Spacing.md)
            .padding(.vertical, RhymeAITokens.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.rhymePress)
        .accessibilityLabel(project.title.isEmpty ? "Untitled Song" : project.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Trash Bin is Empty", systemImage: "trash")
        } description: {
            Text("Deleted songs stay here for 30 days.")
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(RhymeAITokens.Spacing.xl)
    }

    private var bottomActionBar: some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            Button {
                let projects = selectedProjects
                projects.forEach(viewModel.restoreTrashedProject)
                clearSelectionWithFeedback()
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: RhymeAITokens.Touch.minimum)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(selectedIds.isEmpty)

            Button(role: .destructive) {
                confirmPermanentDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: RhymeAITokens.Touch.minimum)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(selectedIds.isEmpty)
        }
        .padding(.horizontal, RhymeAITokens.Spacing.md)
        .padding(.top, RhymeAITokens.Spacing.sm)
        .padding(.bottom, RhymeAITokens.Spacing.sm)
        .background(.ultraThinMaterial)
    }

    private func selectionCircle(selected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? Color.indigo : Color.secondary.opacity(0.9), lineWidth: 2)
                .background(
                    Circle()
                        .fill(Color.indigo)
                        .scaleEffect(selected ? 1 : 0.72)
                        .opacity(selected ? 1 : 0)
                )

            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
            }
        }
        .frame(width: 26, height: 26)
        .rhymeAnimation(RhymeAITokens.Motion.feedback, value: selected)
    }

    private func dismissView() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private func toggleSelection(_ id: String) {
        withRhymeAnimation(RhymeAITokens.Motion.feedback, reduceMotion: reduceMotion) {
            if selectedIds.contains(id) {
                selectedIds.remove(id)
            } else {
                selectedIds.insert(id)
            }
        }
    }

    private func clearSelectionWithFeedback() {
        withRhymeAnimation(RhymeAITokens.Motion.feedback, reduceMotion: reduceMotion) {
            selectedIds.removeAll()
        }
    }

    private func pruneSelection() {
        selectedIds.formIntersection(Set(trashIds))
    }

    private func trashRemainingText(deleteAfter: Date) -> String {
        let remaining = max(deleteAfter.timeIntervalSinceNow, 0)
        let days = Int(ceil(remaining / (24 * 60 * 60)))
        switch days {
        case 0:
            return "deletes today"
        case 1:
            return "1 day left"
        default:
            return "\(days) days left"
        }
    }
}

#Preview {
    TrashBinView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: [SongProject.self, TrashedSongProject.self], inMemory: true)
}
