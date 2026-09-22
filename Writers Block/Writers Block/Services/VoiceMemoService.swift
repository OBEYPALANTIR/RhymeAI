import AVFoundation
import Foundation
import Observation

// VoiceMemoService owns the full record/play/delete lifecycle for per-song
// voice memos. One instance per EditorViewModel — its lifetime matches the
// view model so AVAudioSession is torn down cleanly when the VM is released.
//
// Uses @Observable (Swift 5.9 / iOS 17+) rather than ObservableObject because
// the project sets -default-isolation=MainActor, which breaks ObservableObject
// synthesis on non-NSObject classes and causes false "does not conform" errors
// when accessed via @ObservedObject from views.
@Observable
final class VoiceMemoService {

    // MARK: - Observable State

    private(set) var isRecording: Bool = false
    private(set) var isPlaying: Bool = false
    private(set) var recordingElapsed: TimeInterval = 0
    // Normalised amplitude 0..1 for the spectralizer. Updated at ~10 Hz while
    // recording; resets to 0 when recording stops so bars collapse cleanly.
    private(set) var averagePowerNormalized: Float = 0
    // Not private(set) — the .alert(isPresented:) binding needs write access
    // to reset the flag when the user dismisses the alert.
    var permissionDenied: Bool = false
    // Set when a recording or file operation fails so the UI can surface it
    // instead of swallowing the error. Writable so the alert binding can clear it.
    var lastError: String?

    // MARK: - Private (not tracked by @Observable)

    @ObservationIgnored private var audioRecorder: AVAudioRecorder?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var elapsedTimer: Timer?
    // Separate metering timer so elapsed-clock updates do not drive dB reads.
    @ObservationIgnored private var meteringTimer: Timer?
    @ObservationIgnored private var recordingStartTime: Date?
    @ObservationIgnored private var activePlayURL: URL?
    @ObservationIgnored private var delegateForwarder: VoiceMemoDelegate?
    nonisolated private static let audioSessionQueue = DispatchQueue(
        label: "com.rhymeai.audio-session",
        qos: .userInitiated
    )

    nonisolated static let maximumImportBytes = 100 * 1024 * 1024

    nonisolated enum ImportError: Error {
        case unsupportedAudio, emptyAudio, tooLarge, cannotCreateFile
    }

