import CryptoKit
import Foundation
#if canImport(Testing)
import Testing
#endif
#if canImport(Writers_Block)
@testable import Writers_Block
#endif

#if canImport(Testing)
struct SyncRepairContractTests {
    @Test func permanentDeletionsConverge() throws { try SyncRepairContractChecks.deletions() }
    @Test func strictManifestSchemaAndPaths() throws { try SyncRepairContractChecks.validation() }
    @Test func authenticatedEnvelopeVersions() throws { try SyncRepairContractChecks.crypto() }
    @Test func legacyManifestsRemainReadable() throws { try SyncRepairContractChecks.legacyManifests() }
    @Test func importedAudioUsesV3ManifestAndRetainsDeletionSemantics() throws { try SyncRepairContractChecks.importedAudio() }
}
#endif

enum SyncRepairContractChecks {
    struct Failure: Error { let message: String }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure(message: message)
    }
    static let passphrase = "correct horse battery staple"
    static let salt = Data((0..<16).map(UInt8.init))
    static let iv = Data((0x10..<0x1c).map(UInt8.init))
    static let v1 = Data(#"{"version":1,"projects":[],"trashed":[],"recordings":[],"savedAt":1700000000000,"savedByClientId":"android-fixture"}"#.utf8)
    static let golden = "UkFJMQABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhtizcOcwuED9qmh1u+pIuacjCXfzEdC4XqsUgnAZ08InG+/2sOGiVfCbTNTgVs/qDX5tg+Xq/8BEH3xh/kmBcKKyayJPnin4qkQQO5xj50WFhaXKsgIOrAWlBrJcXMfe1Y6EmdzpzG87TFCQgajLtF4GAU5Pgh+VRicHt164bxqXJ5xxeE="

    static func deletions() throws {
        let later = Date(timeIntervalSince1970: 2_000_000_000)
        func project(_ id: String) -> SyncSongProject { SyncSongProject(id: id, title: id, lyrics: "synthetic", theme: "", updatedAt: later) }
        func recording(_ id: String, _ file: String) -> SyncRecordingManifestEntry {
            SyncRecordingManifestEntry(projectId: id, fileName: file, driveName: RecordingBackupManifest.driveName(projectId: id, fileName: file), sizeBytes: 3, modifiedAt: later, sha256: "synthetic")
        }
        let trash = SyncTrashedSongProject(id: "gone", title: "gone", lyrics: "synthetic", theme: "", updatedAt: later, deletedAt: later, deleteAfter: later)
        let content = SyncBlob(projects: [project("gone"), project("keep")], trashed: [trash], recordings: [recording("gone", "take.m4a"), recording("keep", "removed.m4a"), recording("keep", "new.m4a")], savedAt: later, savedByClientId: "stale")
        let tombstones = SyncBlob(deletions: [SyncDeletion(projectId: "gone", deletedAt: 1), SyncDeletion(projectId: "gone", deletedAt: 2), SyncDeletion(projectId: "gone", fileName: "take.m4a", deletedAt: Int64.max), SyncDeletion(projectId: "keep", fileName: "removed.m4a", deletedAt: 3)], savedAt: later, savedByClientId: "deleter")
        let merged = try SyncMerger.merge(local: content, remote: tombstones)
        try require(merged.projects.map(\.id) == ["keep"], "project tombstone lost to later content")
        try require(merged.trashed.isEmpty, "project tombstone retained visible trash")
        try require(merged.recordings.map(\.fileName) == ["new.m4a"], "recording tombstone lost to later manifest")
        try require(merged.deletions == [SyncDeletion(projectId: "gone", deletedAt: 2), SyncDeletion(projectId: "keep", fileName: "removed.m4a", deletedAt: 3)], "tombstone union/deduplication failed")
        try require(merged == SyncMerger.merge(local: tombstones, remote: content), "merge order changed output")
        try require(merged == SyncMerger.merge(local: merged, remote: merged), "merge was not idempotent")
        try require(merged == SyncMerger.merge(local: merged, remote: content), "repeat stale peer resurrected content")
        let equal = try SyncMerger.merge(local: SyncBlob(projects: [project("gone")], savedAt: later), remote: SyncBlob(trashed: [trash], savedAt: later))
        try require(equal.projects.isEmpty && equal.trashed.count == 1, "equal timestamp must prefer reversible trash")
        var alternative = content
        alternative.projects[1].lyrics = "z synthetic conflict"
        try require(SyncMerger.merge(local: content, remote: alternative) == SyncMerger.merge(local: alternative, remote: content), "equal content timestamps must converge")
    }

    static func validation() throws {
        let migrated = try SyncJSON.decoder.decode(SyncBlob.self, from: v1)
        try require(migrated.version == 1 && migrated.deletions.isEmpty, "v1 migration failed")
        for json in [#"{"version":2}"#, #"{"version":2,"deletions":null}"#, #"{"version":3}"#, #"{"version":3,"deletions":null}"#, #"{"version":4,"deletions":[]}"#, #"{"version":1,"deletions":[]}"#, #"{"deletions":[]}"#] {
            try rejects("invalid version shape accepted") { _ = try SyncJSON.decoder.decode(SyncBlob.self, from: Data(json.utf8)) }
        }
        for value in ["", ".", "..", "../song", "a/b", "a\\b", "a\n", String(repeating: "é", count: 65)] {
            try rejects("invalid project ID accepted") { try SyncIdentity.validateProjectId(value) }
        }
        for value in ["", "../take.m4a", "a\\take.m4a", "take.M4A", " take.m4a", "take.m4a ", "a:take.m4a", "a?take.m4a", "a\ntake.m4a", String(repeating: "é", count: 119) + ".m4a"] {
            try rejects("invalid recording filename accepted") { try SyncIdentity.validateFileName(value) }
        }
        try SyncIdentity.validateProjectId("legacy opaque:é id")
        try SyncIdentity.validateFileName("take 1.m4a")
        let absent = try SyncJSON.decoder.decode(SyncDeletion.self, from: Data(#"{"projectId":"gone","deletedAt":9223372036854775807}"#.utf8))
        try require(absent.fileName == nil && absent.deletedAt == Int64.max, "absent project tombstone key or Int64 failed")
        let encoded = try SyncJSON.encoder.encode(absent)
        try require(String(decoding: encoded, as: UTF8.self).contains(#""fileName":null"#), "writer did not emit explicit null")
        var invalid = SyncBlob()
        invalid.projects = [SyncSongProject(id: "../escape", title: "", lyrics: "", theme: "", updatedAt: Date())]
        try rejects("in-memory snapshot not validated") { _ = try SyncMerger.merge(local: invalid, remote: SyncBlob()) }
        let bad = SyncRecordingManifestEntry(projectId: "good", fileName: "take.m4a", driveName: "other.m4a.enc", sizeBytes: 1, modifiedAt: Date(), sha256: "synthetic")
        try rejects("untrusted Drive name accepted") { try bad.validate() }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sync-contract-\(UUID().uuidString)", isDirectory: true)
        let root = scratch.appendingPathComponent("memos", isDirectory: true)
        let outside = scratch.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try rejects("symlink escaped memo root") { _ = try RecordingBackupManifest.localURL(projectId: "escape", fileName: "take.m4a", memosRoot: root) }
        let safe = try RecordingBackupManifest.localURL(projectId: "good", fileName: "take 1.m4a", memosRoot: root)
        try require(safe.path.hasSuffix("/memos/good/take 1.m4a"), "valid legacy basename changed")
    }

    static func crypto() throws {
        let legacyEnvelope = try SyncBlobCrypto.seal(v1, passphrase: passphrase, salt: salt, iv: iv)
        try require(legacyEnvelope.base64EncodedString() == golden, "RAI1 cross-platform golden changed")
        try require(SyncBlobCrypto.openManifest(legacyEnvelope, passphrase: passphrase).version == 1, "v1 manifest reader failed")
        let blob = SyncBlob(deletions: [SyncDeletion(projectId: "gone", deletedAt: 1700000000000)], savedAt: Date(timeIntervalSince1970: 1700000000), savedByClientId: "ios-fixture")
        let envelope = try SyncBlobCrypto.sealManifest(blob, passphrase: passphrase, salt: salt, iv: iv)
        try require(envelope.prefix(4) == Data("RAI3".utf8), "manifest did not write RAI3")
        try require(SyncBlobCrypto.openManifest(envelope, passphrase: passphrase) == blob, "RAI3 manifest round trip failed")
        try rejects("legacy audio reader accepted RAI3") { _ = try SyncBlobCrypto.open(envelope, passphrase: passphrase) }
        for previous in [UInt8(ascii: "1"), UInt8(ascii: "2")] {
            var downgrade = envelope
            downgrade[3] = previous
            do {
                _ = try SyncBlobCrypto.openManifest(downgrade, passphrase: passphrase)
                throw Failure(message: "tampered magic bypassed AAD")
            } catch SyncBlobCryptoError.authenticationFailed {}
        }
        var future = envelope
        future[3] = UInt8(ascii: "4")
        do {
            _ = try SyncBlobCrypto.openManifest(future, passphrase: passphrase)
            throw Failure(message: "future magic accepted")
        } catch SyncBlobCryptoError.unsupportedEnvelopeVersion {}
        let encodedV3 = try SyncJSON.encoder.encode(blob)
        let mismatched = try SyncBlobCrypto.seal(encodedV3, passphrase: passphrase, salt: salt, iv: iv)
        try rejects("RAI1/v3 pairing accepted") { _ = try SyncBlobCrypto.openManifest(mismatched, passphrase: passphrase) }
        for (magic, plaintext) in [("RAI2", v1), ("RAI2", encodedV3), ("RAI3", v1), ("RAI3", Data(#"{"version":2,"deletions":[]}"#.utf8))] {
            let authenticated = try rawEnvelope(plaintext, magic: magic)
            try rejects("authenticated wrong payload version accepted") { _ = try SyncBlobCrypto.openManifest(authenticated, passphrase: passphrase) }
        }
        try rejects("wrong passphrase accepted") { _ = try SyncBlobCrypto.openManifest(envelope, passphrase: "wrong passphrase") }
        let audio = Data([0, 1, 2, 3])
        let recording = try SyncBlobCrypto.seal(audio, passphrase: passphrase, salt: salt, iv: iv)
        try require(recording.prefix(4) == Data("RAI1".utf8) && SyncBlobCrypto.open(recording, passphrase: passphrase) == audio, "recording compatibility failed")
    }

    static func legacyManifests() throws {
        // Pinned RAI2/v2 fixture uses the historical M4A-only shape and nonempty deletions.
        let legacyV2Base64 = "UkFJMgABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhtizcOcwuED9qmh1uypIuacjCXfzEdC4XqsUgnAZ08InG+/2sOGiVfCbTNTgVs/qDX5tg+Xq/8nHi/wieUmAve3j7SCKyTytfhDCfMy0MNBGBjGLdcBO7wOuhOCLj8fU1l9BigmqHfioDxUBhavGMRgD0IhYZIa6iMF+MffwT+X4aNy9WA/r5Cd8CGcuTJT2rLc4wPJmt+b1s+14XCiUenDXNj9T9ehDKI+5SAlc2fXL+1jNcJUGBOFSaRXllLL4QdGlO5gohagugayi0FaMBgJ6pzySrJu74Z3vh0u21fPM4pUNbdkurFVTB9JGw9P4fLlHP2/fZFUPZCGOscNsPirB3mcNKd1RAkT55tObG1vmacBXcHykXUL7HxoYpyaVDC8vqIkE2oyVBlVjz42F7uLfbhv+5LfiRxN70rdxbN7pRd+AWeGXgldUds9ndrBuWdJGW5H72SeQS/UErTtIWlPQDKtvQV6HX2ymVqivm9GGsNH"
        guard let fixture = Data(base64Encoded: legacyV2Base64) else { throw Failure(message: "invalid RAI2 fixture") }
        let legacy = try SyncBlobCrypto.openManifest(fixture, passphrase: passphrase)
        try require(legacy.version == 2, "v2 manifest reader changed version")
        try require(legacy.recordings.map(\.fileName) == ["take.m4a"], "legacy M4A recording lost")
        try require(legacy.deletions == [SyncDeletion(projectId: "deleted-song", deletedAt: 1700000000000)], "legacy v2 deletion lost")
        let upgraded = try SyncMerger.merge(local: legacy, remote: SyncBlob())
        try require(upgraded.version == 3 && upgraded.deletions == legacy.deletions, "v2 merge lost deletion contract")

        // Android currently emits imported names in RAI1/v1. Keep these transitional
        // reads tolerant; Apple production writes must still advertise the new version.
        for version in [1, 2] {
            let recordings = ["m4a", "mp3", "wav", "aac"].map { ext in
                SyncRecordingManifestEntry(projectId: "song", fileName: "take.\(ext)", driveName: "rec_song_take.\(ext).enc", sizeBytes: 3, modifiedAt: Date(timeIntervalSince1970: 1700000000), sha256: "synthetic")
            }
            let blob = SyncBlob(version: version, recordings: recordings, savedAt: Date(timeIntervalSince1970: 1700000000))
            let envelope = try rawEnvelope(SyncJSON.encoder.encode(blob), magic: "RAI\(version)")
            try require(SyncBlobCrypto.openManifest(envelope, passphrase: passphrase) == blob, "legacy imported-name read regressed")
            do {
                _ = try SyncBlobCrypto.sealManifest(blob, passphrase: passphrase)
                throw Failure(message: "Apple writer emitted a legacy manifest")
            } catch SyncBlobCryptoError.manifestVersionMismatch {}
        }
    }

    static func importedAudio() throws {
        let formats = ["aac", "m4a", "mp3", "wav"]
        let recordings = formats.map { ext in
            SyncRecordingManifestEntry(projectId: "song", fileName: "take.\(ext)", driveName: "rec_song_take.\(ext).enc", sizeBytes: 3, modifiedAt: Date(timeIntervalSince1970: 1700000000), sha256: "synthetic")
        }
        let deleted = formats.map { SyncDeletion(projectId: "song", fileName: "deleted.\($0)", deletedAt: 1700000000000) }
        let blob = SyncBlob(recordings: recordings, deletions: deleted, savedAt: Date(timeIntervalSince1970: 1700000000))
        let encoded = try SyncJSON.encoder.encode(blob)
        try require(SyncJSON.decoder.decode(SyncBlob.self, from: encoded) == blob, "v3 JSON lost recording deletions")
        let envelope = try SyncBlobCrypto.sealManifest(blob, passphrase: passphrase, salt: salt, iv: iv)
        try require(envelope.prefix(4) == Data("RAI3".utf8), "imported names did not advertise RAI3")
        let opened = try SyncBlobCrypto.openManifest(envelope, passphrase: passphrase)
        try require(opened == blob, "v3 import/deletion encrypted round trip failed")
        let tombstoned = SyncBlob(recordings: recordings, deletions: [SyncDeletion(projectId: "song", fileName: "take.wav", deletedAt: 1)])
        let merged = try SyncMerger.merge(local: blob, remote: tombstoned)
        let reopened = try SyncBlobCrypto.openManifest(SyncBlobCrypto.sealManifest(merged, passphrase: passphrase), passphrase: passphrase)
        try require(reopened.version == 3 && !reopened.recordings.contains { $0.fileName == "take.wav" }, "v3 merge/seal resurrected deleted imported audio")
    }

    static func rawEnvelope(_ plaintext: Data, magic: String) throws -> Data {
        // Derived by PBKDF2-HMAC-SHA256 for the public fixture passphrase/salt at 210000 iterations.
        let keyBytes: [UInt8] = [24, 70, 92, 173, 224, 150, 193, 133, 181, 246, 7, 101, 137, 31, 202, 63, 116, 71, 126, 35, 253, 155, 111, 200, 143, 175, 120, 49, 169, 23, 83, 172]
        let key = SymmetricKey(data: Data(keyBytes))
        let header = Data(magic.utf8) + salt + iv
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: iv), authenticating: header)
        return header + sealed.ciphertext + sealed.tag
    }
}
