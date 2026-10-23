import AVFoundation
import CryptoKit
import Foundation

// A recording sitting in the Trash Bin. On disk it is `<recordingId>.<ext>`
// (A36); its name and deletion time come from the recording's metadata.
struct TrashedVoiceMemo: Identifiable, Sendable {
    let url: URL
    let projectId: String
    /// The recording's display name (with extension).
    let originalName: String
    let deletedAt: Date
    /// The recording's id, when it has one (every recording except a file the
    /// library has not taken in yet).
    var recordingId: String? = nil
    // nonisolated: the project builds with -default-isolation=MainActor, and these
    // are read from nonisolated static purge/expiry helpers.
    nonisolated var deleteAfter: Date { deletedAt.addingTimeInterval(trashRetentionInterval) }
    nonisolated var id: String { url.absoluteString }
}

/// Shared recording file policy. Media and observable state stay in VoiceMemoService.
enum RecordingFiles {
    nonisolated static let supportedAudioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac"]

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

    /// Where the recorder writes; a recording is published into the memo folder
    /// only when it finishes, so nothing reads it while it is being written.
    /// Each take records into its own folder named by the take's id, which is
    /// its recording id from the start (A27).
    nonisolated static func recorderStagingURL(for projectId: String, takeId: String, root: URL = recorderStagingRoot()) -> URL {
        root.appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent(takeId, isDirectory: true)
            .appendingPathComponent(newMemoURL(for: projectId).lastPathComponent)
    }

