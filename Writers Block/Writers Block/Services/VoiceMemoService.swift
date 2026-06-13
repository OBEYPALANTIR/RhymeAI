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

    // MARK: - Private (not tracked by @Observable)

    @ObservationIgnored private var audioRecorder: AVAudioRecorder?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var elapsedTimer: Timer?
    // Separate low-frequency timer for metering so the 60 Hz elapsed clock
    // is not taxed with dB reads on every tick.
    @ObservationIgnored private var meteringTimer: Timer?
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
        // Metering must be enabled before record() so AVAudioRecorder captures
        // level data from the first packet; it cannot be toggled mid-session.
        recorder.isMeteringEnabled = true
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

    // MARK: - Rename

    /// Strip illegal filesystem characters from a candidate display name.
    /// Rules: trim whitespace; remove `/`, `:`, `\0`; collapse runs of whitespace;
    /// truncate to 255 UTF-8 code units (HFS+ limit minus .m4a overhead).
    static func sanitizeName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip characters that are illegal in HFS+ / APFS filenames.
        let illegal = CharacterSet(charactersIn: "/:\u{0000}")
        s = s.unicodeScalars
            .filter { !illegal.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        // Collapse interior whitespace runs to a single space.
        s = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Ensure the result, when encoded as UTF-8, fits within 255 bytes
        // (leaving headroom for the ".m4a" extension — 4 bytes).
        let limit = 251
        if let data = s.data(using: .utf8), data.count > limit {
            var truncated = s
            while let d = truncated.data(using: .utf8), d.count > limit {
                truncated.removeLast()
            }
            s = truncated
        }
        return s
    }

    /// Rename the memo at `url` to `newBasename` (without extension).
    /// - The sanitized name is used; if empty after sanitization the rename is skipped.
    /// - If a file with the target name already exists, " 2" is appended (once).
    /// - Returns the new URL on success; throws on FileManager error.
    @discardableResult
    func renameMemo(at url: URL, to newBasename: String) throws -> URL {
        let sanitized = Self.sanitizeName(newBasename)
        guard !sanitized.isEmpty else { return url }

        let folder = url.deletingLastPathComponent()
        var targetURL = folder.appendingPathComponent(sanitized).appendingPathExtension("m4a")

        // Collision avoidance: append " 2" if target already exists (and isn't the source itself).
        if targetURL != url && FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = folder.appendingPathComponent(sanitized + " 2").appendingPathExtension("m4a")
        }

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
