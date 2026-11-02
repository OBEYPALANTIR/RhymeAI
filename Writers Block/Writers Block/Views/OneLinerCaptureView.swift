import SwiftUI
import UIKit

enum OneLinerCaptureMode: Identifiable {
    case record
    case type
    /// New words for a saved line; no microphone.
    case edit(OneLiner)

    var id: String {
        switch self {
        case .record: "record"
        case .type: "type"
        case .edit(let line): "edit-\(line.id)"
        }
    }

    var isEdit: Bool {
        if case .edit = self { return true }
        return false
    }
}

/// What a capture saved: the line, plus its take when one was recorded.
struct OneLinerCapture {
    let text: String
    /// The take's pending file; the store adopts it on a successful save.
    let take: URL?
    let audioDuration: Double
}

/// Quick capture sheet. Record mode starts the microphone on open and
/// transcribes on the device into the field; Type and Edit open with the keyboard.
struct OneLinerCaptureView: View {
    let mode: OneLinerCaptureMode
    /// Where a new take is written until a save adopts it.
    let pendingRoot: URL
    /// A voice memo already holds the microphone; record mode falls back to typing.
    var microphoneBusy = false
    /// Persists the capture; a throw keeps the sheet, the words and the take.
    let onSave: (OneLinerCapture) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appAppearanceStyle) private var appearance
    @State private var recorder = OneLinerRecorder()
    @State private var text = ""
    /// The field's text when the current take started; the transcript follows it.
    @State private var textBeforeTake = ""
    @State private var saved = false
    @State private var saveError: String?
    @FocusState private var fieldFocused: Bool

    private var palette: AppAppearancePalette { appearance.palette }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        mode.isEdit ? !trimmedText.isEmpty : (!trimmedText.isEmpty || recorder.fileURL != nil)
    }
    private var canRecord: Bool { !mode.isEdit && !microphoneBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.standard) {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                Text(mode.isEdit ? "Edit one liner" : "New one liner")
                    .font(.footnote.weight(.semibold))
                Text(mode.isEdit ? "Change the words. A recorded take stays as it was." : "Lands in One Liners. Pick a song later, or never.")
                    .font(.footnote)
            }
            .foregroundStyle(palette.secondaryInk)

            TextField(
                mode.isEdit ? "Edit one liner" : "New one liner",
                text: $text,
                prompt: Text("Say it or type it").foregroundStyle(palette.placeholder),
                axis: .vertical
            )
            .font(.title2)
            .lineLimit(2...6)
            .foregroundStyle(palette.primaryInk)
            .tint(palette.caret)
            .focused($fieldFocused)
            .padding(.bottom, RhymeAITokens.Rhythm.related)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.outline)
                    .frame(height: RhymeAITokens.Spacing.hairline)
            }

            if recorder.isRecording {
                recordingRow
            }

            if let notice = saveError ?? recorder.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(saveError == nil ? palette.secondaryInk : palette.error)
            }

            Spacer(minLength: 0)

            actionRow
        }
        .padding(.horizontal, RhymeAITokens.Rhythm.standard)
        .padding(.top, RhymeAITokens.Rhythm.section)
        .padding(.bottom, RhymeAITokens.Rhythm.related)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.surface)
        .presentationDetents([.fraction(0.62), .large])
        .presentationDragIndicator(.visible)
        .onChange(of: recorder.transcript) { _, transcript in
            guard !transcript.isEmpty else { return }
            text = textBeforeTake.isEmpty ? transcript : textBeforeTake + " " + transcript
        }
        // Leaving the app ends the take where it is (and cancels one still starting),
        // so the microphone and the clock never run on in the background.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, recorder.isRecording || recorder.isStarting else { return }
            let wasRecording = recorder.isRecording
            recorder.stop()
            if wasRecording { recorder.notice = "Recording stopped when Writers Block went to the background. The take so far is kept." }
        }
        .task {
            if case .edit(let line) = mode { text = line.text }
            if case .record = mode, !microphoneBusy {
                await startTake()
            } else {
                if case .record = mode {
                    recorder.notice = "A voice memo is recording. Stop it to record here, or type the line."
                }
                fieldFocused = true
            }
        }
        .onDisappear {
            // Closed without saving: the take is not kept.
            if !saved { recorder.discard() }
        }
    }

    private var recordingRow: some View {
        HStack(spacing: RhymeAITokens.Rhythm.related) {
            Circle()
                .fill(palette.recording)
                .frame(width: 8, height: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.durationText(context.date.timeIntervalSince(recorder.startedAt ?? context.date)))
                    .font(.footnote.monospacedDigit())
                    .monospaced()
            }
            HStack(spacing: 3) {
                ForEach(Array(recorder.levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(palette.outlineStrong)
                        .frame(width: 3, height: max(5, CGFloat(level) * 34))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .animation(.linear(duration: 0.08), value: recorder.levels)
            Text("Listening")
                .font(.footnote)
        }
        .foregroundStyle(palette.secondaryInk)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, listening")
    }

    private var actionRow: some View {
        HStack(spacing: RhymeAITokens.Rhythm.related) {
            Button {
                fieldFocused.toggle()
            } label: {
                roundGlyph("keyboard", stroke: palette.outline, ink: palette.primaryInk)
            }
            .buttonStyle(.rhymePress)
            .accessibilityLabel(fieldFocused ? "Hide keyboard" : "Switch to keyboard")

            if recorder.isRecording {
                Button {
                    recorder.stop()
                } label: {
                    ZStack {
                        Circle().fill(palette.surface)
                        Circle().strokeBorder(palette.recording, lineWidth: 1)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(palette.recording)
                            .frame(width: 18, height: 18)
                    }
                    .frame(width: RhymeAITokens.Rhythm.primary, height: RhymeAITokens.Rhythm.primary)
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Stop recording")
            } else if recorder.fileURL == nil && canRecord {
                Button {
                    Task { await startTake() }
                } label: {
                    roundGlyph("mic", stroke: palette.outline, ink: palette.primaryInk)
                }
                .buttonStyle(.rhymePress)
                .disabled(recorder.isStarting)
                .accessibilityLabel("Record")
            }

            Spacer(minLength: 0)

            Button(action: save) {
                Text("Save")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, RhymeAITokens.Rhythm.section)
                    .frame(minHeight: RhymeAITokens.Rhythm.primary)
                    .foregroundStyle(palette.onAction)
                    .background(palette.action, in: Capsule())
                    .opacity(canSave ? 1 : 0.4)
            }
            .buttonStyle(.rhymePress)
            .disabled(!canSave)
        }
    }

    private func roundGlyph(_ systemName: String, stroke: Color, ink: Color) -> some View {
        Image(systemName: systemName)
            .font(.title3.weight(.medium))
            .foregroundStyle(ink)
            .frame(width: RhymeAITokens.Rhythm.primary, height: RhymeAITokens.Rhythm.primary)
            .background(palette.surface, in: Circle())
            .overlay(Circle().strokeBorder(stroke, lineWidth: 1))
    }

    private func startTake() async {
        textBeforeTake = trimmedText
        let url = pendingRoot.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
        if !(await recorder.start(writingTo: url)), !recorder.isRecording {
            fieldFocused = true
        }
    }

    private func save() {
        if recorder.isRecording || recorder.isStarting {
            // The audio failed to write: stay open so the notice is read before saving words alone.
            guard recorder.stop() else { return }
        }
        guard canSave else { return }
        do {
            try onSave(OneLinerCapture(text: trimmedText, take: recorder.fileURL, audioDuration: recorder.takeDuration))
        } catch {
            // The sheet, the words and the take stay for another try, from wherever the take now is.
            if let failure = error as? OneLinerSaveFailure, let takeNowAt = failure.takeNowAt {
                recorder.takeMoved(to: takeNowAt)
            }
            saveError = "Couldn't save this line. It's still here, so try again."
            return
        }
        saved = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    /// "0:04", "1:12".
    static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
