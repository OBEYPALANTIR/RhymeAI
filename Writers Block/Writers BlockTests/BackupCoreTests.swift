import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Writers_Block

struct BackupCoreTests {
    private let passphrase = SyncRepairContractChecks.passphrase
    private let plaintext = SyncRepairContractChecks.v1
    private let goldenEnvelopeBase64 = SyncRepairContractChecks.golden
    /// A take on Drive for "song-a"; downloading it is the first request after the manifest write.
    static let lateTake: (entry: SyncRecording, audio: Data) = {
        let audio = Data([0x5a, 0x5b, 0x5c])
        return (SyncRecording(projectId: "song-a", fileName: "late.m4a", bytes: 3, sha256: RecordingBackupManifest.sha256Hex(audio)), audio)
    }()

    // MARK: Older encrypted backups stay readable

    @Test func opensAndroidCompatibleRAI1Fixture() async throws {
        let envelope = try #require(Data(base64Encoded: goldenEnvelopeBase64))

        let opened = try SyncBlobCrypto.open(envelope, passphrase: passphrase)

        #expect(opened == plaintext)
    }

    @Test func rai1GoldenVectorMatchesTheFixedKeyDerivation() async throws {
        let envelope = try SyncRepairContractChecks.rawEnvelope(plaintext, magic: "RAI1")

        #expect(envelope.base64EncodedString() == goldenEnvelopeBase64)
    }

    @Test func wrongPassphraseAndTamperFailClosed() async throws {
        let envelope = try #require(Data(base64Encoded: goldenEnvelopeBase64))
        #expect(throws: SyncBlobCryptoError.self) {
            _ = try SyncBlobCrypto.open(envelope, passphrase: "wrong passphrase")
        }

