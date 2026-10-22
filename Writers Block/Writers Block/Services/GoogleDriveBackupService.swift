import AuthenticationServices
import CryptoKit
import Foundation
import SwiftData
import UIKit

enum BackupError: Error, Equatable {
    case notConfigured
    case authorizationRequired
    case noRemoteBackup
    case network(String)
    case quotaExceeded
    case serverError(String)
    case invalidRequest
    case invalidResponse
    case damagedManifest
    case newerAppVersion
    case wrongLegacyPassphrase
    case backupConflict
    case unsafeArchive
    case missingRemoteRecordings([String])
    case archiveTooLarge
    case recordingIntegrityMismatch(String)
    case keychainWriteFailed(OSStatus)
}

extension BackupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google Drive backup is not configured on this device."
        case .authorizationRequired:
            return "Sign in to Google Drive again to continue backup."
        case .noRemoteBackup:
            return "No Google Drive backup was found."
        case .network(let message):
            return message.isEmpty ? "Network connection failed. Check your connection and try again." : message
        case .quotaExceeded:
            return "Google Drive backup is temporarily rate-limited or out of quota. Try again later."
        case .serverError(let message):
            return message.isEmpty ? "Google Drive is temporarily unavailable. Try again later." : message
        case .invalidRequest:
            return "Google Drive backup could not build a valid request."
        case .invalidResponse:
            return "Google Drive returned an invalid response."
        case .damagedManifest:
            return "Backup file is damaged; it was not merged."
        case .newerAppVersion:
            return "This backup was written by a newer version of Writers Block. Update the app before syncing."
        case .wrongLegacyPassphrase:
            return "That passphrase did not open the older backup."
        case .backupConflict:
            return "Backup conflict, will retry."
        case .missingRemoteRecordings(let names):
            return "\(names.count) \(names.count == 1 ? "recording" : "recordings") in the backup \(names.count == 1 ? "has" : "have") no audio on Google Drive: \(names.joined(separator: ", "))"
        case .archiveTooLarge:
            return "This backup file is too large to import; it was not imported."
        case .unsafeArchive:
            return "This file is not a Writers Block backup; it was not imported."
        case .recordingIntegrityMismatch(let name):
            return "The recording \(name) did not match its backup manifest."
        case .keychainWriteFailed:
            return "Could not securely store your backup credentials on this device. Try again."
        }
    }
}

struct DriveAppDataFile: Equatable, Sendable, Decodable {
    var id: String
    var name: String
    var modifiedTime: String?
    var version: String?
    var appProperties: [String: String]?
    var sha256Checksum: String?

    init(id: String, name: String, modifiedTime: String? = nil, version: String? = nil,
         appProperties: [String: String]? = nil, sha256Checksum: String? = nil) {
        self.id = id
        self.name = name
        self.modifiedTime = modifiedTime
        self.version = version
        self.appProperties = appProperties
        self.sha256Checksum = sha256Checksum
    }
}

protocol DriveAppDataClient: AnyObject {
    func findFile(named name: String, accessToken: String) async throws -> DriveAppDataFile?
    func listFiles(prefix: String, accessToken: String) async throws -> [DriveAppDataFile]
    func downloadFile(id: String, accessToken: String) async throws -> Data
    func uploadNewFile(named name: String, mimeType: String, content: Data, appProperties: [String: String]?, accessToken: String) async throws -> DriveAppDataFile
    func updateFile(id: String, mimeType: String, content: Data, appProperties: [String: String]?, accessToken: String) async throws -> DriveAppDataFile
    func deleteFile(id: String, accessToken: String) async throws
}

protocol OAuthAccessTokenProvider: AnyObject {
    var isConfigured: Bool { get }
    var hasRefreshToken: Bool { get }
    func accessToken(interactive: Bool) async throws -> String
    /// Revokes the grant at Google, then forgets the tokens whatever the
    /// outcome. False when the revoke request failed.
    func revokeAndForget() async -> Bool
}

