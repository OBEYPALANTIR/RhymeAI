import CryptoKit
import Foundation

enum SyncValidationError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidProjectId
    case invalidFileName
    case invalidDriveName
    case pathOutsideMemoRoot
    case invalidVersionShape
}

enum SyncIdentity {
    nonisolated static func validateProjectId(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128, value != ".", value != "..",
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "/\\".unicodeScalars.contains($0) }) else {
            throw SyncValidationError.invalidProjectId
        }
    }

    nonisolated static func validateFileName(_ value: String) throws {
        let illegal = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        guard !value.isEmpty, value.utf8.count <= 240, VoiceMemoService.supportedAudioExtensions.contains((value as NSString).pathExtension),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { illegal.contains($0) }) else {
            throw SyncValidationError.invalidFileName
        }
    }
}

struct SyncDeletion: Codable, Equatable, Hashable, Sendable {
    var projectId: String
    var fileName: String?
    var deletedAt: Int64

    init(projectId: String, fileName: String? = nil, deletedAt: Int64) {
        self.projectId = projectId
        self.fileName = fileName
        self.deletedAt = deletedAt
    }

    func validate() throws {
        try SyncIdentity.validateProjectId(projectId)
        if let fileName { try SyncIdentity.validateFileName(fileName) }
    }

    enum CodingKeys: String, CodingKey { case projectId, fileName, deletedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try container.decode(String.self, forKey: .projectId)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        deletedAt = try container.decode(Int64.self, forKey: .deletedAt)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectId, forKey: .projectId)
        if let fileName {
            try container.encode(fileName, forKey: .fileName)
        } else {
            try container.encodeNil(forKey: .fileName)
        }
        try container.encode(deletedAt, forKey: .deletedAt)
    }
}

struct SyncSongProject: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var lyrics: String
    var theme: String
    var updatedAt: Date

    init(id: String, title: String, lyrics: String, theme: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.lyrics = lyrics
        self.theme = theme
        self.updatedAt = updatedAt
    }

    init(project: SongProject) {
        self.init(id: project.id, title: project.title, lyrics: project.lyrics, theme: project.theme, updatedAt: project.updatedAt)
    }

    func makeModel() -> SongProject {
        SongProject(id: id, title: title, lyrics: lyrics, theme: theme, updatedAt: updatedAt)
    }

    enum CodingKeys: String, CodingKey { case id, title, lyrics, theme, updatedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        lyrics = try container.decode(String.self, forKey: .lyrics)
        theme = try container.decode(String.self, forKey: .theme)
        updatedAt = try container.decodeEpochMilliseconds(forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(lyrics, forKey: .lyrics)
        try container.encode(theme, forKey: .theme)
        try container.encodeEpochMilliseconds(updatedAt, forKey: .updatedAt)
    }
}

struct SyncTrashedSongProject: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var lyrics: String
    var theme: String
    var updatedAt: Date
    var deletedAt: Date
    var deleteAfter: Date

    init(id: String, title: String, lyrics: String, theme: String, updatedAt: Date, deletedAt: Date, deleteAfter: Date) {
        self.id = id
        self.title = title
        self.lyrics = lyrics
        self.theme = theme
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.deleteAfter = deleteAfter
    }

    init(trashed: TrashedSongProject) {
        self.init(
            id: trashed.id,
            title: trashed.title,
            lyrics: trashed.lyrics,
            theme: trashed.theme,
            updatedAt: trashed.updatedAt,
            deletedAt: trashed.deletedAt,
            deleteAfter: trashed.deleteAfter
        )
    }

    func makeModel() -> TrashedSongProject {
        TrashedSongProject(id: id, title: title, lyrics: lyrics, theme: theme, updatedAt: updatedAt, deletedAt: deletedAt, deleteAfter: deleteAfter)
    }

    enum CodingKeys: String, CodingKey { case project, deletedAt, deleteAfter }
    enum ProjectCodingKeys: String, CodingKey { case id, title, lyrics, theme, updatedAt }
    enum LegacyFlatCodingKeys: String, CodingKey { case id, title, lyrics, theme, updatedAt, deletedAt, deleteAfter }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.project) {
            let project = try container.decode(SyncSongProject.self, forKey: .project)
            id = project.id
            title = project.title
            lyrics = project.lyrics
            theme = project.theme
            updatedAt = project.updatedAt
            deletedAt = try container.decodeEpochMilliseconds(forKey: .deletedAt)
            deleteAfter = try container.decodeEpochMilliseconds(forKey: .deleteAfter)
        } else {
            // Defensive compatibility with pre-Drive iOS test builds only. Android
            // has always encoded trash as { project, deletedAt, deleteAfter }.
            let legacy = try decoder.container(keyedBy: LegacyFlatCodingKeys.self)
            id = try legacy.decode(String.self, forKey: .id)
            title = try legacy.decode(String.self, forKey: .title)
            lyrics = try legacy.decode(String.self, forKey: .lyrics)
            theme = try legacy.decode(String.self, forKey: .theme)
            updatedAt = try legacy.decodeEpochMilliseconds(forKey: .updatedAt)
            deletedAt = try legacy.decodeEpochMilliseconds(forKey: .deletedAt)
            deleteAfter = try legacy.decodeEpochMilliseconds(forKey: .deleteAfter)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let project = SyncSongProject(id: id, title: title, lyrics: lyrics, theme: theme, updatedAt: updatedAt)
        try container.encode(project, forKey: .project)
        try container.encodeEpochMilliseconds(deletedAt, forKey: .deletedAt)
        try container.encodeEpochMilliseconds(deleteAfter, forKey: .deleteAfter)
    }
}

