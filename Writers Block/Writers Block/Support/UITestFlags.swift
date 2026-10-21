import Foundation

enum UITestFlags {
    static let inMemoryStore = "--ui-test-in-memory-store"
    static let seedProsodySong = "--ui-test-seed-prosody-song"
    static let enableStressPreview = "--ui-test-enable-stress-preview"
    static let openAssistant = "--ui-test-open-assistant"
    static let seedRewriteSelection = "--ui-test-seed-rewrite-selection"
    static let seedRewriteLoading = "--ui-test-seed-rewrite-loading"
    static let seedTrashSong = "--ui-test-seed-trash-song"
    static let forceRewriteBar = "--ui-test-force-rewrite-bar"
    static let fakeVoiceRecording = "--ui-test-fake-voice-recording"
    static let seedSuggestions = "--ui-test-seed-suggestions"
    static let forceSaveFailed = "--ui-test-force-save-failed"
    static let seedLongTitleSong = "--ui-test-seed-long-title-song"
    static let accessibilityTextSize = "--ui-test-accessibility-text-size"
    static let seedCustomGGUFModel = "--ui-test-seed-custom-gguf-model"
    /// Suggest Next Line answers from `scriptedSuggestionStream` instead of a
    /// provider, on the on-device route, so the Assistant's real loading and
    /// arrival states can be held and replayed with no key, request or model.
    /// It only takes effect alongside `inMemoryStore`.
    static let scriptedSuggestions = "--ui-test-scripted-suggestions"

    #if DEBUG
    static func isEnabled(_ flag: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(flag)
    }

    /// Suite that holds the editor's settings during an in-memory UI-test launch.
    static let isolatedEditorDefaultsSuite = "RhymeAI.UITest.EditorDefaults"

    /// Where the editor keeps its settings. An in-memory UI-test launch keeps
    /// the editor's provider, model, sharing-consent and editor-toggle
    /// settings (and its legacy API-key migration) in a suite of its own, so a
    /// test run does not read or rewrite those in the standard domain. The rest
    /// of launch is not isolated: retired-preference cleanup, appearance, model
    /// downloads and backup still use the standard domain and system keychain,
    /// so run UI tests under a separate bundle ID or on a disposable simulator.
    static func editorDefaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard isEnabled(inMemoryStore, in: arguments) else { return .standard }
        return UserDefaults(suiteName: isolatedEditorDefaultsSuite) ?? .standard
    }

    /// The scripted stream answers only in an isolated launch, with the
    /// in-memory store and the editor's own defaults suite.
    static func scriptedSuggestionsEnabled(in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        isEnabled(scriptedSuggestions, in: arguments) && isEnabled(inMemoryStore, in: arguments)
    }

    /// Lines the scripted stream delivers, of mixed length; the fourth runs
    /// long enough to wrap, so a card landing on two lines is covered.
    static let scriptedSuggestionLines = [
        "A quiet light carries me home",
        "The porch still hums the songs we used to know",
        "I count the streetlights back to you",
        "Every window on this road has learned the shape of your name and keeps it lit past midnight",
        "So the quiet doesn't feel the same",
        "And the radio plays on",
    ]

    /// A deterministic stand-in for the suggestion stream: it holds the request
    /// in its loading state, then yields lines on a fixed schedule. Timing comes
    /// from the launch environment: `RHYMEAI_UITEST_SUGGESTION_HOLD` (seconds
    /// before the first line, default 3), `RHYMEAI_UITEST_SUGGESTION_INTERVAL`
    /// (seconds between lines, default 1) and `RHYMEAI_UITEST_SUGGESTION_COUNT`
    /// (0 to 6 lines, default 5; 0 exercises the empty-answer path).
    static func scriptedSuggestionStream(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AsyncThrowingStream<String, Error> {
        let hold = max(0, Double(environment["RHYMEAI_UITEST_SUGGESTION_HOLD"] ?? "") ?? 3)
        let interval = max(0, Double(environment["RHYMEAI_UITEST_SUGGESTION_INTERVAL"] ?? "") ?? 1)
        let requested = Int(environment["RHYMEAI_UITEST_SUGGESTION_COUNT"] ?? "") ?? 5
        let lines = Array(scriptedSuggestionLines.prefix(min(max(0, requested), scriptedSuggestionLines.count)))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .seconds(hold))
                    for (index, line) in lines.enumerated() {
                        if index > 0 { try await Task.sleep(for: .seconds(interval)) }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func seedCustomGGUFModelIfRequested() {
        guard isEnabled(seedCustomGGUFModel),
              let directory = try? GGUFModelStorage.modelsDirectory(create: true) else { return }
        let model = GGUFCustomModel(
            id: "ui-test-custom-model",
            displayName: "Night Drive QA",
            fileName: "ui-test-custom-model.gguf"
        )
        let modelURL = directory.appendingPathComponent(model.fileName)
        let header = Data([
            0x47, 0x47, 0x55, 0x46,
            0x03, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        try? header.write(to: modelURL, options: .atomic)
        GGUFCustomModelRegistry.register(model)
    }
    #else
    static func isEnabled(_ flag: String, in arguments: [String] = []) -> Bool {
        false
    }

    static func editorDefaults() -> UserDefaults {
        .standard
    }

    static func scriptedSuggestionsEnabled() -> Bool {
        false
    }

    static func seedCustomGGUFModelIfRequested() {}
    #endif
}
