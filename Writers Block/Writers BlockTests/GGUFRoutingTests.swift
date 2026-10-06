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
        #expect(options.map(\.expectedBytes) == [3_427_880_800, 5_335_290_784])
        #expect(options.map(\.sha256) == [
            "b250c2f6a91d9f7659f7ac2c90ccc563ca96a84aea4c1e8a3463fafc77d004af",
            "e39b2475a5c8d86d1b376babe16ffce32993c96ab650b6fed7c4e14f5d0d11a3",
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
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]

        // The shipped v1 E2B file: same name, 2,016 bytes smaller than the v2 entry.
        try sparseFile(e2b.fileName, bytes: 3_427_878_784)
        try sparseFile(e4b.fileName, bytes: e4b.expectedBytes)
        try sparseFile("my-custom-model.gguf", bytes: 1_024)
        #expect(GGUFModelStorage.installedModelFileNames(in: directory) == [
            e4b.fileName,
            "my-custom-model.gguf",
        ].sorted())

        try sparseFile(e2b.fileName, bytes: e2b.expectedBytes)
        #expect(GGUFModelStorage.installedModelFileNames(in: directory).contains(e2b.fileName))
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

struct GGUFSuggestionParsingTests {
    @Test func parsesLiteralEscapedLineBreaksFromTunedModel() {
        let raw = #"A hazy amber glow begins to gleam\nA whispered, fragile, waking dream\nAcross the slick and darkened stream\nA silent, solitary, waking theme\nBeneath the shadows of a waking gleam\nA fading, ephemeral, silver gleam<end_of_turn>"#
        let parsed = AIService().parseSuggestionList(raw)

        #expect(parsed.count == 6)
        #expect(parsed.first == "A hazy amber glow begins to gleam")
        #expect(parsed.last == "A fading, ephemeral, silver gleam")
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
        let resume = directory.appendingPathComponent("fixture.gguf.resume")
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
        let resume = directory.appendingPathComponent("fixture.gguf.resume")
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
