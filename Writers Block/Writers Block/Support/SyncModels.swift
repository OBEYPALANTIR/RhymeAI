import CryptoKit
import Foundation

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
    static let currentVersion = 1
    static let driveFileName = "rhymeai-projects.json"
    static let driveMimeType = "application/json"

    var version: Int
    var projects: [SyncSongProject]
    var trashed: [SyncTrashedSongProject]
    var recordings: [SyncRecordingManifestEntry]
    var savedAt: Date
    var savedByClientId: String

    init(
        version: Int = currentVersion,
        projects: [SyncSongProject] = [],
        trashed: [SyncTrashedSongProject] = [],
        recordings: [SyncRecordingManifestEntry] = [],
        savedAt: Date = Date(),
        savedByClientId: String = ""
    ) {
        self.version = version
        self.projects = projects
        self.trashed = trashed
        self.recordings = recordings
        self.savedAt = savedAt
        self.savedByClientId = savedByClientId
    }

    enum CodingKeys: String, CodingKey { case version, projects, trashed, recordings, savedAt, savedByClientId }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        projects = try container.decodeIfPresent([SyncSongProject].self, forKey: .projects) ?? []
        trashed = try container.decodeIfPresent([SyncTrashedSongProject].self, forKey: .trashed) ?? []
        recordings = try container.decodeIfPresent([SyncRecordingManifestEntry].self, forKey: .recordings) ?? []
        savedAt = try container.decodeEpochMillisecondsIfPresent(forKey: .savedAt) ?? Date(timeIntervalSince1970: 0)
        savedByClientId = try container.decodeIfPresent(String.self, forKey: .savedByClientId) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(projects, forKey: .projects)
        try container.encode(trashed, forKey: .trashed)
        try container.encode(recordings, forKey: .recordings)
        try container.encodeEpochMilliseconds(savedAt, forKey: .savedAt)
        try container.encode(savedByClientId, forKey: .savedByClientId)
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
    static func merge(local: SyncBlob, remote: SyncBlob) -> SyncBlob {
        let projects = mergeProjects(local: local.projects, remote: remote.projects)
        let trash = mergeTrash(local: local.trashed, remote: remote.trashed)
        let resolved = resolveActiveTrashConflicts(projects: projects, trashed: trash)
        let recordings = mergeRecordings(local: local.recordings, remote: remote.recordings)
        let newestSavedAt = max(local.savedAt, remote.savedAt)
        return SyncBlob(
            version: max(local.version, remote.version),
            projects: resolved.projects.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending },
            trashed: resolved.trashed.sorted { $0.deletedAt > $1.deletedAt },
            recordings: recordings.sorted { $0.driveName < $1.driveName },
            savedAt: newestSavedAt,
            savedByClientId: local.savedByClientId.isEmpty ? remote.savedByClientId : local.savedByClientId
        )
    }

    private static func mergeProjects(local: [SyncSongProject], remote: [SyncSongProject]) -> [SyncSongProject] {
        var byId: [String: SyncSongProject] = [:]
        for project in local + remote {
            if let existing = byId[project.id], existing.updatedAt > project.updatedAt { continue }
            byId[project.id] = project
        }
        return Array(byId.values)
    }

    private static func mergeTrash(local: [SyncTrashedSongProject], remote: [SyncTrashedSongProject]) -> [SyncTrashedSongProject] {
        var byId: [String: SyncTrashedSongProject] = [:]
        for trashed in local + remote {
            if let existing = byId[trashed.id], existing.deletedAt > trashed.deletedAt { continue }
            byId[trashed.id] = trashed
        }
        return Array(byId.values)
    }

    private static func resolveActiveTrashConflicts(projects: [SyncSongProject], trashed: [SyncTrashedSongProject]) -> (projects: [SyncSongProject], trashed: [SyncTrashedSongProject]) {
        let trashById = Dictionary(uniqueKeysWithValues: trashed.map { ($0.id, $0) })
        let projectById = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let resolvedProjects = projects.filter { project in
            guard let trash = trashById[project.id] else { return true }
            return project.updatedAt >= trash.deletedAt
        }
        let resolvedTrash = trashed.filter { trash in
            guard let project = projectById[trash.id] else { return true }
            return trash.deletedAt > project.updatedAt
        }
        return (resolvedProjects, resolvedTrash)
    }

    private static func mergeRecordings(local: [SyncRecordingManifestEntry], remote: [SyncRecordingManifestEntry]) -> [SyncRecordingManifestEntry] {
        var byIdentity: [String: SyncRecordingManifestEntry] = [:]
        for entry in local + remote {
            let key = "\(entry.projectId)/\(entry.fileName)"
            if let existing = byIdentity[key], existing.modifiedAt > entry.modifiedAt { continue }
            byIdentity[key] = entry
        }
        return Array(byIdentity.values)
    }
}

enum RecordingBackupManifest {
    static func driveName(projectId: String, localURL: URL) -> String {
        let stem = sanitizeComponent(localURL.deletingPathExtension().lastPathComponent)
        return "rec_\(sanitizeComponent(projectId))_\(stem).m4a.enc"
    }

    static func scan(projectIds: [String], memosRoot: URL = VoiceMemoService.memosRoot()) throws -> [(entry: SyncRecordingManifestEntry, localURL: URL)] {
        try projectIds.flatMap { projectId -> [(SyncRecordingManifestEntry, URL)] in
            let folder = memosRoot.appendingPathComponent(projectId, isDirectory: true)
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: .skipsHiddenFiles
            ) else { return [] }

            return try urls
                .filter { $0.pathExtension == "m4a" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { url in
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
                    return (entry, url)
                }
        }
    }

    private static func sanitizeComponent(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\u{0000}")
        let filtered = value.unicodeScalars.filter { !illegal.contains($0) }
        return String(String.UnicodeScalarView(filtered))
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
