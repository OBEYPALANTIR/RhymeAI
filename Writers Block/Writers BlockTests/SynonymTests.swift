import Combine
import Foundation
import Testing
@testable import Writers_Block

@Suite(.serialized)
struct SynonymTests {
    @Test func sanitizerParsesJsonObjectInStableOrder() {
        let raw = #"{"synonyms":["Glow","shine","GLOW","Gleam"]}"#

        let result = SynonymSanitizer.extract(raw, excluding: "Shine", limit: 8)

        #expect(result == ["Glow", "Gleam"])
    }

    @Test func sanitizerParsesJsonArrayInStableOrder() {
        let raw = #"["Glow","Gleam","Spark"]"#

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 8)

        #expect(result == ["Glow", "Gleam", "Spark"])
    }

    @Test func sanitizerNormalizesDelimitedListDecorations() {
        let raw = """
        1. “Ｇｌｏｗ”, - don’t
        3) re—enter
        • Gleam
        """

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 8)

        #expect(result == ["Glow", "don't", "re-enter", "Gleam"])
    }

    @Test func sanitizerRejectsUnsafeEntriesBeforeApplyingLimit() {
        let overLimit = String(repeating: "a", count: 33)
        let raw = """
        Rules:
        <end_turn>
        {"synonyms":
        ---

        two words
        \(overLimit)
        SHINE
        Glow
        glow
        Gleam
        Spark
        Blaze
        """

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 3)

        #expect(result == ["Glow", "Gleam", "Spark"])
    }

    @Test func sanitizerRejectsControlCharacters() {
        let raw = "Glow\u{0000}\nGleam"

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 8)

        #expect(result == ["Gleam"])
    }

    @Test func localGGUFUsesNewlinePromptFormat() {
        let format = AIService.synonymPromptFormat(provider: .local, usesGGUF: true)

        #expect(format == .newlineList)
    }

    @Test func appleLocalUsesJsonPromptFormat() {
        let format = AIService.synonymPromptFormat(provider: .local, usesGGUF: false)

        #expect(format == .jsonObject)
    }

    @Test func cloudProviderUsesJsonPromptFormat() {
        let format = AIService.synonymPromptFormat(provider: .claude, usesGGUF: true)

        #expect(format == .jsonObject)
    }

    @Test func pipelineTopUpRetriesOnceWithAcceptedExclusions() async throws {
        let requests = SynonymRequestRecorder(responses: [
            "Glow, glow, shine, two words",
            "Glow, Gleam, Spark"
        ])

        let result = try await SynonymGenerationPipeline.collect(
            target: "shine",
            limit: 8,
            request: { exclusions in
                try await requests.next(exclusions: exclusions)
            }
        )

        #expect(result == ["Glow", "Gleam", "Spark"])
        #expect(await requests.exclusions == [[], ["Glow"]])
    }

    @Test func pipelineCountsExistingSynonymsBeforeDecidingToTopUp() async throws {
        let requests = SynonymRequestRecorder(responses: ["Spark", "Unused"])

        let result = try await SynonymGenerationPipeline.collect(
            target: "shine",
            limit: 8,
            accepting: ["Glow", "Gleam"],
            request: { exclusions in
                try await requests.next(exclusions: exclusions)
            }
        )

        #expect(result == ["Glow", "Gleam", "Spark"])
        #expect(await requests.callCount == 1)
        #expect(await requests.exclusions == [["Glow", "Gleam"]])
    }

    @Test func pipelineStopsAfterOneTopUpWhenResultsRemainPartial() async throws {
        let requests = SynonymRequestRecorder(responses: ["Glow", "Glow"])

        let result = try await SynonymGenerationPipeline.collect(
            target: "shine",
            limit: 8,
            request: { exclusions in
                try await requests.next(exclusions: exclusions)
            }
        )

        #expect(result == ["Glow"])
        #expect(await requests.callCount == 2)
    }

    @Test func pipelineKeepsPartialResultsWhenTopUpFails() async throws {
        let requests = SynonymRequestRecorder(
            responses: ["Glow"],
            failure: AIServiceError.networkUnavailable
        )

        let result = try await SynonymGenerationPipeline.collect(
            target: "shine",
            limit: 8,
            request: { exclusions in
                try await requests.next(exclusions: exclusions)
            }
        )

        #expect(result == ["Glow"])
        #expect(await requests.callCount == 2)
    }

    @Test func pipelinePropagatesCancellationFromTopUp() async throws {
        let requests = SynonymRequestRecorder(
            responses: ["Glow"],
            failure: CancellationError()
        )
        var cancelled = false

        do {
            _ = try await SynonymGenerationPipeline.collect(
                target: "shine",
                limit: 8,
                request: { exclusions in
                    try await requests.next(exclusions: exclusions)
                }
            )
        } catch is CancellationError {
            cancelled = true
        } catch {}

        #expect(cancelled)
    }

    @Test func pipelineDoesNotCallProviderWhenAlreadyCancelled() async throws {
        let requests = SynonymRequestRecorder(responses: ["Glow"])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SynonymGenerationPipeline.collect(
                target: "shine",
                limit: 8,
                request: { exclusions in
                    try await requests.next(exclusions: exclusions)
                }
            )
        }
        var cancelled = false

        do {
            _ = try await task.value
        } catch is CancellationError {
            cancelled = true
        } catch {}

        #expect(cancelled)
        #expect(await requests.callCount == 0)
    }

    @Test func pipelineStopsBeforeTopUpWhenCancelledPassOneReturnsNormally() async throws {
        let requests = SuspendedFirstSynonymRequest()
        let task = Task {
            try await SynonymGenerationPipeline.collect(
                target: "shine",
                limit: 8,
                request: { exclusions in
                    await requests.next(exclusions: exclusions)
                }
            )
        }
        await requests.waitForCallCount(1)

        task.cancel()
        await requests.resumeFirst(with: "Glow")
        var cancelled = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            cancelled = true
        } catch {}

        #expect(cancelled)
        #expect(await requests.callCount == 1)
    }

    @Test func synonymGGUFBuilderReceivesExactlyOneFinalChatTemplate() {
        let rawPrompt = AIService.synonymPrompt(
            word: "shine",
            lineContext: "Neon lights shine",
            limit: 8,
            format: .newlineList,
            excluding: []
        )

        let finalRunnerInput = GGUFModelService.gemmaPrompt(rawPrompt)
        let expected = "<start_of_turn>user\n\(rawPrompt)\n<end_of_turn>\n<start_of_turn>model"

        #expect(!rawPrompt.contains("<start_of_turn>"))
        #expect(finalRunnerInput == expected)
        #expect(GGUFModelService.gemmaPrompt(finalRunnerInput) == expected)
    }

    @Test func localGGUFPromptUsesCanonicalSynonymContractStructure() {
        let rawPrompt = AIService.synonymPrompt(
            word: " Shine ",
            lineContext: " Neon & <rain> ",
            limit: 7,
            format: .newlineList,
            excluding: ["Glow", " glow ", "shine", "", "Gleam & Spark"]
        )

        #expect(rawPrompt.components(separatedBy: "<synonym-contract>").count - 1 == 1)
        #expect(rawPrompt.contains("<target>Shine</target>"))
        #expect(rawPrompt.contains("<context>Neon &amp; &lt;rain&gt;</context>"))
        #expect(rawPrompt.contains("<counts minimum=\"3\" maximum=\"7\"></counts>"))
        #expect(rawPrompt.contains("<unique required=\"true\"></unique>"))
        #expect(rawPrompt.contains("<stop-early when-exhausted=\"true\"></stop-early>"))
        #expect(rawPrompt.contains(
            "<exclusions><word>Glow</word><word>Gleam &amp; Spark</word></exclusions>"
        ))
        #expect(!rawPrompt.contains("<word>shine</word>"))
        #expect(!rawPrompt.contains("<start_of_turn>"))
    }

    @Test func ggufRouteKeepsCapturedModelPathAcrossTopUp() async throws {
        let route = SynonymGGUFRoute(filePath: "/models/first.gguf")
        let runner = SwitchingGGUFRunner(
            initialSelection: "/models/first.gguf",
            replacementSelection: "/models/second.gguf",
            responses: ["Glow", "Gleam\nSpark"]
        )

        let result = try await SynonymGenerationPipeline.collect(
            target: "shine",
            limit: 8,
            request: { _ in
                try await route.generate(prompt: "single word replacements", runner: runner)
            }
        )

        #expect(result == ["Glow", "Gleam", "Spark"])
        #expect(await runner.loadedPaths == ["/models/first.gguf", "/models/first.gguf"])
        #expect(await runner.simulatedSelection == "/models/second.gguf")
    }

    @Test func concurrentGGUFRoutesKeepLoadAndGenerationAtomic() async throws {
        let runner = InterleavingGGUFRunner()
        let firstRoute = SynonymGGUFRoute(filePath: "/models/first.gguf")
        let secondRoute = SynonymGGUFRoute(filePath: "/models/second.gguf")
        let first = Task {
            try await firstRoute.generate(prompt: "first", runner: runner)
        }
        await runner.waitUntilFirstLoadStarts()
        let second = Task {
            try await secondRoute.generate(prompt: "second", runner: runner)
        }

        let results = try await [first.value, second.value]

        #expect(results == ["first:/models/first.gguf", "second:/models/second.gguf"])
    }

    @Test func ggufUnloadWaitsForActiveGenerationTransaction() async throws {
        let runner = LifecycleGGUFRunner()
        let route = SynonymGGUFRoute(filePath: "/models/first.gguf")
        let generation = Task {
            try await route.generate(prompt: "first", runner: runner)
        }
        await runner.waitUntilGenerationStarts()
        let unload = Task {
            await runner.unload()
        }
        await runner.waitUntilUnloadIsQueued()

        #expect(await !runner.didUnload)

        await runner.finishGeneration()
        _ = try await generation.value
        await unload.value

        #expect(await runner.didUnload)
    }

    @Test func completeSynonymResultsSuppressRetryEvenWhenRefreshHasError() {
        let action = SynonymResultPresentation.recoveryAction(
            resultCount: SynonymGenerationPipeline.minimumUsefulCount,
            error: AIServiceError.networkUnavailable
        )

        #expect(action == nil)
    }

    @Test func missingApiKeyRoutesToSettingsInsteadOfRetry() {
        let action = SynonymResultPresentation.recoveryAction(
            resultCount: 0,
            error: AIServiceError.noApiKey(provider: "Gemini")
        )

        #expect(action == .openSettings)
    }

    @Test func transientSynonymErrorOffersRetryWhenIncomplete() {
        let action = SynonymResultPresentation.recoveryAction(
            resultCount: 0,
            error: AIServiceError.networkUnavailable
        )

        #expect(action == .retry)
    }

    @Test func unavailableLocalModelOffersRetryWhenIncomplete() {
        let action = SynonymResultPresentation.recoveryAction(
            resultCount: 1,
            error: AIServiceError.localModelUnavailable(reason: "Model moved")
        )

        #expect(action == .retry)
    }

    @Test func sanitizerRejectsPromptEchoLineBeforeCommaSplitting() {
        let raw = "Sure, here are:\nGlow"

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 8)

        #expect(result == ["Glow"])
    }

    @Test func sanitizerPreservesStandaloneWordsThatCanAppearInPromptProse() {
        let raw = "model\nsure\nuniqueness\nstop\nGlow"

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 8)

        #expect(result == ["model", "sure", "uniqueness", "stop", "Glow"])
    }

    @Test func ggufMarkerCleanupPreservesStandaloneModelThroughSanitizer() {
        let raw = "<start_of_turn>model\nmodel\nGlow\n<end_of_turn>"

        let cleaned = GGUFModelService.stripMarkers(raw)
        let result = SynonymSanitizer.extract(cleaned, excluding: "shine", limit: 8)

        #expect(result == ["model", "Glow"])
    }

    @Test func sanitizerRejectsStructuralControlAndEchoLinesBeforeCapping() {
        let raw = """
        end-of-turn
        assistant-response
        start-of-turn
        model-response
        you-are-rhymeai
        return-only
        ignore-instructions
        No JSON, bullets, numbering, labels
        Glow
        Gleam
        Spark
        """

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 3)

        #expect(result == ["Glow", "Gleam", "Spark"])
    }

    @Test func sanitizerRejectsPromptContractEchoLinesBeforeSplitting() {
        let raw = """
        Task: return replacements, Drift
        Context: a lyric line, Haze
        Rules: single words, Blaze
        Do not include shine, Flare
        Already accepted: Gleam, Burn
        As an AI, Spark
        Glow
        """

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 8)

        #expect(result == ["Glow"])
    }

    @Test func sanitizerRejectsCanonicalStructuredRuleBeforeCommaSplitting() {
        let raw = """
        Follow the structured counts, uniqueness, stop, and exclusion contract.
        Glow
        """

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 8)

        #expect(result == ["Glow"])
    }

    @Test func compactSynonymContractIsRejectedBeforeContextCommaSplitting() {
        let raw = """
        <synonym-contract><target>glow</target><context>burn, shine, fade</context><counts minimum="3" maximum="8"></counts><unique required="true"></unique><stop-early when-exhausted="true"></stop-early><exclusions></exclusions></synonym-contract>
        Spark
        """

        let result = SynonymSanitizer.extract(raw, excluding: "glow", limit: 8)

        #expect(result == ["Spark"])
    }

    @Test func prettyPrintedSynonymContractChildLinesAreRejectedBeforeCommaSplitting() {
        let raw = """
        <synonym-contract>
        <target>glow</target>
        <context>burn, shine, fade</context>
        <counts minimum="3" maximum="8"></counts>
        <unique required="true"></unique>
        <stop-early when-exhausted="true"></stop-early>
        <exclusions>
        <word>glow</word>
        </exclusions>
        </synonym-contract>
        Spark
        """

        let result = SynonymSanitizer.extract(raw, excluding: "glow", limit: 8)

        #expect(result == ["Spark"])
    }

    @Test func compactAndDashPrefixedCanonicalRulesAreRejectedBeforeCommaSplitting() {
        let raw = """
        FollowTheStructuredCounts, uniqueness, stop, and exclusion contract.
        1- Follow the structured counts, uniqueness, stop, and exclusion contract.
        A- Follow the structured counts, uniqueness, stop, and exclusion contract.
        Spark
        """

        let result = SynonymSanitizer.extract(raw, excluding: "glow", limit: 8)

        #expect(result == ["Spark"])
    }

    @Test func dashPrefixedCompactSynonymContractsAreRejectedBeforeContextCommaSplitting() {
        let contract = #"<synonym-contract><target>glow</target><context>burn, shine, fade</context><counts minimum="3" maximum="8"></counts><unique required="true"></unique><stop-early when-exhausted="true"></stop-early><exclusions></exclusions></synonym-contract>"#
        let raw = """
        1- \(contract)
        A- \(contract)
        Spark
        """

        let result = SynonymSanitizer.extract(raw, excluding: "glow", limit: 8)

        #expect(result == ["Spark"])
    }

    @Test func sanitizerDeduplicatesUsingUnicodeCaseFolding() {
        let raw = "Straße\nSTRASSE\nGlow"

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 8)

        #expect(result == ["Straße", "Glow"])
    }

    @Test func sanitizerExtractsFencedJsonBeforeTrailingCommentary() {
        let raw = """
        ```json
        {"synonyms":["Glow","Gleam"]}
        ```
        Sure
        """

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 8)

        #expect(result == ["Glow", "Gleam"])
    }

    @Test func sanitizerRejectsCompactAndCamelCaseStructuralTokens() {
        let raw = """
        endofturn
        endTurn
        startturn
        startOfTurn
        assistantResponse
        modelresponse
        youAreRhymeAI
        returnOnly
        ignoreInstructions
        Glow
        Gleam
        Spark
        """

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 3)

        #expect(result == ["Glow", "Gleam", "Spark"])
    }

    @Test func sanitizerRejectsBulletedAndNumberedPromptEchoBeforeSplitting() {
        let raw = """
        - No JSON, bullets, numbering, labels, quotes, or commentary.
        1. No JSON, bullets, numbering, labels, quotes, or commentary.
        Glow
        """

        let result = SynonymSanitizer.extract(raw, excluding: "shine", limit: 8)

        #expect(result == ["Glow"])
    }

    @MainActor
    @Test func inspectorKeepsPartialSynonymsVisibleWithRetryError() async throws {
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(synonymService: provider)
        viewModel.lyrics = "shine"

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        let displayed = Task { @MainActor in
            for await values in viewModel.$inspectorSynonyms.values where !values.isEmpty {
                return values
            }
            return []
        }
        provider.succeed(request: 0, with: ["Glow"])

        #expect(await displayed.value == ["Glow"])
        #expect(viewModel.inspectorSynonymsError != nil)
        #expect(viewModel.inspectorSynonymsRecovery == .retry)
    }

    @MainActor
    @Test func inspectorMissingApiKeyPublishesSettingsRecovery() async throws {
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(
            synonymService: provider,
            consentingTo: [.gemini]
        )
        viewModel.lyrics = "shine"
        viewModel.saveProvider(.gemini)

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        let finished = Task { @MainActor in
            for await loading in viewModel.$inspectorSynonymsLoading.values where !loading { return }
        }
        provider.fail(request: 0, with: AIServiceError.noApiKey(provider: "Gemini"))
        await finished.value

        #expect(viewModel.inspectorSynonymsError != nil)
        #expect(viewModel.inspectorSynonymsRecovery == .openSettings)
    }

    @MainActor
    @Test func inspectorSettingsRecoveryPresentsAfterInspectorDismissal() {
        let viewModel = makeViewModel(synonymService: ControlledSynonymProvider())
        viewModel.inspectorWord = "shine"

        viewModel.openSettingsFromInspector()

        #expect(!viewModel.showInspector)
        #expect(!viewModel.showSettingsSheet)

        viewModel.inspectorDidDismiss()

        #expect(viewModel.showSettingsSheet)
    }

    @MainActor
    @Test func inspectorRetryMergesExistingSynonymsWithNewResults() async throws {
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(synonymService: provider)
        viewModel.lyrics = "shine"

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        let firstFinished = Task { @MainActor in
            for await loading in viewModel.$inspectorSynonymsLoading.values where !loading { return }
        }
        provider.succeed(request: 0, with: ["Glow", "Gleam"])
        await firstFinished.value

        viewModel.retryInspectorSynonyms()
        try await provider.waitForRequestCount(2)
        let retryFinished = Task { @MainActor in
            for await loading in viewModel.$inspectorSynonymsLoading.values where !loading { return }
        }
        provider.succeed(request: 1, with: ["Spark"])
        await retryFinished.value

        #expect(viewModel.inspectorSynonyms == ["Glow", "Gleam", "Spark"])
        #expect(provider.requestedExclusions == [[], ["Glow", "Gleam"]])
    }

    @MainActor
    @Test func inspectorDiscardsCompletionFromStaleProvider() async throws {
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(
            synonymService: provider,
            consentingTo: [.gemini]
        )
        viewModel.lyrics = "shine"
        viewModel.saveProvider(.gemini)

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        viewModel.saveProvider(.claude)
        let finished = Task { @MainActor in
            for await loading in viewModel.$inspectorSynonymsLoading.values where !loading {
                return
            }
        }
        provider.succeed(request: 0, with: ["Glow", "Gleam", "Spark"])
        await finished.value

        #expect(viewModel.inspectorSynonyms.isEmpty)
    }

    @MainActor
    @Test func inspectorDiscardsCompletionAfterProviderChangesAwayAndBack() async throws {
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(
            synonymService: provider,
            consentingTo: [.gemini]
        )
        viewModel.lyrics = "shine"
        viewModel.saveProvider(.gemini)

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        viewModel.saveProvider(.claude)
        viewModel.saveProvider(.gemini)
        await complete(provider: provider, request: 0, viewModel: viewModel)

        #expect(viewModel.inspectorSynonyms.isEmpty)
    }

    @MainActor
    @Test func inspectorDiscardsCompletionAfterModelChangesAwayAndBack() async throws {
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(
            synonymService: provider,
            consentingTo: [.gemini]
        )
        viewModel.lyrics = "shine"
        viewModel.saveProvider(.gemini)
        viewModel.saveModel(.gemini35Flash)

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        viewModel.saveModel(.gemini31Pro)
        viewModel.saveModel(.gemini35Flash)
        await complete(provider: provider, request: 0, viewModel: viewModel)

        #expect(viewModel.inspectorSynonyms.isEmpty)
    }

    @MainActor
    @Test func staleRetryCannotClearLoadingForCurrentRequest() async throws {
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(synonymService: provider)
        viewModel.lyrics = "shine"

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        viewModel.retryInspectorSynonyms()
        try await provider.waitForRequestCount(2)
        let synonymsWhenLoadingFinishes = Task { @MainActor in
            for await loading in viewModel.$inspectorSynonymsLoading.values where !loading {
                return viewModel.inspectorSynonyms
            }
            return []
        }
        provider.succeed(request: 0, with: ["Old"])
        try await provider.waitForReturnCount(1)
        provider.succeed(request: 1, with: ["New", "Fresh", "Current"])

        #expect(await synonymsWhenLoadingFinishes.value == ["New", "Fresh", "Current"])
    }

    @MainActor
    @Test func inspectorDiscardsCompletionAfterActiveCredentialChanges() async throws {
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(
            synonymService: provider,
            consentingTo: [.gemini]
        )
        viewModel.lyrics = "shine"
        viewModel.saveProvider(.gemini)
        viewModel.saveApiKey(provider: .gemini, key: "first-key")

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        viewModel.saveApiKey(provider: .gemini, key: "replacement-key")
        await complete(provider: provider, request: 0, viewModel: viewModel)

        #expect(viewModel.inspectorSynonyms.isEmpty)
    }

    @MainActor
    @Test func inspectorDiscardsCompletionAfterCredentialChangesAwayAndBack() async throws {
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(
            synonymService: provider,
            consentingTo: [.gemini]
        )
        viewModel.lyrics = "shine"
        viewModel.saveProvider(.gemini)
        viewModel.saveApiKey(provider: .gemini, key: "first-key")

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        viewModel.saveApiKey(provider: .gemini, key: "replacement-key")
        viewModel.saveApiKey(provider: .gemini, key: "first-key")
        await complete(provider: provider, request: 0, viewModel: viewModel)

        #expect(viewModel.inspectorSynonyms.isEmpty)
    }

    @MainActor
    @Test func inspectorDiscardsCompletionAfterLocalEngineChanges() async throws {
        let defaults = UserDefaults.standard
        let savedProvider = defaults.string(forKey: "selectedProvider")
        let savedModel = defaults.string(forKey: "selectedModel")
        let savedEngine = defaults.string(forKey: "ggufEngineChoice")
        let savedRevision = defaults.object(forKey: "synonymLocalRevision")
        defer {
            restore(savedProvider, forKey: "selectedProvider", in: defaults)
            restore(savedModel, forKey: "selectedModel", in: defaults)
            restore(savedEngine, forKey: "ggufEngineChoice", in: defaults)
            if let savedRevision {
                defaults.set(savedRevision, forKey: "synonymLocalRevision")
            } else {
                defaults.removeObject(forKey: "synonymLocalRevision")
            }
        }
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(synonymService: provider)
        viewModel.lyrics = "shine"
        viewModel.saveProvider(.local)
        GGUFEngineChoice.gemma.save()

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        GGUFEngineChoice.appleIntelligence.save()
        await complete(provider: provider, request: 0, viewModel: viewModel)

        #expect(viewModel.inspectorSynonyms.isEmpty)
    }

    @MainActor
    @Test func inspectorDiscardsCompletionAfterSelectedGGUFChanges() async throws {
        let defaults = UserDefaults.standard
        let keys = [
            "selectedProvider", "selectedModel", "ggufEngineChoice",
            "customGGUFModels", "selectedGGUFModelFileName", "synonymLocalRevision"
        ]
        let savedValues = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in savedValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        let firstModel = GGUFCustomModel(id: "first", displayName: "First", fileName: "first.gguf")
        let secondModel = GGUFCustomModel(id: "second", displayName: "Second", fileName: "second.gguf")
        GGUFCustomModelRegistry.save([firstModel, secondModel])
        GGUFModelSelection.save(fileName: firstModel.fileName)
        GGUFEngineChoice.gemma.save()
        let provider = ControlledSynonymProvider()
        let viewModel = makeViewModel(synonymService: provider)
        viewModel.lyrics = "shine"
        viewModel.saveProvider(.local)

        viewModel.openInspector(word: "shine", range: NSRange(location: 0, length: 5))
        try await provider.waitForRequestCount(1)
        GGUFModelSelection.save(fileName: secondModel.fileName)
        await complete(provider: provider, request: 0, viewModel: viewModel)

        #expect(viewModel.inspectorSynonyms.isEmpty)
    }

    @MainActor
    private func complete(
        provider: ControlledSynonymProvider,
        request: Int,
        viewModel: EditorViewModel
    ) async {
        let finished = Task { @MainActor in
            for await loading in viewModel.$inspectorSynonymsLoading.values where !loading {
                return
            }
        }
        provider.succeed(request: request, with: ["Glow", "Gleam", "Spark"])
        await finished.value
    }

    @MainActor
    private func makeViewModel(
        synonymService: any SynonymProviding,
        consentingTo cloudProviders: [AIProvider] = []
    ) -> EditorViewModel {
        let suiteName = "rhymeai.synonym-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let viewModel = EditorViewModel(
            keychainStore: InMemoryKeychainStore(),
            synonymService: synonymService,
            defaults: defaults
        )
        for provider in cloudProviders {
            viewModel.setCloudAISharingConsent(
                true,
                for: provider,
                scope: .selectedContext
            )
        }
        return viewModel
    }

    private func restore(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

private actor SynonymRequestRecorder {
    private let responses: [String]
    private let failure: Error?
    private(set) var exclusions: [[String]] = []

    init(responses: [String], failure: Error? = nil) {
        self.responses = responses
        self.failure = failure
    }

    var callCount: Int { exclusions.count }

    func next(exclusions: [String]) throws -> String {
        self.exclusions.append(exclusions)
        let index = self.exclusions.count - 1
        if index < responses.count {
            return responses[index]
        }
        if let failure {
            throw failure
        }
        return ""
    }
}

private actor SuspendedFirstSynonymRequest {
    private struct Waiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var firstContinuation: CheckedContinuation<String, Never>?
    private var waiters: [Waiter] = []
    private(set) var callCount = 0

    func next(exclusions: [String]) async -> String {
        callCount += 1
        let currentCall = callCount
        resumeSatisfiedWaiters()
        if currentCall == 1 {
            return await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return "Gleam"
    }

    func waitForCallCount(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(count: count, continuation: continuation))
        }
    }

    func resumeFirst(with response: String) {
        firstContinuation?.resume(returning: response)
        firstContinuation = nil
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = waiters.filter { callCount >= $0.count }
        waiters.removeAll { callCount >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}

private actor SwitchingGGUFRunner: LocalGGUFRunner {
    nonisolated var isLoaded: Bool { true }

    private let replacementSelection: String
    private var responses: [String]
    private(set) var loadedPaths: [String] = []
    private(set) var simulatedSelection: String

    init(initialSelection: String, replacementSelection: String, responses: [String]) {
        self.simulatedSelection = initialSelection
        self.replacementSelection = replacementSelection
        self.responses = responses
    }

    func loadModel(filePath: String) {
        loadedPaths.append(filePath)
    }

    func generate(prompt: String) -> String {
        if loadedPaths.count == 1 {
            simulatedSelection = replacementSelection
        }
        return responses.isEmpty ? "" : responses.removeFirst()
    }

    func generate(prompt: String, loading filePath: String) -> String {
        loadedPaths.append(filePath)
        return generate(prompt: prompt)
    }

    func unload() {}
}

private actor InterleavingGGUFRunner: LocalGGUFRunner {
    nonisolated var isLoaded: Bool { true }

    private var loadedPath: String?
    private var firstLoadStarted = false
    private var firstLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeFirstLoad: CheckedContinuation<Void, Never>?

    func loadModel(filePath: String) async {
        loadedPath = filePath
        if filePath == "/models/first.gguf" {
            firstLoadStarted = true
            let waiters = firstLoadWaiters
            firstLoadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                resumeFirstLoad = continuation
            }
        } else {
            resumeFirstLoad?.resume()
            resumeFirstLoad = nil
        }
    }

    func generate(prompt: String) -> String {
        "\(prompt):\(loadedPath ?? "missing")"
    }

    func generate(prompt: String, loading filePath: String) async -> String {
        if filePath == "/models/first.gguf" {
            firstLoadStarted = true
            let waiters = firstLoadWaiters
            firstLoadWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                resumeFirstLoad = continuation
            }
        } else {
            resumeFirstLoad?.resume()
            resumeFirstLoad = nil
        }
        return "\(prompt):\(filePath)"
    }

    func waitUntilFirstLoadStarts() async {
        guard !firstLoadStarted else { return }
        await withCheckedContinuation { continuation in
            firstLoadWaiters.append(continuation)
        }
    }

    func unload() {}
}