final class RealDriveAppDataClient: DriveAppDataClient {
    private let session: URLSession
    private let boundary = "rhymeai_boundary_ios_42"
    private static let fileFields = "id,name,modifiedTime,version,appProperties,sha256Checksum"

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
        guard var components = URLComponents(
            url: try Self.driveBaseURL().appendingPathComponent("files/\(id)"),
            resolvingAgainstBaseURL: false
        ) else {
            throw BackupError.invalidRequest
        }
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]
        var request = try request(from: components)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await data(for: request)
    }

    func uploadNewFile(named name: String, mimeType: String, content: Data, appProperties: [String: String]?, accessToken: String) async throws -> DriveAppDataFile {
        let metadata = DriveUploadMetadata(name: name, parents: ["appDataFolder"], mimeType: mimeType, appProperties: appProperties)
        return try await upload(path: "files", method: "POST", metadata: metadata, mimeType: mimeType, content: content, accessToken: accessToken)
    }

    func updateFile(id: String, mimeType: String, content: Data, appProperties: [String: String]?, accessToken: String) async throws -> DriveAppDataFile {
        let metadata = DrivePatchMetadata(mimeType: mimeType, appProperties: appProperties)
        return try await upload(path: "files/\(id)", method: "PATCH", metadata: metadata, mimeType: mimeType, content: content, accessToken: accessToken)
    }

    func deleteFile(id: String, accessToken: String) async throws {
        var request = URLRequest(url: try Self.driveBaseURL().appendingPathComponent("files/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        _ = try await data(for: request)
    }

    private func upload<T: Encodable>(path: String, method: String, metadata: T, mimeType: String, content: Data, accessToken: String) async throws -> DriveAppDataFile {
        let body = try multipartBody(metadata: metadata, mimeType: mimeType, content: content)
        guard var components = URLComponents(
            url: try Self.uploadBaseURL().appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw BackupError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: Self.fileFields)
        ]
        var request = try request(from: components)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Recordings run to 16 MiB; give a slow upload time to finish.
        request.timeoutInterval = 120
        let responseData = try await data(for: request)
        do {
            return try JSONDecoder().decode(DriveAppDataFile.self, from: responseData)
        } catch {
            throw BackupError.invalidResponse
        }
    }

    private func listFiles(query: String, accessToken: String) async throws -> [DriveAppDataFile] {
        var files: [DriveAppDataFile] = []
        var pageToken: String?
        repeat {
            guard var components = URLComponents(
                url: try Self.driveBaseURL().appendingPathComponent("files"),
                resolvingAgainstBaseURL: false
            ) else {
                throw BackupError.invalidRequest
            }
            components.queryItems = [
                URLQueryItem(name: "spaces", value: "appDataFolder"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fileFields))"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "q", value: query)
            ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var request = try request(from: components)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let responseData = try await data(for: request)
            do {
                let page = try JSONDecoder().decode(DriveFilesResponse.self, from: responseData)
                files += page.files
                pageToken = page.nextPageToken
            } catch {
                throw BackupError.invalidResponse
            }
        } while pageToken != nil
        return files
    }

    private func request(from components: URLComponents) throws -> URLRequest {
        guard let url = components.url else { throw BackupError.invalidRequest }
        return URLRequest(url: url)
    }

    private func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BackupError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                throw Self.httpError(statusCode: http.statusCode)
            }
            return data
        } catch let error as BackupError {
            throw error
        } catch let error as URLError {
            throw Self.urlError(error)
        }
    }

    private func multipartBody<T: Encodable>(metadata: T, mimeType: String, content: Data) throws -> Data {
        var body = Data()
        try appendUTF8("--\(boundary)\r\n", to: &body)
        try appendUTF8("Content-Type: application/json; charset=UTF-8\r\n\r\n", to: &body)
        body.append(try JSONEncoder().encode(metadata))
        try appendUTF8("\r\n--\(boundary)\r\n", to: &body)
        try appendUTF8("Content-Type: \(mimeType)\r\n\r\n", to: &body)
        body.append(content)
        try appendUTF8("\r\n--\(boundary)--\r\n", to: &body)
        return body
    }

    private func appendUTF8(_ string: String, to body: inout Data) throws {
        guard let data = string.data(using: .utf8) else { throw BackupError.invalidRequest }
        body.append(data)
    }

    private static func driveBaseURL() throws -> URL {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3") else {
            throw BackupError.invalidRequest
        }
        return url
    }

    private static func uploadBaseURL() throws -> URL {
        guard let url = URL(string: "https://www.googleapis.com/upload/drive/v3") else {
            throw BackupError.invalidRequest
        }
        return url
    }

    static func urlError(_ error: URLError) -> BackupError {
        switch error.code {
        case .timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
            return .network("Network connection failed. Check your connection and try again.")
        default:
            return .network(error.localizedDescription)
        }
    }

    private static func httpError(statusCode: Int) -> BackupError {
        switch statusCode {
        case 401:
            return .authorizationRequired
        case 403, 429:
            return .quotaExceeded
        case 500...599:
            return .serverError("Google Drive is temporarily unavailable. Try again later.")
        default:
            return .network("Drive request failed (\(statusCode)).")
        }
    }

    private static func escapeQueryString(_ value: String) -> String {
        // Escape backslash first, then single-quote, matching Android's driveQueryLiteral.
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}

private struct DriveFilesResponse: Decodable {
    var files: [DriveAppDataFile]
    var nextPageToken: String?
}

private struct DriveUploadMetadata: Encodable {
    var name: String
    var parents: [String]
    var mimeType: String
    var appProperties: [String: String]?
}

