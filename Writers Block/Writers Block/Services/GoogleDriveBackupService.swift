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
    case quotaExceeded
    case serverError(String)
    case invalidRequest
    case invalidResponse
    case corruptRemoteOrWrongPassphrase
    case newerAppVersion
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
        case .missingPassphrase:
            return "Enter your backup passphrase before using Google Drive backup."
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
        case .corruptRemoteOrWrongPassphrase:
            return "Your Drive backup could not be decrypted or read. Check your passphrase; it was not overwritten."
        case .newerAppVersion:
            return "This backup was written by a newer version of Writers Block. Update the app before syncing."
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
}

protocol DriveAppDataClient: AnyObject {
    func findFile(named name: String, accessToken: String) async throws -> DriveAppDataFile?
    func listFiles(prefix: String, accessToken: String) async throws -> [DriveAppDataFile]
    func downloadFile(id: String, accessToken: String) async throws -> Data
    func uploadNewFile(named name: String, mimeType: String, content: Data, accessToken: String) async throws -> DriveAppDataFile
    func updateFile(id: String, mimeType: String, content: Data, accessToken: String) async throws
    func deleteFile(id: String, accessToken: String) async throws
}

protocol OAuthAccessTokenProvider: AnyObject {
    var isConfigured: Bool { get }
    var hasRefreshToken: Bool { get }
    func accessToken(interactive: Bool) async throws -> String
}

final class RealDriveAppDataClient: DriveAppDataClient {
    private let session: URLSession
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

    func uploadNewFile(named name: String, mimeType: String, content: Data, accessToken: String) async throws -> DriveAppDataFile {
        let metadata = DriveUploadMetadata(name: name, parents: ["appDataFolder"], mimeType: mimeType)
        let body = try multipartBody(metadata: metadata, mimeType: mimeType, content: content)
        guard var components = URLComponents(
            url: try Self.uploadBaseURL().appendingPathComponent("files"),
            resolvingAgainstBaseURL: false
        ) else {
            throw BackupError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id,name,modifiedTime,version")
        ]
        var request = try request(from: components)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let responseData = try await data(for: request)
        do {
            return try JSONDecoder().decode(DriveFileResponse.self, from: responseData).file
        } catch {
            throw BackupError.invalidResponse
        }
    }

    func updateFile(id: String, mimeType: String, content: Data, accessToken: String) async throws {
        let metadata = DrivePatchMetadata(mimeType: mimeType)
        let body = try multipartBody(metadata: metadata, mimeType: mimeType, content: content)
        guard var components = URLComponents(
            url: try Self.uploadBaseURL().appendingPathComponent("files/\(id)"),
            resolvingAgainstBaseURL: false
        ) else {
            throw BackupError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id,name,modifiedTime,version")
        ]
        var request = try request(from: components)
        request.httpMethod = "PATCH"
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        _ = try await data(for: request)
    }