    /// Copy provider-owned bytes into staging, decode them, then atomically publish.
    /// No microphone or audio session is needed to import a recording.
    nonisolated static func importMemo(from source: URL, projectId: String) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension.lowercased()
            guard RecordingFiles.supportedAudioExtensions.contains(ext) else { throw ImportError.unsupportedAudio }
            let folder = try RecordingFiles.projectURL(projectId: projectId, memosRoot: RecordingFiles.memosRoot())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let staging = folder.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: staging) }
            let copied = staging.appendingPathComponent("audio").appendingPathExtension(ext)
            guard FileManager.default.createFile(atPath: copied.path, contents: nil) else {
                throw ImportError.cannotCreateFile
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: copied)
            defer { try? output.close() }
            var total = 0
            while let bytes = try input.read(upToCount: 64 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                total += bytes.count
                guard total <= maximumImportBytes else { throw ImportError.tooLarge }
                try output.write(contentsOf: bytes)
            }
            try output.close()
            guard total > 0 else { throw ImportError.emptyAudio }
            let audio = try AVAudioFile(forReading: copied)
            guard audio.length > 0, audio.processingFormat.sampleRate > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else {
                throw ImportError.emptyAudio
            }
            // Decode the full stream so a renamed non-audio or corrupt file is not accepted.
            var frames: AVAudioFramePosition = 0
            while audio.framePosition < audio.length {
                try Task.checkCancellation()
                try audio.read(into: buffer)
                guard buffer.frameLength > 0 else { throw ImportError.emptyAudio }
                frames += AVAudioFramePosition(buffer.frameLength)
            }
            guard frames > 0 else { throw ImportError.emptyAudio }
            try Task.checkCancellation()
            let target = try RecordingFiles.importURL(basename: source.deletingPathExtension().lastPathComponent, extension: ext, projectId: projectId)
            try FileManager.default.moveItem(at: copied, to: target)
            return target
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func isPlayingMemo(at url: URL) -> Bool {
        isPlaying && activePlayURL == url
    }

    /// Move the memo at `url` to the Trash Bin instead of deleting it. The file
    /// is kept for `trashRetentionInterval` before purge.
    /// Returns the trashed record on success (usable for undo), nil on failure.
    @discardableResult
    func trashMemo(at url: URL, projectId: String) -> TrashedVoiceMemo? {
        if activePlayURL == url { stopPlayback() }
        let folder = RecordingFiles.trashFolder(for: projectId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Bump the timestamp on collision so a same-named file trashed twice
            // in one millisecond never overwrites an existing trashed recording.
            var deletedAtMs = Int(Date().timeIntervalSince1970 * 1000)
            var target = folder.appendingPathComponent("\(deletedAtMs)\(RecordingFiles.trashNameSeparator)\(url.lastPathComponent)")
            while FileManager.default.fileExists(atPath: target.path) {
                deletedAtMs += 1
                target = folder.appendingPathComponent("\(deletedAtMs)\(RecordingFiles.trashNameSeparator)\(url.lastPathComponent)")
            }
            try FileManager.default.moveItem(at: url, to: target)
            return TrashedVoiceMemo(
                url: target,
                projectId: projectId,
                originalName: url.lastPathComponent,
                deletedAt: Date(timeIntervalSince1970: Double(deletedAtMs) / 1000)
            )
        } catch {
            lastError = "Couldn't move recording to trash: \(error.localizedDescription)"
            return nil
        }
    }

    /// Move a trashed recording back into its project's live memo folder under
    /// its original name (suffixed if that name is now taken).
    func restoreTrashedMemo(_ trashed: TrashedVoiceMemo) {
        let folder = RecordingFiles.memoFolder(for: trashed.projectId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = RecordingFiles.restoredURL(originalName: trashed.originalName, folder: folder)
            try FileManager.default.moveItem(at: trashed.url, to: target)
            RecordingFiles.cleanUpEmptyTrashFolder(trashed.url.deletingLastPathComponent())
        } catch {
            lastError = "Couldn't restore recording: \(error.localizedDescription)"
        }
    }

    /// Permanently delete a trashed recording.
    @discardableResult
    func permanentlyDeleteTrashedMemo(_ trashed: TrashedVoiceMemo) -> Bool {
        if activePlayURL == trashed.url { stopPlayback() }
        do {
            try SyncIdentity.validateProjectId(trashed.projectId)
            try SyncIdentity.validateFileName(trashed.originalName)
            try RecordingFiles.removeItemIfPresent(at: trashed.url, within: RecordingFiles.memosTrashRoot())
            RecordingFiles.cleanUpEmptyTrashFolder(trashed.url.deletingLastPathComponent())
            return true
        } catch {
            lastError = "Couldn't remove the local recording file. Writers Block will retry cleanup."
            return false
        }
    }

    func deletePermanentRecordingFiles(projectId: String, fileName: String) {
        do {
            let live = try RecordingFiles.localURL(projectId: projectId, fileName: fileName, memosRoot: RecordingFiles.memosRoot())
            _ = try RecordingFiles.projectURL(projectId: projectId, memosRoot: RecordingFiles.memosTrashRoot())
            try RecordingFiles.removeItemIfPresent(at: live, within: RecordingFiles.memosRoot())
            for trashed in RecordingFiles.trashedMemos() where trashed.projectId == projectId && trashed.originalName == fileName {
                _ = permanentlyDeleteTrashedMemo(trashed)
            }
        } catch {
            lastError = "Couldn't remove the local recording file. Writers Block will retry cleanup."
        }
    }

    // MARK: - Permission

    func requestPermissionIfNeeded() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied:
                permissionDenied = true
                return false
            case .undetermined:
                let granted = await AVAudioApplication.requestRecordPermission()
                if !granted { permissionDenied = true }
                return granted
            @unknown default:
                return false
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        if !granted { self.permissionDenied = true }
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    // MARK: - Record

    func startRecording(projectId: String) async {
        #if DEBUG
        if UITestFlags.isEnabled(UITestFlags.fakeVoiceRecording) {
            stopPlayback()
            recordingStartTime = Date()
            recordingElapsed = 3
            averagePowerNormalized = 0.55
            isRecording = true
            return
        }
        #endif

        guard await requestPermissionIfNeeded() else { return }

        stopPlayback()

        let folder = RecordingFiles.memoFolder(for: projectId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = RecordingFiles.newMemoURL(for: projectId)

        do {
            try await Self.activateRecordingSession()
        } catch {
            failToStartRecording()
            return
        }

        // AAC in an MPEG-4 container matches the Android MediaRecorder output
        // format (.m4a / AAC_ADTS) for cross-platform parity.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            failToStartRecording()
            return
        }

        let forwarder = VoiceMemoDelegate(service: self)
        delegateForwarder = forwarder
        recorder.delegate = forwarder
        // Metering must be enabled before record() so AVAudioRecorder captures
        // level data from the first packet; it cannot be toggled mid-session.
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            recorder.stop()
            failToStartRecording()
            return
        }

        audioRecorder = recorder
        recordingStartTime = Date()
        isRecording = true

        // Update the elapsed clock once per displayed second; the UI formats it
        // as mm:ss, so sub-second updates redraw the same text.
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            Task { @MainActor [weak self] in
                self?.recordingElapsed = Date().timeIntervalSince(start)
            }
        }
        elapsedTimer?.tolerance = 0.1

        // Poll AVAudioRecorder at ~10 Hz for amplitude. dB range is approximately
        // -160..0 dB (silence to full scale); we map -60..0 → 0..1 so typical
        // speech registers clearly without the bars looking pinned at minimum.
        // Light exponential smoothing (α=0.3) prevents jitter from single-frame
        // spikes without adding noticeable lag.
        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.audioRecorder?.updateMeters()
            let dB = self.audioRecorder?.averagePower(forChannel: 0) ?? -60
            let raw = (dB + 60.0) / 60.0
            let clamped = max(0, min(1, raw))
            Task { @MainActor [weak self] in
                guard let self else { return }
                // α=0.3: new value weighted 30%, history 70%
                self.averagePowerNormalized = 0.3 * Float(clamped) + 0.7 * self.averagePowerNormalized
            }
        }
    }

    func stopRecording() {
        let shouldDeactivateSession = audioRecorder != nil
        audioRecorder?.stop()
        audioRecorder = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        meteringTimer?.invalidate()
        meteringTimer = nil
        recordingStartTime = nil
        delegateForwarder = nil
        isRecording = false
        recordingElapsed = 0
        averagePowerNormalized = 0

        // Deactivate so other apps (Music, Podcast) can resume their sessions.
        if shouldDeactivateSession {
            Self.deactivateAudioSession()
        }
    }

    private func failToStartRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        meteringTimer?.invalidate()
        meteringTimer = nil
        recordingStartTime = nil
        delegateForwarder = nil
        isRecording = false
        recordingElapsed = 0
        averagePowerNormalized = 0
        Self.deactivateAudioSession()
        lastError = "Couldn't start recording. Check the microphone and try again."
    }

    nonisolated private static func activateRecordingSession() async throws {
        try await withCheckedThrowingContinuation { continuation in
            audioSessionQueue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(
                        .playAndRecord,
                        mode: .default,
                        options: [.defaultToSpeaker]
                    )
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func deactivateAudioSession() {
        audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    // MARK: - Playback

    func togglePlayback(url: URL) {
        if isPlaying, activePlayURL == url {
            stopPlayback()
            return
        }
        stopPlayback()
        playMemo(url: url)
    }

    private func playMemo(url: URL) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            return
        }

        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            Self.deactivateAudioSession()
            return
        }

        let forwarder = VoiceMemoDelegate(service: self)
        delegateForwarder = forwarder
        player.delegate = forwarder
        player.play()

        audioPlayer = player
        activePlayURL = url
        isPlaying = true
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        activePlayURL = nil
        delegateForwarder = nil
        isPlaying = false
        Self.deactivateAudioSession()
    }

    // MARK: - Delete

    func deleteMemo(at url: URL) {
        if activePlayURL == url { stopPlayback() }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            lastError = "Couldn't delete recording: \(error.localizedDescription)"
        }
    }

    // MARK: - Rename

    /// Rename the memo at `url` to `newBasename` (without extension).
    /// - The sanitized name is used; if empty after sanitization the rename is skipped.
    /// - If a file with the target name already exists, " 2" is appended (once).
    /// - Returns the new URL on success; throws on FileManager error.
    @discardableResult
    func renameMemo(at url: URL, to newBasename: String) throws -> URL {
        let sanitized = RecordingFiles.sanitizeName(newBasename)
        guard !sanitized.isEmpty else { return url }

        let targetURL = RecordingFiles.renamedURL(for: url, sanitizedName: sanitized)

        // No-op if names are identical.
        guard targetURL != url else { return url }

        // If active playback is on this file, stop it before rename.
        if activePlayURL == url { stopPlayback() }

        try FileManager.default.moveItem(at: url, to: targetURL)
        return targetURL
    }

    // MARK: - Callbacks from delegate forwarder

    fileprivate func recordingDidFinish() {
        isRecording = false
        recordingElapsed = 0
        averagePowerNormalized = 0
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        meteringTimer?.invalidate()
        meteringTimer = nil
        delegateForwarder = nil
    }

    fileprivate func playbackDidFinish() {
        isPlaying = false
        activePlayURL = nil
        delegateForwarder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Cleanup

    deinit {
        elapsedTimer?.invalidate()
        meteringTimer?.invalidate()
    }
}

// MARK: - Private delegate forwarder

// AVFoundation delegate protocols are @objc and require NSObject.
// Keeping that inheritance here (not on VoiceMemoService) avoids conflating
// NSObject identity with the service's Swift Observable type.
private final class VoiceMemoDelegate: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    private weak var service: VoiceMemoService?

    init(service: VoiceMemoService) {
        self.service = service
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.service?.recordingDidFinish()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.service?.playbackDidFinish()
        }
    }
}
