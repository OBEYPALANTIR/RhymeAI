import AVFoundation
import CryptoKit
import Darwin
import Foundation
import os

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
    /// The take's audio is `<takeId>.m4a` (A36 applies to staging too).
    nonisolated static func recorderStagingURL(for projectId: String, takeId: String, root: URL = recorderStagingRoot()) -> URL {
        root.appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent(takeId, isDirectory: true)
            .appendingPathComponent("\(takeId).m4a")
    }

    /// Takes in the recorder's staging folder (finished or not yet published).
    nonisolated static func waitingTakeCount(root: URL = recorderStagingRoot()) -> Int {
        let projects = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return projects.reduce(0) { count, project in
            count + ((try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?.count ?? 0)
        }
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

    /// Nil when the marker cannot be read or parsed. A marker from an earlier
    /// build that held nothing (written only after the recorder finished) is read
    /// as finished at the time it was written, and rewritten in the current form.
    nonisolated static func readFinishedMarker(in folder: URL) -> Date? {
        let marker = folder.appendingPathComponent(finishedTakeMarker)
        guard let data = try? Data(contentsOf: marker) else { return nil }
        if data.isEmpty {
            guard let written = try? facts(marker).modified, written.epochMilliseconds > 0 else { return nil }
            let finishedAt = Date(millisecondsSince1970: written.epochMilliseconds)
            try? writeFinishedMarker(finishedAt, in: folder)
            return finishedAt
        }
        guard let text = String(data: data, encoding: .utf8), let millis = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              millis > 0, millis < maxPlausibleMilliseconds else { return nil }
        return Date(millisecondsSince1970: millis)
    }

    /// Times past this (year 3000) are not times a recording was made.
    nonisolated static let maxPlausibleMilliseconds: Int64 = 32_503_680_000_000

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

    /// The recording id a file is named by, when its name is `<uuid>.<ext>`. Ids are
    /// lower-case now; earlier builds made upper-case ones, which keep their case
    /// (an id is never re-cased, so it stays the same identity everywhere).
    nonisolated static func storedId(of url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: stem) != nil, supportedAudioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        return stem
    }

    /// A Trash file name from before A36, "<deletedAtMs>__<originalName>".
    /// The time is whole epoch milliseconds; anything else (not finite, negative,
    /// past year 3000) is not a time, and the name is read as having none (0), which
    /// is then repaired and persisted like any missing time (A32).
    nonisolated static func legacyTrashName(_ name: String) -> (deletedAt: Date, originalName: String)? {
        guard let separatorRange = name.range(of: trashNameSeparator),
              separatorRange.lowerBound != name.startIndex else { return nil }
        let originalName = String(name[separatorRange.upperBound...])
        guard !originalName.isEmpty else { return nil }
        let stamp = name[..<separatorRange.lowerBound]
        guard stamp.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let millis = Int64(stamp) ?? 0
        return (Date(millisecondsSince1970: millis > 0 && millis < maxPlausibleMilliseconds ? millis : 0), originalName)
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
            removeEmptyFolder(folder, within: memosTrashRoot())
        }
    }

    /// Removes a folder inside `root` only while it is empty: `rmdir` refuses a
    /// folder that holds anything, so a file that appears meanwhile stays (T1.4).
    nonisolated static func removeEmptyFolder(_ url: URL, within root: URL) {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard canonicalURL.path != canonicalRoot.path, canonicalURL.path.hasPrefix(rootPrefix) else { return }
        rmdir(url.standardizedFileURL.path)
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

    /// Where a file going to quarantine goes: `<recordingId>.<ext>` in its song's
    /// quarantine folder, or in a folder of its own when that name is taken. Chosen
    /// when the move is recorded, so the record holds its destination.
    nonisolated static func quarantineDestination(for file: URL, recordingId: String, memosRoot: URL) throws -> URL {
        let projectId = file.deletingLastPathComponent().lastPathComponent
        let name = "\(recordingId).\(storedExtension(of: file.lastPathComponent))"
        let folder = quarantineRoot(for: memosRoot).appendingPathComponent(projectId, isDirectory: true)
        if try !exists(folder.appendingPathComponent(name)) { return folder.appendingPathComponent(name) }
        return folder.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true).appendingPathComponent(name)
    }

    /// Moves `file` (in a memo or Trash project folder) into quarantine at its
    /// recorded destination, verified and never replacing anything.
    nonisolated static func quarantine(_ file: URL, to destination: URL, sha256: String, bytes: Int64, memosRoot: URL, trashRoot: URL) throws {
        guard isRecordingFile(file, in: [memosRoot, trashRoot]) else { throw SyncValidationError.pathOutsideMemoRoot }
        try verifiedMove(file, to: destination, sha256: sha256, bytes: bytes, within: [quarantineRoot(for: memosRoot)])
    }

    /// Moves `source` to `target` without ever replacing, after checking that the
    /// folders between `target` and one of `roots` are real folders inside it, not
    /// symbolic links (finding 3); checked again once missing folders are made.
    /// Aliases above the roots (such as /var and /private/var) are resolved.
    nonisolated static func safeMove(_ source: URL, to target: URL, within roots: [URL]) throws {
        for root in roots { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        guard isSafeDestination(target, in: roots) else { throw SyncValidationError.pathOutsideMemoRoot }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard isSafeDestination(target, in: roots) else { throw SyncValidationError.pathOutsideMemoRoot }
        try exclusiveRename(source, to: target)
    }

    /// The one move every recording byte transition ends in: the source's digest
    /// and length are checked immediately before an exclusive rename into a checked
    /// destination, so neither other bytes nor an occupied destination are ever moved
    /// or replaced.
    nonisolated static func verifiedMove(_ source: URL, to target: URL, sha256: String, bytes: Int64, within roots: [URL]) throws {
        try BoundaryHooks.run(.beforeCheck, source, target)
        guard try facts(source).size == bytes, try self.sha256(of: source) == sha256 else { throw SyncValidationError.invalidRecording }
        try safeMove(source, to: target, within: roots)
        try BoundaryHooks.run(.afterPrimitive, source, target)
    }

    /// Tests only: observers of every move or unlink of recording bytes, called
    /// before the bytes are checked and after the primitive; a hook that throws stops
    /// the operation there, as a crash would. Each test registers its own hook and
    /// filters by its own folders, so tests running at once do not see each other.
    nonisolated enum BoundaryHooks {
        enum Point: Sendable { case beforeCheck, afterPrimitive }
        typealias Hook = @Sendable (Point, URL, URL?) throws -> Void
        private static let hooks = OSAllocatedUnfairLock(initialState: [UUID: Hook]())

        static func install(_ hook: @escaping Hook) -> UUID {
            let id = UUID()
            hooks.withLock { $0[id] = hook }
            return id
        }

        static func remove(_ id: UUID) { _ = hooks.withLock { $0.removeValue(forKey: id) } }

        static func run(_ point: Point, _ source: URL, _ target: URL?) throws {
            for hook in hooks.withLock({ Array($0.values) }) { try hook(point, source, target) }
        }
    }

    /// `rename(2)` with `RENAME_EXCL`: atomic, and it fails rather than replace an
    /// existing destination (the file system checks and renames in one step).
    nonisolated static func exclusiveRename(_ source: URL, to target: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { from in
            target.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return Int32(-1) }
                return renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            if errno == EEXIST { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path]) }
            if errno == ENOENT { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path]) }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))])
        }
    }

    /// True when every folder from `target`'s up to one of `roots` (at most two
    /// levels) is a real folder, so `target` resolves inside that root.
    nonisolated static func isSafeDestination(_ target: URL, in roots: [URL]) -> Bool {
        let rootPaths = Set(roots.map(canonicalPath))
        var folder = target.deletingLastPathComponent()
        for _ in 0..<3 {
            if rootPaths.contains(canonicalPath(folder)) { return true }
            if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
            folder = folder.deletingLastPathComponent()
        }
        return false
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
    /// detached Trash entry stays recorded, so it is never adopted again. Every
    /// entry carries its identity, source, destination, digest and length.
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
            /// Where it goes, chosen when recorded (nil only in records from before
            /// this field, filled in by `upgradePendingMoves`).
            var destination: String? = nil
            var bytes: Int64? = nil
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
            var bytes: Int64? = nil
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

        /// Every field a replay relies on, checked when the record is read (T3.23):
        /// absolute paths, valid ids, digests and lengths, and times.
        func validate() throws {
            func path(_ value: String) throws { guard value.hasPrefix("/"), !value.contains("\0") else { throw PendingMovesError.invalid } }
            func digest(_ value: String) throws {
                guard value.count == 64, value.unicodeScalars.allSatisfy({ "0123456789abcdef".unicodeScalars.contains($0) }) else { throw PendingMovesError.invalid }
            }
            for item in quarantine {
                try path(item.path); try digest(item.sha256); try SyncIdentity.validateRecordingId(item.recordingId)
                if let destination = item.destination { try path(destination) }
                if let bytes = item.bytes, bytes < 0 { throw PendingMovesError.invalid }
            }
            for item in detach {
                if !item.source.isEmpty { try path(item.source) }
                try path(item.destination); try digest(item.sha256); try SyncIdentity.validateRecordingId(item.recordingId)
                try SyncIdentity.validateDisplayName(item.displayName)
                guard item.at > 0, item.detachedAt > 0 else { throw PendingMovesError.invalid }
                if let bytes = item.bytes, bytes < 0 { throw PendingMovesError.invalid }
            }
            for item in adopt {
                try path(item.path); try digest(item.sha256); try SyncIdentity.validateRecordingId(item.recordingId)
                try SyncIdentity.validateDisplayName(item.displayName)
            }
        }
    }

    nonisolated enum PendingMovesError: Error, Equatable {
        /// The record is not one this build or an earlier one wrote, or a field in it is wrong.
        case invalid
        /// A record from an earlier build, not yet upgraded by `upgradePendingMoves`.
        case needsUpgrade
    }

    /// `root` is the memo or the Trash root; both sit in the same folder. A missing
    /// record is empty; one that cannot be read, parsed or validated throws (fail
    /// closed, A31). A record from an earlier build throws `needsUpgrade` until
    /// `upgradePendingMoves` has rewritten it.
    nonisolated static func readPendingMoves(for root: URL) throws -> PendingMoves {
        let url = pendingMovesURL(for: root)
        guard try exists(url) else { return PendingMoves() }
        let data = try Data(contentsOf: url)
        guard let moves = try? JSONDecoder().decode(PendingMoves.self, from: data) else {
            if HistoricalMoves.decode(data) != nil { throw PendingMovesError.needsUpgrade }
            throw PendingMovesError.invalid
        }
        try moves.validate()
        return moves
    }

    /// The shapes earlier builds wrote: a list of paths (cbc39e1); paths and
    /// three-field detaches (c725690); paths with digests and four-field detaches
    /// (89a9aa5 to a25a2c3); and the A36 shape before destinations and lengths.
    nonisolated enum HistoricalMoves {
        struct Detach: Decodable { var recordingId: String; var source: String; var destination: String; var sha256: String? }
        struct Quarantine: Decodable { var path: String; var sha256: String? }
        struct Shape: Decodable { var quarantine: [Quarantine]; var detach: [Detach]? }
        struct PathsShape: Decodable { var quarantine: [String]; var detach: [Detach]? }

        static func decode(_ data: Data) -> (quarantine: [Quarantine], detach: [Detach])? {
            if let paths = try? JSONDecoder().decode([String].self, from: data) { return (paths.map { Quarantine(path: $0) }, []) }
            if let shape = try? JSONDecoder().decode(PathsShape.self, from: data) { return (shape.quarantine.map { Quarantine(path: $0) }, shape.detach ?? []) }
            if let shape = try? JSONDecoder().decode(Shape.self, from: data) { return (shape.quarantine, shape.detach ?? []) }
            return nil
        }
    }

    /// Rewrites a move record from an earlier build (or the A36 shape without
    /// destinations and lengths) in the current shape, run before anything reads it.
    /// Proof missing from an old record is taken from the file now at its path (the
    /// bytes the record was decided on, as nothing moves a recorded file but its
    /// replay); a file gone since needs nothing. Suppression is kept: every old entry
    /// stays recorded. An old detach keeps its destination and gets a repaired time.
    /// A record in no known shape is left in place for `readPendingMoves` to refuse.
    nonisolated static func upgradePendingMoves(for memosRoot: URL, now: Int64, displayName: (String) -> String) throws {
        let url = pendingMovesURL(for: memosRoot)
        guard try exists(url) else { return }
        let data = try Data(contentsOf: url)
        var moves: PendingMoves
        if let current = try? JSONDecoder().decode(PendingMoves.self, from: data) {
            moves = current
        } else if let old = HistoricalMoves.decode(data) {
            moves = PendingMoves()
            for item in old.quarantine {
                let file = URL(fileURLWithPath: item.path)
                guard try exists(file) else { continue }
                let sha = try item.sha256 ?? sha256(of: file)
                let id = storedId(of: file) ?? RecordingBackupManifest.legacyRecordingId(
                    projectId: file.deletingLastPathComponent().lastPathComponent,
                    fileName: legacyTrashName(file.lastPathComponent)?.originalName ?? file.lastPathComponent, sha256: sha)
                moves.quarantine.append(.init(path: canonicalPath(file), sha256: sha, recordingId: id))
            }
            for item in old.detach {
                let held = URL(fileURLWithPath: item.source.isEmpty ? item.destination : item.source)
                guard try exists(held) else { continue }
                let sha = try item.sha256 ?? sha256(of: held)
                let name = legacyTrashName(URL(fileURLWithPath: item.destination).lastPathComponent)
                moves.detach.append(.init(recordingId: item.recordingId, source: item.source, destination: item.destination, sha256: sha,
                                          displayName: name?.originalName ?? displayName(item.recordingId), at: now,
                                          detachedAt: name.map(\.deletedAt.epochMilliseconds).flatMap { $0 > 0 ? $0 : nil } ?? now,
                                          repaired: true, bytes: try facts(held).size))
            }
        } else {
            return
        }
        // Destinations and lengths, when missing, are filled in from the files now.
        for index in moves.quarantine.indices {
            let file = URL(fileURLWithPath: moves.quarantine[index].path)
            guard try exists(file) else { continue }
            if moves.quarantine[index].bytes == nil { moves.quarantine[index].bytes = try facts(file).size }
            if moves.quarantine[index].destination == nil {
                moves.quarantine[index].destination = try quarantineDestination(for: file, recordingId: moves.quarantine[index].recordingId, memosRoot: memosRoot).path
            }
        }
        for index in moves.detach.indices where moves.detach[index].bytes == nil {
            let held = URL(fileURLWithPath: moves.detach[index].source.isEmpty ? moves.detach[index].destination : moves.detach[index].source)
            if try exists(held) { moves.detach[index].bytes = try facts(held).size }
            if moves.detach[index].at <= 0 { moves.detach[index].at = now; moves.detach[index].repaired = true }
            if moves.detach[index].detachedAt <= 0 { moves.detach[index].detachedAt = now }
        }
        guard let rewritten = try? JSONEncoder().encode(moves), rewritten != data else { return }
        try moves.validate()
        try writePendingMoves(moves, for: memosRoot)
    }

    /// Sets a damaged move record aside (kept beside it for diagnosis) so the
    /// library can run again; files it named stay where they are (T5.2).
    nonisolated static func setAsidePendingMoves(for memosRoot: URL, at time: Date = Date()) throws -> URL? {
        let url = pendingMovesURL(for: memosRoot)
        guard try exists(url) else { return nil }
        let aside = url.deletingLastPathComponent().appendingPathComponent("pending-moves.damaged-\(time.epochMilliseconds).json")
        try exclusiveRename(url, to: aside)
        return aside
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
            let file = URL(fileURLWithPath: path)
            let id = storedId(of: file) ?? UUID().uuidString.lowercased()
            return PendingMoves.Quarantine(path: path, sha256: try sha256(of: file), recordingId: id,
                                           destination: try quarantineDestination(for: file, recordingId: id, memosRoot: root).path,
                                           bytes: try facts(file).size)
        }
        try writePendingMoves(moves, for: root)
    }

    private nonisolated static func pendingMovesURL(for root: URL) -> URL {
        quarantineRoot(for: root).appendingPathComponent("pending-moves.json")
    }

    // MARK: - Verified deletion

    /// A deletion the user asked for (permanent delete, expiry, a song's
    /// recordings), recorded with each file's digest and length before anything is
    /// unlinked: only a file that still holds exactly those bytes is removed, at the
    /// boundary, and an interrupted deletion is finished the same way (T1.1–T1.4).
    nonisolated struct DeletionPlan: Codable, Equatable, Sendable {
        nonisolated struct Item: Codable, Equatable, Hashable, Sendable {
            var path: String
            var sha256: String
            var bytes: Int64
        }
        var items: [Item] = []
    }

    private nonisolated static func deletionPlanURL(for memosRoot: URL) -> URL {
        quarantineRoot(for: memosRoot).appendingPathComponent("deletion-plan.json")
    }

    nonisolated static func readDeletionPlan(for memosRoot: URL) throws -> DeletionPlan {
        let url = deletionPlanURL(for: memosRoot)
        guard try exists(url) else { return DeletionPlan() }
        return try JSONDecoder().decode(DeletionPlan.self, from: Data(contentsOf: url))
    }

    /// Records the plan, removes every file that still holds its recorded bytes and
    /// lies inside `roots`, then clears what was done. Returns the files kept (other
    /// bytes, or not a recording file there).
    @discardableResult
    nonisolated static func deleteVerified(_ items: [DeletionPlan.Item], memosRoot: URL, within roots: [URL]) throws -> [URL] {
        var plan = try readDeletionPlan(for: memosRoot)
        plan.items += items.filter { !plan.items.contains($0) }
        try writeDeletionPlan(plan, for: memosRoot)
        return try finishDeletionPlan(memosRoot: memosRoot, within: roots)
    }

    @discardableResult
    nonisolated static func finishDeletionPlan(memosRoot: URL, within roots: [URL]) throws -> [URL] {
        let plan = try readDeletionPlan(for: memosRoot)
        var kept: [URL] = []
        var remaining: [DeletionPlan.Item] = []
        for item in plan.items {
            let file = URL(fileURLWithPath: item.path)
            do {
                guard try exists(file) else { continue }
                try BoundaryHooks.run(.beforeCheck, file, nil)
                // Immediately before the unlink: still a recording file there, and still those bytes.
                guard isRecordingFile(file, in: roots), try facts(file).size == item.bytes, try sha256(of: file) == item.sha256 else {
                    kept.append(file)
                    continue
                }
                try FileManager.default.removeItem(at: file)
            } catch {
                remaining.append(item)
            }
        }
        try writeDeletionPlan(DeletionPlan(items: remaining), for: memosRoot)
        return kept
    }

    private nonisolated static func writeDeletionPlan(_ plan: DeletionPlan, for memosRoot: URL) throws {
        let url = deletionPlanURL(for: memosRoot)
        if plan.items.isEmpty {
            if try exists(url) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: url, options: .atomic)
    }

    /// Removes a song's memo and Trash folders once nothing is left in them.
    nonisolated static func removeEmptySongFolders(_ projectId: String, memosRoot: URL, trashRoot: URL) {
        for root in [memosRoot, trashRoot] {
            removeEmptyFolder(root.appendingPathComponent(projectId, isDirectory: true), within: root)
        }
    }

    // MARK: - Staging

    /// Recovery for an interrupted restore or import, run only as one starts and
    /// under the library's gate: a staged file goes only when nothing claims it (a
    /// row's recorded source, or the staging journal), so audio a row is waiting
    /// for is never dropped (T1.7).
    nonisolated static func clearStaging(for memosRoot: URL, keeping claimed: Set<String>) {
        let staging = stagingRoot(for: memosRoot)
        // An unreadable record is not an empty one: nothing is cleared (T1.7).
        guard let journal = try? readStagingJournal(for: memosRoot) else { return }
        // The journal itself stays while it holds moves (an unreadable one is kept too).
        let keep = claimed.union(journal.moves.flatMap { [$0.source, $0.destination] })
            .union([canonicalPath(stagingJournalURL(for: memosRoot))])
        guard let walker = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            if !keep.contains(canonicalPath(file)) { try? FileManager.default.removeItem(at: file) }
        }
        let partial = staging.appendingPathComponent("partial", isDirectory: true)
        rmdir(partial.path) // only when empty
    }

    /// Partial → staged moves inside the staging folder, recorded before they are
    /// made (T1.10): the id, both paths, the digest and the length.
    nonisolated struct StagingJournal: Codable, Equatable, Sendable {
        nonisolated struct Move: Codable, Equatable, Sendable {
            var recordingId: String
            var source: String
            var destination: String
            var sha256: String
            var bytes: Int64
        }
        var moves: [Move] = []
    }

    private nonisolated static func stagingJournalURL(for memosRoot: URL) -> URL {
        stagingRoot(for: memosRoot).appendingPathComponent("journal.json")
    }

    nonisolated static func readStagingJournal(for memosRoot: URL) throws -> StagingJournal {
        let url = stagingJournalURL(for: memosRoot)
        guard try exists(url) else { return StagingJournal() }
        return try JSONDecoder().decode(StagingJournal.self, from: Data(contentsOf: url))
    }

    private nonisolated static func writeStagingJournal(_ journal: StagingJournal, for memosRoot: URL) throws {
        let url = stagingJournalURL(for: memosRoot)
        if journal.moves.isEmpty {
            if try exists(url) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
    }

    /// Writes `data` for recording `recordingId` into staging (A36: the staged file
    /// is `<recordingId>.<ext>`, and its private partial copy is too, in its own
    /// folder): written, read back and checked, then moved by a recorded, verified,
    /// exclusive move. A staged file of that name left by an interrupted run is used
    /// only when it holds the same bytes. Runs off the main actor under the library's
    /// gate; the caller moves the result into place or removes it with `unstage`.
    nonisolated static func stageVerified(_ data: Data, sha256: String, recordingId: String, storedName: String, memosRoot: URL, modifiedAt: Date) throws -> URL {
        let staging = stagingRoot(for: memosRoot)
        let partialFolder = staging.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partialFolder, withIntermediateDirectories: true)
        let partial = partialFolder.appendingPathComponent(storedName)
        let staged = staging.appendingPathComponent(storedName)
        let bytes = Int64(data.count)
        if try exists(staged) {
            guard try facts(staged).size == bytes, try self.sha256(of: staged) == sha256 else { throw SyncValidationError.invalidRecording }
            return staged
        }
        // The partial is this recording's private copy: one left by an interrupted write goes.
        if try exists(partial) { try FileManager.default.removeItem(at: partial) }
        try data.write(to: partial, options: .withoutOverwriting)
        guard try self.sha256(of: partial) == sha256, try facts(partial).size == bytes else {
            try? FileManager.default.removeItem(at: partial)
            throw SyncValidationError.invalidRecording
        }
        try? FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: partial.path)
        var journal = try readStagingJournal(for: memosRoot)
        let move = StagingJournal.Move(recordingId: recordingId, source: canonicalPath(partial), destination: canonicalPath(staged), sha256: sha256, bytes: bytes)
        journal.moves.append(move)
        try writeStagingJournal(journal, for: memosRoot)
        try verifiedMove(partial, to: staged, sha256: sha256, bytes: bytes, within: [staging])
        journal.moves.removeAll { $0 == move }
        try writeStagingJournal(journal, for: memosRoot)
        rmdir(partialFolder.path) // only when empty
        return staged
    }

    /// Removes a staged file only while it holds the bytes it was staged with (T1.11).
    nonisolated static func unstage(_ staged: URL, sha256: String, bytes: Int64) {
        guard (try? BoundaryHooks.run(.beforeCheck, staged, nil)) != nil, (try? facts(staged).size) == bytes, (try? self.sha256(of: staged)) == sha256 else { return }
        try? FileManager.default.removeItem(at: staged)
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
