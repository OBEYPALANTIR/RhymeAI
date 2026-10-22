import Foundation
import SwiftData
import Testing
@testable import Writers_Block

@MainActor
@Suite(.serialized)
struct CloudPrivacyFlowTests {
    @Test func localPromptsExcludeUnsharedLyricsAndChorusHintsWhenContextIsOff() throws {
        let service = AIService()
        let privateSentinel = "PRIVATE_LOCAL_STANZA_A93E"
        let chorusSentinel = "PRIVATE_LOCAL_CHORUS_6F21"
        let targetLine = "Keep only this target line"
        let lyrics = "[Verse]\nBefore the selected line\n\(targetLine)\n[Bridge]\n\(privateSentinel)"

        let suggestionPrompt = service.buildLocalSuggestionPromptForTest(
            theme: "quiet resolve",
            lyrics: lyrics,
            targetRhymeLine: targetLine,
            rhymeType: .perfect,
            currentLetter: "A",
            currentSection: .chorus,
            sectionOrdinal: 2,
            firstChorusLines: [chorusSentinel],
            useWholeSongContext: false
        )

        #expect(suggestionPrompt.contains("quiet resolve"))
        #expect(suggestionPrompt.contains(targetLine))
        #expect(!suggestionPrompt.contains(privateSentinel))
        #expect(!suggestionPrompt.contains(chorusSentinel))

        let selectedWord = "selected"
        let selectionStart = try #require(lyrics.range(of: selectedWord)).lowerBound.utf16Offset(in: lyrics)
        let applePrompt = service.buildLocalRewritePromptForTest(
            action: .rephrase,
            lyrics: lyrics,
            selection: selectedWord,
            currentSection: .verse,
            selectionStart: selectionStart,
            rejectedCandidates: [],
            useWholeSongContext: false
        )
        let gemmaPrompt = service.buildGemmaRewritePromptForTest(
            action: .rephrase,
            lyrics: lyrics,
            selection: selectedWord,
            currentSection: .verse,
            selectionStart: selectionStart,
            rejectedCandidates: [],
            useWholeSongContext: false
        )

        for prompt in [applePrompt, gemmaPrompt] {
            #expect(prompt.contains("Before the selected line"))
            #expect(prompt.contains(selectedWord))
            #expect(!prompt.contains(privateSentinel))
        }
    }

    @Test func providerSerializersExcludeUnsharedLyricsForStreamingSuggestions() async throws {
        let privateSentinel = "PRIVATE_STANZA_7D43"
        let allowedLine = "Keep only this target night"
        let matchingSuggestions = "One clear light\nTwo burn bright\nThree take flight\nFour feel right\nFive hold sight\nSix still might"

        for provider in [AIProvider.gemini, .openai, .claude] {
            PrivacyURLProtocol.reset(suggestionText: matchingSuggestions)
            let service = AIService(session: Self.makeSession())
            let modelID = try #require(AIModel.models(for: provider).first?.id)

            var streamedLines: [String] = []
            for try await line in service.streamSuggestions(
                provider: provider,
                apiKey: "synthetic-key",
                modelId: modelID,
                theme: "quiet resolve",
                lyrics: "[Verse]\n\(allowedLine)\n[Bridge]\n\(privateSentinel)",
                targetRhymeLine: allowedLine,
                rhymeType: .perfect,
                rhymeScheme: "AABB",
                currentLetter: "A",
                currentSection: .verse,
                complexity: .moderate,
                useWholeSongContext: false
            ) {
                streamedLines.append(line)
            }

            let streamingBody = try #require(PrivacyURLProtocol.capturedBodies().first)
            #expect(!streamedLines.isEmpty, "\(provider.rawValue) fixture produced no streamed suggestions")
            #expect(streamingBody.contains(allowedLine), "\(provider.rawValue) streaming serializer omitted the allowed target line")
            #expect(!streamingBody.contains(privateSentinel), "\(provider.rawValue) streaming serializer leaked unshared lyrics")
        }
    }

