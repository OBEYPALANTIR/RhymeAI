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
    @Test func authenticatedEnvelopeVersionsStillOpen() throws { try SyncRepairContractChecks.crypto() }
    @Test func legacyManifestsRemainReadable() throws { try SyncRepairContractChecks.legacyManifests() }
    @Test func androidWrittenV3ManifestOpens() throws { try SyncRepairContractChecks.androidWrittenManifest() }
    @Test func importedAudioKeepsDeletionSemanticsThroughTheV4Upgrade() throws { try SyncRepairContractChecks.importedAudio() }
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
        let laterMs: Int64 = 2_000_000_000_000
        func project(_ id: String) -> SyncSongProject { SyncSongProject(id: id, title: id, lyrics: "synthetic", theme: "", updatedAt: later) }
        func recording(_ id: String, _ file: String) -> SyncRecording {
            SyncRecording(projectId: id, fileName: file, bytes: 3, sha256: String(repeating: "a", count: 64), uploadedAt: later)
        }
        let trash = SyncTrashedSongProject(id: "gone", title: "gone", lyrics: "synthetic", theme: "", updatedAt: later, deletedAt: later, deleteAfter: later)
        let content = SyncBlob(projects: [project("gone"), project("keep")], trashed: [trash], recordings: [recording("gone", "take.m4a"), recording("keep", "removed.m4a"), recording("keep", "new.m4a")], savedAt: later, savedByClientId: "stale")
        let tombstones = SyncBlob(deletions: [SyncDeletion(projectId: "gone", deletedAt: laterMs + 1), SyncDeletion(projectId: "gone", deletedAt: laterMs + 2), SyncDeletion(projectId: "gone", fileName: "take.m4a", deletedAt: Int64.max), SyncDeletion(projectId: "keep", fileName: "removed.m4a", deletedAt: laterMs + 3)], savedAt: later, savedByClientId: "deleter")
        let merged = try SyncMerger.merge(local: content, remote: tombstones)
        try require(merged.projects.map(\.id) == ["keep"], "newer project tombstone lost to older content")
        try require(merged.trashed.isEmpty, "project tombstone retained visible trash")
        try require(merged.recordings.map(\.fileName) == ["new.m4a"], "recording tombstone lost to older upload")
        try require(merged.deletions == [SyncDeletion(projectId: "gone", deletedAt: laterMs + 2), SyncDeletion(projectId: "gone", fileName: "take.m4a", deletedAt: Int64.max), SyncDeletion(projectId: "keep", fileName: "removed.m4a", deletedAt: laterMs + 3)], "tombstone union/deduplication failed")
        try require(merged == SyncMerger.merge(local: tombstones, remote: content), "merge order changed output")
        try require(merged == SyncMerger.merge(local: merged, remote: merged), "merge was not idempotent")
        try require(merged == SyncMerger.merge(local: merged, remote: content), "repeat stale peer resurrected content")
        let equal = try SyncMerger.merge(local: SyncBlob(projects: [project("gone")], savedAt: later), remote: SyncBlob(trashed: [trash], savedAt: later))
        try require(equal.projects.isEmpty && equal.trashed.count == 1, "equal timestamp must prefer reversible trash")
        var alternative = content
        alternative.projects[1].lyrics = "z synthetic conflict"
        try require(SyncMerger.merge(local: content, remote: alternative) == SyncMerger.merge(local: alternative, remote: content), "equal content timestamps must converge")
        // Timestamps decide: content changed after its tombstone survives and the tombstone is dropped.
        let stale = SyncBlob(deletions: [SyncDeletion(projectId: "keep", deletedAt: laterMs - 1), SyncDeletion(projectId: "keep", fileName: "new.m4a", deletedAt: laterMs - 1)])
        let revived = try SyncMerger.merge(local: content, remote: stale)
        try require(revived.projects.map(\.id).contains("keep") && revived.recordings.contains { $0.fileName == "new.m4a" }, "older tombstone removed newer content")
        try require(revived.deletions.contains { $0.projectId == "keep" && $0.fileName == nil }, "a tombstone that lost was dropped; it must keep protecting older audio")

        // A song edited after its tombstone survives, but audio uploaded before the
        // tombstone stays deleted: on this backup, the next, and against a device
        // that still holds the old take.
        let oldTake = SyncRecording(projectId: "keep", fileName: "old.m4a", bytes: 3, sha256: String(repeating: "c", count: 64), uploadedAt: Date(timeIntervalSince1970: 1_900_000_000))
        let tombstone = SyncDeletion(projectId: "keep", deletedAt: 1_950_000_000_000)
        let first = try SyncMerger.merge(local: SyncBlob(projects: [project("keep")], recordings: [recording("keep", "new.m4a")]), remote: SyncBlob(deletions: [tombstone]))
        let second = try SyncMerger.merge(local: first, remote: SyncBlob(projects: [project("keep")], recordings: [oldTake]))
        let third = try SyncMerger.merge(local: SyncBlob(recordings: [oldTake]), remote: second)
        for result in [first, second, third] {
            try require(result.projects.map(\.id) == ["keep"] && result.recordings.map(\.fileName) == ["new.m4a"], "revived song resurrected audio its tombstone covered")
            try require(result.deletions == [tombstone], "revived song lost its tombstone")
        }
    }

    static func validation() throws {
        let migrated = try SyncJSON.decoder.decode(LegacySyncBlob.self, from: v1)
        try require(migrated.version == 1 && migrated.deletions.isEmpty, "v1 migration failed")
        for json in [#"{"version":2}"#, #"{"version":2,"deletions":null}"#, #"{"version":3}"#, #"{"version":3,"deletions":null}"#, #"{"version":4,"deletions":[]}"#, #"{"version":1,"deletions":[]}"#, #"{"deletions":[]}"#] {
            try rejects("invalid version shape accepted") { _ = try SyncJSON.decoder.decode(LegacySyncBlob.self, from: Data(json.utf8)) }
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
        try rejects("symlink escaped memo root") { _ = try RecordingFiles.localURL(projectId: "escape", fileName: "take.m4a", memosRoot: root) }
        let safe = try RecordingFiles.localURL(projectId: "good", fileName: "take 1.m4a", memosRoot: root)
        try require(safe.path.hasSuffix("/memos/good/take 1.m4a"), "valid legacy basename changed")
    }

    static func crypto() throws {
        let legacyEnvelope = try rawEnvelope(v1, magic: "RAI1")
        try require(legacyEnvelope.base64EncodedString() == golden, "RAI1 cross-platform golden changed")
        try require(SyncBlobCrypto.openManifest(legacyEnvelope, passphrase: passphrase).version == 1, "v1 manifest reader failed")
        let blob = LegacySyncBlob(deletions: [SyncDeletion(projectId: "gone", deletedAt: 1700000000000)], savedAt: Date(timeIntervalSince1970: 1700000000), savedByClientId: "ios-fixture")
        let encodedV3 = try SyncJSON.encoder.encode(blob)
        let envelope = try rawEnvelope(encodedV3, magic: "RAI3")
        try require(SyncBlobCrypto.openManifest(envelope, passphrase: passphrase) == blob, "RAI3 manifest did not open")
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
        let mismatched = try rawEnvelope(encodedV3, magic: "RAI1")
        try rejects("RAI1/v3 pairing accepted") { _ = try SyncBlobCrypto.openManifest(mismatched, passphrase: passphrase) }
        for (magic, plaintext) in [("RAI2", v1), ("RAI2", encodedV3), ("RAI3", v1), ("RAI3", Data(#"{"version":2,"deletions":[]}"#.utf8))] {
            let authenticated = try rawEnvelope(plaintext, magic: magic)
            try rejects("authenticated wrong payload version accepted") { _ = try SyncBlobCrypto.openManifest(authenticated, passphrase: passphrase) }
        }
        try rejects("wrong passphrase accepted") { _ = try SyncBlobCrypto.openManifest(envelope, passphrase: "wrong passphrase") }
        let audio = Data([0, 1, 2, 3])
        let recording = try rawEnvelope(audio, magic: "RAI1")
        try require(SyncBlobCrypto.open(recording, passphrase: passphrase) == audio, "recording compatibility failed")
    }

    static func androidWrittenManifest() throws {
        // The RAI3 vector in android/app/src/test/resources/sync-envelope-vectors.json;
        // Android's SyncBlobCryptoTest seals these exact bytes.
        let androidV3Base64 = "UkFJMwABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhtizcOcwuED9qmh1u2pIuacjCXfzEdC4XqsUgnAZ08InG+/2sOGiVfCbTNTgVs/qDX5tg+Xq/8BEH3mg+MmFeqRheWaMxPs8OlSH7Qk3NlvXhbeadkCMJdN+1TGfXEOfFN1TWcopyCi7nQECwWmM9FoDiFvYdpO9FASv9DMzSzf8bhV9h1x7JyXsCmK9D5Q3b2bgUDXlofE+sOt6C+iD7+DG8H3T/+zR/1o2Xh8ayaScLc2ZoYtTAGPW/MU2kSBrBcVy6A/zgS0sVDgzEFSOF9a2oSxDPsg7pdytAc4nSzgapIddeo97OUTNUhdGRgfs6m1UKjsLc5AcYfWeY8OuuCHLTrLc+4qTwxdp5UKYWRmsrIJXKK8kT1ftiMuN8iECTTtrL42ClJyEx5RnRomdPWaOtR06dGOz0kZng7Pz7Fnt1QvRzLSLEAuDYJ00d3pqyAXeX5r8CCNHXb7H+6jdn9PDipjpjuI9ctCGzSnOi9Z6HVLrPhP4xI="
        guard let fixture = Data(base64Encoded: androidV3Base64) else { throw Failure(message: "invalid RAI3 fixture") }
        let blob = try SyncBlobCrypto.openManifest(fixture, passphrase: passphrase)
        try require(blob.version == 3 && blob.savedByClientId == "deleter", "Android RAI3 manifest did not open as v3")
        try require(blob.deletions.contains { $0.projectId == "keep" && $0.fileName == "removed.m4a" }, "Android RAI3 deletion lost")
    }

    static func legacyManifests() throws {
        // Pinned RAI2/v2 fixture uses the historical M4A-only shape and nonempty deletions.
        let legacyV2Base64 = "UkFJMgABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhtizcOcwuED9qmh1uypIuacjCXfzEdC4XqsUgnAZ08InG+/2sOGiVfCbTNTgVs/qDX5tg+Xq/8nHi/wieUmAve3j7SCKyTytfhDCfMy0MNBGBjGLdcBO7wOuhOCLj8fU1l9BigmqHfioDxUBhavGMRgD0IhYZIa6iMF+MffwT+X4aNy9WA/r5Cd8CGcuTJT2rLc4wPJmt+b1s+14XCiUenDXNj9T9ehDKI+5SAlc2fXL+1jNcJUGBOFSaRXllLL4QdGlO5gohagugayi0FaMBgJ6pzySrJu74Z3vh0u21fPM4pUNbdkurFVTB9JGw9P4fLlHP2/fZFUPZCGOscNsPirB3mcNKd1RAkT55tObG1vmacBXcHykXUL7HxoYpyaVDC8vqIkE2oyVBlVjz42F7uLfbhv+5LfiRxN70rdxbN7pRd+AWeGXgldUds9ndrBuWdJGW5H72SeQS/UErTtIWlPQDKtvQV6HX2ymVqivm9GGsNH"
        guard let fixture = Data(base64Encoded: legacyV2Base64) else { throw Failure(message: "invalid RAI2 fixture") }
        let legacy = try SyncBlobCrypto.openManifest(fixture, passphrase: passphrase)
        try require(legacy.version == 2, "v2 manifest reader changed version")
        try require(legacy.recordings.map(\.fileName) == ["take.m4a"], "legacy M4A recording lost")
        try require(legacy.deletions == [SyncDeletion(projectId: "deleted-song", deletedAt: 1700000000000)], "legacy v2 deletion lost")
        let upgraded = try SyncMerger.merge(local: legacy.upgraded, remote: SyncBlob())
        try require(upgraded.deletions == legacy.deletions, "v2 upgrade lost deletion contract")

        // Android emitted imported names in RAI1/v1 and RAI2/v2; they still open for migration.
        for version in [1, 2] {
            let recordings = ["m4a", "mp3", "wav", "aac"].map { ext in
                SyncRecordingManifestEntry(projectId: "song", fileName: "take.\(ext)", driveName: "rec_song_take.\(ext).enc", sizeBytes: 3, modifiedAt: Date(timeIntervalSince1970: 1700000000), sha256: "synthetic")
            }
            let blob = LegacySyncBlob(version: version, recordings: recordings, savedAt: Date(timeIntervalSince1970: 1700000000))
            let envelope = try rawEnvelope(SyncJSON.encoder.encode(blob), magic: "RAI\(version)")
            try require(SyncBlobCrypto.openManifest(envelope, passphrase: passphrase) == blob, "legacy imported-name read regressed")
        }
    }

    static func importedAudio() throws {
        let formats = ["aac", "m4a", "mp3", "wav"]
        let hash = String(repeating: "b", count: 64)
        let recordings = formats.map { ext in
            SyncRecordingManifestEntry(projectId: "song", fileName: "take.\(ext)", driveName: "rec_song_take.\(ext).enc", sizeBytes: 3, modifiedAt: Date(timeIntervalSince1970: 1700000000), sha256: hash)
        }
        let deleted = formats.map { SyncDeletion(projectId: "song", fileName: "deleted.\($0)", deletedAt: 1700000000000) }
        let legacy = LegacySyncBlob(recordings: recordings, deletions: deleted, savedAt: Date(timeIntervalSince1970: 1700000000))
        let opened = try SyncBlobCrypto.openManifest(rawEnvelope(SyncJSON.encoder.encode(legacy), magic: "RAI3"), passphrase: passphrase)
        try require(opened == legacy, "v3 import/deletion encrypted read failed")
        let upgraded = opened.upgraded
        try require(upgraded.recordings.map(\.driveName) == formats.map { "rec_song_take.\($0)" }, "v4 Drive names wrong")
        let reopened = try SyncBlob.decodeManifest(upgraded.encodedManifest())
        try require(reopened.recordings == upgraded.recordings && reopened.deletions == deleted, "v4 round trip lost imported audio or deletions")
        let tombstoned = SyncBlob(recordings: upgraded.recordings, deletions: [SyncDeletion(projectId: "song", fileName: "take.wav", deletedAt: Int64.max)])
        let merged = try SyncMerger.merge(local: upgraded, remote: tombstoned)
        try require(!merged.recordings.contains { $0.fileName == "take.wav" }, "v4 merge resurrected deleted imported audio")
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
