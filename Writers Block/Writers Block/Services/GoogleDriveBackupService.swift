import AuthenticationServices
import CryptoKit
import Foundation
import SwiftData
import UIKit

enum BackupError: Error, Equatable {
    case notConfigured
    case authorizationRequired
    case missingPassphrase
    case noRemoteBackup
    case network(String)
    case invalidResponse
    case wrongPassphraseOrCorruptData
    case recordingIntegrityMismatch(String)
}

struct DriveAppDataFile: Equatable, Sendable {
    var id: String
    var name: String
}

protocol DriveAppDataClient: AnyObject {
    func findFile(named name: String, accessToken: String) async throws -> DriveAppDataFile?
    func listFiles(prefix: String, accessToken: String) async throws -> [DriveAppDataFile]
    func downloadFile(id: String, accessToken: String) async throws -> Data
    func uploadNewFile(named name: String, mimeType: String, content: Data, accessToken: String) async throws -> DriveAppDataFile
    func updateFile(id: String, mimeType: String, content: Data, accessToken: String) async throws
}

protocol OAuthAccessTokenProvider: AnyObject {
    var isConfigured: Bool { get }
    var hasRefreshToken: Bool { get }
    func accessToken(interactive: Bool) async throws -> String
}

final class RealDriveAppDataClient: DriveAppDataClient {
    private let session: URLSession
    private let driveBase = URL(string: "https://www.googleapis.com/drive/v3")!
    private let uploadBase = URL(string: "https://www.googleapis.com/upload/drive/v3")!
    private let boundary = "rhymeai_boundary_ios_42"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func findFile(named name: String, accessToken: String) async throws -> DriveAppDataFile? {
        try await listFiles(query: "name = '\(Self.escapeQueryString(name))'", accessToken: accessToken).first
    }

    func listFiles(prefix: String, accessToken: String) async throws -> [DriveAppDataFile] {
        try await listFiles(query: "name contains '\(Self.escapeQueryString(prefix))'", accessToken: accessToken)
            .filter { $0.name.hasPrefix(prefix) }
    }

    func downloadFile(id: String, accessToken: String) async throws -> Data {
        var components = URLComponents(url: driveBase.appendingPathComponent("files/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await data(for: request)
    }

    func uploadNewFile(named name: String, mimeType: String, content: Data, accessToken: String) async throws -> DriveAppDataFile {
        let metadata = DriveUploadMetadata(name: name, parents: ["appDataFolder"], mimeType: mimeType)
        let body = try multipartBody(metadata: metadata, mimeType: mimeType, content: content)
        var components = URLComponents(url: uploadBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploadType", value: "multipart"), URLQueryItem(name: "fields", value: "id,name")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let responseData = try await data(for: request)
        return try JSONDecoder().decode(DriveFileResponse.self, from: responseData).file
    }

    func updateFile(id: String, mimeType: String, content: Data, accessToken: String) async throws {
        let metadata = DrivePatchMetadata(mimeType: mimeType)
        let body = try multipartBody(metadata: metadata, mimeType: mimeType, content: content)
        var components = URLComponents(url: uploadBase.appendingPathComponent("files/\(id)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploadType", value: "multipart")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        _ = try await data(for: request)
    }

    private func listFiles(query: String, accessToken: String) async throws -> [DriveAppDataFile] {
        var components = URLComponents(url: driveBase.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "q", value: query)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let responseData = try await data(for: request)
        return try JSONDecoder().decode(DriveFilesResponse.self, from: responseData).files
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackupError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw BackupError.authorizationRequired }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BackupError.network("Drive request failed (\(http.statusCode)): \(body)")
        }
        return data
    }

    private func multipartBody<T: Encodable>(metadata: T, mimeType: String, content: Data) throws -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONEncoder().encode(metadata))
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(content)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func escapeQueryString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "\\'")
    }
}

private struct DriveFilesResponse: Decodable { var files: [DriveAppDataFile] }
private struct DriveFileResponse: Decodable {
    var id: String
    var name: String
    var file: DriveAppDataFile { DriveAppDataFile(id: id, name: name) }
}