    func deleteFile(id: String, accessToken: String) async throws {
        var request = URLRequest(url: try Self.driveBaseURL().appendingPathComponent("files/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        _ = try await data(for: request)
    }

    private func listFiles(query: String, accessToken: String) async throws -> [DriveAppDataFile] {
        guard var components = URLComponents(
            url: try Self.driveBaseURL().appendingPathComponent("files"),
            resolvingAgainstBaseURL: false
        ) else {
            throw BackupError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "fields", value: "files(id,name,modifiedTime,version)"),
            URLQueryItem(name: "q", value: query)
        ]
        var request = try request(from: components)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let responseData = try await data(for: request)
        do {
            return try JSONDecoder().decode(DriveFilesResponse.self, from: responseData).files
        } catch {
            throw BackupError.invalidResponse
        }
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
                let body = String(data: data, encoding: .utf8) ?? ""
                throw Self.httpError(statusCode: http.statusCode, body: body)
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

private struct DriveFilesResponse: Decodable { var files: [DriveAppDataFile] }
private struct DriveFileResponse: Decodable {
    var id: String
    var name: String
    var modifiedTime: String?
    var version: String?

    var file: DriveAppDataFile {
        DriveAppDataFile(id: id, name: name, modifiedTime: modifiedTime, version: version)
    }
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

@MainActor
final class BackupService {
    static let shared = BackupService()

    private static let passphraseKey = "drive-sync-passphrase"
    private static let clientIdKey = "drive-sync-client-id"

    private static let backgroundFailureKey = "drive-sync-last-background-failure"
    private let driveClient: DriveAppDataClient
    private let oauthProvider: OAuthAccessTokenProvider
    private let secretStore: BackupSecretStore
    private let defaults: UserDefaults
    private let memosRoot: URL
    private typealias LocalRecording = (entry: SyncRecordingManifestEntry, localURL: URL)

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
    var backgroundBackupFailureDescription: String? {
        defaults.string(forKey: Self.backgroundFailureKey)?.nilIfBlank
    }

    func updatePassphrase(_ passphrase: String) throws {
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            secretStore.deleteString(for: Self.passphraseKey)
        } else {
            try secretStore.setString(trimmed, for: Self.passphraseKey)
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
            clearBackgroundBackupFailure()
        } catch {
            recordBackgroundBackupFailure(error)
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
        var localSnapshot = try makeSnapshot(modelContext: modelContext)
        let sourceRemoteFile = try await driveClient.findFile(named: SyncBlob.driveFileName, accessToken: accessToken)
        var sourceRemoteBlob: SyncBlob?
        var merged = finalizedBlob(try canonicalized(localSnapshot.blob))

        if let sourceRemoteFile {
            let remoteBlob = try await downloadRemoteBlob(sourceRemoteFile, accessToken: accessToken, passphrase: passphrase)
            sourceRemoteBlob = remoteBlob
            merged = finalizedBlob(try SyncMerger.merge(local: localSnapshot.blob, remote: remoteBlob))
        }

        var localRecordings = try localRecordingMap(projectIds: localSnapshot.allProjectIds)
        try await uploadLocalRecordings(
            for: merged.recordings,
            localRecordings: localRecordings,
            remoteBlob: sourceRemoteBlob,
            accessToken: accessToken,
            passphrase: passphrase
        )

        let latestRemoteFile = try await driveClient.findFile(named: SyncBlob.driveFileName, accessToken: accessToken)
        if remoteMetadataChanged(original: sourceRemoteFile, latest: latestRemoteFile) {
            localSnapshot = try makeSnapshot(modelContext: modelContext)
            if let latestRemoteFile {
                let latestRemoteBlob = try await downloadRemoteBlob(latestRemoteFile, accessToken: accessToken, passphrase: passphrase)
                merged = finalizedBlob(try SyncMerger.merge(local: merged, remote: latestRemoteBlob))
                try await uploadLocalRecordings(
                    for: merged.recordings,
                    localRecordings: localRecordings,
                    remoteBlob: latestRemoteBlob,
                    accessToken: accessToken,
                    passphrase: passphrase
                )
            } else {
                merged = finalizedBlob(localSnapshot.blob)
                localRecordings = try localRecordingMap(projectIds: localSnapshot.allProjectIds)
                try await uploadLocalRecordings(
                    for: merged.recordings,
                    localRecordings: localRecordings,
                    remoteBlob: nil,
                    accessToken: accessToken,
                    passphrase: passphrase
                )
            }
        }

        localSnapshot = try makeSnapshot(modelContext: modelContext)
        merged = finalizedBlob(try SyncMerger.merge(local: localSnapshot.blob, remote: merged))
        localRecordings = try localRecordingMap(projectIds: localSnapshot.allProjectIds)
        try await uploadLocalRecordings(
            for: merged.recordings,
            localRecordings: localRecordings,
            remoteBlob: merged,
            accessToken: accessToken,
            passphrase: passphrase
        )
        try await uploadManifest(merged, accessToken: accessToken, passphrase: passphrase)
        try apply(merged, to: modelContext)
        try await deleteRemoteRecordingsCoveredByDeletions(
            merged.deletions,
            accessToken: accessToken
        )
        try deleteLocalRecordingsCoveredByDeletions(merged.deletions)
        try await restoreRecordings(from: merged.recordings, accessToken: accessToken, passphrase: passphrase)
        clearBackgroundBackupFailure()
    }

    private func restore(modelContext: ModelContext, accessToken: String, passphrase: String) async throws {
        guard let remoteFile = try await driveClient.findFile(named: SyncBlob.driveFileName, accessToken: accessToken) else {
            throw BackupError.noRemoteBackup
        }
        let remoteBlob = try await downloadRemoteBlob(remoteFile, accessToken: accessToken, passphrase: passphrase)
        var localSnapshot = try makeSnapshot(modelContext: modelContext)
        var merged = finalizedBlob(try SyncMerger.merge(local: localSnapshot.blob, remote: remoteBlob))
        var localRecordings = try localRecordingMap(projectIds: localSnapshot.allProjectIds)
        try await uploadLocalRecordings(
            for: merged.recordings,
            localRecordings: localRecordings,
            remoteBlob: remoteBlob,
            accessToken: accessToken,
            passphrase: passphrase
        )
        localSnapshot = try makeSnapshot(modelContext: modelContext)
        merged = finalizedBlob(try SyncMerger.merge(local: localSnapshot.blob, remote: merged))
        localRecordings = try localRecordingMap(projectIds: localSnapshot.allProjectIds)
        try await uploadLocalRecordings(
            for: merged.recordings,
            localRecordings: localRecordings,
            remoteBlob: merged,
            accessToken: accessToken,
            passphrase: passphrase
        )
        try await uploadManifest(merged, accessToken: accessToken, passphrase: passphrase)
        try apply(merged, to: modelContext)
        try await deleteRemoteRecordingsCoveredByDeletions(
            merged.deletions,
            accessToken: accessToken
        )
        try deleteLocalRecordingsCoveredByDeletions(merged.deletions)
        try await restoreRecordings(from: merged.recordings, accessToken: accessToken, passphrase: passphrase)
        clearBackgroundBackupFailure()
    }

    private func upsertDriveFile(name: String, mimeType: String, content: Data, accessToken: String) async throws -> DriveAppDataFile {
        if let existing = try await driveClient.findFile(named: name, accessToken: accessToken) {
            try await driveClient.updateFile(id: existing.id, mimeType: mimeType, content: content, accessToken: accessToken)
            return try await driveClient.findFile(named: name, accessToken: accessToken) ?? existing
        }
        return try await driveClient.uploadNewFile(named: name, mimeType: mimeType, content: content, accessToken: accessToken)
    }

    private func downloadRemoteBlob(_ file: DriveAppDataFile, accessToken: String, passphrase: String) async throws -> SyncBlob {
        let encrypted = try await driveClient.downloadFile(id: file.id, accessToken: accessToken)
        do {
            return try SyncBlobCrypto.openManifest(encrypted, passphrase: passphrase)
        } catch SyncBlobCryptoError.unsupportedEnvelopeVersion {
            throw BackupError.newerAppVersion
        } catch SyncValidationError.unsupportedVersion {
            throw BackupError.newerAppVersion
        } catch {
            throw BackupError.corruptRemoteOrWrongPassphrase
        }
    }

    private func uploadManifest(_ blob: SyncBlob, accessToken: String, passphrase: String) async throws {
        let encrypted = try SyncBlobCrypto.sealManifest(blob, passphrase: passphrase)
        _ = try await upsertDriveFile(name: SyncBlob.driveFileName, mimeType: SyncBlob.driveMimeType, content: encrypted, accessToken: accessToken)
    }

    private func finalizedBlob(_ blob: SyncBlob) -> SyncBlob {
        var finalized = blob
        finalized.savedAt = Date()
        finalized.savedByClientId = clientId
        return finalized
    }

    private func canonicalized(_ blob: SyncBlob) throws -> SyncBlob {
        try SyncMerger.merge(
            local: blob,
            remote: SyncBlob(savedAt: .distantPast, savedByClientId: "")
        )
    }

    private func remoteMetadataChanged(original: DriveAppDataFile?, latest: DriveAppDataFile?) -> Bool {
        switch (original, latest) {
        case (.none, .none):
            return false
        case (.none, .some), (.some, .none):
            return true
        case let (.some(original), .some(latest)):
            return original.id != latest.id
                || original.version != latest.version
                || original.modifiedTime != latest.modifiedTime
        }
    }

    private func localRecordingMap(projectIds: [String]) throws -> [String: LocalRecording] {
        var recordings: [String: LocalRecording] = [:]
        for recording in try RecordingBackupManifest.scan(projectIds: projectIds, memosRoot: memosRoot) {
            let key = recordingKey(recording.entry)
            if let existing = recordings[key],
               Self.epochMilliseconds(existing.entry.modifiedAt) > Self.epochMilliseconds(recording.entry.modifiedAt) {
                continue
            }
            recordings[key] = recording
        }
        return recordings
    }

    private func uploadLocalRecordings(
        for mergedRecordings: [SyncRecordingManifestEntry],
        localRecordings: [String: LocalRecording],
        remoteBlob: SyncBlob?,
        accessToken: String,
        passphrase: String
    ) async throws {
        for entry in mergedRecordings {
            let key = recordingKey(entry)
            guard let local = localRecordings[key],
                  recordingManifest(local.entry, matches: entry),
                  try await shouldUploadLocalRecording(local.entry, remoteBlob: remoteBlob, accessToken: accessToken) else {
                continue
            }
            let encrypted = try SyncBlobCrypto.seal(Data(contentsOf: local.localURL), passphrase: passphrase)
            _ = try await upsertDriveFile(name: local.entry.driveName, mimeType: "application/octet-stream", content: encrypted, accessToken: accessToken)
        }
    }

    private func shouldUploadLocalRecording(_ local: SyncRecordingManifestEntry, remoteBlob: SyncBlob?, accessToken: String) async throws -> Bool {
        let remoteEntry = remoteBlob?.recordings.first(where: { recordingKey($0) == recordingKey(local) })
        guard let remoteEntry else { return true }
        let localMillis = Self.epochMilliseconds(local.modifiedAt)
        let remoteMillis = Self.epochMilliseconds(remoteEntry.modifiedAt)
        if localMillis < remoteMillis { return false }
        if localMillis > remoteMillis { return true }
        guard local.sha256 == remoteEntry.sha256,
              local.sizeBytes == remoteEntry.sizeBytes,
              local.driveName == remoteEntry.driveName else {
            return true
        }
        return try await driveClient.findFile(named: local.driveName, accessToken: accessToken) == nil
    }

    private func recordingManifest(_ lhs: SyncRecordingManifestEntry, matches rhs: SyncRecordingManifestEntry) -> Bool {
        lhs.projectId == rhs.projectId
            && lhs.fileName == rhs.fileName
            && lhs.driveName == rhs.driveName
            && lhs.sizeBytes == rhs.sizeBytes
            && Self.epochMilliseconds(lhs.modifiedAt) == Self.epochMilliseconds(rhs.modifiedAt)
            && lhs.sha256 == rhs.sha256
    }

    private func recordingKey(_ entry: SyncRecordingManifestEntry) -> String {
        "\(entry.projectId)/\(entry.fileName)"
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

    private func makeSnapshot(modelContext: ModelContext) throws -> BackupSnapshot {
        let projects = try modelContext.fetch(FetchDescriptor<SongProject>())
        let trashed = try modelContext.fetch(FetchDescriptor<TrashedSongProject>())
        let deletionRecords = try modelContext.fetch(FetchDescriptor<SyncDeletionRecord>())
        let deletions = try SyncMerger.mergeDeletions(deletionRecords.map(\.deletion))
        let projectIds = Set(projects.map(\.id) + trashed.map(\.id))
        let recordings = try RecordingBackupManifest.scan(projectIds: Array(projectIds), memosRoot: memosRoot).map(\.entry)
        let blob = SyncBlob(
            projects: projects.map(SyncSongProject.init(project:)),
            trashed: trashed.map(SyncTrashedSongProject.init(trashed:)),
            recordings: recordings,
            deletions: deletions,
            savedAt: Date(),
            savedByClientId: clientId
        )
        return BackupSnapshot(blob: blob, allProjectIds: Array(projectIds))
    }

    private func apply(_ blob: SyncBlob, to modelContext: ModelContext) throws {
        let latestLocal = try makeSnapshot(modelContext: modelContext).blob
        let blob = try SyncMerger.merge(local: latestLocal, remote: blob)
        try blob.validate()
        let activeById = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<SongProject>()).map { ($0.id, $0) })
        let trashById = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<TrashedSongProject>()).map { ($0.id, $0) })
        let existingDeletionRecords = try modelContext.fetch(FetchDescriptor<SyncDeletionRecord>())
        let mergedActiveIds = Set(blob.projects.map(\.id))
        let mergedTrashIds = Set(blob.trashed.map(\.id))
        let deletedProjectIds = Set(blob.deletions.filter { $0.fileName == nil }.map(\.projectId))

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

    private func deleteRemoteRecordingsCoveredByDeletions(
        _ deletions: [SyncDeletion],
        accessToken: String
    ) async throws {
        let deletedProjects = Set(deletions.filter { $0.fileName == nil }.map(\.projectId))
        for projectId in deletedProjects.sorted() {
            try SyncIdentity.validateProjectId(projectId)
            let prefix = "rec_\(projectId)_"
            for file in try await driveClient.listFiles(prefix: prefix, accessToken: accessToken) {
                try await driveClient.deleteFile(id: file.id, accessToken: accessToken)
            }
        }
        for deletion in deletions {
            guard let fileName = deletion.fileName,
                  !deletedProjects.contains(deletion.projectId) else { continue }
            try deletion.validate()
            let driveName = RecordingBackupManifest.driveName(
                projectId: deletion.projectId,
                fileName: fileName
            )
            if let file = try await driveClient.findFile(named: driveName, accessToken: accessToken) {
                try await driveClient.deleteFile(id: file.id, accessToken: accessToken)
            }
        }
    }

    private func deleteLocalRecordingsCoveredByDeletions(_ deletions: [SyncDeletion]) throws {
        let deletedProjects = Set(deletions.filter { $0.fileName == nil }.map(\.projectId))
        for projectId in deletedProjects {
            let live = try RecordingBackupManifest.projectURL(projectId: projectId, memosRoot: memosRoot)
            let trash = try RecordingBackupManifest.projectURL(projectId: projectId, memosRoot: VoiceMemoService.memosTrashRoot())
            if FileManager.default.fileExists(atPath: live.path) { try FileManager.default.removeItem(at: live) }
            if FileManager.default.fileExists(atPath: trash.path) { try FileManager.default.removeItem(at: trash) }
        }
        for deletion in deletions {
            guard let fileName = deletion.fileName, !deletedProjects.contains(deletion.projectId) else { continue }
            let live = try RecordingBackupManifest.localURL(projectId: deletion.projectId, fileName: fileName, memosRoot: memosRoot)
            if FileManager.default.fileExists(atPath: live.path) { try FileManager.default.removeItem(at: live) }
            for trashed in VoiceMemoService.trashedMemos() where trashed.projectId == deletion.projectId && trashed.originalName == fileName {
                if FileManager.default.fileExists(atPath: trashed.url.path) { try FileManager.default.removeItem(at: trashed.url) }
            }
        }
    }

    private static func isDeleted(_ entry: SyncRecordingManifestEntry, by deletions: [SyncDeletion]) -> Bool {
        deletions.contains {
            $0.projectId == entry.projectId && ($0.fileName == nil || $0.fileName == entry.fileName)
        }
    }

    private func restoreRecordings(from recordings: [SyncRecordingManifestEntry], accessToken: String, passphrase: String) async throws {
        for entry in recordings {
            try entry.validate()
            let folder = try RecordingBackupManifest.projectURL(projectId: entry.projectId, memosRoot: memosRoot)
            let target = try RecordingBackupManifest.localURL(projectId: entry.projectId, fileName: entry.fileName, memosRoot: memosRoot)
            let shouldRestore = try shouldRestoreRecording(entry: entry, localURL: target)
            guard shouldRestore else { continue }
            guard let remote = try await driveClient.findFile(named: entry.driveName, accessToken: accessToken) else { continue }
            let encrypted = try await driveClient.downloadFile(id: remote.id, accessToken: accessToken)
            let plaintext: Data
            do {
                plaintext = try SyncBlobCrypto.open(encrypted, passphrase: passphrase)
            } catch {
                throw BackupError.corruptRemoteOrWrongPassphrase
            }
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
