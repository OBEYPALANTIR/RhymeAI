import CryptoKit
import Foundation
import Testing
@testable import Writers_Block

// MARK: - Gemma prompt template

/// Verify that GGUFModelService.gemmaPrompt produces the same shape as
/// Android's gemmaInstructionPrompt() — chat template must be stable across
/// platforms so the model behaves identically.
struct GemmaPromptTemplateTests {
    @Test func gemmaPromptMatchesCanonicalMachineWrapperExactly() {
        let input = "Write a verse about midnight roads."
        let expected = "<start_of_turn>user\n\(input)\n<end_of_turn>\n<start_of_turn>model"

        #expect(GGUFModelService.gemmaPrompt(input, format: .gemmaLegacy) == expected)
        #expect(GGUFModelService.gemmaPrompt(expected, format: .gemmaLegacy) == expected)
        #expect(GGUFModelService.gemmaPrompt("\(expected)\n", format: .gemmaLegacy) == expected)
    }

    @Test func gemma4PromptUsesModelTurnTokensAndGenerationNewline() {
        let input = "Write a verse about midnight roads."
        let expected = "<|turn>user\n\(input)<turn|>\n<|turn>model\n"
        #expect(GGUFModelService.gemmaPrompt(input, format: .gemma4) == expected)
        #expect(GGUFModelService.gemmaPrompt(expected, format: .gemma4) == expected)
    }

    @Test func promptFormatRequiresMatchingModelMetadata() {
        let legacy = "<start_of_turn>user <end_of_turn>"
        let gemma4 = "<|turn>user <turn|>"
        #expect(GGUFPromptFormat.resolve(architecture: "gemma4", chatTemplate: gemma4) == .gemma4)
        for architecture in ["gemma", "gemma2", "gemma3", "gemma3n"] {
            #expect(GGUFPromptFormat.resolve(architecture: architecture, chatTemplate: legacy) == .gemmaLegacy)
            #expect(GGUFPromptFormat.resolve(architecture: architecture, chatTemplate: gemma4) == nil)
        }
        #expect(GGUFPromptFormat.resolve(architecture: "gemma4", chatTemplate: legacy) == nil)
        #expect(GGUFPromptFormat.resolve(architecture: "gemma4", chatTemplate: gemma4 + legacy) == nil)
        #expect(GGUFPromptFormat.resolve(architecture: "llama", chatTemplate: gemma4) == nil)
        #expect(GGUFPromptFormat.resolve(architecture: "gemma4", chatTemplate: "") == nil)
    }

    @Test func gemmaPromptPreservesNewlinesInPrompt() {
        let input = "line one\nline two"
        let wrapped = GGUFModelService.gemmaPrompt(input, format: .gemmaLegacy)
        #expect(wrapped.contains("line one\nline two"))
    }
}

// MARK: - Marker stripping

struct GGUFMarkerStrippingTests {
    @Test func stripsBareAngleBracketLines() {
        let raw = ">\nActual lyric line\n>"
        let cleaned = GGUFModelService.stripMarkers(raw)
        #expect(cleaned == "Actual lyric line")
    }

    @Test func stripsStartOfTurnLines() {
        let raw = "<start_of_turn>\nThis is the output\n<end_of_turn>"
        let cleaned = GGUFModelService.stripMarkers(raw)
        #expect(cleaned == "This is the output")
    }

    @Test func stripsModelRoleLabel() {
        let raw = "<model>\nActual output here"
        let cleaned = GGUFModelService.stripMarkers(raw)
        #expect(cleaned == "Actual output here")
    }

    @Test func preservesRealLyricContent() {
        let raw = "I keep a notebook under neon rain\nEvery margin learns my name"
        let cleaned = GGUFModelService.stripMarkers(raw)
        #expect(cleaned == raw)
    }

    @Test func stripsLeadingAndTrailingBlanks() {
        let raw = "\n\nCity lights shine bright\n\n"
        let cleaned = GGUFModelService.stripMarkers(raw)
        #expect(cleaned == "City lights shine bright")
    }

    @Test func emptyInputReturnsEmpty() {
        #expect(GGUFModelService.stripMarkers("").isEmpty)
    }
}

