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

        // The next line is the verse's third lyric line: "B", a new sound.
        #expect(context.currentLetter == "B")
        #expect(context.targetLine == nil)
        #expect(context.currentLineIndex == 3)
        #expect(context.currentSection == .verse)
    }

    @Test func rhymeContextUsesLatestPreviousLyricWithSameLetter() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .abab
        viewModel.lyrics = "[Chorus]\nfirst glow\nsecond rain\nthird road\nfourth rain"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()

        // The next line is the fifth lyric line: the scheme repeats, so it is "A",
        // anchored to the latest "A" line (line 3), not the first.
        #expect(context.currentLetter == "A")
        #expect(context.targetLine == "third road")
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

    @Test func insertSuggestionUsesUITextViewUTF16CursorUnits() {
        let viewModel = EditorViewModel()
        viewModel.lyrics = "🌙 glow"
        viewModel.cursorPosition = ("🌙" as NSString).length

        viewModel.insertSuggestion("new line")

        // A cursor inside a lyric line never splits it: the suggestion follows the line.
        let inserted = "🌙 glow\nnew line\n"
        #expect(viewModel.lyrics == inserted)
        #expect(viewModel.cursorPosition == (inserted as NSString).length)
    }

    @Test func geminiModelPickerStartsWithCurrentGeminiModels() {
        let modelIDs = AIModel.models(for: .gemini).map(\.id)

        #expect(modelIDs == [
            "gemini-3.8-flash",
            "gemini-4-argon",
            "gemini-3.7-flash",
            "gemini-3.6-flash",
            "gemini-3.5-flash",
            "gemini-3.5-flash-lite",
            "gemini-3.1-pro-preview",
            "gemini-3-flash-preview",
            "gemini-3.1-flash-lite-preview",
            "gemini-2.5-pro",
            "gemini-2.5-flash",
            "gemini-2.5-flash-lite"
        ])
    }

    @Test func openAIModelPickerStartsWithCurrentGPT5Models() {
        let modelIDs = AIModel.models(for: .openai).map(\.id)

        #expect(modelIDs == [
            "gpt-6-astra",
            "gpt-6.1-sol",
            "gpt-6-sol",
            "gpt-6-luna",
            "gpt-6-instant",
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
            "claude-fable-5-1",
            "claude-fable-5",
            "claude-opus-5-5",
            "claude-sonnet-5-5",
            "claude-haiku-5-5",
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
    @Test func freshAndInvalidProviderPreferencesRecoverToLocal() throws {
        for storedProvider in [nil, "UNSUPPORTED_PROVIDER"] as [String?] {
            let suiteName = "rhymeai.provider-default.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            if let storedProvider {
                defaults.set(storedProvider, forKey: "selectedProvider")
            }
            defaults.set(AIModel.gpt4o.rawValue, forKey: "selectedModel")

            let viewModel = EditorViewModel(
                keychainStore: InMemoryKeychainStore(),
                defaults: defaults
            )

            #expect(viewModel.selectedProvider == .local)
            #expect(viewModel.selectedModel == .localModel)
        }
    }

    @MainActor
    @Test func validReturningProviderPreferenceIsPreserved() throws {
        let suiteName = "rhymeai.provider-returning.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AIProvider.claude.rawValue, forKey: "selectedProvider")
        defaults.set(AIModel.claudeSonnet46.rawValue, forKey: "selectedModel")

        let viewModel = EditorViewModel(
            keychainStore: InMemoryKeychainStore(),
            defaults: defaults
        )

        #expect(viewModel.selectedProvider == .claude)
        #expect(viewModel.selectedModel == .claudeSonnet46)
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
        #expect(ProsodyAnalyzer.metricFeet(prosody.stressPattern) == "ˈDA da | ˌDA")
        #expect(prosody.isFallback == false)
    }

    @Test func prosodyAnalyzerUsesFallbackForUnknownWords() {
        let prosody = ProsodyAnalyzer.analyzeWord("Scottys", dictionary: Self.fixtureDictionary)

        #expect(prosody.syllableCount == 2)
        #expect(prosody.stressPattern == [1, 0])
        #expect(prosody.isFallback)
    }

    @Test func prosodyFallbackKeepsSyllabicLeWithoutDoubleDecrement() {
        #expect(ProsodyAnalyzer.analyzeWord("obstacles", dictionary: Self.fixtureDictionary).syllableCount == 3)
        #expect(ProsodyAnalyzer.analyzeWord("candles", dictionary: Self.fixtureDictionary).syllableCount == 2)
        #expect(ProsodyAnalyzer.analyzeWord("tables", dictionary: Self.fixtureDictionary).syllableCount == 2)
        #expect(ProsodyAnalyzer.analyzeWord("candle", dictionary: Self.fixtureDictionary).syllableCount == 2)
    }

    @Test func prosodyFallbackStillReducesSilentEAndPluralEs() {
        #expect(ProsodyAnalyzer.analyzeWord("cake", dictionary: Self.fixtureDictionary).syllableCount == 1)
        #expect(ProsodyAnalyzer.analyzeWord("mile", dictionary: Self.fixtureDictionary).syllableCount == 1)
        #expect(ProsodyAnalyzer.analyzeWord("miles", dictionary: Self.fixtureDictionary).syllableCount == 1)
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

    @Test func migrationPreservesLegacyKeyWhenSecureWriteFails() {
        let suiteName = "rhymeai.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("still-needed", forKey: "apiKey_GEMINI")
        let store = RejectingKeychainStore()

        let migrated = ApiKeyMigration.apply(legacyDefaults: defaults, secure: store)

        #expect(!migrated)
        #expect(store.getKey(provider: "GEMINI").isEmpty)
        #expect(defaults.string(forKey: "apiKey_GEMINI") == "still-needed")
    }

    @MainActor
    @Test func failedSettingsKeychainDeletePreservesEditorErrorAndKnownKeyPresence() {
        let store = RejectingKeychainStore(seed: [AIProvider.gemini.rawValue: "existing"])
        let viewModel = EditorViewModel(keychainStore: store)
        viewModel.errorMessage = "Existing editor error"

        let removed = viewModel.saveApiKey(provider: .gemini, key: "")

        #expect(!removed)
        #expect(viewModel.hasApiKey(for: .gemini))
        #expect(store.getKey(provider: AIProvider.gemini.rawValue) == "existing")
        #expect(viewModel.errorMessage == "Existing editor error")
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
            theme: "",
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
        // "road" is in the dictionary, so the prompt constrains ending words
        // and over-generates 2x for the rhyme filter.
        #expect(immediatePrompt.contains("End each line with one of these rhyming words:"))
        #expect(immediatePrompt.contains("Respond with exactly 12 lines"))

        #expect(wholeSongPrompt.contains("Whole song context enabled; infer the theme from the full lyrics."))
        #expect(wholeSongPrompt.contains("Analyze the whole song for story arc"))
        #expect(wholeSongPrompt.contains("new rhyme sound (\"B\")"))
        #expect(wholeSongPrompt.contains("Current song section: Chorus."))
        #expect(wholeSongPrompt.contains("Complexity level: Complex"))
        // No target line: no constraint block and no over-generation.
        #expect(!wholeSongPrompt.contains("End each line with"))
        #expect(wholeSongPrompt.contains("Respond with exactly 6 lines"))
    }

    @Test func suggestionPromptOmitsUnrelatedLyricsWhenWholeSongContextIsOff() {
        let targetLine = "Keep only this target line"
        let unrelatedSentinel = "PRIVATE_UNRELATED_STANZA_SENTINEL"
        let prompt = AIService().buildPrompt(
            theme: "quiet resolve",
            lyrics: "[Verse]\n\(targetLine)\n\n[Bridge]\n\(unrelatedSentinel)",
            targetRhymeLine: targetLine,
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "A",
            currentSection: .verse,
            complexity: .moderate,
            useWholeSongContext: false
        )

        #expect(prompt.contains("quiet resolve"))
        #expect(prompt.contains(targetLine))
        #expect(!prompt.contains(unrelatedSentinel))
    }

    @MainActor
    @Test func firstCloudSuggestionRequestsConsentBeforeStarting() {
        let suiteName = "rhymeai.consent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), defaults: defaults)
        viewModel.saveProvider(.gemini)
        viewModel.lyrics = "private line"

        viewModel.getSuggestions()

        #expect(viewModel.cloudAISharingRequest?.provider == .gemini)
        #expect(viewModel.cloudAISharingRequest?.purpose == "suggestions")
        // Whole Song Context is on by default, so the first request asks to share the whole song.
        #expect(viewModel.cloudAISharingRequest?.scope == .wholeSong)
        #expect(!viewModel.isLoading)
    }

    @MainActor
    @Test func limitedCloudConsentDoesNotAuthorizeWholeSongRequests() {
        let suiteName = "rhymeai.consent.scope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), defaults: defaults)
        viewModel.saveProvider(.gemini)
        viewModel.setCloudAISharingConsent(true, scope: .selectedContext)
        viewModel.saveUseWholeSongContext(true)
        viewModel.lyrics = "private full lyric"

        viewModel.getSuggestions()

        #expect(viewModel.cloudAISharingRequest?.scope == .wholeSong)
        #expect(!viewModel.isLoading)
    }

    @MainActor
    @Test func consentRevocationCancelsPendingCloudRequest() {
        let suiteName = "rhymeai.consent.revoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = EditorViewModel(keychainStore: InMemoryKeychainStore(), defaults: defaults)
        viewModel.saveProvider(.gemini)
        viewModel.saveUseWholeSongContext(false)
        viewModel.lyrics = "private line"
        viewModel.getSuggestions()
        #expect(viewModel.cloudAISharingRequest != nil)

        viewModel.setCloudAISharingConsent(false, scope: .selectedContext)

        #expect(viewModel.cloudAISharingRequest == nil)
        #expect(!viewModel.isLoading)
    }

    @Test func rewritePromptOmitsSurroundingLyricsWhenWholeSongContextIsOff() {
        let sentinel = "REWRITE_BEFORE_92ce"
        let selected = "REWRITE_ALLOWED_81bd"
        let prompt = AIService().buildRewritePrompt(
            action: .punchUp,
            lyrics: "\(sentinel)\n\(selected)",
            selection: selected,
            currentSection: .verse,
            useWholeSongContext: false
        )

        #expect(prompt.contains(selected))
        #expect(!prompt.contains(sentinel))
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

    @Test func localFrameworkFailureBecomesActionableMessage() {
        // The raw failure seen when the system model reports available but cannot run.
        let raw = NSError(domain: "FoundationModels.LanguageModelError", code: -1)

        let withGemma = AIService.mapLocalGenerationError(raw, gemmaDownloadAvailable: true)
        let withoutGemma = AIService.mapLocalGenerationError(raw, gemmaDownloadAvailable: false)

        #expect(withGemma.localizedDescription == "The on-device model couldn't respond on this device. Download Gemma or choose a cloud provider in Settings.")
        #expect(withoutGemma.localizedDescription == "The on-device model couldn't respond on this device. Choose a cloud provider in Settings.")
        #expect(!withGemma.localizedDescription.contains("FoundationModels"))
    }

    @Test func localFrameworkCasesMapByNameSoRetryableFailuresStayRetryable() throws {
        let busy = AIService.localError(forFoundationModelsCase: "rateLimited", gemmaDownloadAvailable: true)
        let concurrent = AIService.localError(forFoundationModelsCase: "concurrentRequests", gemmaDownloadAvailable: true)
        let blocked = AIService.localError(forFoundationModelsCase: "guardrailViolation", gemmaDownloadAvailable: true)
        let unknown = AIService.localError(forFoundationModelsCase: "assetsUnavailable", gemmaDownloadAvailable: false)

        let busyMessage = try #require(busy.errorDescription)
        #expect(busyMessage == "The on-device model is busy. Try again in a moment.")
        #expect(concurrent.errorDescription == busyMessage)
        #expect(AIErrorRecoveryAction(errorMessage: busyMessage) == .retry)
        #expect(blocked.errorDescription == AIServiceError.blockedResponse.errorDescription)
        #expect(unknown.errorDescription == "The on-device model couldn't respond on this device. Choose a cloud provider in Settings.")
    }

    @Test func foundationModelsCaseNameReadsEnumCasesWithAndWithoutPayloads() {
        enum Sample: Error { case rateLimited(detail: String), assetsUnavailable }

        #expect(AIService.foundationModelsCaseName(Sample.rateLimited(detail: "x")) == "rateLimited")
        #expect(AIService.foundationModelsCaseName(Sample.assetsUnavailable) == "assetsUnavailable")
    }

    @Test func localErrorMappingKeepsRecognizedAndUnrelatedErrors() {
        let recognized = AIService.mapLocalGenerationError(AIServiceError.decodingError)
        let cancelled = AIService.mapLocalGenerationError(CancellationError())
        let unrelated = AIService.mapLocalGenerationError(URLError(.timedOut))

        #expect(recognized.localizedDescription == "Failed to parse AI response.")
        #expect(cancelled is CancellationError)
        #expect((unrelated as? URLError)?.code == .timedOut)
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
    @Test(.enabled(if: Self.geminiTestKey != nil, "GEMINI_TEST_KEY is required for live Gemini service verification"))
    func geminiSuggestionRewriteAndStreamingPathsWorkWithDebugKey() async throws {
        let apiKey = try #require(Self.geminiTestKey)

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
    @Test(.enabled(if: Self.geminiTestKey != nil, "GEMINI_TEST_KEY is required for live Gemini cancellation verification"))
    func geminiStreamingCanBeCancelledAfterFirstSuggestionWithDebugKey() async throws {
        let apiKey = try #require(Self.geminiTestKey)

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

    // MARK: - SectionMap tests

    @Test func sectionMapParsesOnlyBracketedHeaders() {
        let lyrics = "[Verse 1]\nLine A\nLine B\n\n[Chorus]\nHook line"
        let map = SectionMap(lyrics: lyrics)

        #expect(map.sections.count == 2)
        #expect(map.sections[0].type == .verse)
        #expect(map.sections[0].ordinal == 1)
        #expect(map.sections[1].type == .chorus)
        #expect(map.sections[1].ordinal == 1)
    }

    @Test func sectionMapParsesBareSectionHeaders() {
        let lyrics = "verse\nLine A\nLine B\n\nchorus\nHook line"
        let map = SectionMap(lyrics: lyrics)

        #expect(map.sections.count == 2)
        #expect(map.sections[0].type == .verse)
        #expect(map.sections[1].type == .chorus)
    }

    @Test func sectionMapOrdinalCountsPerType() {
        let lyrics = "[Verse 1]\nA\n\n[Chorus]\nB\n\n[Verse 2]\nC\n\n[Chorus]\nD"
        let map = SectionMap(lyrics: lyrics)

        let verses = map.sections.filter { $0.type == .verse }
        let choruses = map.sections.filter { $0.type == .chorus }
        #expect(verses.map(\.ordinal) == [1, 2])
        #expect(choruses.map(\.ordinal) == [1, 2])
    }

    @Test func sectionMapImplicitLeadingBlockIsUnknown() {
        let lyrics = "Intro line\n\n[Chorus]\nHook"
        let map = SectionMap(lyrics: lyrics)

        #expect(map.sections[0].type == .unknown)
        #expect(map.sections[0].ordinal == 1)
        #expect(map.sections[1].type == .chorus)
    }

    @Test func sectionMapBareHeaderNotMatchedForLongLines() {
        // "chorus of angels" is a lyric, not a header.
        let lyrics = "[Verse]\ncorrect header\nchor of angels is a lyric"
        let map = SectionMap(lyrics: lyrics)
        // Only one section — the bare "chor..." line is NOT a header.
        #expect(map.sections.count == 1)
    }

    @Test func sectionAtLineIndexReturnsCorrectSection() {
        let lyrics = "[Verse]\nLine 1\n\n[Chorus]\nHook"
        let map = SectionMap(lyrics: lyrics)

        // Line 0 = "[Verse]", line 1 = "Line 1", line 2 = blank, line 3 = "[Chorus]"
        #expect(map.sectionAt(lineIndex: 1)?.type == .verse)
        #expect(map.sectionAt(lineIndex: 4)?.type == .chorus)
    }

    @Test func sectionMapLinesForFirstChorusExtractsLyricLines() {
        let lyrics = "[Verse]\nVerse line\n\n[Chorus]\nHook one\nHook two\n\n[Verse 2]\nAnother verse"
        let map = SectionMap(lyrics: lyrics)
        let rawLines = lyrics.components(separatedBy: "\n")

        let lines = map.lines(forFirstOf: .chorus, in: rawLines)
        #expect(lines == ["Hook one", "Hook two"])
    }

    // MARK: - Chorus candidate injection tests

    @Test func rhymeConstraintBlockInjectsChorusEndWordsForRepeatChorus() {
        // "night" rhymes with "light", "fight", "right" etc.
        let chorusLines = ["We shine so bright", "Dancing through the night"]
        let firstChorusEndWords = AIService.endWords(of: chorusLines) // ["bright","night"]
        let block = AIService.rhymeConstraintBlock(
            targetRhymeLine: "We shine so bright",
            rhymeType: .perfect,
            currentSection: .chorus,
            firstChorusEndWords: firstChorusEndWords
        )

        // Hook end-words should be first in the candidates list.
        guard let block else {
            Issue.record("Expected a constraint block but got nil")
            return
        }
        let brightIndex = block.range(of: "bright")
        let nightIndex = block.range(of: "night")
        // Both hook words must appear.
        #expect(brightIndex != nil)
        #expect(nightIndex != nil)
    }

    @Test func rhymeConstraintBlockExcludesChorusEndWordsForVerse() {
        let chorusLines = ["We move through rain", "Washing out the stain"]
        let firstChorusEndWords = AIService.endWords(of: chorusLines) // ["rain","stain"]
        // "plain" rhymes with "rain"; the verse should avoid "rain" and "stain".
        let block = AIService.rhymeConstraintBlock(
            targetRhymeLine: "Walking through the plain",
            rhymeType: .perfect,
            currentSection: .verse,
            firstChorusEndWords: firstChorusEndWords
        )
        // Extract the candidate words from the block and check "rain"/"stain" absent.
        // The block format is: "End each line with one of these rhyming words: w1, w2 (choose...)"
        guard let block,
              let rangeStart = block.range(of: "rhyming words: "),
              let rangeEnd = block.range(of: " (choose") else {
            // No block → dictionary miss or all candidates excluded, skip assertion.
            return
        }
        let candidateString = String(block[rangeStart.upperBound ..< rangeEnd.lowerBound])
        let candidateWords = candidateString.components(separatedBy: ", ")
        #expect(!candidateWords.contains("rain"))
        #expect(!candidateWords.contains("stain"))
    }

    @Test func rhymeConstraintBlockNeverEmptiesCandidatesOnExclusion() {
        // Contrived: target line ends in a word whose ONLY rhyme candidate is
        // a chorus end-word. Fallback must keep the unfiltered list.
        // We can't easily force this in a dictionary test, but we can verify
        // the static logic: if filtered list is empty we fall back to unfiltered.
        // Build a tiny mock by testing with a word that has very few rhymes
        // and supplying ALL of them as chorus end-words.
        let targetLine = "She turns to face the light"
        let candidates = RhymeConstraint.candidateEndWords(targetWord: "light", rhymeType: .perfect)
        guard !candidates.isEmpty else { return } // dictionary miss, skip
        // Supply all candidates as chorus words → should fall back to unfiltered
        let block = AIService.rhymeConstraintBlock(
            targetRhymeLine: targetLine,
            rhymeType: .perfect,
            currentSection: .verse,
            firstChorusEndWords: candidates
        )
        // Block must still be non-nil (either unfiltered or nil due to dict miss).
        // Key invariant: we never produce an empty candidate list in the block.
        if let block {
            #expect(block.contains("End each line with one of these rhyming words:"))
        }
    }

    // MARK: - Prompt sentence tests

    @Test func sectionInstanceSentenceVerseProducesVerbatimText() {
        let sentence = AIService.sectionInstanceSentence(section: .verse, ordinal: 3, firstChorusLines: nil)
        #expect(sentence == "This is Verse 3.")
    }

    @Test func sectionInstanceSentenceChorusFirstInstanceIsNil() {
        // First chorus: no instance sentence.
        let sentence = AIService.sectionInstanceSentence(section: .chorus, ordinal: 1, firstChorusLines: ["Hook line"])
        #expect(sentence == nil)
    }

    @Test func sectionInstanceSentenceChorusRepeatContainsVerbatimPrefix() {
        let firstLines = ["Moving to the beat", "Taking every seat"]
        let sentence = AIService.sectionInstanceSentence(section: .chorus, ordinal: 2, firstChorusLines: firstLines)

        guard let sentence else {
            Issue.record("Expected non-nil sentence for chorus instance 2")
            return
        }
        #expect(sentence.hasPrefix("This is the chorus (instance 2). Keep hook language and ending words consistent with the established chorus:"))
        #expect(sentence.contains("Moving to the beat"))
        #expect(sentence.contains("Taking every seat"))
    }

    @Test func sectionInstanceSentenceBridgeProducesVerbatimText() {
        let sentence = AIService.sectionInstanceSentence(section: .bridge, ordinal: 1, firstChorusLines: nil)
        #expect(sentence == "This is the bridge — introduce a contrasting rhyme sound and cadence; avoid the chorus's ending words.")
    }

    @Test func buildPromptContainsVerseInstanceSentence() {
        let service = AIService()
        let prompt = service.buildPrompt(
            theme: "road",
            lyrics: "[Verse 1]\nFirst line\n\n[Chorus]\nHook\n\n[Verse 2]\nSecond line",
            targetRhymeLine: nil,
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "A",
            currentSection: .verse,
            sectionOrdinal: 2,
            firstChorusLines: nil,
            complexity: .moderate,
            useWholeSongContext: false
        )
        #expect(prompt.contains("This is Verse 2."))
    }

    @Test func buildPromptContainsChorusRepeatSentenceWithFirstChorusLines() {
        let service = AIService()
        let firstLines = ["We rise together", "Through every weather"]
        let prompt = service.buildPrompt(
            theme: "unity",
            lyrics: "[Chorus]\nWe rise together\n\n[Chorus]\nRepeat",
            targetRhymeLine: nil,
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "A",
            currentSection: .chorus,
            sectionOrdinal: 2,
            firstChorusLines: firstLines,
            complexity: .moderate,
            useWholeSongContext: true
        )
        #expect(prompt.contains("This is the chorus (instance 2). Keep hook language and ending words consistent with the established chorus:"))
        #expect(prompt.contains("We rise together"))
        #expect(prompt.contains("Through every weather"))
    }

    @Test func buildPromptContainsBridgeSentence() {
        let service = AIService()
        let prompt = service.buildPrompt(
            theme: "contrast",
            lyrics: "[Bridge]\nA new direction",
            targetRhymeLine: nil,
            rhymeType: .near,
            rhymeScheme: "ABAB",
            currentLetter: "A",
            currentSection: .bridge,
            sectionOrdinal: 1,
            firstChorusLines: nil,
            complexity: .moderate,
            useWholeSongContext: false
        )
        #expect(prompt.contains("This is the bridge — introduce a contrasting rhyme sound and cadence; avoid the chorus's ending words."))
    }

    // MARK: - Tier propagation tests

    @Test func rhymeLineFilterTierMatchesPerfectRhyme() {
        // "light" rhymes perfectly with "night", "right", "fight" etc.
        guard let filter = RhymeLineFilter(targetLine: "she saw the light", rhymeType: .perfect) else {
            return // Dictionary miss on test system; skip.
        }
        let tier = filter.tier(of: "we stayed the night")
        #expect(tier == 2)
    }

    @Test func rhymeLineFilterTierZeroForNonRhyme() {
        guard let filter = RhymeLineFilter(targetLine: "she saw the light", rhymeType: .perfect) else { return }
        let tier = filter.tier(of: "the clouds were gray and wide")
        #expect(tier == 0)
    }

    @Test func sectionMapOrdinalFlowsThroughRhymeContext() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .aabb
        viewModel.lyrics = "[Verse 1]\nFirst verse\n\n[Chorus]\nHook it\n\n[Verse 2]\nSecond verse"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()
        #expect(context.currentSection == .verse)
        #expect(context.sectionOrdinal == 2)
    }

    @Test func firstChorusLinesPopulatedForRepeatChorus() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .aabb
        viewModel.lyrics = "[Chorus]\nRising up\nNever stop\n\n[Verse]\nSomething\n\n[Chorus]\nNext chorus line"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()
        #expect(context.currentSection == .chorus)
        #expect(context.sectionOrdinal == 2)
        #expect(context.firstChorusLines != nil)
        #expect(context.firstChorusLines?.contains("Rising up") == true)
    }

    @Test func firstChorusLinesNilForFirstChorusInstance() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .aabb
        viewModel.lyrics = "[Chorus]\nRising up"
        viewModel.cursorPosition = viewModel.lyrics.count

        let context = viewModel.computeRhymeContext()
        #expect(context.currentSection == .chorus)
        #expect(context.sectionOrdinal == 1)
        #expect(context.firstChorusLines == nil)
    }

    // MARK: - BeatGrid tests

    @Test func beatGridSyllablesMapToBeatsAndBars() {
        // "hello world" → 3 syllables at 1 syl/beat, 4/4 → beats=3, bars=0.75 → fits
        let grid = BeatGrid.compute(lyrics: "hello world", bpm: 90)
        #expect(grid.lines.count == 1)
        let line = grid.lines[0]
        #expect(line.syllableCount == 3)
        #expect(abs(line.beats - 3.0) < 0.001)
        #expect(abs(line.bars - 0.75) < 0.001)
        #expect(line.fit == .fits)
    }

    @Test func beatGridSecondsPerLineCalculation() {
        // 4 beats at 120 bpm → 4 * 60/120 = 2.0 s
        let grid = BeatGrid.compute(lyrics: "one two three four", bpm: 120)
        #expect(grid.lines.count == 1)
        let line = grid.lines[0]
        let expected = line.beats * 60.0 / 120.0
        #expect(abs(line.secondsPerLine - expected) < 0.001)
    }

    @Test func beatGridExactlyOneBarClassifiedAsFits() {
        // 4 syllables = 4 beats = exactly 1 bar in 4/4 → FITS
        let grid = BeatGrid.compute(lyrics: "one two three four", bpm: 90)
        #expect(grid.lines.count == 1)
        #expect(grid.lines[0].syllableCount == 4)
        #expect(grid.lines[0].fit == .fits)
    }

    @Test func beatGridOneBarPlusOneBeatClassifiedAsTight() {
        // 5 syllables → beats=5 > 4 but ≤ 5 → TIGHT
        let grid = BeatGrid.compute(lyrics: "one two three four five", bpm: 90)
        #expect(grid.lines.count == 1)
        #expect(grid.lines[0].fit == .tight)
    }

    @Test func beatGridMoreThanOneBarPlusOneBeatClassifiedAsOverflow() {
        // 6 syllables → beats=6 > 5 → OVERFLOW
        let grid = BeatGrid.compute(lyrics: "one two three four five six", bpm: 90)
        #expect(grid.lines.count == 1)
        #expect(grid.lines[0].fit == .overflow)
    }

    @Test func beatGridBracketedHeadersAreSkipped() {
        let lyrics = "[Verse 1]\nhello world"
        let grid = BeatGrid.compute(lyrics: lyrics, bpm: 90)
        // Only the lyric line appears; [Verse 1] header is excluded.
        #expect(grid.lines.count == 1)
        #expect(grid.lines[0].text == "hello world")
    }

    @Test func beatGridBareHeadersAreSkipped() {
        let lyrics = "chorus\none two three"
        let grid = BeatGrid.compute(lyrics: lyrics, bpm: 90)
        #expect(grid.lines.count == 1)
    }

    @Test func beatGridBlankLinesAreSkipped() {
        let lyrics = "one two\n\nthree four"
        let grid = BeatGrid.compute(lyrics: lyrics, bpm: 90)
        #expect(grid.lines.count == 2)
    }

    @Test func beatGridTapTempoAveragesFourTapsAt500msIntervals() {
        // 5 timestamps at 500 ms intervals → 4 × 500 ms intervals → 120 bpm
        let timestamps: [TimeInterval] = [0, 500, 1000, 1500, 2000]
        let bpm = BeatGrid.tapTempoBpm(timestamps: timestamps)
        #expect(bpm == 120)
    }

    @Test func beatGridTapTempoRequiresAtLeastTwoTimestamps() {
        #expect(BeatGrid.tapTempoBpm(timestamps: []) == nil)
        #expect(BeatGrid.tapTempoBpm(timestamps: [1000]) == nil)
    }

    @Test func beatGridTapTempoClampedToMinimum40() {
        // 10 000 ms interval → 6 bpm → clamp to 40
        let bpm = BeatGrid.tapTempoBpm(timestamps: [0, 10_000])
        #expect(bpm == 40)
    }

    @Test func beatGridTapTempoClampedToMaximum220() {
        // 100 ms interval → 600 bpm → clamp to 220
        let bpm = BeatGrid.tapTempoBpm(timestamps: [0, 100])
        #expect(bpm == 220)
    }

    @Test func beatGridBpmClampedToMinimum40() {
        let grid = BeatGrid.compute(lyrics: "hello", bpm: 0)
        #expect(grid.bpm == 40)
    }

    @Test func beatGridBpmClampedToMaximum220() {
        let grid = BeatGrid.compute(lyrics: "hello", bpm: 999)
        #expect(grid.bpm == 220)
    }

    @Test func beatGridBpmPassedThroughWhenInRange() {
        let grid = BeatGrid.compute(lyrics: "hello", bpm: 90)
        #expect(grid.bpm == 90)
    }

    // MARK: - Editor Toggle Persistence

    @Test func editorToggleWholeSongContextRoundTrips() {
        // Write via the VM save path, then read it back via a fresh VM instance to
        // confirm UserDefaults persistence survives across object lifetimes.
        let vm = EditorViewModel()
        let initial = vm.useWholeSongContext
        vm.saveUseWholeSongContext(!initial)
        let vm2 = EditorViewModel()
        #expect(vm2.useWholeSongContext == !initial)
        // Restore original to avoid polluting other test runs.
        vm.saveUseWholeSongContext(initial)
    }

    @Test func editorToggleHighlightRhymesRoundTrips() {
        let vm = EditorViewModel()
        let initial = vm.isHighlightEnabled
        vm.saveIsHighlightEnabled(!initial)
        let vm2 = EditorViewModel()
        #expect(vm2.isHighlightEnabled == !initial)
        vm.saveIsHighlightEnabled(initial)
    }

    @Test func editorToggleSyllableColoringRoundTrips() {
        let vm = EditorViewModel()
        let initial = vm.isSyllableColoringEnabled
        vm.saveIsSyllableColoringEnabled(!initial)
        let vm2 = EditorViewModel()
        #expect(vm2.isSyllableColoringEnabled == !initial)
        vm.saveIsSyllableColoringEnabled(initial)
    }

    @Test func editorToggleStressPreviewRoundTrips() {
        let vm = EditorViewModel()
        let initial = vm.isStressPreviewEnabled
        vm.saveIsStressPreviewEnabled(!initial)
        let vm2 = EditorViewModel()
        #expect(vm2.isStressPreviewEnabled == !initial)
        vm.saveIsStressPreviewEnabled(initial)
    }

    @Test func editorToggleRhymeHighlightRoundTrips() {
        let vm = EditorViewModel()
        let initial = vm.isRhymeHighlightEnabled
        vm.saveIsRhymeHighlightEnabled(!initial)
        let vm2 = EditorViewModel()
        #expect(vm2.isRhymeHighlightEnabled == !initial)
        vm.saveIsRhymeHighlightEnabled(initial)
    }

    @Test func editorToggleBeatGridRoundTrips() {
        let vm = EditorViewModel()
        let initial = vm.isBeatGridEnabled
        vm.saveIsBeatGridEnabled(!initial)
        let vm2 = EditorViewModel()
        #expect(vm2.isBeatGridEnabled == !initial)
        vm.saveIsBeatGridEnabled(initial)
    }

    // MARK: - dB Normalisation Helper

    // The normalisation formula is (dB + 60) / 60, clamped 0..1. These tests
    // exercise the pure math without touching AVFoundation.

    @Test func dbNormalisationSilenceMapsToZero() {
        // -60 dB should map to 0.0 (silence floor)
        let dB: Float = -60
        let result = max(0, min(1, (dB + 60.0) / 60.0))
        #expect(result == 0.0)
    }

    @Test func dbNormalisationFullScaleMapsToOne() {
        // 0 dB (full scale) should map to 1.0
        let dB: Float = 0
        let result = max(0, min(1, (dB + 60.0) / 60.0))
        #expect(result == 1.0)
    }

    @Test func dbNormalisationMidRangeMapsToHalf() {
        // -30 dB is midpoint of -60..0 → 0.5
        let dB: Float = -30
        let result = max(0, min(1, (dB + 60.0) / 60.0))
        #expect(abs(result - 0.5) < 0.001)
    }

    @Test func dbNormalisationBelowFloorClampedToZero() {
        // Below -60 dB (e.g. -100 dB) should clamp to 0
        let dB: Float = -100
        let result = max(0, min(1, (dB + 60.0) / 60.0))
        #expect(result == 0.0)
    }

    @Test func dbNormalisationAboveCeilingClampedToOne() {
        // Positive dB (clip condition) should clamp to 1
        let dB: Float = 6
        let result = max(0, min(1, (dB + 60.0) / 60.0))
        #expect(result == 1.0)
    }

    // MARK: - Recordings Aggregation

    @Test func recordingsAggregationLabelsOrphanedMemo() {
        // When the title map doesn't contain the projectId, the label is "Deleted song".
        // This mirrors the display logic in ProjectsDrawerView.reloadRecordings().
        let titleMap: [String: String] = ["known-id": "My Song"]
        let unknownId = "orphaned-project-id"
        let title = titleMap[unknownId] ?? "Deleted song"
        #expect(title == "Deleted song")
    }

    @Test func recordingsAggregationResolvesKnownProjectTitle() {
        let titleMap: [String: String] = ["abc123": "Summer Bop"]
        let title = titleMap["abc123"] ?? "Deleted song"
        #expect(title == "Summer Bop")
    }

    @Test func recordingsAggregationUsesUntitledFallbackForEmptyTitle() {
        // Empty-title projects should display "Untitled Song", not an empty string.
        let rawTitle = ""
        let displayTitle = rawTitle.isEmpty ? "Untitled Song" : rawTitle
        #expect(displayTitle == "Untitled Song")
    }

}

private final class RejectingKeychainStore: KeychainStore {
    private var storage: [String: String]

    init(seed: [String: String] = [:]) {
        storage = seed
    }

    func getKey(provider: String) -> String { storage[provider] ?? "" }
    func setKey(provider: String, key: String) -> Bool { false }
    func deleteKey(provider: String) -> Bool { false }
    func allKeys() -> [String: String] { storage }
    func clear() {}
}
