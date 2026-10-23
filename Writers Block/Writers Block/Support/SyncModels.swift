import CryptoKit
import Foundation

enum SyncValidationError: Error, Equatable {
    case unsupportedVersion(Int)
    case invalidProjectId
    case invalidFileName
    case invalidDriveName
    case pathOutsideMemoRoot
    case invalidVersionShape
    case invalidRecording
}

enum SyncIdentity {
    nonisolated static func validateProjectId(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128, value != ".", value != "..",
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "/\\".unicodeScalars.contains($0) }) else {
            throw SyncValidationError.invalidProjectId
        }
    }

    /// A recording's stable id: it names the Drive file `rec_<id>`.
    nonisolated static func validateRecordingId(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128, value != ".", value != "..",
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || "/\\".unicodeScalars.contains($0) }) else {
            throw SyncValidationError.invalidRecording
        }
    }

    nonisolated static func validateFileName(_ value: String) throws {
        let illegal = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
        guard !value.isEmpty, value.utf8.count <= 240, RecordingFiles.supportedAudioExtensions.contains((value as NSString).pathExtension),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { illegal.contains($0) }) else {
            throw SyncValidationError.invalidFileName
        }
    }
}

/// A tombstone. Song tombstones have neither `recordingId` nor `fileName`;
/// recording tombstones name the recording by `recordingId` (v4) and keep its
/// `fileName` for display. A `fileName` without an id comes from before ids.
struct SyncDeletion: Codable, Equatable, Hashable, Sendable {
    var projectId: String
    var recordingId: String?
    var fileName: String?
    var deletedAt: Int64

    init(projectId: String, recordingId: String? = nil, fileName: String? = nil, deletedAt: Int64) {
        self.projectId = projectId
        self.recordingId = recordingId
        self.fileName = fileName
        self.deletedAt = deletedAt
    }

    var isSongTombstone: Bool { recordingId == nil && fileName == nil }

    /// One tombstone per song, per recording id, or per pre-id file name.
    var identity: String {
        "\(projectId)/" + (recordingId.map { "id:\($0)" } ?? fileName.map { "name:\($0)" } ?? "")
    }

    func validate() throws {
        try SyncIdentity.validateProjectId(projectId)
        if let recordingId { try SyncIdentity.validateRecordingId(recordingId) }
        if let fileName { try SyncIdentity.validateFileName(fileName) }
    }

    /// True when this tombstone names the recording (or its whole song) and is
    /// newer than the recording's precedence time.
    func covers(_ entry: SyncRecording) -> Bool {
        covers(projectId: entry.projectId, recordingId: entry.id, sha256: entry.sha256, at: entry.uploadedAt)
    }

    /// A pre-id name tombstone names only the recording that name had before v4:
    /// the one whose id is the legacy id derived from that name and its audio. It
    /// never matches another recording that later took the name.
    func covers(projectId: String, recordingId: String, sha256: String, at time: Date) -> Bool {
        guard self.projectId == projectId, deletedAt > time.epochMilliseconds else { return false }
        if let id = self.recordingId { return id == recordingId }
        guard let fileName else { return true }
        return recordingId == RecordingBackupManifest.legacyRecordingId(projectId: projectId, fileName: fileName, sha256: sha256)
    }

    enum CodingKeys: String, CodingKey { case projectId, recordingId, fileName, deletedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try container.decode(String.self, forKey: .projectId)
        recordingId = try container.decodeIfPresent(String.self, forKey: .recordingId)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        deletedAt = try container.decode(Int64.self, forKey: .deletedAt)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectId, forKey: .projectId)
        if let recordingId { try container.encode(recordingId, forKey: .recordingId) }
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
        guard driveName == RecordingBackupManifest.legacyDriveName(projectId: projectId, fileName: fileName),
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

/// The encrypted v1–v3 manifest (`rhymeai-projects.json`). Read only, to
/// migrate an older backup into v4; nothing writes this shape any more.
struct LegacySyncBlob: Codable, Equatable, Sendable {
    static let currentVersion = 3
    static let driveFileName = "rhymeai-projects.json"

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

/// One recording in a v4 manifest. Identity is (projectId, fileName); the
/// Drive copy is the raw audio under `RecordingBackupManifest.driveName`.
struct SyncRecording: Equatable, Hashable, Sendable {
    /// Recordings above this stay on the device: not in the manifest, not on Drive, not in iCloud.
    static let maxBytes: Int64 = 16 * 1024 * 1024

