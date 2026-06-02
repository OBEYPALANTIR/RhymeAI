//
//  Writers_BlockTests.swift
//  Writers BlockTests
//
//  Created by Tyler Manring on 4/6/26.
//

import Foundation
import Testing
@testable import Writers_Block

struct Writers_BlockTests {

    @Test func rhymeContextIgnoresSectionHeadersForSchemePosition() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .aabb
        viewModel.lyrics = "[Verse 1]\nfirst light\nsecond night"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()

        #expect(context.currentLetter == "A")
        #expect(context.targetLine == "first light")
        #expect(context.currentLineIndex == 2)
        #expect(context.currentSection == .verse)
    }

    @Test func rhymeContextUsesLatestPreviousLyricWithSameLetter() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .abab
        viewModel.lyrics = "[Chorus]\nfirst glow\nsecond rain\nthird road\nfourth rain"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()

        #expect(context.currentLetter == "B")
        #expect(context.targetLine == "second rain")
        #expect(context.currentSection == .chorus)
    }

    @Test func rhymeContextDetectsBridgeSectionForPromptShaping() {
        let viewModel = EditorViewModel()
        viewModel.lyrics = "[Verse 1]\nfirst line\n\n[Bridge]\nnew angle"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()

        #expect(context.currentSection == .bridge)
    }

    @Test func openAIModelPickerStartsWithCurrentGPT5Models() {
        let modelIDs = AIModel.models(for: .openai).map(\.id)

        #expect(modelIDs == [
            "gpt-5.5",
            "gpt-5.5-pro",
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.4-nano",
            "gpt-4.1",
            "gpt-4.1-mini",
            "gpt-4.1-nano",
            "gpt-4o",
            "gpt-4o-mini"
        ])
    }

    @Test func claudeModelPickerUsesCurrentClaudeModels() {
        let modelIDs = AIModel.models(for: .claude).map(\.id)

        #expect(modelIDs == [
            "claude-opus-4-7",
            "claude-sonnet-4-6",
            "claude-opus-4-20250514",
            "claude-sonnet-4-20250514",
            "claude-haiku-4-5-20251001"
        ])
    }

    @Test func prosodyAnalyzerCountsDictionaryStress() {
        let dictionary = Self.fixtureDictionary
        let prosody = ProsodyAnalyzer.analyzeLine("yellow music", dictionary: dictionary)

        #expect(prosody.syllableCount == 4)
        #expect(prosody.stressPattern == [1, 0, 1, 0])
        #expect(prosody.feet == "ˈDA da | ˈDA da")
    }

    @Test func prosodyAnalyzerRendersIpaPreview() {
        let prosody = ProsodyAnalyzer.analyzeWord("music", dictionary: Self.fixtureDictionary)

        #expect(prosody.ipa == "ˈmjuzɪk")
        #expect(prosody.isFallback == false)
    }

    @Test func prosodyAnalyzerUsesFallbackForUnknownWords() {
        let prosody = ProsodyAnalyzer.analyzeWord("Scottys", dictionary: Self.fixtureDictionary)

        #expect(prosody.syllableCount == 2)
        #expect(prosody.stressPattern == [1, 0])
        #expect(prosody.isFallback)
    }

    @Test func prosodyAnalyzerUsesCmuPhonesForRhymeKeys() {
        let roadKeys = ProsodyAnalyzer.rhymeKeys(for: "road", dictionary: Self.fixtureDictionary)
        let glowedKeys = ProsodyAnalyzer.rhymeKeys(for: "glowed", dictionary: Self.fixtureDictionary)

        #expect(!Set(roadKeys).intersection(glowedKeys).isEmpty)
    }

    @Test func inMemoryKeychainRoundTripsKey() {
        let store: KeychainStore = InMemoryKeychainStore()

        store.setKey(provider: "GEMINI", key: "abc")
        store.setKey(provider: "OPENAI", key: "xyz")

        #expect(store.getKey(provider: "GEMINI") == "abc")
        #expect(store.getKey(provider: "OPENAI") == "xyz")
        #expect(store.getKey(provider: "CLAUDE") == "")

        store.deleteKey(provider: "GEMINI")
        #expect(store.getKey(provider: "GEMINI") == "")
    }

    @Test func migrationMovesPopulatedLegacyKeysFromUserDefaults() {
        let suiteName = "rhymeai.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("gem-1", forKey: "apiKey_GEMINI")
        defaults.set("cla-1", forKey: "apiKey_CLAUDE")

        let store: KeychainStore = InMemoryKeychainStore()
        let migrated = ApiKeyMigration.apply(legacyDefaults: defaults, secure: store)

        #expect(migrated)
        #expect(store.getKey(provider: "GEMINI") == "gem-1")
        #expect(store.getKey(provider: "OPENAI") == "")
        #expect(store.getKey(provider: "CLAUDE") == "cla-1")
        #expect(defaults.string(forKey: "apiKey_GEMINI") == nil)
        #expect(defaults.string(forKey: "apiKey_CLAUDE") == nil)
    }

    @Test func migrationIsIdempotentAndDoesNotOverwriteSecureKey() {
        let suiteName = "rhymeai.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("stale-plaintext", forKey: "apiKey_GEMINI")

        let store: KeychainStore = InMemoryKeychainStore()
        store.setKey(provider: "GEMINI", key: "already-in-secure")

        let migrated = ApiKeyMigration.apply(legacyDefaults: defaults, secure: store)

        #expect(!migrated)
        #expect(store.getKey(provider: "GEMINI") == "already-in-secure")
        // Legacy entry still wiped even though we didn't overwrite the secure value.
        #expect(defaults.string(forKey: "apiKey_GEMINI") == nil)
    }

    @Test func suggestionParserSanitizesProviderLineResponses() {
        let raw = """
        1. "Yellow lights keep pulling me home"
        * Yellow lights keep pulling me home
        - Static in the choir of the road
        model_response>
        You are RhymeAI's on-device songwriting assistant.
        This line is deliberately far too long to be a usable lyric suggestion because it keeps going past the expected single-line length limit for the assistant surface.
        2) I trade the dark for a borrowed glow
        """

        let suggestions = AIService().parseSuggestionList(raw)

        #expect(suggestions == [
            "Yellow lights keep pulling me home",
            "Static in the choir of the road",
            "I trade the dark for a borrowed glow"
        ])
    }

    @Test func suggestionParserAcceptsJsonArrayAndObjectWrappers() {
        let service = AIService()

        #expect(service.parseSuggestionList(#"["1. First clean line", "\"Second clean line\"", "First clean line"]"#) == [
            "First clean line",
            "Second clean line"
        ])
        #expect(service.parseSuggestionList(#"{"suggestions":["- First wrapped line","2) Second wrapped line"]}"#) == [
            "First wrapped line",
            "Second wrapped line"
        ])
    }

    @Test func suggestionPromptShapesImmediateAndWholeSongContext() {
        let service = AIService()
        let immediatePrompt = service.buildPrompt(
            theme: "late-night resolve",
            lyrics: "[Verse]\nYellow lights on a midnight road",
            targetRhymeLine: "Yellow lights on a midnight road",
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "A",
            currentSection: .verse,
            complexity: .moderate,
            useWholeSongContext: false
        )
        let wholeSongPrompt = service.buildPrompt(
            theme: "ignored when whole-song context is enabled",
            lyrics: "[Verse]\nYellow lights\n\n[Chorus]\nKeep moving",
            targetRhymeLine: nil,
            rhymeType: .slant,
            rhymeScheme: "ABAB",
            currentLetter: "B",
            currentSection: .chorus,
            complexity: .complex,
            useWholeSongContext: true
        )

        #expect(immediatePrompt.contains("late-night resolve"))
        #expect(immediatePrompt.contains("Prioritize the immediate writing context"))
        #expect(immediatePrompt.contains("MUST end with a **Perfect Rhyme**"))
        #expect(immediatePrompt.contains("Current song section: Verse."))
        #expect(immediatePrompt.contains("Complexity level: Moderate"))
        #expect(immediatePrompt.contains("Respond with exactly 6 lines"))

        #expect(wholeSongPrompt.contains("Whole song context enabled; infer the theme from the full lyrics."))
        #expect(wholeSongPrompt.contains("Analyze the whole song for story arc"))
        #expect(wholeSongPrompt.contains("new rhyme sound (\"B\")"))
        #expect(wholeSongPrompt.contains("Current song section: Chorus."))
        #expect(wholeSongPrompt.contains("Complexity level: Complex"))
    }

    @Test func rewritePromptIncludesEveryActionContract() {
        let service = AIService()

        for action in RewriteAction.allCases {
            let prompt = service.buildRewritePrompt(
                action: action,
                lyrics: "[Bridge]\nI keep the melody close",
                selection: "I keep the melody close",
                currentSection: .bridge
            )

            #expect(prompt.contains("Current song section: Bridge."))
            #expect(prompt.contains("Action: \(action.label)"))
            #expect(prompt.contains("Instruction: \(action.instruction)"))
            #expect(prompt.contains("Preserve line breaks where present."))
            #expect(prompt.contains(#"{"rewrite": "..."}"#))
        }
    }

    @Test func emptySuggestionResponsesParseToEmptyList() {
        let service = AIService()

        #expect(service.parseSuggestionList("") == [])
        #expect(service.parseSuggestionList("```json\n[]\n```") == [])
    }

    @MainActor
    @Test func geminiSuggestionRewriteAndStreamingPathsWorkWithDebugKey() async throws {
        let apiKey = Self.geminiTestKey
        if apiKey.isEmpty { return }

        let service = AIService()
        let lyrics = "[Verse]\nYellow lights on a midnight road\nI keep the melody close"

        let suggestions = try await service.getSuggestions(
            provider: .gemini,
            apiKey: apiKey,
            modelId: AIModel.default.id,
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
        #expect(!suggestions.isEmpty, "Gemini returned no suggestions")
        #expect(suggestions.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        for action in RewriteAction.allCases {
            let rewrite = try await service.getRewrite(
                provider: .gemini,
                apiKey: apiKey,
                modelId: AIModel.default.id,
                action: action,
                fullLyrics: lyrics,
                selection: "I keep the melody close",
                currentSection: .verse
            )
            #expect(!rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Gemini returned no \(action.label) rewrite")
        }

        var streamed: [String] = []
        for try await line in service.streamSuggestions(
            provider: .gemini,
            apiKey: apiKey,
            modelId: AIModel.default.id,
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
        }
        #expect(!streamed.isEmpty, "Gemini stream emitted no suggestions")
        #expect(streamed.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @MainActor
    @Test func geminiInvalidKeyFailureIsUserFacingAndDoesNotEchoSecret() async throws {
        let service = AIService()
        let invalidKey = "invalid-gemini-key-for-test"

        do {
            _ = try await service.getSuggestions(
                provider: .gemini,
                apiKey: invalidKey,
                modelId: AIModel.default.id,
                theme: "",
                lyrics: "one line",
                targetRhymeLine: nil,
                rhymeType: .perfect,
                rhymeScheme: "AABB",
                currentLetter: "A",
                currentSection: .unknown,
                complexity: .moderate,
                useWholeSongContext: false
            )
            #expect(Bool(false), "Expected invalid Gemini key to fail")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            #expect(!message.isEmpty)
            #expect(message.contains("Provider") || message.contains("API error"))
            #expect(!message.contains(invalidKey))
        }
    }

    private static let fixtureDictionary = PronunciationDictionary.fromLines([
        "yellow\tY EH1 L OW0",
        "music\tM Y UW1 Z IH0 K",
        "road\tR OW1 D",
        "glowed\tG L OW1 D",
        "orange\tAO1 R AH0 N JH|AO1 R IH0 N JH"
    ])

    private static var geminiTestKey: String {
        ProcessInfo.processInfo.environment["GEMINI_TEST_KEY"]
            ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_GEMINI_TEST_KEY"]
            ?? ""
    }

}
