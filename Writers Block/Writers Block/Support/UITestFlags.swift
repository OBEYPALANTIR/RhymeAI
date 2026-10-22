import Foundation

enum UITestFlags {
    static let inMemoryStore = "--ui-test-in-memory-store"
    static let seedProsodySong = "--ui-test-seed-prosody-song"
    static let enableStressPreview = "--ui-test-enable-stress-preview"
    static let openAssistant = "--ui-test-open-assistant"
    static let seedRewriteSelection = "--ui-test-seed-rewrite-selection"
    static let seedRewriteLoading = "--ui-test-seed-rewrite-loading"
    static let seedTrashSong = "--ui-test-seed-trash-song"
    static let forceRewriteBar = "--ui-test-force-rewrite-bar"
    static let fakeVoiceRecording = "--ui-test-fake-voice-recording"
    static let seedSuggestions = "--ui-test-seed-suggestions"
    static let forceSaveFailed = "--ui-test-force-save-failed"
    static let seedLongTitleSong = "--ui-test-seed-long-title-song"
    static let accessibilityTextSize = "--ui-test-accessibility-text-size"
    static let seedCustomGGUFModel = "--ui-test-seed-custom-gguf-model"
    /// Suggest Next Line answers from `scriptedSuggestionStream` instead of a
    /// provider, on the on-device route, so the Assistant's real loading and
    /// arrival states can be held and replayed with no key, request or model.
    /// It only takes effect alongside `inMemoryStore`.
    static let scriptedSuggestions = "--ui-test-scripted-suggestions"
    /// Google Drive backup talks to an in-memory Drive and a fake sign-in, with
    /// backup state in a suite of its own that each launch starts empty.
    static let fakeDrive = "--ui-test-fake-drive"
    /// With `fakeDrive`: start signed in.
    static let fakeDriveConnected = "--ui-test-fake-drive-connected"
    /// With `fakeDrive`: the Drive holds a v4 backup of two songs and two recordings.
    static let fakeDriveSeeded = "--ui-test-fake-drive-seeded"

    #if DEBUG
    static func isEnabled(_ flag: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(flag)
    }

    /// Suite that holds the editor's settings during an in-memory UI-test launch.
    static let isolatedEditorDefaultsSuite = "RhymeAI.UITest.EditorDefaults"