extension DriveAppDataFile: Decodable {
    enum CodingKeys: String, CodingKey { case id, name }
}

private struct DriveUploadMetadata: Encodable {
    var name: String
    var parents: [String]
    var mimeType: String
}

private struct DrivePatchMetadata: Encodable { var mimeType: String }

struct GoogleDriveOAuthConfiguration: Equatable, Sendable {
    var clientID: String?
    var redirectScheme: String?

    init(clientID: String?, redirectScheme: String?) {
        self.clientID = clientID?.nilIfBlank
        self.redirectScheme = redirectScheme?.nilIfBlank
    }

    static func fromBundle(_ bundle: Bundle = .main) -> GoogleDriveOAuthConfiguration {
        GoogleDriveOAuthConfiguration(
            clientID: bundle.object(forInfoDictionaryKey: "GoogleDriveOAuthClientID") as? String,
            redirectScheme: (bundle.object(forInfoDictionaryKey: "GoogleDriveOAuthRedirectScheme") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "GoogleDriveOAuthReversedClientID") as? String)
        )
    }
}

struct OAuthToken: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date

    var isUsable: Bool { !accessToken.isEmpty && expiresAt.timeIntervalSinceNow > 60 }
}

protocol OAuthTokenStore: AnyObject {
    func loadToken() -> OAuthToken?
    func saveToken(_ token: OAuthToken)
    func deleteToken()
}

final class InMemoryOAuthTokenStore: OAuthTokenStore {
    private var token: OAuthToken?
    init(token: OAuthToken? = nil) { self.token = token }
    func loadToken() -> OAuthToken? { token }
    func saveToken(_ token: OAuthToken) { self.token = token }
    func deleteToken() { token = nil }
}

final class KeychainOAuthTokenStore: OAuthTokenStore {
    private let service = "ShaydeTree.Writers-Block.googleDriveOAuth"
    private let account = "oauth-token"

    func loadToken() -> OAuthToken? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthToken.self, from: data)
    }

    func saveToken(_ token: OAuthToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func deleteToken() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class GoogleDriveOAuthService: NSObject, OAuthAccessTokenProvider, ASWebAuthenticationPresentationContextProviding {
    private let configuration: GoogleDriveOAuthConfiguration
    private let tokenStore: OAuthTokenStore
    private let session: URLSession
    private var currentSession: ASWebAuthenticationSession?

    init(
        configuration: GoogleDriveOAuthConfiguration = .fromBundle(),
        tokenStore: OAuthTokenStore = KeychainOAuthTokenStore(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.session = session
    }

    var isConfigured: Bool { configuration.clientID != nil && configuration.redirectScheme != nil }
    var hasRefreshToken: Bool { tokenStore.loadToken()?.refreshToken?.isEmpty == false }

    func accessToken(interactive: Bool) async throws -> String {
        guard let clientID = configuration.clientID, let redirectScheme = configuration.redirectScheme else {
            throw BackupError.notConfigured
        }
        if let token = tokenStore.loadToken(), token.isUsable {
            return token.accessToken
        }
        if let refreshToken = tokenStore.loadToken()?.refreshToken, !refreshToken.isEmpty {
            return try await refreshAccessToken(refreshToken: refreshToken, clientID: clientID).accessToken
        }
        guard interactive else { throw BackupError.authorizationRequired }
        return try await authorize(clientID: clientID, redirectScheme: redirectScheme).accessToken
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private func authorize(clientID: String, redirectScheme: String) async throws -> OAuthToken {
        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.codeChallenge(for: verifier)
        let redirectURI = "\(redirectScheme):/oauth2redirect/google"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.appdata"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        let callback = try await runWebAuthentication(url: components.url!, callbackScheme: redirectScheme)
        guard let returned = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let code = returned.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw BackupError.invalidResponse
        }
        return try await exchangeCode(code, verifier: verifier, clientID: clientID, redirectURI: redirectURI)
    }

    private func runWebAuthentication(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let error { continuation.resume(throwing: error); return }
                guard let callbackURL else { continuation.resume(throwing: BackupError.invalidResponse); return }
                continuation.resume(returning: callbackURL)
            }
            authSession.presentationContextProvider = self
            authSession.prefersEphemeralWebBrowserSession = false
            currentSession = authSession
            if !authSession.start() {
                continuation.resume(throwing: BackupError.authorizationRequired)
            }
        }
    }

    private func exchangeCode(_ code: String, verifier: String, clientID: String, redirectURI: String) async throws -> OAuthToken {
        let body = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ]
        return try await requestToken(body: body, preservingRefreshToken: nil)
    }

    private func refreshAccessToken(refreshToken: String, clientID: String) async throws -> OAuthToken {
        let body = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        return try await requestToken(body: body, preservingRefreshToken: refreshToken)
    }

    private func requestToken(body: [String: String], preservingRefreshToken: String?) async throws -> OAuthToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.httpBody = body.formURLEncoded.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackupError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw BackupError.network("OAuth token request failed (\(http.statusCode)): \(text)")
        }
        let responseBody = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        let token = OAuthToken(
            accessToken: responseBody.accessToken,
            refreshToken: responseBody.refreshToken ?? preservingRefreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(responseBody.expiresIn))
        )
        tokenStore.saveToken(token)
        return token
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var data = Data(repeating: 0, count: byteCount)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.bindMemory(to: UInt8.self).baseAddress!) }
        return data.base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private struct OAuthTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