    @Test func cloudSuggestionStreamSanitizesProviderLineResponses() async throws {
        let raw = """
        1. "Yellow lights keep pulling me home"
        * Yellow lights keep pulling me home
        - Static in the choir of the road
        model_response>
        You are RhymeAI's on-device songwriting assistant.
        This line is deliberately far too long to be a usable lyric suggestion because it keeps going past the expected single-line length limit for the assistant surface.
        2) I trade the dark for a borrowed glow
        """
        PrivacyURLProtocol.reset(suggestionText: raw)
        let service = AIService(session: Self.makeSession())

        var streamed: [String] = []
        for try await line in service.streamSuggestions(
            provider: .gemini,
            apiKey: "synthetic-key",
            modelId: AIModel.default.id,
            theme: "",
            lyrics: "one line",
            targetRhymeLine: nil,
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "B",
            currentSection: .verse,
            complexity: .moderate,
            useWholeSongContext: false
        ) {
            streamed.append(line)
        }

        #expect(streamed == [
            "Yellow lights keep pulling me home",
            "Static in the choir of the road",
            "I trade the dark for a borrowed glow"
        ])
    }

    @Test func wholeSongScopeEscalationRequiresFreshConsentBeforeSerialization() async throws {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore()
        keychain.setKey(provider: AIProvider.gemini.rawValue, key: "synthetic-key")
        PrivacyURLProtocol.reset()
        let viewModel = EditorViewModel(
            aiService: AIService(session: Self.makeSession()),
            keychainStore: keychain,
            defaults: defaults
        )
        viewModel.saveProvider(.gemini)
        viewModel.setCloudAISharingConsent(true, scope: .selectedContext)
        viewModel.lyrics = "Allowed target\nPRIVATE_WHOLE_SONG_D41C"
        viewModel.cursorPosition = viewModel.lyrics.utf16.count

        viewModel.getSuggestions()
        #expect(await Self.waitUntil { PrivacyURLProtocol.capturedBodies().count == 1 })

        viewModel.saveUseWholeSongContext(true)
        viewModel.getSuggestions()

        #expect(viewModel.cloudAISharingRequest?.scope == .wholeSong)
        #expect(PrivacyURLProtocol.capturedBodies().count == 1)

        let request = try #require(viewModel.cloudAISharingRequest)
        viewModel.approveCloudAISharing(request)
        #expect(await Self.waitUntil { PrivacyURLProtocol.capturedBodies().count == 2 })
        #expect(PrivacyURLProtocol.capturedBodies()[1].contains("PRIVATE_WHOLE_SONG_D41C"))
    }

    @Test func retryCannotSendAfterProviderSwitchOrConsentRevocation() async throws {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore()
        keychain.setKey(provider: AIProvider.gemini.rawValue, key: "synthetic-key")
        keychain.setKey(provider: AIProvider.openai.rawValue, key: "synthetic-key")
        PrivacyURLProtocol.reset()
        let viewModel = EditorViewModel(
            aiService: AIService(session: Self.makeSession()),
            keychainStore: keychain,
            defaults: defaults
        )
        viewModel.saveProvider(.gemini)
        viewModel.setCloudAISharingConsent(true, for: .gemini, scope: .selectedContext)
        viewModel.lyrics = "Replace this phrase"
        viewModel.selectedRange = NSRange(location: 0, length: 7)

        viewModel.requestRewrite(.rephrase)
        #expect(await Self.waitUntil { viewModel.rewritePreview != nil })
        let completedRequests = PrivacyURLProtocol.capturedBodies().count

        viewModel.saveProvider(.openai)
        viewModel.retryRewrite()
        try await Task.sleep(for: .milliseconds(100))
        #expect(PrivacyURLProtocol.capturedBodies().count == completedRequests)
        #expect(viewModel.rewritePreview == nil)

        viewModel.saveProvider(.gemini)
        viewModel.selectedRange = NSRange(location: 0, length: 7)
        viewModel.requestRewrite(.rephrase)
        #expect(await Self.waitUntil { viewModel.rewritePreview != nil })
        let requestsBeforeRevocation = PrivacyURLProtocol.capturedBodies().count

        viewModel.setCloudAISharingConsent(false, for: .gemini, scope: .selectedContext)
        viewModel.retryRewrite()
        try await Task.sleep(for: .milliseconds(100))
        #expect(PrivacyURLProtocol.capturedBodies().count == requestsBeforeRevocation)
        #expect(viewModel.rewritePreview == nil)
    }

    @Test func themeEditDropsInFlightSuggestionsWithWholeSongContextOn() async throws {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore()
        keychain.setKey(provider: AIProvider.gemini.rawValue, key: "synthetic-key")
        let viewModel = EditorViewModel(
            aiService: AIService(session: Self.makeSession()),
            keychainStore: keychain,
            defaults: defaults
        )
        viewModel.saveProvider(.gemini)
        viewModel.saveUseWholeSongContext(true)
        viewModel.setCloudAISharingConsent(true, scope: .wholeSong)
        viewModel.lyrics = "A first unfinished line"
        viewModel.cursorPosition = viewModel.lyrics.utf16.count
        viewModel.theme = "leaving town"

        // Control: an undisturbed request lands its suggestions. The next line rhymes
        // with "line", so the fixture lines end on perfect rhymes for it.
        let rhymingLines = "Under the pine\nHolding the sign\nPouring the wine\nAll of it mine\nDrawing the design\nTelling me fine"
        PrivacyURLProtocol.reset(suggestionText: rhymingLines)
        viewModel.getSuggestions()
        #expect(await Self.waitUntil { !viewModel.isLoading && !viewModel.suggestions.isEmpty })

        // A theme edit while the next request is in flight drops it.
        PrivacyURLProtocol.reset(suggestionText: rhymingLines, holdResponse: true)
        defer { PrivacyURLProtocol.releaseHeldResponse() }
        viewModel.getSuggestions()
        #expect(await Self.waitUntil { PrivacyURLProtocol.capturedBodies().count == 1 })
        #expect(PrivacyURLProtocol.capturedBodies()[0].contains("leaving town"))
        let requestID = try #require(viewModel.suggestionsRequestIDForTest())
        #expect(viewModel.isLoading)

        viewModel.theme = "coming home"

        #expect(viewModel.suggestionsRequestIDForTest() != requestID)
        #expect(!viewModel.isLoading)
        #expect(viewModel.suggestions.isEmpty)
        PrivacyURLProtocol.releaseHeldResponse()
        try await Task.sleep(for: .milliseconds(300))
        #expect(viewModel.suggestions.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isLoading)
        #expect(viewModel.theme == "coming home")
    }

    @Test func delayedSuggestionResponseCannotCrossSongNavigation() async throws {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore()
        keychain.setKey(provider: AIProvider.gemini.rawValue, key: "synthetic-key")
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let first = SongProject(id: "song-a", title: "First", lyrics: "Song A private draft")
        container.mainContext.insert(first)
        try container.mainContext.save()
        PrivacyURLProtocol.reset(delay: 0.25)
        let viewModel = EditorViewModel(
            aiService: AIService(session: Self.makeSession()),
            keychainStore: keychain,
            defaults: defaults
        )
        viewModel.modelContext = container.mainContext
        viewModel.loadProject(first)
        viewModel.saveProvider(.gemini)
        viewModel.setCloudAISharingConsent(true, scope: .selectedContext)

        viewModel.getSuggestions()
        #expect(await Self.waitUntil { !PrivacyURLProtocol.capturedBodies().isEmpty })
        viewModel.newProject()
        try await Task.sleep(for: .milliseconds(400))

        #expect(viewModel.currentProjectId == nil)
        #expect(viewModel.suggestions.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isLoading)
    }

    @Test func rewriteCompletesWhenFirstAutoSaveAssignsProjectID() async throws {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore()
        keychain.setKey(provider: AIProvider.gemini.rawValue, key: "synthetic-key")
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        PrivacyURLProtocol.reset(holdResponse: true)
        defer { PrivacyURLProtocol.releaseHeldResponse() }
        let viewModel = EditorViewModel(
            aiService: AIService(session: Self.makeSession()),
            keychainStore: keychain,
            defaults: defaults
        )
        viewModel.modelContext = container.mainContext
        viewModel.newProject()
        viewModel.saveProvider(.gemini)
        viewModel.setCloudAISharingConsent(true, scope: .selectedContext)
        viewModel.title = "First save"
        viewModel.lyrics = "Replace this phrase"
        viewModel.selectedRange = NSRange(location: 0, length: 7)

        viewModel.requestRewrite(.rephrase)
        #expect(await Self.waitUntil { PrivacyURLProtocol.capturedBodies().count == 1 })
        #expect(viewModel.rewriteLoading)
        #expect(viewModel.currentProjectId == nil)

        viewModel.triggerAutoSave()
        #expect(await Self.waitUntil { viewModel.currentProjectId != nil })
        #expect(viewModel.rewriteLoading)
        PrivacyURLProtocol.releaseHeldResponse()

        #expect(await Self.waitUntil { !viewModel.rewriteLoading })
        #expect(viewModel.rewritePreview == "replacement")
        #expect(viewModel.rewriteError == nil)
    }

    @Test func delayedRewriteCannotAppearAfterRealSongSwitch() async throws {
        let (defaults, suiteName) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore()
        keychain.setKey(provider: AIProvider.gemini.rawValue, key: "synthetic-key")
        let schema = Schema([SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let first = SongProject(id: "rewrite-a", title: "First", lyrics: "Replace this phrase", theme: "")
        let second = SongProject(id: "rewrite-b", title: "Second", lyrics: "Other lyric", theme: "")
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()
        PrivacyURLProtocol.reset(holdResponse: true)
        defer { PrivacyURLProtocol.releaseHeldResponse() }
        let viewModel = EditorViewModel(
            aiService: AIService(session: Self.makeSession()),
            keychainStore: keychain,
            defaults: defaults
        )
        viewModel.modelContext = container.mainContext
        viewModel.loadProject(first)
        viewModel.saveProvider(.gemini)
        viewModel.setCloudAISharingConsent(true, scope: .selectedContext)
        viewModel.selectedRange = NSRange(location: 0, length: 7)

        viewModel.requestRewrite(.rephrase)
        #expect(await Self.waitUntil { PrivacyURLProtocol.capturedBodies().count == 1 })
        viewModel.loadProject(second)
        PrivacyURLProtocol.releaseHeldResponse()
        try await Task.sleep(for: .milliseconds(100))

        #expect(viewModel.currentProjectId == second.id)
        #expect(viewModel.rewritePreview == nil)
        #expect(viewModel.rewriteError == nil)
        #expect(!viewModel.rewriteLoading)
    }

    @Test func rhymeMismatchAndProviderEmptyResponsesUseDifferentMessages() async throws {
        let (mismatchDefaults, mismatchSuite) = Self.makeDefaults()
        defer { mismatchDefaults.removePersistentDomain(forName: mismatchSuite) }
        let keychain = InMemoryKeychainStore()
        keychain.setKey(provider: AIProvider.gemini.rawValue, key: "synthetic-key")
        PrivacyURLProtocol.reset(
            suggestionText: "The morning comes too soon\nNothing here can save us"
        )
        let mismatchViewModel = EditorViewModel(
            aiService: AIService(session: Self.makeSession()),
            keychainStore: keychain,
            defaults: mismatchDefaults
        )
        mismatchViewModel.saveProvider(.gemini)
        mismatchViewModel.setCloudAISharingConsent(true, scope: .selectedContext)
        mismatchViewModel.lyrics = "We own the night\n"
        mismatchViewModel.cursorPosition = mismatchViewModel.lyrics.utf16.count
        #expect(await Self.waitUntil { mismatchViewModel.rhymeContext.targetLine == "We own the night" })

        mismatchViewModel.getSuggestions()

        #expect(await Self.waitUntil { !mismatchViewModel.isLoading && mismatchViewModel.errorMessage != nil })
        #expect(mismatchViewModel.suggestions.isEmpty)
        #expect(mismatchViewModel.errorMessage == "The provider returned lines, but none matched the requested perfect rhyme. Try another rhyme type.")

        let (emptyDefaults, emptySuite) = Self.makeDefaults()
        defer { emptyDefaults.removePersistentDomain(forName: emptySuite) }
        PrivacyURLProtocol.reset(suggestionText: "")
        let emptyViewModel = EditorViewModel(
            aiService: AIService(session: Self.makeSession()),
            keychainStore: keychain,
            defaults: emptyDefaults
        )
        emptyViewModel.saveProvider(.gemini)
        emptyViewModel.setCloudAISharingConsent(true, scope: .selectedContext)
        emptyViewModel.lyrics = "A first unfinished line"
        emptyViewModel.cursorPosition = emptyViewModel.lyrics.utf16.count

        emptyViewModel.getSuggestions()

        #expect(await Self.waitUntil { !emptyViewModel.isLoading && emptyViewModel.errorMessage != nil })
        #expect(emptyViewModel.suggestions.isEmpty)
        #expect(emptyViewModel.errorMessage == "AI did not return suggestions. Try again.")
    }

    /// The ink burst keys off this signal. Each case streams one line, holds
    /// the response open, then ends it one way; only a stream that ends on its
    /// own with its lines still listed sets the signal.
    @Test func onlyNaturalCompletionWithListedLinesSignalsFinishedSuggestions() async throws {
        enum Interruption { case none, consume, stop, setting, streamError }
        for interruption in [Interruption.none, .consume, .stop, .setting, .streamError] {
            let (defaults, suiteName) = Self.makeDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let keychain = InMemoryKeychainStore()
            keychain.setKey(provider: AIProvider.gemini.rawValue, key: "synthetic-key")
            StagedStreamURLProtocol.reset(firstLine: "Under the pine")
            defer { StagedStreamURLProtocol.release(.finish) }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StagedStreamURLProtocol.self]
            let viewModel = EditorViewModel(
                aiService: AIService(session: URLSession(configuration: configuration)),
                keychainStore: keychain,
                defaults: defaults
            )
            viewModel.saveProvider(.gemini)
            viewModel.setCloudAISharingConsent(true, scope: .selectedContext)
            viewModel.lyrics = "A first unfinished line"
            viewModel.cursorPosition = viewModel.lyrics.utf16.count

            viewModel.getSuggestions()
            let requestID = try #require(viewModel.suggestionsRequestIDForTest())
            #expect(await Self.waitUntil { viewModel.suggestions.count == 1 }, "\(interruption): the first line streams in")
            #expect(viewModel.isLoading)
            #expect(viewModel.completedSuggestionsRequestID == nil)

            switch interruption {
            case .none, .streamError:
                break
            case .consume:
                // Using a line clears the list without cancelling the request.
                viewModel.insertSuggestion(viewModel.suggestions[0].text)
                #expect(viewModel.suggestions.isEmpty)
            case .stop:
                viewModel.cancelSuggestions()
            case .setting:
                #expect(!viewModel.useWholeSongContext)
                viewModel.saveUseWholeSongContext(true)
                #expect(viewModel.useWholeSongContext)
            }

            StagedStreamURLProtocol.release(interruption == .streamError ? .fail : .finish)
            #expect(await Self.waitUntil { !viewModel.isLoading }, "\(interruption): loading ends")
            try await Task.sleep(for: .milliseconds(200))

            switch interruption {
            case .none:
                #expect(viewModel.completedSuggestionsRequestID == requestID)
                #expect(viewModel.suggestions.count == 1)
            case .consume:
                #expect(viewModel.completedSuggestionsRequestID == nil)
                #expect(viewModel.errorMessage == nil, "consumed lines are not an empty answer")
            case .stop, .setting:
                #expect(viewModel.completedSuggestionsRequestID == nil, "\(interruption)")
                #expect(viewModel.suggestions.count == 1, "\(interruption): the line already shown stays")
            case .streamError:
                #expect(viewModel.completedSuggestionsRequestID == nil)
                #expect(viewModel.errorMessage != nil)
                #expect(viewModel.suggestions.count == 1)
            }
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeDefaults() -> (UserDefaults, String) {
        let name = "rhymeai.cloud-privacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        // These flows exercise the selected-context scope; Whole Song Context
        // defaults on, so start each one from an explicit off.
        defaults.set(false, forKey: "editor.useWholeSongContext")
        return (defaults, name)
    }

    private static func waitUntil(
        timeoutIterations: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<timeoutIterations {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private final class PrivacyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    private static let defaultSuggestionText = "One clear line\nTwo clear lines\nThree clear lines\nFour clear lines\nFive clear lines\nSix clear lines"
    nonisolated(unsafe) private static var bodies: [String] = []
    nonisolated(unsafe) private static var responseDelay: TimeInterval = 0
    nonisolated(unsafe) private static var heldResponse: DispatchSemaphore?
    nonisolated(unsafe) private static var configuredSuggestionText = defaultSuggestionText

    nonisolated static func reset(
        delay: TimeInterval = 0,
        suggestionText: String = defaultSuggestionText,
        holdResponse: Bool = false
    ) {
        stateLock.withLock {
            bodies = []
            responseDelay = delay
            configuredSuggestionText = suggestionText
            heldResponse = holdResponse ? DispatchSemaphore(value: 0) : nil
        }
    }

    nonisolated static func releaseHeldResponse() {
        let gate = stateLock.withLock { () -> DispatchSemaphore? in
            let gate = heldResponse
            heldResponse = nil
            return gate
        }
        gate?.signal()
    }

    nonisolated static func capturedBodies() -> [String] {
        stateLock.withLock { bodies }
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        let body = String(decoding: Self.bodyData(for: request), as: UTF8.self)
        let (delay, gate) = Self.stateLock.withLock { () -> (TimeInterval, DispatchSemaphore?) in
            Self.bodies.append(body)
            return (Self.responseDelay, Self.heldResponse)
        }
        gate?.wait()
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": Self.isStreaming(request) ? "text/event-stream" : "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData(for: request, body: body))
        client?.urlProtocolDidFinishLoading(self)
    }

    nonisolated override func stopLoading() {}

    nonisolated private static func isStreaming(_ request: URLRequest) -> Bool {
        if request.url?.absoluteString.contains("streamGenerateContent") == true {
            return true
        }
        return request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
    }

    nonisolated private static func responseData(for request: URLRequest, body: String) -> Data {
        let suggestionText = stateLock.withLock { configuredSuggestionText }
        let provider: AIProvider
        switch request.url?.host {
        case "api.openai.com": provider = .openai
        case "api.anthropic.com": provider = .claude
        default: provider = .gemini
        }

        if isStreaming(request) {
            let payload: [String: Any]
            switch provider {
            case .gemini:
                payload = ["candidates": [["content": ["parts": [["text": suggestionText]]]]]]
            case .openai:
                payload = ["choices": [["delta": ["content": suggestionText]]]]
            case .claude:
                payload = ["type": "content_block_delta", "delta": ["text": suggestionText]]
            case .local:
                payload = [:]
            }
            let json = try! JSONSerialization.data(withJSONObject: payload)
            return Data("data: \(String(decoding: json, as: UTF8.self))\n\ndata: [DONE]\n\n".utf8)
        }

        let text = bodyRequestsJSON(body)
            ? #"{"rewrite":"replacement"}"#
            : suggestionText
        let payload: [String: Any]
        switch provider {
        case .gemini:
            payload = ["candidates": [["content": ["parts": [["text": text]]]]]]
        case .openai:
            payload = ["choices": [["message": ["content": text]]]]
        case .claude:
            payload = ["content": [["text": text]]]
        case .local:
            payload = [:]
        }
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    nonisolated private static func bodyRequestsJSON(_ body: String) -> Bool {
        body.contains("responseMimeType") || body.contains("response_format") || body.contains(#"\"rewrite\""#)
    }

    nonisolated private static func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

}

/// Streams one Gemini SSE line, then holds the response open until the test
/// releases it to finish normally or fail mid-stream.
private final class StagedStreamURLProtocol: URLProtocol, @unchecked Sendable {
    enum Ending { case finish, fail }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gate = DispatchSemaphore(value: 0)
    nonisolated(unsafe) private static var ending = Ending.finish
    nonisolated(unsafe) private static var line = ""

    nonisolated static func reset(firstLine: String) {
        lock.withLock {
            gate = DispatchSemaphore(value: 0)
            ending = .finish
            line = firstLine
        }
    }

    nonisolated static func release(_ end: Ending) {
        let gate = lock.withLock { () -> DispatchSemaphore in
            ending = end
            return Self.gate
        }
        gate.signal()
    }

    nonisolated override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    nonisolated override func startLoading() {
        let (gate, line) = Self.lock.withLock { (Self.gate, Self.line) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let payload = ["candidates": [["content": ["parts": [["text": line + "\n"]]]]]]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        client?.urlProtocol(self, didLoad: Data("data: \(json)\n\n".utf8))
        DispatchQueue.global().async { [self] in
            gate.wait()
            gate.signal()
            switch Self.lock.withLock({ Self.ending }) {
            case .finish:
                client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
                client?.urlProtocolDidFinishLoading(self)
            case .fail:
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        }
    }

    nonisolated override func stopLoading() {}
}