        var tampered = envelope
        tampered[tampered.count - 1] ^= 0xff
        #expect(throws: SyncBlobCryptoError.self) {
            _ = try SyncBlobCrypto.open(tampered, passphrase: passphrase)
        }
    }

    @Test func nonAsciiPassphraseIsRejectedBeforeDerivation() async throws {
        let envelope = try #require(Data(base64Encoded: goldenEnvelopeBase64))
        #expect(throws: SyncBlobCryptoError.nonPortablePassphrase) {
            _ = try SyncBlobCrypto.open(envelope, passphrase: "café")
        }
    }

    // MARK: Google sign-in

    @MainActor
    @Test func oauthWithoutClientIdThrowsNotConfigured() async throws {
        let service = GoogleDriveOAuthService(
            configuration: .init(clientID: nil, redirectScheme: nil),
            tokenStore: InMemoryOAuthTokenStore()
        )

        await #expect(throws: BackupError.notConfigured) {
            _ = try await service.accessToken(interactive: false)
        }
    }

    @Test func oauthCallbackRequiresMatchingState() async throws {
        let valid = try #require(URL(string: "com.example:/oauth2redirect/google?code=test-code&state=expected"))
        let mismatched = try #require(URL(string: "com.example:/oauth2redirect/google?code=test-code&state=other"))
        let missing = try #require(URL(string: "com.example:/oauth2redirect/google?code=test-code"))

        #expect(try GoogleDriveOAuthService.authorizationCode(from: valid, expectedState: "expected") == "test-code")
        #expect(throws: BackupError.invalidResponse) {
            _ = try GoogleDriveOAuthService.authorizationCode(from: mismatched, expectedState: "expected")
        }
        #expect(throws: BackupError.invalidResponse) {
            _ = try GoogleDriveOAuthService.authorizationCode(from: missing, expectedState: "expected")
        }
    }

    @MainActor
    @Test(arguments: [200, 503])
    func disconnectRevokesTheRefreshTokenAndAlwaysForgetsIt(_ status: Int) async throws {
        let store = InMemoryOAuthTokenStore(token: OAuthToken(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: .distantFuture))
        let stub: RevokeStub.Type = status == 200 ? RevokeAccepted.self : RevokeUnavailable.self
        stub.log.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [stub]
        let service = GoogleDriveOAuthService(
            configuration: .init(clientID: "client", redirectScheme: "com.example"),
            tokenStore: store,
            session: URLSession(configuration: configuration)
        )

        let revoked = await service.revokeAndForget()

        #expect(revoked == (status == 200))
        #expect(store.loadToken() == nil)
        #expect(!service.hasRefreshToken)
        #expect(stub.log.requests.count == 1)
        let request = try #require(stub.log.requests.first)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(request.httpMethod == "POST")
        #expect(stub.log.bodies.first == "token=refresh-1")
    }

    @MainActor
    @Test func disconnectClearsBackupStateAndStopsBackups() async throws {
        let oauth = FakeOAuthProvider()
        let harness = try await makeHarness(oauthProvider: oauth)
        try await harness.service.backupNow(modelContext: harness.context)
        #expect(harness.service.lastBackupAt != nil)

        let revoked = await harness.service.disconnect()

        #expect(revoked)
        #expect(oauth.revokeCalls == 1)
        #expect(!harness.service.isConnected)
        #expect(harness.service.lastBackupAt == nil)
        #expect(harness.service.backgroundBackupFailureDescription == nil)
        let uploads = harness.drive.uploadCount
        await harness.service.backupInBackgroundIfPossible(modelContext: harness.context)
        #expect(harness.drive.uploadCount == uploads)
    }

    @MainActor
    @Test func backgroundBackupFailureIsPersistedForRefresh() async throws {
        let oauthProvider = FakeOAuthProvider()
        oauthProvider.accessTokenError = BackupError.network("offline")
        let harness = try await makeHarness(oauthProvider: oauthProvider)

        await harness.service.backupInBackgroundIfPossible(modelContext: harness.context)

        #expect(harness.service.backgroundBackupFailureDescription == "offline")
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        #expect(viewModel.backupStatus == .failed(reason: "offline", lastBackupAt: nil))
    }

    // MARK: v4 backup and restore

    @MainActor
    @Test func backupUploadsRawRecordingsAndAHashedManifestWithoutAPIKeys() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "project-1", title: "Hook", lyrics: "secret lyric", theme: "dark",
                                           updatedAt: Date(timeIntervalSince1970: 1_700_000_010)))
        try harness.context.save()
        let memoData = Data([0, 1, 2, 3, 4, 5])
        try await harness.writeMemo(memoData, projectId: "project-1", fileName: "take 1.m4a")

        try await harness.service.backupNow(modelContext: harness.context)

        let manifestData = try #require(harness.drive.content(named: "rhymeai-manifest.json"))
        let manifest = try SyncBlob.decodeManifest(manifestData)
        #expect(manifest.projects.map(\.id) == ["project-1"])
        #expect(manifest.platform == "ios")
        let id = try harness.rowId("take 1.m4a")
        #expect(manifest.recordings.map { [$0.id, $0.projectId, $0.fileName, String($0.bytes), $0.sha256] } == [[id, "project-1", "take 1.m4a", "6", RecordingBackupManifest.sha256Hex(memoData)]])
        #expect(abs(try #require(manifest.recordings.first).uploadedAt.timeIntervalSinceNow) < 60)
        let text = try #require(String(data: manifestData, encoding: .utf8))
        #expect(!text.contains("apiKey"))
        #expect(text.contains(#""manifestSha256":"\#(manifest.manifestSha256)""#))

        #expect(harness.drive.content(named: "rec_\(id)") == memoData)
        #expect(harness.drive.appProperties(named: "rec_\(id)") == [
            "id": id, "projectId": "project-1", "fileName": "take 1.m4a", "sha256": RecordingBackupManifest.sha256Hex(memoData), "bytes": "6",
        ])
        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).map(\.key) == ["project-1/take 1.m4a"])
        #expect(harness.service.lastBackupAt != nil)
    }

    @MainActor
    @Test func backupSkipsUnchangedRecordingsOnTheNextRun() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "project-1", title: "Hook"))
        try harness.context.save()
        try await harness.writeMemo(Data([1, 2]), projectId: "project-1", fileName: "take.m4a")

        try await harness.service.backupNow(modelContext: harness.context)
        let name = "rec_\(try harness.rowId("take.m4a"))"
        let recordingUploads = harness.drive.uploads(named: name)
        try await harness.service.backupNow(modelContext: harness.context)

        #expect(recordingUploads == 1)
        #expect(harness.drive.uploads(named: name) == 1)
    }

    @MainActor
    @Test func oversizedRecordingsStayLocalAndAreCounted() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "project-1", title: "Hook"))
        try harness.context.save()
        try await harness.writeMemo(Data(count: Int(SyncRecording.maxBytes) + 1), projectId: "project-1", fileName: "long.m4a")

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.recordings.isEmpty)
        #expect(harness.drive.content(named: "rec_project-1_long.m4a") == nil)
        #expect(harness.service.lastReport?.oversizedRecordings == 1)
        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).isEmpty)
    }

    @MainActor
    @Test func backupMergesExistingRemoteManifestBeforeUploading() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "local-project", title: "Local Hook", lyrics: "local lyric", theme: "dark",
                                           updatedAt: Date(timeIntervalSince1970: 1_700_000_040)))
        try harness.context.save()
        let remote = SyncBlob(
            projects: [SyncSongProject(id: "remote-project", title: "Remote Verse", lyrics: "remote lyric", theme: "blue",
                                       updatedAt: Date(timeIntervalSince1970: 1_700_000_041))],
            savedAt: Date(timeIntervalSince1970: 1_700_000_042),
            savedByClientId: "remote-client",
            platform: "android"
        )
        harness.drive.seed(name: SyncBlob.driveFileName, content: try remote.encodedManifest())

        try await harness.service.backupNow(modelContext: harness.context)

        let uploaded = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(Set(uploaded.projects.map(\.id)) == Set(["local-project", "remote-project"]))
        // Back up never changes this device: the remote song arrives only on restore.
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["local-project"])
    }

    @MainActor
    @Test func hashMismatchedRemoteManifestIsRefusedAndLeftInPlace() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "local-project", title: "Local"))
        try harness.context.save()
        let remote = SyncBlob(projects: [SyncSongProject(id: "remote", title: "Remote", lyrics: "line", theme: "", updatedAt: Date(timeIntervalSince1970: 1))])
        let tampered = Data(String(decoding: try remote.encodedManifest(), as: UTF8.self)
            .replacingOccurrences(of: #""lyrics":"line""#, with: #""lyrics":"lime""#).utf8)
        harness.drive.seed(name: SyncBlob.driveFileName, content: tampered)

        await #expect(throws: BackupError.damagedManifest) {
            try await harness.service.backupNow(modelContext: harness.context)
        }
        #expect(BackupError.damagedManifest.errorDescription == "Backup file is damaged; it was not merged.")
        #expect(harness.drive.content(named: SyncBlob.driveFileName) == tampered)
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["local-project"])
        #expect(harness.service.backgroundBackupFailureDescription == "Backup file is damaged; it was not merged.")
    }

    @MainActor
    @Test func manifestFromANewerVersionIsRefused() async throws {
        let harness = try await makeHarness()
        guard case .object(var fields) = SyncBlob().jsonValue else { Issue.record("not an object"); return }
        fields["version"] = .int(5)
        fields["manifestSha256"] = .string(CanonicalJSON.sha256Hex(.object(fields)))
        harness.drive.seed(name: SyncBlob.driveFileName, content: Data(CanonicalJSON.string(.object(fields)).utf8))

        await #expect(throws: BackupError.newerAppVersion) {
            try await harness.service.backupNow(modelContext: harness.context)
        }
    }

    @MainActor
    @Test func backupReMergesOnceWhenRemoteManifestMetadataChangesBeforeUpload() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "local-project", title: "Local Hook", lyrics: "local lyric", theme: "dark",
                                           updatedAt: Date(timeIntervalSince1970: 1_700_000_060)))
        try harness.context.save()
        let initial = SyncBlob(projects: [SyncSongProject(id: "initial-remote-project", title: "Initial Remote", lyrics: "a", theme: "",
                                                          updatedAt: Date(timeIntervalSince1970: 1_700_000_061))])
        let late = SyncBlob(projects: [SyncSongProject(id: "late-remote-project", title: "Late Remote", lyrics: "b", theme: "",
                                                       updatedAt: Date(timeIntervalSince1970: 1_700_000_063))])
        harness.drive.seed(name: SyncBlob.driveFileName, content: try initial.encodedManifest())
        harness.drive.concurrentWrites = [try SyncMerger.merge(local: initial, remote: late).encodedManifest()]

        try await harness.service.backupNow(modelContext: harness.context)

        let uploaded = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(Set(uploaded.projects.map(\.id)) == Set(["local-project", "initial-remote-project", "late-remote-project"]))
    }

    @MainActor
    @Test func restoreDownloadsMissingRecordingsIntoTheLibrary() async throws {
        let harness = try await makeHarness()
        let remoteMemo = Data([9, 8, 7, 6])
        let entry = SyncRecording(projectId: "project-2", fileName: "demo.m4a", bytes: 4, sha256: RecordingBackupManifest.sha256Hex(remoteMemo))
        let blob = SyncBlob(
            projects: [SyncSongProject(id: "project-2", title: "Restored", lyrics: "Lyrics", theme: "blue", updatedAt: Date(timeIntervalSince1970: 1_700_000_019))],
            recordings: [entry]
        )
        harness.drive.seed(name: SyncBlob.driveFileName, content: try blob.encodedManifest())
        harness.drive.seed(name: entry.driveName, content: remoteMemo)

        try await harness.service.restoreNow(modelContext: harness.context)

        let restoredURL = harness.file(entry.id, "project-2")
        #expect(try Data(contentsOf: restoredURL) == remoteMemo)
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["project-2"])
        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).map { [$0.id, $0.key, $0.sha256, $0.origin] } == [[entry.id, "project-2/demo.m4a", entry.sha256, "restored"]])
        #expect(harness.service.lastReport?.damagedRecordings == [])
    }

    @MainActor
    @Test func restoreDiscardsMismatchedAudioAndNeverOverwritesALocalFile() async throws {
        let harness = try await makeHarness()
        let local = Data([1, 1, 1])
        try harness.writeFile(local, projectId: "project-3", fileName: "mine.m4a")
        let remoteMine = Data([2, 2, 2])
        let corrupt = Data([3, 3, 3])
        let mine = SyncRecording(projectId: "project-3", fileName: "mine.m4a", bytes: 3, sha256: RecordingBackupManifest.sha256Hex(remoteMine))
        let broken = SyncRecording(projectId: "project-3", fileName: "broken.m4a", bytes: 3, sha256: RecordingBackupManifest.sha256Hex(Data([4, 4, 4])))
        let blob = SyncBlob(
            projects: [SyncSongProject(id: "project-3", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1))],
            recordings: [mine, broken]
        )
        harness.drive.seed(name: SyncBlob.driveFileName, content: try blob.encodedManifest())
        harness.drive.seed(name: mine.driveName, content: remoteMine)
        harness.drive.seed(name: broken.driveName, content: corrupt)

        await #expect(throws: BackupError.damagedRemoteRecordings(["broken.m4a"])) {
            try await harness.service.restoreNow(modelContext: harness.context)
        }

        // The Drive recording is another recording that shares the name: both are
        // kept under their ids, with one display name; the damaged one is not.
        #expect(harness.audios("project-3") == [remoteMine, local])
        #expect(try Data(contentsOf: harness.file(mine.id, "project-3")) == remoteMine)
        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).map(\.displayName) == ["mine.m4a", "mine.m4a"])
        #expect(harness.service.lastReport?.damagedRecordings == ["broken.m4a"])
        #expect(harness.service.lastBackupAt == nil)
    }

    @MainActor
    @Test func twoRecordingsSharingANameAreBothKept() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        try harness.context.save()
        let local = Data([1, 2, 3])
        let drive = Data([9, 9])
        try await harness.writeMemo(local, projectId: "song", fileName: "take.m4a")
        let entry = SyncRecording(projectId: "song", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(drive))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(recordings: [entry]).encodedManifest())
        harness.drive.seedRecording(entry, content: drive)

        try await harness.service.backupNow(modelContext: harness.context)
        try await harness.service.restoreNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        let rows = try harness.context.fetch(FetchDescriptor<Recording>())
        #expect(Set(manifest.recordings.map(\.id)) == Set(rows.map(\.id)) && rows.count == 2 && rows.contains { $0.id == entry.id })
        #expect(manifest.recordings.map(\.fileName) == ["take.m4a", "take.m4a"] && rows.allSatisfy { $0.displayName == "take.m4a" })
        #expect(harness.drive.content(named: entry.driveName) == drive)
        #expect(try Data(contentsOf: harness.file(entry.id, "song")) == drive)
        #expect(harness.audios("song") == [drive, local])
    }

    @MainActor
    @Test func restoreWithoutAnyBackupSaysSo() async throws {
        let harness = try await makeHarness()

        await #expect(throws: BackupError.noRemoteBackup) {
            try await harness.service.restoreNow(modelContext: harness.context)
        }
    }

    @MainActor
    @Test func restorePushesLocalOnlyRecordingsAndMergedManifestBackToDrive() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "local-project", title: "Local Hook", lyrics: "local lyric", theme: "dark",
                                           updatedAt: Date(timeIntervalSince1970: 1_700_000_070)))
        try harness.context.save()
        let memoData = Data([4, 3, 2, 1])
        try await harness.writeMemo(memoData, projectId: "local-project", fileName: "restore-push.m4a")
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(savedAt: Date(timeIntervalSince1970: 1)).encodedManifest())

        try await harness.service.restoreNow(modelContext: harness.context)

        let pushed = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(pushed.projects.map(\.id) == ["local-project"])
        let id = try harness.rowId("restore-push.m4a")
        #expect(pushed.recordings.map(\.driveName) == ["rec_\(id)"])
        #expect(harness.drive.content(named: "rec_\(id)") == memoData)
    }

    @MainActor
    @Test func restorePublishesPermanentDeletionBeforeRemovingRemoteContent() async throws {
        let harness = try await makeHarness()
        let remoteMemo = Data([7, 7, 7])
        let entry = SyncRecording(projectId: "gone", fileName: "take.m4a", bytes: 3, sha256: RecordingBackupManifest.sha256Hex(remoteMemo))
        let staleRemote = SyncBlob(
            projects: [SyncSongProject(id: "gone", title: "Stale", lyrics: "stale lyric", theme: "", updatedAt: Date(timeIntervalSince1970: 2_000_000_000))],
            recordings: [entry],
            savedAt: Date(timeIntervalSince1970: 2_000_000_000),
            savedByClientId: "stale-peer"
        )
        harness.context.insert(SyncDeletionRecord(projectId: "gone", deletedAt: 4_000_000_000_000))
        try harness.context.save()
        harness.drive.seed(name: SyncBlob.driveFileName, content: try staleRemote.encodedManifest())
        harness.drive.seedRecording(entry, content: remoteMemo)

        try await harness.service.restoreNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.isEmpty)
        #expect(manifest.recordings.isEmpty)
        // The song's recording gets its own tombstone by id.
        let tombstones = [SyncDeletion(projectId: "gone", deletedAt: 4_000_000_000_000),
                          SyncDeletion(projectId: "gone", recordingId: entry.id, fileName: "take.m4a", deletedAt: 4_000_000_000_000)]
        #expect(manifest.deletions == tombstones)
        #expect(harness.drive.content(named: entry.driveName) == nil)
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).isEmpty)
        #expect(try DeletionStore.all(in: harness.context).count == 2)
    }

    @MainActor
    @Test func backupCanonicalizesTombstonesWithoutAnExistingRemoteManifest() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "gone", title: "Stale", lyrics: "must stay deleted", updatedAt: Date(timeIntervalSince1970: 100)))
        harness.context.insert(SyncDeletionRecord(projectId: "gone", deletedAt: 200_000))
        try harness.context.save()

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.isEmpty)
        #expect(manifest.trashed.isEmpty)
        #expect(manifest.recordings.isEmpty)
        #expect(manifest.deletions == [SyncDeletion(projectId: "gone", deletedAt: 200_000)])
    }

    @MainActor
    @Test func failedRemoteRecordingCleanupRetriesFromDurableProjectTombstone() async throws {
        let harness = try await makeHarness()
        let entry = SyncRecording(projectId: "gone", fileName: "take.m4a", bytes: 3, sha256: RecordingBackupManifest.sha256Hex(Data([1, 2, 3])))
        let remote = SyncBlob(
            projects: [SyncSongProject(id: "gone", title: "Stale", lyrics: "stale", theme: "", updatedAt: Date(timeIntervalSince1970: 100))],
            recordings: [entry],
            savedAt: Date(timeIntervalSince1970: 100),
            savedByClientId: "stale-peer"
        )
        harness.context.insert(SyncDeletionRecord(projectId: "gone", deletedAt: 4_000_000_000_000))
        try harness.context.save()
        harness.drive.seed(name: SyncBlob.driveFileName, content: try remote.encodedManifest())
        harness.drive.seedRecording(entry, content: Data([1, 2, 3]))
        harness.drive.failNextDelete(named: entry.driveName)

        await #expect(throws: BackupError.self) {
            try await harness.service.restoreNow(modelContext: harness.context)
        }
        #expect(harness.drive.content(named: entry.driveName) != nil)

        try await harness.service.restoreNow(modelContext: harness.context)

        #expect(harness.drive.content(named: entry.driveName) == nil)
        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.deletions == [SyncDeletion(projectId: "gone", deletedAt: 4_000_000_000_000),
                                       SyncDeletion(projectId: "gone", recordingId: entry.id, fileName: "take.m4a", deletedAt: 4_000_000_000_000)])
        #expect(manifest.recordings.isEmpty)
    }

    @MainActor
    @Test func networkWaitCannotOverwriteNewerPersistedWritingAtApply() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "draft", title: "Draft", lyrics: "before network wait", updatedAt: Date(timeIntervalSince1970: 100))
        harness.context.insert(project)
        try harness.context.save()
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(savedAt: Date(timeIntervalSince1970: 1)).encodedManifest())
        harness.drive.beforeManifestWrite = {
            project.lyrics = "edited while upload waited"
            project.updatedAt = Date(timeIntervalSince1970: 200)
            try harness.context.save()
        }

        try await harness.service.restoreNow(modelContext: harness.context)

        let stored = try #require(harness.context.fetch(FetchDescriptor<SongProject>()).first)
        #expect(stored.lyrics == "edited while upload waited")
        #expect(stored.updatedAt == Date(timeIntervalSince1970: 200))
    }

    @MainActor
    @Test func networkWaitCannotResurrectAConcurrentPermanentDeletion() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "draft", title: "Draft", lyrics: "delete while upload waits", updatedAt: Date(timeIntervalSince1970: 100)))
        try harness.context.save()
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(savedAt: Date(timeIntervalSince1970: 1)).encodedManifest())
        harness.drive.beforeManifestWrite = {
            harness.context.insert(SyncDeletionRecord(projectId: "draft", deletedAt: 200_000))
            try harness.context.save()
        }

        try await harness.service.restoreNow(modelContext: harness.context)

        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.projectId) == ["draft"])
    }

    // MARK: Recordings stay out of the backup until finished, and must be on Drive

    @MainActor
    @Test func aBackupDuringRecordingWaitsForTheFinishedAudio() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song"))
        try harness.context.save()
        // The recorder writes outside the memo folder until it finishes (A22).
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("in-progress-\(UUID().uuidString)/take.m4a")
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2]).write(to: staged)
        try await harness.service.library.reconcile(context: harness.context)

        try await harness.service.backupNow(modelContext: harness.context)
        #expect(try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName))).recordings.isEmpty)

        let finished = Data([1, 2, 3, 4, 5])
        try finished.write(to: staged)
        harness.service.library.context = harness.context
        _ = try harness.service.library.publishFinished(staged, projectId: "song", preferredName: "take.m4a", origin: .recorded)
        try await harness.service.backupNow(modelContext: harness.context)

        let row = try #require(harness.context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.audio == finished && row.origin == "recorded")
        #expect(harness.drive.content(named: "rec_\(row.id)") == finished)
        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.recordings.map(\.id) == [row.id])
    }

    @MainActor
    @Test func aBackupNeverChangesLocalFilesOrRows() async throws {
        let harness = try await makeHarness()
        try harness.writeFile(Data([3]), projectId: "song", fileName: "unseen.m4a")

        try await harness.service.backupNow(modelContext: harness.context)

        // The library has not picked the file up yet, and a backup does not either.
        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.memosRoot.appendingPathComponent("song").path) == ["unseen.m4a"])
    }

    @MainActor
    @Test func audioListedButMissingOnDriveFailsTheBackupAndIsNamedByRestore() async throws {
        let harness = try await makeHarness()
        let entry = SyncRecording(projectId: "song", fileName: "lost.m4a", bytes: 3, sha256: RecordingBackupManifest.sha256Hex(Data([1, 2, 3])))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            projects: [SyncSongProject(id: "song", title: "Song", lyrics: "words", theme: "", updatedAt: Date(timeIntervalSince1970: 1))],
            recordings: [entry]
        ).encodedManifest())

        await #expect(throws: BackupError.missingRemoteRecordings(["lost.m4a"])) {
            try await harness.service.backupNow(modelContext: harness.context)
        }
        await #expect(throws: BackupError.missingRemoteRecordings(["lost.m4a"])) {
            try await harness.service.restoreNow(modelContext: harness.context)
        }
        // The songs still arrive; the run is not recorded as a complete success.
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["song"])
        #expect(harness.service.lastBackupAt == nil)
        #expect(harness.service.backgroundBackupFailureDescription == "1 recording in the backup has no audio on Google Drive: lost.m4a")
    }

    @MainActor
    @Test func restoredAudioKeepsItsUploadTimeSoALaterTombstoneStillWins() async throws {
        let harness = try await makeHarness()
        let audio = Data([6, 6, 6])
        let entry = SyncRecording(projectId: "song", fileName: "old.m4a", bytes: 3, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 1_000))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 9_000))],
            recordings: [entry]
        ).encodedManifest())
        harness.drive.seed(name: entry.driveName, content: audio, appProperties: ["sha256": entry.sha256, "bytes": "3"])

        try await harness.service.restoreNow(modelContext: harness.context)
        let row = try #require(harness.context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.uploadedAt == Date(timeIntervalSince1970: 1_000))

        harness.context.insert(SyncRecordingDeletion(projectId: "song", recordingId: entry.id, fileName: "old.m4a", deletedAt: 5_000_000))
        try harness.context.save()
        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.recordings.isEmpty)
        #expect(manifest.projects.map(\.id) == ["song"])
    }

    @MainActor
    @Test func importedAudioKeepsItsTimeThroughExportSoAnOlderTombstoneElsewhereStillWins() async throws {
        let deviceA = try await makeHarness()
        let audio = Data([4, 5])
        let take = SyncRecording(projectId: "S", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 1_000))
        let zip = try BackupArchive.zip([
            ("manifest.json", try SyncBlob(projects: [SyncSongProject(id: "S", title: "S", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 9_000))], recordings: [take]).encodedManifest()),
            ("recordings/S/take.m4a", audio),
        ])
        try await deviceA.service.importArchive(zip, modelContext: deviceA.context)
        let row = try #require(deviceA.context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.uploadedAt == Date(timeIntervalSince1970: 1_000) && row.origin == "imported")

        let exported = try deviceA.service.exportArchive(modelContext: deviceA.context, now: Date())
        let exportedManifest = try SyncBlob.decodeManifest(try #require(BackupArchive.unzip(exported.data)["manifest.json"]))
        #expect(exportedManifest.recordings.map(\.uploadedAt) == [Date(timeIntervalSince1970: 1_000)])

        let deviceB = try await makeHarness()
        deviceB.context.insert(SyncDeletionRecord(projectId: "S", deletedAt: 5_000_000))
        try deviceB.context.save()
        try await deviceB.service.importArchive(exported.data, modelContext: deviceB.context)

        #expect(try deviceB.context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["S"])
        #expect(deviceB.audios("S").isEmpty)
    }

    @MainActor
    @Test func aTrashOnlyTakeGetsItsOwnTombstoneSoARevivalCannotBringItBack() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "S", title: "S", updatedAt: Date(timeIntervalSince1970: 500)))
        try harness.context.save()
        // A take from 1000 s, then moved to the recordings Trash.
        let library = harness.service.library
        library.context = harness.context
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).m4a")
        try Data([1, 1]).write(to: staged)
        let live = try library.publishFinished(staged, projectId: "S", preferredName: "take.m4a", origin: .recorded)
        let row = try #require(harness.context.fetch(FetchDescriptor<Recording>()).first)
        row.uploadedAt = Date(timeIntervalSince1970: 1_000)
        try harness.context.save()
        let trashed = try library.trashRecording(at: live, trashedAt: Date(timeIntervalSince1970: 1_500)).url
        let takeId = row.id
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(deletions: [SyncDeletion(projectId: "S", deletedAt: 5_000_000)]).encodedManifest())

        try await harness.service.restoreNow(modelContext: harness.context)
        #expect(!FileManager.default.fileExists(atPath: trashed.path))
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).isEmpty)
        let protection = SyncDeletion(projectId: "S", recordingId: takeId, fileName: "take.m4a", deletedAt: 5_000_000)
        #expect(try DeletionStore.all(in: harness.context).contains(protection))

        // The song comes back newer; a device that was offline still holds the take.
        harness.context.insert(SongProject(id: "S", title: "S", lyrics: "revived", updatedAt: Date(timeIntervalSince1970: 9_000)))
        try harness.context.save()
        let offline = SyncRecording(id: takeId, projectId: "S", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(Data([1, 1])), uploadedAt: Date(timeIntervalSince1970: 1_000))
        harness.drive.concurrentWrites = [try SyncBlob(projects: [SyncSongProject(id: "S", title: "S", lyrics: "old", theme: "", updatedAt: Date(timeIntervalSince1970: 500))], recordings: [offline]).encodedManifest()]
        harness.drive.seedRecording(offline, content: Data([1, 1]))
        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.map(\.lyrics) == ["revived"])
        #expect(manifest.recordings.isEmpty)
        #expect(manifest.deletions == [protection])
    }

    @MainActor
    @Test func aTombstoneWrittenWhileAudioUploadsJoinsBeforeTheManifestIsCommitted() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "S", title: "S", updatedAt: Date(timeIntervalSince1970: 100)))
        try harness.context.save()
        try await harness.writeMemo(Data([1, 2]), projectId: "S", fileName: "take.m4a")
        harness.drive.duringRecordingUpload = {
            harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(deletions: [SyncDeletion(projectId: "S", deletedAt: Date().epochMilliseconds + 60_000)]).encodedManifest())
        }

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.isEmpty)
        #expect(manifest.recordings.isEmpty)
        #expect(manifest.deletions.contains { $0.isSongTombstone && $0.projectId == "S" })
        #expect(manifest.deletions.contains { $0.recordingId == (try? harness.rowId("take.m4a")) })
    }

    @MainActor
    @Test func missingDriveAudioFailsRestoreEvenWhenALocalFileHasItsName() async throws {
        let harness = try await makeHarness()
        try await harness.writeMemo(Data([7]), projectId: "song", fileName: "take.m4a")
        let entry = SyncRecording(projectId: "song", fileName: "take.m4a", bytes: 1, sha256: RecordingBackupManifest.sha256Hex(Data([8])))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1))],
            recordings: [entry]
        ).encodedManifest())

        await #expect(throws: BackupError.missingRemoteRecordings(["take.m4a"])) {
            try await harness.service.restoreNow(modelContext: harness.context)
        }
        #expect(harness.service.lastBackupAt == nil)
        #expect(harness.service.backgroundBackupFailureDescription != nil)
    }

    @MainActor
    @Test func fractionalSecondsDecideAgainstATombstone() async throws {
        let take = SyncRecording(projectId: "song", fileName: "take.m4a", bytes: 1, sha256: RecordingBackupManifest.sha256Hex(Data([1])),
                                 uploadedAt: Date(millisecondsSince1970: 1_000_400))
        let roundTripped = try SyncBlob.decodeManifest(try SyncBlob(recordings: [take]).encodedManifest()).recordings
        #expect(roundTripped.map(\.uploadedAt.epochMilliseconds) == [1_000_400])
        let after = try SyncMerger.merge(local: SyncBlob(recordings: roundTripped), remote: SyncBlob(deletions: [SyncDeletion(projectId: "song", recordingId: take.id, fileName: "take.m4a", deletedAt: 1_000_401)]))
        let before = try SyncMerger.merge(local: SyncBlob(recordings: roundTripped), remote: SyncBlob(deletions: [SyncDeletion(projectId: "song", recordingId: take.id, fileName: "take.m4a", deletedAt: 1_000_399)]))
        #expect(after.recordings.isEmpty)
        #expect(before.recordings.map(\.id) == [take.id])
    }

    @MainActor
    @Test func aDeletionMadeHereDuringARestoreWinsWhenItIsNewer() async throws {
        let harness = try await makeHarness()
        let audio = Data([5])
        let entry = SyncRecording(projectId: "song", fileName: "take.m4a", bytes: 1, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 1_000))
        let later = SyncRecording(projectId: "song", fileName: "later.m4a", bytes: 1, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 1_000))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 2_000))],
            recordings: [entry, later]
        ).encodedManifest())
        harness.drive.seedRecording(entry, content: audio)
        harness.drive.seedRecording(later, content: audio)
        // While the first download is in flight, the writer deletes both here: one
        // tombstone newer than the backup's copy, one older.
        harness.drive.afterManifestWrite = {
            harness.context.insert(SyncRecordingDeletion(projectId: "song", recordingId: entry.id, fileName: "take.m4a", deletedAt: 1_500_000))
            harness.context.insert(SyncRecordingDeletion(projectId: "song", recordingId: later.id, fileName: "later.m4a", deletedAt: 500_000))
            try harness.context.save()
        }

        try await harness.service.restoreNow(modelContext: harness.context)

        #expect(!FileManager.default.fileExists(atPath: harness.file(entry.id, "song").path))
        #expect(FileManager.default.fileExists(atPath: harness.file(later.id, "song").path))
    }

    @MainActor
    @Test func everyOldRecordingGoesUpRawEvenWhenATombstoneKeepsItOutOfTheManifest() async throws {
        let harness = try await makeHarness()
        harness.secrets.setString(passphrase, for: "drive-sync-passphrase")
        let oldAudio = Data([3, 3])
        try harness.seedLegacyBackup(audio: oldAudio)
        harness.context.insert(SyncDeletionRecord(projectId: "old-song", deletedAt: 4_000_000_000_000))
        try harness.context.save()

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.recordings.isEmpty && manifest.projects.isEmpty)
        let raw = try #require(manifest.deletions.first { $0.recordingId != nil }?.recordingId)
        #expect(harness.drive.content(named: "rec_\(raw)") == oldAudio)
        #expect(harness.service.lastReport?.migratedLegacyBackup == true)
        #expect(harness.drive.content(named: "rhymeai-projects.json") == nil)
    }

    @MainActor
    @Test func aNameNotChangedHereTakesTheManifestsName() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        try harness.context.save()
        try await harness.writeMemo(Data([4, 4]), projectId: "song", fileName: "renamed here.m4a")
        let id = try harness.rowId("renamed here.m4a")
        let elsewhere = SyncRecording(id: id, projectId: "song", fileName: "renamed elsewhere.m4a", bytes: 2,
                                      sha256: RecordingBackupManifest.sha256Hex(Data([4, 4])), uploadedAt: Date(timeIntervalSince1970: 1_000))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(recordings: [elsewhere]).encodedManifest())
        harness.drive.seedRecording(elsewhere, content: Data([4, 4]))

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        // Not renamed on this device: Drive's name stands, and this device takes it
        // as metadata; its file keeps its id.
        #expect(manifest.recordings.map(\.fileName) == ["renamed elsewhere.m4a"])
        #expect(manifest.recordings.map(\.uploadedAt) == [Date(timeIntervalSince1970: 1_000)], "the backed-up copy keeps its time")
        #expect(try harness.rowId("renamed elsewhere.m4a") == id)
        #expect(FileManager.default.fileExists(atPath: harness.file(id, "song").path))
    }

    // MARK: Lost updates between devices

    @MainActor
    @Test func everyWriteSeenAcrossRetriesSurvives() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "L", title: "L", updatedAt: Date(timeIntervalSince1970: 10)))
        try harness.context.save()
        func song(_ id: String) -> SyncSongProject { SyncSongProject(id: id, title: id, lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 20)) }
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(projects: [song("R")]).encodedManifest())
        harness.drive.concurrentWrites = [try SyncBlob(projects: [song("T")]).encodedManifest(), try SyncBlob(projects: [song("U")]).encodedManifest()]

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.map(\.id) == ["L", "R", "T", "U"])
    }

    @MainActor
    @Test func aSongEditedAfterAConcurrentTombstoneSurvivesButItsOlderAudioDoesNot() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "S", title: "S", lyrics: "edited", updatedAt: Date(timeIntervalSince1970: 9_000)))
        try harness.context.save()
        let audio = Data([1, 2, 3])
        let take = SyncRecording(projectId: "S", fileName: "take.m4a", bytes: 3, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 1_000))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            projects: [SyncSongProject(id: "S", title: "S", lyrics: "old", theme: "", updatedAt: Date(timeIntervalSince1970: 500))],
            recordings: [take]
        ).encodedManifest())
        harness.drive.seed(name: take.driveName, content: audio, appProperties: ["sha256": take.sha256, "bytes": "3"])
        harness.drive.concurrentWrites = [try SyncBlob(deletions: [SyncDeletion(projectId: "S", deletedAt: 5_000_000)]).encodedManifest()]

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.map(\.lyrics) == ["edited"])
        #expect(manifest.recordings.isEmpty)
        // The outlived song tombstone goes; the take keeps its own tombstone by id.
        #expect(manifest.deletions == [SyncDeletion(projectId: "S", recordingId: take.id, fileName: "take.m4a", deletedAt: 5_000_000)])
    }

    @MainActor
    @Test func importRevivesANewerSongOverALocalDeletionButNotItsOlderAudio() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SyncDeletionRecord(projectId: "S", deletedAt: 5_000_000))
        try harness.context.save()
        let audio = Data([4, 5])
        let take = SyncRecording(projectId: "S", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 1_000))
        let manifest = try SyncBlob(
            projects: [SyncSongProject(id: "S", title: "S", lyrics: "newer", theme: "", updatedAt: Date(timeIntervalSince1970: 9_000))],
            recordings: [take]
        ).encodedManifest()
        let zip = try BackupArchive.zip([("manifest.json", manifest), ("recordings/S/take.m4a", audio)])

        try await harness.service.importArchive(zip, modelContext: harness.context)

        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.lyrics) == ["newer"])
        #expect(harness.audios("S").isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).isEmpty)
    }


    @MainActor
    @Test func aManifestWrittenByAnotherDeviceMeanwhileIsMergedAndRewritten() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "mine", title: "Mine", updatedAt: Date(timeIntervalSince1970: 10)))
        try harness.context.save()
        let before = SyncBlob(projects: [SyncSongProject(id: "remote", title: "Remote", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 5))])
        harness.drive.seed(name: SyncBlob.driveFileName, content: try before.encodedManifest())
        // The intervening write knows nothing of the earlier remote song.
        let theirs = SyncBlob(projects: [SyncSongProject(id: "theirs", title: "Theirs", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 20))])
        harness.drive.concurrentWrites = [try theirs.encodedManifest()]

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(Set(manifest.projects.map(\.id)) == Set(["remote", "mine", "theirs"]))
        #expect(harness.drive.uploads(named: SyncBlob.driveFileName) == 2)
    }

    @MainActor
    @Test func writesThatNeverReadBackGiveUpAfterThreeAttempts() async throws {
        let harness = try await makeHarness()
        harness.drive.concurrentWrites = try (1...12).map { index in
            try SyncBlob(projects: [SyncSongProject(id: "other-\(index)", title: "", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: Double(index)))]).encodedManifest()
        }

        await #expect(throws: BackupError.backupConflict) {
            try await harness.service.backupNow(modelContext: harness.context)
        }
        #expect((1...3).contains(harness.drive.uploads(named: SyncBlob.driveFileName)))
        #expect(BackupError.backupConflict.errorDescription == "Backup conflict, will retry.")
    }

    @MainActor
    @Test func aDeletionArrivingDuringTheSecondUploadIsSeenBeforeTheManifestIsWritten() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "S", title: "S", updatedAt: Date(timeIntervalSince1970: 100)))
        try harness.context.save()
        try await harness.writeMemo(Data([1]), projectId: "S", fileName: "one.m4a")
        try await harness.writeMemo(Data([2]), projectId: "S", fileName: "two.m4a")
        harness.drive.duringRecordingUploadNumber[2] = {
            harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(deletions: [SyncDeletion(projectId: "S", deletedAt: Date().epochMilliseconds + 60_000)]).encodedManifest())
        }

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.isEmpty && manifest.recordings.isEmpty)
        #expect(Set(manifest.deletions.compactMap(\.recordingId)) == [try harness.rowId("one.m4a"), try harness.rowId("two.m4a")])
    }

    @MainActor
    @Test func restoreResolvesTheCounterexampleOnceAtCommit() async throws {
        // Song 40 outlives tombstone 20; the take is 30 here and 10 on Drive, and
        // Drive's copy wins, so the tombstone removes it.
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "S", title: "S", updatedAt: Date(timeIntervalSince1970: 40)))
        try harness.context.save()
        let audio = Data([3, 3])
        let local = SyncRecording(id: "R", projectId: "S", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 30))
        try harness.service.library.commitRestored(audio, entry: local, origin: .restored, context: harness.context)
        var remote = local
        remote.uploadedAt = Date(timeIntervalSince1970: 10)
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(recordings: [remote], deletions: [SyncDeletion(projectId: "S", deletedAt: 20_000)]).encodedManifest())
        harness.drive.seedRecording(remote, content: audio)

        try await harness.service.restoreNow(modelContext: harness.context)

        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<SyncRecordingDeletion>()).contains { $0.recordingId == "R" && $0.deletedAt == 20_000 })
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["S"])
        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.recordings.isEmpty && manifest.projects.map(\.id) == ["S"])
        #expect(manifest.deletions.contains { $0.recordingId == "R" })
    }

    @MainActor
    @Test func importKeepsALocalRecordingWithTheSameNameAndAddsTheArchivedOneById() async throws {
        let source = try await makeHarness()
        source.context.insert(SongProject(id: "song", title: "Song"))
        try source.context.save()
        try await source.writeMemo(Data([0xA]), projectId: "song", fileName: "take.m4a")
        let archive = try source.service.exportArchive(modelContext: source.context, now: Date())
        let archivedId = try source.rowId("take.m4a")

        let target = try await makeHarness()
        try await target.writeMemo(Data([0xB]), projectId: "song", fileName: "take.m4a")
        let localId = try target.rowId("take.m4a")
        try await target.service.importArchive(archive.data, modelContext: target.context)

        // Both are kept by id under one display name; nothing is renamed (A36).
        let rows = Dictionary(uniqueKeysWithValues: try target.context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0) })
        #expect(rows[archivedId]?.displayName == "take.m4a" && rows[archivedId]?.audio == Data([0xA]))
        #expect(rows[localId]?.displayName == "take.m4a" && rows[localId]?.audio == Data([0xB]))
        #expect(try Data(contentsOf: target.file(archivedId, "song")) == Data([0xA]))
        #expect(try Data(contentsOf: target.file(localId, "song")) == Data([0xB]))
    }

    @MainActor
    @Test func exportNumbersRepeatedNamesByPrecedenceAndImportKeepsTheNames() async throws {
        let source = try await makeHarness()
        source.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        try source.context.save()
        func entry(_ id: String, _ seconds: TimeInterval, _ byte: UInt8) -> (SyncRecording, Data) {
            let audio = Data([byte])
            return (SyncRecording(id: id, projectId: "song", fileName: "take.m4a", bytes: 1, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: seconds)), audio)
        }
        // Inserted later-first: the earlier recording still gets the plain name.
        for (recording, audio) in [entry("late", 30, 3), entry("early", 10, 1), entry("middle", 20, 2)] {
            try source.service.library.commitRestored(audio, entry: recording, origin: .restored, context: source.context)
        }
        let archive = try source.service.exportArchive(modelContext: source.context, now: Date())
        let files = try BackupArchive.unzip(archive.data)
        #expect(files["recordings/song/take.m4a"] == Data([1]))
        #expect(files["recordings/song/take 2.m4a"] == Data([2]))
        #expect(files["recordings/song/take 3.m4a"] == Data([3]))
        // The numbering is the export's alone: the manifest keeps the names.
        #expect(try SyncBlob.decodeManifest(try #require(files["manifest.json"])).recordings.allSatisfy { $0.fileName == "take.m4a" })

        let target = try await makeHarness()
        try await target.service.importArchive(archive.data, modelContext: target.context)
        let rows = Dictionary(uniqueKeysWithValues: try target.context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0) })
        #expect(rows.mapValues(\.audio) == ["early": Data([1]), "middle": Data([2]), "late": Data([3])])
        #expect(rows.values.allSatisfy { $0.displayName == "take.m4a" })
        #expect(target.service.lastReport?.damagedRecordings.isEmpty == true)
    }

    @MainActor
    @Test func anIdTombstoneWithoutAFileNameNeverDeletesTheSong() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        try harness.context.save()
        try await harness.writeMemo(Data([1]), projectId: "song", fileName: "keep.m4a")
        let blob = SyncBlob(projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1))],
                            deletions: [SyncDeletion(projectId: "song", recordingId: "some-other-take", fileName: nil, deletedAt: 4_000_000_000_000)])
        try await harness.service.importArchive(try blob.encodedManifest(), modelContext: harness.context)

        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["song"])
        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).map(\.displayName) == ["keep.m4a"])
        #expect(try harness.context.fetch(FetchDescriptor<SyncRecordingDeletion>()).map(\.recordingId) == ["some-other-take"])
    }

    @MainActor
    @Test func aTombstoneWithoutATimeIsRefusedBeforeAnythingIsSaved() async throws {
        let harness = try await makeHarness()
        let manifest = try SyncBlob(deletions: [SyncDeletion(projectId: "song", deletedAt: 1)]).encodedManifest()
        let zeroed = try #require(String(data: manifest, encoding: .utf8)).replacingOccurrences(of: "\"deletedAt\":1", with: "\"deletedAt\":0")
        // The hash no longer matches either way; a bare manifest without one is checked too.
        var fields = try #require(try JSONSerialization.jsonObject(with: Data(zeroed.utf8)) as? [String: Any])
        fields.removeValue(forKey: "manifestSha256")
        await #expect(throws: (any Error).self) {
            try await harness.service.importArchive(try JSONSerialization.data(withJSONObject: fields), modelContext: harness.context)
        }
        #expect(throws: (any Error).self) { try DeletionStore.upsert(SyncDeletion(projectId: "song", deletedAt: 0), in: harness.context) }
        #expect(try harness.context.fetch(FetchDescriptor<SyncDeletionRecord>()).isEmpty)
    }

    @MainActor
    @Test func twoOfflineRenamesSettleOnTheLastOneWritten() async throws {
        let drive = FakeDriveClient()
        let deviceA = try await makeHarness(oauthProvider: FakeOAuthProvider(), drive: drive)
        let deviceB = try await makeHarness(oauthProvider: FakeOAuthProvider(), drive: drive)
        let audio = Data([5, 5])
        let take = SyncRecording(id: "b", projectId: "song", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 20))
        for harness in [deviceA, deviceB] {
            harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
            try harness.context.save()
            try harness.service.library.commitRestored(audio, entry: take, origin: .restored, context: harness.context)
            try await harness.service.library.reconcile(context: harness.context)
            try await harness.service.backupNow(modelContext: harness.context)
        }
        // A renames to foo, B (offline) to bar.
        try deviceA.service.library.renameRecording(at: deviceA.file("b", "song"), to: "foo.m4a")
        try deviceB.service.library.renameRecording(at: deviceB.file("b", "song"), to: "bar.m4a")

        var names: [String] = []
        for harness in [deviceA, deviceB, deviceA, deviceB] {
            try await harness.service.backupNow(modelContext: harness.context)
            let manifest = try SyncBlob.decodeManifest(try #require(drive.content(named: SyncBlob.driveFileName)))
            names.append(try #require(manifest.recordings.first).fileName)
        }
        #expect(names == ["foo.m4a", "bar.m4a", "bar.m4a", "bar.m4a"])
        func driveClaim() throws -> String {
            let data = try #require(drive.content(named: SyncBlob.driveFileName))
            return try #require(SyncBlob.decodeManifest(data).recordings.first).fileName
        }
        // Another backup from A before it reconciles: still bar.
        try await deviceA.service.backupNow(modelContext: deviceA.context)
        #expect(try driveClaim() == "bar.m4a")
        // A took bar as metadata; its file never moved.
        let row = try #require(deviceA.context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.displayName == "bar.m4a" && !row.displayNameChanged)
        #expect(FileManager.default.fileExists(atPath: deviceA.file("b", "song").path))
        // Cleared settings mean "take the manifest's", not "renamed here".
        deviceA.service.forgetLocalSyncState()
        try await deviceA.service.backupNow(modelContext: deviceA.context)
        #expect(try driveClaim() == "bar.m4a")
        // Restore keeps it, on the device and on Drive.
        try await deviceA.service.restoreNow(modelContext: deviceA.context)
        #expect(row.displayName == "bar.m4a")
        #expect(try driveClaim() == "bar.m4a")
    }

    @MainActor
    @Test func aSongWithoutATimeIsStampedOnTheRowOnce() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 0)))
        try harness.context.save()
        try await harness.service.backupNow(modelContext: harness.context)
        let song = try #require(harness.context.fetch(FetchDescriptor<SongProject>()).first)
        let stamped = song.updatedAt
        #expect(stamped.epochMilliseconds > 0)
        // Settings lost: the row keeps its time, and so does the manifest.
        harness.service.forgetLocalSyncState()
        try await harness.service.backupNow(modelContext: harness.context)
        #expect(song.updatedAt == stamped)
        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.first?.updatedAt == stamped)
    }

    @MainActor
    @Test func restoreAppliesNothingWhenTheRecordingsCannotBeCheckedAfterTheNetworkWait() async throws {
        let harness = try await makeHarness()
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            projects: [SyncSongProject(id: "remote", title: "Remote", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 5))]
        ).encodedManifest())
        let record = RecordingFiles.quarantineRoot(for: harness.memosRoot).appendingPathComponent("pending-moves.json")
        // During the restore's network work the move record becomes unreadable.
        harness.drive.beforeManifestWrite = {
            try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{".utf8).write(to: record)
        }
        await #expect(throws: (any Error).self) { try await harness.service.restoreNow(modelContext: harness.context) }
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).isEmpty)
    }

    @MainActor
    @Test func anArchiveWithOneRecordingIdTwiceIsRefusedWhole() async throws {
        let harness = try await makeHarness()
        let sha = RecordingBackupManifest.sha256Hex(Data([1]))
        let first = SyncRecording(id: "dup", projectId: "song", fileName: "old.m4a", bytes: 1, sha256: sha, uploadedAt: Date(timeIntervalSince1970: 1))
        var second = first
        second.fileName = "new.m4a"
        let manifest = try SyncBlob(projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1))],
                                    recordings: [first, second]).encodedManifest()
        let archive = try BackupArchive.zip([("manifest.json", manifest), ("recordings/song/old.m4a", Data([1])), ("recordings/song/new.m4a", Data([1]))])
        await #expect(throws: BackupError.damagedManifest) { try await harness.service.importArchive(archive, modelContext: harness.context) }
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).isEmpty)
    }

    @MainActor
    @Test func aRecordingDeletedElsewhereLeavesTheListForQuarantine() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "S", title: "S", updatedAt: Date(timeIntervalSince1970: 100)))
        try harness.context.save()
        try await harness.writeMemo(Data([4, 4]), projectId: "S", fileName: "take.m4a")
        let id = try harness.rowId("take.m4a")
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            projects: [SyncSongProject(id: "S", title: "S", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 100))],
            deletions: [SyncDeletion(projectId: "S", recordingId: id, fileName: "take.m4a", deletedAt: Date().epochMilliseconds + 60_000)]
        ).encodedManifest())

        try await harness.service.restoreNow(modelContext: harness.context)

        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: harness.memosRoot.appendingPathComponent("S").path)) ?? []).isEmpty)
        let quarantine = RecordingFiles.quarantineRoot(for: harness.memosRoot).appendingPathComponent("S")
        let kept = try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
        #expect(kept.count == 1 && (try? Data(contentsOf: kept[0])) == Data([4, 4]))
    }

    @MainActor
    @Test func anOversizedRecordingCountsAsBackedUpOnlyWhenDriveHoldsItsBytes() async throws {
        let harness = try await makeHarness()
        let audio = Data(count: Int(SyncRecording.maxBytes) + 1)
        try await harness.writeMemo(audio, projectId: "song", fileName: "long.m4a")

        try await harness.service.backupNow(modelContext: harness.context)
        #expect(harness.service.lastReport?.oversizedRecordings == 1)

        harness.drive.seed(name: "rec_elsewhere", content: Data(), appProperties: ["sha256": RecordingBackupManifest.sha256Hex(audio), "bytes": String(audio.count)])
        try await harness.service.backupNow(modelContext: harness.context)
        #expect(harness.service.lastReport?.oversizedRecordings == 0)
    }

    @MainActor
    @Test func anOldRecordingWhoseAudioCannotBeOpenedStillTakesPartInResolution() async throws {
        // Song 40 here, old backup: song tombstone 20 and recording R at 10 whose
        // encrypted audio is missing; R is 30 here. The old copy wins the gather
        // and the tombstone removes R.
        let harness = try await makeHarness()
        harness.secrets.setString(passphrase, for: "drive-sync-passphrase")
        harness.context.insert(SongProject(id: "T", title: "T", updatedAt: Date(timeIntervalSince1970: 40)))
        try harness.context.save()
        let audio = Data([7, 7, 7])
        let sha = RecordingBackupManifest.sha256Hex(audio)
        let id = RecordingBackupManifest.legacyRecordingId(projectId: "T", fileName: "take.m4a", sha256: sha)
        try harness.service.library.commitRestored(audio, entry: SyncRecording(id: id, projectId: "T", fileName: "take.m4a", bytes: 3, sha256: sha, uploadedAt: Date(timeIntervalSince1970: 30)), origin: .restored, context: harness.context)
        let entry = SyncRecordingManifestEntry(projectId: "T", fileName: "take.m4a", driveName: RecordingBackupManifest.legacyDriveName(projectId: "T", fileName: "take.m4a"),
                                               sizeBytes: 3, modifiedAt: Date(timeIntervalSince1970: 10), sha256: sha)
        let legacy = LegacySyncBlob(recordings: [entry], deletions: [SyncDeletion(projectId: "T", deletedAt: 20_000)], savedAt: Date(timeIntervalSince1970: 50), savedByClientId: "old")
        harness.drive.seed(name: LegacySyncBlob.driveFileName, content: try SyncRepairContractChecks.rawEnvelope(SyncJSON.encoder.encode(legacy), magic: "RAI3"))

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.map(\.id) == ["T"])
        #expect(manifest.recordings.isEmpty)
        #expect(manifest.deletions.contains { $0.recordingId == id })
        #expect(harness.service.lastReport?.migratedLegacyBackup != true)
    }

    @MainActor
    @Test func anOversizedTrashRecordingCountsUntilDriveHoldsItsBytes() async throws {
        let harness = try await makeHarness()
        let audio = Data(count: Int(SyncRecording.maxBytes) + 1)
        let trash = harness.service.library.trashRoot.appendingPathComponent("song/1000__long.m4a")
        try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try audio.write(to: trash)

        try await harness.service.backupNow(modelContext: harness.context)
        #expect(harness.service.lastReport?.oversizedRecordings == 1)

        harness.drive.seed(name: "rec_elsewhere", content: Data(), appProperties: ["sha256": RecordingBackupManifest.sha256Hex(audio), "bytes": String(audio.count)])
        try await harness.service.backupNow(modelContext: harness.context)
        #expect(harness.service.lastReport?.oversizedRecordings == 0)
    }

    @MainActor
    @Test func entriesWithoutATimeGetOneOnceAndRepeatedBackupsKeepTheirNames() async throws {
        let harness = try await makeHarness()
        let audio = Data([6, 6])
        let zero = SyncRecording(id: "z", projectId: "song", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 0))
        let older = SyncRecording(id: "o", projectId: "song", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 5))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 0))],
            recordings: [zero, older],
            // An older positive tombstone does not beat a time that was missing.
            deletions: [SyncDeletion(projectId: "song", recordingId: "z", fileName: "take.m4a", deletedAt: 1_000)]
        ).encodedManifest())
        harness.drive.seedRecording(zero, content: audio)
        harness.drive.seedRecording(older, content: audio)

        var manifests: [SyncBlob] = []
        for _ in 0..<3 {
            try await harness.service.backupNow(modelContext: harness.context)
            manifests.append(try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName))))
        }
        let first = try #require(manifests.first)
        #expect(first.recordings.first { $0.id == "z" }.map { $0.uploadedAt.epochMilliseconds > 0 } == true)
        #expect(first.projects.first.map { $0.updatedAt.epochMilliseconds > 0 } == true)
        #expect(Set(first.recordings.map(\.id)) == ["z", "o"])
        #expect(first.recordings.allSatisfy { $0.fileName == "take.m4a" })
        // The time it got is marked as a repair (A37).
        #expect(first.recordings.first { $0.id == "z" }?.precedenceRepaired == true && first.recordings.first { $0.id == "o" }?.precedenceRepaired == false)
        for manifest in manifests.dropFirst() {
            #expect(manifest.recordings == first.recordings)
            #expect(manifest.projects == first.projects)
        }
    }

    @MainActor
    @Test func restoredRecordingsAreWrittenToTheirIdsWithTheManifestsNames() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        try harness.context.save()
        let first = Data([1, 1]), second = Data([2, 2])
        let a = SyncRecording(id: UUID().uuidString.lowercased(), projectId: "song", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(first), uploadedAt: Date(timeIntervalSince1970: 10))
        let b = SyncRecording(id: UUID().uuidString.lowercased(), projectId: "song", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(second), uploadedAt: Date(timeIntervalSince1970: 20))
        let manifest = SyncBlob(projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1))], recordings: [a, b])
        harness.drive.seed(name: SyncBlob.driveFileName, content: try manifest.encodedManifest())
        harness.drive.seedRecording(a, content: first)
        harness.drive.seedRecording(b, content: second)

        try await harness.service.restoreNow(modelContext: harness.context)

        #expect(try Data(contentsOf: harness.file(a.id, "song")) == first)
        #expect(try Data(contentsOf: harness.file(b.id, "song")) == second)
        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).allSatisfy { $0.displayName == "take.m4a" })
        // A backup writes them back as they were.
        try await harness.service.backupNow(modelContext: harness.context)
        let written = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(written.recordings.sorted { $0.id < $1.id } == manifest.recordings.sorted { $0.id < $1.id })
    }

    @MainActor
    @Test func alternatingBackupsFromTwoDevicesConvergeOnNames() async throws {
        let drive = FakeDriveClient()
        let deviceA = try await makeHarness(oauthProvider: FakeOAuthProvider(), drive: drive)
        let deviceB = try await makeHarness(oauthProvider: FakeOAuthProvider(), drive: drive)
        func entry(_ id: String, _ name: String, _ seconds: TimeInterval, _ byte: UInt8) -> (SyncRecording, Data) {
            let audio = Data([byte, byte])
            return (SyncRecording(id: id, projectId: "song", fileName: name, bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: seconds)), audio)
        }
        for harness in [deviceA, deviceB] {
            harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
            try harness.context.save()
        }
        // A, after a restore: a = take, b = take 2. B, offline: b = take, c = take 2.
        for (recording, audio) in [entry("a", "take.m4a", 10, 1), entry("b", "take 2.m4a", 20, 2)] {
            try deviceA.service.library.commitRestored(audio, entry: recording, origin: .restored, context: deviceA.context)
        }
        for (recording, audio) in [entry("b", "take.m4a", 20, 2), entry("c", "take.m4a", 30, 3)] {
            try deviceB.service.library.commitRestored(audio, entry: recording, origin: .restored, context: deviceB.context)
        }
        try await deviceA.service.library.reconcile(context: deviceA.context)
        try await deviceB.service.library.reconcile(context: deviceB.context)

        var names: [[String: String]] = []
        for harness in [deviceA, deviceB, deviceA, deviceB] {
            try await harness.service.backupNow(modelContext: harness.context)
            let manifest = try SyncBlob.decodeManifest(try #require(drive.content(named: SyncBlob.driveFileName)))
            names.append(Dictionary(uniqueKeysWithValues: manifest.recordings.map { ($0.id, $0.fileName) }))
        }
        // B never renamed b, so Drive's name for it stands; c is new from B.
        #expect(names[1] == ["a": "take.m4a", "b": "take 2.m4a", "c": "take.m4a"])
        #expect(names[2] == names[1] && names[3] == names[1])
    }

    @MainActor
    @Test func cleanupKeepsAudioAnotherDeviceUploadedBeforeItsManifest() async throws {
        let harness = try await makeHarness()
        let old = Data([1]), new = Data([2])
        let covered = SyncRecording(id: UUID().uuidString.lowercased(), projectId: "S", fileName: "old.m4a", bytes: 1, sha256: RecordingBackupManifest.sha256Hex(old), uploadedAt: Date(timeIntervalSince1970: 1_000))
        let pending = SyncRecording(id: UUID().uuidString.lowercased(), projectId: "S", fileName: "new.m4a", bytes: 1, sha256: RecordingBackupManifest.sha256Hex(new), uploadedAt: Date(timeIntervalSince1970: 9_000))
        // The song was deleted at 5 000 s; its older take is listed and covered.
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(recordings: [covered], deletions: [SyncDeletion(projectId: "S", deletedAt: 5_000_000)]).encodedManifest())
        harness.drive.seedRecording(covered, content: old)
        // Another device uploaded a newer take and has not written its manifest yet.
        harness.drive.seedRecording(pending, content: new)

        try await harness.service.backupNow(modelContext: harness.context)

        #expect(harness.drive.content(named: covered.driveName) == nil)
        #expect(harness.drive.content(named: pending.driveName) == new, "audio with no gathered time is never judged")

        // The other device finishes: its manifest lists the take, and a restore brings it here.
        let current = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        let finished = try SyncMerger.merge(local: current, remote: SyncBlob(projects: [SyncSongProject(id: "S", title: "S", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 9_000))], recordings: [pending]))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try finished.encodedManifest())
        try await harness.service.restoreNow(modelContext: harness.context)
        #expect(try Data(contentsOf: harness.file(pending.id, "S")) == new)
    }

    @MainActor
    @Test func cleanupDeletesOnlyTheObjectWhoseContentTheDeletionCovers() async throws {
        let harness = try await makeHarness()
        let audio = Data([1, 1])
        let entry = SyncRecording(id: UUID().uuidString.lowercased(), projectId: "S", fileName: "take.m4a", bytes: 2,
                                  sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 1_000))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(recordings: [entry], deletions: [SyncDeletion(projectId: "S", deletedAt: 5_000_000)]).encodedManifest())
        harness.drive.seedRecording(entry, content: audio)
        // Another object under the same id with other bytes (A40: never this recording).
        var other = entry
        other.sha256 = RecordingBackupManifest.sha256Hex(Data([9, 9, 9]))
        other.bytes = 3
        harness.drive.seedDuplicateRecording(other, content: Data([9, 9, 9]), id: "~other")

        try await harness.service.backupNow(modelContext: harness.context)

        #expect(harness.drive.objects(named: entry.driveName) == 1)
        #expect(harness.drive.content(named: entry.driveName) == nil, "the covered object is gone")
        #expect(harness.service.lastReport?.conflictingDriveObjects == [entry.driveName])
    }

    @MainActor
    @Test func anUploadNeverChangesAnExistingObject() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        try harness.context.save()
        try await harness.writeMemo(Data([4, 4]), projectId: "song", fileName: "take.m4a")
        let id = try harness.rowId("take.m4a")
        // Drive already holds other bytes under this id's name.
        harness.drive.seed(name: RecordingBackupManifest.driveName(recordingId: id), content: Data([8]),
                           appProperties: ["id": id, "projectId": "song", "fileName": "take.m4a", "sha256": RecordingBackupManifest.sha256Hex(Data([8])), "bytes": "1"])

        try await harness.service.backupNow(modelContext: harness.context)

        #expect(harness.drive.objects(named: RecordingBackupManifest.driveName(recordingId: id)) == 2)
        #expect(harness.drive.contents(named: RecordingBackupManifest.driveName(recordingId: id)) == [Data([8]), Data([4, 4])])
    }

    @MainActor
    @Test func fixtureDisplayNamesRoundTripThroughARealArchive() async throws {
        final class Token {}
        let url = try #require(Bundle(for: Token.self).url(forResource: "archive-names-v1", withExtension: "json"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        let source = try await makeHarness()
        var expected: [String: (path: String, name: String, audio: Data)] = [:]
        for (index, item) in cases.enumerated() {
            let id = try #require(item["id"] as? String), projectId = try #require(item["projectId"] as? String)
            let name = try #require(item["displayName"] as? String)
            let audio = Data([UInt8(index + 1), 7])
            if try source.context.fetch(FetchDescriptor<SongProject>()).first(where: { $0.id == projectId }) == nil {
                source.context.insert(SongProject(id: projectId, title: projectId, updatedAt: Date(timeIntervalSince1970: 1)))
            }
            let entry = SyncRecording(id: id, projectId: projectId, fileName: name, bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio),
                                      uploadedAt: Date(millisecondsSince1970: try #require((item["precedenceTime"] as? NSNumber)?.int64Value)))
            try source.service.library.commitRestored(audio, entry: entry, origin: .restored, context: source.context)
            expected[id] = (try #require(item["archivePath"] as? String), name, audio)
        }
        try source.context.save()
        let archive = try source.service.exportArchive(modelContext: source.context, now: Date())
        let files = try BackupArchive.unzip(archive.data)
        for (_, value) in expected { #expect(files[value.path] == value.audio, "\(value.path)") }

        let target = try await makeHarness()
        try await target.service.importArchive(archive.data, modelContext: target.context)
        let rows = Dictionary(uniqueKeysWithValues: try target.context.fetch(FetchDescriptor<Recording>()).map { ($0.id, $0) })
        for (id, value) in expected { #expect(rows[id]?.displayName == value.name && rows[id]?.audio == value.audio) }
        #expect(target.service.lastReport?.damagedRecordings.isEmpty == true)
    }

    @MainActor
    @Test func backupAndExportWriteNothingToTheRecordingFolders() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        try harness.context.save()
        try await harness.writeMemo(Data([1]), projectId: "song", fileName: "kept.m4a")
        try await harness.writeMemo(Data([2]), projectId: "song", fileName: "binned.m4a")
        _ = try harness.service.library.trashRecording(at: harness.file(try harness.rowId("binned.m4a"), "song"), trashedAt: Date())
        // A file not taken in yet and a staged leftover.
        try harness.writeFile(Data([3]), projectId: "song", fileName: "new.m4a")
        let staging = RecordingFiles.stagingRoot(for: harness.memosRoot)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([5]).write(to: staging.appendingPathComponent("left.partial"))
        func snapshot() throws -> [String: String] {
            let scratch = harness.memosRoot.deletingLastPathComponent()
            var state: [String: String] = [:]
            let walker = try #require(FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: nil))
            for case let url as URL in walker {
                let facts = try RecordingFiles.facts(url)
                let isFile = (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
                state[url.path] = "\(facts.size)/\(facts.modified.timeIntervalSince1970)/\(facts.inode)/" + (isFile ? try RecordingFiles.sha256(of: url) : "dir")
            }
            return state
        }
        let before = try snapshot()
        try await harness.service.backupNow(modelContext: harness.context)
        _ = try harness.service.exportArchive(modelContext: harness.context, now: Date())
        #expect(try snapshot() == before)
    }

    @MainActor
    @Test func cleanupKeepsAnUnlistedUploadOfATombstonedId() async throws {
        let harness = try await makeHarness()
        let audio = Data([3])
        let id = UUID().uuidString.lowercased()
        let upload = SyncRecording(id: id, projectId: "S", fileName: "take.m4a", bytes: 1, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 9_000))
        // Drive has a tombstone for this very id, and an upload of it whose manifest
        // another device has not written yet: its time is unknown here.
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            deletions: [SyncDeletion(projectId: "S", recordingId: id, fileName: "take.m4a", deletedAt: 5_000_000)]
        ).encodedManifest())
        harness.drive.seedRecording(upload, content: audio)

        try await harness.service.backupNow(modelContext: harness.context)
        try await harness.service.backupNow(modelContext: harness.context)

        #expect(harness.drive.content(named: upload.driveName) == audio)
    }

    @MainActor
    @Test func exportNamesTheRecordingsItLeavesOut() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        try harness.context.save()
        try await harness.writeMemo(Data([1]), projectId: "song", fileName: "kept.m4a")
        // A file whose id's name holds other bytes: neither is taken in.
        let id = RecordingBackupManifest.legacyRecordingId(projectId: "song", fileName: "blocked.m4a", sha256: RecordingBackupManifest.sha256Hex(Data([2])))
        try harness.writeFile(Data([2]), projectId: "song", fileName: "blocked.m4a")
        try harness.writeFile(Data([9]), projectId: "song", fileName: "\(id).m4a")
        try await harness.service.library.reconcile(context: harness.context)

        let archive = try harness.service.exportArchive(modelContext: harness.context, now: Date())
        #expect(try BackupArchive.unzip(archive.data).keys.filter { $0.hasPrefix("recordings/") } == ["recordings/song/kept.m4a"])
        #expect(Set(harness.service.lastReport?.leftOutRecordings ?? []) == ["blocked.m4a (not in the library yet)", "\(id).m4a (not in the library yet)"])
    }

    @MainActor
    @Test func exportNamesEveryKindOfRecordingItDoesNotHold() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        try harness.context.save()
        try await harness.writeMemo(Data([1]), projectId: "song", fileName: "kept.m4a")
        try await harness.writeMemo(Data([2]), projectId: "song", fileName: "binned.m4a")
        _ = try harness.service.library.trashRecording(at: harness.file(try harness.rowId("binned.m4a"), "song"), trashedAt: Date())
        try await harness.writeMemo(Data(repeating: 5, count: Int(SyncRecording.maxBytes) + 1), projectId: "song", fileName: "long.m4a")
        let quarantine = RecordingFiles.quarantineRoot(for: harness.memosRoot).appendingPathComponent("song", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data([7]).write(to: quarantine.appendingPathComponent("gone.m4a"))

        _ = try harness.service.exportArchive(modelContext: harness.context, now: Date())

        let report = try #require(harness.service.lastReport)
        #expect(Set(report.leftOutRecordings) == ["binned.m4a (recordings Trash)", "long.m4a (over 16 MB)"])
        #expect(report.quarantinedNotExported == 1)
    }

    @MainActor
    @Test func aRecordingWithoutATimeOnDriveIsRepairedNotRefused() async throws {
        let harness = try await makeHarness()
        let audio = Data([2, 2])
        let entry = SyncRecording(id: UUID().uuidString.lowercased(), projectId: "song", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio),
                                  uploadedAt: Date(timeIntervalSince1970: 5))
        var fields = try #require(try JSONSerialization.jsonObject(with: try SyncBlob(
            projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1))], recordings: [entry]
        ).encodedManifest()) as? [String: Any])
        fields.removeValue(forKey: "manifestSha256")
        var recordings = try #require(fields["recordings"] as? [[String: Any]])
        recordings[0].removeValue(forKey: "uploadedAt")
        fields["recordings"] = recordings
        fields["manifestSha256"] = CanonicalJSON.sha256Hex(try JSONValue(any: fields))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try JSONSerialization.data(withJSONObject: fields))
        harness.drive.seedRecording(entry, content: audio)

        try await harness.service.restoreNow(modelContext: harness.context)

        let row = try #require(harness.context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.precedenceRepaired && row.precedenceTime.epochMilliseconds > 0)
        let written = try #require(harness.drive.content(named: SyncBlob.driveFileName))
        #expect(try SyncBlob.decodeManifest(written).recordings.first?.precedenceRepaired == true)
    }

    @MainActor
    @Test func duplicateRawObjectsGiveTheVerifiedCopyAndAreAllCleanedUp() async throws {
        for damagedFirst in [true, false] {
            let harness = try await makeHarness()
            let audio = Data([6, 6])
            let entry = SyncRecording(id: UUID().uuidString.lowercased(), projectId: "song", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 100))
            harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
                projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1))],
                recordings: [entry]
            ).encodedManifest())
            // Two objects under one name, both claiming the hash; one holds other bytes.
            harness.drive.seedRecording(entry, content: damagedFirst ? audio : Data([9, 9]))
            harness.drive.seedDuplicateRecording(entry, content: damagedFirst ? Data([9, 9]) : audio, id: damagedFirst ? "!first" : "~last")
            #expect(harness.drive.objects(named: entry.driveName) == 2)

            try await harness.service.restoreNow(modelContext: harness.context)
            #expect(try harness.context.fetch(FetchDescriptor<Recording>()).map(\.audio) == [audio])
            #expect(harness.service.lastReport?.damagedRecordings.isEmpty == true)

            // Deleted later: every object under its name goes.
            harness.context.insert(SyncRecordingDeletion(projectId: "song", recordingId: entry.id, fileName: "take.m4a", deletedAt: 4_000_000_000_000))
            try harness.context.save()
            try await harness.service.backupNow(modelContext: harness.context)
            #expect(harness.drive.objects(named: entry.driveName) == 0)
        }
    }

    @MainActor
    @Test func twoReplicasRepairingOneSongSettleOnTheEarlierTimeAndTheDeletionBetweenWins() async throws {
        let drive = FakeDriveClient()
        let deviceA = try await makeHarness(oauthProvider: FakeOAuthProvider(), drive: drive)
        let deviceB = try await makeHarness(oauthProvider: FakeOAuthProvider(), drive: drive)
        // The same zero-time song from iCloud, first seen at tA = 1 000 s and tB = 3 000 s.
        for (harness, seconds) in [(deviceA, 1_000.0), (deviceB, 3_000.0)] {
            let song = SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: seconds))
            song.precedenceRepaired = true
            harness.context.insert(song)
            try harness.context.save()
        }
        for harness in [deviceB, deviceA, deviceB] { try await harness.service.backupNow(modelContext: harness.context) }
        let manifest = try SyncBlob.decodeManifest(try #require(drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.map(\.updatedAt) == [Date(timeIntervalSince1970: 1_000)] && manifest.projects.first?.precedenceRepaired == true)
        try await deviceB.service.restoreNow(modelContext: deviceB.context)
        #expect(try deviceB.context.fetch(FetchDescriptor<SongProject>()).map(\.updatedAt) == [Date(timeIntervalSince1970: 1_000)])

        // A deletion at 2 000 s, between the two: it wins on both.
        drive.seed(name: SyncBlob.driveFileName, content: try SyncMerger.merge(local: manifest, remote: SyncBlob(deletions: [SyncDeletion(projectId: "song", deletedAt: 2_000_000)])).encodedManifest())
        for harness in [deviceA, deviceB] {
            try await harness.service.restoreNow(modelContext: harness.context)
            #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).isEmpty)
        }
        #expect(try SyncBlob.decodeManifest(try #require(drive.content(named: SyncBlob.driveFileName))).projects.isEmpty)

        // A genuine edit beats a repair and clears the mark.
        let edited = SyncSongProject(id: "edited", title: "E", lyrics: "new", theme: "", updatedAt: Date(timeIntervalSince1970: 500))
        let repaired = SyncSongProject(id: "edited", title: "E", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 400), precedenceRepaired: true)
        let merged = try SyncMerger.merge(local: SyncBlob(projects: [repaired]), remote: SyncBlob(projects: [edited]))
        #expect(merged.projects == [edited])
    }

    @MainActor
    @Test func aTrashedSongWithoutATimeKeepsItsRetentionThroughImportRestoreAndPurge() async throws {
        let zero = Date(timeIntervalSince1970: 0)
        let trashed = SyncTrashedSongProject(id: "old", title: "Old", lyrics: "", theme: "", updatedAt: zero, deletedAt: zero, deleteAfter: zero.addingTimeInterval(trashRetentionInterval))
        let blob = SyncBlob(trashed: [trashed])
        func check(_ harness: BackupHarness) async throws {
            let row = try #require(harness.context.fetch(FetchDescriptor<TrashedSongProject>()).first)
            #expect(row.deletedAt.epochMilliseconds > 0 && row.trashedAtRepaired && row.precedenceRepaired)
            #expect(row.deleteAfter == row.deletedAt.addingTimeInterval(trashRetentionInterval))
            let viewModel = EditorViewModel(recordingLibrary: harness.service.library)
            viewModel.modelContext = harness.context
            await viewModel.recordingsLaunchTask?.value
            viewModel.purgeExpiredTrashedProjects()
            #expect(try harness.context.fetch(FetchDescriptor<TrashedSongProject>()).map(\.id) == ["old"])
            #expect(try harness.context.fetch(FetchDescriptor<SyncDeletionRecord>()).isEmpty)
        }

        let imported = try await makeHarness()
        try await imported.service.importArchive(try blob.encodedManifest(), modelContext: imported.context)
        try await check(imported)

        let restored = try await makeHarness()
        restored.drive.seed(name: SyncBlob.driveFileName, content: try blob.encodedManifest())
        try await restored.service.restoreNow(modelContext: restored.context)
        try await check(restored)
    }

    @MainActor
    @Test func aRepairedTimeKeepsItsMarkThroughDriveAndArchiveRoundTrips() async throws {
        let source = try await makeHarness()
        source.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        let audio = Data([3, 3])
        let entry = SyncRecording(id: UUID().uuidString.lowercased(), projectId: "song", fileName: "take.m4a", bytes: 2,
                                  sha256: RecordingBackupManifest.sha256Hex(audio), uploadedAt: Date(timeIntervalSince1970: 70), precedenceRepaired: true)
        try source.service.library.commitRestored(audio, entry: entry, origin: .restored, context: source.context)
        try source.context.save()
        try await source.service.backupNow(modelContext: source.context)
        let manifest = try SyncBlob.decodeManifest(try #require(source.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.recordings.map(\.precedenceRepaired) == [true])

        // Drive: another device restores it.
        let other = try await makeHarness(oauthProvider: FakeOAuthProvider(), drive: source.drive)
        try await other.service.restoreNow(modelContext: other.context)
        let restored = try #require(other.context.fetch(FetchDescriptor<Recording>()).first)
        #expect(restored.precedenceRepaired && restored.uploadedAt == Date(timeIntervalSince1970: 70))

        // Archive: export, then import elsewhere.
        let archive = try source.service.exportArchive(modelContext: source.context, now: Date())
        #expect(try SyncBlob.decodeManifest(try #require(BackupArchive.unzip(archive.data)["manifest.json"])).recordings.map(\.precedenceRepaired) == [true])
        let target = try await makeHarness()
        try await target.service.importArchive(archive.data, modelContext: target.context)
        let imported = try #require(target.context.fetch(FetchDescriptor<Recording>()).first)
        #expect(imported.precedenceRepaired && imported.uploadedAt == Date(timeIntervalSince1970: 70))
    }

    @MainActor
    @Test func aRecordedTimeFromDriveReplacesARepairedOneOnTheRowBeforeTombstonesAreCompared() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        let audio = Data([4, 4])
        let id = UUID().uuidString.lowercased()
        let repaired = SyncRecording(id: id, projectId: "song", fileName: "take.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio),
                                     uploadedAt: Date(timeIntervalSince1970: 9_000), precedenceRepaired: true)
        try harness.service.library.commitRestored(audio, entry: repaired, origin: .restored, context: harness.context)
        // In the recordings Trash here, so it is judged by its own time.
        let live = try #require(harness.service.library.liveRecordings(in: harness.context).first).url
        _ = try harness.service.library.trashRecording(at: live, trashedAt: Date())
        // Drive knows its recorded time (1 000 s) and a deletion of it at 5 000 s.
        var recorded = repaired
        recorded.uploadedAt = Date(timeIntervalSince1970: 1_000)
        recorded.precedenceRepaired = false
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1))],
            recordings: [recorded], deletions: [SyncDeletion(projectId: "song", recordingId: id, fileName: "take.m4a", deletedAt: 5_000_000)]
        ).encodedManifest())

        try await harness.service.restoreNow(modelContext: harness.context)

        #expect(try harness.context.fetch(FetchDescriptor<Recording>()).isEmpty, "the deletion wins against the recorded time")
        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.recordings.isEmpty)
        try await harness.service.backupNow(modelContext: harness.context)
        #expect(try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName))).recordings.isEmpty)
    }

    @MainActor
    @Test func namesFollowDriveWhateverTimeWinsAndARenameBeforeTrashIsPublished() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "song", title: "Song", updatedAt: Date(timeIntervalSince1970: 1)))
        let audio = Data([5, 5])
        let id = UUID().uuidString.lowercased()
        // Here: the smaller repaired time, so this copy wins on time; Drive has another name.
        let local = SyncRecording(id: id, projectId: "song", fileName: "here.m4a", bytes: 2, sha256: RecordingBackupManifest.sha256Hex(audio),
                                  uploadedAt: Date(timeIntervalSince1970: 50), precedenceRepaired: true)
        try harness.service.library.commitRestored(audio, entry: local, origin: .restored, context: harness.context)
        var remote = local
        remote.fileName = "drive.m4a"
        remote.uploadedAt = Date(timeIntervalSince1970: 100)
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(recordings: [remote]).encodedManifest())
        harness.drive.seedRecording(remote, content: audio)

        for _ in 0..<2 {
            try await harness.service.backupNow(modelContext: harness.context)
            let data = try #require(harness.drive.content(named: SyncBlob.driveFileName))
            let written = try #require(SyncBlob.decodeManifest(data).recordings.first)
            #expect(written.fileName == "drive.m4a" && written.uploadedAt == Date(timeIntervalSince1970: 50))
        }
        let row = try #require(harness.context.fetch(FetchDescriptor<Recording>()).first)
        #expect(row.displayName == "drive.m4a")

        // Renamed, then trashed before any backup: the rename still goes up.
        let file = harness.file(id, "song")
        try harness.service.library.renameRecording(at: file, to: "final.m4a")
        _ = try harness.service.library.trashRecording(at: file, trashedAt: Date())
        try await harness.service.backupNow(modelContext: harness.context)
        let data = try #require(harness.drive.content(named: SyncBlob.driveFileName))
        let written = try #require(SyncBlob.decodeManifest(data).recordings.first)
        #expect(written.fileName == "final.m4a")
        #expect(row.displayName == "final.m4a" && !row.displayNameChanged)
    }

    @MainActor
    @Test func duplicateManifestsAreMergedAndTheExtraRemovedAfterVerifying() async throws {
        let harness = try await makeHarness()
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(projects: [SyncSongProject(id: "a", title: "A", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1))]).encodedManifest())
        harness.drive.seedDuplicateManifest(try SyncBlob(projects: [SyncSongProject(id: "b", title: "B", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 2))]).encodedManifest())
        #expect(harness.drive.manifestCount == 2)

        try await harness.service.backupNow(modelContext: harness.context)

        #expect(harness.drive.manifestCount == 1)
        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.map(\.id) == ["a", "b"])
    }

    @MainActor
    @Test func driveListingFollowsEveryPage() async throws {
        PagingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PagingURLProtocol.self]
        let client = RealDriveAppDataClient(session: URLSession(configuration: configuration))

        let files = try await client.listFiles(prefix: "rec_", accessToken: "token")

        #expect(files.map(\.name) == ["rec_a_1.m4a", "rec_b_2.m4a"])
        #expect(PagingURLProtocol.pageTokens == [nil, "page-2"])
    }

    @MainActor
    @Test func aFileThatAppearsWhileARestoreDownloadsIsKept() async throws {
        let harness = try await makeHarness()
        let remote = Data([4, 4, 4])
        let entry = SyncRecording(projectId: "song", fileName: "take.m4a", bytes: 3, sha256: RecordingBackupManifest.sha256Hex(remote))
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(
            projects: [SyncSongProject(id: "song", title: "Song", lyrics: "", theme: "", updatedAt: Date(timeIntervalSince1970: 1))],
            recordings: [entry]
        ).encodedManifest())
        harness.drive.seed(name: entry.driveName, content: remote)
        let local = Data([7, 7])
        // Planned as missing; the writer records a take with that name before the download lands.
        harness.drive.afterManifestWrite = { try harness.writeFile(local, projectId: "song", fileName: "take.m4a") }
        // A file left staged by an interrupted restore is cleared when the next restore starts.
        let staging = RecordingFiles.stagingRoot(for: harness.memosRoot)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([9]).write(to: staging.appendingPathComponent("left-over.partial"))

        try await harness.service.restoreNow(modelContext: harness.context)

        // Both are kept, each under its own id.
        #expect(try Data(contentsOf: harness.file(entry.id, "song")) == remote)
        #expect(harness.audios("song") == [remote, local])
        #expect((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] == [])
    }

    @Test func pinnedTrustCoversTheDriveHostsWithNoWayAround() async throws {
        let ats = try #require(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
        #expect(ats["NSAllowsArbitraryLoads"] == nil && ats["NSExceptionDomains"] == nil)
        let pinned = try #require(ats["NSPinnedDomains"] as? [String: [String: Any]])
        for host in ["www.googleapis.com", "oauth2.googleapis.com"] {
            let entry = try #require(pinned[host], "\(host) is not pinned")
            #expect(entry["NSIncludesSubdomains"] as? Bool == false)
            let identities = try #require(entry["NSPinnedCAIdentities"] as? [[String: String]])
            // GTS Root R4 serves the hosts today; the other Google roots and GlobalSign are the backups.
            #expect(identities.compactMap { $0["SPKI-SHA256-BASE64"] }.contains("mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c="))
            #expect(identities.count >= 2)
        }
    }

    // MARK: Migration from the encrypted backup

    @MainActor
    @Test func anUnreadableOldRecordingKeepsTheOldBackupAndIsCounted() async throws {
        let harness = try await makeHarness()
        harness.secrets.setString(passphrase, for: "drive-sync-passphrase")
        try harness.seedLegacyBackup(audio: Data([1, 2, 3]))
        harness.drive.seed(name: "rec_old-song_take.m4a.enc", content: Data("not an envelope".utf8))

        try await harness.service.backupNow(modelContext: harness.context)

        #expect(harness.drive.content(named: "rhymeai-projects.json") != nil)
        #expect(harness.drive.content(named: "rec_old-song_take.m4a.enc") != nil)
        #expect(harness.secrets.string(for: "drive-sync-passphrase") == passphrase)
        #expect(harness.service.hasLegacyBackupToMigrate)
        #expect(harness.service.lastReport?.unmovedLegacyRecordings == 1)
        #expect(harness.service.lastReport?.migratedLegacyBackup == false)
        // The songs are already safe in v4.
        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.map(\.id) == ["old-song"])
    }

    @Test(arguments: [(false, false, LegacyMigrationDecision.none), (false, true, .none), (true, true, .migrate), (true, false, .askForPassphrase)])
    func migrationDecisionTable(_ legacyExists: Bool, _ hasPassphrase: Bool, _ expected: LegacyMigrationDecision) {
        #expect(LegacyMigrationDecision.decide(legacyBackupExists: legacyExists, hasPassphrase: hasPassphrase) == expected)
    }

    @MainActor
    @Test func storedPassphraseMigratesTheOldBackupVerifiesV4ThenRemovesTheOldFiles() async throws {
        let harness = try await makeHarness()
        harness.secrets.setString(passphrase, for: "drive-sync-passphrase")
        harness.context.insert(SongProject(id: "local", title: "Local"))
        try harness.context.save()
        let oldAudio = Data([8, 6, 7, 5])
        try harness.seedLegacyBackup(audio: oldAudio)

        try await harness.service.backupNow(modelContext: harness.context)

        #expect(harness.drive.content(named: "rhymeai-projects.json") == nil)
        #expect(harness.drive.content(named: "rec_old-song_take.m4a.enc") == nil)
        #expect(harness.secrets.string(for: "drive-sync-passphrase") == nil)
        #expect(harness.service.lastReport?.migratedLegacyBackup == true)
        #expect(!harness.service.hasLegacyBackupToMigrate)
        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(Set(manifest.projects.map(\.id)) == Set(["local", "old-song"]))
        #expect(manifest.recordings.map(\.fileName) == ["take.m4a"])
        #expect(harness.drive.content(named: try #require(manifest.recordings.first).driveName) == oldAudio)
        // The migration is a backup: the old songs reach this device on Restore.
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["local"])
        #expect(harness.audios("old-song").isEmpty)
        try await harness.service.restoreNow(modelContext: harness.context)
        #expect(Set(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.id)) == Set(["local", "old-song"]))
        #expect(harness.audios("old-song") == [oldAudio])
    }

    @MainActor
    @Test func withoutAPassphraseTheOldFilesStayAndMigrationIsOffered() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "local", title: "Local"))
        try harness.context.save()
        try harness.seedLegacyBackup(audio: Data([1]))

        try await harness.service.backupNow(modelContext: harness.context)

        #expect(harness.drive.content(named: "rhymeai-projects.json") != nil)
        #expect(harness.drive.content(named: "rec_old-song_take.m4a.enc") != nil)
        #expect(harness.service.hasLegacyBackupToMigrate)
        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.map(\.id) == ["local"])
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        #expect(viewModel.legacyBackupNeedsPassphrase)
    }

    @MainActor
    @Test func enteredPassphraseMigratesAndAWrongOneKeepsEverything() async throws {
        let harness = try await makeHarness()
        try harness.seedLegacyBackup(audio: Data([4, 2]))
        try await harness.service.backupNow(modelContext: harness.context)
        #expect(harness.service.hasLegacyBackupToMigrate)

        await #expect(throws: BackupError.wrongLegacyPassphrase) {
            try await harness.service.migrateLegacyBackup(passphrase: "not the passphrase", modelContext: harness.context)
        }
        #expect(harness.drive.content(named: "rhymeai-projects.json") != nil)
        #expect(harness.service.hasLegacyBackupToMigrate)

        try await harness.service.migrateLegacyBackup(passphrase: "  \(passphrase)\n", modelContext: harness.context)

        #expect(harness.drive.content(named: "rhymeai-projects.json") == nil)
        #expect(harness.drive.content(named: "rec_old-song_take.m4a.enc") == nil)
        #expect(!harness.service.hasLegacyBackupToMigrate)
        #expect(harness.secrets.string(for: "drive-sync-passphrase") == nil)
        #expect(try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName))).projects.map(\.id) == ["old-song"])
    }

    @MainActor
    @Test func noOldBackupForgetsAStoredPassphrase() async throws {
        let harness = try await makeHarness()
        harness.secrets.setString(passphrase, for: "drive-sync-passphrase")

        try await harness.service.backupNow(modelContext: harness.context)

        #expect(harness.secrets.string(for: "drive-sync-passphrase") == nil)
    }

    // MARK: Export and import

    @MainActor
    @Test func exportThenImportYieldsTheSameManifest() async throws {
        let source = try await makeHarness()
        source.context.insert(SongProject(id: "song-1", title: "Café \"Noir\"", lyrics: "one\ntwo", theme: "late", updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        source.context.insert(TrashedSongProject(id: "song-2", title: "Old", lyrics: "gone", theme: "", updatedAt: Date(timeIntervalSince1970: 1_700_000_001), deletedAt: Date(timeIntervalSince1970: 1_700_000_002)))
        source.context.insert(SyncDeletionRecord(projectId: "song-3", deletedAt: 1_700_000_003_000))
        try source.context.save()
        let take = Data([0xde, 0xad, 0xbe, 0xef])
        try await source.writeMemo(take, projectId: "song-1", fileName: "take 1.m4a")

        let archive = try source.service.exportArchive(modelContext: source.context, now: Date(timeIntervalSince1970: 1_761_134_400))

        #expect(archive.fileName == "WritersBlock-backup-2025-10-22.zip")
        let files = try BackupArchive.unzip(archive.data)
        #expect(Set(files.keys) == Set(["manifest.json", "songs/Café Noir.txt", "songs/song-1.json", "recordings/song-1/take 1.m4a"]))
        #expect(files["recordings/song-1/take 1.m4a"] == take)
        let exported = try SyncBlob.decodeManifest(try #require(files["manifest.json"]))

        let target = try await makeHarness()
        try await target.service.importArchive(archive.data, modelContext: target.context)

        let reexported = try SyncBlob.decodeManifest(try #require(BackupArchive.unzip(
            try target.service.exportArchive(modelContext: target.context, now: Date()).data
        )["manifest.json"]))
        #expect(reexported.projects == exported.projects)
        #expect(reexported.trashed == exported.trashed)
        #expect(reexported.recordings == exported.recordings)
        #expect(reexported.deletions == exported.deletions)
        #expect(target.audios("song-1") == [take])
        #expect(try target.context.fetch(FetchDescriptor<Recording>()).map(\.displayName) == ["take 1.m4a"])
    }

    @MainActor
    @Test func importRefusesADamagedManifestAndMergesABareOne() async throws {
        let harness = try await makeHarness()
        harness.context.insert(SongProject(id: "local", title: "Local"))
        try harness.context.save()
        let incoming = SyncBlob(projects: [SyncSongProject(id: "incoming", title: "Incoming", lyrics: "x", theme: "", updatedAt: Date(timeIntervalSince1970: 5))])
        let manifest = try incoming.encodedManifest()
        var damaged = manifest
        damaged[damaged.count / 2] ^= 0x01

        await #expect(throws: BackupError.damagedManifest) {
            try await harness.service.importArchive(damaged, modelContext: harness.context)
        }
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.id) == ["local"])

        try await harness.service.importArchive(manifest, modelContext: harness.context)
        #expect(Set(try harness.context.fetch(FetchDescriptor<SongProject>()).map(\.id)) == Set(["local", "incoming"]))
    }

    @MainActor
    @Test func aRetainedOlderTombstoneDoesNotExemptALegacySongFromVerification() async throws {
        let harness = try await makeHarness()
        harness.secrets.setString(passphrase, for: "drive-sync-passphrase")
        let oldAudio = Data([1, 2])
        try harness.seedLegacyBackup(audio: oldAudio)
        // A tombstone older than the legacy song: kept for audio protection, song survives.
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlob(deletions: [SyncDeletion(projectId: "old-song", deletedAt: 1_600_000_000_000)]).encodedManifest())

        try await harness.service.backupNow(modelContext: harness.context)

        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.map(\.id) == ["old-song"])
        #expect(harness.service.lastReport?.migratedLegacyBackup == true)
    }

    @MainActor
    @Test func importRefusesUnsafeOrForeignZipEntries() async throws {
        let harness = try await makeHarness()
        let manifest = try SyncBlob().encodedManifest()
        for path in ["../escape.txt", "/etc/passwd", "C:/evil.txt", "songs/../../x.txt", "notes/extra.txt", "songs\\x.txt"] {
            let zip = try BackupArchive.zip([("manifest.json", manifest), (path, Data("x".utf8))])
            await #expect(throws: BackupError.unsafeArchive, "\(path)") {
                try await harness.service.importArchive(zip, modelContext: harness.context)
            }
        }
        #expect(BackupArchive.isSafePath("recordings/song/take 1.m4a"))
        #expect(!BackupArchive.isSafePath("recordings/./take.m4a"))
    }

    @Test func zipReaderChecksEveryEntryAndEverySizeBeforeInflating() async throws {
        let allow: (String) -> Bool = { $0 == "manifest.json" || $0.hasPrefix("songs/") }
        // A directory outside the allowed roots is refused even though it holds nothing.
        #expect(throws: BackupArchiveError.unsafePath) {
            try BackupArchive.unzip(try BackupArchive.zip([("manifest.json", Data("{}".utf8)), ("elsewhere/", Data())]), allow: allow)
        }
        #expect(throws: BackupArchiveError.unsafePath) {
            try BackupArchive.unzip(try BackupArchive.zip([("../", Data())]))
        }
        // Declared sizes over the limits are refused before any inflation.
        var oversized = try BackupArchive.zip([("songs/a.txt", Data("x".utf8))])
        let central = oversized.count - 22 - 46 - "songs/a.txt".utf8.count
        let huge = UInt32(BackupArchive.maxEntryBytes + 1).littleEndian
        withUnsafeBytes(of: huge) { oversized.replaceSubrange((central + 24)..<(central + 28), with: $0) }
        #expect(throws: BackupArchiveError.tooLarge) { try BackupArchive.unzip(oversized) }
    }

    @Test func zipReaderTakesStoredAndDeflatedEntries() async throws {
        let stored = try BackupArchive.zip([("a.txt", Data("hello".utf8)), ("dir/b.bin", Data([0, 1, 2]))])
        #expect(try BackupArchive.unzip(stored) == ["a.txt": Data("hello".utf8), "dir/b.bin": Data([0, 1, 2])])
        #expect(BackupArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        // "hello" deflated by zlib (raw), stored in a one-entry archive written by hand.
        let deflated = Data([0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00])
        var zip = Data()
        func le16(_ v: Int) { zip.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func le32(_ v: Int) { le16(v & 0xffff); le16(v >> 16 & 0xffff) }
        let crc = Int(BackupArchive.crc32(Data("hello".utf8)))
        le32(0x0403_4b50); le16(20); le16(0); le16(8); le16(0); le16(0); le32(crc); le32(deflated.count); le32(5); le16(1); le16(0)
        zip.append(Data("h".utf8)); zip.append(deflated)
        let central = zip.count
        le32(0x0201_4b50); le16(20); le16(20); le16(0); le16(8); le16(0); le16(0); le32(crc); le32(deflated.count); le32(5); le16(1); le16(0); le16(0); le16(0); le16(0); le32(0); le32(0)
        zip.append(Data("h".utf8))
        let size = zip.count - central
        le32(0x0605_4b50); le16(0); le16(0); le16(1); le16(1); le32(size); le32(central); le16(0)
        #expect(try BackupArchive.unzip(zip) == ["h": Data("hello".utf8)])
        // An entry that inflates past its declared size is refused, not inflated further.
        var lying = zip
        for offset in [22, central + 24] { lying[offset] = 4 }
        #expect(throws: BackupArchiveError.unreadable) { try BackupArchive.unzip(lying) }
        #expect(throws: BackupArchiveError.unreadable) { try BackupArchive.unzip(Data("not a zip".utf8)) }
    }

    @MainActor
    @Test func restoreKeepsPendingEditorDraftWhenRemoteSongWinsMerge() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "open-song", title: "Local", lyrics: "saved line", theme: "calm")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        viewModel.lyrics = "pending local line"
        viewModel.triggerAutoSave()

        let remote = SyncBlob(projects: [
            SyncSongProject(id: project.id, title: "Remote", lyrics: "remote line", theme: "loud",
                            updatedAt: Date().addingTimeInterval(3_600))
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(projects.first(where: { $0.id == project.id })?.lyrics == "remote line")
        #expect(viewModel.lyrics == "pending local line")
        #expect(viewModel.currentProjectId != project.id)
        #expect(projects.first(where: { $0.id == viewModel.currentProjectId })?.lyrics == "pending local line")
    }

    @MainActor
    @Test func restoreRefreshesUneditedOpenSongFromMergedStore() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "open-song", title: "Local", lyrics: "saved line", theme: "calm")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        let remote = SyncBlob(projects: [
            SyncSongProject(id: project.id, title: "Remote", lyrics: "remote line", theme: "loud",
                            updatedAt: Date().addingTimeInterval(3_600))
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")

        #expect(viewModel.currentProjectId == project.id)
        #expect(viewModel.title == "Remote")
        #expect(viewModel.lyrics == "remote line")
        #expect(viewModel.theme == "loud")
    }

    @MainActor
    @Test func restoreClearsSavingStateWhenAwaitedEditIsReverted() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "open-song", title: "Local", lyrics: "saved line", theme: "calm")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        let remote = SyncBlob(projects: [
            SyncSongProject(id: project.id, title: "Local", lyrics: "saved line", theme: "calm",
                            updatedAt: Date().addingTimeInterval(3_600))
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        harness.drive.beforeManifestWrite = {
            viewModel.lyrics = "temporary edit"
            viewModel.triggerAutoSave()
            viewModel.lyrics = "saved line"
            viewModel.triggerAutoSave()
        }
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        let stored = try #require(harness.context.fetch(FetchDescriptor<SongProject>()).first)
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        #expect(viewModel.saveStatus == .saved)
        #expect(viewModel.currentProjectId == project.id)
        #expect(viewModel.lyrics == "saved line")
        #expect(stored.id == project.id && stored.lyrics == "saved line")
    }

    @MainActor
    @Test func restoreClearsSavingStateWhenPendingEditMatchesMergedSong() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "open-song", title: "Local", lyrics: "saved line", theme: "calm")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        viewModel.lyrics = "pending local line"
        let remote = SyncBlob(projects: [
            SyncSongProject(id: project.id, title: "Local", lyrics: "pending local line", theme: "calm",
                            updatedAt: Date().addingTimeInterval(3_600))
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        harness.drive.beforeManifestWrite = {
            viewModel.lyrics = "temporary edit"
            viewModel.triggerAutoSave()
            viewModel.lyrics = "pending local line"
            viewModel.triggerAutoSave()
        }
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        let stored = try #require(harness.context.fetch(FetchDescriptor<SongProject>()).first)
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        #expect(viewModel.saveStatus == .saved)
        #expect(viewModel.currentProjectId == project.id)
        #expect(viewModel.lyrics == "pending local line")
        #expect(stored.id == project.id && stored.lyrics == "pending local line")
    }

    @MainActor
    @Test func restorePreservesEditMadeDuringAwaitWhenRemoteDeletesOpenSong() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "open-song", title: "Local", lyrics: "saved line", theme: "calm")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        let remote = SyncBlob(deletions: [
            SyncDeletion(projectId: project.id, deletedAt: Int64(Date().timeIntervalSince1970 * 1_000) + 3_600_000)
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        harness.drive.beforeManifestWrite = {
            viewModel.lyrics = "typed while restore awaited"
            viewModel.triggerAutoSave()
        }
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(projects.first(where: { $0.id == project.id }) == nil)
        #expect(viewModel.lyrics == "typed while restore awaited")
        #expect(viewModel.currentProjectId != project.id)
        #expect(projects.first(where: { $0.id == viewModel.currentProjectId })?.lyrics == "typed while restore awaited")
    }


    @MainActor
    @Test func restoreClearsUneditedOpenSongWhenRemoteTombstoneWins() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "open-song", title: "Local", lyrics: "saved line", theme: "calm")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        let remote = SyncBlob(deletions: [
            SyncDeletion(projectId: project.id, deletedAt: Int64(Date().timeIntervalSince1970 * 1_000) + 3_600_000)
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).isEmpty)
        #expect(viewModel.currentProjectId == nil)
        #expect(viewModel.lyrics.isEmpty)
        #expect(viewModel.showWelcome)
    }

    @MainActor
    @Test func restorePreservesOutgoingAWhenSwitchingToUnchangedBDuringAwait() async throws {
        let harness = try await makeHarness()
        let first = SongProject(id: "song-a", title: "A", lyrics: "saved A")
        let second = SongProject(id: "song-b", title: "B", lyrics: "saved B")
        harness.context.insert(first)
        harness.context.insert(second)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(first)
        viewModel.lyrics = "pending A"
        let remote = SyncBlob(projects: [
            SyncSongProject(id: first.id, title: "Remote A", lyrics: "remote A", theme: "",
                            updatedAt: Date().addingTimeInterval(3_600))
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        harness.drive.beforeManifestWrite = { viewModel.loadProject(second) }
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        #expect(projects.first(where: { $0.id == first.id })?.lyrics == "remote A")
        #expect(projects.first(where: { $0.id == second.id })?.lyrics == "saved B")
        #expect(viewModel.currentProjectId == second.id)
        #expect(viewModel.lyrics == "saved B")
        #expect(projects.contains { $0.id != first.id && $0.id != second.id && $0.lyrics == "pending A" })
    }

    @MainActor
    @Test func restorePreservesEditOnAThenNavigationToBDuringAwait() async throws {
        let harness = try await makeHarness()
        let first = SongProject(id: "song-a", title: "A", lyrics: "saved A")
        let second = SongProject(id: "song-b", title: "B", lyrics: "saved B")
        let localAudio = Data([0x31, 0x32, 0x33, 0x34])
        let recordingURL = try RecordingFiles.localURL(
            projectId: first.id, fileName: "late-take.m4a", memosRoot: harness.memosRoot
        )
        try FileManager.default.createDirectory(at: recordingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try localAudio.write(to: recordingURL)
        harness.context.insert(first)
        harness.context.insert(second)
        try harness.context.save()
        // As the app wires it: the editor and the backup share one library.
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service, recordingLibrary: harness.service.library)
        viewModel.modelContext = harness.context
        await viewModel.recordingsLaunchTask?.value
        viewModel.loadProject(first)
        let remote = SyncBlob(projects: [
            SyncSongProject(id: first.id, title: "Remote A", lyrics: "remote A", theme: "",
                            updatedAt: Date().addingTimeInterval(3_600))
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        harness.drive.beforeManifestWrite = {
            viewModel.lyrics = "late edit on A"
            viewModel.triggerAutoSave()
            viewModel.loadProject(second)
        }
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        #expect(projects.first(where: { $0.id == first.id })?.lyrics == "remote A")
        #expect(projects.first(where: { $0.id == second.id })?.lyrics == "saved B")
        #expect(viewModel.currentProjectId == second.id && viewModel.lyrics == "saved B")
        let recovered = try #require(projects.first { $0.id != first.id && $0.id != second.id && $0.lyrics == "late edit on A" })
        #expect(harness.audios(recovered.id) == [localAudio])
        // The copy is taken in with the name it had.
        #expect(await viewModel.reconcileRecordings())
        let recoveredNames = try harness.context.fetch(FetchDescriptor<Recording>()).filter { $0.projectId == recovered.id }.map(\.displayName)
        #expect(recoveredNames == ["late-take.m4a"])
    }

    @MainActor
    @Test func restoreKeepsEditedBAfterRecoveringOutgoingA() async throws {
        let harness = try await makeHarness()
        let first = SongProject(id: "song-a", title: "A", lyrics: "saved A")
        let second = SongProject(id: "song-b", title: "B", lyrics: "saved B")
        harness.context.insert(first)
        harness.context.insert(second)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(first)
        viewModel.lyrics = "pending A"
        let remote = SyncBlob(projects: [
            SyncSongProject(id: first.id, title: "Remote A", lyrics: "remote A", theme: "",
                            updatedAt: Date().addingTimeInterval(3_600))
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        harness.drive.beforeManifestWrite = {
            viewModel.loadProject(second)
            viewModel.lyrics = "pending B"
            viewModel.triggerAutoSave()
        }
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        #expect(projects.first(where: { $0.id == first.id })?.lyrics == "remote A")
        #expect(projects.first(where: { $0.id == second.id })?.lyrics == "pending B")
        #expect(viewModel.currentProjectId == second.id)
        #expect(viewModel.lyrics == "pending B")
        #expect(projects.contains { $0.id != first.id && $0.id != second.id && $0.lyrics == "pending A" })
    }

    @MainActor
    @Test(arguments: ["update", "tombstone", "outgoingA", "failedRecoverySave"])
    func restoreKeepsDestinationRecordingsWithDestinationDraft(_ mode: String) async throws {
        let harness = try await makeHarness()
        let first = SongProject(id: "song-a", title: "A", lyrics: "saved A")
        let second = SongProject(id: "song-b", title: "B", lyrics: "saved B")
        let firstAudio = Data([0xa1, 0xa2, 0xa3])
        let secondAudio = Data([0xb1, 0xb2, 0xb3])
        for (project, bytes) in [(first, firstAudio), (second, secondAudio)] {
            let url = try RecordingFiles.localURL(
                projectId: project.id, fileName: "take.m4a", memosRoot: harness.memosRoot
            )
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            harness.context.insert(project)
        }
        try harness.context.save()
        var rejectedRecovery = false
        let viewModel = EditorViewModel(
            keychainStore: InMemoryKeychainStore(), backupService: harness.service,
            saveModelContext: { context in
                if mode == "failedRecoverySave" && !rejectedRecovery,
                   try context.fetch(FetchDescriptor<SongProject>()).contains(where: {
                       $0.id != first.id && $0.id != second.id && $0.lyrics == "pending B"
                   }) {
                    rejectedRecovery = true
                    throw CocoaError(.fileWriteUnknown)
                }
                try context.save()
            }
        )
        viewModel.modelContext = harness.context
        viewModel.loadProject(first)
        if mode == "outgoingA" { viewModel.lyrics = "pending A" }

        let remote: SyncBlob
        if mode == "update" {
            remote = SyncBlob(projects: [
                SyncSongProject(id: second.id, title: "Remote B", lyrics: "remote B", theme: "",
                                updatedAt: Date().addingTimeInterval(3_600))
            ])
        } else {
            remote = SyncBlob(deletions: [
                SyncDeletion(projectId: second.id,
                             deletedAt: Int64(Date().timeIntervalSince1970 * 1_000) + 3_600_000)
            ])
        }
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        harness.drive.beforeManifestWrite = {
            viewModel.loadProject(second)
            viewModel.lyrics = "pending B"
            viewModel.triggerAutoSave()
        }
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        if mode == "failedRecoverySave" {
            #expect(rejectedRecovery)
            #expect(viewModel.cloudBackupLastResultIsError)
            #expect(viewModel.currentProjectId == nil)
            #expect(viewModel.lyrics == "pending B")
            viewModel.triggerAutoSave()
            await viewModel.waitForPendingAutoSaveForTesting()
        } else {
            #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        }

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        let recoveredB = try #require(projects.first {
            $0.id != first.id && $0.id != second.id && $0.lyrics == "pending B"
        })
        #expect(viewModel.currentProjectId == recoveredB.id)
        #expect(viewModel.saveStatus == .saved)
        #expect(harness.audios(recoveredB.id) == [secondAudio])
        if mode == "update" {
            #expect(projects.first(where: { $0.id == second.id })?.lyrics == "remote B")
        } else {
            #expect(projects.first(where: { $0.id == second.id }) == nil)
            #expect(try harness.context.fetch(FetchDescriptor<SyncDeletionRecord>()).contains { $0.projectId == second.id })
            #expect(harness.audios(second.id).isEmpty)
        }
        if mode == "outgoingA" {
            let recoveredA = try #require(projects.first {
                $0.id != first.id && $0.id != second.id && $0.id != recoveredB.id && $0.lyrics == "pending A"
            })
            #expect(harness.audios(recoveredA.id) == [firstAudio])
        } else {
            #expect(harness.audios(first.id) == [firstAudio])
        }
    }

    @MainActor
    @Test func restoreDoesNotAutosaveOverAppliedRemoteRowDuringRecordingAwait() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "song-a", title: "A", lyrics: "saved A")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        let remote = SyncBlob(
            projects: [SyncSongProject(id: project.id, title: "Remote A", lyrics: "remote A", theme: "",
                                       updatedAt: Date().addingTimeInterval(3_600))],
            recordings: [Self.lateTake.entry],
            deletions: [SyncDeletion(projectId: "cleanup", deletedAt: Int64(Date().timeIntervalSince1970 * 1_000) + 3_600_000)]
        )
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        harness.drive.seed(name: Self.lateTake.entry.driveName, content: Self.lateTake.audio)
        harness.drive.afterManifestWrite = {
            viewModel.lyrics = "late local A"
            viewModel.triggerAutoSave()
            await viewModel.waitForPendingAutoSaveForTesting()
        }
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        #expect(projects.first(where: { $0.id == project.id })?.lyrics == "remote A")
        #expect(viewModel.lyrics == "late local A")
        #expect(viewModel.currentProjectId != project.id)
        #expect(projects.first(where: { $0.id == viewModel.currentProjectId })?.lyrics == "late local A")
    }

    @MainActor
    @Test func restoreFailureAfterApplyKeepsRemoteAndLateLocalDraft() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "song-a", title: "A", lyrics: "saved A")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        let remote = SyncBlob(
            projects: [SyncSongProject(id: project.id, title: "Remote A", lyrics: "remote A", theme: "",
                                       updatedAt: Date().addingTimeInterval(3_600))],
            recordings: [Self.lateTake.entry],
            deletions: [SyncDeletion(projectId: "cleanup", deletedAt: Int64(Date().timeIntervalSince1970 * 1_000) + 3_600_000)]
        )
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        harness.drive.seed(name: Self.lateTake.entry.driveName, content: Self.lateTake.audio)
        harness.drive.afterManifestWrite = {
            viewModel.lyrics = "late local A"
            viewModel.triggerAutoSave()
            await viewModel.waitForPendingAutoSaveForTesting()
            throw BackupError.network("Synthetic failure after apply")
        }
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(viewModel.cloudBackupLastResultIsError)
        #expect(projects.first(where: { $0.id == project.id })?.lyrics == "remote A")
        #expect(viewModel.lyrics == "late local A")
        #expect(viewModel.currentProjectId != project.id)
        #expect(projects.first(where: { $0.id == viewModel.currentProjectId })?.lyrics == "late local A")
    }

    @MainActor
    @Test(arguments: ["restoreRemote", "restoreTombstone"])
    func failedRecoverySaveKeepsRemoteIdentityAndAllowsOrdinaryRetry(_ mode: String) async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "song-a", title: "A", lyrics: "saved A")
        let localAudio = Data([0x11, 0x22, 0x33, 0x44])
        let recordingURL = try RecordingFiles.localURL(
            projectId: project.id, fileName: "original-take.m4a", memosRoot: harness.memosRoot
        )
        try FileManager.default.createDirectory(at: recordingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try localAudio.write(to: recordingURL)
        harness.context.insert(project)
        try harness.context.save()
        var saveAttempts = 0
        var failedRecoverySave = false
        let viewModel = EditorViewModel(
            keychainStore: InMemoryKeychainStore(),
            backupService: harness.service,
            saveModelContext: { context in
                saveAttempts += 1
                if saveAttempts == 2 {
                    failedRecoverySave = true
                    throw CocoaError(.fileWriteUnknown)
                }
                try context.save()
            }
        )
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        saveAttempts = 0
        viewModel.lyrics = "pending local A"
        let remote: SyncBlob
        if mode == "restoreTombstone" {
            remote = SyncBlob(deletions: [
                SyncDeletion(projectId: project.id, deletedAt: Int64(Date().timeIntervalSince1970 * 1_000) + 3_600_000)
            ])
        } else {
            remote = SyncBlob(projects: [
                SyncSongProject(id: project.id, title: "Remote A", lyrics: "remote A", theme: "",
                                updatedAt: Date().addingTimeInterval(3_600))
            ])
        }
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        #expect(failedRecoverySave && saveAttempts == 2)
        #expect(viewModel.cloudBackupLastResultIsError)
        #expect(viewModel.currentProjectId == nil)
        #expect(!viewModel.showWelcome)
        #expect(viewModel.saveStatus == .idle)
        #expect(viewModel.lyrics == "pending local A")
        var projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        if mode == "restoreTombstone" {
            #expect(projects.first(where: { $0.id == project.id }) == nil)
            #expect(try harness.context.fetch(FetchDescriptor<SyncDeletionRecord>()).contains { $0.projectId == project.id })
        } else {
            #expect(projects.first(where: { $0.id == project.id })?.lyrics == "remote A")
        }
        #expect(!projects.contains { $0.id != project.id && $0.lyrics == "pending local A" })

        viewModel.triggerAutoSave()
        await viewModel.waitForPendingAutoSaveForTesting()

        projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(viewModel.saveStatus == .saved)
        #expect(viewModel.currentProjectId != nil && viewModel.currentProjectId != project.id)
        #expect(projects.first(where: { $0.id == viewModel.currentProjectId })?.lyrics == "pending local A")
        #expect(harness.audios(try #require(viewModel.currentProjectId)) == [localAudio])
        if mode == "restoreTombstone" {
            #expect(projects.first(where: { $0.id == project.id }) == nil)
            #expect(try harness.context.fetch(FetchDescriptor<SyncDeletionRecord>()).contains { $0.projectId == project.id })
            #expect(harness.audios(project.id).isEmpty)
        } else {
            #expect(projects.first(where: { $0.id == project.id })?.lyrics == "remote A")
        }
    }

    @MainActor
    @Test func manualBackupFlushesPendingEditAndLeavesTheLibraryAlone() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "song-a", title: "A", lyrics: "saved A")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        viewModel.lyrics = "pending local A"
        let remote = SyncBlob(projects: [
            SyncSongProject(id: project.id, title: "Remote A", lyrics: "remote A", theme: "",
                            updatedAt: Date().addingTimeInterval(3_600))
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        viewModel.refreshCloudBackupState()

        await viewModel.backUpNow()

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        #expect(projects.map(\.lyrics) == ["pending local A"])
        #expect(viewModel.lyrics == "pending local A")
        #expect(viewModel.currentProjectId == project.id)
        // The newer Drive copy stays in the backup; it reaches this device only on restore.
        let manifest = try SyncBlob.decodeManifest(try #require(harness.drive.content(named: SyncBlob.driveFileName)))
        #expect(manifest.projects.map(\.lyrics) == ["remote A"])
    }

    @MainActor
    @Test func manualBackupPreservesOutgoingAWhenSwitchingToBDuringAwait() async throws {
        let harness = try await makeHarness()
        let first = SongProject(id: "song-a", title: "A", lyrics: "saved A")
        let second = SongProject(id: "song-b", title: "B", lyrics: "saved B")
        harness.context.insert(first)
        harness.context.insert(second)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(first)
        viewModel.lyrics = "pending A"
        let remote = SyncBlob(projects: [
            SyncSongProject(id: first.id, title: "Remote A", lyrics: "remote A", theme: "",
                            updatedAt: Date().addingTimeInterval(3_600))
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        harness.drive.beforeManifestWrite = { viewModel.loadProject(second) }
        viewModel.refreshCloudBackupState()

        await viewModel.backUpNow()

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        #expect(projects.first(where: { $0.id == first.id })?.lyrics == "pending A")
        #expect(projects.first(where: { $0.id == second.id })?.lyrics == "saved B")
        #expect(viewModel.currentProjectId == second.id)
        #expect(projects.count == 2)
    }

    @MainActor
    @Test func backgroundBackupFlushesPendingOpenDraftBeforeMerge() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "song-a", title: "A", lyrics: "saved A")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        viewModel.lyrics = "pending local A"
        let remote = SyncBlob(projects: [
            SyncSongProject(id: project.id, title: "Remote A", lyrics: "remote A", theme: "",
                            updatedAt: Date().addingTimeInterval(3_600))
        ])
        harness.drive.seed(name: SyncBlob.driveFileName,
                           content: try remote.encodedManifest())
        viewModel.refreshCloudBackupState()

        await viewModel.runCloudBackupOnBackgroundIfPossible()

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(!viewModel.cloudBackupLastResultIsError, "\(viewModel.cloudBackupStatusText)")
        #expect(projects.map(\.lyrics) == ["pending local A"])
        #expect(viewModel.currentProjectId == project.id)
        #expect(harness.service.lastBackupAt != nil)
    }

    @MainActor
    @Test func failedRestoreLeavesOpenBufferAndPendingEditSavedLocally() async throws {
        let harness = try await makeHarness()
        let project = SongProject(id: "open-song", title: "Local", lyrics: "saved line", theme: "calm")
        harness.context.insert(project)
        try harness.context.save()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        viewModel.loadProject(project)
        viewModel.lyrics = "pending line before failed restore"
        viewModel.triggerAutoSave()
        viewModel.refreshCloudBackupState()

        await viewModel.restoreBackupNow()

        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(viewModel.cloudBackupLastResultIsError)
        #expect(viewModel.currentProjectId == project.id)
        #expect(viewModel.lyrics == "pending line before failed restore")
        #expect(projects.first(where: { $0.id == project.id })?.lyrics == "pending line before failed restore")
    }

    @MainActor
    private func makeHarness() async throws -> BackupHarness {
        try await makeHarness(oauthProvider: FakeOAuthProvider())
    }

    @MainActor
    private func makeHarness(oauthProvider: OAuthAccessTokenProvider, drive shared: FakeDriveClient? = nil) async throws -> BackupHarness {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("BackupCoreTests-\(UUID().uuidString)", isDirectory: true)
        let memosRoot = scratch.appendingPathComponent("voice-memos", isDirectory: true)
        let drive = shared ?? FakeDriveClient()
        let secrets = FakeBackupSecretStore()
        let service = BackupService(
            driveClient: drive,
            oauthProvider: oauthProvider,
            secretStore: secrets,
            defaults: UserDefaults(suiteName: "BackupCoreTests-\(UUID().uuidString)")!,
            memosRoot: memosRoot,
            trashRoot: scratch.appendingPathComponent("voice-memos-trash", isDirectory: true)
        )
        service.library.context = container.mainContext
        // Changes need a successful check of the recordings (A33).
        try await service.library.reconcile(context: container.mainContext)
        return BackupHarness(container: container, drive: drive, secrets: secrets, service: service, memosRoot: memosRoot)
    }
}

@MainActor
private struct BackupHarness {
    let container: ModelContainer
    let drive: FakeDriveClient
    let secrets: FakeBackupSecretStore
    let service: BackupService
    let memosRoot: URL

    var context: ModelContext { container.mainContext }

    /// A finished memo, as the recorder or an import leaves it; the app's
    /// recordings library picks it up straight away.
    func writeMemo(_ data: Data, projectId: String, fileName: String) async throws {
        try writeFile(data, projectId: projectId, fileName: fileName)
        try await service.library.reconcile(context: context)
    }

    func rowId(_ displayName: String) throws -> String {
        try #require(try context.fetch(FetchDescriptor<Recording>()).first { $0.displayName == displayName && $0.trashedAt == nil }?.id)
    }

    /// A recording's file: `<id>.m4a` in its song's folder (A36).
    func file(_ id: String, _ projectId: String) -> URL {
        memosRoot.appendingPathComponent("\(projectId)/\(id).m4a")
    }

    /// The audio of every file in a song's folder.
    func audios(_ projectId: String) -> Set<Data> {
        let folder = memosRoot.appendingPathComponent(projectId, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.compactMap { try? Data(contentsOf: folder.appendingPathComponent($0)) })
    }

    func writeFile(_ data: Data, projectId: String, fileName: String) throws {
        let url = try RecordingFiles.localURL(projectId: projectId, fileName: fileName, memosRoot: memosRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// A v3 manifest under RAI3 and one RAI1 recording, as the passphrase builds wrote them.
    func seedLegacyBackup(audio: Data) throws {
        let entry = SyncRecordingManifestEntry(
            projectId: "old-song", fileName: "take.m4a",
            driveName: RecordingBackupManifest.legacyDriveName(projectId: "old-song", fileName: "take.m4a"),
            sizeBytes: Int64(audio.count), modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sha256: RecordingBackupManifest.sha256Hex(audio)
        )
        let legacy = LegacySyncBlob(
            projects: [SyncSongProject(id: "old-song", title: "Old Song", lyrics: "from the old backup", theme: "", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))],
            recordings: [entry],
            savedAt: Date(timeIntervalSince1970: 1_700_000_000),
            savedByClientId: "old-device"
        )
        drive.seed(name: LegacySyncBlob.driveFileName, content: try SyncRepairContractChecks.rawEnvelope(SyncJSON.encoder.encode(legacy), magic: "RAI3"))
        drive.seed(name: entry.driveName, content: try SyncRepairContractChecks.rawEnvelope(audio, magic: "RAI1"))
    }
}

private final class FakeOAuthProvider: OAuthAccessTokenProvider {
    var isConfigured = true
    var hasRefreshToken = true
    var accessTokenError: Error?
    private(set) var revokeCalls = 0

    func accessToken(interactive: Bool) async throws -> String {
        if let accessTokenError { throw accessTokenError }
        return "fake-token"
    }

    func revokeAndForget() async -> Bool {
        revokeCalls += 1
        hasRefreshToken = false
        return true
    }
}

private final class FakeBackupSecretStore: BackupSecretStore {
    private var values: [String: String] = [:]

    func string(for key: String) -> String? {
        values[key]
    }

    func setString(_ value: String, for key: String) {
        values[key] = value
    }

    func deleteString(for key: String) {
        values.removeValue(forKey: key)
    }
}

/// What a stubbed endpoint received. Each stub subclass has its own, so the
/// parameterized revoke cases can run in parallel without sharing state.
private final class StubLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(request: URLRequest, body: String)] = []

    func record(_ request: URLRequest, body: String) { lock.withLock { entries.append((request, body)) } }
    func reset() { lock.withLock { entries = [] } }
    var requests: [URLRequest] { lock.withLock { entries.map(\.request) } }
    var bodies: [String] { lock.withLock { entries.map(\.body) } }
}