protocol BackupSecretStore: AnyObject {
    func string(for key: String) -> String?
    func setString(_ value: String, for key: String)
    func deleteString(for key: String)
}

final class KeychainBackupSecretStore: BackupSecretStore {
    private let service = "ShaydeTree.Writers-Block.googleDriveBackup"

    func string(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setString(_ value: String, for key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
        var query = baseQuery(key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func deleteString(for key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

@MainActor
final class BackupService {
    static let shared = BackupService()

    private static let passphraseKey = "drive-sync-passphrase"
    private static let clientIdKey = "drive-sync-client-id"

    private let driveClient: DriveAppDataClient
    private let oauthProvider: OAuthAccessTokenProvider
    private let secretStore: BackupSecretStore
    private let defaults: UserDefaults
    private let memosRoot: URL

    convenience init() {
        self.init(
            driveClient: RealDriveAppDataClient(),
            oauthProvider: GoogleDriveOAuthService(),
            secretStore: KeychainBackupSecretStore(),
            defaults: .standard,
            memosRoot: VoiceMemoService.memosRoot()
        )
    }

    init(
        driveClient: DriveAppDataClient,
        oauthProvider: OAuthAccessTokenProvider,
        secretStore: BackupSecretStore,
        defaults: UserDefaults,
        memosRoot: URL
    ) {
        self.driveClient = driveClient
        self.oauthProvider = oauthProvider
        self.secretStore = secretStore
        self.defaults = defaults
        self.memosRoot = memosRoot
    }

    var isConfigured: Bool { oauthProvider.isConfigured }
    var hasStoredPassphrase: Bool { storedPassphrase != nil }

    func updatePassphrase(_ passphrase: String) {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            secretStore.deleteString(for: Self.passphraseKey)
        } else {
            secretStore.setString(trimmed, for: Self.passphraseKey)
        }
    }

    func backupNow(modelContext: ModelContext) async throws {
        let passphrase = try requirePassphrase()
        let accessToken = try await oauthProvider.accessToken(interactive: true)
        try await backup(modelContext: modelContext, accessToken: accessToken, passphrase: passphrase)
    }

    func restoreNow(modelContext: ModelContext) async throws {
        let passphrase = try requirePassphrase()
        let accessToken = try await oauthProvider.accessToken(interactive: true)
        try await restore(modelContext: modelContext, accessToken: accessToken, passphrase: passphrase)
    }

    func backupInBackgroundIfPossible(modelContext: ModelContext) async {
        guard let passphrase = storedPassphrase, isConfigured, oauthProvider.hasRefreshToken else { return }
        do {
            let accessToken = try await oauthProvider.accessToken(interactive: false)
            try await backup(modelContext: modelContext, accessToken: accessToken, passphrase: passphrase)
        } catch {
            return
        }
    }

    private var storedPassphrase: String? {
        secretStore.string(for: Self.passphraseKey)?.nilIfBlank
    }

    private func requirePassphrase() throws -> String {
        guard let passphrase = storedPassphrase else { throw BackupError.missingPassphrase }
        return passphrase
    }

    private func backup(modelContext: ModelContext, accessToken: String, passphrase: String) async throws {
        let snapshot = try makeSnapshot(modelContext: modelContext)
        for recording in try RecordingBackupManifest.scan(projectIds: snapshot.allProjectIds, memosRoot: memosRoot) {
            let encrypted = try SyncBlobCrypto.seal(Data(contentsOf: recording.localURL), passphrase: passphrase)
            try await upsertDriveFile(name: recording.entry.driveName, mimeType: "application/octet-stream", content: encrypted, accessToken: accessToken)
        }

        var blob = snapshot.blob
        blob.recordings = try RecordingBackupManifest.scan(projectIds: snapshot.allProjectIds, memosRoot: memosRoot).map(\.entry)
        let plaintext = try SyncJSON.encoder.encode(blob)
        let encrypted = try SyncBlobCrypto.seal(plaintext, passphrase: passphrase)
        try await upsertDriveFile(name: SyncBlob.driveFileName, mimeType: SyncBlob.driveMimeType, content: encrypted, accessToken: accessToken)
    }

    private func restore(modelContext: ModelContext, accessToken: String, passphrase: String) async throws {
        guard let remoteFile = try await driveClient.findFile(named: SyncBlob.driveFileName, accessToken: accessToken) else {
            throw BackupError.noRemoteBackup
        }
        let encrypted = try await driveClient.downloadFile(id: remoteFile.id, accessToken: accessToken)
        let plaintext: Data
        do {
            plaintext = try SyncBlobCrypto.open(encrypted, passphrase: passphrase)
        } catch {
            throw BackupError.wrongPassphraseOrCorruptData
        }
        let remoteBlob = try SyncJSON.decoder.decode(SyncBlob.self, from: plaintext)
        let localBlob = try makeSnapshot(modelContext: modelContext).blob
        let merged = SyncMerger.merge(local: localBlob, remote: remoteBlob)
        try apply(merged, to: modelContext)
        try await restoreRecordings(from: merged.recordings, accessToken: accessToken, passphrase: passphrase)
    }

    private func upsertDriveFile(name: String, mimeType: String, content: Data, accessToken: String) async throws {
        if let existing = try await driveClient.findFile(named: name, accessToken: accessToken) {
            try await driveClient.updateFile(id: existing.id, mimeType: mimeType, content: content, accessToken: accessToken)
        } else {
            _ = try await driveClient.uploadNewFile(named: name, mimeType: mimeType, content: content, accessToken: accessToken)
        }
    }

    private func makeSnapshot(modelContext: ModelContext) throws -> BackupSnapshot {
        let projects = try modelContext.fetch(FetchDescriptor<SongProject>())
        let trashed = try modelContext.fetch(FetchDescriptor<TrashedSongProject>())
        let projectIds = Set(projects.map(\.id) + trashed.map(\.id))
        let recordings = try RecordingBackupManifest.scan(projectIds: Array(projectIds), memosRoot: memosRoot).map(\.entry)
        let blob = SyncBlob(
            projects: projects.map(SyncSongProject.init(project:)),
            trashed: trashed.map(SyncTrashedSongProject.init(trashed:)),
            recordings: recordings,
            savedAt: Date(),
            savedByClientId: clientId
        )
        return BackupSnapshot(blob: blob, allProjectIds: Array(projectIds))
    }

    private func apply(_ blob: SyncBlob, to modelContext: ModelContext) throws {
        let activeById = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<SongProject>()).map { ($0.id, $0) })
        let trashById = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<TrashedSongProject>()).map { ($0.id, $0) })
        let mergedActiveIds = Set(blob.projects.map(\.id))
        let mergedTrashIds = Set(blob.trashed.map(\.id))

        for project in blob.projects {
            if let existing = activeById[project.id] {
                existing.title = project.title
                existing.lyrics = project.lyrics
                existing.theme = project.theme
                existing.updatedAt = project.updatedAt
            } else {
                modelContext.insert(project.makeModel())
            }
            if let staleTrash = trashById[project.id] {
                modelContext.delete(staleTrash)
            }
        }

        for trash in blob.trashed {
            if let existing = trashById[trash.id] {
                existing.title = trash.title
                existing.lyrics = trash.lyrics
                existing.theme = trash.theme
                existing.updatedAt = trash.updatedAt
                existing.deletedAt = trash.deletedAt
                existing.deleteAfter = trash.deleteAfter
            } else {
                modelContext.insert(trash.makeModel())
            }
            if let staleProject = activeById[trash.id] {
                modelContext.delete(staleProject)
            }
        }

        for (id, project) in activeById where mergedTrashIds.contains(id) && !mergedActiveIds.contains(id) {
            modelContext.delete(project)
        }
        for (id, trash) in trashById where mergedActiveIds.contains(id) && !mergedTrashIds.contains(id) {
            modelContext.delete(trash)
        }
        try modelContext.save()
    }