    /// Stable identity; a rename changes only `fileName`.
    var id: String
    var projectId: String
    var fileName: String
    var bytes: Int64
    var sha256: String
    /// The recording's precedence time (epoch milliseconds in the manifest); a
    /// tombstone removes it only when deleted after this.
    var uploadedAt: Date

    var key: String { id }
    var driveName: String { RecordingBackupManifest.driveName(recordingId: id) }

    func validate() throws {
        try SyncIdentity.validateRecordingId(id)
        try SyncIdentity.validateProjectId(projectId)
        try SyncIdentity.validateFileName(fileName)
        guard bytes >= 0, sha256.count == 64,
              sha256.unicodeScalars.allSatisfy({ "0123456789abcdef".unicodeScalars.contains($0) }) else {
            throw SyncValidationError.invalidRecording
        }
    }
}

enum SyncManifestError: Error, Equatable {
    /// The hash does not cover the content, or the content is not a v4 manifest.
    case damaged
    /// Written by a newer app (`version` above 4).
    case newerVersion(Int)
}

/// The v4 backup manifest (`rhymeai-manifest.json`), identical on Android and
/// iOS. Unencrypted JSON; `manifestSha256` is the SHA-256 of the canonical form
/// of the object without that key (see `CanonicalJSON`). Timestamps other than
/// `savedAt` are epoch milliseconds, as in v3.
struct SyncBlob: Equatable, Sendable {
    static let version = 4
    static let driveFileName = "rhymeai-manifest.json"
    static let driveMimeType = "application/json"

    var projects: [SyncSongProject]
    var trashed: [SyncTrashedSongProject]
    var recordings: [SyncRecording]
    var deletions: [SyncDeletion]
    var savedAt: Date
    var savedByClientId: String
    var platform: String

    init(
        projects: [SyncSongProject] = [],
        trashed: [SyncTrashedSongProject] = [],
        recordings: [SyncRecording] = [],
        deletions: [SyncDeletion] = [],
        savedAt: Date = Date(),
        savedByClientId: String = "",
        platform: String = "ios"
    ) {
        self.projects = projects
        self.trashed = trashed
        self.recordings = recordings
        self.deletions = deletions
        self.savedAt = savedAt
        self.savedByClientId = savedByClientId
        self.platform = platform
    }

    func validate() throws {
        for project in projects { try SyncIdentity.validateProjectId(project.id) }
        for project in trashed { try SyncIdentity.validateProjectId(project.id) }
        for entry in recordings { try entry.validate() }
        for deletion in deletions { try deletion.validate() }
    }

    // MARK: Canonical JSON

    /// The manifest object without `manifestSha256`.
    var jsonValue: JSONValue {
        .object([
            "version": .int(Int64(Self.version)),
            "savedAt": .string(Self.formatSavedAt(savedAt)),
            "savedByClientId": .string(savedByClientId),
            "platform": .string(platform),
            "projects": .array(projects.map { project in
                .object([
                    "id": .string(project.id), "title": .string(project.title), "lyrics": .string(project.lyrics),
                    "theme": .string(project.theme), "updatedAt": .int(project.updatedAt.epochMilliseconds),
                ])
            }),
            "trashed": .array(trashed.map { trash in
                .object([
                    "id": .string(trash.id), "title": .string(trash.title), "lyrics": .string(trash.lyrics),
                    "theme": .string(trash.theme), "updatedAt": .int(trash.updatedAt.epochMilliseconds),
                    "trashedAt": .int(trash.deletedAt.epochMilliseconds),
                ])
            }),
            "recordings": .array(recordings.map { entry in
                .object([
                    "id": .string(entry.id),
                    "projectId": .string(entry.projectId), "fileName": .string(entry.fileName),
                    "bytes": .int(entry.bytes), "sha256": .string(entry.sha256),
                    "uploadedAt": .int(entry.uploadedAt.epochMilliseconds),
                ])
            }),
            "deletions": .array(deletions.map { deletion in
                var fields: [String: JSONValue] = [
                    "projectId": .string(deletion.projectId),
                    "fileName": deletion.fileName.map(JSONValue.string) ?? .null,
                    "deletedAt": .int(deletion.deletedAt),
                ]
                if let recordingId = deletion.recordingId { fields["recordingId"] = .string(recordingId) }
                return .object(fields)
            }),
        ])
    }