    nonisolated static func recorderStagingRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recording-in-progress", isDirectory: true)
    }

    /// Written beside a take's audio when the recorder reports it finished; a take
    /// folder without it is unfinished and is never published.
    nonisolated static let finishedTakeMarker = "finished"
    /// Written when a take is definitively not saveable; its files stay.
    nonisolated static let failedTakeMarker = "failed"

    /// The finished marker holds the finish time (epoch ms), written atomically.
    nonisolated static func writeFinishedMarker(_ finishedAt: Date, in folder: URL) throws {
        try Data(String(finishedAt.epochMilliseconds).utf8).write(to: folder.appendingPathComponent(finishedTakeMarker), options: .atomic)
    }

    /// Nil when the marker cannot be read or parsed.
    nonisolated static func readFinishedMarker(in folder: URL) -> Date? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(finishedTakeMarker)),
              let text = String(data: data, encoding: .utf8), let millis = Int64(text) else { return nil }
        return Date(millisecondsSince1970: millis)
    }

    enum ContainerCheck: Equatable { case complete, invalid, uninspectable }

    /// Whether a take with no finished marker is a finished recording: its bytes
    /// read, its audio track decodes to the end of the stream without error, and
    /// the decoded sample count matches the count the container declares. A file
    /// cut off before its index, after it, or mid-data fails.
    nonisolated static func checkFinishedContainer(_ url: URL) async -> ContainerCheck {
        // Bytes that cannot be read cannot be judged.
        guard (try? sha256(of: url)) != nil else { return .uninspectable }
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return demonstratesMalformed(error) ? .invalid : .uninspectable
        }
        // A container that parses and holds no audio is not a recording.
        guard let track = tracks.first else { return .invalid }
        let range: CMTimeRange
        let formats: [CMFormatDescription]
        do {
            range = try await track.load(.timeRange)
            formats = try await track.load(.formatDescriptions)
        } catch {
            return demonstratesMalformed(error) ? .invalid : .uninspectable
        }
        guard let format = formats.first, let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mSampleRate > 0, range.duration.isNumeric else { return .invalid }
        let declared = Int64((range.duration.seconds * description.mSampleRate).rounded())
        guard declared > 0 else { return .invalid }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return demonstratesMalformed(error) ? .invalid : .uninspectable
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        guard reader.canAdd(output) else { return .uninspectable }
        reader.add(output)
        guard reader.startReading() else {
            return reader.error.map(demonstratesMalformed) == true ? .invalid : .uninspectable
        }
        var decoded: Int64 = 0
        while let buffer = output.copyNextSampleBuffer() { decoded += Int64(CMSampleBufferGetNumSamples(buffer)) }
        switch reader.status {
        case .completed:
            // AAC trims its encoder delay and padding; that leaves under two packets of slack.
            return abs(decoded - declared) <= 2048 ? .complete : .invalid
        case .failed:
            return reader.error.map(demonstratesMalformed) == true ? .invalid : .uninspectable
        default:
            return .uninspectable
        }
    }

    /// Errors that show the file itself is not a usable container (it was read,
    /// and its structure or data is wrong), as opposed to a failure to look.
    nonisolated private static func demonstratesMalformed(_ error: Error) -> Bool {
        let codes: Set<Int> = [
            AVError.Code.fileFormatNotRecognized.rawValue,
            AVError.Code.decodeFailed.rawValue,
            AVError.Code.undecodableMediaData.rawValue,
            AVError.Code.failedToParse.rawValue,
            AVError.Code.fileFailedToParse.rawValue,
            // The index points at samples the file does not hold: cut off.
            AVError.Code.invalidSampleCursor.rawValue,
        ]
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain, codes.contains(nsError.code) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return demonstratesMalformed(underlying) }
        return false
    }

    nonisolated static func newMemoURL(for projectId: String) -> URL {
        let folder = memoFolder(for: projectId)
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        return folder.appendingPathComponent("\(timestamp).m4a")
    }

    // MARK: - Names on disk (A36)

    /// The file name a recording has on disk: `<recordingId>.<ext>`, the extension
    /// taken from its display name (m4a when that has none we play).
    nonisolated static func storedName(id: String, displayName: String) -> String {
        "\(id).\(storedExtension(of: displayName))"
    }

    nonisolated static func storedExtension(of name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return supportedAudioExtensions.contains(ext) ? ext : "m4a"
    }

    /// The recording id a file is named by, when its name is `<lower-case uuid>.<ext>`.
    nonisolated static func storedId(of url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: stem) != nil, stem == stem.lowercased(),
              supportedAudioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return stem
    }

    /// A Trash file name from before A36, "<deletedAtMs>__<originalName>".
    nonisolated static func legacyTrashName(_ name: String) -> (deletedAt: Date, originalName: String)? {
        guard let separatorRange = name.range(of: trashNameSeparator),
              separatorRange.lowerBound != name.startIndex,
              let deletedAtMs = Double(name[..<separatorRange.lowerBound]) else { return nil }
        let originalName = String(name[separatorRange.upperBound...])
        guard !originalName.isEmpty else { return nil }
        return (Date(timeIntervalSince1970: deletedAtMs / 1000), originalName)
    }

    /// Remove a project's entire memo folder — live and trashed. Called on
    /// permanent delete and on trash-purge expiry so orphaned audio doesn't
    /// accumulate on disk.
    @discardableResult
    static func deleteMemosFolder(for projectId: String) -> Bool {
        do {
            let live = try projectURL(projectId: projectId, memosRoot: memosRoot())
            let trash = try projectURL(projectId: projectId, memosRoot: memosTrashRoot())
            try removeItemIfPresent(at: live, within: memosRoot())
            try removeItemIfPresent(at: trash, within: memosTrashRoot())
            return true
        } catch {
            return false
        }
    }

    // MARK: - Recordings Trash

    /// Separated the deletion time from the original name in Trash file names before A36.
    nonisolated static let trashNameSeparator = "__"

    nonisolated static func memosTrashRoot() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("voice-memos-trash", isDirectory: true)
    }

    nonisolated static func trashFolder(for projectId: String) -> URL {
        memosTrashRoot().appendingPathComponent(projectId, isDirectory: true)
    }

    /// Remove a project's trash folder once its last recording leaves it.
    nonisolated static func cleanUpEmptyTrashFolder(_ folder: URL) {
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ), contents.isEmpty {
            try? removeItemIfPresent(at: folder, within: memosTrashRoot())
        }
    }

    nonisolated static func removeItemIfPresent(at url: URL, within root: URL) throws {
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

    /// Strip illegal filesystem characters from a candidate display name.
    /// Rules: trim whitespace; remove `/`, `:`, `\0`; collapse runs of whitespace;
    /// reserve room within the shared 240-byte backup filename limit.
    nonisolated static func sanitizeName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip characters that are illegal in HFS+ / APFS filenames.
        let illegal = CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines).union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        s = s.unicodeScalars
            .filter { !illegal.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        // Collapse interior whitespace runs to a single space.
        s = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Leave room for an extension and collision suffix within the shared backup limit.
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

    /// The byte limit for a recording's file name (shared with Android and the manifest).
    nonisolated static let maxFileNameBytes = 240

    /// Where restored audio is written before it is verified and moved into
    /// place; beside the memos root, so the move is a rename on the same volume.
    nonisolated static func stagingRoot(for memosRoot: URL) -> URL {
        memosRoot.deletingLastPathComponent().appendingPathComponent("recording-staging", isDirectory: true)
    }

    /// Where copies that are not a recording's canonical file, and audio a known
    /// deletion covers, are kept (A26/A28): never listed, adopted or deleted.
    nonisolated static func quarantineRoot(for memosRoot: URL) -> URL {
        memosRoot.deletingLastPathComponent().appendingPathComponent("recording-quarantine", isDirectory: true)
    }

    /// Moves `file` (in a memo or Trash project folder) into quarantine as
    /// `<recordingId>.<ext>` (A36); a second copy of one id goes in a folder of
    /// its own. Never replaces anything.
    nonisolated static func quarantine(_ file: URL, recordingId: String, memosRoot: URL, trashRoot: URL) throws {
        guard isRecordingFile(file, in: [memosRoot, trashRoot]) else { throw SyncValidationError.pathOutsideMemoRoot }
        let projectId = file.deletingLastPathComponent().lastPathComponent
        var folder = quarantineRoot(for: memosRoot).appendingPathComponent(projectId, isDirectory: true)
        let name = "\(recordingId).\(storedExtension(of: file.lastPathComponent))"
        if try exists(folder.appendingPathComponent(name)) {
            folder = folder.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent(name))
    }

    /// Size and modification time, read now; a file that cannot be read throws.
    nonisolated static func facts(_ url: URL) throws -> (size: Int64, modified: Date, inode: UInt64) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value, let modified = attributes[.modificationDate] as? Date,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw CocoaError(.fileReadUnknown)
        }
        return (size, modified, inode)
    }

    /// SHA-256 of a file's bytes, read in chunks.
    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True or false only when the file system confirms it; any other failure to
    /// look (permissions, I/O) throws, so it is never taken for absence.
    nonisolated static func exists(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return false
        }
    }

    /// True only for a file itself (not a symbolic link) directly in a song folder of
    /// one of `roots` (finding 10): checked before a move is recorded and again
    /// before it is made.
    nonisolated static func isRecordingFile(_ url: URL, in roots: [URL]) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink != true, values.isRegularFile == true else { return false }
        let songFolder = url.deletingLastPathComponent()
        guard (try? songFolder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        let root = canonicalPath(songFolder.deletingLastPathComponent())
        return roots.contains { canonicalPath($0) == root }
    }

    nonisolated static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Moves recorded before the save that decides them and finished after it, or
    /// at the next run (A28, finding 4): files going to quarantine, and files of
    /// recordings removed on another device going to the recordings Trash. A
    /// detached Trash entry stays recorded, so it is never adopted again.
    nonisolated struct PendingMoves: Codable, Equatable, Sendable {
        var quarantine: [Quarantine] = []
        var detach: [Detach] = []
        /// Files written outside the library (a draft's copied recordings) that the
        /// next reconcile takes in under this identity.
        var adopt: [Adopt] = []

        /// A file going to quarantine, with the digest it was decided on: at replay
        /// other bytes there are not moved (they are adopted on their own).
        nonisolated struct Quarantine: Codable, Equatable, Hashable, Sendable {
            var path: String
            var sha256: String
            /// The id the bytes are kept under in quarantine.
            var recordingId: String
        }

        /// A recording removed on another device, moved to the recordings Trash here.
        /// It keeps its id, name and precedence time, so a later tombstone still
        /// applies to it and restoring it keeps its id.
        nonisolated struct Detach: Codable, Equatable, Hashable, Sendable {
            var recordingId: String
            /// Empty once the move is done.
            var source: String
            var destination: String
            /// The removed recording's digest: only those bytes are moved or kept.
            var sha256: String
            var displayName: String
            /// Its precedence time (epoch ms).
            var at: Int64
            /// When it was moved to the Trash (epoch ms); the Trash deadline counts from it.
            var detachedAt: Int64
            /// A37: `at` is a repaired time (absent in older records: false).
            var repaired: Bool? = nil
        }

        nonisolated struct Adopt: Codable, Equatable, Hashable, Sendable {
            var path: String
            var recordingId: String
            var displayName: String
            var sha256: String
        }

        var isEmpty: Bool { quarantine.isEmpty && detach.isEmpty && adopt.isEmpty }
        /// Never adopted: waiting for quarantine, or a detached entry either side of its move.
        /// A finished detach stays listed: the reconcile keeps it under its id while
        /// its bytes are its own, and applies later tombstones to it.
        var adoptionHidden: Set<String> {
            Set(quarantine.map(\.path) + detach.filter { !$0.source.isEmpty }.flatMap { [$0.source, $0.destination] })
        }
        /// Not listed or played: waiting for quarantine, or still at its source.
        var listingHidden: Set<String> { Set(quarantine.map(\.path) + detach.map(\.source).filter { !$0.isEmpty }) }
    }

    /// `root` is the memo or the Trash root; both sit in the same folder. A missing
    /// record is empty; one that cannot be read or parsed throws (fail closed, A31).
    nonisolated static func readPendingMoves(for root: URL) throws -> PendingMoves {
        let url = pendingMovesURL(for: root)
        guard try exists(url) else { return PendingMoves() }
        return try JSONDecoder().decode(PendingMoves.self, from: Data(contentsOf: url))
    }

    nonisolated static func writePendingMoves(_ moves: PendingMoves, for root: URL) throws {
        let url = pendingMovesURL(for: root)
        if moves.isEmpty {
            if try exists(url) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(moves).write(to: url, options: .atomic)
    }

    /// For listings and playback: nil when the record cannot be read, so nothing is listed.
    nonisolated static func pendingQuarantine(for root: URL) -> Set<String>? {
        (try? readPendingMoves(for: root))?.listingHidden
    }

    /// Records files for quarantine with their current digests (tests).
    nonisolated static func setPendingQuarantine(_ paths: Set<String>, for root: URL) throws {
        var moves = try readPendingMoves(for: root)
        moves.quarantine = try paths.sorted().map { path in
            let digest = try sha256(of: URL(fileURLWithPath: path))
            return PendingMoves.Quarantine(path: path, sha256: digest, recordingId: storedId(of: URL(fileURLWithPath: path)) ?? UUID().uuidString.lowercased())
        }
        try writePendingMoves(moves, for: root)
    }

    private nonisolated static func pendingMovesURL(for root: URL) -> URL {
        quarantineRoot(for: root).appendingPathComponent("pending-moves.json")
    }

    /// Recovery for an interrupted restore or import, run only as one starts:
    /// anything still staged never reached the memo folders, so it is dropped.
    nonisolated static func clearStaging(for memosRoot: URL) {
        try? FileManager.default.removeItem(at: stagingRoot(for: memosRoot))
    }

    /// Writes `data` to a new staging file, reads it back and checks its digest;
    /// runs off the main actor. The caller moves it into place or removes it.
    /// Writes `data` to staging as `storedName` (the recording's `<id>.<ext>`, A36)
    /// through a temporary name and a move that never replaces: the bytes are read
    /// back and checked first. A staged file of that name left by an interrupted run
    /// is used only when it holds the same bytes. Runs off the main actor; the caller
    /// moves the result into place or removes it.
    nonisolated static func stageVerified(_ data: Data, sha256: String, storedName: String, in staging: URL, modifiedAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let temporary = staging.appendingPathComponent("\(UUID().uuidString).partial")
        let staged = staging.appendingPathComponent(storedName)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        guard try RecordingFiles.sha256(of: temporary) == sha256, try facts(temporary).size == Int64(data.count) else {
            throw SyncValidationError.invalidRecording
        }
        try? FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: temporary.path)
        do {
            try FileManager.default.moveItem(at: temporary, to: staged)
        } catch CocoaError.fileWriteFileExists {
            guard try RecordingFiles.sha256(of: staged) == sha256, try facts(staged).size == Int64(data.count) else { throw SyncValidationError.invalidRecording }
        }
        return staged
    }

    nonisolated static func projectURL(projectId: String, memosRoot: URL) throws -> URL {
        try SyncIdentity.validateProjectId(projectId)
        let root = memosRoot.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent(projectId, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        try requireDescendant(folder, of: root)
        return folder
    }

    nonisolated static func localURL(projectId: String, fileName: String, memosRoot: URL) throws -> URL {
        try SyncIdentity.validateFileName(fileName)
        let root = memosRoot.standardizedFileURL.resolvingSymlinksInPath()
        let folder = try projectURL(projectId: projectId, memosRoot: root)
        let url = folder.appendingPathComponent(fileName).standardizedFileURL.resolvingSymlinksInPath()
        try requireDescendant(url, of: root)
        return url
    }

    nonisolated private static func requireDescendant(_ url: URL, of root: URL) throws {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix), url.path != root.path else { throw SyncValidationError.pathOutsideMemoRoot }
    }

}
