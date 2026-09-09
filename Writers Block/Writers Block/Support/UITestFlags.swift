import Foundation

enum UITestFlags {
    static let inMemoryStore = "--ui-test-in-memory-store"
    static let seedProsodySong = "--ui-test-seed-prosody-song"
    static let seedLongTitleSong = "--ui-test-seed-long-title-song"
    static let enableStressPreview = "--ui-test-enable-stress-preview"
    static let openAssistant = "--ui-test-open-assistant"
    static let seedRewriteSelection = "--ui-test-seed-rewrite-selection"
    static let seedRewriteLoading = "--ui-test-seed-rewrite-loading"
    static let seedTrashSong = "--ui-test-seed-trash-song"
    static let forceRewriteBar = "--ui-test-force-rewrite-bar"
    static let accessibilityTextSize = "--ui-test-accessibility-text-size"
    static let seedCustomGGUFModel = "--ui-test-seed-custom-gguf-model"

    #if DEBUG
    static func isEnabled(_ flag: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(flag)
    }

    static func seedCustomGGUFModelIfRequested() {
        guard isEnabled(seedCustomGGUFModel),
              let directory = try? GGUFModelCatalog.modelsDirectory(create: true) else { return }
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

    static func seedCustomGGUFModelIfRequested() {}
    #endif
}