struct GGUFDownloadCatalogTests {
    @Test func catalogUsesRhymeAITunedModels() {
        let options = GGUFDownloadCatalog.options

        #expect(options.count == 2)
        #expect(options.allSatisfy { $0.url.host == "huggingface.co" })
        #expect(options.allSatisfy { $0.url.path.contains("Shayde182/rhymeai-gemma-4-gguf") })
        #expect(options.allSatisfy { $0.fileName.contains("rhymeai-Q4_K_M") })
        #expect(options.allSatisfy {
            $0.url.path.contains("/resolve/\(GGUFDownloadCatalog.huggingFaceRevision)/")
        })
        #expect(options.allSatisfy { !$0.url.path.contains("/resolve/main/") })
        #expect(options.map(\.expectedBytes) == [3_427_880_800, 5_335_292_800])
        #expect(options.map(\.sha256) == [
            "902e5d83a86393f064b1c8abc1a9d25fec5b3634683317792b02856c01c604e0",
            "6d6b7890655943a3dba1a4212f6668537503a9e085f55fbdeeb40265c5e91944",
        ])
    }

    // The catalog must pin an immutable commit, never a branch or placeholder.
    @Test func catalogPinsAnImmutableHuggingFaceCommit() {
        let revision = GGUFDownloadCatalog.huggingFaceRevision
        #expect(revision.count == 40 && revision.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func previousModelVersionUnderTheSameNameIsNotReportedInstalled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-installed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func sparseFile(_ name: String, bytes: Int64) throws {
            let url = directory.appendingPathComponent(name)
            #expect(FileManager.default.createFile(atPath: url.path, contents: Data("GGUF".utf8)))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
        }
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]

        // The shipped v1 E2B file: same name, 2,016 bytes smaller than the current entry.
        try sparseFile(e2b.fileName, bytes: 3_427_878_784)
        try sparseFile(e4b.fileName, bytes: e4b.expectedBytes)
        GGUFVerifiedArtifactStore.record(
            sha256: e4b.sha256, at: directory.appendingPathComponent(e4b.fileName), defaults: defaults
        )
        try sparseFile("my-custom-model.gguf", bytes: 1_024)
        #expect(GGUFModelStorage.installedModelFileNames(in: directory, defaults: defaults) == [
            e4b.fileName,
            "my-custom-model.gguf",
        ].sorted())

        // The right size alone is not enough: the file must be marked as the current artifact.
        try sparseFile(e2b.fileName, bytes: e2b.expectedBytes)
        #expect(!GGUFModelStorage.installedModelFileNames(in: directory, defaults: defaults).contains(e2b.fileName))
        GGUFVerifiedArtifactStore.record(
            sha256: e2b.sha256, at: directory.appendingPathComponent(e2b.fileName), defaults: defaults
        )
        #expect(GGUFModelStorage.installedModelFileNames(in: directory, defaults: defaults).contains(e2b.fileName))
    }

    /// E2B v2.1 and v6 share a name and an exact byte size; only the SHA-256 differs.
    @Test func sameSizePreviousE2bIsNotInstalledAndIsReclaimed() throws {
        let directory = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let e2b = GGUFDownloadCatalog.options[0]
        let v21SHA256 = "4cfffebcb0b96e154d963de5d90ed63962d0bcd9e77ab9fec38314257870e6a5"
        #expect(v21SHA256 != e2b.sha256)
        let installed = directory.appendingPathComponent(e2b.fileName)

        // A device that installed v2.1 with a build which recorded its marker: reclaimed by
        // metadata alone, without hashing.
        try writeSparseFile(installed, bytes: e2b.expectedBytes)
        GGUFVerifiedArtifactStore.record(sha256: v21SHA256, at: installed, defaults: defaults)
        #expect(!GGUFModelStorage.installedModelFileNames(in: directory, defaults: defaults).contains(e2b.fileName))
        #expect(try GGUFModelStorage.removeStaleArtifacts(for: e2b, in: directory, defaults: defaults) == e2b.expectedBytes)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
        #expect(GGUFVerifiedArtifactStore.marker(fileName: e2b.fileName, defaults: defaults) == nil)

        // A device whose v2.1 file has no marker yet: not installed; the download path
        // hashes it once, finds v2.1's bytes and reclaims the file.
        try writeSparseFile(installed, bytes: e2b.expectedBytes)
        #expect(!GGUFModelStorage.installedModelFileNames(in: directory, defaults: defaults).contains(e2b.fileName))
        #expect(GGUFModelStorage.needsInstalledVerification(for: e2b, in: directory, defaults: defaults))
        #expect(try GGUFModelStorage.verifyOrReclaimInstalled(e2b, in: directory, defaults: defaults) == false)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
        #expect(GGUFVerifiedArtifactStore.marker(fileName: e2b.fileName, defaults: defaults) == nil)
    }

    @Test func verifiedMarkerIsTrustedOnlyForTheFileItWasWrittenFor() throws {
        let directory = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let valid = Data([0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4])
        let option = GGUFDownloadOption(
            id: "fixture", title: "Fixture", subtitle: "", size: "8 B",
            fileName: "fixture.gguf", expectedBytes: Int64(valid.count),
            sha256: SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/fixture.gguf")!, isRecommended: false
        )
        let staging = directory.appendingPathComponent("fixture.gguf.download")
        let installed = directory.appendingPathComponent(option.fileName)

        // A verified install writes the marker.
        try valid.write(to: staging)
        try GGUFDownloadManager.installDownload(from: staging, in: directory, option: option, defaults: defaults)
        #expect(GGUFModelStorage.isVerifiedInstall(of: option, at: installed, defaults: defaults))
        #expect(!GGUFModelStorage.needsInstalledVerification(for: option, in: directory, defaults: defaults))

        // Replacing the file under the same name invalidates the marker.
        var other = valid
        other[7] = 9
        try FileManager.default.removeItem(at: installed)
        try other.write(to: installed)
        #expect(!GGUFModelStorage.isVerifiedInstall(of: option, at: installed, defaults: defaults))
        #expect(GGUFModelStorage.needsInstalledVerification(for: option, in: directory, defaults: defaults))
        #expect(try GGUFModelStorage.verifyOrReclaimInstalled(option, in: directory, defaults: defaults) == false)
        #expect(!FileManager.default.fileExists(atPath: installed.path))

        // The current bytes without a marker (installed by an older build) are kept and marked.
        try valid.write(to: installed)
        #expect(try GGUFModelStorage.verifyOrReclaimInstalled(option, in: directory, defaults: defaults))
        #expect(GGUFModelStorage.isVerifiedInstall(of: option, at: installed, defaults: defaults))
        #expect(try GGUFModelStorage.removeStaleArtifacts(for: option, in: directory, defaults: defaults) == 0)
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "gguf-verified-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func makeModelsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeSparseFile(_ url: URL, bytes: Int64) throws {
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data("GGUF".utf8)))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    @Test func staleSameNameModelAndForeignResumeDataAreReclaimed() throws {
        let directory = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let staleModel = directory.appendingPathComponent(e2b.fileName)
        try writeSparseFile(staleModel, bytes: 3_427_878_784)
        try writeSparseFile(directory.appendingPathComponent(e4b.fileName), bytes: e4b.expectedBytes)
        // Resume data written by the previous build (unkeyed) and for another artifact.
        let legacyResume = directory.appendingPathComponent("\(e2b.fileName).resume")
        let foreignResume = directory.appendingPathComponent("\(e2b.fileName).059e73281d764ba0.resume")
        let currentResume = GGUFModelStorage.resumeDataURL(for: e2b, in: directory)
        for url in [legacyResume, foreignResume, currentResume] {
            try Data("resume".utf8).write(to: url)
        }
        #expect(currentResume.lastPathComponent.contains(String(e2b.sha256.prefix(16))))

        let freed = try GGUFModelStorage.removeStaleArtifacts(for: e2b, in: directory)

        #expect(freed == 3_427_878_784)
        #expect(!FileManager.default.fileExists(atPath: staleModel.path))
        #expect(!FileManager.default.fileExists(atPath: legacyResume.path))
        #expect(!FileManager.default.fileExists(atPath: foreignResume.path))
        #expect(FileManager.default.fileExists(atPath: currentResume.path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(e4b.fileName).path
        ))

        // A file matching the current entry is never removed.
        try writeSparseFile(staleModel, bytes: e2b.expectedBytes)
        #expect(try GGUFModelStorage.removeStaleArtifacts(for: e2b, in: directory) == 0)
        #expect(FileManager.default.fileExists(atPath: staleModel.path))
    }

    @Test func upgradeSpaceCheckCountsTheReclaimedStaleModel() throws {
        let directory = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let e2b = GGUFDownloadCatalog.options[0]
        let staleModel = directory.appendingPathComponent(e2b.fileName)
        let staleBytes: Int64 = 3_427_878_784
        try writeSparseFile(staleModel, bytes: staleBytes)
        // Free space only suffices once the stale model's bytes are returned to the volume.
        let freeWithStaleModel = e2b.expectedBytes + GGUFModelStorage.downloadReserveBytes - staleBytes
        let capacity: (URL) throws -> Int64? = { _ in
            FileManager.default.fileExists(atPath: staleModel.path)
                ? freeWithStaleModel
                : freeWithStaleModel + staleBytes
        }

        try GGUFModelStorage.prepareSpace(for: e2b, in: directory, availableCapacity: capacity)
        #expect(!FileManager.default.fileExists(atPath: staleModel.path))

        // Without anything to reclaim, the same volume is still too full.
        #expect(throws: (any Error).self) {
            try GGUFModelStorage.prepareSpace(for: e2b, in: directory) { _ in freeWithStaleModel }
        }
    }

    /// A paused download already holds its received bytes on the volume, so
    /// resuming only needs room for the remainder plus the reserve.
    @Test func resumeSpaceCheckCreditsTheBytesAlreadyDownloaded() throws {
        let directory = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let e2b = GGUFDownloadCatalog.options[0]
        let received: Int64 = 2_000_000_000
        try Self.resumeData(received: received).write(to: GGUFModelStorage.resumeDataURL(for: e2b, in: directory))
        let remaining = e2b.expectedBytes - received + GGUFModelStorage.downloadReserveBytes

        try GGUFModelStorage.prepareSpace(for: e2b, in: directory) { _ in remaining }
        #expect(throws: (any Error).self) {
            try GGUFModelStorage.prepareSpace(for: e2b, in: directory) { _ in remaining - 1 }
        }

        // Without resume data the whole file is needed again.
        try FileManager.default.removeItem(at: GGUFModelStorage.resumeDataURL(for: e2b, in: directory))
        #expect(throws: (any Error).self) {
            try GGUFModelStorage.prepareSpace(for: e2b, in: directory) { _ in remaining }
        }
    }

    /// URLSession resume data in the shape current systems write: a keyed archive
    /// whose root dictionary sits under the literal key "NSKeyedArchiveRootObjectKey".
    private static func resumeData(received: Int64) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        let info: NSDictionary = [
            "NSURLSessionResumeInfoVersion": 2,
            "NSURLSessionResumeBytesReceived": NSNumber(value: received),
            "NSURLSessionResumeInfoTempFileName": "CFNetworkDownload_test.tmp",
        ]
        archiver.encode(info, forKey: "NSKeyedArchiveRootObjectKey")
        return archiver.encodedData
    }

    @Test func receivedBytesAreReadFromKeyedArchiveAndPlainPlistResumeData() throws {
        #expect(GGUFModelStorage.receivedBytes(inResumeData: Self.resumeData(received: 3_193_413)) == 3_193_413)
        let plain = try PropertyListSerialization.data(
            fromPropertyList: ["NSURLSessionResumeBytesReceived": NSNumber(value: 42)],
            format: .binary,
            options: 0
        )
        #expect(GGUFModelStorage.receivedBytes(inResumeData: plain) == 42)
        #expect(GGUFModelStorage.receivedBytes(inResumeData: Data("not a plist".utf8)) == 0)
        // An archive under Swift's own root key ("root") is not what URLSession writes.
        let swiftRoot = try NSKeyedArchiver.archivedData(
            withRootObject: ["NSURLSessionResumeBytesReceived": NSNumber(value: 7)],
            requiringSecureCoding: false
        )
        #expect(GGUFModelStorage.receivedBytes(inResumeData: swiftRoot) == 7)
    }

    /// Each artifact's record: opened once per download, marked by any choice while it
    /// is open (a paused download is still pending), kept across an internal restart or a
    /// resume, and closed by completion, failure or Stop without touching another artifact's.
    @Test func downloadChoiceRecordsAreKeptPerArtifact() {
        let suite = "gguf-choice-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]

        // No record (a download that began before this rule existed) still selects.
        #expect(GGUFDownloadManager.closeDownloadChoiceWatch(for: e2b, defaults: defaults))

        // Only a first open creates the record; a start that fails before its task
        // closes only a record it created, so a paused download keeps its own.
        #expect(GGUFDownloadManager.openDownloadChoiceWatch(for: e2b, defaults: defaults))
        #expect(!GGUFDownloadManager.openDownloadChoiceWatch(for: e2b, defaults: defaults))
        #expect(GGUFDownloadManager.closeDownloadChoiceWatch(for: e2b, defaults: defaults))

        // A choice while E2B is pending (paused or running) marks E2B only; E4B, started
        // later, consumes its own record.
        GGUFDownloadManager.openDownloadChoiceWatch(for: e2b, defaults: defaults)
        GGUFDownloadManager.noteChoiceDuringDownload(defaults: defaults)
        GGUFDownloadManager.openDownloadChoiceWatch(for: e4b, defaults: defaults)
        #expect(GGUFDownloadManager.closeDownloadChoiceWatch(for: e4b, defaults: defaults))
        // A resume or an internal restart of E2B reopens without forgetting the choice.
        GGUFDownloadManager.openDownloadChoiceWatch(for: e2b, defaults: defaults)
        #expect(!GGUFDownloadManager.closeDownloadChoiceWatch(for: e2b, defaults: defaults))

        // Closing clears the record; a choice with nothing pending is not noted.
        GGUFDownloadManager.noteChoiceDuringDownload(defaults: defaults)
        GGUFDownloadManager.openDownloadChoiceWatch(for: e2b, defaults: defaults)
        #expect(GGUFDownloadManager.closeDownloadChoiceWatch(for: e2b, defaults: defaults))
    }

    /// A relaunch keeps the record of a restored, paused or recoverable download and
    /// drops the record of one a force-quit cancelled.
    @Test func relaunchDropsChoiceRecordsOfDownloadsThatDidNotSurvive() throws {
        let suite = "gguf-choice-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        func openMarked(_ option: GGUFDownloadOption) {
            GGUFDownloadManager.openDownloadChoiceWatch(for: option, defaults: defaults)
            GGUFDownloadManager.noteChoiceDuringDownload(defaults: defaults)
        }

        // Nothing survived: both records go, so a fresh download selects itself.
        openMarked(e2b); openMarked(e4b)
        GGUFDownloadManager.reconcileDownloadChoiceRecords(restoredOptionID: nil, in: directory, defaults: defaults)
        #expect(GGUFDownloadManager.closeDownloadChoiceWatch(for: e2b, defaults: defaults))
        #expect(GGUFDownloadManager.closeDownloadChoiceWatch(for: e4b, defaults: defaults))

        // A restored task keeps its record; a paused one (resume blob) and a recoverable
        // one (staging file) keep theirs too.
        openMarked(e2b); openMarked(e4b)
        GGUFDownloadManager.reconcileDownloadChoiceRecords(restoredOptionID: e2b.id, in: directory, defaults: defaults)
        #expect(!GGUFDownloadManager.closeDownloadChoiceWatch(for: e2b, defaults: defaults))
        #expect(GGUFDownloadManager.closeDownloadChoiceWatch(for: e4b, defaults: defaults))

        openMarked(e2b); openMarked(e4b)
        try Data("resume".utf8).write(to: GGUFModelStorage.resumeDataURL(for: e2b, in: directory))
        try Data("GGUF".utf8).write(to: directory.appendingPathComponent("\(e4b.fileName).download"))
        GGUFDownloadManager.reconcileDownloadChoiceRecords(restoredOptionID: nil, in: directory, defaults: defaults)
        #expect(!GGUFDownloadManager.closeDownloadChoiceWatch(for: e2b, defaults: defaults))
        #expect(!GGUFDownloadManager.closeDownloadChoiceWatch(for: e4b, defaults: defaults))

        // A surviving download from a build without records gets one now, so a choice
        // made after the relaunch still counts when it completes.
        GGUFDownloadManager.reconcileDownloadChoiceRecords(restoredOptionID: nil, in: directory, defaults: defaults)
        GGUFDownloadManager.noteChoiceDuringDownload(defaults: defaults)
        #expect(!GGUFDownloadManager.closeDownloadChoiceWatch(for: e2b, defaults: defaults))
        #expect(!GGUFDownloadManager.closeDownloadChoiceWatch(for: e4b, defaults: defaults))
        try FileManager.default.removeItem(at: GGUFModelStorage.resumeDataURL(for: e2b, in: directory))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("\(e4b.fileName).download"))
        GGUFDownloadManager.reconcileDownloadChoiceRecords(restoredOptionID: e2b.id, in: directory, defaults: defaults)
        GGUFDownloadManager.noteChoiceDuringDownload(defaults: defaults)
        #expect(!GGUFDownloadManager.closeDownloadChoiceWatch(for: e2b, defaults: defaults))
        #expect(GGUFDownloadManager.closeDownloadChoiceWatch(for: e4b, defaults: defaults))
    }

    @Test func preferredModelUsesCatalogOrder() {
        let options = GGUFDownloadCatalog.options
        let preferred = GGUFModelSelection.preferredFileName(
            in: [options[1].fileName, options[0].fileName],
            selectedFileName: nil
        )

        #expect(preferred == options[0].fileName)
    }

    @Test func modelDownloadUsesRedirectCompatibleFullFileRequest() {
        let request = ggufDownloadRequest(for: GGUFDownloadCatalog.options[0])

        #expect(request.value(forHTTPHeaderField: "Range") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
    }

    @Test func modelDownloadRecognizesArtifactsFromRemovedSegmentedDownloader() {
        #expect(isLegacyGGUFDownloadArtifact(fileName: "gemma-4-e2b.segment-0.part"))
        #expect(isLegacyGGUFDownloadArtifact(fileName: "gemma-4-e4b.segment-3.resume"))
        #expect(isLegacyGGUFDownloadArtifact(
            fileName: "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf.download"
        ))
        #expect(!isLegacyGGUFDownloadArtifact(
            fileName: "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf.resume"
        ))
        #expect(!isLegacyGGUFDownloadArtifact(
            fileName: "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf"
        ))
    }
}