    var manifestSha256: String { CanonicalJSON.sha256Hex(jsonValue) }

    /// The file uploaded to Drive and written into an export: the canonical
    /// object with its `manifestSha256`.
    func encodedManifest() throws -> Data {
        try validate()
        guard case .object(var fields) = jsonValue else { throw SyncManifestError.damaged }
        fields["manifestSha256"] = .string(manifestSha256)
        return Data(CanonicalJSON.string(.object(fields)).utf8)
    }

    /// Refuses a manifest whose hash does not match its content, one written by
    /// a newer version, and any that is not a well-formed v4 manifest.
    static func decodeManifest(_ data: Data) throws -> SyncBlob {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let value = try? JSONValue(any: parsed),
              case .object(var fields) = value,
              case .string(let storedHash)? = fields.removeValue(forKey: "manifestSha256") else {
            throw SyncManifestError.damaged
        }
        guard case .int(let version)? = fields["version"] else { throw SyncManifestError.damaged }
        if version > Int64(Self.version) { throw SyncManifestError.newerVersion(Int(version)) }
        guard version == Int64(Self.version),
              storedHash.lowercased() == CanonicalJSON.sha256Hex(.object(fields)) else {
            throw SyncManifestError.damaged
        }
        do {
            let blob = SyncBlob(
                projects: try fields.array("projects").map { project in
                    SyncSongProject(
                        id: try project.string("id"), title: try project.string("title"),
                        lyrics: try project.string("lyrics"), theme: try project.string("theme"),
                        updatedAt: Date(millisecondsSince1970: try project.int("updatedAt"))
                    )
                },
                trashed: try fields.array("trashed").map { trash in
                    let trashedAt = Date(millisecondsSince1970: try trash.int("trashedAt"))
                    return SyncTrashedSongProject(
                        id: try trash.string("id"), title: try trash.string("title"),
                        lyrics: try trash.string("lyrics"), theme: try trash.string("theme"),
                        updatedAt: Date(millisecondsSince1970: try trash.int("updatedAt")),
                        deletedAt: trashedAt, deleteAfter: trashedAt.addingTimeInterval(trashRetentionInterval)
                    )
                },
                recordings: try fields.array("recordings").map { entry in
                    SyncRecording(
                        id: try entry.string("id"),
                        projectId: try entry.string("projectId"), fileName: try entry.string("fileName"),
                        bytes: try entry.int("bytes"), sha256: try entry.string("sha256"),
                        uploadedAt: Date(millisecondsSince1970: try entry.int("uploadedAt"))
                    )
                },
                deletions: try fields.array("deletions").map { deletion in
                    func optionalString(_ key: String) throws -> String? {
                        switch deletion[key] {
                        case .string(let value)?: return value
                        case .null?, nil: return nil
                        default: throw SyncManifestError.damaged
                        }
                    }
                    return SyncDeletion(
                        projectId: try deletion.string("projectId"), recordingId: try optionalString("recordingId"),
                        fileName: try optionalString("fileName"), deletedAt: try deletion.int("deletedAt")
                    )
                },
                savedAt: try parseSavedAt(try fields.string("savedAt")),
                savedByClientId: try fields.string("savedByClientId"),
                platform: try fields.string("platform")
            )
            try blob.validate()
            return blob
        } catch let error as SyncManifestError {
            throw error
        } catch {
            throw SyncManifestError.damaged
        }
    }

    /// `savedAt`: ISO-8601 UTC with milliseconds and a trailing Z.
    static func formatSavedAt(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(millisecondsSince1970: date.epochMilliseconds))
    }

    private static func parseSavedAt(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: text) else { throw SyncManifestError.damaged }
        return date
    }
}

extension LegacySyncBlob {
    /// The same content in the v4 model. Recordings get the ids `recordingId`
    /// hands out (persisted by the caller, so an old entry keeps its id).
    func upgraded(recordingId: (SyncRecordingManifestEntry) -> String) -> SyncBlob {
        // A name tombstone for an old recording listed here becomes a tombstone for its id.
        let normalized = deletions.map { deletion -> SyncDeletion in
            guard deletion.recordingId == nil, let fileName = deletion.fileName,
                  let entry = recordings.first(where: { $0.projectId == deletion.projectId && $0.fileName == fileName }) else { return deletion }
            return SyncDeletion(projectId: deletion.projectId, recordingId: recordingId(entry), fileName: fileName, deletedAt: deletion.deletedAt)
        }
        return SyncBlob(
            projects: projects,
            trashed: trashed,
            // An entry without a usable SHA-256 cannot be verified, so v4 does not carry it.
            recordings: recordings
                .map { SyncRecording(id: recordingId($0), projectId: $0.projectId, fileName: $0.fileName, bytes: $0.sizeBytes, sha256: $0.sha256.lowercased(), uploadedAt: $0.modifiedAt) }
                .filter { (try? $0.validate()) != nil },
            deletions: normalized,
            savedAt: savedAt,
            savedByClientId: savedByClientId
        )
    }
}