/// Answers every request offline with the subclass's status code.
private class RevokeStub: URLProtocol, @unchecked Sendable {
    nonisolated class var status: Int { 200 }
    nonisolated class var log: StubLog { fatalError("use a subclass") }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        let stub = type(of: self)
        stub.log.record(request, body: String(decoding: body ?? Data(), as: UTF8.self))
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}
}

private final class RevokeAccepted: RevokeStub, @unchecked Sendable {
    nonisolated static let shared = StubLog()
    nonisolated override class var status: Int { 200 }
    nonisolated override class var log: StubLog { shared }
}

private final class RevokeUnavailable: RevokeStub, @unchecked Sendable {
    nonisolated static let shared = StubLog()
    nonisolated override class var status: Int { 503 }
    nonisolated override class var log: StubLog { shared }
}

private final class PagingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var pageTokens: [String?] = []

    static func reset() { pageTokens = [] }

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        let token = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageToken" }?.value
        Self.pageTokens.append(token)
        let body = token == nil
            ? #"{"nextPageToken":"page-2","files":[{"id":"1","name":"rec_a_1.m4a"}]}"#
            : #"{"files":[{"id":"2","name":"rec_b_2.m4a"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}
}

private final class FakeDriveClient: DriveAppDataClient {
    private struct StoredFile {
        var file: DriveAppDataFile
        var content: Data
    }

