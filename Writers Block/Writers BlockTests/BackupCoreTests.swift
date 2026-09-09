import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import Writers_Block

struct BackupCoreTests {
    private let passphrase = "correct horse battery staple"
    private let plaintext = Data(#"{"version":1,"projects":[],"trashed":[],"recordings":[],"savedAt":1700000000000,"savedByClientId":"android-fixture"}"#.utf8)
    private let goldenEnvelopeBase64 = "UkFJMQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhtizcOcwuED9qmh1u+pIuacjCXfzEdC4XqsUgnAZ08InG+/2sOGiVfCbTNTgVs/qDX5tg+Xq/8BEH3xh/kmBcKKyayJPnin4qkQQO5xj50WFhaXKsgIOrAWlBrJcXMfe1Y6EmdzpzG87TFCQgajLtF4GAU5Pgh+VRicHt164bxqXJ5xxeE="

    @Test func opensAndroidCompatibleRAI1Fixture() throws {
        let envelope = try #require(Data(base64Encoded: goldenEnvelopeBase64))

        let opened = try SyncBlobCrypto.open(envelope, passphrase: passphrase)

        #expect(opened == plaintext)
    }

    @Test func deterministicSealMatchesRAI1GoldenVector() throws {
        let salt = Data((0..<16).map(UInt8.init))
        let iv = Data((0x10..<0x1c).map(UInt8.init))

        let sealed = try SyncBlobCrypto.seal(plaintext, passphrase: passphrase, salt: salt, iv: iv)

        #expect(sealed.base64EncodedString() == goldenEnvelopeBase64)
    }

    @Test func wrongPassphraseAndTamperFailClosed() throws {
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

    @Test func nonAsciiPassphraseIsRejectedBeforeDerivation() throws {
        let envelope = try #require(Data(base64Encoded: goldenEnvelopeBase64))
        #expect(throws: SyncBlobCryptoError.nonPortablePassphrase) {
            _ = try SyncBlobCrypto.seal(plaintext, passphrase: "café")
        }
        #expect(throws: SyncBlobCryptoError.nonPortablePassphrase) {
            _ = try SyncBlobCrypto.open(envelope, passphrase: "café")
        }
    }

    @MainActor
    @Test func syncBlobEncodesEpochMillisecondsAndRecordingManifest() throws {
        let project = SyncSongProject(
            id: "project-1",
            title: "Title",
            lyrics: "Lyrics",
            theme: "Noir",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let trash = SyncTrashedSongProject(
            id: "trash-1",
            title: "Old",
            lyrics: "Draft",
            theme: "Warm",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            deletedAt: Date(timeIntervalSince1970: 1_700_000_002),
            deleteAfter: Date(timeIntervalSince1970: 1_700_000_003)
        )
        let recording = SyncRecordingManifestEntry(
            projectId: "project-1",
            fileName: "take 1.m4a",
            driveName: "rec_project-1_take 1.m4a.enc",
            sizeBytes: 42,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_004),
            sha256: "abc123"
        )
        let blob = SyncBlob(
            projects: [project],
            trashed: [trash],
            recordings: [recording],
            savedAt: Date(timeIntervalSince1970: 1_700_000_005),
            savedByClientId: "ios-test"
        )

        let data = try SyncJSON.encoder.encode(blob)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains(#""updatedAt":1700000000000"#))
        #expect(json.contains(#""deletedAt":1700000002000"#))
        #expect(json.contains(#""deleteAfter":1700000003000"#))
        #expect(json.contains(#""project":{"id":"trash-1""#))
        #expect(json.contains(#""modifiedAt":1700000004000"#))
        #expect(json.contains(#""savedAt":1700000005000"#))
        #expect(json.contains(#""recordings""#))
        #expect(json.contains(#""driveName":"rec_project-1_take 1.m4a.enc""#))

        let decoded = try SyncJSON.decoder.decode(SyncBlob.self, from: data)
        #expect(decoded.projects.first?.updatedAt == project.updatedAt)
        #expect(decoded.trashed.first?.deletedAt == trash.deletedAt)
        #expect(decoded.recordings.first?.modifiedAt == recording.modifiedAt)
    }

    @MainActor
    @Test func oldSyncBlobJSONDefaultsRecordingsToEmpty() throws {
        let oldJSON = Data(#"{"version":1,"projects":[],"trashed":[],"savedAt":1700000000000,"savedByClientId":"old"}"#.utf8)

        let decoded = try SyncJSON.decoder.decode(SyncBlob.self, from: oldJSON)

        #expect(decoded.recordings.isEmpty)
    }

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

    @Test func oauthCallbackRequiresMatchingState() throws {
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
    @Test func shortCloudBackupPassphraseIsRejectedBeforeStorage() {
        let backupService = FakeCloudBackupService()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: backupService)

        viewModel.updateCloudBackupPassphrase("  short  ")

        #expect(backupService.updatedPassphrase == nil)
        #expect(viewModel.cloudBackupLastResultIsError)
        #expect(viewModel.cloudBackupStatusText == "Use at least 8 characters (printable ASCII) so your backup restores on any device.")
    }

    @MainActor
    @Test func tabAndNewlinePaddedPassphraseIsAcceptedAfterTrim() {
        let backupService = FakeCloudBackupService()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: backupService)

        viewModel.updateCloudBackupPassphrase("\t validpass1 \n")

        #expect(backupService.updatedPassphrase == "validpass1")
        #expect(!viewModel.cloudBackupLastResultIsError)
    }

    @MainActor
    @Test func interiorTabPassphraseIsRejected() {
        let backupService = FakeCloudBackupService()
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: backupService)

        viewModel.updateCloudBackupPassphrase("valid\tpass1")

        #expect(backupService.updatedPassphrase == nil)
        #expect(viewModel.cloudBackupLastResultIsError)
        #expect(viewModel.cloudBackupStatusText == "Use at least 8 characters (printable ASCII) so your backup restores on any device.")
    }