/// A parsed JSON value. Numbers are integers only: the manifest has no other kind.
nonisolated indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(any value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                let integer = number.int64Value
                guard number.doubleValue == Double(integer) else { throw SyncManifestError.damaged }
                self = .int(integer)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(try array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(try object.mapValues(JSONValue.init(any:)))
        default:
            throw SyncManifestError.damaged
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) throws -> String {
        guard case .string(let value)? = self[key] else { throw SyncManifestError.damaged }
        return value
    }

    func int(_ key: String) throws -> Int64 {
        guard case .int(let value)? = self[key] else { throw SyncManifestError.damaged }
        return value
    }

    func array(_ key: String) throws -> [[String: JSONValue]] {
        guard case .array(let values)? = self[key] else { throw SyncManifestError.damaged }
        return try values.map { value in
            guard case .object(let object) = value else { throw SyncManifestError.damaged }
            return object
        }
    }
}

/// The shared canonical serialisation the manifest hash covers: keys sorted by
/// Unicode code point, arrays in stored order, no whitespace, integers only, and
/// escapes limited to \" \\ \n \r \t and \u00XX for other controls below 0x20.
/// Non-ASCII text (and "/") is written as is.
enum CanonicalJSON {
    static func string(_ value: JSONValue) -> String {
        var out = ""
        write(value, to: &out)
        return out
    }