    private var filesByName: [String: StoredFile] = [:]
    private var findCountsByName: [String: Int] = [:]
    private var replacementsByFindCount: [String: [Int: Data]] = [:]
    private var deleteFailuresByName: [String: Int] = [:]
    private var uploadsByName: [String: Int] = [:]
    private var manifestWritten = false
    var beforeManifestWrite: (@MainActor () throws -> Void)?
    /// Runs once, when the first recording is uploaded: another device writing meanwhile.
    var duringRecordingUpload: (@MainActor () throws -> Void)?
    /// Runs once, when the recording upload with that number (from 1) starts.
    var duringRecordingUploadNumber: [Int: @MainActor () throws -> Void] = [:]
    private var recordingUploads = 0
    /// Runs at the first download after the manifest upload: an await after the merge is applied.
    var afterManifestWrite: (@MainActor () async throws -> Void)?

    var uploadCount: Int { uploadsByName.values.reduce(0, +) }
    /// Manifests another device writes between this device's write and its read-back.
    var concurrentWrites: [Data] = []
    private var extraFiles: [StoredFile] = []

    /// A second file with the manifest's name, as two devices creating it at once leave.
    func seedDuplicateManifest(_ content: Data) {
        extraFiles.append(StoredFile(file: DriveAppDataFile(id: UUID().uuidString, name: SyncBlob.driveFileName, modifiedTime: "dup", version: "1"), content: content))
    }

