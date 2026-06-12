import XCTest
@testable import Writers_Block

final class LocalProviderSmokeTests: XCTestCase {
    @MainActor
    func testLocalProviderReturnsTextOrAvailabilityMessage() async throws {
        let service = AIService()
        let lyrics = "[Verse]\nI keep a notebook under neon rain\nEvery margin learns my name"
        let maxAttempts = 2

        for attempt in 1...maxAttempts {
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
                return
            } catch AIServiceError.localModelUnavailable(let reason) {
                XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertTrue(
                    AIServiceError.localModelUnavailable(reason: reason)
                        .localizedDescription
                        .hasPrefix("On-device model unavailable: ")
                )
                return
            } catch {
                // Apple's on-device guardrails can refuse a prompt
                // nondeterministically; retry once before calling it real.
                print("LOCAL_SUGGESTION_RETRY attempt=\(attempt) error=\(error)")
                if attempt == maxAttempts {
                    throw error
                }
            }
        }
    }

    // MARK: - Local rewrite smoke (Apple Intelligence path)

    private static let rewriteLyrics = "[Verse]\nI keep a notebook under neon rain\nEvery margin learns my name"
    private static let rewritePassage = "I keep a notebook under neon rain\nEvery margin learns my name"

    @MainActor
    func testLocalRewriteRephrasePassageReturnsTextOrAvailabilityMessage() async throws {
        try await verifyLocalRewrite(
            action: .rephrase,
            fullLyrics: Self.rewriteLyrics,
            selection: Self.rewritePassage
        )
    }

    @MainActor
    func testLocalRewritePunchUpPassageReturnsTextOrAvailabilityMessage() async throws {
        try await verifyLocalRewrite(
            action: .punchUp,
            fullLyrics: Self.rewriteLyrics,
            selection: Self.rewritePassage
        )
    }

    @MainActor
    func testLocalRewriteHarderRhymePassageReturnsTextOrAvailabilityMessage() async throws {
        try await verifyLocalRewrite(
            action: .harderRhyme,
            fullLyrics: Self.rewriteLyrics,
            selection: Self.rewritePassage
        )
    }

    @MainActor
    func testLocalRewritePunchUpSingleWordReturnsTextOrAvailabilityMessage() async throws {
        // "glow" is in AIService.fallbackPunchUpWords, so the deterministic
        // fallback table can serve this selection if the live model declines.
        let lyrics = "[Verse]\nCity lights glow on the boulevard\nEvery window hums a different song"
        let selection = "glow"
        let selectionRange = try XCTUnwrap(lyrics.range(of: selection))
        let selectionStart = lyrics.distance(from: lyrics.startIndex, to: selectionRange.lowerBound)

        try await verifyLocalRewrite(
            action: .punchUp,
            fullLyrics: lyrics,
            selection: selection,
            selectionStart: selectionStart,
            caseLabel: "punchUpSingleWord",
            acceptsGuardrailBlock: false
        )
    }

    /// Mirrors the suggestion smoke's tolerance: a non-empty rewrite and an
    /// on-device availability message are both acceptable outcomes. For
    /// passage selections a recognized guardrail block (blockedResponse) is
    /// also acceptable after one retry, because Apple's on-device safety layer
    /// can refuse a prompt nondeterministically. Single-word selections must
    /// never end blocked — the deterministic fallback table has to serve them.
    /// Any other error gets one retry before it is treated as a real failure.
    @MainActor
    private func verifyLocalRewrite(
        action: RewriteAction,
        fullLyrics: String,
        selection: String,
        selectionStart: Int? = nil,
        caseLabel: String? = nil,
        acceptsGuardrailBlock: Bool = true
    ) async throws {
        let service = AIService()
        let label = caseLabel ?? action.rawValue
        let maxAttempts = 2

        for attempt in 1...maxAttempts {
            let start = Date()
            do {
                let rewrite = try await service.getRewrite(
                    provider: .local,
                    apiKey: "",
                    modelId: AIModel.localModel.id,
                    action: action,
                    fullLyrics: fullLyrics,
                    selection: selection,
                    currentSection: .verse,
                    selectionStart: selectionStart
                )
                let trimmed = rewrite.trimmingCharacters(in: .whitespacesAndNewlines)
                print("LOCAL_REWRITE_RESULT action=\(label) attempt=\(attempt) elapsed=\(Self.elapsedString(since: start)) output=\(Self.logSample(trimmed))")
                XCTAssertFalse(trimmed.isEmpty, "Local rewrite (\(label)) returned empty text")
                // cleanLocalRewrite already rejects echoes of the selection, so a
                // returned rewrite must differ from the input.
                XCTAssertNotEqual(
                    trimmed.lowercased(),
                    selection.lowercased(),
                    "Local rewrite (\(label)) returned the selection unchanged"
                )
                return
            } catch AIServiceError.localModelUnavailable(let reason) {
                print("LOCAL_REWRITE_RESULT action=\(label) attempt=\(attempt) elapsed=\(Self.elapsedString(since: start)) unavailable=\(Self.logSample(reason))")
                XCTAssertFalse(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertTrue(
                    AIServiceError.localModelUnavailable(reason: reason)
                        .localizedDescription
                        .hasPrefix("On-device model unavailable: ")
                )
                return
            } catch AIServiceError.blockedResponse where acceptsGuardrailBlock {
                print("LOCAL_REWRITE_RESULT action=\(label) attempt=\(attempt) elapsed=\(Self.elapsedString(since: start)) blocked=on-device guardrail refused the prompt")
                if attempt == maxAttempts {
                    // Recognized, user-facing safety refusal — acceptable
                    // terminal outcome for a passage rewrite.
                    return
                }
            } catch {
                print("LOCAL_REWRITE_RESULT action=\(label) attempt=\(attempt) elapsed=\(Self.elapsedString(since: start)) error=\(error)")
                if attempt == maxAttempts {
                    throw error
                }
            }
        }
    }

    private static func elapsedString(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    private static func logSample(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " / ")
        return flattened.count > 160 ? String(flattened.prefix(160)) + "…" : flattened
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
