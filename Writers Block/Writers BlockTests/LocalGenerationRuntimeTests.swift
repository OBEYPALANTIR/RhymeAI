import CryptoKit
import Foundation
import SwiftData
import UIKit
import XCTest
@testable import Writers_Block

final class LocalGenerationRuntimeTests: XCTestCase {
    @MainActor
    func testInstalledE2BStreamAndStop() async throws {
        let defaults = UserDefaults.standard
        guard let sourcePath = defaults.string(forKey: "RhymeAITestNativeRuntimeModelPath") else {
            throw XCTSkip("Set RhymeAITestNativeRuntimeModelPath to the accepted E2B GGUF for this simulator.")
        }
        let sourceSHA = try XCTUnwrap(defaults.string(forKey: "RhymeAITestNativeRuntimeSourceSHA"))
        let descriptor = try XCTUnwrap(GGUFModelCatalog.models.first)
        let modelURL = try GGUFModelCatalog.modelsDirectory(create: true).appendingPathComponent(descriptor.fileName)
        let ownsModel = !FileManager.default.fileExists(atPath: modelURL.path)
        if ownsModel {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: sourcePath), to: modelURL)
        }
        defer { if ownsModel { try? FileManager.default.removeItem(at: modelURL) } }
        try GGUFModelCatalog.validateFile(at: modelURL, against: descriptor)

        let keys = ["ggufEngineChoice", "selectedGGUFModelFileName", "synonymLocalRevision"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        GGUFEngineChoice.gemma.save()
        GGUFModelSelection.save(fileName: descriptor.fileName)
        await AIService.unloadGGUFRunner()

        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self, SyncRecordingDeletion.self, Recording.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let viewModel = EditorViewModel()
        viewModel.modelContext = container.mainContext
        viewModel.selectedProvider = .local
        viewModel.selectedModel = .localModel
        viewModel.theme = "dawn over a quiet harbor"
        viewModel.rhymeScheme = .abab
        viewModel.rhymeComplexity = .complex
        viewModel.useWholeSongContext = false
        viewModel.lyrics = "[Verse]\nRopes tap time against the mast\nBlue light gathers on the water"
        viewModel.cursorPosition = (viewModel.lyrics as NSString).length
        let input = viewModel.suggestionInputForTest()
        XCTAssertNil(input.targetRhymeLine)

        var records: [[String: Any]] = []
        for phase in ["cold", "warm"] {
            let start = Date()
            viewModel.getSuggestions()
            var firstVisible: Double?
            while viewModel.isLoading && Date().timeIntervalSince(start) < 150 {
                if firstVisible == nil, !viewModel.suggestions.isEmpty {
                    firstVisible = Date().timeIntervalSince(start)
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if viewModel.isLoading { viewModel.cancelSuggestions() }
            let trace = try XCTUnwrap(GGUFModelService.lastGenerationTrace)
            let prompt = AIService().buildLocalSuggestionPromptForTest(input: input)
            XCTAssertEqual(trace.userPromptSHA256, Self.sha256(prompt))
            XCTAssertEqual(trace.renderedPromptSHA256, Self.sha256(GGUFModelService.gemmaPrompt(prompt, format: .gemma4)))
            XCTAssertEqual(trace.tokenizerArchitecture, "gemma4")
            XCTAssertEqual(trace.terminationReason, "eog")
            XCTAssertNil(viewModel.errorMessage)
            XCTAssertEqual(viewModel.suggestions.count, 6)
            XCTAssertEqual(Set(viewModel.suggestions.map(\.text)).count, 6)
            records.append([
                "phase": phase,
                "firstValidatedSuggestionSeconds": firstVisible ?? -1,
                "terminalSeconds": Date().timeIntervalSince(start),
                "modelLoadSeconds": trace.modelLoadSeconds,
                "seed": trace.seed,
                "promptTokenCount": trace.promptTokenCount,
                "tokenizerArchitecture": trace.tokenizerArchitecture,
                "tokenizerEnvelope": trace.tokenizerEnvelope,
                "tokenizerChatTemplateSha256": trace.tokenizerChatTemplateSHA256,
                "addSpecialTokens": GGUFModelService.addSpecialTokens,
                "parseSpecialTokens": GGUFModelService.parseSpecialTokens,
                "contextLength": GGUFModelService.contextLength,
                "responseByteLimit": GGUFModelService.maxResponseBytes,
                "cachePolicy": GGUFModelService.cachePolicy,
                "userPromptSha256": trace.userPromptSHA256,
                "renderedPromptSha256": trace.renderedPromptSHA256,
                "terminationReason": trace.terminationReason,
                "validatedLines": viewModel.suggestions.map(\.text),
                "error": viewModel.errorMessage ?? ""
            ])
        }

        viewModel.getSuggestions()
        let start = Date()
        while viewModel.suggestions.isEmpty && viewModel.isLoading && Date().timeIntervalSince(start) < 90 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(viewModel.suggestions.isEmpty)
        XCTAssertTrue(viewModel.isLoading)
        let stop = Date()
        viewModel.cancelSuggestions()
        let idleSeconds = Date().timeIntervalSince(stop)
        XCTAssertFalse(viewModel.isLoading)
        let countAtStop = viewModel.suggestions.count
        while GGUFModelService.lastGenerationTrace?.terminationReason == "running",
              Date().timeIntervalSince(stop) < 5 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let quiescentSeconds = Date().timeIntervalSince(stop)
        XCTAssertEqual(GGUFModelService.lastGenerationTrace?.terminationReason, "cancelled")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.suggestions.count, countAtStop)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertLessThan(idleSeconds, 1)
        XCTAssertLessThan(quiescentSeconds, 5)
        records.append(["phase": "stop", "uiIdleSeconds": idleSeconds, "nativeQuiescentSeconds": quiescentSeconds])

        await AIService.unloadGGUFRunner()
        XCTAssertFalse(AIService.ggufRunner.isLoaded)
        let report: [String: Any] = [
            "sourceSha": sourceSHA,
            "modelSha256": descriptor.sha256,
            "osVersion": UIDevice.current.systemVersion,
            "device": UIDevice.current.model,
            "engine": GGUFModelService.engineVersion,
            "runs": records
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "local-generation-runtime.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try data.write(to: documents.appendingPathComponent("local-generation-runtime.json"), options: .atomic)
    }

    @MainActor
    func testResidentModelIdentityChanges() async throws {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "RhymeAITestNativeRuntimeModelPath") != nil else {
            throw XCTSkip("Opt in only in the owned test container with the accepted E2B staged.")
        }
        let descriptor = try XCTUnwrap(GGUFModelCatalog.models.first)
        let directory = try GGUFModelCatalog.modelsDirectory(create: true)
        let modelURL = directory.appendingPathComponent(descriptor.fileName)
        let backup = directory.appendingPathComponent("identity-owned-backup.gguf")
        let customURL = directory.appendingPathComponent("identity-owned-custom.gguf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: customURL.path))
        let keys = ["selectedGGUFModelFileName", "customGGUFModels", "synonymLocalRevision"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let runner = AIService.ggufRunner
        addTeardownBlock {
            await runner.unload()
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.removeItem(at: modelURL)
                try FileManager.default.moveItem(at: backup, to: modelURL)
            }
            try? FileManager.default.removeItem(at: customURL)
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        await runner.unload()
        GGUFModelSelection.save(fileName: descriptor.fileName)
        let firstLoad = Date()
        try await runner.loadModel(filePath: modelURL.path)
        let firstLoadSeconds = Date().timeIntervalSince(firstLoad)
        XCTAssertTrue(runner.isLoaded)
        let reuse = Date()
        try await runner.loadModel(filePath: modelURL.path)
        let reuseSeconds = Date().timeIntervalSince(reuse)

        // The old mapping can remain resident after atomic replacement of this pathname.
        try FileManager.default.moveItem(at: modelURL, to: backup)
        try Data("GGUFcorrupt".utf8).write(to: modelURL, options: .atomic)
        let readyAfterReplacement = runner.isLoaded
        XCTAssertFalse(readyAfterReplacement)
        var corruptionRejected = false
        do { try await runner.loadModel(filePath: modelURL.path) }
        catch { corruptionRejected = true }
        XCTAssertTrue(corruptionRejected)
        XCTAssertFalse(runner.isLoaded)
        try FileManager.default.removeItem(at: modelURL)
        try FileManager.default.moveItem(at: backup, to: modelURL)
        try await runner.loadModel(filePath: modelURL.path)
        XCTAssertTrue(runner.isLoaded)

        try FileManager.default.copyItem(at: modelURL, to: customURL)
        let custom = GGUFCustomModel(id: "identity-owned-custom", displayName: "Identity fixture", fileName: customURL.lastPathComponent)
        GGUFCustomModelRegistry.register(custom)
        GGUFModelSelection.save(fileName: custom.fileName)
        let readyAfterSelectingB = runner.isLoaded
        XCTAssertFalse(readyAfterSelectingB)
        var stalePathRejected = false
        do { try await runner.loadModel(filePath: modelURL.path) }
        catch { stalePathRejected = true }
        XCTAssertTrue(stalePathRejected)
        XCTAssertFalse(runner.isLoaded)
        try await runner.loadModel(filePath: customURL.path)
        XCTAssertTrue(runner.isLoaded)
        GGUFModelSelection.save(fileName: descriptor.fileName)
        let readyAfterSelectingA = runner.isLoaded
        XCTAssertFalse(readyAfterSelectingA)
        try await runner.loadModel(filePath: modelURL.path)
        XCTAssertTrue(runner.isLoaded)
        let response = try await runner.generate(prompt: "Write one brief line about dawn. Return only the line.", loading: modelURL.path)
        XCTAssertFalse(response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(GGUFModelService.lastGenerationTrace?.tokenizerArchitecture, "gemma4")
        let report: [String: Any] = [
            "firstLoadSeconds": firstLoadSeconds, "unchangedReuseSeconds": reuseSeconds,
            "readyAfterReplacement": readyAfterReplacement, "corruptionRejected": corruptionRejected,
            "readyAfterSelectingB": readyAfterSelectingB, "readyAfterSelectingA": readyAfterSelectingA,
            "stalePathRejected": stalePathRejected,
            "response": response, "modelSha256": descriptor.sha256,
            "source": defaults.string(forKey: "RhymeAITestNativeRuntimeSourceSHA") ?? "unknown"
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "resident-identity-runtime.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try data.write(to: documents.appendingPathComponent("resident-identity-runtime.json"), options: .atomic)
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