    var manifestCount: Int { (filesByName[SyncBlob.driveFileName] == nil ? 0 : 1) + extraFiles.count }

    /// A second raw object under a recording's name (two uploads at once), with the given id.
    func seedDuplicateRecording(_ entry: SyncRecording, content: Data, id: String) {
        let properties = ["id": entry.id, "projectId": entry.projectId, "fileName": entry.fileName, "sha256": entry.sha256, "bytes": String(entry.bytes)]
        extraFiles.append(StoredFile(file: DriveAppDataFile(id: id, name: entry.driveName, modifiedTime: "dup", version: "1", appProperties: properties), content: content))
    }

    func objects(named name: String) -> Int { (filesByName[name] == nil ? 0 : 1) + extraFiles.filter { $0.file.name == name }.count }

    /// Every object's content under a name, the older first.
    func contents(named name: String) -> [Data] { extraFiles.filter { $0.file.name == name }.map(\.content) + (filesByName[name].map { [$0.content] } ?? []) }

    func uploads(named name: String) -> Int { uploadsByName[name] ?? 0 }

    func seed(name: String, content: Data, appProperties: [String: String]? = nil) {
        let file = DriveAppDataFile(id: UUID().uuidString, name: name, modifiedTime: "seed-\(UUID().uuidString)", version: UUID().uuidString, appProperties: appProperties)
        filesByName[name] = StoredFile(file: file, content: content)
    }