@Suite(.serialized)
struct GGUFModelSelectionTests {
    @Test func selectionPersistsAndWinsOverCatalogOrder() {
        let original = GGUFModelSelection.currentFileName
        defer {
            if let original {
                GGUFModelSelection.save(fileName: original)
            } else {
                GGUFModelSelection.clear()
            }
        }

        let options = GGUFDownloadCatalog.options
        GGUFModelSelection.save(fileName: options[1].fileName)

        #expect(GGUFModelSelection.currentFileName == options[1].fileName)
        #expect(
            GGUFModelSelection.preferredFileName(in: options.map(\.fileName))
                == options[1].fileName
        )
    }
}

// MARK: - GGUFEngineChoice

// Serialized: every test reads/writes the same UserDefaults key, so the
// default parallel execution makes them clobber each other.
@Suite(.serialized)
struct GGUFEngineChoiceTests {
    @Test func defaultIsAppleIntelligence() {
        // When no value is stored, current() returns .appleIntelligence.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "ggufEngineChoice")
        #expect(GGUFEngineChoice.current == .appleIntelligence)
    }

    @Test func savePersistsAndRestores() {
        let defaults = UserDefaults.standard
        let originalRaw = defaults.string(forKey: "ggufEngineChoice")
        defer {
            if let r = originalRaw {
                defaults.set(r, forKey: "ggufEngineChoice")
            } else {
                defaults.removeObject(forKey: "ggufEngineChoice")
            }
        }

        GGUFEngineChoice.gemma.save()
        #expect(GGUFEngineChoice.current == .gemma)

        GGUFEngineChoice.appleIntelligence.save()
        #expect(GGUFEngineChoice.current == .appleIntelligence)
    }