private struct DrivePatchMetadata: Encodable {
    var mimeType: String
    var appProperties: [String: String]?
}

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
    func saveToken(_ token: OAuthToken) throws
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

    func saveToken(_ token: OAuthToken) throws {
        guard let data = try? JSONEncoder().encode(token) else {
            throw BackupError.keychainWriteFailed(errSecParam)
        }
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BackupError.keychainWriteFailed(updateStatus)
        }
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BackupError.keychainWriteFailed(status)
        }
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

    func revokeAndForget() async -> Bool {
        defer { tokenStore.deleteToken() }
        guard let stored = tokenStore.loadToken() else { return true }
        // The refresh token revokes the whole grant, access tokens included.
        let token = stored.refreshToken?.nilIfBlank ?? stored.accessToken
        guard let url = URL(string: "https://oauth2.googleapis.com/revoke"),
              let body = ["token": token].formURLEncoded.data(using: .utf8) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
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
        let state = Self.randomURLSafeString(byteCount: 16)
        let redirectURI = "\(redirectScheme):/oauth2redirect/google"
        guard var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth") else {
            throw BackupError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.appdata"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let authorizationURL = components.url else {
            throw BackupError.invalidRequest
        }
        let callback = try await runWebAuthentication(url: authorizationURL, callbackScheme: redirectScheme)
        let code = try Self.authorizationCode(from: callback, expectedState: state)
        return try await exchangeCode(code, verifier: verifier, clientID: clientID, redirectURI: redirectURI)
    }

    static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard let returned = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              returned.queryItems?.first(where: { $0.name == "state" })?.value == expectedState,
              let code = returned.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw BackupError.invalidResponse
        }
        return code
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
        guard let url = URL(string: "https://oauth2.googleapis.com/token"),
              let encodedBody = body.formURLEncoded.data(using: .utf8) else {
            throw BackupError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = encodedBody
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw BackupError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw Self.httpError(statusCode: http.statusCode, body: text)
            }
            let responseBody = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
            let token = OAuthToken(
                accessToken: responseBody.accessToken,
                refreshToken: responseBody.refreshToken ?? preservingRefreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(responseBody.expiresIn))
            )
            try tokenStore.saveToken(token)
            return token
        } catch let error as BackupError {
            throw error
        } catch let error as URLError {
            throw Self.urlError(error)
        } catch {
            throw BackupError.invalidResponse
        }
    }

    private static func urlError(_ error: URLError) -> BackupError {
        switch error.code {
        case .timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
            return .network("Network connection failed. Check your connection and try again.")
        default:
            return .network(error.localizedDescription)
        }
    }

    private static func httpError(statusCode: Int, body: String) -> BackupError {
        switch statusCode {
        case 401:
            return .authorizationRequired
        case 403, 429:
            return .quotaExceeded
        case 500...599:
            return .serverError("Google Drive is temporarily unavailable. Try again later.")
        default:
            return .network("OAuth token request failed (\(statusCode)).")
        }
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
    func setString(_ value: String, for key: String) throws
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

    func setString(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw BackupError.keychainWriteFailed(updateStatus)
        }
        var query = baseQuery(key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw BackupError.keychainWriteFailed(status)
        }
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

/// What a backup, restore, migration or import did besides merging songs.
struct BackupReport: Equatable, Sendable {
    /// Recordings whose downloaded audio did not match the manifest; discarded.
    var damagedRecordings: [String] = []
    /// Local recordings over `SyncRecording.maxBytes`, kept on this device only.
    var oversizedRecordings = 0
    /// True once the older encrypted backup was moved to v4 and removed.
    var migratedLegacyBackup = false
    /// Older recordings that could not be moved (unreadable, missing or oversized); the old backup stays.
    var unmovedLegacyRecordings = 0
}

struct RemoteBackupSummary: Equatable, Sendable {
    var songs: Int
    var recordings: Int
}

/// What to do with an older encrypted backup (`rhymeai-projects.json`) at sync time.
enum LegacyMigrationDecision: Equatable {
    /// No older backup: back up as v4 and forget any stored passphrase.
    case none
    /// Decrypt with the stored passphrase, merge, upload v4, verify, then remove the old files.
    case migrate
    /// Leave the old files alone, back up local data as v4, and offer "Migrate older encrypted backup…".
    case askForPassphrase

    static func decide(legacyBackupExists: Bool, hasPassphrase: Bool) -> Self {
        guard legacyBackupExists else { return .none }
        return hasPassphrase ? .migrate : .askForPassphrase
    }
}

/// Backup schedule: a quiet period after the last change, then exponential
/// backoff after failures (1, 2, 4, 8 … minutes, capped at an hour).
enum BackupSchedule {
    static let debounce: TimeInterval = 30

    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(60, pow(2, Double(min(failures, 7) - 1))) * 60
    }
}

@MainActor
final class BackupService {
    static let shared: BackupService = {
        #if DEBUG
        if UITestFlags.isEnabled(UITestFlags.fakeDrive) {
            return UITestFlags.makeFakeDriveBackupService()
        }
        #endif
        return BackupService(library: .shared)
    }()

    private static let passphraseKey = "drive-sync-passphrase"
    private static let clientIdKey = "drive-sync-client-id"
    private static let backgroundFailureKey = "drive-sync-last-background-failure"
    private static let lastBackupKey = "drive-sync-last-backup-at"
    private static let legacyPendingKey = "drive-sync-legacy-backup-pending"

    private let driveClient: DriveAppDataClient
    private let oauthProvider: OAuthAccessTokenProvider
    private let secretStore: BackupSecretStore
    private let defaults: UserDefaults
    private let memosRoot: URL
    /// Recordings sync lives in the library; backup only reads its rows.
    let library: RecordingLibrary
    var recordingRecoveryRoot: URL? { memosRoot }
    private(set) var lastReport: BackupReport?

    convenience init(library: RecordingLibrary) {
        self.init(
            driveClient: RealDriveAppDataClient(),
            oauthProvider: GoogleDriveOAuthService(),
            secretStore: KeychainBackupSecretStore(),
            defaults: .standard,
            memosRoot: RecordingFiles.memosRoot(),
            library: library
        )
    }

    init(
        driveClient: DriveAppDataClient,
        oauthProvider: OAuthAccessTokenProvider,
        secretStore: BackupSecretStore,
        defaults: UserDefaults,
        memosRoot: URL,
        trashRoot: URL = RecordingFiles.memosTrashRoot(),
        library: RecordingLibrary? = nil
    ) {
        self.driveClient = driveClient
        self.oauthProvider = oauthProvider
        self.secretStore = secretStore
        self.defaults = defaults
        self.memosRoot = memosRoot
        self.library = library ?? RecordingLibrary(memosRoot: memosRoot, trashRoot: trashRoot, defaults: defaults)
    }

    var isConfigured: Bool { oauthProvider.isConfigured }
    var isConnected: Bool { oauthProvider.isConfigured && oauthProvider.hasRefreshToken }
    var lastBackupAt: Date? {
        defaults.object(forKey: Self.lastBackupKey) as? Date
    }
    var backgroundBackupFailureDescription: String? {
        defaults.string(forKey: Self.backgroundFailureKey)?.nilIfBlank
    }
    /// An older encrypted backup is on Drive and no stored passphrase can open it.
    var hasLegacyBackupToMigrate: Bool {
        isConnected && defaults.bool(forKey: Self.legacyPendingKey)
    }