    /// Raw recording audio as a v4 writer leaves it, with its properties.
    func seedRecording(_ entry: SyncRecording, content: Data) {
        seed(name: entry.driveName, content: content, appProperties: [
            "id": entry.id, "projectId": entry.projectId, "fileName": entry.fileName, "sha256": entry.sha256, "bytes": String(entry.bytes),
        ])
    }

    func content(named name: String) -> Data? {
        filesByName[name]?.content
    }

    func appProperties(named name: String) -> [String: String]? {
        filesByName[name]?.file.appProperties
    }

    func replace(name: String, onFind findCount: Int, content: Data) {
        replacementsByFindCount[name, default: [:]][findCount] = content
    }

    func failNextDelete(named name: String) {
        deleteFailuresByName[name, default: 0] += 1
    }

    func findFile(named name: String, accessToken: String) async throws -> DriveAppDataFile? {
        let findCount = (findCountsByName[name] ?? 0) + 1
        findCountsByName[name] = findCount
        if let replacement = replacementsByFindCount[name]?[findCount] {
            seed(name: name, content: replacement)
        }
        return filesByName[name]?.file
    }

    func listFiles(prefix: String, accessToken: String) async throws -> [DriveAppDataFile] {
        (filesByName.values.map(\.file) + extraFiles.map(\.file)).filter { $0.name.hasPrefix(prefix) }
    }

