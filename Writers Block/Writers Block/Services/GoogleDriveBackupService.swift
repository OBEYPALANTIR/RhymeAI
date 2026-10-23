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
    case damagedRemoteRecordings([String])
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
        case .damagedRemoteRecordings(let names):
            return "\(names.count) \(names.count == 1 ? "recording" : "recordings") on Google Drive did not match the backup and \(names.count == 1 ? "was" : "were") not restored: \(names.joined(separator: ", "))"
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

    init(session: URLSession = PinnedTrust.session) {
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
        session: URLSession = PinnedTrust.session
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
    /// Export: recordings it could not include (no verified bytes here, or files the
    /// library has not taken in), by name; never left out silently.
    var leftOutRecordings: [String] = []
    /// Drive objects of a known recording id holding other bytes (A40): kept, reported.
    var conflictingDriveObjects: [String] = []
    /// Recordings not uploaded because Drive holds different audio under their id (A40).
    var notUploadedConflicts: [String] = []
    /// Recordings that lose to a tombstone only by a repaired time: kept on Drive (A41).
    var deferredRepairedCleanup: [String] = []
    /// Drive objects an earlier build had marked for removal without content proof: kept.
    var unresolvedCleanup = 0
    /// The cleanup record could not be read: no cleanup ran (it is kept for diagnosis).
    var cleanupDeferred = false
    /// Old encrypted objects not removed because they were not the verified copy.
    var retainedLegacyObjects = 0
    /// Songs (active or Trash, here or only on Drive) that a tombstone removes while
    /// their own time is a repair (A41): kept in the song recovery folder first, by title.
    var recoveredRepairedSongs: [String] = []
    /// Recordings held here with other audio than the backup lists for their id (A40):
    /// both kept, neither uploaded over nor downloaded over the other.
    var localDigestConflicts: [String] = []
    /// Export: quarantined files and takes waiting to be saved are never exported.
    var quarantinedNotExported = 0
    var takesWaitingNotExported = 0
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

    /// Every raw object per Drive name: a race can leave more than one (finding 9).
    private typealias RemoteFiles = [String: [DriveAppDataFile]]

    /// The object under a name whose properties carry this hash and size, if any.
    private static func intact(_ remote: RemoteFiles, _ name: String, sha256: String, bytes: Int64) -> DriveAppDataFile? {
        remote[name]?.first { $0.appProperties?["sha256"] == sha256 && $0.appProperties?["bytes"] == String(bytes) }
    }
    private static let manifestWriteAttempts = 3

    /// Back up (`restore` false) merges this device into Drive and leaves local data
    /// alone; a migration is a backup. Restore merges both ways: it applies the merge
    /// here, uploads local-only items, then downloads missing recordings.
    private func sync(modelContext: ModelContext, accessToken: String, restore: Bool, enteredPassphrase: String? = nil) async throws {
        // A restore changes recordings, so it holds the library's gate throughout (T4);
        // a backup only reads them.
        if restore {
            try await library.withGate { try await syncHoldingGate(modelContext: modelContext, accessToken: accessToken, restore: true, enteredPassphrase: enteredPassphrase) }
        } else {
            try await syncHoldingGate(modelContext: modelContext, accessToken: accessToken, restore: false, enteredPassphrase: enteredPassphrase)
        }
    }

    private func syncHoldingGate(modelContext: ModelContext, accessToken: String, restore: Bool, enteredPassphrase: String?) async throws {
        var report = BackupReport()
        // Restore recovery: drop what an interrupted restore or import left staged,
        // except what a row is waiting for (T1.7).
        if restore { library.clearStaging(context: modelContext) }
        var remoteRecordings = try await recordingFiles(accessToken: accessToken)
        let legacy = try await openLegacyBackupIfNeeded(
            modelContext: modelContext, accessToken: accessToken,
            remoteRecordings: remoteRecordings, enteredPassphrase: enteredPassphrase
        )
        // Backup reads the library as it is; restore first brings it up to date.
        if restore { try await library.reconcile(context: modelContext) }
        // A32: missing times are fixed on the rows themselves before anything is
        // resolved (the one write a backup makes to local data).
        try repairLocalPrecedence(modelContext)
        report.oversizedRecordings = try await unpreservedOversizedCount(remote: remoteRecordings)

        // Every remote-side input seen in this run, unresolved, in the order seen:
        // each candidate gathers them all with the current local snapshot and
        // resolves once (A18). Content seen once is never dropped (A14).
        var inputs: [SyncBlob] = legacy.map { [$0.blob] } ?? []
        var seen = Set<String>()
        var manifests = try await manifestFiles(accessToken: accessToken)
        if restore, manifests.isEmpty, legacy == nil { throw BackupError.noRemoteBackup }
        for file in manifests {
            let blob = try await downloadManifest(file, accessToken: accessToken)
            if seen.insert(blob.manifestSha256).inserted { inputs.append(blob) }
        }
        let legacyAudioIds = Set(legacy?.audio.keys.map { $0 } ?? [])
        let legacyOnlyIds = Set(legacy?.allRecordings.map(\.id) ?? []).subtracting(legacyAudioIds)
        /// An old recording whose audio could not be opened is listed only when this
        /// device or Drive holds its bytes; it still took part in the resolution.
        func listable(_ entry: SyncRecording) throws -> Bool {
            guard legacyOnlyIds.contains(entry.id) else { return true }
            if Self.intact(remoteRecordings, entry.driveName, sha256: entry.sha256, bytes: entry.bytes) != nil { return true }
            return try modelContext.fetch(FetchDescriptor<Recording>()).contains { $0.id == entry.id && $0.sha256 == entry.sha256 }
        }
        // The names held here when the written candidate was built: a rename made
        // while this run waited is not overwritten by the written name.
        var namesAtCandidate: [String: (String, Bool)] = [:]
        func candidate() throws -> SyncBlob {
            namesAtCandidate = Dictionary(try modelContext.fetch(FetchDescriptor<Recording>()).map { ($0.id, ($0.displayName, $0.displayNameChanged)) }) { first, _ in first }
            var resolved = try resolve(inputs, with: modelContext)
            resolved.recordings = try resolved.recordings.filter(listable)
            return finalizedBlob(resolved)
        }
        /// Folds in any manifest written since the last look; true when something new arrived.
        func absorbFreshManifests() async throws -> Bool {
            var changed = false
            for file in try await manifestFiles(accessToken: accessToken) {
                if !manifests.contains(where: { $0.id == file.id }) { manifests.append(file) }
                let blob = try await downloadManifest(file, accessToken: accessToken)
                if seen.insert(blob.manifestSha256).inserted {
                    inputs.append(blob)
                    changed = true
                }
            }
            return changed
        }
        let legacyAudio = legacy?.audio ?? [:]
        let legacyIds = Set(legacy?.allRecordings.map(\.id) ?? [])

        var merged = try candidate()
        var uploadConflicts = Set<String>()
        var localConflicts = Set<String>()
        var target = manifests.max { ($0.modifiedTime ?? "") < ($1.modifiedTime ?? "") }
        var verified = false
        for _ in 0..<Self.manifestWriteAttempts {
            // Upload, then look again; only a look that finds nothing new, after the
            // last upload, lets the manifest be written (A18).
            var missing: [String] = []
            var settled = false
            for _ in 0..<Self.manifestWriteAttempts {
                merged = try candidate()
                missing = try await uploadRecordings(merged, legacy: legacy, modelContext: modelContext, legacyAudio: legacyAudio, remote: &remoteRecordings,
                                                     conflicts: &uploadConflicts, localConflicts: &localConflicts, accessToken: accessToken)
                if try await !absorbFreshManifests() {
                    settled = true
                    break
                }
            }
            guard settled else { throw BackupError.backupConflict }
            // Every recording the manifest lists must be on Drive, verified or just uploaded.
            if !restore, !missing.isEmpty { throw BackupError.missingRemoteRecordings(missing) }
            // A song the manifest drops only against a repaired time is kept here first.
            try preserveRepairedSongLosers(from: [fixingPrecedence(try makeSnapshot(modelContext: modelContext))] + inputs.map(fixingPrecedence),
                                           merged: merged, report: &report)
            let content = try merged.encodedManifest()
            if target == nil { target = manifests.max { ($0.modifiedTime ?? "") < ($1.modifiedTime ?? "") } }
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
            // Another device wrote in between: its manifest joins the inputs.
            if seen.insert(readBack.manifestSha256).inserted { inputs.append(readBack) }
        }
        guard verified, let target else { throw BackupError.backupConflict }
        try adoptWrittenNames(merged.recordings, heldBefore: namesAtCandidate, in: modelContext)
        // Duplicates are folded into the verified manifest above; only now remove them.
        for duplicate in manifests where duplicate.id != target.id {
            try await driveClient.deleteFile(id: duplicate.id, accessToken: accessToken)
        }

        // Precedence times of every recording this run gathered, before resolution.
        let gatheredRecordings = try SyncMerger.gather([fixingPrecedence(try makeSnapshot(modelContext: modelContext))] + inputs.map(fixingPrecedence)).recordings
        let gatheredById = Dictionary(gatheredRecordings.map { ($0.id, $0) }) { first, _ in first }
        report.notUploadedConflicts = uploadConflicts.sorted()
        report.localDigestConflicts = localConflicts.sorted()
        try await deleteRemoteRecordingsCoveredByDeletions(merged.deletions, recordings: merged.recordings, keeping: legacyIds,
                                                           gathered: gatheredById, remote: remoteRecordings, accessToken: accessToken, report: &report)
        var missingOnDrive: [String] = []
        var damagedOnDrive: [String] = []
        if restore {
            // The commit resolves the current local state with the original inputs, once.
            let applied = try apply(inputs: inputs, to: modelContext, report: &report)
            // Nothing a tombstone without a time names is brought back (T5.24).
            let held = try library.held(in: modelContext)
            (damagedOnDrive, missingOnDrive) = try await downloadMissingRecordings(
                try applied.recordings.filter(listable).filter { !held.contains(projectId: $0.projectId, recordingId: $0.id, displayName: $0.fileName) },
                remote: remoteRecordings, modelContext: modelContext, accessToken: accessToken)
            report.damagedRecordings = damagedOnDrive
            try await library.reconcile(context: modelContext)
        }

        if let legacy {
            report.unmovedLegacyRecordings = legacy.unmovedRecordings
            if try await legacyBackupIsPreserved(legacy, in: merged, remote: try await recordingFiles(accessToken: accessToken), accessToken: accessToken) {
                let moved = Set(legacy.allRecordings.map { RecordingBackupManifest.legacyDriveName(projectId: $0.projectId, fileName: $0.fileName) })
                report.retainedLegacyObjects = try await removeLegacyBackup(movedRecordingNames: moved, verifiedObjects: legacy.verifiedObjects,
                                                                            remoteRecordings: remoteRecordings, accessToken: accessToken)
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
        // A restore that could not fetch, or verify, every recording is not a success:
        // "Last backed up" does not advance and the failure stays shown.
        if !missingOnDrive.isEmpty { throw BackupError.missingRemoteRecordings(missingOnDrive) }
        if !damagedOnDrive.isEmpty { throw BackupError.damagedRemoteRecordings(damagedOnDrive) }
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
        /// The Drive objects whose encrypted audio was opened and verified: the only
        /// old objects cleanup may remove (T1.34).
        var verifiedObjects: Set<String> = []
    }

    /// The same id on every device for the same old recording.
    private func legacyRecordingId(_ entry: SyncRecordingManifestEntry) -> String {
        RecordingBackupManifest.legacyRecordingId(projectId: entry.projectId, fileName: entry.fileName, sha256: entry.sha256)
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
            let upgraded = legacy.upgraded(recordingId: legacyRecordingId)
            var audio: [String: Data] = [:]
            var unmoved = 0
            var verifiedObjects = Set<String>()
            // Every listed recording counts, tombstoned ones too: only audio verified
            // in v4 lets the old copy go. Every object under its name is tried, and each
            // one whose bytes open and verify is recorded by its Drive id (T1.34).
            for entry in legacy.recordings {
                var opened: Data?
                if entry.sizeBytes <= SyncRecording.maxBytes {
                    for file in (remoteRecordings[entry.driveName] ?? []).sorted(by: { $0.id < $1.id }) {
                        guard let bytes = try? SyncBlobCrypto.open(try await driveClient.downloadFile(id: file.id, accessToken: accessToken), passphrase: passphrase),
                              bytes.count == entry.sizeBytes, RecordingBackupManifest.sha256Hex(bytes) == entry.sha256.lowercased() else { continue }
                        verifiedObjects.insert(file.id)
                        opened = opened ?? bytes
                    }
                }
                guard let opened else {
                    unmoved += 1
                    continue
                }
                audio[legacyRecordingId(entry)] = opened
            }
            // Every listed recording takes part in resolution (A18); whether its audio
            // could be opened is tracked apart, in `audio`.
            return LegacyBackup(blob: upgraded, allRecordings: upgraded.recordings, audio: audio, unmovedRecordings: unmoved, verifiedObjects: verifiedObjects)
        }
    }

    /// True only when the v4 backup on Drive holds everything the old one did:
    /// every song not deleted there, at the same or a newer version, and every
    /// recording as raw audio whose SHA-256 and size match.
    private func legacyBackupIsPreserved(_ legacy: LegacyBackup, in merged: SyncBlob, remote: RemoteFiles, accessToken: String) async throws -> Bool {
        guard legacy.unmovedRecordings == 0,
              let uploaded = try await manifestFiles(accessToken: accessToken).first,
              try await downloadManifest(uploaded, accessToken: accessToken).manifestSha256 == merged.manifestSha256 else { return false }
        // Each old song or Trash entry, its times fixed and flagged like any input
        // (T2.37), is kept when v4 holds the same or a later standing version of it,
        // each time compared with its own repair flag (A38, T2.38), or a tombstone
        // beats it (A41).
        let old = fixingPrecedence(legacy.blob)
        let active = Dictionary(merged.projects.map { ($0.id, $0) }) { first, _ in first }
        let trash = Dictionary(merged.trashed.map { ($0.id, $0) }) { first, _ in first }
        let tombstones = merged.deletions.filter(\.isSongTombstone)
        func standsAtLeast(_ new: (Date, Bool), over previous: (Date, Bool)) -> Bool {
            SyncMerger.standingTime(new, over: previous) ?? true
        }
        for project in old.projects {
            let mine = (project.updatedAt, project.precedenceRepaired)
            if let kept = active[project.id] {
                guard standsAtLeast((kept.updatedAt, kept.precedenceRepaired), over: mine),
                      kept.updatedAt != project.updatedAt || kept.precedenceRepaired != project.precedenceRepaired || kept.lyrics == project.lyrics else { return false }
            } else if let kept = trash[project.id] {
                guard standsAtLeast((kept.deletedAt, kept.trashedAtRepaired), over: mine) else { return false }
            } else {
                guard tombstones.contains(where: { $0.projectId == project.id && $0.wins(over: project.updatedAt, repaired: project.precedenceRepaired) }) else { return false }
            }
        }
        for entry in old.trashed {
            let mine = (entry.deletedAt, entry.trashedAtRepaired)
            if let kept = trash[entry.id] {
                guard standsAtLeast((kept.deletedAt, kept.trashedAtRepaired), over: mine) else { return false }
            } else if let kept = active[entry.id] {
                guard standsAtLeast((kept.updatedAt, kept.precedenceRepaired), over: mine) else { return false }
            } else {
                guard tombstones.contains(where: { $0.projectId == entry.id && $0.wins(over: entry.deletedAt, repaired: entry.trashedAtRepaired) }) else { return false }
            }
        }
        // Every old recording, tombstoned or not, must be on Drive raw with its hash and size.
        for old in legacy.allRecordings {
            guard Self.intact(remote, old.driveName, sha256: old.sha256, bytes: old.bytes) != nil else { return false }
        }
        return true
    }

    /// Deletes the old manifest and only the old recording objects verified as
    /// moved, each by its own Drive id; any other object under one of those names
    /// (other bytes, or bytes that would not open) is kept and counted (T1.34).
    @discardableResult
    private func removeLegacyBackup(movedRecordingNames: Set<String>, verifiedObjects: Set<String>, remoteRecordings: RemoteFiles, accessToken: String) async throws -> Int {
        var retained = 0
        for file in remoteRecordings.values.joined() where movedRecordingNames.contains(file.name) {
            guard verifiedObjects.contains(file.id) else {
                retained += 1
                continue
            }
            try await driveClient.deleteFile(id: file.id, accessToken: accessToken)
        }
        if let legacyFile = try await driveClient.findFile(named: LegacySyncBlob.driveFileName, accessToken: accessToken) {
            try await driveClient.deleteFile(id: legacyFile.id, accessToken: accessToken)
        }
        secretStore.deleteString(for: Self.passphraseKey)
        defaults.set(false, forKey: Self.legacyPendingKey)
        return retained
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

    /// Recordings over the cap that Drive does not hold: an oversized file counts
    /// as backed up only when a raw Drive object has its SHA-256 and size (A29).
    /// Live and Trash files are inventoried now, on every run.
    private func unpreservedOversizedCount(remote: RemoteFiles) async throws -> Int {
        let files = try await library.oversizedInventory()
        let held = Set(remote.values.joined().compactMap { file -> String? in
            guard let sha = file.appProperties?["sha256"], let bytes = file.appProperties?["bytes"] else { return nil }
            return "\(sha)/\(bytes)"
        })
        // Hashed off the main actor.
        return await Task.detached(priority: .utility) {
            files.filter { file in
                guard let size = try? RecordingFiles.facts(file).size, let digest = try? RecordingFiles.sha256(of: file) else { return true }
                return !held.contains("\(digest)/\(size)")
            }.count
        }.value
    }

    /// Every recording file in appDataFolder, v4 and legacy, by name.
    private func recordingFiles(accessToken: String) async throws -> RemoteFiles {
        Dictionary(grouping: try await driveClient.listFiles(prefix: "rec_", accessToken: accessToken), by: \.name)
    }

    /// Uploads manifest recordings Drive lacks, from this device or the old backup,
    /// and stamps their `uploadedAt`.
    /// Returns the file names the manifest lists that are neither verified on
    /// Drive (SHA-256 and size) nor uploadable from here.
    private func uploadRecordings(_ merged: SyncBlob, legacy: LegacyBackup?, modelContext: ModelContext, legacyAudio: [String: Data], remote: inout RemoteFiles,
                                  conflicts: inout Set<String>, localConflicts: inout Set<String>, accessToken: String) async throws -> [String] {
        let rows = Dictionary(try modelContext.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0) }) { first, _ in first }
        var missing: [String] = []
        // Old recordings a tombstone keeps out of the manifest still go up raw, so
        // the migration can verify every one of them (A13).
        let listed = Set(merged.recordings.map(\.id))
        let extra = (legacy?.allRecordings ?? []).filter { !listed.contains($0.id) }
        for entry in merged.recordings + extra {
            // Present only when an object under its name carries both the hash and the size.
            // A40: this device holds other bytes under the manifest's id. Both are kept:
            // the local recording stays, Drive's stays, and the clash is reported rather
            // than counted missing or left out silently.
            if let row = rows[entry.id], row.sha256 != entry.sha256 || row.bytes != entry.bytes {
                localConflicts.insert(row.displayName)
                continue
            }
            guard Self.intact(remote, entry.driveName, sha256: entry.sha256, bytes: entry.bytes) == nil else { continue }
            // A40: Drive already holds other audio for this id. It is never changed or
            // joined by another copy; the recording is not uploaded and is reported.
            let other = (remote[entry.driveName] ?? []).contains { file in
                guard let sha = file.appProperties?["sha256"] else { return false }
                return sha != entry.sha256 || file.appProperties?["bytes"] != String(entry.bytes)
            }
            if other {
                conflicts.insert(entry.fileName)
                continue
            }
            // Only audio that is the manifest's (winning) content is uploaded.
            let audio: Data
            if let row = rows[entry.id], row.sha256 == entry.sha256 {
                audio = row.audio
            } else if let migrated = legacyAudio[entry.id], RecordingBackupManifest.sha256Hex(migrated) == entry.sha256 {
                audio = migrated
            } else {
                if listed.contains(entry.id) { missing.append(entry.fileName) }
                continue
            }
            let properties = ["id": entry.id, "projectId": entry.projectId, "fileName": entry.fileName, "sha256": entry.sha256, "bytes": String(entry.bytes)]
            // A40: an existing object's content is never changed.
            let uploaded = try await driveClient.uploadNewFile(named: entry.driveName, mimeType: "application/octet-stream", content: audio, appProperties: properties, accessToken: accessToken)
            if let checksum = uploaded.sha256Checksum, checksum.lowercased() != entry.sha256 {
                throw BackupError.recordingIntegrityMismatch(entry.fileName)
            }
            var file = uploaded
            file.appProperties = properties
            remote[entry.driveName] = (remote[entry.driveName] ?? []).filter { $0.id != file.id } + [file]
        }
        return missing
    }

    /// Downloads recordings missing on this device. Never writes over a local
    /// file; audio that does not match the manifest is discarded and named.
    /// Fetches every listed recording this device lacks (by id), whatever local
    /// file holds its name. Missing or damaged Drive audio is named, never skipped.
    private func downloadMissingRecordings(_ entries: [SyncRecording], remote: RemoteFiles, modelContext: ModelContext, accessToken: String) async throws -> (damaged: [String], missing: [String]) {
        var damaged: [String] = []
        var missing: [String] = []
        let localIds = Set(try modelContext.fetch(FetchDescriptor<Recording>()).map(\.id))
        for entry in entries where entry.bytes <= SyncRecording.maxBytes && !localIds.contains(entry.id) {
            let objects = remote[entry.driveName] ?? []
            guard !objects.isEmpty else {
                missing.append(entry.fileName)
                continue
            }
            // Every object under the name is a candidate, the ones whose properties
            // match first; the first whose bytes verify is used.
            let ordered = objects.sorted { lhs, rhs in
                let left = lhs.appProperties?["sha256"] == entry.sha256, right = rhs.appProperties?["sha256"] == entry.sha256
                return left != right ? left : lhs.id < rhs.id
            }
            var verified: Data?
            for object in ordered {
                let audio = try await driveClient.downloadFile(id: object.id, accessToken: accessToken)
                if audio.count == entry.bytes, RecordingBackupManifest.sha256Hex(audio) == entry.sha256 {
                    verified = audio
                    break
                }
            }
            guard let audio = verified else {
                damaged.append(entry.fileName)
                continue
            }
            // Staged, verified, then moved in under a free name with the backup's time.
            try library.commitRestored(audio, entry: entry, origin: .restored, context: modelContext)
        }
        return (damaged, missing)
    }

    /// Removes Drive audio for recordings the merge dropped by tombstone.
    /// A40: one id, one digest. An object is removed only when its own properties
    /// (id, sha256, bytes) are those of a recording gathered in a run that a winning
    /// tombstone covers, and only by its Drive file id. Anything else is kept: another
    /// device's upload not yet in a manifest, a file from before ids, and an object of
    /// a known id with other bytes or length (returned, to be reported). A covered
    /// entry is kept here until its objects are gone, so a retry after a failed
    /// removal still has its proof.
    private func deleteRemoteRecordingsCoveredByDeletions(_ deletions: [SyncDeletion], recordings: [SyncRecording], keeping kept: Set<String>,
                                                          gathered: [String: SyncRecording], remote: RemoteFiles,
                                                          accessToken: String, report: inout BackupReport) async throws {
        let live = Set(recordings.map(\.driveName) + kept.map(RecordingBackupManifest.driveName(recordingId:)))
        // Proof an earlier build kept by Drive id and version cannot show content; the
        // objects it named are kept and reported until they are gone (T3.41).
        if var old = defaults.dictionary(forKey: Self.oldProvenCoveredKey) as? [String: String] {
            let listed = Set(remote.values.joined().map(\.id))
            old = old.filter { listed.contains($0.key) }
            report.unresolvedCleanup += old.count
            if old.isEmpty { defaults.removeObject(forKey: Self.oldProvenCoveredKey) } else { defaults.set(old, forKey: Self.oldProvenCoveredKey) }
        }
        // A damaged proof record is kept for diagnosis and no cleanup runs (T3.42).
        guard var proven = provenCovered else {
            report.cleanupDeferred = true
            return
        }
        var conflicting: [String] = []
        for file in remote.values.joined().sorted(by: { ($0.name, $0.id) < ($1.name, $1.id) }) {
            guard let id = file.appProperties?["id"], let sha = file.appProperties?["sha256"], let bytes = file.appProperties?["bytes"],
                  let known = gathered[id] ?? proven[id] else { continue }
            guard known.sha256 == sha, String(known.bytes) == bytes else {
                conflicting.append(file.name)
                continue
            }
            guard !live.contains(file.name),
                  deletions.contains(where: { $0.covers(projectId: known.projectId, recordingId: id, sha256: sha, at: known.uploadedAt, repaired: known.precedenceRepaired) }) else { continue }
            // A41: a recording that loses only because its time is a repair is kept on
            // Drive and reported; its bytes are not deleted on that judgement (T1.35).
            // Its proof is kept too, so later runs keep reporting it while the object stays.
            if known.precedenceRepaired {
                if !report.deferredRepairedCleanup.contains(known.fileName) { report.deferredRepairedCleanup.append(known.fileName) }
                proven[id] = known
                provenCovered = proven
                continue
            }
            proven[id] = known
            provenCovered = proven
            try await driveClient.deleteFile(id: file.id, accessToken: accessToken)
        }
        // Proof is dropped once no object of that id is left.
        let remaining = Set(remote.values.joined().compactMap { $0.appProperties?["id"] })
        provenCovered = proven.filter { remaining.contains($0.key) && !live.contains(RecordingBackupManifest.driveName(recordingId: $0.key)) }
        report.conflictingDriveObjects = conflicting.sorted()
    }

    /// Every song an input of this run held (this device or a manifest, active or in
    /// Trash) with a repaired time, that the written manifest leaves out under a song
    /// tombstone, is kept in the song recovery folder and read back before the
    /// manifest is written; a failure stops the run (A41, remote-only songs too).
    private func preserveRepairedSongLosers(from blobs: [SyncBlob], merged: SyncBlob, report: inout BackupReport) throws {
        let present = Set(merged.projects.map(\.id) + merged.trashed.map(\.id))
        let tombstoned = Set(merged.deletions.filter(\.isSongTombstone).map(\.projectId))
        let losers = blobs.flatMap { blob in
            blob.projects.filter(\.precedenceRepaired).map { SongRecoveryStore.Song(project: $0) }
                + blob.trashed.filter { $0.precedenceRepaired || $0.trashedAtRepaired }.map { SongRecoveryStore.Song(trashed: $0) }
        }.filter { tombstoned.contains($0.id) && !present.contains($0.id) }
        for song in losers {
            try SongRecoveryStore.keep(song, memosRoot: memosRoot)
            if !report.recoveredRepairedSongs.contains(song.title) { report.recoveredRepairedSongs.append(song.title) }
        }
    }

    /// Covered recordings whose Drive objects a run started removing (A40); nil when
    /// the record is present but cannot be read (it is left as it is).
    private var provenCovered: [String: SyncRecording]? {
        get {
            guard let raw = defaults.object(forKey: Self.provenCoveredKey) else { return [:] }
            guard let data = raw as? Data, let decoded = try? JSONDecoder().decode([String: SyncRecording].self, from: data) else { return nil }
            return decoded
        }
        set { if let newValue { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.provenCoveredKey) } }
    }

    // MARK: Export and import

    /// The "Export all songs" zip: `manifest.json` (v4), `songs/<title>.txt`,
    /// `songs/<id>.json` and `recordings/<projectId>/<fileName>`.
    func exportArchive(modelContext: ModelContext, now: Date = Date()) throws -> (fileName: String, data: Data) {
        // Times are fixed and persisted before anything is resolved (T2.40); this
        // writes rows and settings only, never a recording file.
        try repairLocalPrecedence(modelContext)
        let blob = finalizedBlob(try SyncMerger.merge(local: fixingPrecedence(try makeSnapshot(modelContext: modelContext)), remote: SyncBlob(savedAt: .distantPast)))
        var entries: [(path: String, data: Data)] = [("manifest.json", try blob.encodedManifest())]
        var usedNames = Set<String>()
        for project in try modelContext.fetch(FetchDescriptor<SongProject>()).sorted(by: { $0.id < $1.id }) {
            var name = RecordingFiles.sanitizeName(project.title)
            if name.isEmpty || name.hasPrefix(".") || usedNames.contains(name.lowercased()) { name = project.id }
            usedNames.insert(name.lowercased())
            entries.append(("songs/\(name).txt", try LyricsExporter.data(for: project, format: .txt)))
            entries.append(("songs/\(project.id).json", try LyricsExporter.data(for: project, format: .json)))
        }
        let rows = Dictionary(try modelContext.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0) }) { first, _ in first }
        let names = RecordingBackupManifest.exportNames(blob.recordings)
        var report = BackupReport()
        for entry in blob.recordings {
            guard let row = rows[entry.id], row.sha256 == entry.sha256, let name = names[entry.id] else {
                report.leftOutRecordings.append(entry.fileName)
                continue
            }
            entries.append(("recordings/\(entry.projectId)/\(name)", row.audio))
        }
        // Everything else on this device that the archive does not hold is named.
        let omitted = try library.exportOmissions(in: modelContext)
        report.leftOutRecordings += omitted.trashed.map { "\($0) (recordings Trash)" }
        report.leftOutRecordings += omitted.notTakenIn.map { "\($0) (not in the library yet)" }
        report.leftOutRecordings += omitted.oversized.map { "\($0) (over 16 MB)" }
        report.quarantinedNotExported = omitted.quarantined
        report.takesWaitingNotExported = RecordingFiles.waitingTakeCount()
        report.oversizedRecordings = library.oversizedCount
        lastReport = report
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return ("WritersBlock-backup-\(formatter.string(from: now)).zip", try BackupArchive.zip(entries))
    }

    /// Merges an exported zip, or a bare v4 `manifest.json`, into the library.
    /// Recordings in the zip that are missing here are added; nothing local is replaced.
    func importArchive(_ data: Data, modelContext: ModelContext) async throws {
        try await library.withGate { try await importArchiveHoldingGate(data, modelContext: modelContext) }
    }

    private func importArchiveHoldingGate(_ data: Data, modelContext: ModelContext) async throws {
        var report = BackupReport()
        library.clearStaging(context: modelContext)
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
            // One recording id twice is not a manifest this app writes: refused whole.
            guard Set(imported.recordings.map(\.id)).count == imported.recordings.count else { throw BackupError.damagedManifest }
        } catch SyncManifestError.newerVersion {
            throw BackupError.newerAppVersion
        } catch {
            throw BackupError.damagedManifest
        }
        try await library.reconcile(context: modelContext)
        try repairLocalPrecedence(modelContext)
        report.oversizedRecordings = library.oversizedCount
        let merged = try apply(inputs: [imported], to: modelContext, report: &report)
        // Decided by id: a recording this device lacks is written to its id; its bytes
        // must match hash and declared size. The archive holds each recording under
        // the name the export gave it (its display name, numbered where names repeat),
        // found again from the imported manifest by the same rule.
        let localIds = Set(try modelContext.fetch(FetchDescriptor<Recording>()).map(\.id))
        let importedById = Dictionary(imported.recordings.map { ($0.id, $0) }) { first, _ in first }
        let exportNames = RecordingBackupManifest.exportNames(imported.recordings)
        let held = try library.held(in: modelContext)
        for entry in merged.recordings where !localIds.contains(entry.id) && !held.contains(projectId: entry.projectId, recordingId: entry.id, displayName: entry.fileName) {
            guard let original = importedById[entry.id], let name = exportNames[entry.id] else { continue }
            guard let audio = files["recordings/\(original.projectId)/\(name)"] else {
                if BackupArchive.isZip(data) { report.damagedRecordings.append(original.fileName) }
                continue
            }
            guard Int64(audio.count) == entry.bytes, Int64(audio.count) <= SyncRecording.maxBytes,
                  RecordingBackupManifest.sha256Hex(audio) == entry.sha256 else {
                report.damagedRecordings.append(entry.fileName)
                continue
            }
            try library.commitRestored(audio, entry: entry, origin: .imported, context: modelContext)
        }
        try await library.reconcile(context: modelContext)
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
        let deletions = try SyncMerger.mergeDeletions(DeletionStore.all(in: modelContext))
        let projectIds = Set(projects.map(\.id) + trashed.map(\.id))
        // Recordings in the recordings Trash stay on this device.
        // One entry per id (rows of one id with other bytes are an A40 conflict the
        // library reports; the first by id order stands here, consistently).
        var seenIds = Set<String>()
        let recordings = try modelContext.fetch(FetchDescriptor<Recording>())
            .filter { projectIds.contains($0.projectId) && $0.trashedAt == nil && $0.bytes > 0 }
            .sorted { ($0.id, $0.sha256) < ($1.id, $1.sha256) }
            .filter { seenIds.insert($0.id).inserted }
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

    /// The current local state gathered with the run's unresolved inputs and resolved
    /// once (A18): the same rule every candidate uses. A rename that conflicts
    /// across devices takes the name from the device holding the bytes.
    private static let firstSeenKey = "backup-first-seen-times"
    /// Covered recordings (id, digest, length, time) whose Drive objects are being removed.
    private static let provenCoveredKey = "backup-proven-covered-recordings"
    /// The proof an earlier build kept (Drive id → version, 40088c1).
    private static let oldProvenCoveredKey = "backup-proven-covered-objects"

    /// A32: an entry without a precedence time (zero or missing) gets the time this
    /// device first saw it, kept here and written to the manifest, never changed.
    private func fixingPrecedence(_ blob: SyncBlob) -> SyncBlob {
        var seen = firstSeenTimes()
        let now = Date().epochMilliseconds
        func time(_ key: String) -> Date {
            if seen[key] == nil { seen[key] = now }
            return Date(millisecondsSince1970: seen[key]!)
        }
        var fixed = blob
        fixed.recordings = blob.recordings.map { entry in
            var entry = entry
            if entry.uploadedAt.epochMilliseconds <= 0 {
                entry.uploadedAt = time("recording:\(entry.id)")
                entry.precedenceRepaired = true
            }
            return entry
        }
        fixed.projects = blob.projects.map { project in
            var project = project
            if project.updatedAt.epochMilliseconds <= 0 {
                project.updatedAt = time("project:\(project.id)")
                project.precedenceRepaired = true
            }
            return project
        }
        fixed.trashed = blob.trashed.map { trash in
            var trash = trash
            if trash.updatedAt.epochMilliseconds <= 0 {
                trash.updatedAt = time("project:\(trash.id)")
                trash.precedenceRepaired = true
            }
            if trash.deletedAt.epochMilliseconds <= 0 {
                trash.deletedAt = time("trashed:\(trash.id)")
                trash.trashedAtRepaired = true
            }
            // The deadline always follows the deletion time (A37).
            trash.deleteAfter = trash.deletedAt.addingTimeInterval(trashRetentionInterval)
            return trash
        }
        defaults.set(seen.mapValues { NSNumber(value: $0) }, forKey: Self.firstSeenKey)
        return fixed
    }

    /// A36: after a manifest is written and verified, each recording held here
    /// takes the display name it carries (metadata only, no file changes) and a
    /// rename made here is marked written. A rename made while the run waited stays.
    private func adoptWrittenNames(_ recordings: [SyncRecording], heldBefore: [String: (String, Bool)], in modelContext: ModelContext) throws {
        let written = Dictionary(recordings.map { ($0.id, $0) }) { first, _ in first }
        // A recording a tombstone without a time holds keeps its name here (T5.24).
        let suspended = try library.held(in: modelContext)
        for row in try modelContext.fetch(FetchDescriptor<Recording>())
        where !suspended.contains(projectId: row.projectId, recordingId: row.id, displayName: row.displayName) {
            guard let entry = written[row.id], entry.sha256 == row.sha256, let before = heldBefore[row.id],
                  before.0 == row.displayName, before.1 == row.displayNameChanged else { continue }
            if row.displayName != entry.fileName { row.displayName = entry.fileName }
            if row.displayNameChanged { row.displayNameChanged = false }
        }
        if modelContext.hasChanges { try modelContext.save() }
    }

    /// Tests: what a reinstall or cleared settings leaves behind.
    func forgetLocalSyncState() {
        defaults.removeObject(forKey: Self.firstSeenKey)
    }

    /// The backup's first-seen times; a damaged record is set aside and reported.
    private func firstSeenTimes() -> [String: Int64] {
        let read = RepairRegistry.read(defaults, key: Self.firstSeenKey)
        if read.damaged { repairStateDamaged = true }
        return read.times
    }

    /// Set when the first-seen record was found damaged (it was set aside); shown by
    /// the view model until the app restarts.
    private(set) var repairStateDamaged = false

    /// A32 on the canonical rows: a song, trashed song or recording without a time
    /// gets the time first seen here, saved on the row (so losing settings cannot
    /// restamp it) before anything is resolved.
    private func repairLocalPrecedence(_ modelContext: ModelContext) throws {
        var seen = firstSeenTimes()
        let now = Date().epochMilliseconds
        func time(_ key: String) -> Date {
            if seen[key] == nil { seen[key] = now }
            return Date(millisecondsSince1970: seen[key]!)
        }
        // A37: each repair is marked, and a Trash deadline follows its repaired time.
        for project in try modelContext.fetch(FetchDescriptor<SongProject>()) where project.updatedAt.epochMilliseconds <= 0 {
            project.updatedAt = time("project:\(project.id)")
            project.precedenceRepaired = true
        }
        for trash in try modelContext.fetch(FetchDescriptor<TrashedSongProject>()) {
            if trash.updatedAt.epochMilliseconds <= 0 {
                trash.updatedAt = time("project:\(trash.id)")
                trash.precedenceRepaired = true
            }
            if trash.deletedAt.epochMilliseconds <= 0 {
                trash.deletedAt = time("trashed:\(trash.id)")
                trash.trashedAtRepaired = true
            }
            // A repaired deletion time always sets the deadline (A37).
            if trash.trashedAtRepaired { trash.deleteAfter = trash.deletedAt.addingTimeInterval(trashRetentionInterval) }
        }
        for row in try modelContext.fetch(FetchDescriptor<Recording>()) {
            // A row from before A20 keeps its recorded time (T3.1).
            if row.uploadedAt == nil, row.recordedAt.epochMilliseconds > 0 { row.uploadedAt = row.recordedAt }
            if row.precedenceTime.epochMilliseconds <= 0 {
                row.uploadedAt = time("recording:\(row.id)")
                row.precedenceRepaired = true
            }
        }
        defaults.set(seen.mapValues { NSNumber(value: $0) }, forKey: Self.firstSeenKey)
        if modelContext.hasChanges { try modelContext.save() }
    }

    private func resolve(_ inputs: [SyncBlob], with modelContext: ModelContext) throws -> SyncBlob {
        // Precedence times are fixed before anything is compared (A32).
        let snapshot = fixingPrecedence(try makeSnapshot(modelContext: modelContext))
        let gathered = try SyncMerger.gather([snapshot] + inputs.map(fixingPrecedence))
        // A36: the display name is metadata. A rename made here and not yet written,
        // or a recording no input lists yet, carries this device's name; otherwise the
        // gathered (Drive's) name stands, and this device takes it after the write.
        // Every row, in the Trash too: a rename made before trashing is still published.
        let rows = try modelContext.fetch(FetchDescriptor<Recording>())
        let held = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
        // The name Drive holds comes from the remote entry itself (the latest input
        // listing it), whichever copy's time won, so tied repairs cannot alternate names.
        var remoteNames: [String: String] = [:]
        for input in inputs { for entry in input.recordings { remoteNames[entry.id] = entry.fileName } }
        // A recording's winning time (A37: a recorded time beats a repair, the smaller
        // repair wins) is kept on its row before any tombstone is compared, so local
        // quarantine and playback judge the same time the backup does.
        let gatheredById = Dictionary(gathered.recordings.map { ($0.id, $0) }) { first, _ in first }
        for row in rows {
            guard let won = gatheredById[row.id], won.sha256 == row.sha256 else { continue }
            if row.precedenceTime != won.uploadedAt { row.uploadedAt = won.uploadedAt }
            if row.precedenceRepaired != won.precedenceRepaired { row.precedenceRepaired = won.precedenceRepaired }
        }
        var resolved = try SyncMerger.resolve(gathered)
        resolved.recordings = resolved.recordings.map { entry in
            var named = entry
            if let row = held[entry.id], row.sha256 == entry.sha256, row.displayNameChanged || remoteNames[entry.id] == nil {
                named.fileName = row.displayName
            } else if let remote = remoteNames[entry.id] {
                named.fileName = remote
            }
            return named
        }.sorted { ($0.projectId, $0.fileName, $0.id) < ($1.projectId, $1.fileName, $1.id) }
        return resolved
    }

    @discardableResult
    private func apply(inputs raw: [SyncBlob], to modelContext: ModelContext, report: inout BackupReport) throws -> SyncBlob {
        // After the network waits: the recordings' last check must still hold, and the
        // tombstones and move record read now, before anything changes (finding 7).
        try library.requireChecked(modelContext)
        // Times are fixed once (A32); resolution and preservation see the same values.
        let inputs = raw.map(fixingPrecedence)
        let blob = try resolve(inputs, with: modelContext)
        try blob.validate()
        // A41: every repaired song this apply removes (held here or in an input) is
        // kept and read back first; a failure stops the run before anything is deleted.
        try preserveRepairedSongLosers(from: [try makeSnapshot(modelContext: modelContext)] + inputs, merged: blob, report: &report)
        let activeById = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<SongProject>()).map { ($0.id, $0) })
        let trashById = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<TrashedSongProject>()).map { ($0.id, $0) })
        let mergedActiveIds = Set(blob.projects.map(\.id))
        let mergedTrashIds = Set(blob.trashed.map(\.id))
        // A kept tombstone of a song edited after it does not remove the song.
        let deletedProjectIds = Set(blob.deletions.filter(\.isSongTombstone).map(\.projectId))
            .subtracting(mergedActiveIds).subtracting(mergedTrashIds)

        for deletion in blob.deletions { try DeletionStore.upsert(deletion, in: modelContext) }
        // A song a tombstone without a time still names (none with a time superseded
        // it above) is left exactly as it is here: not changed, removed or brought back (T5.24).
        let held = try library.held(in: modelContext)
        // Recordings of removed songs get their own tombstones; recordings an incoming
        // tombstone covers lose their rows; both in this save, files after it.
        var removedFiles: [(url: URL, sha256: String, recordingId: String)] = []
        for projectId in deletedProjectIds {
            let deletedAt = blob.deletions.filter { $0.isSongTombstone && $0.projectId == projectId }.map(\.deletedAt).max() ?? 0
            for row in try library.tombstoneRecordings(ofProject: projectId, deletedAt: deletedAt, in: modelContext) {
                if let file = row.fileURL(memosRoot: memosRoot, trashRoot: library.trashRoot) { removedFiles.append((file, row.sha256, row.id)) }
            }
        }
        // A recording a tombstone beats goes, live or trashed, each judged by its own
        // time and repair flag (A41), also one whose song is not here (T2.42); its
        // bytes are kept first: its file to quarantine, or its row's audio written
        // there when no file holds it (T1.44).
        for row in try modelContext.fetch(FetchDescriptor<Recording>()) where !row.isDeleted {
            library.establishTimes(row)
            guard blob.deletions.contains(where: { $0.covers(projectId: row.projectId, recordingId: row.id, sha256: row.sha256, at: row.precedenceTime, repaired: row.precedenceIsRepair) }) else { continue }
            var holds = false
            if let file = row.fileURL(memosRoot: memosRoot, trashRoot: library.trashRoot), try RecordingFiles.exists(file) {
                holds = try RecordingFiles.sha256(of: file) == row.sha256
                if holds { removedFiles.append((file, row.sha256, row.id)) }
            }
            if !holds { try library.preserveRowAudio(row) }
            modelContext.delete(row)
        }
        // A36: rows take the resolved display names (metadata only).
        let resolvedById = Dictionary(blob.recordings.map { ($0.id, $0) }) { first, _ in first }
        for row in try modelContext.fetch(FetchDescriptor<Recording>())
        where !row.isDeleted && !held.contains(projectId: row.projectId, recordingId: row.id, displayName: row.displayName) {
            // A rename made here is the resolved name; its mark is cleared only once a
            // verified manifest carries it. A held recording keeps its name (T5.24).
            guard let entry = resolvedById[row.id], entry.sha256 == row.sha256, !row.displayNameChanged else { continue }
            if row.displayName != entry.fileName { row.displayName = entry.fileName }
        }

        for project in blob.projects where !held.songs.contains(project.id) {
            if let existing = activeById[project.id] {
                existing.title = project.title
                existing.lyrics = project.lyrics
                existing.theme = project.theme
                existing.updatedAt = project.updatedAt
                existing.precedenceRepaired = project.precedenceRepaired
            } else {
                modelContext.insert(project.makeModel())
            }
            if let staleTrash = trashById[project.id] {
                modelContext.delete(staleTrash)
            }
        }

        for trash in blob.trashed where !held.songs.contains(trash.id) {
            if let existing = trashById[trash.id] {
                existing.title = trash.title
                existing.lyrics = trash.lyrics
                existing.theme = trash.theme
                existing.updatedAt = trash.updatedAt
                existing.deletedAt = trash.deletedAt
                existing.deleteAfter = trash.deleteAfter
                existing.precedenceRepaired = trash.precedenceRepaired
                existing.trashedAtRepaired = trash.trashedAtRepaired
            } else {
                modelContext.insert(trash.makeModel())
            }
            if let staleProject = activeById[trash.id] {
                modelContext.delete(staleProject)
            }
        }

        for (id, project) in activeById where mergedTrashIds.contains(id) && !mergedActiveIds.contains(id) && !held.songs.contains(id) {
            modelContext.delete(project)
        }
        for (id, trash) in trashById where mergedActiveIds.contains(id) && !mergedTrashIds.contains(id) && !held.songs.contains(id) {
            modelContext.delete(trash)
        }
        for (id, project) in activeById where deletedProjectIds.contains(id) {
            modelContext.delete(project)
        }
        for (id, trash) in trashById where deletedProjectIds.contains(id) {
            modelContext.delete(trash)
        }
        // Deleted recordings leave the memo folders and the Trash for quarantine,
        // recorded before this save and finished after it (A28).
        try library.saveRecordingMoves(quarantine: removedFiles, in: modelContext) { try modelContext.save() }
        return blob
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