    @MainActor
    @Test func backgroundBackupFailureIsPersistedForRefresh() async throws {
        let oauthProvider = FakeOAuthProvider()
        oauthProvider.accessTokenError = BackupError.network("offline")
        let harness = try makeHarness(oauthProvider: oauthProvider)
        try harness.service.updatePassphrase(passphrase)

        await harness.service.backupInBackgroundIfPossible(modelContext: harness.context)

        #expect(harness.service.backgroundBackupFailureDescription == "offline")
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), backupService: harness.service)
        viewModel.modelContext = harness.context
        #expect(viewModel.cloudBackupLastResultIsError)
        #expect(viewModel.cloudBackupStatusText == "Background backup failed: offline")
    }

    @Test func recordingRemoteNameUsesProjectAndFileStem() {
        let url = URL(fileURLWithPath: "/tmp/voice-memos/project-1/take 1.m4a")

        let driveName = RecordingBackupManifest.driveName(projectId: "project-1", localURL: url)

        #expect(driveName == "rec_project-1_take 1.m4a.enc")
    }

    @MainActor
    @Test func backupUploadsEncryptedProjectsAndRecordingsWithoutAPIKeys() async throws {
        let harness = try makeHarness()
        let project = SongProject(
            id: "project-1",
            title: "Hook",
            lyrics: "secret lyric",
            theme: "dark",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        harness.context.insert(project)
        try harness.context.save()

        let projectFolder = harness.memosRoot.appendingPathComponent(project.id, isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let memoURL = projectFolder.appendingPathComponent("take 1.m4a")
        let memoData = Data([0, 1, 2, 3, 4, 5])
        try memoData.write(to: memoURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_011)], ofItemAtPath: memoURL.path)

        try harness.service.updatePassphrase(passphrase)

        try await harness.service.backupNow(modelContext: harness.context)

        let blobEnvelope = try #require(harness.drive.content(named: SyncBlob.driveFileName))
        let blob = try SyncBlobCrypto.openManifest(blobEnvelope, passphrase: passphrase)
        #expect(blob.projects.map(\.id) == ["project-1"])
        #expect(blob.recordings.map(\.driveName) == ["rec_project-1_take 1.m4a.enc"])
        #expect(String(data: try SyncJSON.encoder.encode(blob), encoding: .utf8)?.contains("apiKey") == false)

        let recordingEnvelope = try #require(harness.drive.content(named: "rec_project-1_take 1.m4a.enc"))
        let recordingPlaintext = try SyncBlobCrypto.open(recordingEnvelope, passphrase: passphrase)
        #expect(recordingPlaintext == memoData)
    }

    @MainActor
    @Test func backupMergesExistingRemoteManifestBeforeUploading() async throws {
        let harness = try makeHarness()
        let localProject = SongProject(
            id: "local-project",
            title: "Local Hook",
            lyrics: "local lyric",
            theme: "dark",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_040)
        )
        harness.context.insert(localProject)
        try harness.context.save()

        let remoteBlob = SyncBlob(
            projects: [
                SyncSongProject(
                    id: "remote-project",
                    title: "Remote Verse",
                    lyrics: "remote lyric",
                    theme: "blue",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_041)
                )
            ],
            savedAt: Date(timeIntervalSince1970: 1_700_000_042),
            savedByClientId: "remote-client"
        )
        harness.drive.seed(
            name: SyncBlob.driveFileName,
            content: try SyncBlobCrypto.sealManifest(remoteBlob, passphrase: passphrase)
        )
        try harness.service.updatePassphrase(passphrase)

        try await harness.service.backupNow(modelContext: harness.context)

        let uploadedEnvelope = try #require(harness.drive.content(named: SyncBlob.driveFileName))
        let uploadedBlob = try SyncBlobCrypto.openManifest(uploadedEnvelope, passphrase: passphrase)
        #expect(Set(uploadedBlob.projects.map(\.id)) == Set(["local-project", "remote-project"]))
    }

    @MainActor
    @Test func backupFailsClosedWhenRemoteManifestDecryptsButDoesNotDecode() async throws {
        let harness = try makeHarness()
        let project = SongProject(
            id: "local-project",
            title: "Local Hook",
            lyrics: "local lyric",
            theme: "dark",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_050)
        )
        harness.context.insert(project)
        try harness.context.save()

        let corruptEnvelope = try SyncBlobCrypto.seal(Data("{".utf8), passphrase: passphrase)
        harness.drive.seed(name: SyncBlob.driveFileName, content: corruptEnvelope)
        try harness.service.updatePassphrase(passphrase)

        await #expect(throws: BackupError.corruptRemoteOrWrongPassphrase) {
            try await harness.service.backupNow(modelContext: harness.context)
        }
        #expect(harness.drive.content(named: SyncBlob.driveFileName) == corruptEnvelope)
    }

    @MainActor
    @Test func backupFailsClosedWhenRemoteManifestCannotDecrypt() async throws {
        let harness = try makeHarness()
        let project = SongProject(
            id: "local-project",
            title: "Local Hook",
            lyrics: "local lyric",
            theme: "dark",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_055)
        )
        harness.context.insert(project)
        try harness.context.save()

        let remoteBlob = SyncBlob(
            projects: [SyncSongProject(id: "remote-project", title: "Remote", lyrics: "remote", theme: "blue", updatedAt: Date(timeIntervalSince1970: 1_700_000_056))],
            savedAt: Date(timeIntervalSince1970: 1_700_000_057),
            savedByClientId: "remote-client"
        )
        let originalEnvelope = try SyncBlobCrypto.sealManifest(remoteBlob, passphrase: passphrase)
        harness.drive.seed(name: SyncBlob.driveFileName, content: originalEnvelope)
        try harness.service.updatePassphrase("wrong horse battery staple")

        await #expect(throws: BackupError.corruptRemoteOrWrongPassphrase) {
            try await harness.service.backupNow(modelContext: harness.context)
        }
        #expect(harness.drive.content(named: SyncBlob.driveFileName) == originalEnvelope)
    }

    @MainActor
    @Test func backupReMergesOnceWhenRemoteManifestMetadataChangesBeforeUpload() async throws {
        let harness = try makeHarness()
        let localProject = SongProject(
            id: "local-project",
            title: "Local Hook",
            lyrics: "local lyric",
            theme: "dark",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_060)
        )
        harness.context.insert(localProject)
        try harness.context.save()

        let initialRemoteBlob = SyncBlob(
            projects: [
                SyncSongProject(
                    id: "initial-remote-project",
                    title: "Initial Remote",
                    lyrics: "initial remote lyric",
                    theme: "blue",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_061)
                )
            ],
            savedAt: Date(timeIntervalSince1970: 1_700_000_062),
            savedByClientId: "initial-remote"
        )
        let lateRemoteBlob = SyncBlob(
            projects: [
                SyncSongProject(
                    id: "late-remote-project",
                    title: "Late Remote",
                    lyrics: "late remote lyric",
                    theme: "green",
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_063)
                )
            ],
            savedAt: Date(timeIntervalSince1970: 1_700_000_064),
            savedByClientId: "late-remote"
        )
        harness.drive.seed(
            name: SyncBlob.driveFileName,
            content: try SyncBlobCrypto.sealManifest(initialRemoteBlob, passphrase: passphrase)
        )
        harness.drive.replace(
            name: SyncBlob.driveFileName,
            onFind: 2,
            content: try SyncBlobCrypto.sealManifest(lateRemoteBlob, passphrase: passphrase)
        )
        try harness.service.updatePassphrase(passphrase)

        try await harness.service.backupNow(modelContext: harness.context)

        let uploadedEnvelope = try #require(harness.drive.content(named: SyncBlob.driveFileName))
        let uploadedBlob = try SyncBlobCrypto.openManifest(uploadedEnvelope, passphrase: passphrase)
        #expect(Set(uploadedBlob.projects.map(\.id)) == Set(["local-project", "initial-remote-project", "late-remote-project"]))
    }

    @MainActor
    @Test func restoreDownloadsMissingRecordingsNonDestructively() async throws {
        let harness = try makeHarness()
        let remoteMemo = Data([9, 8, 7, 6])
        let recording = SyncRecordingManifestEntry(
            projectId: "project-2",
            fileName: "demo.m4a",
            driveName: "rec_project-2_demo.m4a.enc",
            sizeBytes: Int64(remoteMemo.count),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_020),
            sha256: SHA256.hash(data: remoteMemo).map { String(format: "%02x", $0) }.joined()
        )
        let blob = SyncBlob(
            projects: [SyncSongProject(id: "project-2", title: "Restored", lyrics: "Lyrics", theme: "blue", updatedAt: Date(timeIntervalSince1970: 1_700_000_019))],
            recordings: [recording],
            savedAt: Date(timeIntervalSince1970: 1_700_000_021),
            savedByClientId: "remote"
        )
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlobCrypto.sealManifest(blob, passphrase: passphrase))
        harness.drive.seed(name: recording.driveName, content: try SyncBlobCrypto.seal(remoteMemo, passphrase: passphrase))
        try harness.service.updatePassphrase(passphrase)

        try await harness.service.restoreNow(modelContext: harness.context)

        let restoredURL = harness.memosRoot.appendingPathComponent("project-2", isDirectory: true).appendingPathComponent("demo.m4a")
        #expect(try Data(contentsOf: restoredURL) == remoteMemo)
        let projects = try harness.context.fetch(FetchDescriptor<SongProject>())
        #expect(projects.map(\.id) == ["project-2"])
    }

    @MainActor
    @Test func restorePushesLocalOnlyRecordingsAndMergedManifestBackToDrive() async throws {
        let harness = try makeHarness()
        let project = SongProject(
            id: "local-project",
            title: "Local Hook",
            lyrics: "local lyric",
            theme: "dark",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_070)
        )
        harness.context.insert(project)
        try harness.context.save()

        let projectFolder = harness.memosRoot.appendingPathComponent(project.id, isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let memoURL = projectFolder.appendingPathComponent("restore-push.m4a")
        let memoData = Data([4, 3, 2, 1])
        try memoData.write(to: memoURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_071)], ofItemAtPath: memoURL.path)

        let remoteBlob = SyncBlob(
            projects: [],
            recordings: [],
            savedAt: Date(timeIntervalSince1970: 1_700_000_069),
            savedByClientId: "remote"
        )
        harness.drive.seed(
            name: SyncBlob.driveFileName,
            content: try SyncBlobCrypto.sealManifest(remoteBlob, passphrase: passphrase)
        )
        try harness.service.updatePassphrase(passphrase)

        try await harness.service.restoreNow(modelContext: harness.context)

        let pushedManifestEnvelope = try #require(harness.drive.content(named: SyncBlob.driveFileName))
        let pushedManifest = try SyncBlobCrypto.openManifest(pushedManifestEnvelope, passphrase: passphrase)
        #expect(Set(pushedManifest.projects.map(\.id)) == Set(["local-project"]))
        #expect(pushedManifest.recordings.map(\.driveName) == ["rec_local-project_restore-push.m4a.enc"])

        let pushedRecordingEnvelope = try #require(harness.drive.content(named: "rec_local-project_restore-push.m4a.enc"))
        let pushedRecording = try SyncBlobCrypto.open(pushedRecordingEnvelope, passphrase: passphrase)
        #expect(pushedRecording == memoData)
    }

    @MainActor
    @Test func restoreReplacesEqualTimestampRecordingWhenShaDiffers() async throws {
        let harness = try makeHarness()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_030)
        let localMemo = Data([1, 1, 1])
        let remoteMemo = Data([2, 2, 2])
        let folder = harness.memosRoot.appendingPathComponent("project-3", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let localURL = folder.appendingPathComponent("same-time.m4a")
        try localMemo.write(to: localURL)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: localURL.path)

        let recording = SyncRecordingManifestEntry(
            projectId: "project-3",
            fileName: "same-time.m4a",
            driveName: "rec_project-3_same-time.m4a.enc",
            sizeBytes: Int64(remoteMemo.count),
            modifiedAt: timestamp,
            sha256: SHA256.hash(data: remoteMemo).map { String(format: "%02x", $0) }.joined()
        )
        let blob = SyncBlob(
            projects: [SyncSongProject(id: "project-3", title: "Restored", lyrics: "Lyrics", theme: "green", updatedAt: timestamp)],
            recordings: [recording],
            savedAt: timestamp,
            savedByClientId: "remote"
        )
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlobCrypto.sealManifest(blob, passphrase: passphrase))
        harness.drive.seed(name: recording.driveName, content: try SyncBlobCrypto.seal(remoteMemo, passphrase: passphrase))
        try harness.service.updatePassphrase(passphrase)

        try await harness.service.restoreNow(modelContext: harness.context)

        #expect(try Data(contentsOf: localURL) == remoteMemo)
    }

    @MainActor
    @Test func restorePublishesPermanentDeletionBeforeRemovingRemoteContent() async throws {
        let harness = try makeHarness()
        let remoteMemo = Data([7, 7, 7])
        let recording = SyncRecordingManifestEntry(
            projectId: "gone",
            fileName: "take.m4a",
            driveName: "rec_gone_take.m4a.enc",
            sizeBytes: Int64(remoteMemo.count),
            modifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            sha256: SHA256.hash(data: remoteMemo).map { String(format: "%02x", $0) }.joined()
        )
        let staleRemote = SyncBlob(
            projects: [SyncSongProject(id: "gone", title: "Stale", lyrics: "stale lyric", theme: "", updatedAt: Date(timeIntervalSince1970: 2_000_000_000))],
            recordings: [recording],
            savedAt: Date(timeIntervalSince1970: 2_000_000_000),
            savedByClientId: "stale-peer"
        )
        harness.context.insert(SyncDeletionRecord(projectId: "gone", deletedAt: 1))
        try harness.context.save()
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlobCrypto.sealManifest(staleRemote, passphrase: passphrase))
        harness.drive.seed(name: recording.driveName, content: try SyncBlobCrypto.seal(remoteMemo, passphrase: passphrase))
        try harness.service.updatePassphrase(passphrase)

        try await harness.service.restoreNow(modelContext: harness.context)

        let manifestEnvelope = try #require(harness.drive.content(named: SyncBlob.driveFileName))
        let manifest = try SyncBlobCrypto.openManifest(manifestEnvelope, passphrase: passphrase)
        #expect(manifest.projects.isEmpty)
        #expect(manifest.recordings.isEmpty)
        #expect(manifest.deletions == [SyncDeletion(projectId: "gone", deletedAt: 1)])
        #expect(harness.drive.content(named: recording.driveName) == nil)
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<SyncDeletionRecord>()).count == 1)
    }

    @MainActor
    @Test func backupCanonicalizesTombstonesWithoutAnExistingRemoteManifest() async throws {
        let harness = try makeHarness()
        harness.context.insert(SongProject(id: "gone", title: "Stale", lyrics: "must stay deleted"))
        harness.context.insert(SyncDeletionRecord(projectId: "gone", deletedAt: 1))
        try harness.context.save()
        try harness.service.updatePassphrase(passphrase)

        try await harness.service.backupNow(modelContext: harness.context)

        let envelope = try #require(harness.drive.content(named: SyncBlob.driveFileName))
        let manifest = try SyncBlobCrypto.openManifest(envelope, passphrase: passphrase)
        #expect(manifest.projects.isEmpty)
        #expect(manifest.trashed.isEmpty)
        #expect(manifest.recordings.isEmpty)
        #expect(manifest.deletions == [SyncDeletion(projectId: "gone", deletedAt: 1)])
        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).isEmpty)
    }

    @MainActor
    @Test func failedRemoteRecordingCleanupRetriesFromDurableProjectTombstone() async throws {
        let harness = try makeHarness()
        let recording = SyncRecordingManifestEntry(
            projectId: "gone",
            fileName: "take.m4a",
            driveName: "rec_gone_take.m4a.enc",
            sizeBytes: 3,
            modifiedAt: Date(timeIntervalSince1970: 100),
            sha256: SHA256.hash(data: Data([1, 2, 3])).map { String(format: "%02x", $0) }.joined()
        )
        let remote = SyncBlob(
            projects: [SyncSongProject(id: "gone", title: "Stale", lyrics: "stale", theme: "", updatedAt: Date(timeIntervalSince1970: 100))],
            recordings: [recording],
            savedAt: Date(timeIntervalSince1970: 100),
            savedByClientId: "stale-peer"
        )
        harness.context.insert(SyncDeletionRecord(projectId: "gone", deletedAt: 1))
        try harness.context.save()
        harness.drive.seed(name: SyncBlob.driveFileName, content: try SyncBlobCrypto.sealManifest(remote, passphrase: passphrase))
        harness.drive.seed(name: recording.driveName, content: try SyncBlobCrypto.seal(Data([1, 2, 3]), passphrase: passphrase))
        harness.drive.failNextDelete(named: recording.driveName)
        try harness.service.updatePassphrase(passphrase)

        await #expect(throws: BackupError.self) {
            try await harness.service.restoreNow(modelContext: harness.context)
        }
        #expect(harness.drive.content(named: recording.driveName) != nil)

        try await harness.service.restoreNow(modelContext: harness.context)

        #expect(harness.drive.content(named: recording.driveName) == nil)
        let envelope = try #require(harness.drive.content(named: SyncBlob.driveFileName))
        let manifest = try SyncBlobCrypto.openManifest(envelope, passphrase: passphrase)
        #expect(manifest.deletions == [SyncDeletion(projectId: "gone", deletedAt: 1)])
        #expect(manifest.recordings.isEmpty)
    }

    @MainActor
    @Test func networkWaitCannotOverwriteNewerPersistedWritingAtApply() async throws {
        let harness = try makeHarness()
        let project = SongProject(
            id: "draft",
            title: "Draft",
            lyrics: "before network wait",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        harness.context.insert(project)
        try harness.context.save()
        harness.drive.beforeManifestWrite = {
            project.lyrics = "edited while upload waited"
            project.updatedAt = Date(timeIntervalSince1970: 200)
            try harness.context.save()
        }
        try harness.service.updatePassphrase(passphrase)

        try await harness.service.backupNow(modelContext: harness.context)

        let stored = try #require(harness.context.fetch(FetchDescriptor<SongProject>()).first)
        #expect(stored.lyrics == "edited while upload waited")
        #expect(stored.updatedAt == Date(timeIntervalSince1970: 200))
    }

    @MainActor
    @Test func networkWaitCannotResurrectAConcurrentPermanentDeletion() async throws {
        let harness = try makeHarness()
        harness.context.insert(SongProject(
            id: "draft",
            title: "Draft",
            lyrics: "delete while upload waits",
            updatedAt: Date(timeIntervalSince1970: 100)
        ))
        try harness.context.save()
        harness.drive.beforeManifestWrite = {
            harness.context.insert(SyncDeletionRecord(projectId: "draft", deletedAt: 200))
            try harness.context.save()
        }
        try harness.service.updatePassphrase(passphrase)

        try await harness.service.backupNow(modelContext: harness.context)

        #expect(try harness.context.fetch(FetchDescriptor<SongProject>()).isEmpty)
        #expect(try harness.context.fetch(FetchDescriptor<SyncDeletionRecord>()).map(\.projectId) == ["draft"])
    }

    @MainActor
    private func makeHarness() throws -> BackupHarness {
        try makeHarness(oauthProvider: FakeOAuthProvider())
    }

    @MainActor
    private func makeHarness(oauthProvider: OAuthAccessTokenProvider) throws -> BackupHarness {
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let memosRoot = FileManager.default.temporaryDirectory.appendingPathComponent("BackupCoreTests-\(UUID().uuidString)", isDirectory: true)
        let drive = FakeDriveClient()
        let service = BackupService(
            driveClient: drive,
            oauthProvider: oauthProvider,
            secretStore: FakeBackupSecretStore(),
            defaults: UserDefaults(suiteName: "BackupCoreTests-\(UUID().uuidString)")!,
            memosRoot: memosRoot
        )
        return BackupHarness(container: container, drive: drive, service: service, memosRoot: memosRoot)
    }
}


