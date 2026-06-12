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

    @Test func rhymeContextUsesFirstActiveSchemeLetterForEmptyLyrics() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .custom
        viewModel.customRhymeScheme = "BABA"
        viewModel.lyrics = ""
        viewModel.cursorPosition = 100

        let context = viewModel.computeRhymeContext()

        #expect(context.currentLetter == "B")
        #expect(context.targetLine == nil)
        #expect(context.stanzaLines.isEmpty)
        #expect(context.currentLineIndex == 0)
        #expect(context.currentSection == .unknown)
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

    @Test func localModelPickerUsesOnDeviceModelOnly() {
        let models = AIModel.models(for: .local)

        #expect(models == [.localModel])
        #expect(models.first?.displayName == "On-Device Model")
        #expect(AIProvider.local.keyHint == "Runs on-device with Apple Foundation Models when available.")
    }

    @MainActor
    @Test func providerSwitchingKeepsSelectedModelAligned() {
        let defaults = UserDefaults.standard
        let savedProvider = defaults.string(forKey: "selectedProvider")
        let savedModel = defaults.string(forKey: "selectedModel")
        defer {
            if let savedProvider {
                defaults.set(savedProvider, forKey: "selectedProvider")
            } else {
                defaults.removeObject(forKey: "selectedProvider")
            }
            if let savedModel {
                defaults.set(savedModel, forKey: "selectedModel")
            } else {
                defaults.removeObject(forKey: "selectedModel")
            }
        }
        defaults.removeObject(forKey: "selectedProvider")
        defaults.removeObject(forKey: "selectedModel")

        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore())

        viewModel.saveModel(.gpt4o)
        viewModel.saveProvider(.local)

        #expect(viewModel.selectedProvider == .local)
        #expect(viewModel.selectedModel == .localModel)
        #expect(viewModel.apiKey(for: .local).isEmpty)

        viewModel.saveProvider(.claude)

        #expect(viewModel.selectedProvider == .claude)
        #expect(viewModel.selectedModel.provider == .claude)
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

    @Test func prosodyAnalyzerRendersSecondaryStressInIpaPreview() {
        let prosody = ProsodyAnalyzer.analyzeWord("radio", dictionary: Self.fixtureDictionary)

        #expect(prosody.ipa == "ˈreɪdiˌoʊ")
        #expect(prosody.stressPattern == [1, 0, 2])
        #expect(prosody.isFallback == false)
    }

    @Test func prosodyAnalyzerUsesFallbackForUnknownWords() {
        let prosody = ProsodyAnalyzer.analyzeWord("Scottys", dictionary: Self.fixtureDictionary)

        #expect(prosody.syllableCount == 2)
        #expect(prosody.stressPattern == [1, 0])
        #expect(prosody.isFallback)
    }

    @Test func prosodyAnalyzerNormalizesPunctuationDigitsAndInternalApostrophes() {
        #expect(ProsodyAnalyzer.normalizeWord("  'Don't!!42") == "don't")

        let prosody = ProsodyAnalyzer.analyzeLine("Don't stop, road-99 glowed.", dictionary: Self.fixtureDictionary)

        #expect(prosody.words.map(\.normalized) == ["don't", "stop", "road", "glowed"])
        #expect(prosody.syllableCount == 4)
        #expect(prosody.stressPattern == [1, 1, 1, 1])
    }

    @Test func prosodyAnalyzerUsesCmuPhonesForRhymeKeys() {
        let roadKeys = ProsodyAnalyzer.rhymeKeys(for: "road", dictionary: Self.fixtureDictionary)
        let glowedKeys = ProsodyAnalyzer.rhymeKeys(for: "glowed", dictionary: Self.fixtureDictionary)

        #expect(!Set(roadKeys).intersection(glowedKeys).isEmpty)
    }

    @Test func prosodyAnalyzerRhymeKeysIncludeMultipleDictionaryPronunciations() {
        let keys = ProsodyAnalyzer.rhymeKeys(for: "orange", dictionary: Self.fixtureDictionary)

        #expect(keys == [
            "AO R AH N JH",
            "AO R IH N JH"
        ])
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

    @Test func localRewriteCleanerStripsMalformedTurnMarkers() {
        let raw = """
        start_of_turn>model
        Where we swear we're free
        <end_of_turn>
        """

        #expect(
            AIService().cleanLocalRewrite(raw, selection: "Where we claim to be free") ==
            "Where we swear we're free"
        )
    }

    @Test func localRewriteCleanerExtractsJsonAfterMarkers() {
        let raw = """
        <start_of_turn>model
        {"rewrite":"Cold corporate walls still listen"}
        <end_of_turn>
        """

        #expect(
            AIService().cleanLocalRewrite(raw, selection: "Cold corporate walls") ==
            "Cold corporate walls still listen"
        )
    }

    @Test func localRewriteCleanerRejectsMarkerOnlyAndUnchangedOutput() {
        let service = AIService()

        #expect(service.cleanLocalRewrite("start_of_turn>", selection: "Where we claim to be free").isEmpty)
        #expect(service.cleanLocalRewrite("Where we claim to be free", selection: "Where we claim to be free").isEmpty)
    }

    @Test func localSingleWordRewriteDropsLabelsAndMarkers() {
        let raw = """
        <start_of_turn>model
        Replacement: gleam
        <end_of_turn>
        """

        #expect(AIService().cleanLocalRewrite(raw, selection: "glow") == "gleam")
    }

    @Test func localSingleWordFallbackCoversCommonRewriteActions() {
        let service = AIService()

        #expect(service.fallbackLocalSingleWordRewrite(selection: "glow", action: .rephrase) == "gleam")
        #expect(service.fallbackLocalSingleWordRewrite(selection: "glow", action: .harderRhyme) == "show")
        #expect(service.fallbackLocalSingleWordRewrite(selection: "glow", action: .punchUp) == "flare")
        #expect(service.fallbackLocalSingleWordRewrite(selection: "real", action: .harderRhyme) == "feel")
        #expect(service.fallbackLocalSingleWordRewrite(selection: "xylophone", action: .rephrase).isEmpty)
    }

    @Test func localSingleWordValidatorRejectsAwkwardHarderRhymeExpansion() {
        let service = AIService()

        #expect(service.cleanLocalRewrite("reality", selection: "real") == "reality")
        #expect(
            service.acceptLocalSingleWordRewrite(
                candidate: "reality",
                selection: "real",
                action: .harderRhyme
            ).isEmpty
        )
        let fallback = service.acceptLocalSingleWordRewrite(
            candidate: "reality",
            selection: "real",
            action: .harderRhyme
        ).isEmpty ? service.fallbackLocalSingleWordRewrite(selection: "real", action: .harderRhyme) : "reality"
        #expect(fallback == "feel")
        #expect(
            service.acceptLocalSingleWordRewrite(
                candidate: "feel",
                selection: "real",
                action: .harderRhyme
            ) == "feel"
        )
    }

    @Test func localHarderRhymeValidatorRejectsReportedBadSingleWordContexts() {
        let service = AIService()
        let makeLyrics = "In the land of make believe"
        let makeContext = service.singleWordRewriteContext(
            lyrics: makeLyrics,
            selection: "make",
            selectionStart: (makeLyrics as NSString).range(of: "make").location
        )
        #expect(
            service.acceptLocalSingleWordRewrite(
                candidate: "deceive",
                selection: "make",
                action: .harderRhyme,
                context: makeContext,
                rejectedCandidates: []
            ).isEmpty
        )

        let callsLyrics = "Birds chirping in phone calls"
        let callsContext = service.singleWordRewriteContext(
            lyrics: callsLyrics,
            selection: "calls",
            selectionStart: (callsLyrics as NSString).range(of: "calls").location
        )
        #expect(
            service.acceptLocalSingleWordRewrite(
                candidate: "walls",
                selection: "calls",
                action: .harderRhyme,
                context: callsContext,
                rejectedCandidates: []
            ).isEmpty
        )
        #expect(
            service.fallbackLocalSingleWordRewrite(
                selection: "calls",
                action: .harderRhyme,
                context: callsContext
            ).isEmpty
        )

        let feedsLyrics = "Personalized social feeds"
        let feedsContext = service.singleWordRewriteContext(
            lyrics: feedsLyrics,
            selection: "feeds",
            selectionStart: (feedsLyrics as NSString).range(of: "feeds").location
        )
        #expect(
            service.acceptLocalSingleWordRewrite(
                candidate: "streams",
                selection: "feeds",
                action: .harderRhyme,
                context: feedsContext,
                rejectedCandidates: []
            ).isEmpty
        )
    }

    @Test func localHarderRhymeValidatorRejectsPreviousPreviewOnRedo() {
        let service = AIService()
        let lyrics = "Cold corporate walls"
        let context = service.singleWordRewriteContext(
            lyrics: lyrics,
            selection: "walls",
            selectionStart: (lyrics as NSString).range(of: "walls").location
        )

        #expect(
            service.acceptLocalSingleWordRewrite(
                candidate: "calls",
                selection: "walls",
                action: .harderRhyme,
                context: context,
                rejectedCandidates: []
            ) == "calls"
        )
        #expect(
            service.acceptLocalSingleWordRewrite(
                candidate: "calls",
                selection: "walls",
                action: .harderRhyme,
                context: context,
                rejectedCandidates: ["calls"]
            ).isEmpty
        )
        #expect(
            service.fallbackLocalSingleWordRewrite(
                selection: "walls",
                action: .harderRhyme,
                context: context,
                rejectedCandidates: ["calls"]
            ) == "falls"
        )
    }

    @Test func emptySuggestionResponsesParseToEmptyList() {
        let service = AIService()

        #expect(service.parseSuggestionList("") == [])
        #expect(service.parseSuggestionList("```json\n[]\n```") == [])
    }

    @MainActor
    @Test func cloudSuggestionSurfacesNoKeyBeforeNetworkWork() async throws {
        do {
            _ = try await AIService().getSuggestions(
                provider: .gemini,
                apiKey: "",
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
            #expect(Bool(false), "Expected missing Gemini key to fail")
        } catch {
            #expect(error.localizedDescription == "No API key set. Go to Settings to add your Gemini API key.")
        }
    }

    @MainActor
    @Test func cloudStreamSurfacesNoKeyBeforeNetworkWork() async throws {
        do {
            for try await _ in AIService().streamSuggestions(
                provider: .gemini,
                apiKey: "",
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
            ) {}
            #expect(Bool(false), "Expected missing Gemini key to fail")
        } catch {
            #expect(error.localizedDescription == "No API key set. Go to Settings to add your Gemini API key.")
        }
    }

    @MainActor
    @Test func cloudRewriteAndSynonymsSurfaceNoKeyBeforeNetworkWork() async throws {
        let service = AIService()

        do {
            _ = try await service.getRewrite(
                provider: .gemini,
                apiKey: "",
                modelId: AIModel.default.id,
                action: .rephrase,
                fullLyrics: "one line",
                selection: "one line",
                currentSection: .unknown
            )
            #expect(Bool(false), "Expected missing Gemini key to fail")
        } catch {
            #expect(error.localizedDescription.contains("No API key set"))
        }

        do {
            _ = try await service.getSynonyms(
                provider: .gemini,
                apiKey: "",
                modelId: AIModel.default.id,
                word: "line",
                lineContext: "one line"
            )
            #expect(Bool(false), "Expected missing Gemini key to fail")
        } catch {
            #expect(error.localizedDescription.contains("No API key set"))
        }
    }

    @Test func providerStatusMessagesAreUserFacing() {
        #expect(AIService.userFacingStatusMessage(for: 401) == "Provider rejected the request — check your API key in Settings.")
        #expect(AIService.userFacingStatusMessage(for: 404) == "Provider could not find the requested model — pick another in Settings.")
        #expect(AIService.userFacingStatusMessage(for: 429) == "Provider rate limit reached — wait a moment and retry.")
        #expect(AIService.userFacingStatusMessage(for: 503) == "Provider service error — try again shortly.")
    }

    @Test func providerNetworkAndBlockedMessagesAreUserFacing() {
        #expect(AIServiceError.networkUnavailable.localizedDescription == "Provider request failed — check your connection and try again.")
        #expect(AIServiceError.blockedResponse.localizedDescription == "Provider blocked the response for safety. Try adjusting the lyric or prompt.")
    }

    @Test func geminiBlockedResponsesSurfaceSafetyMessage() throws {
        let promptBlocked: [String: Any] = [
            "promptFeedback": [
                "blockReason": "SAFETY"
            ]
        ]
        let candidateBlocked: [String: Any] = [
            "candidates": [
                [
                    "finishReason": "SAFETY"
                ]
            ]
        ]

        do {
            _ = try AIService.geminiText(from: promptBlocked)
            #expect(Bool(false), "Expected prompt block to fail")
        } catch {
            #expect(error.localizedDescription == "Provider blocked the response for safety. Try adjusting the lyric or prompt.")
        }

        do {
            _ = try AIService.geminiText(from: candidateBlocked)
            #expect(Bool(false), "Expected candidate block to fail")
        } catch {
            #expect(error.localizedDescription == "Provider blocked the response for safety. Try adjusting the lyric or prompt.")
        }
    }

    @MainActor
    @Test func geminiSuggestionRewriteAndStreamingPathsWorkWithDebugKey() async throws {
        let apiKey = try #require(Self.geminiTestKey, "GEMINI_TEST_KEY is required for live Gemini service verification")

        let service = AIService()
        let lyrics = "[Verse]\nYellow lights on a midnight road\nI keep the melody close"

        for model in Self.liveGeminiModels {
            let suggestions = try await service.getSuggestions(
                provider: .gemini,
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
            #expect(!suggestions.isEmpty, "Gemini returned no suggestions for \(model.id)")
            #expect(suggestions.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

            for action in RewriteAction.allCases {
                let rewrite = try await service.getRewrite(
                    provider: .gemini,
                    apiKey: apiKey,
                    modelId: model.id,
                    action: action,
                    fullLyrics: lyrics,
                    selection: "I keep the melody close",
                    currentSection: .verse
                )
                #expect(!rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Gemini returned no \(action.label) rewrite for \(model.id)")
            }

            var streamed: [String] = []
            for try await line in service.streamSuggestions(
                provider: .gemini,
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
            }
            #expect(!streamed.isEmpty, "Gemini stream emitted no suggestions for \(model.id)")
            #expect(streamed.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
    }

    @MainActor
    @Test func geminiStreamingCanBeCancelledAfterFirstSuggestionWithDebugKey() async throws {
        let apiKey = try #require(Self.geminiTestKey, "GEMINI_TEST_KEY is required for live Gemini cancellation verification")

        let service = AIService()
        let lyrics = "[Verse]\nYellow lights on a midnight road\nI keep the melody close"

        for model in Self.liveGeminiModels {
            var streamed: [String] = []

            for try await line in service.streamSuggestions(
                provider: .gemini,
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

            #expect(streamed.count == 1, "Gemini stream did not cancel after first suggestion for \(model.id)")
            #expect(!streamed[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @MainActor
    @Test func geminiInvalidKeyFailureIsUserFacingAndDoesNotEchoSecret() async throws {
        let service = AIService()
        let invalidKey = "invalid-gemini-key-for-test"

        for model in Self.liveGeminiModels {
            do {
                _ = try await service.getSuggestions(
                    provider: .gemini,
                    apiKey: invalidKey,
                    modelId: model.id,
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
                #expect(Bool(false), "Expected invalid Gemini key to fail for \(model.id)")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                #expect(!message.isEmpty)
                #expect(message.contains("Provider") || message.contains("API error"))
                #expect(!message.contains(invalidKey))
            }
        }
    }

    private static let liveGeminiModels: [AIModel] = [
        .gemini35Flash,
        .gemini31Pro
    ]

    private static let fixtureDictionary = PronunciationDictionary.fromLines([
        "yellow\tY EH1 L OW0",
        "music\tM Y UW1 Z IH0 K",
        "road\tR OW1 D",
        "glowed\tG L OW1 D",
        "radio\tR EY1 D IY0 OW2",
        "orange\tAO1 R AH0 N JH|AO1 R IH0 N JH"
    ])

    private static var geminiTestKey: String? {
        let key = ProcessInfo.processInfo.environment["GEMINI_TEST_KEY"]
            ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_GEMINI_TEST_KEY"]
            ?? ""
        return key.isEmpty ? nil : key
    }

}