    private func restoreRecordings(from recordings: [SyncRecordingManifestEntry], accessToken: String, passphrase: String) async throws {
        for entry in recordings {
            let folder = memosRoot.appendingPathComponent(entry.projectId, isDirectory: true)
            let target = folder.appendingPathComponent(entry.fileName)
            let shouldRestore = try shouldRestoreRecording(entry: entry, localURL: target)
            guard shouldRestore else { continue }
            guard let remote = try await driveClient.findFile(named: entry.driveName, accessToken: accessToken) else { continue }
            let encrypted = try await driveClient.downloadFile(id: remote.id, accessToken: accessToken)
            let plaintext = try SyncBlobCrypto.open(encrypted, passphrase: passphrase)
            let digest = SHA256.hash(data: plaintext).map { String(format: "%02x", $0) }.joined()
            guard digest == entry.sha256, plaintext.count == entry.sizeBytes else {
                throw BackupError.recordingIntegrityMismatch(entry.driveName)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temp = folder.appendingPathComponent(".\(entry.fileName).tmp-\(UUID().uuidString)")
            try plaintext.write(to: temp, options: [.atomic])
            try FileManager.default.setAttributes([.modificationDate: entry.modifiedAt], ofItemAtPath: temp.path)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
        }
    }

    private func shouldRestoreRecording(entry: SyncRecordingManifestEntry, localURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: localURL.path) else { return true }
        let values = try localURL.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modifiedAt = values.contentModificationDate else { return true }
        let localMillis = Self.epochMilliseconds(modifiedAt)
        let remoteMillis = Self.epochMilliseconds(entry.modifiedAt)
        if localMillis < remoteMillis { return true }
        if localMillis > remoteMillis { return false }
        let localData = try Data(contentsOf: localURL)
        let localDigest = SHA256.hash(data: localData).map { String(format: "%02x", $0) }.joined()
        return localDigest != entry.sha256
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private var clientId: String {
        if let existing = defaults.string(forKey: Self.clientIdKey), !existing.isEmpty { return existing }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.clientIdKey)
        return id
    }
}

private struct BackupSnapshot {
    var blob: SyncBlob
    var allProjectIds: [String]
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Dictionary where Key == String, Value == String {
    var formURLEncoded: String {
        map { key, value in
            "\(key.urlFormEncoded)=\(value.urlFormEncoded)"
        }
        .sorted()
        .joined(separator: "&")
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? self
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=")
        return set
    }()
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
