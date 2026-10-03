import Foundation

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

    nonisolated static func importURL(basename: String, extension ext: String, projectId: String) throws -> URL {
        let stem = RecordingFiles.sanitizeName(basename)
        let name = stem.isEmpty || stem.hasPrefix(".") ? "Imported recording" : stem
        var suffix = 1
        var target: URL
        repeat {
            let filename = suffix == 1 ? "\(name).\(ext)" : "\(name) \(suffix).\(ext)"
            target = try RecordingFiles.localURL(projectId: projectId, fileName: filename, memosRoot: RecordingFiles.memosRoot())
            suffix += 1
        } while FileManager.default.fileExists(atPath: target.path)
        return target
    }

    nonisolated static func restoredURL(originalName: String, folder: URL) -> URL {
        var target = folder.appendingPathComponent(originalName)
        if FileManager.default.fileExists(atPath: target.path) {
            let stem = (originalName as NSString).deletingPathExtension
            var suffix = 2
            repeat {
                target = folder.appendingPathComponent("\(stem) \(suffix).\((originalName as NSString).pathExtension)")
                suffix += 1
            } while FileManager.default.fileExists(atPath: target.path) && suffix < 1000
        }
        return target
    }

    nonisolated static func renamedURL(for url: URL, sanitizedName sanitized: String) -> URL {
        let folder = url.deletingLastPathComponent()
        var targetURL = folder.appendingPathComponent(sanitized).appendingPathExtension(url.pathExtension)

        // Collision avoidance: append " 2" if target already exists (and isn't the source itself).
        if targetURL != url && FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = folder.appendingPathComponent(sanitized + " 2").appendingPathExtension(url.pathExtension)
        }

        return targetURL
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