    func connect() async throws {
        _ = try await oauthProvider.accessToken(interactive: true)
    }

    /// Revokes the grant and clears this device's backup state. False when the
    /// revoke request failed; local state is cleared either way.
    func disconnect() async -> Bool {
        let revoked = await oauthProvider.revokeAndForget()
        for key in [Self.lastBackupKey, Self.backgroundFailureKey, Self.legacyPendingKey] {
            defaults.removeObject(forKey: key)
        }
        lastReport = nil
        return revoked
    }

    func backupNow(modelContext: ModelContext) async throws {
        try await recordingFailure {
            let accessToken = try await oauthProvider.accessToken(interactive: true)
            try await sync(modelContext: modelContext, accessToken: accessToken, restore: false)
        }
    }

    func restoreNow(modelContext: ModelContext) async throws {
        try await recordingFailure {
            let accessToken = try await oauthProvider.accessToken(interactive: true)
            try await sync(modelContext: modelContext, accessToken: accessToken, restore: true)
        }
    }

    func backupInBackgroundIfPossible(modelContext: ModelContext) async {
        guard isConnected else { return }
        try? await recordingFailure {
            let accessToken = try await oauthProvider.accessToken(interactive: false)
            try await sync(modelContext: modelContext, accessToken: accessToken, restore: false)
        }
    }

    func migrateLegacyBackup(passphrase: String, modelContext: ModelContext) async throws {
        try await recordingFailure {
            let accessToken = try await oauthProvider.accessToken(interactive: true)
            try await sync(modelContext: modelContext, accessToken: accessToken, restore: false, enteredPassphrase: passphrase)
        }
    }

    /// A failure stays as the status (with Retry) until a later run succeeds.
    private func recordingFailure(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch {
            recordBackgroundBackupFailure(error)
            throw error
        }
    }

    /// Songs and recordings in the v4 backup, or nil when there is none.
    func remoteBackupSummary() async throws -> RemoteBackupSummary? {
        guard isConnected else { return nil }
        let accessToken = try await oauthProvider.accessToken(interactive: false)
        guard let file = try await driveClient.findFile(named: SyncBlob.driveFileName, accessToken: accessToken) else { return nil }
        let blob = try await downloadManifest(file, accessToken: accessToken)
        return RemoteBackupSummary(songs: blob.projects.count, recordings: blob.recordings.count)
    }

    // MARK: Sync

    private typealias RemoteFiles = [String: DriveAppDataFile]
    private static let manifestWriteAttempts = 3

