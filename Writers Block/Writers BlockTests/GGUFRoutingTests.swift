import CryptoKit
import Foundation
import Testing
import XCTest
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
            id: "fixture", title: "Fixture", character: "",
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

    @Test func fileDigestMatchesCryptoKitAcrossChunkBoundaries() throws {
        let directory = try makeModelsDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Three 1 MiB chunks plus a short tail, so the loop crosses chunk boundaries and ends mid-chunk.
        var bytes = Data(count: 3 * 1_048_576 + 17)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31) }
        let url = directory.appendingPathComponent("digest.gguf")
        try bytes.write(to: url)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try GGUFModelCatalog.fileSHA256(at: url) == expected)
    }

    /// Android's `gemmaModelNeedsMoreMemory`: only E4B, and only below 10 GiB of RAM.
    @Test func onlyE4BNeedsMoreMemoryBelowTenGibibytes() {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let gib: UInt64 = 1 << 30
        #expect(GGUFDownloadCatalog.needsMoreMemory(e4b, totalRAMBytes: 8 * gib))
        #expect(GGUFDownloadCatalog.needsMoreMemory(e4b, totalRAMBytes: 10 * gib - 1))
        #expect(!GGUFDownloadCatalog.needsMoreMemory(e4b, totalRAMBytes: 10 * gib))
        #expect(!GGUFDownloadCatalog.needsMoreMemory(e2b, totalRAMBytes: 4 * gib))
        #expect(GGUFDownloadCatalog.needsMoreMemoryMessage == "May be slow on this device — needs more memory")
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

    @Test func preferredModelUsesCatalogOrder() {
        // Own defaults: the standard domain may carry a cleared selection from a UI-test delete.
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let options = GGUFDownloadCatalog.options
        let preferred = GGUFModelSelection.preferredFileName(
            in: [options[1].fileName, options[0].fileName],
            selectedFileName: nil,
            defaults: defaults
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

// MARK: - Cleared selection routing

/// Serialized: reads and writes the standard engine, selection and cleared-flag keys.
@Suite(.serialized)
@MainActor
struct GGUFClearedChoiceRoutingTests {
    @Test func synonymsStayOnTheNoModelErrorWhileGemmaIsChosenWithAClearedSelection() async throws {
        let defaults = UserDefaults.standard
        let originalEngine = defaults.string(forKey: "ggufEngineChoice")
        let originalSelection = GGUFModelSelection.currentFileName
        let originalCleared = GGUFModelSelection.isCleared()
        defer {
            if let originalEngine { defaults.set(originalEngine, forKey: "ggufEngineChoice") } else { defaults.removeObject(forKey: "ggufEngineChoice") }
            if let originalSelection { GGUFModelSelection.save(fileName: originalSelection) } else { GGUFModelSelection.clear() }
            if !originalCleared { defaults.removeObject(forKey: "ggufModelSelectionCleared") }
        }
        GGUFEngineChoice.gemma.save()
        GGUFModelSelection.clearExplicitly()
        #expect(AIService.gemmaChoiceCleared())
        #expect(LocalReadiness.current().title == "Choose a model")

        do {
            _ = try await AIService().getSynonyms(provider: .local, apiKey: "", modelId: "local-model", word: "light", lineContext: "a quiet light")
            Issue.record("Expected the no-model error")
        } catch AIServiceError.localModelUnavailable(let reason) {
            #expect(reason == AIService.noGGUFModelReason)
        }

        // Choosing Apple Intelligence lifts it; the cleared flag itself stays until a model is chosen.
        GGUFEngineChoice.appleIntelligence.save()
        #expect(!AIService.gemmaChoiceCleared())
        #expect(GGUFModelSelection.isCleared())
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
            id: "fixture", title: "Fixture", character: "",
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

    @Test func gatedInstallPublishesThroughTheRunner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = Data([0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4])
        let option = GGUFDownloadOption(
            id: "fixture", title: "Fixture", character: "",
            fileName: "fixture.gguf", expectedBytes: Int64(valid.count),
            sha256: SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/fixture.gguf")!, isRecommended: false
        )
        let staging = directory.appendingPathComponent("fixture.gguf.download")
        let destination = directory.appendingPathComponent(option.fileName)
        let suite = "gguf-gated-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try Data(valid.dropLast()).write(to: staging)
        await #expect(throws: (any Error).self) {
            try await GGUFDownloadManager.installDownloadGated(from: staging, in: directory, option: option, defaults: defaults)
        }
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        try valid.write(to: staging)
        try await GGUFDownloadManager.installDownloadGated(from: staging, in: directory, option: option, defaults: defaults)
        #expect(try Data(contentsOf: destination) == valid)
        #expect(GGUFVerifiedArtifactStore.marker(fileName: option.fileName, defaults: defaults)?.sha256 == option.sha256)
    }

    @Test func filesystemFailurePreservesValidatedStagingForRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = Data([0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4])
        let option = GGUFDownloadOption(
            id: "fixture", title: "Fixture", character: "",
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
            id: "fixture", title: "Fixture", character: "",
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
            id: "fixture", title: "Fixture", character: "",
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

/// Completion through the manager, each test on its own temporary models root and
/// defaults, with both catalog artifacts installed and verified there so `select` can
/// run: the download selects itself only while the choice revision it started under is
/// still current; a completion with no live snapshot (a manager that restored after a
/// relaunch) installs without selecting.
@MainActor
struct GGUFDownloadCompletionTests {
    private struct Sandbox {
        let root: URL
        let defaults: UserDefaults
        let suite: String

        init() throws {
            suite = "gguf-completion-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func install(_ options: [GGUFDownloadOption]) throws {
            for option in options {
                let installed = root.appendingPathComponent(option.fileName)
                #expect(FileManager.default.createFile(atPath: installed.path, contents: Data("GGUF".utf8)))
                let handle = try FileHandle(forWritingTo: installed)
                try handle.truncate(atOffset: UInt64(option.expectedBytes))
                try handle.close()
                GGUFVerifiedArtifactStore.record(sha256: option.sha256, at: installed, defaults: defaults)
            }
        }

        @MainActor
        func restoredManager(totalRAMBytes: UInt64 = 16 << 30) async throws -> GGUFDownloadManager {
            let manager = GGUFDownloadManager(
                configuration: .ephemeral, modelsRoot: root, defaults: defaults, totalRAMBytes: totalRAMBytes
            )
            for _ in 0..<250 where manager.isRestoringDownloads {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(!manager.isRestoringDownloads)
            manager.refreshInstalledModels()
            return manager
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// On a device short on memory for E4B (an 8 GB iPad), its download is installed but
    /// never selected on its own; choosing it stays explicit and carries Android's warning.
    @Test func completionKeepsAModelTheDeviceIsShortOnMemoryForInstalledButUnselected() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.install([e2b, e4b])
        let manager = try await sandbox.restoredManager(totalRAMBytes: 8 << 30)
        manager.select(e2b)

        manager.beginDownloadForTest(e4b)
        #expect(!manager.finishForTest(e4b))
        #expect(manager.installedModelFiles.contains(e4b.fileName))
        #expect(manager.selectedModelFileName == e2b.fileName)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == e2b.fileName)
        #expect(manager.statusMessage == "\(e4b.title) downloaded but not selected. May be slow on this device — needs more memory.")

        manager.select(e4b)
        #expect(manager.selectedModelFileName == e4b.fileName)
        #expect(manager.statusMessage == "\(e4b.title) selected. May be slow on this device — needs more memory.")

        // A choice made while it ran still carries the warning.
        manager.select(e2b)
        manager.beginDownloadForTest(e4b)
        manager.selectEngine(.appleIntelligence)
        #expect(!manager.finishForTest(e4b))
        #expect(manager.statusMessage == "\(e4b.title) downloaded. May be slow on this device — needs more memory.")

        // E2B is never gated, and a device with enough memory selects E4B on completion.
        manager.beginDownloadForTest(e2b)
        #expect(manager.finishForTest(e2b))
        #expect(manager.statusMessage == "\(e2b.title) downloaded and selected.")
        let roomy = try await sandbox.restoredManager(totalRAMBytes: 16 << 30)
        roomy.beginDownloadForTest(e4b)
        #expect(roomy.finishForTest(e4b))
        #expect(roomy.statusMessage == "\(e4b.title) downloaded and selected.")
    }

    /// With E4B the only installed model and nothing chosen, neither the manager's refresh
    /// nor runtime resolution falls back to it on a device short on memory; an explicit
    /// saved choice of E4B is still honoured.
    @Test func fallbackNeverPicksAModelTheDeviceIsShortOnMemoryFor() async throws {
        let e4b = GGUFDownloadCatalog.options[1]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.install([e4b])
        let small: UInt64 = 8 << 30
        let roomy: UInt64 = 16 << 30

        let manager = try await sandbox.restoredManager(totalRAMBytes: small)
        #expect(manager.selectedModelFileName == nil)
        manager.beginDownloadForTest(e4b)
        #expect(!manager.finishForTest(e4b))
        #expect(manager.selectedModelFileName == nil)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == nil)
        #expect(manager.statusMessage == "\(e4b.title) downloaded but not selected. May be slow on this device — needs more memory.")

        #expect(GGUFModelSelection.preferredFileName(
            in: [e4b.fileName], selectedFileName: nil, defaults: sandbox.defaults, totalRAMBytes: small
        ) == nil)
        #expect(GGUFModelSelection.preferredFileName(
            in: [e4b.fileName], selectedFileName: nil, defaults: sandbox.defaults, totalRAMBytes: roomy
        ) == e4b.fileName)
        #expect(GGUFModelSelection.resolvedModelURL(
            defaults: sandbox.defaults, modelsDirectory: sandbox.root, totalRAMBytes: small
        ) == nil)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == nil)

        // The user's explicit choice is kept, on refresh and at runtime.
        manager.select(e4b)
        #expect(manager.selectedModelFileName == e4b.fileName)
        manager.refreshInstalledModels()
        #expect(manager.selectedModelFileName == e4b.fileName)
        #expect(GGUFModelSelection.resolvedModelURL(
            defaults: sandbox.defaults, modelsDirectory: sandbox.root, totalRAMBytes: small
        )?.lastPathComponent == e4b.fileName)
        #expect(try await sandbox.restoredManager(totalRAMBytes: roomy).selectedModelFileName == e4b.fileName)
    }

    @Test func completionSelectsTheDownloadUnlessAChoiceWasMadeWhileItRan() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.install([e2b, e4b])
        let manager = try await sandbox.restoredManager()
        try #require(manager.installedModelFiles == [e2b.fileName, e4b.fileName])

        // Nothing chosen while it ran: the download is selected and persisted.
        manager.selectEngine(.appleIntelligence)
        manager.select(e4b)
        manager.beginDownloadForTest(e2b)
        #expect(manager.finishForTest(e2b))
        #expect(manager.engineChoice == .gemma)
        #expect(manager.selectedModelFileName == e2b.fileName)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == e2b.fileName)
        #expect(GGUFEngineChoice.current(defaults: sandbox.defaults) == .gemma)
        #expect(manager.statusMessage == "\(e2b.title) downloaded and selected.")

        // An engine chosen while it ran stays.
        manager.beginDownloadForTest(e2b)
        manager.selectEngine(.appleIntelligence)
        #expect(!manager.finishForTest(e2b))
        #expect(manager.engineChoice == .appleIntelligence)
        #expect(GGUFEngineChoice.current(defaults: sandbox.defaults) == .appleIntelligence)
        #expect(manager.statusMessage == "\(e2b.title) downloaded.")

        // Another model chosen while it ran stays, in memory and on disk.
        manager.beginDownloadForTest(e2b)
        manager.select(e4b)
        #expect(!manager.finishForTest(e2b))
        #expect(manager.selectedModelFileName == e4b.fileName)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == e4b.fileName)

        // Switching away and back is still a choice made while it ran.
        manager.beginDownloadForTest(e2b)
        manager.select(e2b)
        manager.select(e4b)
        #expect(!manager.finishForTest(e2b))
        #expect(manager.selectedModelFileName == e4b.fileName)

        // The snapshot is consumed, so the next download starts clean.
        manager.beginDownloadForTest(e2b)
        #expect(manager.finishForTest(e2b))
        #expect(manager.selectedModelFileName == e2b.fileName)
    }

    /// A download the system finished for a manager that did not start it (restored
    /// after a relaunch) has no snapshot: it is installed, not selected.
    @Test func completionWithoutALiveSnapshotInstallsWithoutSelecting() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.install([e2b, e4b])
        let manager = try await sandbox.restoredManager()
        manager.select(e4b)
        manager.selectEngine(.appleIntelligence)

        #expect(!manager.finishForTest(e2b))
        #expect(manager.installedModelFiles.contains(e2b.fileName))
        #expect(manager.selectedModelFileName == e4b.fileName)
        #expect(manager.engineChoice == .appleIntelligence)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == e4b.fileName)
        #expect(manager.statusMessage == "\(e2b.title) downloaded.")
    }

    /// Delete removes the file, its staging and resume artifacts and the verified marker.
    /// Deleting the selected model leaves nothing selected: neither the manager's refresh nor
    /// runtime resolution takes up the other installed model, until the next explicit choice.
    @Test func deleteRemovesArtifactsAndMarkerAndClearsTheSelectionWithoutFallback() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.install([e2b, e4b])
        let staging = sandbox.root.appendingPathComponent("\(e2b.fileName).download")
        let resume = GGUFModelStorage.resumeDataURL(for: e2b, in: sandbox.root)
        let legacyResume = sandbox.root.appendingPathComponent("\(e2b.fileName).resume")
        for url in [staging, resume, legacyResume] { try Data("partial".utf8).write(to: url) }
        let manager = try await sandbox.restoredManager()
        manager.select(e2b)
        try #require(manager.bytesOnDisk[e2b.fileName] == e2b.expectedBytes)

        await manager.delete(e2b)

        for url in [sandbox.root.appendingPathComponent(e2b.fileName), staging, resume, legacyResume] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(GGUFVerifiedArtifactStore.marker(fileName: e2b.fileName, defaults: sandbox.defaults) == nil)
        #expect(FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent(e4b.fileName).path))
        #expect(manager.installedModelFiles == [e4b.fileName])
        #expect(manager.bytesOnDisk[e2b.fileName] == nil)
        #expect(manager.statusMessage == "\(e2b.title) deleted.")
        #expect(manager.errorMessage == nil)
        #expect(manager.freedSpace[e2b.fileName]?.bytes == e2b.expectedBytes)

        #expect(manager.selectedModelFileName == nil)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == nil)
        manager.refreshInstalledModels()
        #expect(manager.selectedModelFileName == nil)
        #expect(GGUFModelSelection.resolvedModelURL(defaults: sandbox.defaults, modelsDirectory: sandbox.root) == nil)
        #expect(try await sandbox.restoredManager().selectedModelFileName == nil)

        // The next explicit choice turns the fallback back on.
        manager.select(e4b)
        #expect(manager.selectedModelFileName == e4b.fileName)
        #expect(GGUFModelSelection.resolvedModelURL(defaults: sandbox.defaults, modelsDirectory: sandbox.root)?.lastPathComponent == e4b.fileName)
    }

    /// A same-name file of the wrong size (a previous version) is not installed, but Delete
    /// still offers and removes it; another model's selection is untouched.
    @Test func staleSameNameFileIsDeletableAndKeepsAnotherSelection() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.install([e4b])
        let stale = sandbox.root.appendingPathComponent(e2b.fileName)
        #expect(FileManager.default.createFile(atPath: stale.path, contents: Data("GGUF".utf8)))
        let handle = try FileHandle(forWritingTo: stale)
        try handle.truncate(atOffset: 3_427_878_784)
        try handle.close()
        let manager = try await sandbox.restoredManager()
        manager.select(e4b)
        #expect(!manager.installedModelFiles.contains(e2b.fileName))
        #expect(manager.bytesOnDisk[e2b.fileName] == 3_427_878_784)

        await manager.delete(e2b)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(manager.bytesOnDisk[e2b.fileName] == nil)
        #expect(manager.installedModelFiles == [e4b.fileName])
        #expect(manager.selectedModelFileName == e4b.fileName)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == e4b.fileName)
        #expect(manager.errorMessage == nil)
    }

    /// The persisted selection can name a stale file while the manager shows the verified
    /// fallback; deleting that file still clears the selection, and nothing is taken up.
    @Test func deletingAStaleFileThatIsThePersistedSelectionClearsIt() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.install([e4b])
        let stale = sandbox.root.appendingPathComponent(e2b.fileName)
        #expect(FileManager.default.createFile(atPath: stale.path, contents: Data("GGUF".utf8)))
        let handle = try FileHandle(forWritingTo: stale)
        try handle.truncate(atOffset: 3_427_878_784)
        try handle.close()
        GGUFModelSelection.save(fileName: e2b.fileName, defaults: sandbox.defaults)
        let manager = try await sandbox.restoredManager()
        try #require(manager.selectedModelFileName == e4b.fileName)
        try #require(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == e2b.fileName)

        await manager.delete(e2b)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(manager.selectedModelFileName == nil)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == nil)
        #expect(GGUFModelSelection.resolvedModelURL(defaults: sandbox.defaults, modelsDirectory: sandbox.root) == nil)
        #expect(AIService.gemmaChoiceCleared(engineChoice: .gemma, cleared: GGUFModelSelection.isCleared(defaults: sandbox.defaults)))
        #expect(!AIService.gemmaChoiceCleared(engineChoice: .appleIntelligence, cleared: true))
    }

    /// Only this entry's artifacts go: a similarly named file, a resume blob of another
    /// entry and a custom import stay.
    @Test func deleteLeavesSimilarlyNamedFilesAlone() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.install([e2b])
        let kept = [
            sandbox.root.appendingPathComponent("\(e2b.fileName).backup.gguf"),
            sandbox.root.appendingPathComponent("\(e2b.fileName).notes.resume"),
            sandbox.root.appendingPathComponent("\(e2b.id).segment-personal.gguf"),
            sandbox.root.appendingPathComponent("\(e2b.id).segment-personal.part"),
            sandbox.root.appendingPathComponent("custom-notes.txt"),
            GGUFModelStorage.resumeDataURL(for: e4b, in: sandbox.root),
        ]
        let removed = [
            sandbox.root.appendingPathComponent("\(e2b.fileName).download"),
            sandbox.root.appendingPathComponent("\(e2b.id).segment-0.part"),
            sandbox.root.appendingPathComponent("\(e2b.fileName).resume"),
            GGUFModelStorage.resumeDataURL(for: e2b, in: sandbox.root),
        ]
        for url in kept + removed { try Data("x".utf8).write(to: url) }
        // A directory under an artifact name is never removed.
        let folder = sandbox.root.appendingPathComponent("\(e2b.id).segment-1.part", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let manager = try await sandbox.restoredManager()

        await manager.delete(e2b)

        #expect(manager.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        for url in kept { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        for url in removed + [sandbox.root.appendingPathComponent(e2b.fileName)] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }
    }

    /// A directory under the catalog name is neither offered for deletion nor removed.
    @Test func directoryUnderTheModelNameIsNeitherDeletableNorRemoved() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let folder = sandbox.root.appendingPathComponent(e2b.fileName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        let manager = try await sandbox.restoredManager()
        #expect(manager.bytesOnDisk[e2b.fileName] == nil)

        await manager.delete(e2b)

        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("inside.txt").path))
        #expect(manager.errorMessage == nil)
    }

    /// A completion the system delivers after the entry was deleted (a background download
    /// that finished while the app was away, even across a relaunch) is discarded, not
    /// republished, until a download of that entry begins again.
    @Test func completionDeliveredAfterADeleteIsDiscarded() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let valid = Data([0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4])
        let option = GGUFDownloadOption(
            id: "fixture", title: "Fixture", character: "",
            fileName: "fixture.gguf", expectedBytes: Int64(valid.count),
            sha256: SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/fixture.gguf")!, isRecommended: false
        )
        let staging = sandbox.root.appendingPathComponent("\(option.fileName).download")
        let installed = sandbox.root.appendingPathComponent(option.fileName)
        let manager = try await sandbox.restoredManager()
        let directory = sandbox.root

        // Nothing deleted: the completion installs.
        try valid.write(to: staging)
        #expect(try await Task.detached { try manager.installCompletedDownload(from: staging, in: directory, option: option) }.value)
        #expect(try Data(contentsOf: installed) == valid)

        await manager.delete(option)
        #expect(!FileManager.default.fileExists(atPath: installed.path))

        try valid.write(to: staging)
        #expect(try await Task.detached { try manager.installCompletedDownload(from: staging, in: directory, option: option) }.value == false)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(GGUFVerifiedArtifactStore.marker(fileName: option.fileName, defaults: sandbox.defaults) == nil)

        // The app was terminated before the callback: a fresh manager still discards it.
        let relaunched = try await sandbox.restoredManager()
        try valid.write(to: staging)
        #expect(try await Task.detached { try relaunched.installCompletedDownload(from: staging, in: directory, option: option) }.value == false)
        #expect(!FileManager.default.fileExists(atPath: installed.path))

        // A download of the entry beginning is a fresh intent; the next completion installs.
        relaunched.beginDownloadForTest(option)
        try valid.write(to: staging)
        #expect(try await Task.detached { try relaunched.installCompletedDownload(from: staging, in: directory, option: option) }.value)
        #expect(try Data(contentsOf: installed) == valid)
    }

    @Test func artifactNamesFollowTheDownloaderGrammar() {
        let e2b = GGUFDownloadCatalog.options[0]
        for name in ["\(e2b.fileName).download", "\(e2b.fileName).resume", "\(e2b.fileName).059e73281d764ba0.resume",
                     "\(e2b.id).segment-0.part", "\(e2b.id).segment-12.resume"] {
            #expect(GGUFModelStorage.isDownloadArtifactName(name, of: e2b), "\(name)")
        }
        for name in [e2b.fileName, "\(e2b.fileName).notes.resume", "\(e2b.fileName).059e73281d764ba.resume",
                     "\(e2b.fileName).backup.gguf", "\(e2b.id).segment-personal.part", "\(e2b.id).segment-.part",
                     "\(e2b.id).segment-1.gguf", GGUFDownloadCatalog.options[1].fileName] {
            #expect(!GGUFModelStorage.isDownloadArtifactName(name, of: e2b), "\(name)")
        }
    }

    @Test func deleteFailureIsReportedAndKeepsTheModel() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let sandbox = try Sandbox()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sandbox.root.path)
            sandbox.tearDown()
        }
        try sandbox.install([e2b])
        let manager = try await sandbox.restoredManager()
        manager.select(e2b)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sandbox.root.path)

        await manager.delete(e2b)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sandbox.root.path)
        #expect(manager.errorMessage?.hasPrefix("Could not delete \(e2b.title):") == true)
        #expect(FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent(e2b.fileName).path))
        // The model is still there, so its selection comes back.
        #expect(manager.selectedModelFileName == e2b.fileName)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == e2b.fileName)
        manager.refreshInstalledModels()
        #expect(manager.installedModelFiles == [e2b.fileName])
    }

    // MARK: Pause, resume and cancel (model rows)

    private static func resumeBlob(received: Int64) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["NSURLSessionResumeBytesReceived": NSNumber(value: received)], format: .binary, options: 0
        )
    }

    private func row(_ option: GGUFDownloadOption, _ manager: GGUFDownloadManager) -> ModelRowContent {
        ModelRowContent.catalog(option, facts: ModelRowContent.Facts(
            bytesOnDisk: manager.bytesOnDisk[option.fileName],
            isInstalled: manager.installedModelFiles.contains(option.fileName),
            isSelected: manager.selectedModelFileName == option.fileName,
            isActive: manager.activeDownloadID == option.id,
            isVerifying: manager.isVerifying,
            receivedBytes: manager.receivedBytes,
            pausedBytes: manager.pausedBytes[option.fileName],
            isDeleting: manager.deletingModelFileName == option.fileName,
            freedBytes: manager.freedSpace[option.fileName]?.bytes
        ))
    }

    /// A saved resume blob is a paused download: its row offers Resume and Cancel with the
    /// bytes it holds; Cancel removes only the downloader's files and the row reads Download.
    @Test func pausedEntryShowsResumeAndCancelDiscardsOnlyDownloadArtifacts() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.install([e4b])
        let resume = GGUFModelStorage.resumeDataURL(for: e2b, in: sandbox.root)
        let staging = sandbox.root.appendingPathComponent("\(e2b.fileName).download")
        let notes = sandbox.root.appendingPathComponent("\(e2b.fileName).notes")
        try Self.resumeBlob(received: 1_474_000_000).write(to: resume)
        for url in [staging, notes] { try Data("x".utf8).write(to: url) }
        let manager = try await sandbox.restoredManager()

        #expect(manager.pausedBytes == [e2b.fileName: 1_474_000_000])
        let paused = row(e2b, manager)
        #expect(paused.chip == .resume)
        #expect(paused.column == .cancel)
        #expect(paused.metadata == "Paused · 1.47 of 3.43 GB")
        #expect(paused.accessibilityLabel == "Resume download of \(e2b.title)")

        manager.cancelDownload(e2b)

        #expect(!FileManager.default.fileExists(atPath: resume.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent(e4b.fileName).path))
        #expect(manager.installedModelFiles == [e4b.fileName])
        #expect(manager.pausedBytes.isEmpty)
        #expect(manager.statusMessage == "Download of \(e2b.title) cancelled.")
        let rest = row(e2b, manager)
        #expect(rest.chip == .download)
        #expect(rest.column == .empty)
        #expect(rest.line == .none)
        #expect(rest.metadata == "Quick drafts · 3.43 GB · Recommended")
    }

    /// Resume continues from the saved bytes (the line does not restart from the ghost),
    /// and Cancel while it runs stops it and returns the row to Download.
    @Test func resumeStartsFromTheSavedBytesAndCancelStopsTheRunningDownload() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let resume = GGUFModelStorage.resumeDataURL(for: e2b, in: sandbox.root)
        try Self.resumeBlob(received: 1_474_000_000).write(to: resume)
        let manager = try await sandbox.restoredManager()

        manager.start(e2b)

        #expect(manager.activeDownloadID == e2b.id)
        #expect(manager.receivedBytes == 1_474_000_000)
        let running = row(e2b, manager)
        #expect(running.chip == .pause)
        #expect(running.column == .cancel)
        #expect(running.metadata == "1.47 of 3.43 GB · 43%")
        #expect(running.line == .written(Double(1_474_000_000) / Double(e2b.expectedBytes)))

        manager.cancelDownload(e2b)

        #expect(manager.activeDownloadID == nil)
        #expect(!FileManager.default.fileExists(atPath: resume.path))
        #expect(manager.pausedBytes.isEmpty)
        #expect(row(e2b, manager).chip == .download)
    }

    /// A completion the session delivers after Cancel is discarded, not published; a new
    /// download of the entry lifts that.
    @Test func completionDeliveredAfterCancelIsDiscarded() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let valid = Data([0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4])
        let option = GGUFDownloadOption(
            id: "fixture", title: "Fixture", character: "",
            fileName: "fixture.gguf", expectedBytes: Int64(valid.count),
            sha256: SHA256.hash(data: valid).map { String(format: "%02x", $0) }.joined(),
            url: URL(string: "https://example.com/fixture.gguf")!, isRecommended: false
        )
        let staging = sandbox.root.appendingPathComponent("\(option.fileName).download")
        let installed = sandbox.root.appendingPathComponent(option.fileName)
        let manager = try await sandbox.restoredManager()
        let directory = sandbox.root
        manager.beginDownloadForTest(option)
        let starting = ModelRowContent.catalog(option, facts: ModelRowContent.Facts(isActive: true))
        #expect(starting.chip == .pause)
        #expect(starting.line == .ghost)
        #expect(starting.metadata == "Starting download…")

        manager.cancelDownload(option)
        #expect(manager.activeDownloadID == nil)

        try valid.write(to: staging)
        #expect(try await Task.detached { try manager.installCompletedDownload(from: staging, in: directory, option: option) }.value == false)
        #expect(!FileManager.default.fileExists(atPath: installed.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))

        manager.beginDownloadForTest(option)
        try valid.write(to: staging)
        #expect(try await Task.detached { try manager.installCompletedDownload(from: staging, in: directory, option: option) }.value)
        #expect(FileManager.default.fileExists(atPath: installed.path))
    }

    /// After Cancel and a new download of the same entry, the cancelled transfer's late
    /// progress, completion and resume data are all discarded and never touch the new one.
    @Test func aCancelledTransfersLateCallbacksNeverTouchTheNextDownload() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let resume = GGUFModelStorage.resumeDataURL(for: e2b, in: sandbox.root)
        try Self.resumeBlob(received: 1_474_000_000).write(to: resume)
        let manager = try await sandbox.restoredManager()
        manager.start(e2b)
        let old = try #require(manager.activeTransferIdentifier)
        manager.cancelDownload(e2b)
        try Self.resumeBlob(received: 1_000_000_000).write(to: resume)
        manager.start(e2b)
        let current = try #require(manager.activeTransferIdentifier)
        #expect(current != old)

        manager.receiveProgressForTest(e2b, taskIdentifier: old, bytes: 3_000_000_000)
        #expect(manager.receivedBytes == 1_000_000_000)
        #expect(!manager.finishForTest(e2b, taskIdentifier: old))
        #expect(manager.activeDownloadID == e2b.id)
        #expect(!manager.saveResumeData(Data("late".utf8), for: e2b, taskIdentifier: old))
        #expect(try Data(contentsOf: resume) == Self.resumeBlob(received: 1_000_000_000))

        let staging = sandbox.root.appendingPathComponent("\(e2b.fileName).download")
        try Data("not the model".utf8).write(to: staging)
        let directory = sandbox.root
        #expect(try await Task.detached {
            try manager.installCompletedDownload(from: staging, in: directory, option: e2b, taskIdentifier: old)
        }.value == false)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        manager.cancelDownload(e2b)
    }

    /// Resume shows the saved count, then the offset URLSession actually resumed at; a
    /// lower count arriving late is ignored, so the line never runs backwards on its own.
    @Test func resumeOffsetReplacesTheSavedCountAndProgressNeverGoesBack() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try Self.resumeBlob(received: 1_474_000_000).write(to: GGUFModelStorage.resumeDataURL(for: e2b, in: sandbox.root))
        let manager = try await sandbox.restoredManager()
        manager.start(e2b)
        let transfer = try #require(manager.activeTransferIdentifier)

        manager.receiveProgressForTest(e2b, taskIdentifier: transfer, bytes: 1_000_000_000)
        #expect(manager.receivedBytes == 1_474_000_000)
        manager.resumedForTest(taskIdentifier: transfer, offset: 0)  // the server restarted the file
        #expect(manager.receivedBytes == 0)
        manager.receiveProgressForTest(e2b, taskIdentifier: transfer, bytes: 2 << 20)
        #expect(manager.receivedBytes == 2 << 20)
        manager.cancelDownload(e2b)
    }

    /// Each delete's "back for your songs" line keeps its own 4 s: a second delete does not
    /// cut the first one short.
    @Test func freedSpaceIsHeldPerModel() async throws {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        try sandbox.install([e2b, e4b])
        let manager = try await sandbox.restoredManager()

        await manager.delete(e2b)
        await manager.delete(e4b)

        #expect(manager.freedSpace[e2b.fileName]?.bytes == e2b.expectedBytes)
        #expect(manager.freedSpace[e4b.fileName]?.bytes == e4b.expectedBytes)
        try await Task.sleep(for: .seconds(GGUFDownloadManager.freedSpaceHold + 0.5))
        #expect(manager.freedSpace.isEmpty)
    }

    // MARK: Custom model delete

    /// Delete on an imported model removes the app's copy and its registration and clears
    /// the selection; the file the writer picked is never touched.
    @Test func customDeleteRemovesOnlyTheAppsCopyNeverTheOriginal() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let picked = sandbox.root.deletingLastPathComponent()
            .appendingPathComponent("picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: picked) }
        let original = picked.appendingPathComponent("Night Drive.gguf")
        let bytes = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0, 0, 0] + [UInt8](repeating: 7, count: 4_088))
        try bytes.write(to: original)
        let manager = try await sandbox.restoredManager()

        #expect(await manager.importCustomModel(from: original))
        let model = try #require(GGUFCustomModelRegistry.models(defaults: sandbox.defaults).first)
        let copy = sandbox.root.appendingPathComponent(model.fileName)
        #expect(model.displayName == "Night Drive")
        #expect(manager.selectedModelFileName == model.fileName)
        #expect(manager.bytesOnDisk[model.fileName] == Int64(bytes.count))
        let selected = ModelRowContent.custom(model, facts: ModelRowContent.Facts(bytesOnDisk: Int64(bytes.count), isSelected: true))
        #expect(selected.metadata == "In use · 4 KB on this device")
        #expect(selected.chip == .selected)
        #expect(selected.column == .trash)

        await manager.deleteCustom(model)

        #expect(manager.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(try Data(contentsOf: original) == bytes)
        #expect(GGUFCustomModelRegistry.models(defaults: sandbox.defaults).isEmpty)
        #expect(manager.selectedModelFileName == nil)
        #expect(GGUFModelSelection.currentFileName(defaults: sandbox.defaults) == nil)
        #expect(GGUFModelSelection.isCleared(defaults: sandbox.defaults))
        #expect(manager.bytesOnDisk[model.fileName] == nil)
        #expect(manager.freedSpace[model.fileName]?.bytes == Int64(bytes.count))
        #expect(manager.statusMessage == "Night Drive deleted.")
    }

    /// A custom entry whose file name is not a plain name in the models folder is refused.
    @Test func customDeleteRefusesANameOutsideTheModelsFolder() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.tearDown() }
        let outside = sandbox.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).gguf")
        try Data("GGUF".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let model = GGUFCustomModel(id: "escape", displayName: "Escape", fileName: "../\(outside.lastPathComponent)")
        GGUFCustomModelRegistry.register(model, defaults: sandbox.defaults)
        let manager = try await sandbox.restoredManager()

        await manager.deleteCustom(model)

        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(GGUFCustomModelRegistry.contains(fileName: model.fileName, defaults: sandbox.defaults))
    }
}

