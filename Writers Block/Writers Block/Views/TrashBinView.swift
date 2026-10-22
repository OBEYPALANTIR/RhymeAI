import Foundation
import SwiftData
import SwiftUI

struct TrashBinView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TrashedSongProject.deletedAt, order: .reverse) private var trashedProjects: [TrashedSongProject]
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]
    @State private var selectedIds: Set<String> = []
    @State private var confirmPermanentDelete = false
    @State private var activeTab: TrashTab = .projects
    @State private var trashedMemos: [TrashedVoiceMemo] = []
    @State private var selectedMemoIds: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var onDismiss: (() -> Void)? = nil

    private enum TrashTab: String, CaseIterable {
        case projects = "Songs"
        case recordings = "Recordings"
    }

    private var trashIds: [String] {
        trashedProjects.map(\.id)
    }

    private var selectedProjects: [TrashedSongProject] {
        trashedProjects.filter { selectedIds.contains($0.id) }
    }

    private var selectedMemos: [TrashedVoiceMemo] {
        trashedMemos.filter { selectedMemoIds.contains($0.id) }
    }

    private var allSelected: Bool {
        if activeTab == .projects {
            return !trashedProjects.isEmpty && selectedIds.count == trashedProjects.count
        }
        return !trashedMemos.isEmpty && selectedMemoIds.count == trashedMemos.count
    }

    private var activeSelectionCount: Int {
        activeTab == .projects ? selectedIds.count : selectedMemoIds.count
    }

    // Song titles for recording subtitles: live projects and trashed projects
    // both count; anything else was permanently deleted.
    private var projectTitleById: [String: String] {
        var titles: [String: String] = [:]
        for trashed in trashedProjects {
            titles[trashed.id] = trashed.title.isEmpty ? "Untitled Song" : trashed.title
        }
        for project in projects {
            titles[project.id] = project.title.isEmpty ? "Untitled Song" : project.title
        }
        return titles
    }

    var body: some View {
        ZStack {
            AppWritingBackground()

            VStack(spacing: 0) {
                topBar

                VStack(spacing: 0) {
                    Picker("Trash Tab", selection: $activeTab) {
                        ForEach(TrashTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("trashTabPicker")
                    .padding(.horizontal, RhymeAITokens.Spacing.md)
                    .padding(.top, RhymeAITokens.Spacing.sm)

                    if activeTab == .projects {
                        if trashedProjects.isEmpty {
                            emptyState
                        } else {
                            trashList
                        }
                    } else {
                        if trashedMemos.isEmpty {
                            recordingsEmptyState
                        } else {
                            recordingsTrashList
                        }
                    }
                }
                .frame(maxWidth: contentMaxWidth)
            }
        }
        // The background opts out of hit testing; without a shape, taps on
        // blank parts of the screen reach the songs drawer underneath.
        .contentShape(Rectangle())
        .navigationBarHidden(true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomActionBar
        }
        .onAppear {
            viewModel.purgeExpiredTrashedProjects()
            reloadTrashedMemos()
            pruneSelection()
        }
        .onChange(of: trashIds) { _, _ in
            pruneSelection()
        }
        .alert("Delete forever?", isPresented: $confirmPermanentDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Forever", role: .destructive) {
                deleteSelectedForever()
            }
        } message: {
            let noun = activeTab == .projects ? "song" : "recording"
            Text("\(activeSelectionCount) selected \(noun)\(activeSelectionCount == 1 ? "" : "s") will be permanently deleted. This cannot be undone.")
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
                .foregroundStyle(appearance.palette.secondaryInk)
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, RhymeAITokens.Spacing.md)
        .padding(.top, RhymeAITokens.Spacing.md)
        .padding(.bottom, RhymeAITokens.Spacing.sm)
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .liquidGlassSurface(cornerRadius: 0)
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
                if activeTab == .projects {
                    selectedIds = allSelected ? [] : Set(trashIds)
                } else {
                    selectedMemoIds = allSelected ? [] : Set(trashedMemos.map(\.id))
                }
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
                        .fill(appearance.palette.raisedSurface)

                    Image(systemName: "doc.text")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(appearance.palette.secondaryInk)
                }
                .frame(width: RhymeAITokens.Touch.comfortable, height: RhymeAITokens.Touch.comfortable)

                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                    Text(project.title.isEmpty ? "Untitled Song" : project.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(rowLineLimit)

                    Text("\(SyllableCounter.wordCount(project.lyrics)) words · \(trashRemainingText(deleteAfter: project.deleteAfter))")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.secondaryInk)
                        .lineLimit(rowLineLimit)
                }
                .multilineTextAlignment(.leading)

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
            Label("No Songs in Trash", systemImage: "trash")
        } description: {
            Text("Deleted songs stay here for 30 days.")
        }
        .foregroundStyle(appearance.palette.secondaryInk)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(RhymeAITokens.Spacing.xl)
    }

    // MARK: - Recordings Tab

    private var recordingsEmptyState: some View {
        ContentUnavailableView {
            Label("No Recordings in Trash", systemImage: "mic.slash")
        } description: {
            Text("Deleted recordings stay here for 30 days.")
        }
        .foregroundStyle(appearance.palette.secondaryInk)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(RhymeAITokens.Spacing.xl)
    }

    private var recordingsTrashList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                selectionHeader

                ForEach(trashedMemos) { memo in
                    trashRecordingRow(memo)
                }
            }
            .padding(.top, RhymeAITokens.Spacing.sm)
            .padding(.bottom, RhymeAITokens.Spacing.xxl)
        }
        .scrollContentBackground(.hidden)
    }

    private func trashRecordingRow(_ memo: TrashedVoiceMemo) -> some View {
        let selected = selectedMemoIds.contains(memo.id)
        let projectTitle = projectTitleById[memo.projectId] ?? "Deleted song"

        return Button {
            toggleMemoSelection(memo.id)
        } label: {
            HStack(spacing: RhymeAITokens.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: RhymeAITokens.Radius.sm, style: .continuous)
                        .fill(appearance.palette.raisedSurface)

                    Image(systemName: "mic")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(appearance.palette.secondaryInk)
                }
                .frame(width: RhymeAITokens.Touch.comfortable, height: RhymeAITokens.Touch.comfortable)

                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                    Text(recordingDisplayName(memo.originalName))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(rowLineLimit)

                    Text("\(projectTitle) · \(trashRemainingText(deleteAfter: memo.deleteAfter))")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.secondaryInk)
                        .lineLimit(rowLineLimit)
                }
                .multilineTextAlignment(.leading)

                Spacer(minLength: RhymeAITokens.Spacing.sm)

                selectionCircle(selected: selected)
            }
            .frame(minHeight: 76)
            .padding(.horizontal, RhymeAITokens.Spacing.md)
            .padding(.vertical, RhymeAITokens.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.rhymePress)
        .accessibilityLabel(recordingDisplayName(memo.originalName))
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private static let recordingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Human-readable name for a trashed recording: renamed files keep their
    /// name, raw millisecond-timestamp names render as a date (drawer parity).
    private func recordingDisplayName(_ originalName: String) -> String {
        let stem = (originalName as NSString).deletingPathExtension
        if stem.count == 13, stem.allSatisfy(\.isNumber), let ms = Double(stem) {
            return Self.recordingDateFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        return stem
    }

    private func reloadTrashedMemos() {
        trashedMemos = RecordingFiles.trashedMemos()
        selectedMemoIds.formIntersection(Set(trashedMemos.map(\.id)))
    }

    /// One line at standard sizes; room to wrap at accessibility sizes, where
    /// a single line cut titles and the days-left note short.
    private var rowLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }

    private var bottomActionBar: some View {
        // Side by side at standard sizes; stacked at accessibility sizes,
        // where half the width truncated the labels to "Rest…" and "Dele…".
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: RhymeAITokens.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: RhymeAITokens.Spacing.sm))
        return layout {
            Button {
                restoreSelected()
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(activeSelectionCount == 0)

            Button(role: .destructive) {
                confirmPermanentDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    // The prominent style draws white on the action fill,
                    // which is warm white on Graphite.
                    .foregroundStyle(appearance.palette.onAction)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .disabled(activeSelectionCount == 0)
        }
        .padding(.horizontal, RhymeAITokens.Spacing.md)
        .padding(.top, RhymeAITokens.Spacing.sm)
        .padding(.bottom, RhymeAITokens.Spacing.sm)
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .liquidGlassSurface(cornerRadius: 0)
    }

    /// On regular width the screen keeps the editor's 740pt column, centred.
    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? RhymeAITokens.Layout.editorMaxWidth : .infinity
    }

    private func restoreSelected() {
        if activeTab == .projects {
            let projects = selectedProjects
            projects.forEach { _ = viewModel.restoreTrashedProject($0) }
        } else {
            selectedMemos.forEach(viewModel.voiceMemoService.restoreTrashedMemo)
            reloadTrashedMemos()
        }
        clearSelectionWithFeedback()
    }

    private func deleteSelectedForever() {
        if activeTab == .projects {
            let projects = selectedProjects
            projects.forEach { _ = viewModel.permanentlyDeleteTrashedProject($0) }
        } else {
            selectedMemos.forEach { _ = viewModel.permanentlyDeleteTrashedMemo($0) }
            reloadTrashedMemos()
        }
        clearSelectionWithFeedback()
    }

    private func selectionCircle(selected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? appearance.palette.action : appearance.palette.outlineStrong, lineWidth: 2)
                .background(
                    Circle()
                        .fill(appearance.palette.action)
                        .scaleEffect(selected ? 1 : 0.72)
                        .opacity(selected ? 1 : 0)
                )

            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    // The circle is a fixed 26pt, so the tick must not
                    // outgrow it at accessibility text sizes.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(appearance.palette.onAction)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.72).combined(with: .opacity))
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

    private func toggleMemoSelection(_ id: String) {
        withRhymeAnimation(RhymeAITokens.Motion.feedback, reduceMotion: reduceMotion) {
            if selectedMemoIds.contains(id) {
                selectedMemoIds.remove(id)
            } else {
                selectedMemoIds.insert(id)
            }
        }
    }

    private func clearSelectionWithFeedback() {
        withRhymeAnimation(RhymeAITokens.Motion.feedback, reduceMotion: reduceMotion) {
            selectedIds.removeAll()
            selectedMemoIds.removeAll()
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