private actor LifecycleGGUFRunner: LocalGGUFRunner {
    nonisolated var isLoaded: Bool { true }

    private var transactionIsActive = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationStarted = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishGenerationContinuation: CheckedContinuation<Void, Never>?
    private var unloadIsQueued = false
    private var unloadWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var didUnload = false

    func loadModel(filePath: String) {}

    func generate(prompt: String) -> String { prompt }

    func generate(prompt: String, loading filePath: String) async -> String {
        await acquireTransaction()
        defer { releaseTransaction() }
        generationStarted = true
        let waiters = generationWaiters
        generationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            finishGenerationContinuation = continuation
        }
        return prompt
    }

    func unload() async {
        unloadIsQueued = true
        let waiters = unloadWaiters
        unloadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await acquireTransaction()
        defer { releaseTransaction() }
        didUnload = true
    }

    func waitUntilGenerationStarts() async {
        guard !generationStarted else { return }
        await withCheckedContinuation { continuation in
            generationWaiters.append(continuation)
        }
    }

    func waitUntilUnloadIsQueued() async {
        guard !unloadIsQueued else { return }
        await withCheckedContinuation { continuation in
            unloadWaiters.append(continuation)
        }
    }

    func finishGeneration() {
        finishGenerationContinuation?.resume()
        finishGenerationContinuation = nil
    }

    private func acquireTransaction() async {
        if !transactionIsActive {
            transactionIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            transactionWaiters.append(continuation)
        }
    }

    private func releaseTransaction() {
        if transactionWaiters.isEmpty {
            transactionIsActive = false
        } else {
            transactionWaiters.removeFirst().resume()
        }
    }
}

