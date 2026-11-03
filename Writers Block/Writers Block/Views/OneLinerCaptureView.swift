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

/// The sheet's recording controls for the recorder's state.
struct OneLinerCaptureControls: Equatable {
    /// A finished take of a new capture: its length and Discard take.
    var takeRow: Bool
    /// The mic glyph that starts a take.
    var record: Bool

    init(isEdit: Bool, microphoneBusy: Bool, isRecording: Bool, hasTake: Bool) {
        // Edit never records, so it never holds a new take.
        takeRow = !isEdit && !isRecording && hasTake
        record = !isEdit && !microphoneBusy && !isRecording && !hasTake
    }
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
    /// The field as the transcript last left it; any other text is the writer's edit.
    @State private var transcribedText = ""
    @State private var saved = false
    @State private var saveError: String?
    /// This sheet's place in the router's open captures.
    @State private var captureID = UUID()
    @FocusState private var fieldFocused: Bool

    private var palette: AppAppearancePalette { appearance.palette }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        mode.isEdit ? !trimmedText.isEmpty : (!trimmedText.isEmpty || recorder.fileURL != nil)
    }
    private var controls: OneLinerCaptureControls {
        OneLinerCaptureControls(
            isEdit: mode.isEdit,
            microphoneBusy: microphoneBusy,
            isRecording: recorder.isRecording,
            hasTake: recorder.fileURL != nil
        )
    }

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
            } else if controls.takeRow {
                takeRow
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
            guard let next = Self.fieldText(current: text, lastTranscribed: transcribedText, beforeTake: textBeforeTake, transcript: transcript.text) else { return }
            text = next
            transcribedText = next
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
        .onAppear {
            OneLinerRouter.shared.captureAppeared(captureID)
            takeRequest()
        }
        .onChange(of: OneLinerRouter.shared.pending) { _, _ in takeRequest() }
        .onDisappear {
            OneLinerRouter.shared.captureDisappeared(captureID)
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

    /// The stopped take that Save keeps. Discarding drops only the audio; the words stay.
    private var takeRow: some View {
        HStack(spacing: RhymeAITokens.Rhythm.related) {
            HStack(spacing: RhymeAITokens.Rhythm.related) {
                Image(systemName: "waveform")
                    .font(.footnote.weight(.medium))
                Text("Take")
                    .font(.footnote)
                Text(Self.durationText(recorder.takeDuration))
                    .font(.footnote.monospacedDigit())
                    .monospaced()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Take, \(Self.durationText(recorder.takeDuration))")

            Spacer(minLength: 0)

            Button(action: discardTake) {
                Text("Discard take")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.action)
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
            }
            .buttonStyle(.rhymePress)
            .accessibilityHint("Removes the recording. The words stay.")
        }
        .foregroundStyle(palette.secondaryInk)
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
            } else if controls.record {
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

    /// The Live Activity's Done stops and saves this take, as the Save button does.
    /// Another Record or Type while this sheet is open never replaces it.
    private func takeRequest() {
        let router = OneLinerRouter.shared
        guard router.openCaptures.contains(captureID), let action = router.pending else { return }
        switch action {
        case .stopRecording:
            guard router.recordingOwner == recorder.id, router.take([.stopRecording]) != nil else { return }
            save()
        case .record, .type:
            _ = router.take([.record, .type])
            recorder.notice = Self.finishFirstNotice
        case .open:
            _ = router.take([.open])
        }
    }

    static let finishFirstNotice = "Finish this one liner first. Save it or close it, then try again."

    private func startTake() async {
        textBeforeTake = trimmedText
        transcribedText = text
        let url = pendingRoot.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
        if !(await recorder.start(writingTo: url)), !recorder.isRecording {
            fieldFocused = true
        }
    }

    /// Removes the stopped take's file, as closing without saving does; the words stay
    /// and the mic comes back for another take.
    private func discardTake() {
        recorder.discard()
        // A notice about the take ("The take so far is kept") no longer applies.
        recorder.notice = nil
    }

    private func save() {
        if recorder.isRecording || recorder.isStarting {
            // The audio failed to write: stay open so the notice is read before saving words alone.
            guard recorder.stop(endingActivity: false) else { return }
        }
        guard canSave else {
            recorder.endActivity(.stopped)
            return
        }
        do {
            try onSave(OneLinerCapture(text: trimmedText, take: recorder.fileURL, audioDuration: recorder.takeDuration))
            recorder.endActivity(.saved)
        } catch {
            recorder.endActivity(.stopped)
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

    /// The field after a transcript update: the words from before the take, then the
    /// take's words. Nil when there are no words yet, or when the writer changed the
    /// field since the transcript last set it; their edit wins for the rest of the take.
    static func fieldText(current: String, lastTranscribed: String, beforeTake: String, transcript: String) -> String? {
        guard !transcript.isEmpty, current == lastTranscribed else { return nil }
        return beforeTake.isEmpty ? transcript : beforeTake + " " + transcript
    }

    /// "0:04", "1:12".
    static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
