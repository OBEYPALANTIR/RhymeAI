import SwiftUI
import UIKit

enum OneLinerCaptureMode: String, Identifiable {
    case record
    case type

    var id: String { rawValue }
}

/// What a capture saved: the line, plus its take when one was recorded.
struct OneLinerCapture {
    let text: String
    let audioFileName: String?
    let audioDuration: Double
}

/// Quick capture sheet. Record mode starts the microphone on open and
/// transcribes on the device into the field; Type mode opens with the keyboard.
struct OneLinerCaptureView: View {
    let mode: OneLinerCaptureMode
    let audioRoot: URL
    /// A voice memo already holds the microphone; record mode falls back to typing.
    var microphoneBusy = false
    let onSave: (OneLinerCapture) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAppearanceStyle) private var appearance
    @State private var recorder = OneLinerRecorder()
    @State private var text = ""
    /// The field's text when the current take started; the transcript follows it.
    @State private var textBeforeTake = ""
    @State private var takeDuration: Double = 0
    @State private var saved = false
    @FocusState private var fieldFocused: Bool

    private var palette: AppAppearancePalette { appearance.palette }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedText.isEmpty || recorder.fileURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.standard) {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                Text("New one liner")
                    .font(.footnote.weight(.semibold))
                Text("Lands in One Liners. Pick a song later, or never.")
                    .font(.footnote)
            }
            .foregroundStyle(palette.secondaryInk)

            TextField(
                "New one liner",
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

            if let notice = recorder.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryInk)
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
        .task {
            if mode == .record && !microphoneBusy {
                await startTake()
            } else {
                if mode == .record {
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
                Button(action: stopTake) {
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
            } else if recorder.fileURL == nil && !microphoneBusy {
                Button {
                    Task { await startTake() }
                } label: {
                    roundGlyph("mic", stroke: palette.outline, ink: palette.primaryInk)
                }
                .buttonStyle(.rhymePress)
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
        let url = audioRoot.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
        if !(await recorder.start(writingTo: url)) {
            fieldFocused = true
        }
    }

    private func stopTake() {
        takeDuration = recorder.stop()
    }

    private func save() {
        if recorder.isRecording { stopTake() }
        guard canSave else { return }
        saved = true
        onSave(OneLinerCapture(
            text: trimmedText,
            audioFileName: recorder.fileURL?.lastPathComponent,
            audioDuration: takeDuration
        ))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    /// "0:04", "1:12".
    static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