struct SyncRecordingManifestEntry: Codable, Equatable, Sendable {
    var projectId: String
    var fileName: String
    var driveName: String
    var sizeBytes: Int64
    var modifiedAt: Date
    var sha256: String

    enum CodingKeys: String, CodingKey { case projectId, fileName, driveName, sizeBytes, modifiedAt, sha256 }

    init(projectId: String, fileName: String, driveName: String, sizeBytes: Int64, modifiedAt: Date, sha256: String) {
        self.projectId = projectId
        self.fileName = fileName
        self.driveName = driveName
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try container.decode(String.self, forKey: .projectId)
        fileName = try container.decode(String.self, forKey: .fileName)
        driveName = try container.decode(String.self, forKey: .driveName)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        modifiedAt = try container.decodeEpochMilliseconds(forKey: .modifiedAt)
        sha256 = try container.decode(String.self, forKey: .sha256)
        try validate()
    }

    func validate() throws {
        try SyncIdentity.validateProjectId(projectId)
        try SyncIdentity.validateFileName(fileName)
        guard driveName == RecordingBackupManifest.driveName(projectId: projectId, fileName: fileName),
              !driveName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "/\\".unicodeScalars.contains($0) }),
              driveName.hasSuffix(".enc") else { throw SyncValidationError.invalidDriveName }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectId, forKey: .projectId)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(driveName, forKey: .driveName)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encodeEpochMilliseconds(modifiedAt, forKey: .modifiedAt)
        try container.encode(sha256, forKey: .sha256)
    }
}

struct SyncBlob: Codable, Equatable, Sendable {
    static let currentVersion = 3
    static let driveFileName = "rhymeai-projects.json"
    static let driveMimeType = "application/json"

    var version: Int
    var projects: [SyncSongProject]
    var trashed: [SyncTrashedSongProject]
    var recordings: [SyncRecordingManifestEntry]
    var deletions: [SyncDeletion]
    var savedAt: Date
    var savedByClientId: String

    init(
        version: Int = currentVersion,
        projects: [SyncSongProject] = [],
        trashed: [SyncTrashedSongProject] = [],
        recordings: [SyncRecordingManifestEntry] = [],
        deletions: [SyncDeletion] = [],
        savedAt: Date = Date(),
        savedByClientId: String = ""
    ) {
        self.version = version
        self.projects = projects
        self.trashed = trashed
        self.recordings = recordings
        self.deletions = deletions
        self.savedAt = savedAt
        self.savedByClientId = savedByClientId
    }

