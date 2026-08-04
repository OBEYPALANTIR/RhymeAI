import Foundation
import Testing
@testable import Writers_Block

// MARK: - Gemma prompt template

/// Verify that GGUFModelService.gemmaPrompt produces the same shape as
/// Android's gemmaInstructionPrompt() — chat template must be stable across
/// platforms so the model behaves identically.
struct GemmaPromptTemplateTests {
    @Test func gemmaPromptWrapsUserTurn() {
        let input = "Write a verse about midnight roads."
        let wrapped = GGUFModelService.gemmaPrompt(input)

        #expect(wrapped.hasPrefix("<start_of_turn>user\n"))
        #expect(wrapped.contains(input))
        #expect(wrapped.contains("<end_of_turn>"))
        #expect(wrapped.hasSuffix("<start_of_turn>model\n"))
    }

    @Test func gemmaPromptPreservesNewlinesInPrompt() {
        let input = "line one\nline two"
        let wrapped = GGUFModelService.gemmaPrompt(input)
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
        let raw = "model\nActual output here"
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
        #expect(options.allSatisfy { $0.sha256.count == 64 })
        #expect(options.map(\.expectedBytes) == [3_427_878_784, 5_335_290_784])
    }

    @Test func preferredModelUsesCatalogOrder() {
        let options = GGUFDownloadCatalog.options
        let preferred = GGUFModelSelection.preferredFileName(
            in: [options[1].fileName, options[0].fileName]
        )

        #expect(preferred == options[0].fileName)
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

struct GGUFRoutingDecisionTests {
    // shouldUseGemma returns false when engine is Apple Intelligence regardless
    // of whether GGUF files are present.
    @Test func appleEngineNeverRoutesToGemma() {
        let result = AIService.shouldUseGemma(
            engineChoice: .appleIntelligence,
            ggufPath: "/tmp/model.gguf"
        )
        #expect(result == false)
    }

    // shouldUseGemma returns false when engine is Gemma but no GGUF exists
    // (the models directory is either absent or empty).
    @Test func gemmaEngineWithNoFileReturnsFalse() {
        let result = AIService.shouldUseGemma(engineChoice: .gemma, ggufPath: nil)
        #expect(result == false)
    }
}

@Suite(.serialized)
struct GGUFCustomModelRegistryTests {
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

struct GGUFLlamaFrameworkEmbeddingTests {
    @Test func appBundleContainsLinkedLlamaFramework() {
        let frameworkURL = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("llama.framework/llama")

        #expect(frameworkURL != nil)
        #expect(FileManager.default.fileExists(atPath: frameworkURL?.path ?? ""))
        #expect(GGUFModelService.isEngineAvailable)
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
