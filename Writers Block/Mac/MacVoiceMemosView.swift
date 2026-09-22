import SwiftUI
import UniformTypeIdentifiers

struct MacVoiceMemosView: View {
    @EnvironmentObject private var editor: EditorViewModel
    @State private var recordings: [URL] = []
    @State private var showingImporter = false
    @State private var importProjectId: String?
    @State private var importTask: Task<Void, Never>?
    @State private var isImporting = false
    @State private var importError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recordings").font(.title2.bold())
            if editor.voiceMemoService.isRecording {
                Text("Recording \(Int(editor.voiceMemoService.recordingElapsed)) seconds")
                Button("Stop Recording") { editor.voiceMemoService.stopRecording(); refresh() }
            } else {
                Button("Record Memo") {
                    guard let id = editor.ensureProjectForRecording() else { return }
                    Task { await editor.voiceMemoService.startRecording(projectId: id) }
                }
                .disabled(isImporting)
                Button("Import Recording") {
                    importProjectId = editor.currentProjectId
                    importError = nil
                    showingImporter = true
                }
                .disabled(isImporting)
                .accessibilityIdentifier("importRecordingButton")
            }
            if isImporting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Importing recording…")
                    Button("Cancel") { importTask?.cancel() }
                }
            }
            if editor.voiceMemoService.permissionDenied { Text("Microphone access is off. Enable Writers Block in System Settings → Privacy & Security → Microphone.").font(.caption) }
            if let error = importError ?? editor.voiceMemoService.lastError { Text(error).foregroundStyle(.red) }
            if recordings.isEmpty { Text("Record a melody or import audio for this song.").foregroundStyle(.secondary) }
            Text("Import M4A, MP3, WAV, or AAC files up to 100 MB. Your original file stays where it is.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(recordings, id: \.self) { url in
                        HStack {
                            Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                            Spacer()
                            Button(editor.voiceMemoService.isPlayingMemo(at: url) ? "Stop" : "Play") {
                                editor.voiceMemoService.togglePlayback(url: url)
                            }
                            .disabled(editor.voiceMemoService.isRecording)
                            .accessibilityLabel("\(editor.voiceMemoService.isPlayingMemo(at: url) ? "Stop" : "Play") \(url.deletingPathExtension().lastPathComponent)")
                        }
                    }
                }
            }.frame(maxHeight: 240)
        }.padding(24).frame(width: 410)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: RecordingFiles.supportedAudioExtensions.sorted().compactMap { UTType(filenameExtension: $0) }) { result in
            switch result {
            case .success(let source):
                guard let projectId = importProjectId ?? editor.ensureProjectForRecording() else { return }
                isImporting = true
                importTask = Task { @MainActor in
                    defer { isImporting = false; importTask = nil }
                    do {
                        _ = try await VoiceMemoService.importMemo(from: source, projectId: projectId)
                        refresh()
                    } catch is CancellationError {
                        // Cancellation leaves the source intact and removes staging files.
                    } catch VoiceMemoService.ImportError.tooLarge {
                        importError = "Choose a recording smaller than 100 MB."
                    } catch {
                        importError = "Couldn't import this recording. Choose a playable M4A, MP3, WAV, or AAC file."
                    }
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    importError = "Couldn't open the recording. Try choosing it again."
                }
            }
        }
        .task { refresh() }
        .onDisappear {
            importTask?.cancel()
            editor.voiceMemoService.stopRecording()
            editor.voiceMemoService.stopPlayback()
        }
        .onChange(of: editor.currentProjectId) {
            editor.voiceMemoService.stopRecording()
            editor.voiceMemoService.stopPlayback()
            refresh()
        }
        .onChange(of: editor.voiceMemoService.isRecording) { refresh() }
    }
    private func refresh() { recordings = editor.currentProjectId.map { RecordingFiles.memos(for: $0) } ?? [] }
}