/// Songs a tombstone removes while their own time is a repair (A41) are kept here,
/// one verified JSON file per song content, before they leave the store or Drive.
nonisolated enum SongRecoveryStore {
    struct Song: Codable, Equatable {
        var project: SyncSongProject?
        var trashed: SyncTrashedSongProject?

        var id: String { project?.id ?? trashed?.id ?? "" }
        var title: String { project?.title ?? trashed?.title ?? id }
    }

    static func root(for memosRoot: URL) -> URL {
        memosRoot.deletingLastPathComponent().appendingPathComponent("song-recovery", isDirectory: true)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// Written once per content (a repeat finds it), never over another file, and read
    /// back: the decoded song, repair flags included, must equal what was kept.
    static func keep(_ song: Song, memosRoot: URL) throws {
        // Times are kept to the millisecond, as written.
        var song = song
        func ms(_ date: Date) -> Date { Date(millisecondsSince1970: date.epochMilliseconds) }
        if var project = song.project {
            project.updatedAt = ms(project.updatedAt)
            song.project = project
        }
        if var trashed = song.trashed {
            trashed.updatedAt = ms(trashed.updatedAt)
            trashed.deletedAt = ms(trashed.deletedAt)
            trashed.deleteAfter = ms(trashed.deleteAfter)
            song.trashed = trashed
        }
        let data = try encoder.encode(song)
        let folder = root(for: memosRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(song.id)-\(RecordingBackupManifest.sha256Hex(data).prefix(16)).json")
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .withoutOverwriting) }
        guard try decoder.decode(Song.self, from: Data(contentsOf: file)) == song else { throw SyncValidationError.invalidVersionShape }
    }

    static func all(memosRoot: URL) throws -> [Song] {
        let folder = root(for: memosRoot)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try decoder.decode(Song.self, from: Data(contentsOf: $0)) }
    }
}
