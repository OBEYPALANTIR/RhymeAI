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
    /// The latest start's session activation, which also undoes itself when that
    /// start was cancelled. A new start waits for it, so an old cleanup can never
    /// deactivate the newer start's session.
    @ObservationIgnored private var pendingActivation: Task<Bool, Never>?
    /// This recorder's start activated the session and has not given it back.
    @ObservationIgnored private var sessionHeld = false
    /// Set on the audio thread the moment a write fails; read by `stop()` so a take
    /// that lost audio is never handed on, even before the main-actor notice runs.
    @ObservationIgnored private var writeFailed = OSAllocatedUnfairLock(initialState: false)

    /// True while any capture holds or is claiming the microphone; one-liner playback waits for it.
    static private(set) var isCapturing = false

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
        Self.isCapturing = true
        notice = nil
        OneLinerPlayer.stopAll()
        // An earlier cancelled start finishes undoing its activation first.
        if let previous = pendingActivation { _ = await previous.value }
        guard owner == generation else { return false }

        guard await Self.microphoneGranted() else {
            guard owner == generation else { return false }
            isStarting = false
            Self.isCapturing = false
            notice = "Microphone access is off. Turn it on in Settings, or type the line."
            return false
        }
        guard owner == generation else { return false }
        let recognizer = await Self.onDeviceRecognizer()
        guard owner == generation else { return false }

        let transitions = sessionTransitions
        let activation = Task { [weak self] () -> Bool in
            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                transitions.activateRecording { continuation.resume(returning: $0) }
            }
            guard case .success = result else { return false }
            // Cancelled meanwhile: give the session back before any newer start activates.
            guard let self, owner == self.generation else {
                transitions.deactivate()
                return false
            }
            // From here a stop or discard gives the session back (tearDown).
            self.sessionHeld = true
            return true
        }
        pendingActivation = activation
        let activated = await activation.value
        guard owner == generation else { return false }
        guard activated else { return failToStart() }

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

        writeFailed = OSAllocatedUnfairLock(initialState: false)
        Self.installTap(
            on: input,
            format: format,
            file: file,
            request: request,
            failed: writeFailed,
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

    /// Stops the take (or cancels a start); the file stays at `fileURL` and its length
    /// in `takeDuration`. Returns false when audio failed to write: the take is then
    /// removed and `notice` says so.
    @discardableResult
    func stop() -> Bool {
        generation &+= 1
        let wasRecording = isRecording
        if isRecording, let startedAt {
            takeDuration = Date().timeIntervalSince(startedAt)
        }
        tearDown()
        guard wasRecording, writeFailed.withLock({ $0 }) else { return true }
        removeTakeFiles()
        takeDuration = 0
        notice = Self.writeFailureNotice
        return false
    }

    /// Points the take at where a failed save left it, so a retry adopts it from there.
    func takeMoved(to url: URL) {
        fileURL = url
    }

    static let writeFailureNotice = "Recording stopped because the audio couldn't be saved. The words so far are kept."

    /// Stops or cancels, and removes the take's file.
    func discard() {
        generation &+= 1
        tearDown()
        removeTakeFiles()
        takeDuration = 0
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
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        isStarting = false
        isRecording = false
        Self.isCapturing = false
        startedAt = nil
        levels = Array(repeating: 0, count: Self.levelCount)
        if sessionHeld {
            sessionHeld = false
            sessionTransitions.deactivate()
        }
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
        notice = Self.writeFailureNotice
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
        failed: OSAllocatedUnfairLock<Bool>,
        level: @escaping @Sendable (Float) -> Void,
        writeFailed: @escaping @Sendable () -> Void
    ) {
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

    /// The player that last started, so a recording can silence it first.
    private static weak var current: OneLinerPlayer?

    /// Stops any one-liner take playing, before a microphone is opened.
    static func stopAll() {
        current?.stop()
    }

    /// Plays or stops the take. Refuses (returning false) while a voice memo or a
    /// one-liner capture is recording, so a take never plays into the microphone.
    @discardableResult
    func toggle(_ url: URL, memoRecording: Bool) -> Bool {
        if playingURL == url {
            stop()
            return true
        }
        guard !memoRecording, !OneLinerRecorder.isCapturing else { return false }
        stop()
        Self.current = self
        revision &+= 1
        let owner = revision
        playingURL = url
        sessionTransitions.activatePlayback { [weak self] result in
            Task { @MainActor [weak self] in self?.begin(url, owner: owner, activation: result) }
        }
        return true
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