    static func sha256Hex(_ value: JSONValue) -> String {
        SHA256.hash(data: Data(string(value).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ value: JSONValue, to out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .int(let number): out += String(number)
        case .string(let text): writeString(text, to: &out)
        case .array(let values):
            out += "["
            for (index, element) in values.enumerated() {
                if index > 0 { out += "," }
                write(element, to: &out)
            }
            out += "]"
        case .object(let fields):
            out += "{"
            let keys = fields.keys.sorted { lhs, rhs in
                lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) { $0.value < $1.value }
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                writeString(key, to: &out)
                out += ":"
                write(fields[key] ?? .null, to: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ text: String, to out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
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
        try resolve(try gather([local, remote]))
    }

    /// Collects every input into one working set without resolving anything: per
    /// id the newest song and trash entry, per recording id the last input's entry
    /// (the copy already backed up wins), per tombstone identity the newest. Resolve
    /// once, after every input is in, so nothing is filtered or dropped early (A18).
    static func gather(_ inputs: [SyncBlob]) throws -> SyncBlob {
        for input in inputs { try input.validate() }
        var recordings: [String: SyncRecording] = [:]
        for input in inputs {
            for entry in input.recordings { recordings[entry.id] = entry }
        }
        let newest = inputs.max { ($0.savedAt, $0.savedByClientId) < ($1.savedAt, $1.savedByClientId) }
        return SyncBlob(
            projects: mergeProjects(local: inputs.flatMap(\.projects), remote: []),
            trashed: mergeTrash(local: inputs.flatMap(\.trashed), remote: []),
            recordings: Array(recordings.values),
            deletions: try mergeDeletions(inputs.flatMap(\.deletions)),
            savedAt: newest?.savedAt ?? Date(),
            savedByClientId: newest?.savedByClientId ?? "",
            platform: inputs.first?.platform ?? "ios"
        )
    }

    /// Applies A3 once to a gathered set. A song tombstone removes a song only when
    /// newer than its last change and a recording only when newer than its
    /// precedence time; each recording a song tombstone removes gets its own
    /// tombstone, so reviving the song (which drops the song tombstone) cannot
    /// bring the audio back. A tombstone whose song or recording survives is dropped.
    static func resolve(_ gathered: SyncBlob) throws -> SyncBlob {
        let resolved = resolveActiveTrashConflicts(projects: gathered.projects, trashed: gathered.trashed)
        let songTombstones = Dictionary(gathered.deletions.filter(\.isSongTombstone).map { ($0.projectId, $0) }) { first, _ in first }
        let projects = resolved.projects.filter { project in
            !(songTombstones[project.id].map { $0.deletedAt > project.updatedAt.epochMilliseconds } ?? false)
        }
        let trashed = resolved.trashed.filter { trash in
            !(songTombstones[trash.id].map { $0.deletedAt > max(trash.updatedAt, trash.deletedAt).epochMilliseconds } ?? false)
        }
        let recordings = gathered.recordings.filter { entry in !gathered.deletions.contains { $0.covers(entry) } }
        let covered = gathered.recordings.compactMap { entry -> SyncDeletion? in
            guard let song = songTombstones[entry.projectId], song.deletedAt > entry.uploadedAt.epochMilliseconds else { return nil }
            return SyncDeletion(projectId: entry.projectId, recordingId: entry.id, fileName: entry.fileName, deletedAt: song.deletedAt)
        }
        let survivingSongs = Set(projects.map(\.id) + trashed.map(\.id))
        let survivingIds = Set(recordings.map(\.id))
        let deletions = try mergeDeletions(gathered.deletions + covered).filter { deletion in
            if deletion.isSongTombstone { return !survivingSongs.contains(deletion.projectId) }
            if let id = deletion.recordingId { return !survivingIds.contains(id) }
            // A pre-v4 name tombstone goes only when the recording it names (the id
            // derived for that name and audio) survived it.
            return !recordings.contains { entry in
                entry.projectId == deletion.projectId && entry.fileName == deletion.fileName
                    && entry.id == RecordingBackupManifest.legacyRecordingId(projectId: entry.projectId, fileName: entry.fileName, sha256: entry.sha256)
            }
        }
        return SyncBlob(
            projects: projects.sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) },
            trashed: trashed.sorted { $0.deletedAt == $1.deletedAt ? $0.id < $1.id : $0.deletedAt > $1.deletedAt },
            recordings: recordings.sorted { ($0.projectId, $0.fileName, $0.id) < ($1.projectId, $1.fileName, $1.id) },
            deletions: deletions,
            savedAt: gathered.savedAt,
            savedByClientId: gathered.savedByClientId,
            platform: gathered.platform
        )
    }

    /// The newest tombstone per identity.
    static func mergeDeletions(_ deletions: [SyncDeletion]) throws -> [SyncDeletion] {
        for deletion in deletions { try deletion.validate() }
        var byIdentity: [String: SyncDeletion] = [:]
        for deletion in deletions {
            if let existing = byIdentity[deletion.identity], existing.deletedAt >= deletion.deletedAt { continue }
            byIdentity[deletion.identity] = deletion
        }
        return byIdentity.values.sorted { $0.identity < $1.identity }
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

}

enum RecordingBackupManifest {
    /// v4 Drive name for a recording's raw audio.
    static func driveName(recordingId: String) -> String {
        "rec_\(recordingId)"
    }

    /// v1–v3 Drive name for a recording's RAI1-encrypted audio.
    static func legacyDriveName(projectId: String, fileName: String) -> String {
        "rec_\(projectId)_\(fileName).enc"
    }

    /// The id of a recording from before v4: a name-based UUID (version 3, MD5,
    /// as Java's `UUID.nameUUIDFromBytes`) of
    /// "rhymeai-legacy-recording:<projectId>/<fileName>/<sha256>", so every
    /// device derives the same id for the same old recording.
    static func legacyRecordingId(projectId: String, fileName: String, sha256: String) -> String {
        var bytes = Array(Insecure.MD5.hash(data: Data("rhymeai-legacy-recording:\(projectId)/\(fileName)/\(sha256.lowercased())".utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x30
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A project's memo files, sorted by name.
    static func scanFiles(projectId: String, memosRoot: URL) throws -> [(fileName: String, url: URL)] {
        let folder = try RecordingFiles.projectURL(projectId: projectId, memosRoot: memosRoot)
        // A folder that is not there has no recordings; one that cannot be read is an error.
        guard try RecordingFiles.exists(folder) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        )
        // A name a manifest cannot carry (it fails `validateFileName`) stays local only.
        return urls
            .filter { RecordingFiles.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
            .sorted()
            .compactMap { name in
                (try? RecordingFiles.localURL(projectId: projectId, fileName: name, memosRoot: memosRoot)).map { (name, $0) }
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

extension Date {
    var epochMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(millisecondsSince1970 milliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
    }
}