    /// Back up (`restore` false) merges this device into Drive and leaves local data
    /// alone; a migration is a backup. Restore merges both ways: it applies the merge
    /// here, uploads local-only items, then downloads missing recordings.
    private func sync(modelContext: ModelContext, accessToken: String, restore: Bool, enteredPassphrase: String? = nil) async throws {
        var report = BackupReport()
        // Restore recovery: drop what an interrupted restore or import left staged.
        if restore { RecordingFiles.clearStaging(for: memosRoot) }
        var remoteRecordings = try await recordingFiles(accessToken: accessToken)
        let legacy = try await openLegacyBackupIfNeeded(
            modelContext: modelContext, accessToken: accessToken,
            remoteRecordings: remoteRecordings, enteredPassphrase: enteredPassphrase
        )
        // Backup reads the library as it is; restore first brings it up to date.
        if restore { try library.reconcile(context: modelContext) }
        report.oversizedRecordings = library.oversizedCount

        let manifests = try await manifestFiles(accessToken: accessToken)
        if restore, manifests.isEmpty, legacy == nil { throw BackupError.noRemoteBackup }
        var merged = try SyncMerger.merge(local: try makeSnapshot(modelContext: modelContext), remote: legacy?.blob ?? SyncBlob(savedAt: .distantPast))
        for file in manifests {
            merged = try SyncMerger.merge(local: merged, remote: try await downloadManifest(file, accessToken: accessToken))
        }
        _ = try await uploadRecordings(of: &merged, modelContext: modelContext, legacyAudio: legacy?.audio ?? [:], remote: &remoteRecordings, accessToken: accessToken)

        // Write, read back and compare. Another device writing in between shows up
        // as a different hash: merge its manifest in and try again.
        var target = manifests.max { ($0.modifiedTime ?? "") < ($1.modifiedTime ?? "") }
        var verified = false
        for _ in 0..<Self.manifestWriteAttempts {
            // Edits saved while the requests above were in flight join this manifest.
            merged = finalizedBlob(try SyncMerger.merge(local: try makeSnapshot(modelContext: modelContext), remote: merged))
            let missing = try await uploadRecordings(of: &merged, modelContext: modelContext, legacyAudio: legacy?.audio ?? [:], remote: &remoteRecordings, accessToken: accessToken)
            // Every recording the manifest lists must be on Drive, verified or just uploaded.
            if !restore, !missing.isEmpty { throw BackupError.missingRemoteRecordings(missing) }
            let content = try merged.encodedManifest()
            if let current = target {
                target = try await driveClient.updateFile(id: current.id, mimeType: SyncBlob.driveMimeType, content: content, appProperties: nil, accessToken: accessToken)
            } else {
                target = try await driveClient.uploadNewFile(named: SyncBlob.driveFileName, mimeType: SyncBlob.driveMimeType, content: content, appProperties: nil, accessToken: accessToken)
            }
            guard let written = target else { throw BackupError.invalidResponse }
            let readBack = try await downloadManifest(written, accessToken: accessToken)
            if readBack.manifestSha256 == merged.manifestSha256 {
                verified = true
                break
            }
            merged = try SyncMerger.merge(local: merged, remote: readBack)
        }
        guard verified, let target else { throw BackupError.backupConflict }
        // Duplicates are folded into the verified manifest above; only now remove them.
        for duplicate in manifests where duplicate.id != target.id {
            try await driveClient.deleteFile(id: duplicate.id, accessToken: accessToken)
        }

        try await deleteRemoteRecordingsCoveredByDeletions(merged.deletions, recordings: merged.recordings, remote: remoteRecordings, accessToken: accessToken)
        var missingOnDrive: [String] = []
        if restore {
            try apply(merged, to: modelContext)
            try deleteLocalRecordingsCoveredByDeletions(merged.deletions)
            (report.damagedRecordings, missingOnDrive) = try await downloadMissingRecordings(merged.recordings, remote: remoteRecordings, modelContext: modelContext, accessToken: accessToken)
            try library.reconcile(context: modelContext)
        }

        if let legacy {
            report.unmovedLegacyRecordings = legacy.unmovedRecordings
            if try await legacyBackupIsPreserved(legacy, in: merged, remote: try await recordingFiles(accessToken: accessToken), accessToken: accessToken) {
                let moved = Set(legacy.allRecordings.map { RecordingBackupManifest.legacyDriveName(projectId: $0.projectId, fileName: $0.fileName) })
                try await removeLegacyBackup(movedRecordingNames: moved, remoteRecordings: remoteRecordings, accessToken: accessToken)
                report.migratedLegacyBackup = true
            } else {
                // Keep the old files, the passphrase and the row until everything is preserved.
                if let enteredPassphrase {
                    try? secretStore.setString(enteredPassphrase.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n")), for: Self.passphraseKey)
                }
                defaults.set(true, forKey: Self.legacyPendingKey)
            }
        }
        lastReport = report
        // A restore that could not fetch every recording is not a complete success.
        if !missingOnDrive.isEmpty { throw BackupError.missingRemoteRecordings(missingOnDrive) }
        defaults.set(Date(), forKey: Self.lastBackupKey)
        clearBackgroundBackupFailure()
    }

    // MARK: Migration from the encrypted backup

    private struct LegacyBackup {
        /// The old songs and tombstones, and the recordings that could be opened.
        var blob: SyncBlob
        /// Every recording the old manifest listed; all must be verified before cleanup.
        var allRecordings: [SyncRecording]
        /// Decrypted, verified audio by recording key; it goes to Drive, never to this device.
        var audio: [String: Data]
        /// Recordings that could not be read, are missing, or are over the size cap.
        var unmovedRecordings: Int
    }

    private var storedPassphrase: String? {
        secretStore.string(for: Self.passphraseKey)?.nilIfBlank
    }

    private func openLegacyBackupIfNeeded(
        modelContext: ModelContext, accessToken: String, remoteRecordings: RemoteFiles, enteredPassphrase: String?
    ) async throws -> LegacyBackup? {
        let legacyFile = try await driveClient.findFile(named: LegacySyncBlob.driveFileName, accessToken: accessToken)
        let passphrase = enteredPassphrase.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n")) } ?? storedPassphrase
        switch LegacyMigrationDecision.decide(legacyBackupExists: legacyFile != nil, hasPassphrase: passphrase?.isEmpty == false) {
        case .none:
            secretStore.deleteString(for: Self.passphraseKey)
            defaults.set(false, forKey: Self.legacyPendingKey)
            if enteredPassphrase != nil { throw BackupError.noRemoteBackup }
            return nil
        case .askForPassphrase:
            defaults.set(true, forKey: Self.legacyPendingKey)
            return nil
        case .migrate:
            guard let legacyFile, let passphrase else { return nil }
            let legacy: LegacySyncBlob
            do {
                legacy = try SyncBlobCrypto.openManifest(try await driveClient.downloadFile(id: legacyFile.id, accessToken: accessToken), passphrase: passphrase)
            } catch SyncBlobCryptoError.unsupportedEnvelopeVersion {
                throw BackupError.newerAppVersion
            } catch SyncValidationError.unsupportedVersion {
                throw BackupError.newerAppVersion
            } catch let error as BackupError {
                throw error
            } catch {
                if enteredPassphrase != nil { throw BackupError.wrongLegacyPassphrase }
                // The stored passphrase cannot open it, so it is no use; ask instead.
                secretStore.deleteString(for: Self.passphraseKey)
                defaults.set(true, forKey: Self.legacyPendingKey)
                return nil
            }
            let upgraded = legacy.upgraded
            var audio: [String: Data] = [:]
            var unmoved = 0
            // Every listed recording counts, tombstoned ones too: only audio verified
            // in v4 lets the old copy go.
            for entry in legacy.recordings {
                guard entry.sizeBytes <= SyncRecording.maxBytes, let file = remoteRecordings[entry.driveName],
                      let opened = try? SyncBlobCrypto.open(try await driveClient.downloadFile(id: file.id, accessToken: accessToken), passphrase: passphrase),
                      opened.count == entry.sizeBytes, RecordingBackupManifest.sha256Hex(opened) == entry.sha256.lowercased() else {
                    unmoved += 1
                    continue
                }
                audio["\(entry.projectId)/\(entry.fileName)"] = opened
            }
            var opened = upgraded
            opened.recordings = upgraded.recordings.filter { audio[$0.key] != nil }
            return LegacyBackup(blob: opened, allRecordings: upgraded.recordings, audio: audio, unmovedRecordings: unmoved)
        }
    }

    /// True only when the v4 backup on Drive holds everything the old one did:
    /// every song not deleted there, at the same or a newer version, and every
    /// recording as raw audio whose SHA-256 and size match.
    private func legacyBackupIsPreserved(_ legacy: LegacyBackup, in merged: SyncBlob, remote: RemoteFiles, accessToken: String) async throws -> Bool {
        guard legacy.unmovedRecordings == 0,
              let uploaded = try await manifestFiles(accessToken: accessToken).first,
              try await downloadManifest(uploaded, accessToken: accessToken).manifestSha256 == merged.manifestSha256 else { return false }
        let kept = Dictionary((merged.projects.map { ($0.id, ($0.updatedAt, $0.lyrics)) } + merged.trashed.map { ($0.id, ($0.updatedAt, $0.lyrics)) })) { first, _ in first }
        for project in legacy.blob.projects + legacy.blob.trashed.map({ SyncSongProject(id: $0.id, title: $0.title, lyrics: $0.lyrics, theme: $0.theme, updatedAt: $0.updatedAt) }) {
            guard let version = kept[project.id] else {
                // Gone from v4 only counts when a tombstone newer than this copy removed it.
                guard merged.deletions.contains(where: { $0.fileName == nil && $0.projectId == project.id && $0.deletedAt > project.updatedAt.epochMilliseconds }) else { return false }
                continue
            }
            // The same or a newer edit of the song is in v4.
            guard version.0 > project.updatedAt || (version.0 == project.updatedAt && version.1 == project.lyrics) else { return false }
        }
        for old in legacy.allRecordings {
            guard let entry = merged.recordings.first(where: { $0.key == old.key }), entry.sha256 == old.sha256,
                  let properties = remote[entry.driveName]?.appProperties,
                  properties["sha256"] == old.sha256, properties["bytes"] == String(old.bytes) else { return false }
        }
        return true
    }

    /// Deletes the old manifest and only the old recordings verified as moved.
    private func removeLegacyBackup(movedRecordingNames: Set<String>, remoteRecordings: RemoteFiles, accessToken: String) async throws {
        for file in remoteRecordings.values where movedRecordingNames.contains(file.name) {
            try await driveClient.deleteFile(id: file.id, accessToken: accessToken)
        }
        if let legacyFile = try await driveClient.findFile(named: LegacySyncBlob.driveFileName, accessToken: accessToken) {
            try await driveClient.deleteFile(id: legacyFile.id, accessToken: accessToken)
        }
        secretStore.deleteString(for: Self.passphraseKey)
        defaults.set(false, forKey: Self.legacyPendingKey)
    }

    // MARK: Manifest and recordings on Drive

    /// Every file named like the manifest; normally one.
    private func manifestFiles(accessToken: String) async throws -> [DriveAppDataFile] {
        try await driveClient.listFiles(prefix: SyncBlob.driveFileName, accessToken: accessToken)
            .filter { $0.name == SyncBlob.driveFileName }
    }

    private func downloadManifest(_ file: DriveAppDataFile, accessToken: String) async throws -> SyncBlob {
        let data = try await driveClient.downloadFile(id: file.id, accessToken: accessToken)
        do {
            return try SyncBlob.decodeManifest(data)
        } catch SyncManifestError.newerVersion {
            throw BackupError.newerAppVersion
        } catch {
            throw BackupError.damagedManifest
        }
    }

    private func upsertDriveFile(name: String, mimeType: String, content: Data, appProperties: [String: String]?, accessToken: String) async throws -> DriveAppDataFile {
        if let existing = try await driveClient.findFile(named: name, accessToken: accessToken) {
            return try await driveClient.updateFile(id: existing.id, mimeType: mimeType, content: content, appProperties: appProperties, accessToken: accessToken)
        }
        return try await driveClient.uploadNewFile(named: name, mimeType: mimeType, content: content, appProperties: appProperties, accessToken: accessToken)
    }

    /// Every recording file in appDataFolder, v4 and legacy, by name.
    private func recordingFiles(accessToken: String) async throws -> RemoteFiles {
        Dictionary(try await driveClient.listFiles(prefix: "rec_", accessToken: accessToken).map { ($0.name, $0) }) { first, _ in first }
    }

    /// Uploads manifest recordings Drive lacks, from this device or the old backup,
    /// and stamps their `uploadedAt`.
    /// Returns the file names the manifest lists that are neither verified on
    /// Drive (SHA-256 and size) nor uploadable from here.
    private func uploadRecordings(of merged: inout SyncBlob, modelContext: ModelContext, legacyAudio: [String: Data], remote: inout RemoteFiles, accessToken: String) async throws -> [String] {
        let rows = Dictionary(try modelContext.fetch(FetchDescriptor<Recording>()).map { ($0.key, $0) }) { first, _ in first }
        var missing: [String] = []
        for index in merged.recordings.indices {
            let entry = merged.recordings[index]
            let present = remote[entry.driveName]?.appProperties
            // Present only when both the hash and the size match.
            guard present?["sha256"] != entry.sha256 || present?["bytes"] != String(entry.bytes) else { continue }
            // Only audio that is the manifest's (winning) content is uploaded.
            let audio: Data
            if let row = rows[entry.key], row.sha256 == entry.sha256 {
                audio = row.audio
            } else if let migrated = legacyAudio[entry.key], RecordingBackupManifest.sha256Hex(migrated) == entry.sha256 {
                audio = migrated
            } else {
                missing.append(entry.fileName)
                continue
            }
            let properties = ["projectId": entry.projectId, "fileName": entry.fileName, "sha256": entry.sha256, "bytes": String(entry.bytes)]
            let uploaded = try await upsertDriveFile(name: entry.driveName, mimeType: "application/octet-stream", content: audio, appProperties: properties, accessToken: accessToken)
            if let checksum = uploaded.sha256Checksum, checksum.lowercased() != entry.sha256 {
                throw BackupError.recordingIntegrityMismatch(entry.fileName)
            }
            var file = uploaded
            file.appProperties = properties
            // The precedence time stays the one the row carries (A20); it is not restamped.
            remote[entry.driveName] = file
        }
        return missing
    }

    /// Downloads recordings missing on this device. Never writes over a local
    /// file; audio that does not match the manifest is discarded and named.
    private func downloadMissingRecordings(_ entries: [SyncRecording], remote: RemoteFiles, modelContext: ModelContext, accessToken: String) async throws -> (damaged: [String], missing: [String]) {
        var damaged: [String] = []
        var missing: [String] = []
        for entry in entries where entry.bytes <= SyncRecording.maxBytes {
            let target = try RecordingFiles.localURL(projectId: entry.projectId, fileName: entry.fileName, memosRoot: memosRoot)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            guard let file = remote[entry.driveName] else {
                missing.append(entry.fileName)
                continue
            }
            let audio = try await driveClient.downloadFile(id: file.id, accessToken: accessToken)
            guard audio.count == entry.bytes, RecordingBackupManifest.sha256Hex(audio) == entry.sha256 else {
                damaged.append(entry.fileName)
                continue
            }
            // A file that appeared here while downloading wins; the download is dropped.
            try library.commitRestored(audio, entry: entry, origin: .restored, context: modelContext)
        }
        return (damaged, missing)
    }

    /// Removes Drive audio for recordings the merge dropped by tombstone.
    private func deleteRemoteRecordingsCoveredByDeletions(_ deletions: [SyncDeletion], recordings: [SyncRecording], remote: RemoteFiles, accessToken: String) async throws {
        let live = Set(recordings.map(\.driveName))
        for file in remote.values.sorted(by: { $0.name < $1.name }) where !live.contains(file.name) && !file.name.hasSuffix(".enc") {
            let projectId = file.appProperties?["projectId"]
            let fileName = file.appProperties?["fileName"]
            let covered = deletions.contains { deletion in
                if let projectId, let fileName {
                    return deletion.projectId == projectId && (deletion.fileName == nil || deletion.fileName == fileName)
                }
                // Files without properties: match their names.
                guard let name = deletion.fileName else { return file.name.hasPrefix("rec_\(deletion.projectId)_") }
                return file.name == RecordingBackupManifest.driveName(projectId: deletion.projectId, fileName: name)
            }
            if covered { try await driveClient.deleteFile(id: file.id, accessToken: accessToken) }
        }
    }

    // MARK: Export and import

    /// The "Export all songs" zip: `manifest.json` (v4), `songs/<title>.txt`,
    /// `songs/<id>.json` and `recordings/<projectId>/<fileName>`.
    func exportArchive(modelContext: ModelContext, now: Date = Date()) throws -> (fileName: String, data: Data) {
        let blob = finalizedBlob(try SyncMerger.merge(local: try makeSnapshot(modelContext: modelContext), remote: SyncBlob(savedAt: .distantPast)))
        var entries: [(path: String, data: Data)] = [("manifest.json", try blob.encodedManifest())]
        var usedNames = Set<String>()
        for project in try modelContext.fetch(FetchDescriptor<SongProject>()).sorted(by: { $0.id < $1.id }) {
            var name = RecordingFiles.sanitizeName(project.title)
            if name.isEmpty || name.hasPrefix(".") || usedNames.contains(name.lowercased()) { name = project.id }
            usedNames.insert(name.lowercased())
            entries.append(("songs/\(name).txt", try LyricsExporter.data(for: project, format: .txt)))
            entries.append(("songs/\(project.id).json", try LyricsExporter.data(for: project, format: .json)))
        }
        let rows = Dictionary(try modelContext.fetch(FetchDescriptor<Recording>()).map { ($0.key, $0) }) { first, _ in first }
        for entry in blob.recordings {
            guard let row = rows[entry.key] else { continue }
            entries.append(("recordings/\(entry.projectId)/\(entry.fileName)", row.audio))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return ("WritersBlock-backup-\(formatter.string(from: now)).zip", try BackupArchive.zip(entries))
    }

    /// Merges an exported zip, or a bare v4 `manifest.json`, into the library.
    /// Recordings in the zip that are missing here are added; nothing local is replaced.
    func importArchive(_ data: Data, modelContext: ModelContext) throws {
        var report = BackupReport()
        RecordingFiles.clearStaging(for: memosRoot)
        var files: [String: Data] = [:]
        var manifestData = data
        if BackupArchive.isZip(data) {
            do {
                // Only the layout "Export all songs" writes is accepted.
                files = try BackupArchive.unzip(data) { name in
                    name == "manifest.json" || name.hasPrefix("songs/") || name.hasPrefix("recordings/")
                }
            } catch BackupArchiveError.unsafePath {
                throw BackupError.unsafeArchive
            } catch BackupArchiveError.tooLarge {
                throw BackupError.archiveTooLarge
            }
            guard let manifest = files["manifest.json"] else { throw BackupError.damagedManifest }
            manifestData = manifest
        }
        let imported: SyncBlob
        do {
            imported = try SyncBlob.decodeManifest(manifestData)
        } catch SyncManifestError.newerVersion {
            throw BackupError.newerAppVersion
        } catch {
            throw BackupError.damagedManifest
        }
        try library.reconcile(context: modelContext)
        report.oversizedRecordings = library.oversizedCount
        let merged = try SyncMerger.merge(local: try makeSnapshot(modelContext: modelContext), remote: imported)
        try apply(merged, to: modelContext)
        try deleteLocalRecordingsCoveredByDeletions(merged.deletions)
        for entry in merged.recordings {
            guard let audio = files["recordings/\(entry.projectId)/\(entry.fileName)"] else { continue }
            let target = try RecordingFiles.localURL(projectId: entry.projectId, fileName: entry.fileName, memosRoot: memosRoot)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            guard RecordingBackupManifest.sha256Hex(audio) == entry.sha256 else {
                report.damagedRecordings.append(entry.fileName)
                continue
            }
            try library.commitRestored(audio, entry: entry, origin: .imported, context: modelContext)
        }
        try library.reconcile(context: modelContext)
        lastReport = report
    }

    // MARK: Local library

    private func finalizedBlob(_ blob: SyncBlob) -> SyncBlob {
        var finalized = blob
        finalized.savedAt = Date()
        finalized.savedByClientId = clientId
        finalized.platform = "ios"
        return finalized
    }

    private func recordBackgroundBackupFailure(_ error: Error) {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            defaults.set(description, forKey: Self.backgroundFailureKey)
        } else {
            defaults.set(error.localizedDescription, forKey: Self.backgroundFailureKey)
        }
    }

    private func clearBackgroundBackupFailure() {
        defaults.removeObject(forKey: Self.backgroundFailureKey)
    }

    private func makeSnapshot(modelContext: ModelContext) throws -> SyncBlob {
        let projects = try modelContext.fetch(FetchDescriptor<SongProject>())
        let trashed = try modelContext.fetch(FetchDescriptor<TrashedSongProject>())
        let deletionRecords = try modelContext.fetch(FetchDescriptor<SyncDeletionRecord>())
        let deletions = try SyncMerger.mergeDeletions(deletionRecords.map(\.deletion))
        let projectIds = Set(projects.map(\.id) + trashed.map(\.id))
        let recordings = try modelContext.fetch(FetchDescriptor<Recording>())
            .filter { projectIds.contains($0.projectId) }
            .map(\.syncEntry)
        return SyncBlob(
            projects: projects.map(SyncSongProject.init(project:)),
            trashed: trashed.map(SyncTrashedSongProject.init(trashed:)),
            recordings: recordings,
            deletions: deletions,
            savedAt: Date(),
            savedByClientId: clientId
        )
    }

    private func apply(_ blob: SyncBlob, to modelContext: ModelContext) throws {
        let latestLocal = try makeSnapshot(modelContext: modelContext)
        let blob = try SyncMerger.merge(local: latestLocal, remote: blob)
        try blob.validate()
        let activeById = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<SongProject>()).map { ($0.id, $0) })
        let trashById = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<TrashedSongProject>()).map { ($0.id, $0) })
        let existingDeletionRecords = try modelContext.fetch(FetchDescriptor<SyncDeletionRecord>())
        let mergedActiveIds = Set(blob.projects.map(\.id))
        let mergedTrashIds = Set(blob.trashed.map(\.id))
        // A kept tombstone of a song edited after it does not remove the song.
        let deletedProjectIds = Set(blob.deletions.filter { $0.fileName == nil }.map(\.projectId))
            .subtracting(mergedActiveIds).subtracting(mergedTrashIds)

        for deletion in blob.deletions {
            if let existing = existingDeletionRecords.first(where: { $0.projectId == deletion.projectId && $0.fileName == deletion.fileName }) {
                existing.deletedAt = max(existing.deletedAt, deletion.deletedAt)
            } else {
                modelContext.insert(SyncDeletionRecord(deletion: deletion))
            }
        }

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
        for (id, project) in activeById where deletedProjectIds.contains(id) {
            modelContext.delete(project)
        }
        for (id, trash) in trashById where deletedProjectIds.contains(id) {
            modelContext.delete(trash)
        }
        try modelContext.save()
    }

    /// Removes local memo files (live and trashed) that a tombstone newer than the file covers.
    private func deleteLocalRecordingsCoveredByDeletions(_ deletions: [SyncDeletion]) throws {
        for projectId in Set(deletions.map(\.projectId)) {
            let tombstones = deletions.filter { $0.projectId == projectId }
            for (fileName, url) in try RecordingBackupManifest.scanFiles(projectId: projectId, memosRoot: memosRoot)
            where tombstones.contains(where: { $0.covers(projectId: projectId, fileName: fileName, modifiedAt: RecordingFiles.modificationDate(url)) }) {
                try RecordingFiles.removeItemIfPresent(at: url, within: memosRoot)
            }
        }
        for trashed in RecordingFiles.trashedMemos(in: library.trashRoot)
        where deletions.contains(where: { $0.covers(projectId: trashed.projectId, fileName: trashed.originalName, modifiedAt: trashed.deletedAt) }) {
            try RecordingFiles.removeItemIfPresent(at: trashed.url, within: library.trashRoot)
        }
    }

    private var clientId: String {
        if let existing = defaults.string(forKey: Self.clientIdKey), !existing.isEmpty { return existing }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.clientIdKey)
        return id
    }
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