@MainActor
private final class ControlledSynonymProvider: SynonymProviding {
    private var responseContinuations: [CheckedContinuation<[String], Error>?] = []
    private var returnCount = 0
    private(set) var requestedExclusions: [[String]] = []

    func getSynonyms(
        provider: AIProvider,
        apiKey: String,
        modelId: String,
        word: String,
        lineContext: String,
        excluding existing: [String],
        limit: Int
    ) async throws -> [String] {
        requestedExclusions.append(existing)
        let result = try await withCheckedThrowingContinuation { continuation in
            responseContinuations.append(continuation)
        }
        returnCount += 1
        return result
    }

    func waitForRequestCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if responseContinuations.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ControlledSynonymProviderError.timedOutWaitingForRequest(count)
    }

    func waitForReturnCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if returnCount >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ControlledSynonymProviderError.timedOutWaitingForReturn(count)
    }

    func succeed(request index: Int, with result: [String]) {
        guard responseContinuations.indices.contains(index),
              let continuation = responseContinuations[index] else { return }
        responseContinuations[index] = nil
        continuation.resume(returning: result)
    }

    func fail(request index: Int, with error: Error) {
        guard responseContinuations.indices.contains(index),
              let continuation = responseContinuations[index] else { return }
        responseContinuations[index] = nil
        continuation.resume(throwing: error)
    }

}

private enum ControlledSynonymProviderError: Error {
    case timedOutWaitingForRequest(Int)
    case timedOutWaitingForReturn(Int)
}
