import AVFoundation
import Foundation
import Observation
import os
import Speech

/// Records one quick line to an .m4a while on-device speech recognition
/// transcribes it live. One AVAudioEngine tap feeds both, so the file and the
/// words come from the same microphone input. Shares the memo service's serial
/// audio-session queue so activation and deactivation never interleave with a
/// voice memo's.
@Observable
final class OneLinerRecorder {
    /// Permissions or the audio session are still being set up.
    private(set) var isStarting = false
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    /// Latest live transcription of this take; empty until words arrive.
    private(set) var transcript = ""
    /// Recent input levels 0...1, oldest first, for the level bars.
    private(set) var levels: [Float] = Array(repeating: 0, count: OneLinerRecorder.levelCount)
    /// The take this recorder holds (recording or finished); nil when there is none.
    private(set) var fileURL: URL?
    /// Length of the finished take, fixed when it stops.
    private(set) var takeDuration: Double = 0
    /// Why recording or transcription is off, or why a take stopped; nil while everything works.
    var notice: String?

    static let levelCount = 12

    @ObservationIgnored private let sessionTransitions: VoiceMemoAudioSessionTransitions
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    /// Each start, stop and discard moves it on; a start that finds it moved after
    /// an await was cancelled and undoes what it set up.
    @ObservationIgnored private var generation: UInt64 = 0
    /// The file a start is creating, known before the engine runs so a failed or
    /// cancelled start can remove it.
    @ObservationIgnored private var pendingURL: URL?

    init(sessionTransitions: VoiceMemoAudioSessionTransitions = .shared) {
        self.sessionTransitions = sessionTransitions
    }

    /// Starts recording into `url`. Returns false (with `notice` set) when the
    /// microphone is unavailable or the start was cancelled; a missing speech
    /// permission only turns off the live transcript. A second call while one
    /// is starting or recording is ignored.
    @discardableResult
    func start(writingTo url: URL) async -> Bool {
        guard !isStarting, !isRecording else { return false }
        generation &+= 1
        let owner = generation
        isStarting = true
        notice = nil

        guard await Self.microphoneGranted() else {
            guard owner == generation else { return false }
            isStarting = false
            notice = "Microphone access is off. Turn it on in Settings, or type the line."
            return false
        }
        guard owner == generation else { return false }
        let recognizer = await Self.onDeviceRecognizer()
        guard owner == generation else { return false }

        let activation: Result<Void, Error> = await withCheckedContinuation { continuation in
            sessionTransitions.activateRecording { continuation.resume(returning: $0) }
        }
        guard owner == generation else {
            if case .success = activation { sessionTransitions.deactivate() }
            return false
        }
        guard case .success = activation else { return failToStart() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return failToStart() }
        pendingURL = url
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
        } else {
            notice = "Live transcription isn't available on this device. The audio is still saved."
        }

        Self.installTap(
            on: input,
            format: format,
            file: file,
            request: request,
            level: { [weak self] level in
                Task { @MainActor [weak self] in self?.pushLevel(level) }
            },
            writeFailed: { [weak self] in
                Task { @MainActor [weak self] in self?.failTake(owner: owner) }
            }
        )
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return failToStart()
        }
        self.engine = engine
        observeInterruptions()
        fileURL = url
        pendingURL = nil
        transcript = ""
        takeDuration = 0
        startedAt = Date()
        isStarting = false
        isRecording = true
        return true
    }

    /// Stops the take (or cancels a start) and returns its length in seconds;
    /// the file stays at `fileURL`.
    @discardableResult
    func stop() -> Double {
        generation &+= 1
        if isRecording, let startedAt {
            takeDuration = Date().timeIntervalSince(startedAt)
        }
        tearDown()
        return takeDuration
    }

    /// Stops or cancels, and removes the take's file.
    func discard() {
        generation &+= 1
        tearDown()
        removeTakeFiles()
        takeDuration = 0
    }

    private func tearDown() {
        let wasActive = engine != nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        // Releasing the file finalizes the .m4a.
        file = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        isStarting = false
        isRecording = false
        startedAt = nil
        levels = Array(repeating: 0, count: Self.levelCount)
        if wasActive { sessionTransitions.deactivate() }
    }

    private func removeTakeFiles() {
        for url in [fileURL, pendingURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        fileURL = nil
        pendingURL = nil
    }

    /// A start that failed after the session was activated: nothing it made is kept.
    private func failToStart() -> Bool {
        tearDown()
        removeTakeFiles()
        sessionTransitions.deactivate()
        notice = "Couldn't start recording. Check the microphone and try again."
        return false
    }

    /// The audio could not be written (for example the disk is full): the take is
    /// unusable, so it is stopped and removed; the words already transcribed stay.
    private func failTake(owner: UInt64) {
        guard owner == generation, isRecording else { return }
        generation &+= 1
        tearDown()
        removeTakeFiles()
        takeDuration = 0
        notice = "Recording stopped because the audio couldn't be saved. The words so far are kept."
    }

    /// A call, Siri or another app took the microphone: the take ends where it was.
    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.stop()
                self.notice = "Recording stopped by an interruption. The take so far is kept."
            }
        }
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
        level: @escaping @Sendable (Float) -> Void,
        writeFailed: @escaping @Sendable () -> Void
    ) {
        let failed = OSAllocatedUnfairLock(initialState: false)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            guard !failed.withLock({ $0 }) else { return }
            do {
                try file?.write(from: buffer)
            } catch {
                failed.withLock { $0 = true }
                writeFailed()
                return
            }
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

/// Plays one line's take at a time. Kept apart from the memo service, whose
/// playback only accepts files the recordings library tracks.
@Observable
final class OneLinerPlayer {
    /// The file playing (or about to play), if any.
    private(set) var playingURL: URL?
    var lastError: String?

    @ObservationIgnored private let sessionTransitions: VoiceMemoAudioSessionTransitions
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: OneLinerPlayerDelegate?
    @ObservationIgnored private var revision: UInt64 = 0

    init(sessionTransitions: VoiceMemoAudioSessionTransitions = .shared) {
        self.sessionTransitions = sessionTransitions
    }

    func toggle(_ url: URL) {
        if playingURL == url {
            stop()
            return
        }
        stop()
        revision &+= 1
        let owner = revision
        playingURL = url
        sessionTransitions.activatePlayback { [weak self] result in
            Task { @MainActor [weak self] in self?.begin(url, owner: owner, activation: result) }
        }
    }

    func stop() {
        revision &+= 1
        let hadPlayback = playingURL != nil
        player?.stop()
        player = nil
        delegate = nil
        playingURL = nil
        if hadPlayback { sessionTransitions.deactivate() }
    }

    private func begin(_ url: URL, owner: UInt64, activation: Result<Void, Error>) {
        guard owner == revision else { return }
        guard case .success = activation, let player = try? AVAudioPlayer(contentsOf: url) else {
            stop()
            lastError = "This take couldn't be played."
            return
        }
        let delegate = OneLinerPlayerDelegate { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.revision == owner else { return }
                self.stop()
            }
        }
        player.delegate = delegate
        guard player.play() else {
            stop()
            lastError = "This take couldn't be played."
            return
        }
        self.player = player
        self.delegate = delegate
    }
}

// AVFoundation delegate protocols are @objc and require NSObject.
private final class OneLinerPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    private let finished: @Sendable () -> Void

    init(finished: @escaping @Sendable () -> Void) {
        self.finished = finished
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finished()
    }
}