    @Test func unknownRawValueFallsBackToApple() {
        let defaults = UserDefaults.standard
        let originalRaw = defaults.string(forKey: "ggufEngineChoice")
        defer {
            if let r = originalRaw {
                defaults.set(r, forKey: "ggufEngineChoice")
            } else {
                defaults.removeObject(forKey: "ggufEngineChoice")
            }
        }

        defaults.set("bogus_value_xyz", forKey: "ggufEngineChoice")
        #expect(GGUFEngineChoice.current == .appleIntelligence)
    }
}

// MARK: - Routing decision: shouldUseGemma

extension GGUFEngineChoiceTests {
    // shouldUseGemma returns false when engine is Apple Intelligence regardless
    // of whether GGUF files are present.
    @Test func appleEngineNeverRoutesToGemma() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "ggufEngineChoice")
        defer {
            if let r = original { defaults.set(r, forKey: "ggufEngineChoice") }
            else { defaults.removeObject(forKey: "ggufEngineChoice") }
        }

        GGUFEngineChoice.appleIntelligence.save()
        // Even if a GGUF magically exists, Apple engine must short-circuit.
        let result = AIService.shouldUseGemma()
        #expect(result == false)
    }

    // shouldUseGemma returns false when engine is Gemma but no GGUF exists
    // (the models directory is either absent or empty).
    @Test func gemmaEngineWithNoFileReturnsFalse() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "ggufEngineChoice")
        defer {
            if let r = original { defaults.set(r, forKey: "ggufEngineChoice") }
            else { defaults.removeObject(forKey: "ggufEngineChoice") }
        }

        GGUFEngineChoice.gemma.save()
        // In the test sandbox, no GGUF has been downloaded, so directory is
        // either missing or has no .gguf files.
        // We can't guarantee the models directory is empty in all CI configs,
        // so only assert the general correctness: if the real device has no
        // GGUF then false is returned. This test is a logic sanity check,
        // not a file-system mutation test.
        let result = AIService.shouldUseGemma()
        // On CI / simulator without any model: must be false.
        // On a device where user downloaded a GGUF: could be true, skip assertion.
        if AIService.firstGGUFPath() == nil {
            #expect(result == false)
        }
    }
}

