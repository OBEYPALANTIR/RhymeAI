import SwiftUI

struct MacVoiceMemosView: View {
    @EnvironmentObject private var editor: EditorViewModel
    @State private var recordings: [URL] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Voice Memos").font(.title2.bold())
            if editor.voiceMemoService.isRecording {
                Text("Recording \(Int(editor.voiceMemoService.recordingElapsed)) seconds")
                Button("Stop Recording") { editor.voiceMemoService.stopRecording(); refresh() }
            } else {
                Button("Record Memo") {
                    guard let id = editor.ensureProjectForRecording() else { return }
                    Task { await editor.voiceMemoService.startRecording(projectId: id) }
                }
            }
            if editor.voiceMemoService.permissionDenied { Text("Microphone access is off. Enable Writers Block in System Settings → Privacy & Security → Microphone.").font(.caption) }
            if let error = editor.voiceMemoService.lastError { Text(error).foregroundStyle(.red) }
            if recordings.isEmpty { Text("Record a melody or a lyric idea for this song.").foregroundStyle(.secondary) }
            ForEach(recordings, id: \.self) { url in
                HStack {
                    Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer()
                    Button("Play / Stop") { editor.voiceMemoService.togglePlayback(url: url) }
                }
            }
        }.padding(24).frame(width: 370)
        .task { refresh() }
        .onDisappear { editor.voiceMemoService.stopRecording(); editor.voiceMemoService.stopPlayback() }
        .onChange(of: editor.currentProjectId) { refresh() }
    }
    private func refresh() { recordings = editor.currentProjectId.map { VoiceMemoService.memos(for: $0) } ?? [] }
}
