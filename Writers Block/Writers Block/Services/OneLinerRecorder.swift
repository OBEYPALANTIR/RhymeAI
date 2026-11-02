import AVFoundation
import Foundation
import Observation
import Speech

/// Records one quick line to an .m4a under the One Liners audio root while
/// on-device speech recognition transcribes it live. One AVAudioEngine tap
/// feeds both, so the file and the words come from the same microphone input.
/// Shares the memo service's serial audio-session queue so activation and
/// deactivation never interleave with a voice memo's.
@Observable
final class OneLinerRecorder {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// Latest live transcription of this take; empty until words arrive.
    private(set) var transcript = ""
    /// Recent input levels 0...1, oldest first, for the level bars.
    private(set) var levels: [Float] = Array(repeating: 0, count: OneLinerRecorder.levelCount)
    /// Why recording or transcription is off; nil while everything works.
    var notice: String?

    static let levelCount = 12

    @ObservationIgnored private let sessionTransitions: VoiceMemoAudioSessionTransitions
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private(set) var fileURL: URL?

    init(sessionTransitions: VoiceMemoAudioSessionTransitions = .shared) {
        self.sessionTransitions = sessionTransitions
    }

    /// Starts recording into `url`. Returns false (with `notice` set) when the
    /// microphone is unavailable; a missing speech permission only turns off
    /// the live transcript.
    @discardableResult
    func start(writingTo url: URL) async -> Bool {
        guard !isRecording else { return true }
        guard await Self.microphoneGranted() else {
            notice = "Microphone access is off. Turn it on in Settings, or type the line."
            return false
        }
        let recognizer = await Self.onDeviceRecognizer()

        let activation: Result<Void, Error> = await withCheckedContinuation { continuation in
            sessionTransitions.activateRecording { continuation.resume(returning: $0) }
        }
        guard case .success = activation else { return failToStart() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return failToStart() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // AAC in MPEG-4, as voice memos are recorded.
            file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ],
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            return failToStart()
        }

        if let recognizer {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request
            task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
                guard let text = result?.bestTranscription.formattedString else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.transcript = text
                }
            }
        } else if notice == nil {
            notice = "Live transcription isn't available on this device. The audio is still saved."
        }

        Self.installTap(on: input, format: format, file: file, request: request) { [weak self] level in
            Task { @MainActor [weak self] in self?.pushLevel(level) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return failToStart()
        }
        self.engine = engine
        fileURL = url
        transcript = ""
        startedAt = Date()
        isRecording = true
        return true
    }

    /// Stops the take and returns its length in seconds; the file stays at `fileURL`.
    @discardableResult
    func stop() -> Double {
        guard isRecording else { return 0 }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        tearDown()
        return duration
    }

    /// Stops and removes the take's file.
    func discard() {
        tearDown()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    private func tearDown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        // Releasing the file finalizes the .m4a.
        file = nil
        let wasActive = isRecording
        isRecording = false
        startedAt = nil
        levels = Array(repeating: 0, count: Self.levelCount)
        if wasActive { sessionTransitions.deactivate() }
    }

    private func failToStart() -> Bool {
        tearDown()
        sessionTransitions.deactivate()
        notice = "Couldn't start recording. Check the microphone and try again."
        return false
    }

    private func pushLevel(_ level: Float) {
        guard isRecording else { return }
        levels.removeFirst()
        levels.append(level)
    }

    // The tap runs on the audio render thread, so it is built outside the main actor.
    nonisolated private static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        file: AVAudioFile?,
        request: SFSpeechAudioBufferRecognitionRequest?,
        level: @escaping @Sendable (Float) -> Void
    ) {
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            try? file?.write(from: buffer)
            request?.append(buffer)
            level(normalizedLevel(buffer))
        }
    }

    /// RMS of the first channel mapped from -60...0 dB to 0...1, as the memo meter maps power.
    nonisolated private static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_001))
        return max(0, min(1, (decibels + 60) / 60))
    }

    private static func microphoneGranted() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        default: return false
        }
    }

    /// A recognizer that runs on the device, or nil when speech access is off
    /// or this device cannot transcribe offline. Nothing is sent to a server.
    private static func onDeviceRecognizer() async -> SFSpeechRecognizer? {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized,
              let recognizer = SFSpeechRecognizer(),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { return nil }
        return recognizer
    }
}