// MARK: - GGUFModelStub (always compiled, no model needed)

@MainActor
struct GGUFModelStubTests {
    @Test func stubIsNotLoaded() {
        let stub = GGUFModelStub()
        #expect(stub.isLoaded == false)
    }

    @Test func stubLoadThrowsUnavailable() async throws {
        let stub = GGUFModelStub()
        do {
            try await stub.loadModel(filePath: "/nonexistent/model.gguf")
            Issue.record("Expected localModelUnavailable to be thrown")
        } catch AIServiceError.localModelUnavailable {
            // Expected
        }
    }

    @Test func stubGenerateThrowsUnavailable() async throws {
        let stub = GGUFModelStub()
        do {
            _ = try await stub.generate(prompt: "hello")
            Issue.record("Expected localModelUnavailable to be thrown")
        } catch AIServiceError.localModelUnavailable {
            // Expected
        }
    }

    @Test func stubUnloadIsNoop() {
        // Should not crash or throw.
        let stub = GGUFModelStub()
        stub.unload()
        #expect(stub.isLoaded == false)
    }
}

// MARK: - Gemma rewrite prompt: punchUp uses raw instruction (no softening)

struct GemmaRewritePromptTests {
    @Test func punchUpUsesRawInstruction() {
        let service = AIService()
        let prompt = service.buildGemmaRewritePromptForTest(
            action: .punchUp,
            lyrics: "[Verse]\nCity lights glow on the boulevard",
            selection: "City lights glow on the boulevard",
            currentSection: .verse,
            selectionStart: nil,
            rejectedCandidates: []
        )
        // Must contain the raw punchUp instruction (not the softened Apple version).
        #expect(prompt.contains(RewriteAction.punchUp.instruction))
        // Must NOT contain the Apple-softened version.
        let appleVersion = "sharper, bolder, more vivid imagery"
        #expect(!prompt.contains(appleVersion))
    }