    func downloadFile(id: String, accessToken: String) async throws -> Data {
        if let extra = extraFiles.first(where: { $0.file.id == id }) { return extra.content }
        guard let (name, stored) = filesByName.first(where: { $0.value.file.id == id }).map({ ($0.key, $0.value) }) else {
            throw BackupError.noRemoteBackup
        }
        if manifestWritten, name != SyncBlob.driveFileName, let hook = afterManifestWrite {
            afterManifestWrite = nil
            try await hook()
        }
        if name == SyncBlob.driveFileName, manifestWritten, let concurrent = concurrentWrites.first {
            // Another device wrote right after this one: its manifest is what reads back.
            concurrentWrites.removeFirst()
            filesByName[name] = StoredFile(file: DriveAppDataFile(id: stored.file.id, name: name, modifiedTime: "concurrent", version: UUID().uuidString), content: concurrent)
            return concurrent
        }
        return stored.content
    }

    func uploadNewFile(named name: String, mimeType: String, content: Data, appProperties: [String: String]?, accessToken: String) async throws -> DriveAppDataFile {
        try await runManifestWriteHookIfNeeded(name: name)
        if name.hasPrefix("rec_"), let hook = duringRecordingUpload {
            duringRecordingUpload = nil
            try await MainActor.run { try hook() }
        }
        if name.hasPrefix("rec_") {
            recordingUploads += 1
            if let hook = duringRecordingUploadNumber.removeValue(forKey: recordingUploads) {
                try await MainActor.run { try hook() }
            }
        }
        let file = DriveAppDataFile(id: UUID().uuidString, name: name, modifiedTime: "upload-\(UUID().uuidString)", version: UUID().uuidString, appProperties: appProperties)
        // As on Drive, a new file beside any other with the same name.
        if name.hasPrefix("rec_"), let existing = filesByName[name] { extraFiles.append(existing) }
        filesByName[name] = StoredFile(file: file, content: content)
        uploadsByName[name, default: 0] += 1
        return file
    }

