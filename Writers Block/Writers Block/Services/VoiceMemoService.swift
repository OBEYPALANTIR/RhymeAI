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
    // Not private(set) — the .alert(isPresented:) binding needs write access
    // to reset the flag when the user dismisses the alert.
    var permissionDenied: Bool = false

    // MARK: - Private (not tracked by @Observable)

    @ObservationIgnored private var audioRecorder: AVAudioRecorder?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var recordingStartTime: Date?
    @ObservationIgnored private var activePlayURL: URL?
    @ObservationIgnored private var delegateForwarder: VoiceMemoDelegate?

    // MARK: - File System

    // Root under Application Support so iOS backs it up and excludes it from
    // iCloud Documents — memos are device-local scratch recordings, not synced content.
    static func memosRoot() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("voice-memos", isDirectory: true)
    }

    static func memoFolder(for projectId: String) -> URL {
        memosRoot().appendingPathComponent(projectId, isDirectory: true)
    }

    static func newMemoURL(for projectId: String) -> URL {
        let folder = memoFolder(for: projectId)
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        return folder.appendingPathComponent("\(timestamp).m4a")
    }

    /// Returns all memo URLs for a project, sorted oldest-first by filename
    /// (filenames are millisecond timestamps, so lexicographic == chronological).
    static func memos(for projectId: String) -> [URL] {
        let folder = memoFolder(for: projectId)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return items
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Remove a project's entire memo folder — called on permanent delete and
    /// on trash-purge expiry so orphaned audio doesn't accumulate on disk.
    static func deleteMemosFolder(for projectId: String) {
        let folder = memoFolder(for: projectId)
        try? FileManager.default.removeItem(at: folder)
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
        guard await requestPermissionIfNeeded() else { return }

        stopPlayback()

        let folder = Self.memoFolder(for: projectId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = Self.newMemoURL(for: projectId)

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
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

        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        let forwarder = VoiceMemoDelegate(service: self)
        delegateForwarder = forwarder
        recorder.delegate = forwarder
        recorder.record()

        audioRecorder = recorder
        recordingStartTime = Date()
        isRecording = true

        // Update the elapsed clock on every UI tick — displayed as mm:ss so a
        // 1-second interval would feel laggy.
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            Task { @MainActor [weak self] in
                self?.recordingElapsed = Date().timeIntervalSince(start)
            }
        }
    }

    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartTime = nil
        delegateForwarder = nil
        isRecording = false
        recordingElapsed = 0

        // Deactivate so other apps (Music, Podcast) can resume their sessions.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Delete

    func deleteMemo(at url: URL) {
        if activePlayURL == url { stopPlayback() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Callbacks from delegate forwarder

    fileprivate func recordingDidFinish() {
        isRecording = false
        recordingElapsed = 0
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