    @Test func rephraseInstructionPassedThrough() {
        let service = AIService()
        let prompt = service.buildGemmaRewritePromptForTest(
            action: .rephrase,
            lyrics: "[Verse]\nI keep a notebook under neon rain",
            selection: "I keep a notebook under neon rain",
            currentSection: .verse,
            selectionStart: nil,
            rejectedCandidates: []
        )
        #expect(prompt.contains(RewriteAction.rephrase.instruction))
    }
}

struct GGUFDownloadIntegrityTests {
    @Test func modelDirectoryIsExcludedFromBackup() throws {
        let directory = try GGUFModelStorage.modelsDirectory(create: true)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func invalidStagingIsDiscardedAndFreshDownloadCanBeInstalled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = Data([0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4])
        let option = GGUFDownloadOption(
            id: "fixture", title: "Fixture", subtitle: "", size: "8 B",
            fileName: "fixture.gguf", expectedBytes: Int64(valid.count),
            sha256: SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/fixture.gguf")!, isRecommended: false
        )
        let staging = directory.appendingPathComponent("fixture.gguf.download")
        let resume = GGUFModelStorage.resumeDataURL(for: option, in: directory)
        let destination = directory.appendingPathComponent(option.fileName)
        let previousModel = Data("existing model".utf8)
        try previousModel.write(to: destination)
        var corrupt = valid
        corrupt[7] = 9
        for invalid in [Data(repeating: 0, count: valid.count), corrupt, Data(valid.dropLast())] {
            try invalid.write(to: staging)
            try Data([1, 2]).write(to: resume)
            #expect(throws: (any Error).self) {
                try GGUFDownloadManager.installDownload(from: staging, in: directory, option: option)
            }
            #expect(!FileManager.default.fileExists(atPath: staging.path))
            #expect(!FileManager.default.fileExists(atPath: resume.path))
            #expect(try Data(contentsOf: destination) == previousModel)
        }
        try valid.write(to: staging)
        try Data([1, 2]).write(to: resume)
        try GGUFDownloadManager.installDownload(from: staging, in: directory, option: option)
        #expect(try Data(contentsOf: destination) == valid)
        #expect(try destination.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: resume.path))
    }

    @Test func filesystemFailurePreservesValidatedStagingForRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = Data([0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4])
        let option = GGUFDownloadOption(
            id: "fixture", title: "Fixture", subtitle: "", size: "8 B",
            fileName: "fixture.gguf", expectedBytes: Int64(valid.count),
            sha256: SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/fixture.gguf")!, isRecommended: false
        )
        let staging = directory.appendingPathComponent("fixture.gguf.download")
        try valid.write(to: staging)
        #expect(throws: (any Error).self) {
            try GGUFDownloadManager.installDownload(
                from: staging, in: directory.appendingPathComponent("missing"), option: option
            )
        }
        #expect(try Data(contentsOf: staging) == valid)
    }

    @Test func replacementFailurePreservesExistingModelAndStaging() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let valid = Data([0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4])
        let previousModel = Data("existing model".utf8)
        let option = GGUFDownloadOption(
            id: "fixture", title: "Fixture", subtitle: "", size: "8 B",
            fileName: "fixture.gguf", expectedBytes: Int64(valid.count),
            sha256: SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/fixture.gguf")!, isRecommended: false
        )
        let staging = directory.appendingPathComponent("fixture.gguf.download")
        let destination = directory.appendingPathComponent(option.fileName)
        let resume = GGUFModelStorage.resumeDataURL(for: option, in: directory)
        try valid.write(to: staging)
        try previousModel.write(to: destination)
        try Data([1, 2]).write(to: resume)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        #expect(throws: (any Error).self) {
            try GGUFDownloadManager.installDownload(from: staging, in: directory, option: option)
        }
        #expect(try Data(contentsOf: destination) == previousModel)
        #expect(try Data(contentsOf: staging) == valid)
        #expect(try Data(contentsOf: resume) == Data([1, 2]))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try GGUFDownloadManager.installDownload(from: staging, in: directory, option: option)
        #expect(try Data(contentsOf: destination) == valid)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(!FileManager.default.fileExists(atPath: resume.path))
    }

    @Test func validatesCompleteModelAndRejectsCorruption() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data([0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4])
        let option = GGUFDownloadOption(
            id: "fixture", title: "Fixture", subtitle: "", size: "8 B",
            fileName: "fixture.gguf", expectedBytes: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/fixture.gguf")!, isRecommended: false
        )
        try data.write(to: url)
        try GGUFDownloadManager.validateDownload(at: url, option: option)
        try data.dropLast().write(to: url)
        #expect(throws: (any Error).self) {
            try GGUFDownloadManager.validateDownload(at: url, option: option)
        }
        var corrupted = data
        corrupted[7] = 9
        try corrupted.write(to: url)
        #expect(throws: (any Error).self) {
            try GGUFDownloadManager.validateDownload(at: url, option: option)
        }
    }
}

@Suite(.serialized)
struct GGUFCustomModelRegistryTests {
    @Test func selectionRejectsUnregisteredFilesAndPreservesExplicitCustomChoice() throws {
        let name = "CompositionSelection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let custom = GGUFCustomModel(id: "custom", displayName: "Custom", fileName: "custom.gguf")
        #expect(GGUFModelSelection.preferredFileName(in: ["unknown.gguf"], selectedFileName: nil, defaults: defaults) == nil)
        GGUFCustomModelRegistry.register(custom, defaults: defaults)
        let catalog = GGUFDownloadCatalog.options[0].fileName
        #expect(GGUFModelSelection.preferredFileName(in: [catalog, custom.fileName], selectedFileName: custom.fileName, defaults: defaults) == custom.fileName)
        #expect(GGUFModelSelection.preferredFileName(in: ["../custom.gguf"], selectedFileName: "../custom.gguf", defaults: defaults) == nil)
        #expect(GGUFModelSelection.preferredFileName(in: [catalog, "unknown.gguf"], selectedFileName: "unknown.gguf", defaults: defaults) == catalog)
    }