@MainActor
private struct BackupHarness {
    let container: ModelContainer
    let drive: FakeDriveClient
    let service: BackupService
    let memosRoot: URL

    var context: ModelContext { container.mainContext }
}

private final class FakeOAuthProvider: OAuthAccessTokenProvider {
    var isConfigured = true
    var hasRefreshToken = true
    var accessTokenError: Error?

    func accessToken(interactive: Bool) async throws -> String {
        if let accessTokenError { throw accessTokenError }
        return "fake-token"
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

private final class FakeCloudBackupService: CloudBackupServicing {
    var isConfigured = true
    var hasStoredPassphrase = false
    var backgroundBackupFailureDescription: String?
    var updatedPassphrase: String?

    func updatePassphrase(_ passphrase: String) {
        updatedPassphrase = passphrase
        hasStoredPassphrase = true
    }

    func backupNow(modelContext: ModelContext) async throws {}
    func restoreNow(modelContext: ModelContext) async throws {}
    func backupInBackgroundIfPossible(modelContext: ModelContext) async {}
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
    var beforeManifestWrite: (@MainActor () throws -> Void)?

    func seed(name: String, content: Data) {
        let file = DriveAppDataFile(id: UUID().uuidString, name: name, modifiedTime: "seed-\(UUID().uuidString)", version: UUID().uuidString)
        filesByName[name] = StoredFile(file: file, content: content)
    }

    func content(named name: String) -> Data? {
        filesByName[name]?.content
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
        filesByName.values.map(\.file).filter { $0.name.hasPrefix(prefix) }
    }

    func downloadFile(id: String, accessToken: String) async throws -> Data {
        guard let stored = filesByName.values.first(where: { $0.file.id == id }) else {
            throw BackupError.noRemoteBackup
        }
        return stored.content
    }

    func uploadNewFile(named name: String, mimeType: String, content: Data, accessToken: String) async throws -> DriveAppDataFile {
        try await runManifestWriteHookIfNeeded(name: name)
        let file = DriveAppDataFile(id: UUID().uuidString, name: name, modifiedTime: "upload-\(UUID().uuidString)", version: UUID().uuidString)
        filesByName[name] = StoredFile(file: file, content: content)
        return file
    }

    func updateFile(id: String, mimeType: String, content: Data, accessToken: String) async throws {
        guard let name = filesByName.first(where: { $0.value.file.id == id })?.key else { return }
        try await runManifestWriteHookIfNeeded(name: name)
        let existing = filesByName[name]?.file
        let file = DriveAppDataFile(
            id: existing?.id ?? id,
            name: existing?.name ?? name,
            modifiedTime: "update-\(UUID().uuidString)",
            version: UUID().uuidString
        )
        filesByName[name] = StoredFile(file: file, content: content)
    }

    func deleteFile(id: String, accessToken: String) async throws {
        guard let name = filesByName.first(where: { $0.value.file.id == id })?.key else { return }
        if let failures = deleteFailuresByName[name], failures > 0 {
            deleteFailuresByName[name] = failures - 1
            throw BackupError.network("Synthetic recording cleanup failure")
        }
        filesByName.removeValue(forKey: name)
    }

    private func runManifestWriteHookIfNeeded(name: String) async throws {
        guard name == SyncBlob.driveFileName, let hook = beforeManifestWrite else { return }
        beforeManifestWrite = nil
        try await MainActor.run { try hook() }
    }
}
