import AVFoundation
import Foundation
import Observation

// A recording sitting in the Trash Bin. The trash filename encodes the deletion
// timestamp as "<deletedAtMs>__<originalName>" so trash state survives restarts
// without a separate metadata store — mirrors the Android TrashedVoiceMemo.
struct TrashedVoiceMemo: Identifiable, Sendable {
    let url: URL
    let projectId: String
    /// Original filename (with extension) the memo had before it was trashed.
    let originalName: String
    let deletedAt: Date
    // nonisolated: the project builds with -default-isolation=MainActor, and these
    // are read from nonisolated static purge/expiry helpers.
    nonisolated var deleteAfter: Date { deletedAt.addingTimeInterval(trashRetentionInterval) }
    nonisolated var id: String { url.absoluteString }
}

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

    nonisolated static let supportedAudioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac"]
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
            guard supportedAudioExtensions.contains(ext) else { throw ImportError.unsupportedAudio }
            let folder = try RecordingBackupManifest.projectURL(projectId: projectId, memosRoot: memosRoot())
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
            let stem = sanitizeName(source.deletingPathExtension().lastPathComponent)
            let name = stem.isEmpty || stem.hasPrefix(".") ? "Imported recording" : stem
            var suffix = 1
            var target: URL
            repeat {
                let filename = suffix == 1 ? "\(name).\(ext)" : "\(name) \(suffix).\(ext)"
                target = try RecordingBackupManifest.localURL(projectId: projectId, fileName: filename, memosRoot: memosRoot())
                suffix += 1
            } while FileManager.default.fileExists(atPath: target.path)
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

    // MARK: - File System

    // Root under Application Support so iOS backs it up and excludes it from
    // iCloud Documents — memos are device-local scratch recordings, not synced content.
    nonisolated static func memosRoot() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("voice-memos", isDirectory: true)
    }

    nonisolated static func memoFolder(for projectId: String) -> URL {
        memosRoot().appendingPathComponent(projectId, isDirectory: true)
    }

    nonisolated static func newMemoURL(for projectId: String) -> URL {
        let folder = memoFolder(for: projectId)
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        return folder.appendingPathComponent("\(timestamp).m4a")
    }

    /// Newest recordings first. Renaming a recording does not change its file date.
    nonisolated static func memos(for projectId: String) -> [URL] {
        let folder = memoFolder(for: projectId)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        let memoURLs = items.filter { Self.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
        let datedMemos = memoURLs.map { url -> (url: URL, date: Date) in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            return (url: url, date: values?.contentModificationDate ?? values?.creationDate ?? .distantPast)
        }
        return datedMemos.sorted { lhs, rhs in
                lhs.date == rhs.date
                    ? lhs.url.lastPathComponent < rhs.url.lastPathComponent
                    : lhs.date > rhs.date
            }
            .map(\.url)
    }

    /// Remove a project's entire memo folder — live and trashed. Called on
    /// permanent delete and on trash-purge expiry so orphaned audio doesn't
    /// accumulate on disk.
    @discardableResult
    static func deleteMemosFolder(for projectId: String) -> Bool {
        do {
            let live = try RecordingBackupManifest.projectURL(projectId: projectId, memosRoot: memosRoot())
            let trash = try RecordingBackupManifest.projectURL(projectId: projectId, memosRoot: memosTrashRoot())
            try removeItemIfPresent(at: live, within: memosRoot())
            try removeItemIfPresent(at: trash, within: memosTrashRoot())
            return true
        } catch {
            return false
        }
    }

    // MARK: - Recordings Trash

    /// Separates the deletion timestamp from the original name in trash filenames.
    nonisolated static let trashNameSeparator = "__"

    nonisolated static func memosTrashRoot() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("voice-memos-trash", isDirectory: true)
    }

    nonisolated static func trashFolder(for projectId: String) -> URL {
        memosTrashRoot().appendingPathComponent(projectId, isDirectory: true)
    }

    /// All trashed recordings across every project, newest deletion first.
    nonisolated static func trashedMemos() -> [TrashedVoiceMemo] {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: memosTrashRoot(),
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return folders
            .flatMap { folder -> [TrashedVoiceMemo] in
                let projectId = folder.lastPathComponent
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                ) else { return [] }
                return files
                    .filter { Self.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
                    .compactMap { trashedMemo(at: $0, projectId: projectId) }
            }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    nonisolated private static func trashedMemo(at url: URL, projectId: String) -> TrashedVoiceMemo? {
        let name = url.lastPathComponent
        guard let separatorRange = name.range(of: trashNameSeparator),
              separatorRange.lowerBound != name.startIndex,
              let deletedAtMs = Double(name[..<separatorRange.lowerBound]) else { return nil }
        let originalName = String(name[separatorRange.upperBound...])
        guard !originalName.isEmpty else { return nil }
        return TrashedVoiceMemo(
            url: url,
            projectId: projectId,
            originalName: originalName,
            deletedAt: Date(timeIntervalSince1970: deletedAtMs / 1000)
        )
    }

    /// Move the memo at `url` to the Trash Bin instead of deleting it. The file
    /// is kept for `trashRetentionInterval` before purge.
    /// Returns the trashed record on success (usable for undo), nil on failure.
    @discardableResult
    func trashMemo(at url: URL, projectId: String) -> TrashedVoiceMemo? {
        if activePlayURL == url { stopPlayback() }
        let folder = Self.trashFolder(for: projectId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Bump the timestamp on collision so a same-named file trashed twice
            // in one millisecond never overwrites an existing trashed recording.
            var deletedAtMs = Int(Date().timeIntervalSince1970 * 1000)
            var target = folder.appendingPathComponent("\(deletedAtMs)\(Self.trashNameSeparator)\(url.lastPathComponent)")
            while FileManager.default.fileExists(atPath: target.path) {
                deletedAtMs += 1
                target = folder.appendingPathComponent("\(deletedAtMs)\(Self.trashNameSeparator)\(url.lastPathComponent)")
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
        let folder = Self.memoFolder(for: trashed.projectId)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var target = folder.appendingPathComponent(trashed.originalName)
            if FileManager.default.fileExists(atPath: target.path) {
                let stem = (trashed.originalName as NSString).deletingPathExtension
                var suffix = 2
                repeat {
                    target = folder.appendingPathComponent("\(stem) \(suffix).\((trashed.originalName as NSString).pathExtension)")
                    suffix += 1
                } while FileManager.default.fileExists(atPath: target.path) && suffix < 1000
            }
            try FileManager.default.moveItem(at: trashed.url, to: target)
            Self.cleanUpEmptyTrashFolder(trashed.url.deletingLastPathComponent())
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
            try Self.removeItemIfPresent(at: trashed.url, within: Self.memosTrashRoot())
            Self.cleanUpEmptyTrashFolder(trashed.url.deletingLastPathComponent())
            return true
        } catch {
            lastError = "Couldn't remove the local recording file. Writers Block will retry cleanup."
            return false
        }
    }

    func deletePermanentRecordingFiles(projectId: String, fileName: String) {
        do {
            let live = try RecordingBackupManifest.localURL(projectId: projectId, fileName: fileName, memosRoot: Self.memosRoot())
            _ = try RecordingBackupManifest.projectURL(projectId: projectId, memosRoot: Self.memosTrashRoot())
            try Self.removeItemIfPresent(at: live, within: Self.memosRoot())
            for trashed in Self.trashedMemos() where trashed.projectId == projectId && trashed.originalName == fileName {
                _ = permanentlyDeleteTrashedMemo(trashed)
            }
        } catch {
            lastError = "Couldn't remove the local recording file. Writers Block will retry cleanup."
        }
    }

    /// Delete every trashed recording whose retention window has passed.
    nonisolated static func purgeExpiredTrashedMemos(now: Date = Date()) {
        for trashed in trashedMemos() where trashed.deleteAfter <= now {
            try? removeItemIfPresent(at: trashed.url, within: memosTrashRoot())
            cleanUpEmptyTrashFolder(trashed.url.deletingLastPathComponent())
        }
    }

    /// Earliest deleteAfter among trashed recordings, or nil when trash is empty.
    nonisolated static func nextTrashedMemoExpiry() -> Date? {
        trashedMemos().map(\.deleteAfter).min()
    }

    /// Remove a project's trash folder once its last recording leaves it.
    nonisolated private static func cleanUpEmptyTrashFolder(_ folder: URL) {
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ), contents.isEmpty {
            try? removeItemIfPresent(at: folder, within: memosTrashRoot())
        }
    }

    nonisolated private static func removeItemIfPresent(at url: URL, within root: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let standardizedURL = url.standardizedFileURL
        let canonicalURL = standardizedURL.resolvingSymlinksInPath()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard canonicalURL.path != canonicalRoot.path, canonicalURL.path.hasPrefix(rootPrefix) else {
            throw SyncValidationError.pathOutsideMemoRoot
        }

        try FileManager.default.removeItem(at: standardizedURL)
    }

    // MARK: - Permission

    func requestPermissionIfNeeded() async -> Bool {
        #if os(macOS)
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permissionDenied = !granted
        return granted
        #else
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
        #endif
    }

    // MARK: - Record

    func startRecording(projectId: String) async {
        guard await requestPermissionIfNeeded() else { return }

        stopPlayback()

        let folder = Self.memoFolder(for: projectId)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = Self.newMemoURL(for: projectId)

        #if !os(macOS)
        let recordingSession = AVAudioSession.sharedInstance()
        do {
            try recordingSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try recordingSession.setActive(true)
        } catch {
            failToStartRecording()
            return
        }
        #endif

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
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        lastError = "Couldn't start recording. Check the microphone and try again."
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
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            return
        }
        #endif

        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            #if !os(macOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
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
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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

    /// Strip illegal filesystem characters from a candidate display name.
    /// Rules: trim whitespace; remove `/`, `:`, `\0`; collapse runs of whitespace;
    /// truncate to 255 UTF-8 code units (HFS+ limit minus .m4a overhead).
    nonisolated static func sanitizeName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip characters that are illegal in HFS+ / APFS filenames.
        let illegal = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        s = s.unicodeScalars
            .filter { !illegal.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        // Collapse interior whitespace runs to a single space.
        s = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Ensure the result, when encoded as UTF-8, fits within 255 bytes
        // (leaving headroom for the ".m4a" extension — 4 bytes).
        let limit = 220
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
        var targetURL = folder.appendingPathComponent(sanitized).appendingPathExtension(url.pathExtension)

        // Collision avoidance: append " 2" if target already exists (and isn't the source itself).
        if targetURL != url && FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = folder.appendingPathComponent(sanitized + " 2").appendingPathExtension(url.pathExtension)
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
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
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
