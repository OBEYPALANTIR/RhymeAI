import CryptoKit
import Foundation
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
        let ownsLink = !FileManager.default.fileExists(atPath: modelURL.path)
        if ownsLink {
            try FileManager.default.createSymbolicLink(atPath: modelURL.path, withDestinationPath: sourcePath)
        }
        defer { if ownsLink { try? FileManager.default.removeItem(at: modelURL) } }
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

        let viewModel = EditorViewModel()
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
                "firstValidatedVisibleSeconds": firstVisible ?? -1,
                "terminalSeconds": Date().timeIntervalSince(start),
                "modelLoadSeconds": trace.modelLoadSeconds,
                "seed": trace.seed,
                "promptTokenCount": trace.promptTokenCount,
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

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

