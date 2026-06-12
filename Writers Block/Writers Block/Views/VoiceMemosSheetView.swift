import SwiftUI

// Sheet that lists, plays, and records voice memos for the current song.
// Presented from the mic button in EditorView's top bar.
//
// The VoiceMemoService is accessed via viewModel.voiceMemoService rather than
// a separate @ObservedObject property — that avoids ObservableObject synthesis
// issues under -default-isolation=MainActor while still reacting to @Published
// changes because EditorViewModel's @Published voiceMemoService changes cause
// view updates through the existing @EnvironmentObject chain.
// The service's own @Published properties drive UI updates via the service
// reference held on the ObservableObject viewModel chain.
struct VoiceMemosSheetView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    let projectId: String
    let onDismiss: () -> Void

    // Memo list is re-derived whenever this view appears or after record/delete
    // so the list stays in sync without a separate observable.
    @State private var memos: [URL] = []

    private var service: VoiceMemoService { viewModel.voiceMemoService }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if memos.isEmpty && !service.isRecording {
                    emptyState
                } else {
                    memoList
                }

                Divider()
                recordingBar
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("Voice Memos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close voice memos")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { reloadMemos() }
        .alert("Microphone Access Denied", isPresented: Bindable(service).permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow microphone access in Settings to record melody ideas.")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: RhymeAITokens.Spacing.md) {
            Spacer()
            Image(systemName: "mic.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No memos yet")
                .font(.headline)
            Text("Tap the mic to record a melody idea.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(RhymeAITokens.Spacing.xl)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Memo List

    private var memoList: some View {
        ScrollView {
            LazyVStack(spacing: RhymeAITokens.Spacing.xs) {
                ForEach(memos, id: \.absoluteString) { url in
                    MemoRowView(
                        url: url,
                        onTogglePlay: { service.togglePlayback(url: url) },
                        onDelete: {
                            service.deleteMemo(at: url)
                            reloadMemos()
                        }
                    )
                }
            }
            .padding(RhymeAITokens.Spacing.md)
            .liquidGlassGroup(spacing: RhymeAITokens.Spacing.xs)
        }
    }

    // MARK: - Recording Bar

    private var recordingBar: some View {
        HStack(spacing: RhymeAITokens.Spacing.md) {
            if service.isRecording {
                // Red pulsing dot + elapsed time shown outside the sheet
                // so the user knows how long they've been recording.
                HStack(spacing: RhymeAITokens.Spacing.xs) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text(formattedElapsed)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .transition(.opacity)
            }

            Spacer()

            Button {
                Task {
                    if service.isRecording {
                        service.stopRecording()
                        reloadMemos()
                    } else {
                        await service.startRecording(projectId: projectId)
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(service.isRecording ? Color.red : Color.accentColor)
                        .frame(width: RhymeAITokens.Touch.comfortable, height: RhymeAITokens.Touch.comfortable)
                    Image(systemName: service.isRecording ? "stop.fill" : "mic.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel(service.isRecording ? "Stop recording" : "Start recording")
            .accessibilityIdentifier("voiceMemoRecordButton")
        }
        .padding(.horizontal, RhymeAITokens.Spacing.md)
        .padding(.vertical, RhymeAITokens.Spacing.sm)
        .liquidGlassSurface(cornerRadius: 0, fallbackOpacity: 0.02)
    }

    // MARK: - Helpers

    private func reloadMemos() {
        memos = VoiceMemoService.memos(for: projectId)
    }

    private var formattedElapsed: String {
        let total = Int(service.recordingElapsed)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Memo Row

private struct MemoRowView: View {
    let url: URL
    let onTogglePlay: () -> Void
    let onDelete: () -> Void

    // Each row tracks its own playing state. The service serialises playback —
    // tapping a second row stops the first and starts the new one — so the
    // worst case is both rows briefly show "playing" for one render cycle.
    @State private var rowIsPlaying = false

    var body: some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            // Play / Pause
            Button {
                rowIsPlaying.toggle()
                onTogglePlay()
            } label: {
                Image(systemName: rowIsPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(rowIsPlaying ? .red : .accentColor)
                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
            }
            .accessibilityLabel(rowIsPlaying ? "Pause memo" : "Play memo")

            VStack(alignment: .leading, spacing: 2) {
                Text(formattedDate)
                    .font(.subheadline.weight(.medium))
                if let size = fileSize {
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Delete
            Button(role: .destructive) {
                rowIsPlaying = false
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.red.opacity(0.75))
                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
            }
            .accessibilityLabel("Delete memo")
        }
        .padding(.horizontal, RhymeAITokens.Spacing.sm)
        .padding(.vertical, RhymeAITokens.Spacing.xs)
        .liquidGlassSurface(
            cornerRadius: RhymeAITokens.Radius.sm,
            tint: .white.opacity(0.03),
            fallbackOpacity: 0.05
        )
    }

    // Derive human-readable date from the millisecond timestamp filename.
    private var formattedDate: String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let ms = Double(stem) {
            let date = Date(timeIntervalSince1970: ms / 1000)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return stem
    }

    private var fileSize: String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.0f KB", kb)
        }
        return String(format: "%.1f MB", kb / 1024)
    }
}