    @Test func customModelRegistrationAndSelectionSurviveReload() throws {
        let suiteName = "GGUFCustomModelRegistryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelURL = directory.appendingPathComponent("custom-night-drive.gguf")
        let header = Data([
            0x47, 0x47, 0x55, 0x46,
            0x03, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        FileManager.default.createFile(atPath: modelURL.path, contents: header)
        let model = GGUFCustomModel(
            id: "custom-night-drive",
            displayName: "Night Drive",
            fileName: modelURL.lastPathComponent
        )

        GGUFCustomModelRegistry.save([model], defaults: defaults)
        GGUFModelSelection.save(fileName: model.fileName, defaults: defaults)

        #expect(GGUFCustomModelRegistry.models(defaults: defaults) == [model])
        #expect(
            GGUFModelSelection.resolvedModelURL(
                defaults: defaults,
                modelsDirectory: directory
            ) == modelURL
        )
    }
}

struct GGUFCustomModelValidationTests {
    @Test func rejectsTruncatedMagicOnlyFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).gguf")
        try Data("GGUF".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            try GGUFModelCatalog.validateCustomFile(at: fileURL)
            Issue.record("Expected a truncated GGUF header to be rejected")
        } catch AIServiceError.localModelUnavailable {
        }
    }
}

// MARK: - GGUFModelStub (always compiled, no model needed)

struct GGUFResidentFileIdentityTests {
    @Test func unchangedFileKeepsIdentityAndSelectionRevisionMatters() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("one model".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let identity = try GGUFModelFileIdentity.read(at: file.path)
        let resident = GGUFResidentIdentity(file: identity, selection: GGUFModelSelection.Snapshot(fileName: nil, revision: 11), verifiedSHA256: "fixture")
        #expect(try GGUFModelFileIdentity.read(at: file.path) == identity)
        #expect(resident.matchesCurrentFile(selection: GGUFModelSelection.Snapshot(fileName: nil, revision: 11)))
        #expect(!resident.matchesCurrentFile(selection: GGUFModelSelection.Snapshot(fileName: nil, revision: 12)))
        #expect(!resident.matchesCurrentFile(selection: GGUFModelSelection.Snapshot(fileName: "other.gguf", revision: 11)))
    }

    @Test func atomicSameSizeReplacementInvalidatesResident() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("first".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = try GGUFModelFileIdentity.read(at: file.path)
        let resident = GGUFResidentIdentity(file: original, selection: GGUFModelSelection.Snapshot(fileName: nil, revision: 3), verifiedSHA256: "fixture")
        try Data("other".utf8).write(to: file, options: .atomic)
        let replacement = try GGUFModelFileIdentity.read(at: file.path)
        #expect(replacement.size == original.size)
        #expect(replacement != original)
        #expect(!resident.matchesCurrentFile(selection: GGUFModelSelection.Snapshot(fileName: nil, revision: 3)))
    }

    @Test func inPlaceWriteWithRestoredModificationDateStillInvalidatesResident() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("first".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = try GGUFModelFileIdentity.read(at: file.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let modified = try #require(attributes[.modificationDate] as? Date)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("other".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let replacement = try GGUFModelFileIdentity.read(at: file.path)
        #expect(replacement.inode == original.inode)
        #expect(replacement.size == original.size)
        #expect(replacement.changedSeconds != original.changedSeconds || replacement.changedNanoseconds != original.changedNanoseconds)
        #expect(replacement != original)
    }

    @Test func deletedFileInvalidatesResident() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("first".utf8).write(to: file)
        let resident = GGUFResidentIdentity(file: try GGUFModelFileIdentity.read(at: file.path), selection: GGUFModelSelection.Snapshot(fileName: nil, revision: 1), verifiedSHA256: "fixture")
        try FileManager.default.removeItem(at: file)
        #expect(!resident.matchesCurrentFile(selection: GGUFModelSelection.Snapshot(fileName: nil, revision: 1)))
        #expect(throws: (any Error).self) { try GGUFModelFileIdentity.read(at: file.path) }
    }
}


struct GGUFSelectionCaptureTests {
    @Test(arguments: [false, true])
    func selectionChangedDuringFileCaptureIsRejected(returnToOriginal: Bool) throws {
        let suite = "selection-capture-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = GGUFModelCatalog.models
        let a = try #require(models.first)
        let b = try #require(models.last)
        #expect(a.fileName != b.fileName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(a.fileName)
        try Data("fixture".utf8).write(to: file)
        GGUFModelSelection.save(fileName: a.fileName, defaults: defaults)
        #expect(throws: (any Error).self) {
            try GGUFModelSelection.captureForLoading(filePath: file.path, defaults: defaults) { path in
                // Deterministic boundary: selection changes after entry, before metadata returns.
                GGUFModelSelection.save(fileName: b.fileName, defaults: defaults)
                if returnToOriginal { GGUFModelSelection.save(fileName: a.fileName, defaults: defaults) }
                return try GGUFModelFileIdentity.read(at: path)
            }
        }
    }

    @Test func unchangedSelectionCaptureRetainsFilenameAndRevision() throws {
        let suite = "selection-capture-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = try #require(GGUFModelCatalog.models.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(a.fileName)
        try Data("fixture".utf8).write(to: file)
        GGUFModelSelection.save(fileName: a.fileName, defaults: defaults)
        let captured = try GGUFModelSelection.captureForLoading(filePath: file.path, defaults: defaults)
        #expect(captured.selection.fileName == a.fileName)
        #expect(captured.selection == GGUFModelSelection.snapshot(defaults: defaults))
        #expect(captured.file == (try GGUFModelFileIdentity.read(at: file.path)))
    }
}

