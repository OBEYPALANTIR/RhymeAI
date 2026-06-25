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

    static func isEnabled(_ flag: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(flag)
    }
}