    /// Where the editor keeps its settings. An in-memory UI-test launch keeps
    /// the editor's provider, model, sharing-consent and editor-toggle
    /// settings (and its legacy API-key migration) in a suite of its own, so a
    /// test run does not read or rewrite those in the standard domain. The rest
    /// of launch is not isolated: retired-preference cleanup, appearance, model
    /// downloads and backup still use the standard domain and system keychain,
    /// so run UI tests under a separate bundle ID or on a disposable simulator.
    static func editorDefaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard isEnabled(inMemoryStore, in: arguments) else { return .standard }
        return UserDefaults(suiteName: isolatedEditorDefaultsSuite) ?? .standard
    }

    /// The scripted stream answers only in an isolated launch, with the
    /// in-memory store and the editor's own defaults suite.
    static func scriptedSuggestionsEnabled(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        isEnabled(scriptedSuggestions, in: arguments) && isEnabled(inMemoryStore, in: arguments)
    }

    /// Lines the scripted stream delivers, of mixed length; the fourth runs
    /// long enough to wrap, so a card landing on two lines is covered.
    static let scriptedSuggestionLines = [
        "A quiet light carries me home",
        "The porch still hums the songs we used to know",
        "I count the streetlights back to you",
        "Every window on this road has learned the shape of your name and keeps it lit past midnight",
        "So the quiet doesn't feel the same",
        "And the radio plays on",
    ]

    /// A deterministic stand-in for the suggestion stream: it holds the request
    /// in its loading state, then yields lines on a fixed schedule. Timing comes
    /// from the launch environment: `RHYMEAI_UITEST_SUGGESTION_HOLD` (seconds
    /// before the first line, default 3), `RHYMEAI_UITEST_SUGGESTION_INTERVAL`
    /// (seconds between lines, default 1) and `RHYMEAI_UITEST_SUGGESTION_COUNT`
    /// (0 to 6 lines, default 5; 0 exercises the empty-answer path).
    static func scriptedSuggestionStream(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AsyncThrowingStream<String, Error> {
        let hold = max(0, Double(environment["RHYMEAI_UITEST_SUGGESTION_HOLD"] ?? "") ?? 3)
        let interval = max(0, Double(environment["RHYMEAI_UITEST_SUGGESTION_INTERVAL"] ?? "") ?? 1)
        let requested = Int(environment["RHYMEAI_UITEST_SUGGESTION_COUNT"] ?? "") ?? 5
        let lines = Array(scriptedSuggestionLines.prefix(min(max(0, requested), scriptedSuggestionLines.count)))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .seconds(hold))
                    for (index, line) in lines.enumerated() {
                        if index > 0 { try await Task.sleep(for: .seconds(interval)) }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func makeFakeDriveBackupService() -> BackupService {
        let suite = "RhymeAI.UITest.Backup"
        UserDefaults().removePersistentDomain(forName: suite)
        let drive = InMemoryDriveAppDataClient()
        if isEnabled(fakeDriveSeeded) {
            let takes = [("drive-song-1", "first take.m4a", Data([1, 2, 3, 4])), ("drive-song-2", "second take.m4a", Data([5, 6, 7]))]
            let seeded = SyncBlob(
                projects: [
                    SyncSongProject(id: "drive-song-1", title: "Drive Song One", lyrics: "Found it in the cloud", theme: "", updatedAt: Date(timeIntervalSince1970: 1_761_000_000)),
                    SyncSongProject(id: "drive-song-2", title: "Drive Song Two", lyrics: "Back where it belongs", theme: "", updatedAt: Date(timeIntervalSince1970: 1_761_000_100)),
                ],
                recordings: takes.map { SyncRecording(id: "take-\($0.0)", projectId: $0.0, fileName: $0.1, bytes: Int64($0.2.count), sha256: RecordingBackupManifest.sha256Hex($0.2), uploadedAt: Date(timeIntervalSince1970: 1_761_000_150)) },
                savedAt: Date(timeIntervalSince1970: 1_761_000_200),
                savedByClientId: "ui-test-seed",
                platform: "android"
            )
            if let manifest = try? seeded.encodedManifest() {
                drive.seed(name: SyncBlob.driveFileName, content: manifest)
            }
            for (projectId, fileName, audio) in takes {
                drive.seed(name: RecordingBackupManifest.driveName(recordingId: "take-\(projectId)"), content: audio,
                           appProperties: ["id": "take-\(projectId)", "projectId": projectId, "fileName": fileName, "sha256": RecordingBackupManifest.sha256Hex(audio), "bytes": String(audio.count)])
            }
        }
        return BackupService(
            driveClient: drive,
            oauthProvider: FakeOAuthProvider(connected: isEnabled(fakeDriveConnected)),
            secretStore: InMemoryBackupSecretStore(),
            defaults: UserDefaults(suiteName: suite) ?? .standard,
            memosRoot: RecordingFiles.memosRoot()
        )
    }

    static func seedCustomGGUFModelIfRequested() {
        guard isEnabled(seedCustomGGUFModel),
              let directory = try? GGUFModelStorage.modelsDirectory(create: true) else { return }
        let model = GGUFCustomModel(
            id: "ui-test-custom-model",
            displayName: "Night Drive QA",
            fileName: "ui-test-custom-model.gguf"
        )
        let modelURL = directory.appendingPathComponent(model.fileName)
        let header = Data([
            0x47, 0x47, 0x55, 0x46,
            0x03, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        try? header.write(to: modelURL, options: .atomic)
        GGUFCustomModelRegistry.register(model)
    }
    #else
    static func isEnabled(_ flag: String, in arguments: [String] = []) -> Bool {
        false
    }

    static func editorDefaults() -> UserDefaults {
        .standard
    }

    static func scriptedSuggestionsEnabled() -> Bool {
        false
    }

    static func seedCustomGGUFModelIfRequested() {}
    #endif
}

#if DEBUG
/// The UI tests' Google Drive: appDataFolder files in memory.
final class InMemoryDriveAppDataClient: DriveAppDataClient {
    private var files: [String: (file: DriveAppDataFile, content: Data)] = [:]

    func seed(name: String, content: Data, appProperties: [String: String]? = nil) {
        files[name] = (DriveAppDataFile(id: UUID().uuidString, name: name, version: UUID().uuidString, appProperties: appProperties), content)
    }

    func findFile(named name: String, accessToken: String) async throws -> DriveAppDataFile? { files[name]?.file }

    func listFiles(prefix: String, accessToken: String) async throws -> [DriveAppDataFile] {
        files.values.map(\.file).filter { $0.name.hasPrefix(prefix) }
    }

    func downloadFile(id: String, accessToken: String) async throws -> Data {
        guard let stored = files.values.first(where: { $0.file.id == id }) else { throw BackupError.noRemoteBackup }
        return stored.content
    }

    func uploadNewFile(named name: String, mimeType: String, content: Data, appProperties: [String: String]?, accessToken: String) async throws -> DriveAppDataFile {
        seed(name: name, content: content, appProperties: appProperties)
        return files[name]!.file
    }

    func updateFile(id: String, mimeType: String, content: Data, appProperties: [String: String]?, accessToken: String) async throws -> DriveAppDataFile {
        guard let name = files.first(where: { $0.value.file.id == id })?.key else { throw BackupError.invalidResponse }
        let file = DriveAppDataFile(id: id, name: name, version: UUID().uuidString, appProperties: appProperties ?? files[name]?.file.appProperties)
        files[name] = (file, content)
        return file
    }

    func deleteFile(id: String, accessToken: String) async throws {
        files = files.filter { $0.value.file.id != id }
    }
}

/// Signs in without a browser: an interactive request connects.
final class FakeOAuthProvider: OAuthAccessTokenProvider {
    private var connected: Bool
    init(connected: Bool) { self.connected = connected }

    var isConfigured: Bool { true }
    var hasRefreshToken: Bool { connected }

    func accessToken(interactive: Bool) async throws -> String {
        if !connected, interactive { connected = true }
        guard connected else { throw BackupError.authorizationRequired }
        return "ui-test-token"
    }

    func revokeAndForget() async -> Bool {
        connected = false
        return true
    }
}

final class InMemoryBackupSecretStore: BackupSecretStore {
    private var values: [String: String] = [:]
    func string(for key: String) -> String? { values[key] }
    func setString(_ value: String, for key: String) { values[key] = value }
    func deleteString(for key: String) { values.removeValue(forKey: key) }
}
#endif
