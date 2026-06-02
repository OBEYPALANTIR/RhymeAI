import XCTest
@testable import Writers_Block

final class LocalProviderSmokeTests: XCTestCase {
    @MainActor
    func testLocalProviderReturnsTextOrAvailabilityMessage() async throws {
        let service = AIService()
        let lyrics = "[Verse]\nI keep a notebook under neon rain\nEvery margin learns my name"

        do {
            let suggestions = try await service.getSuggestions(
                provider: .local,
                apiKey: "",
                modelId: AIModel.localModel.id,
                theme: "late-night writing",
                lyrics: lyrics,
                targetRhymeLine: "I keep a notebook under neon rain",
                rhymeType: .perfect,
                rhymeScheme: "AABB",
                currentLetter: "A",
                currentSection: .verse,
                complexity: .moderate,
                useWholeSongContext: false
            )
            XCTAssertFalse(suggestions.isEmpty, "Local provider returned no suggestions")
            XCTAssertTrue(suggestions.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        } catch AIServiceError.localModelUnavailable(let reason) {
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(
                AIServiceError.localModelUnavailable(reason: reason)
                    .localizedDescription
                    .hasPrefix("On-device model unavailable: ")
            )
        }
    }
}

final class ProviderLiveSmokeTests: XCTestCase {
    @MainActor
    func testOpenAIConfiguredModelServesSuggestionRewriteAndStreamWhenKeyIsPresent() async throws {
        try await verifyProviderWhenKeyIsPresent(
            provider: .openai,
            apiKey: Self.openAITestKey
        )
    }

    @MainActor
    func testClaudeConfiguredModelServesSuggestionRewriteAndStreamWhenKeyIsPresent() async throws {
        try await verifyProviderWhenKeyIsPresent(
            provider: .claude,
            apiKey: Self.claudeTestKey
        )
    }

    @MainActor
    private func verifyProviderWhenKeyIsPresent(
        provider: AIProvider,
        apiKey: String
    ) async throws {
        if apiKey.isEmpty {
            throw XCTSkip("Set \(Self.testKeyDescription(for: provider)) to run the live \(provider.displayName) gate.")
        }

        let service = AIService()
        let model = try Self.model(for: provider)
        let lyrics = "[Verse]\nYellow lights on a midnight road\nI keep the melody close"

        let suggestions = try await service.getSuggestions(
            provider: provider,
            apiKey: apiKey,
            modelId: model.id,
            theme: "late-night resolve",
            lyrics: lyrics,
            targetRhymeLine: "Yellow lights on a midnight road",
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "A",
            currentSection: .verse,
            complexity: .moderate,
            useWholeSongContext: false
        )
        XCTAssertFalse(suggestions.isEmpty, "\(provider.displayName) returned no suggestions for \(model.id)")
        XCTAssertTrue(suggestions.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        let rewrite = try await service.getRewrite(
            provider: provider,
            apiKey: apiKey,
            modelId: model.id,
            action: .rephrase,
            fullLyrics: lyrics,
            selection: "I keep the melody close",
            currentSection: .verse
        )
        XCTAssertFalse(
            rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(provider.displayName) returned no rewrite for \(model.id)"
        )

        var streamed: [String] = []
        for try await line in service.streamSuggestions(
            provider: provider,
            apiKey: apiKey,
            modelId: model.id,
            theme: "late-night resolve",
            lyrics: lyrics,
            targetRhymeLine: nil,
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "B",
            currentSection: .verse,
            complexity: .moderate,
            useWholeSongContext: true
        ) {
            streamed.append(line)
            break
        }
        XCTAssertFalse(streamed.isEmpty, "\(provider.displayName) stream emitted no suggestions for \(model.id)")
        XCTAssertTrue(streamed.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private static var openAITestKey: String {
        ProcessInfo.processInfo.environment["OPENAI_TEST_KEY"]
            ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_OPENAI_TEST_KEY"]
            ?? ""
    }

    private static var claudeTestKey: String {
        ProcessInfo.processInfo.environment["CLAUDE_TEST_KEY"]
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_TEST_KEY"]
            ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_CLAUDE_TEST_KEY"]
            ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_ANTHROPIC_TEST_KEY"]
            ?? ""
    }

    private static func testKeyDescription(for provider: AIProvider) -> String {
        switch provider {
        case .openai:
            return "OPENAI_TEST_KEY"
        case .claude:
            return "CLAUDE_TEST_KEY or ANTHROPIC_TEST_KEY"
        case .gemini:
            return "GEMINI_TEST_KEY"
        case .local:
            return "a local provider availability fixture"
        }
    }

    private static func model(for provider: AIProvider) throws -> AIModel {
        let override: String?
        switch provider {
        case .openai:
            override = ProcessInfo.processInfo.environment["OPENAI_TEST_MODEL"]
                ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_OPENAI_TEST_MODEL"]
        case .claude:
            override = ProcessInfo.processInfo.environment["CLAUDE_TEST_MODEL"]
                ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_CLAUDE_TEST_MODEL"]
        case .gemini, .local:
            override = nil
        }

        let models = AIModel.models(for: provider)
        guard let override, !override.isEmpty else {
            return try XCTUnwrap(models.first)
        }
        return try XCTUnwrap(
            models.first { $0.id == override },
            "Unknown \(provider.displayName) test model: \(override)"
        )
    }
}