// MARK: - Hash loop memory bound

/// XCTest on purpose: the bundle runs its XCTest cases serially and finishes them before the
/// Swift Testing run starts, so no other test's allocations land in this measurement.
final class GGUFHashMemoryTests: XCTestCase {
    /// Each hashed chunk must leave memory before the next is read. Holding them all kept a
    /// whole multi-GB model resident during verification and the app was jetsammed.
    func testHashingALargeFileKeepsOnlyOneChunkResident() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-memory-\(UUID().uuidString).gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("GGUF".utf8)))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 1 << 30) // 1 GiB, sparse: reads return zero pages without touching disk.
        try handle.close()

        // Sampled once per chunk from inside the hash loop, so a pool around the whole loop
        // (drained only on return) still shows the growth.
        let baseline = try physicalFootprint()
        var peak = baseline
        _ = try GGUFModelCatalog.fileSHA256(at: url, cancellationCheck: { peak = max(peak, try physicalFootprint()) })
        let grownBy = peak - baseline
        // Measured: about 3 MiB with the per-chunk pool, 1103 MiB without it.
        XCTAssertLessThan(grownBy, 256 * 1_048_576, "hashing grew the footprint by \(grownBy / 1_048_576) MiB")
    }

    private func physicalFootprint() throws -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        XCTAssertEqual(result, KERN_SUCCESS)
        return Int64(info.phys_footprint)
    }
}