    func updateFile(id: String, mimeType: String, content: Data, appProperties: [String: String]?, accessToken: String) async throws -> DriveAppDataFile {
        guard let name = filesByName.first(where: { $0.value.file.id == id })?.key else { throw BackupError.invalidResponse }
        try await runManifestWriteHookIfNeeded(name: name)
        let existing = filesByName[name]?.file
        let file = DriveAppDataFile(
            id: existing?.id ?? id,
            name: existing?.name ?? name,
            modifiedTime: "update-\(UUID().uuidString)",
            version: UUID().uuidString,
            appProperties: appProperties ?? existing?.appProperties
        )
        filesByName[name] = StoredFile(file: file, content: content)
        uploadsByName[name, default: 0] += 1
        return file
    }

    func deleteFile(id: String, accessToken: String) async throws {
        if let index = extraFiles.firstIndex(where: { $0.file.id == id }) {
            extraFiles.remove(at: index)
            return
        }
        guard let name = filesByName.first(where: { $0.value.file.id == id })?.key else { return }
        if let failures = deleteFailuresByName[name], failures > 0 {
            deleteFailuresByName[name] = failures - 1
            throw BackupError.network("Synthetic recording cleanup failure")
        }
        filesByName.removeValue(forKey: name)
    }

    private func runManifestWriteHookIfNeeded(name: String) async throws {
        guard name == SyncBlob.driveFileName else { return }
        manifestWritten = true
        guard let hook = beforeManifestWrite else { return }
        beforeManifestWrite = nil
        try await MainActor.run { try hook() }
    }
}