    enum CodingKeys: String, CodingKey { case version, projects, trashed, recordings, deletions, savedAt, savedByClientId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(version) else { throw SyncValidationError.unsupportedVersion(version) }
        if version == 1 {
            guard !container.contains(.deletions) else { throw SyncValidationError.invalidVersionShape }
            deletions = []
        } else {
            deletions = try container.decode([SyncDeletion].self, forKey: .deletions)
        }
        projects = try container.decodeIfPresent([SyncSongProject].self, forKey: .projects) ?? []
        trashed = try container.decodeIfPresent([SyncTrashedSongProject].self, forKey: .trashed) ?? []
        recordings = try container.decodeIfPresent([SyncRecordingManifestEntry].self, forKey: .recordings) ?? []
        savedAt = try container.decodeEpochMillisecondsIfPresent(forKey: .savedAt) ?? Date(timeIntervalSince1970: 0)
        savedByClientId = try container.decodeIfPresent(String.self, forKey: .savedByClientId) ?? ""
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try validate()
        try container.encode(version, forKey: .version)
        if version >= 2 { try container.encode(deletions, forKey: .deletions) }
        try container.encode(projects, forKey: .projects)
        try container.encode(trashed, forKey: .trashed)
        try container.encode(recordings, forKey: .recordings)
        try container.encodeEpochMilliseconds(savedAt, forKey: .savedAt)
        try container.encode(savedByClientId, forKey: .savedByClientId)
    }

    func validate() throws {
        guard (1...Self.currentVersion).contains(version) else { throw SyncValidationError.unsupportedVersion(version) }
        guard version >= 2 || deletions.isEmpty else { throw SyncValidationError.invalidVersionShape }
        for project in projects { try SyncIdentity.validateProjectId(project.id) }
        for project in trashed { try SyncIdentity.validateProjectId(project.id) }
        for entry in recordings { try entry.validate() }
        for deletion in deletions { try deletion.validate() }
    }
}

enum SyncJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder = JSONDecoder()
}

enum SyncMerger {
    static func merge(local: SyncBlob, remote: SyncBlob) throws -> SyncBlob {
        try local.validate()
        try remote.validate()
        let deletions = try mergeDeletions(local.deletions + remote.deletions)
        let deletedProjects = Set(deletions.filter { $0.fileName == nil }.map(\.projectId))
        let projects = mergeProjects(local: local.projects, remote: remote.projects)
        let trash = mergeTrash(local: local.trashed, remote: remote.trashed)
        let resolved = resolveActiveTrashConflicts(projects: projects, trashed: trash)
        let recordings = mergeRecordings(local: local.recordings, remote: remote.recordings)
        let newestSavedAt = max(local.savedAt, remote.savedAt)
        return SyncBlob(
            version: SyncBlob.currentVersion,
            projects: resolved.projects.filter { !deletedProjects.contains($0.id) }.sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) },
            trashed: resolved.trashed.filter { !deletedProjects.contains($0.id) }.sorted { $0.deletedAt == $1.deletedAt ? $0.id < $1.id : $0.deletedAt > $1.deletedAt },
            recordings: recordings.filter { entry in
                !deletedProjects.contains(entry.projectId) && !deletions.contains { $0.projectId == entry.projectId && $0.fileName == entry.fileName }
            }.sorted { ($0.driveName, $0.projectId, $0.fileName) < ($1.driveName, $1.projectId, $1.fileName) },
            deletions: deletions,
            savedAt: newestSavedAt,
            savedByClientId: local.savedAt == remote.savedAt ? max(local.savedByClientId, remote.savedByClientId) : (local.savedAt > remote.savedAt ? local.savedByClientId : remote.savedByClientId)
        )
    }

    static func mergeDeletions(_ deletions: [SyncDeletion]) throws -> [SyncDeletion] {
        for deletion in deletions { try deletion.validate() }
        let deletedProjects = Set(deletions.filter { $0.fileName == nil }.map(\.projectId))
        var byIdentity: [String: SyncDeletion] = [:]
        for deletion in deletions {
            if deletion.fileName != nil && deletedProjects.contains(deletion.projectId) { continue }
            let key = "\(deletion.projectId)/\(deletion.fileName ?? "")"
            if let existing = byIdentity[key], existing.deletedAt >= deletion.deletedAt { continue }
            byIdentity[key] = deletion
        }
        return byIdentity.values.sorted { ($0.projectId, $0.fileName ?? "") < ($1.projectId, $1.fileName ?? "") }
    }

    private static func mergeProjects(local: [SyncSongProject], remote: [SyncSongProject]) -> [SyncSongProject] {
        var byId: [String: SyncSongProject] = [:]
        for project in local + remote {
            if let existing = byId[project.id], (existing.updatedAt, existing.title, existing.lyrics, existing.theme) >= (project.updatedAt, project.title, project.lyrics, project.theme) { continue }
            byId[project.id] = project
        }
        return Array(byId.values)
    }

    private static func mergeTrash(local: [SyncTrashedSongProject], remote: [SyncTrashedSongProject]) -> [SyncTrashedSongProject] {
        var byId: [String: SyncTrashedSongProject] = [:]
        for trashed in local + remote {
            if let existing = byId[trashed.id], (existing.deletedAt, existing.updatedAt, existing.deleteAfter, existing.title, existing.lyrics, existing.theme) >= (trashed.deletedAt, trashed.updatedAt, trashed.deleteAfter, trashed.title, trashed.lyrics, trashed.theme) { continue }
            byId[trashed.id] = trashed
        }
        return Array(byId.values)
    }

    private static func resolveActiveTrashConflicts(projects: [SyncSongProject], trashed: [SyncTrashedSongProject]) -> (projects: [SyncSongProject], trashed: [SyncTrashedSongProject]) {
        let trashById = Dictionary(uniqueKeysWithValues: trashed.map { ($0.id, $0) })
        let projectById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let resolvedProjects = projects.filter { project in
            guard let trash = trashById[project.id] else { return true }
            return project.updatedAt > trash.deletedAt
        }
        let resolvedTrash = trashed.filter { trash in
            guard let project = projectById[trash.id] else { return true }
            return trash.deletedAt >= project.updatedAt
        }
        return (resolvedProjects, resolvedTrash)
    }

    private static func mergeRecordings(local: [SyncRecordingManifestEntry], remote: [SyncRecordingManifestEntry]) -> [SyncRecordingManifestEntry] {
        var byIdentity: [String: SyncRecordingManifestEntry] = [:]
        for entry in local + remote {
            let key = "\(entry.projectId)/\(entry.fileName)"
            if let existing = byIdentity[key], (existing.modifiedAt, existing.sha256, existing.sizeBytes, existing.driveName) >= (entry.modifiedAt, entry.sha256, entry.sizeBytes, entry.driveName) { continue }
            byIdentity[key] = entry
        }
        return Array(byIdentity.values)
    }
}

