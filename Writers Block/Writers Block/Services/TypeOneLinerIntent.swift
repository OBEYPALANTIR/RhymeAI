import AppIntents
import SwiftData

enum OneLinerIntentError: LocalizedError {
    case libraryUnavailable

    var errorDescription: String? {
        switch self {
        case .libraryUnavailable: "Writers Block couldn't open your library, so the line wasn't saved. Open the app and try again."
        }
    }
}

/// Saves a line without opening the app, so Siri can take it by dictation alone.
struct TypeOneLinerIntent: AppIntent {
    static let title: LocalizedStringResource = "Type One Liner"
    static let description = IntentDescription("Saves a line to One Liners without opening Writers Block.")

    /// The app's own container; tests swap in an in-memory one.
    static var container: () -> ModelContainer? = {
        let bootstrap = ModelContainerBootstrap.shared
        // A library that failed to open falls back to memory, where the line would be lost.
        return bootstrap.persistenceDegraded ? nil : bootstrap.container
    }

    @Parameter(title: "Line", requestValueDialog: "What's the line?")
    var text: String

    init() {}

    init(text: String) {
        self.text = text
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { throw $text.needsValueError("What's the line?") }
        guard let container = Self.container() else { throw OneLinerIntentError.libraryUnavailable }
        try OneLinersStore(context: ModelContext(container)).add(text: line)
        return .result(dialog: "Saved to One Liners")
    }
}

struct WritersBlockShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TypeOneLinerIntent(),
            phrases: [
                "Add a one liner to \(.applicationName)",
                "Type a one liner in \(.applicationName)",
            ],
            shortTitle: "Type One Liner",
            systemImageName: "keyboard"
        )
        AppShortcut(
            intent: RecordOneLinerIntent(),
            phrases: [
                "Record a one liner in \(.applicationName)",
                "Record a one liner with \(.applicationName)",
            ],
            shortTitle: "Record One Liner",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: OpenOneLinersIntent(),
            phrases: [
                "Open one liners in \(.applicationName)",
                "Show my one liners in \(.applicationName)",
            ],
            shortTitle: "One Liners",
            systemImageName: "text.quote"
        )
    }
}
