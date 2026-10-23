import AVFoundation
import Foundation
import Observation

// All memo audio-session mutations share one serial queue. A stop enqueues its
// deactivation before the next activation, even when that stop does not wait.
nonisolated final class VoiceMemoAudioSessionTransitions: @unchecked Sendable {
    static let shared = VoiceMemoAudioSessionTransitions(
        activateRecording: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        },
        activatePlayback: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        },
        deactivate: {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    )

    private let queue = DispatchQueue(label: "com.rhymeai.audio-session", qos: .userInitiated)
    private let recordingAction: @Sendable () throws -> Void
    private let playbackAction: @Sendable () throws -> Void
    private let deactivationAction: @Sendable () -> Void

    init(
        activateRecording: @escaping @Sendable () throws -> Void,
        activatePlayback: @escaping @Sendable () throws -> Void,
        deactivate: @escaping @Sendable () -> Void
    ) {
        recordingAction = activateRecording
        playbackAction = activatePlayback
        deactivationAction = deactivate
    }

    func activateRecording(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        perform(recordingAction, completion: completion)
    }

    func activatePlayback(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        perform(playbackAction, completion: completion)
    }

    func deactivate() {
        queue.async(execute: deactivationAction)
    }

    private func perform(
        _ action: @escaping @Sendable () throws -> Void,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async {
            do {
                try action()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }
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
    /// Finished takes not yet published into the library (A27), found on disk
    /// (a take folder with its finished marker), shown as "waiting to be saved"
    /// with Retry until each one is published.
    private(set) var pendingTakes: [PendingTake] = []
    /// Takes that are definitively not saveable (their audio is gone or is not a
    /// finished recording); their files stay on this device.
    private(set) var failedTakes: [PendingTake] = []
    /// Bumped whenever the recordings change (a take published, a deletion
    /// applied), so open lists reload.
    private(set) var publishedRevision = 0

    struct PendingTake: Equatable {
        /// The take folder's name: the recording id it is published under, fixed
        /// when the recording started and never replaced.
        let id: String
        let projectId: String
        let folder: URL
        /// The take's audio, if it is still in staging.
        let audio: URL?
        enum State: Equatable {
            /// The recorder reported it finished, at this time.
            case finished(Date)
            /// A finished marker that cannot be read: it waits, and is never re-dated.
            case unreadableMarker
            /// No marker: its container is checked before it is published.
            case unconfirmed
            case failed
        }
        let state: State
    }

    /// Answers whether a recording may be played: one a winning deletion covers
    /// may not (A28). Set by the view model.
    @ObservationIgnored var playbackAllowed: ((URL) -> Bool)?
    /// The recording id that owns a file, if a row does; playback is tracked by it,
    /// so a recording removed while it plays (or before its player starts) stops.
    @ObservationIgnored var playbackIdentity: ((URL) -> String?)?
    @ObservationIgnored private var playingIdentity: String?
    /// Set when the take folders could not be listed; the last known takes stay.
    private(set) var pendingTakesUnreadable = false
    /// Audio in the recorder's staging that is not in a take folder and could not be
    /// given one (T3.29, T5.13): kept and listed.
    private(set) var unmigratedTakes = Set<String>()

    /// Builds before take folders (d185048) recorded straight into the song's staging
    /// folder. Each such file becomes a take of its own, `<newId>/<newId>.<ext>`, by an
    /// exclusive rename; with no finished marker its container is checked before it
    /// is published. One that cannot be moved stays and is reported.
    private func migrateFlatTakes(in project: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles) else { return }
        for file in entries where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && RecordingFiles.supportedAudioExtensions.contains(file.pathExtension.lowercased()) {
            let id = UUID().uuidString.lowercased()
            let folder = project.appendingPathComponent(id, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try RecordingFiles.exclusiveRename(file, to: folder.appendingPathComponent("\(id).\(file.pathExtension.lowercased())"))
                unmigratedTakes.remove(file.path)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                unmigratedTakes.insert(file.path)
            }
        }
    }

    // MARK: - Private (not tracked by @Observable)

    @ObservationIgnored private var audioRecorder: AVAudioRecorder?
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var elapsedTimer: Timer?
    // Separate metering timer so elapsed-clock updates do not drive dB reads.
    @ObservationIgnored private var meteringTimer: Timer?
    @ObservationIgnored private var recordingStartTime: Date?
    @ObservationIgnored private var activePlayURL: URL?
    @ObservationIgnored private var delegateForwarder: VoiceMemoDelegate?
    @ObservationIgnored private let sessionTransitions: VoiceMemoAudioSessionTransitions
    @ObservationIgnored private var audioIntentRevision: UInt64 = 0
    @ObservationIgnored private var recordingActivationRevision: UInt64?
    @ObservationIgnored private var pendingPlayURL: URL?
    /// Called after a recording file is added, renamed, trashed, restored or
    /// deleted, so the automatic backup can pick the change up.
    @ObservationIgnored var onFilesChanged: (() -> Void)?
    /// Records each memo change in the library before the file moves; without
    /// one (tests of the service alone) changes are file moves only.
    @ObservationIgnored weak var publisher: (any RecordingPublishing)?
    @ObservationIgnored private var recordingProjectId: String?
    /// A stopped recorder whose completion has not arrived yet; it keeps its
    /// delegate alive so the outcome is not lost.
    @ObservationIgnored private var finishing: (recorder: AVAudioRecorder, projectId: String, delegate: VoiceMemoDelegate?)?

    @ObservationIgnored let stagingRoot: URL

    init(sessionTransitions: VoiceMemoAudioSessionTransitions = .shared, stagingRoot: URL = RecordingFiles.recorderStagingRoot()) {
        self.sessionTransitions = sessionTransitions
        self.stagingRoot = stagingRoot
        refreshPendingTakes()
    }

    /// Take folders still in staging, sorted into waiting and failed. A folder
    /// the recorder is writing is left alone.
    func refreshPendingTakes() {
        let fm = FileManager.default
        let active = [audioRecorder?.url, finishing?.recorder.url].compactMap { $0?.deletingLastPathComponent().standardizedFileURL.path }
        var takes: [PendingTake] = []
        do {
            // Only a staging root the file system confirms missing means no takes;
            // a listing that fails keeps the last known takes (finding 8).
            if try RecordingFiles.exists(stagingRoot) {
                for project in try fm.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    migrateFlatTakes(in: project)
                    for folder in try fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                    where !active.contains(folder.standardizedFileURL.path) {
                        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                            unmigratedTakes.insert(folder.path)
                            continue
                        }
                        let contents = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                        let audio = contents.first { RecordingFiles.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
                        let names = Set(contents.map(\.lastPathComponent))
                        let state: PendingTake.State
                        if names.contains(RecordingFiles.failedTakeMarker) || (try? SyncIdentity.validateRecordingId(folder.lastPathComponent)) == nil {
                            state = .failed
                        } else if names.contains(RecordingFiles.finishedTakeMarker) {
                            state = RecordingFiles.readFinishedMarker(in: folder).map(PendingTake.State.finished) ?? .unreadableMarker
                        } else if audio != nil {
                            state = .unconfirmed
                        } else {
                            continue
                        }
                        takes.append(PendingTake(id: folder.lastPathComponent, projectId: project.lastPathComponent, folder: folder, audio: audio, state: state))
                    }
                }
            }
        } catch {
            pendingTakesUnreadable = true
            lastError = "Recordings waiting to be saved could not be read. They are kept on this device; tap Retry to try again."
            return
        }
        pendingTakesUnreadable = false
        if !unmigratedTakes.isEmpty {
            lastError = "\(unmigratedTakes.count) \(unmigratedTakes.count == 1 ? "recording waiting to be saved is" : "recordings waiting to be saved are") in an older layout and could not be read. They are kept on this device."
        }
        takes.sort { $0.id < $1.id }
        pendingTakes = takes.filter { $0.state != .failed }
        failedTakes = takes.filter { $0.state == .failed }
    }

    nonisolated static let maximumImportBytes = 100 * 1024 * 1024

    nonisolated enum ImportError: Error {
        case unsupportedAudio, emptyAudio, tooLarge, cannotCreateFile
    }

    /// Copy provider-owned bytes into staging, decode them, then atomically publish.
    /// No microphone or audio session is needed to import a recording.
    /// Where imports copy audio before it is published.
    nonisolated static var defaultImportRoot: URL {
        RecordingFiles.memosRoot().deletingLastPathComponent().appendingPathComponent("recording-import", isDirectory: true)
    }

    /// What an import's private copy is for, written before it is copied.
    nonisolated struct ImportRecord: Codable {
        var id: String
        var projectId: String
        var displayName: String
        /// True once the copy decoded in full: only then is it published.
        var verified: Bool

        func write(in folder: URL) throws {
            try JSONEncoder().encode(self).write(to: folder.appendingPathComponent("import.json"), options: .atomic)
        }
    }

    /// Publishes a verified import under the library's gate, on the main actor.
    @MainActor
    private static func publishImported(_ copied: URL, projectId: String, displayName: String, id: String, publisher: (any RecordingPublishing)?) async throws -> URL {
        guard let publisher else { throw RecordingLibraryError.unavailable }
        return try await publisher.withGate {
            try publisher.publishFinished(copied, projectId: projectId, preferredName: displayName, origin: .imported, id: id, finishedAt: nil)
        }
    }

    /// Imports a killed app left behind (T1.21): a copy that had decoded in full is
    /// published under its id; one that had not is disposed of (the user's original
    /// file is untouched); a folder whose record cannot be read is kept and reported.
    @discardableResult
    static func recoverImports(publisher: any RecordingPublishing, importRoot: URL = defaultImportRoot) async -> [String] {
        var kept: [String] = []
        let folders = (try? FileManager.default.contentsOfDirectory(at: importRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("import.json")),
                  let record = try? JSONDecoder().decode(ImportRecord.self, from: data), record.id == folder.lastPathComponent else {
                kept.append(folder.lastPathComponent)
                continue
            }
            let audio = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .first { $0.deletingPathExtension().lastPathComponent == record.id && RecordingFiles.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
            guard record.verified, let audio else {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            do {
                _ = try await publisher.withGate {
                    try publisher.publishFinished(audio, projectId: record.projectId, preferredName: record.displayName, origin: .imported, id: record.id, finishedAt: nil)
                }
                try? FileManager.default.removeItem(at: folder)
            } catch {
                kept.append(record.displayName)
            }
        }
        return kept
    }

    nonisolated static func importMemo(from source: URL, projectId: String, publisher: (any RecordingPublishing)? = nil,
                                       importRoot: URL = defaultImportRoot) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension.lowercased()
            guard RecordingFiles.supportedAudioExtensions.contains(ext) else { throw ImportError.unsupportedAudio }
            _ = try RecordingFiles.projectURL(projectId: projectId, memosRoot: RecordingFiles.memosRoot())
            // The import's id is fixed before anything is copied; its private copy is
            // `<id>.<ext>` beside a record of what it is for, so a killed import is
            // recovered or disposed of at the next launch (T1.21, T1.22).
            let id = UUID().uuidString.lowercased()
            let stem = RecordingFiles.sanitizeName(source.deletingPathExtension().lastPathComponent)
            let displayName = "\(stem.isEmpty || stem.hasPrefix(".") ? "Imported recording" : stem).\(ext)"
            let staging = importRoot.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: importRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            var record = ImportRecord(id: id, projectId: projectId, displayName: displayName, verified: false)
            try record.write(in: staging)
            var finished = false
            // A failed import disposes of its own private copy; a finished one is gone with publication.
            defer { if !finished { try? FileManager.default.removeItem(at: staging) } }
            let copied = staging.appendingPathComponent("\(id).\(ext)")
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
            record.verified = true
            try record.write(in: staging)
            // The source's name becomes the recording's display name; its file is `<id>.<ext>`.
            let url = try await publishImported(copied, projectId: projectId, displayName: displayName, id: id, publisher: publisher)
            finished = true
            try? FileManager.default.removeItem(at: staging)
            return url
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
        stopPlayback(ifPlayingAnyOf: [url])
        do {
            guard let publisher else { throw RecordingLibraryError.unavailable }
            let trashed = try publisher.trashRecording(at: url, trashedAt: Date())
            onFilesChanged?()
            return trashed
        } catch {
            lastError = "Couldn't move recording to trash: \(error.localizedDescription)"
            return nil
        }
    }

    /// Moves a trashed recording back to its song; it keeps its id and file name (A36).
    func restoreTrashedMemo(_ trashed: TrashedVoiceMemo) {
        stopPlayback(ifPlayingAnyOf: [trashed.url])
        do {
            guard let publisher else { throw RecordingLibraryError.unavailable }
            _ = try publisher.untrashRecording(trashed)
            RecordingFiles.cleanUpEmptyTrashFolder(trashed.url.deletingLastPathComponent())
            onFilesChanged?()
        } catch {
            lastError = "Couldn't restore recording: \(error.localizedDescription)"
        }
    }

    /// The recordings Trash this service removes files from (the library's).
    @ObservationIgnored var trashRoot: URL = RecordingFiles.memosTrashRoot()

    /// Permanently delete a trashed recording: recorded with its digest and length,
    /// playback of it stopped by id, and unlinked only while it holds those bytes (T1.25).
    @discardableResult
    func permanentlyDeleteTrashedMemo(_ trashed: TrashedVoiceMemo, sha256: String, bytes: Int64) -> Bool {
        stopPlayback(ids: trashed.recordingId.map { [$0] } ?? [], files: [trashed.url])
        do {
            try SyncIdentity.validateProjectId(trashed.projectId)
            if let publisher {
                try publisher.deleteTrashedFile(trashed, sha256: sha256, bytes: bytes)
            } else {
                let kept = try RecordingFiles.deleteVerified([.init(path: RecordingFiles.canonicalPath(trashed.url), sha256: sha256, bytes: bytes)],
                                                             memosRoot: trashRoot, within: [trashRoot])
                guard kept.isEmpty else { throw RecordingLibraryError.notVerified }
                RecordingFiles.cleanUpEmptyTrashFolder(trashed.url.deletingLastPathComponent())
            }
            return true
        } catch {
            lastError = "Couldn't remove the local recording file. Writers Block will retry cleanup."
            return false
        }
    }

    /// The same, with the bytes there now as the proof.
    @discardableResult
    func permanentlyDeleteTrashedMemo(_ trashed: TrashedVoiceMemo) -> Bool {
        stopPlayback(ids: trashed.recordingId.map { [$0] } ?? [], files: [trashed.url])
        guard let sha = try? RecordingFiles.sha256(of: trashed.url), let bytes = try? RecordingFiles.facts(trashed.url).size else {
            lastError = "Couldn't remove the local recording file. Writers Block will retry cleanup."
            return false
        }
        return permanentlyDeleteTrashedMemo(trashed, sha256: sha, bytes: bytes)
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
        audioIntentRevision &+= 1
        let permissionRevision = audioIntentRevision
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
        guard audioIntentRevision == permissionRevision else { return }

        stopPlayback()
        let recordingRevision = audioIntentRevision

        let url = RecordingFiles.recorderStagingURL(for: projectId, takeId: UUID().uuidString.lowercased(), root: stagingRoot)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            recordingActivationRevision = recordingRevision
            let result: Result<Void, Error> = await withCheckedContinuation { continuation in
                sessionTransitions.activateRecording { continuation.resume(returning: $0) }
            }
            try result.get()
        } catch {
            if recordingActivationRevision == recordingRevision { recordingActivationRevision = nil }
            guard audioIntentRevision == recordingRevision else { return }
            failToStartRecording()
            return
        }
        if recordingActivationRevision == recordingRevision { recordingActivationRevision = nil }
        guard audioIntentRevision == recordingRevision else { return }

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
        recordingProjectId = projectId
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

    /// Stops the recorder; a recording that finished is published into the memo
    /// folder (with its library row first). One that failed stays in staging.
    /// Stops the recorder. The recording is published (row first, then file) only
    /// from the recorder's completion callback, and only when it finished
    /// successfully; a failed one stays in staging and the failure is shown.
    func stopRecording() {
        audioIntentRevision &+= 1
        let shouldDeactivateSession = audioRecorder != nil || recordingActivationRevision != nil
        if let recorder = audioRecorder, let projectId = recordingProjectId {
            finishing = (recorder, projectId, delegateForwarder)
        }
        audioRecorder = nil
        recordingProjectId = nil
        finishing?.recorder.stop()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        meteringTimer?.invalidate()
        meteringTimer = nil
        recordingStartTime = nil
        delegateForwarder = nil
        let finishedRecording = isRecording
        isRecording = false
        recordingElapsed = 0
        averagePowerNormalized = 0
        if finishedRecording { onFilesChanged?() }

        // Deactivate so other apps (Music, Podcast) can resume their sessions.
        if shouldDeactivateSession {
            sessionTransitions.deactivate()
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
        sessionTransitions.deactivate()
        lastError = "Couldn't start recording. Check the microphone and try again."
    }

    // MARK: - Playback

    func togglePlayback(url: URL) {
        if (isPlaying && activePlayURL == url) || pendingPlayURL == url {
            stopPlayback()
            return
        }
        guard playbackAllowed?(url) ?? true else {
            lastError = "This recording was deleted and can't be played."
            return
        }
        // A verified identity first: what plays can always be found and stopped.
        let identity = playbackIdentity?(url)
        guard playbackIdentity == nil || identity != nil else {
            lastError = "This recording could not be read, so it can't be played."
            return
        }
        if isRecording || recordingActivationRevision != nil { stopRecording() }
        stopPlayback()
        pendingPlayURL = url
        playingIdentity = identity
        let playbackRevision = audioIntentRevision
        sessionTransitions.activatePlayback { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishPlaybackActivation(result, url: url, revision: playbackRevision)
            }
        }
    }

    private func finishPlaybackActivation(
        _ result: Result<Void, Error>, url: URL, revision: UInt64
    ) {
        guard audioIntentRevision == revision else { return }
        do {
            try result.get()
        } catch {
            pendingPlayURL = nil
            return
        }
        pendingPlayURL = nil
        // Checked again as the player starts: removed meanwhile, it does not play.
        guard playbackAllowed?(url) ?? true, playbackIdentity?(url) == playingIdentity else {
            playingIdentity = nil
            sessionTransitions.deactivate()
            return
        }

        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            sessionTransitions.deactivate()
            return
        }

        let forwarder = VoiceMemoDelegate(service: self)
        delegateForwarder = forwarder
        player.delegate = forwarder
        guard player.play() else {
            sessionTransitions.deactivate()
            return
        }

        audioPlayer = player
        activePlayURL = url
        isPlaying = true
    }

    /// Stops playback (or a pending start) of any of these recordings, by id, or of
    /// any of these files.
    func stopPlayback(ids: Set<String>, files: [URL]) {
        if let identity = playingIdentity, ids.contains(identity) {
            stopPlayback()
            return
        }
        if let playing = activePlayURL ?? pendingPlayURL, let id = RecordingFiles.storedId(of: playing), ids.contains(id) {
            stopPlayback()
            return
        }
        stopPlayback(ifPlayingAnyOf: files)
    }

    /// Stops playback (or a pending start) of any of these files.
    func stopPlayback(ifPlayingAnyOf files: [URL]) {
        let paths = Set(files.map(RecordingFiles.canonicalPath))
        if let playing = activePlayURL ?? pendingPlayURL, paths.contains(RecordingFiles.canonicalPath(playing)) { stopPlayback() }
    }

    /// Stops playback (or a pending start) of anything under these folder paths.
    func stopPlayback(ifPlayingWithin folders: [String]) {
        if let playing = activePlayURL ?? pendingPlayURL,
           folders.contains(where: { RecordingFiles.canonicalPath(playing).hasPrefix($0) }) { stopPlayback() }
    }

    func stopPlayback() {
        audioIntentRevision &+= 1
        playingIdentity = nil
        let hadPlayback = audioPlayer != nil || pendingPlayURL != nil
        audioPlayer?.stop()
        audioPlayer = nil
        activePlayURL = nil
        pendingPlayURL = nil
        delegateForwarder = nil
        isPlaying = false
        if hadPlayback { sessionTransitions.deactivate() }
    }

    // MARK: - Delete

    // MARK: - Rename

    /// Renames for the user: the recording's display name changes and its file
    /// keeps its name (A36). Returns the file, which does not move.
    @discardableResult
    func renameMemo(at url: URL, to newBasename: String) throws -> URL {
        let sanitized = RecordingFiles.sanitizeName(newBasename)
        guard !sanitized.isEmpty else { return url }
        guard let publisher else { throw RecordingLibraryError.unavailable }
        try publisher.renameRecording(at: url, to: "\(sanitized).\(url.pathExtension.lowercased())")
        onFilesChanged?()
        return url
    }

    /// A take the recorder reported finished: its marker (with the finish time)
    /// is written first, so a failure or a crash leaves it recoverable, then it is
    /// published (A27/A31). A marker that cannot be written stops here: the take
    /// waits, unpublished, and the failure is shown.
    func publishRecording(_ staged: URL, projectId: String) {
        let folder = staged.deletingLastPathComponent()
        let finishedAt = Date(millisecondsSince1970: Date().epochMilliseconds)
        do {
            try RecordingFiles.writeFinishedMarker(finishedAt, in: folder)
        } catch {
            lastError = "Couldn't finish saving the recording. It is kept on this device; tap Retry to save it."
            refreshPendingTakes()
            return
        }
        publish(PendingTake(id: folder.lastPathComponent, projectId: projectId, folder: folder, audio: staged, state: .finished(finishedAt)))
        refreshPendingTakes()
    }

    /// Publishes every waiting take; the caller brings the library up to date
    /// first, so a take already published (by id) counts as saved. A take without
    /// a marker is published only when its container is a finished recording.
    func retryPendingTakes() async {
        guard let publisher else {
            await retryPendingTakesHoldingGate()
            return
        }
        await publisher.withGate { await retryPendingTakesHoldingGate() }
    }

    private func retryPendingTakesHoldingGate() async {
        refreshPendingTakes()
        for take in pendingTakes {
            switch take.state {
            case .finished:
                publish(take)
            case .unreadableMarker:
                // A marker no build can read (T5.11): it is kept aside, and the take's
                // own container decides, as for a take with no marker.
                let marker = take.folder.appendingPathComponent(RecordingFiles.finishedTakeMarker)
                try? RecordingFiles.exclusiveRename(marker, to: take.folder.appendingPathComponent("finished.unreadable-\(Date().epochMilliseconds)"))
                guard let audio = take.audio else { continue }
                switch await RecordingFiles.checkFinishedContainer(audio) {
                case .complete:
                    if let finishedAt = try? RecordingFiles.facts(audio).modified, (try? RecordingFiles.writeFinishedMarker(finishedAt, in: take.folder)) != nil {
                        publish(PendingTake(id: take.id, projectId: take.projectId, folder: take.folder, audio: audio, state: .finished(finishedAt)))
                    }
                case .invalid:
                    markFailed(take)
                case .uninspectable:
                    lastError = "A recording waiting to be saved could not be read. It is kept on this device; tap Retry to try again."
                }
            case .unconfirmed:
                guard let audio = take.audio else { continue }
                switch await RecordingFiles.checkFinishedContainer(audio) {
                case .complete:
                    do {
                        let finishedAt = try RecordingFiles.facts(audio).modified
                        try RecordingFiles.writeFinishedMarker(finishedAt, in: take.folder)
                        publish(PendingTake(id: take.id, projectId: take.projectId, folder: take.folder, audio: audio, state: .finished(finishedAt)))
                    } catch {
                        lastError = "A recording waiting to be saved could not be read. It is kept on this device; tap Retry to try again."
                    }
                case .invalid:
                    markFailed(take)
                case .uninspectable:
                    lastError = "A recording waiting to be saved could not be read. It is kept on this device; tap Retry to try again."
                }
            case .failed:
                break
            }
        }
        refreshPendingTakes()
    }

    private func publish(_ take: PendingTake) {
        guard case .finished(let finishedAt) = take.state else { return }
        let staged = take.audio ?? take.folder.appendingPathComponent("missing.m4a")
        do {
            // The take's name for the user is its finish time; its file becomes `<id>.m4a`.
            guard let publisher else { throw RecordingLibraryError.unavailable }
            _ = try publisher.publishFinished(staged, projectId: take.projectId, preferredName: "\(finishedAt.epochMilliseconds).\(staged.pathExtension.lowercased())",
                                              origin: .recorded, id: take.id, finishedAt: finishedAt)
        } catch RecordingLibraryError.busy {
            // Another recordings change holds the library: the take waits (its marker is
            // written) and is published as soon as the gate is free.
            Task { [weak self] in await self?.retryPendingTakes() }
            return
        } catch RecordingLibraryError.takeMissing {
            // Neither a row nor its audio: definitively nothing to save.
            markFailed(take)
            return
        } catch {
            // Before or after the move, the take keeps its marker and waits; a retry
            // resolves it by id.
            lastError = "Couldn't save the recording: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) It is kept on this device; tap Retry to save it."
            return
        }
        forget(take)
        publishedRevision &+= 1
        onFilesChanged?()
    }

    /// Deletes a take that could not be saved, on the user's explicit choice (T5.12).
    func deleteFailedTake(_ take: PendingTake) {
        guard failedTakes.contains(take) else { return }
        do {
            try FileManager.default.removeItem(at: take.folder)
        } catch {
            lastError = "Couldn't delete that recording. It is kept on this device."
        }
        refreshPendingTakes()
    }

    private func markFailed(_ take: PendingTake) {
        try? Data().write(to: take.folder.appendingPathComponent(RecordingFiles.failedTakeMarker), options: .atomic)
    }

    /// The take is saved: its marker goes, and its folder once empty.
    private func forget(_ take: PendingTake) {
        try? FileManager.default.removeItem(at: take.folder.appendingPathComponent(RecordingFiles.finishedTakeMarker))
        if (try? FileManager.default.contentsOfDirectory(atPath: take.folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: take.folder)
        }
    }

    /// The recordings changed (a deletion applied, a restore): lists reload, and a
    /// recording that may no longer be played stops (A28).
    func recordingsChanged() {
        publishedRevision &+= 1
        if let playing = activePlayURL ?? pendingPlayURL,
           playbackAllowed?(playing) == false || playbackIdentity?(playing) != playingIdentity {
            stopPlayback()
        }
    }

    // MARK: - Callbacks from delegate forwarder

    fileprivate func recordingDidFinish(_ recorder: AVAudioRecorder, successfully: Bool) {
        // The recorder ended on its own (an interruption or a limit): tidy up first.
        if audioRecorder === recorder { stopRecording() }
        guard let finished = finishing, finished.recorder === recorder else { return }
        finishing = nil
        if successfully {
            publishRecording(recorder.url, projectId: finished.projectId)
        } else {
            lastError = "The recording could not be finished. Its audio was kept on this device and was not added to the song."
        }
    }

    fileprivate func playbackDidFinish(_ player: AVAudioPlayer) {
        guard audioPlayer === player else { return }
        stopPlayback()
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
            self?.service?.recordingDidFinish(recorder, successfully: flag)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.service?.playbackDidFinish(player)
        }
    }
}