/// Completion through the manager, with both catalog artifacts installed and verified so
/// `select` can run: a model or engine chosen while a download was pending is kept,
/// including one switched away and back, and completion's own selection of another
/// download is not a choice. The models directory, markers and selection are app-wide
/// state, so the suite restores them.
@MainActor
@Suite(.serialized)
struct GGUFDownloadCompletionTests {
    @Test func completionSelectsTheDownloadUnlessAChoiceWasMadeWhileItRan() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let directory = try GGUFModelStorage.modelsDirectory(create: true)
        for option in [e2b, e4b] {
            let installed = directory.appendingPathComponent(option.fileName)
            try #require(!FileManager.default.fileExists(atPath: installed.path), "a real install is never touched")
            #expect(FileManager.default.createFile(atPath: installed.path, contents: Data("GGUF".utf8)))
            let handle = try FileHandle(forWritingTo: installed)
            try handle.truncate(atOffset: UInt64(option.expectedBytes))
            try handle.close()
            GGUFVerifiedArtifactStore.record(sha256: option.sha256, at: installed)
        }
        let savedFile = GGUFModelSelection.currentFileName
        let savedEngine = GGUFEngineChoice.current
        defer {
            for option in [e2b, e4b] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(option.fileName))
                GGUFVerifiedArtifactStore.remove(fileName: option.fileName)
            }
            if let savedFile { GGUFModelSelection.save(fileName: savedFile) } else { GGUFModelSelection.clear() }
            savedEngine.save()
        }
        let suite = "gguf-completion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = GGUFDownloadManager(configuration: .ephemeral, defaults: defaults)
        // Choices made while restoration is pending are judged by the restoration tests.
        for _ in 0..<250 where manager.isRestoringDownloads {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!manager.isRestoringDownloads)
        manager.refreshInstalledModels()
        try #require(manager.installedModelFiles.isSuperset(of: [e2b.fileName, e4b.fileName]))

        // Nothing chosen while it ran: the download is selected and persisted.
        manager.selectEngine(.appleIntelligence)
        manager.select(e4b)
        manager.beginDownloadForTest(e2b)
        #expect(manager.finishForTest(e2b))
        #expect(manager.engineChoice == .gemma)
        #expect(manager.selectedModelFileName == e2b.fileName)
        #expect(GGUFModelSelection.currentFileName == e2b.fileName)
        #expect(GGUFEngineChoice.current == .gemma)
        #expect(manager.statusMessage == "\(e2b.title) downloaded and selected.")

        // An engine chosen while it ran stays.
        manager.beginDownloadForTest(e2b)
        manager.selectEngine(.appleIntelligence)
        #expect(!manager.finishForTest(e2b))
        #expect(manager.engineChoice == .appleIntelligence)
        #expect(GGUFEngineChoice.current == .appleIntelligence)
        #expect(manager.statusMessage == "\(e2b.title) downloaded.")

        // Another model chosen while it ran stays, in memory and on disk.
        manager.beginDownloadForTest(e2b)
        manager.select(e4b)
        #expect(!manager.finishForTest(e2b))
        #expect(manager.selectedModelFileName == e4b.fileName)
        #expect(GGUFModelSelection.currentFileName == e4b.fileName)

        // Switching away and back is still a choice made while it ran.
        manager.beginDownloadForTest(e2b)
        manager.select(e2b)
        manager.select(e4b)
        #expect(!manager.finishForTest(e2b))
        #expect(manager.selectedModelFileName == e4b.fileName)

        // Another download finishing (paused E2B, E4B downloaded meanwhile) is not a
        // choice: the resumed E2B is still selected when it completes.
        manager.beginDownloadForTest(e2b)
        manager.beginDownloadForTest(e4b)
        #expect(manager.finishForTest(e4b))
        #expect(manager.selectedModelFileName == e4b.fileName)
        #expect(manager.finishForTest(e2b))
        #expect(manager.selectedModelFileName == e2b.fileName)
        #expect(GGUFModelSelection.currentFileName == e2b.fileName)
    }

    /// A paused download inherited from a build without records gets one during startup
    /// restoration; an engine chosen before that finishes still marks it.
    @Test func aChoiceDuringStartupRestorationMarksAnInheritedPausedDownload() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let directory = try GGUFModelStorage.modelsDirectory(create: true)
        let resumeURL = GGUFModelStorage.resumeDataURL(for: e2b, in: directory)
        try #require(!FileManager.default.fileExists(atPath: resumeURL.path), "a real paused download is never touched")
        try Data("resume".utf8).write(to: resumeURL)
        defer { try? FileManager.default.removeItem(at: resumeURL) }
        let savedEngine = GGUFEngineChoice.current
        defer { savedEngine.save() }
        let suite = "gguf-restoration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = GGUFDownloadManager(configuration: .ephemeral, defaults: defaults)
        try #require(manager.isRestoringDownloads)
        manager.selectEngine(.appleIntelligence)
        for _ in 0..<250 where manager.isRestoringDownloads {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(!manager.isRestoringDownloads)

        #expect(!GGUFDownloadManager.closeDownloadChoiceWatch(for: e2b, defaults: defaults))
    }

    /// A completion delivered before task discovery finishes still honours an engine
    /// chosen during restoration, although no record exists yet.
    @Test func aCompletionBeforeRestorationFinishesHonoursTheChoiceMadeMeanwhile() throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let savedEngine = GGUFEngineChoice.current
        defer { savedEngine.save() }
        let suite = "gguf-restoration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = GGUFDownloadManager(configuration: .ephemeral, defaults: defaults)
        try #require(manager.isRestoringDownloads)
        manager.selectEngine(.appleIntelligence)
        #expect(!manager.finishForTest(e2b))
        #expect(manager.engineChoice == .appleIntelligence)
        #expect(manager.statusMessage == "\(e2b.title) downloaded.")
    }
}