enum RecordingBackupManifest {
    static func driveName(projectId: String, localURL: URL) -> String {
        driveName(projectId: projectId, fileName: localURL.lastPathComponent)
    }

    static func driveName(projectId: String, fileName: String) -> String {
        "rec_\(projectId)_\(fileName).enc"
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

    static func scan(projectIds: [String], memosRoot: URL = VoiceMemoService.memosRoot()) throws -> [(entry: SyncRecordingManifestEntry, localURL: URL)] {
        try projectIds.flatMap { projectId -> [(SyncRecordingManifestEntry, URL)] in
            let folder = try projectURL(projectId: projectId, memosRoot: memosRoot)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: .skipsHiddenFiles
            ) else { return [] }

            return try urls
                .filter { VoiceMemoService.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { url in
                    let url = try localURL(projectId: projectId, fileName: url.lastPathComponent, memosRoot: memosRoot)
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let data = try Data(contentsOf: url)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    let entry = SyncRecordingManifestEntry(
                        projectId: projectId,
                        fileName: url.lastPathComponent,
                        driveName: driveName(projectId: projectId, localURL: url),
                        sizeBytes: Int64(values.fileSize ?? data.count),
                        modifiedAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                        sha256: digest
                    )
                    try entry.validate()
                    return (entry, url)
                }
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeEpochMilliseconds(forKey key: Key) throws -> Date {
        let millis = try decode(Int64.self, forKey: key)
        return Date(millisecondsSince1970: millis)
    }

    func decodeEpochMillisecondsIfPresent(forKey key: Key) throws -> Date? {
        guard let millis = try decodeIfPresent(Int64.self, forKey: key) else { return nil }
        return Date(millisecondsSince1970: millis)
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeEpochMilliseconds(_ date: Date, forKey key: Key) throws {
        try encode(date.epochMilliseconds, forKey: key)
    }
}

private extension Date {
    var epochMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(millisecondsSince1970 milliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
    }
}
