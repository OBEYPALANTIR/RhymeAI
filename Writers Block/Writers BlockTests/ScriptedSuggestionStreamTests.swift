import Foundation
import Testing
@testable import Writers_Block

/// The scripted suggestion stream behind `--ui-test-scripted-suggestions`: UI
/// tests and simulator QA rely on it delivering the same lines, in order, every
/// time, and only in a launch isolated from the simulator's own songs and settings.
@MainActor
struct ScriptedSuggestionStreamTests {
    private func collect(_ environment: [String: String]) async throws -> [String] {
        var lines: [String] = []
        for try await line in UITestFlags.scriptedSuggestionStream(environment: environment) {
            lines.append(line)
        }
        return lines
    }

    @Test
    func deliversTheRequestedLinesInOrder() async throws {
        let lines = try await collect([
            "RHYMEAI_UITEST_SUGGESTION_HOLD": "0",
            "RHYMEAI_UITEST_SUGGESTION_INTERVAL": "0",
            "RHYMEAI_UITEST_SUGGESTION_COUNT": "4",
        ])
        #expect(lines == Array(UITestFlags.scriptedSuggestionLines.prefix(4)))
    }

    @Test
    func zeroLinesExercisesTheEmptyAnswer() async throws {
        let lines = try await collect([
            "RHYMEAI_UITEST_SUGGESTION_HOLD": "0",
            "RHYMEAI_UITEST_SUGGESTION_COUNT": "0",
        ])
        #expect(lines.isEmpty)
    }

    @Test
    func countIsClampedToTheScriptedLines() async throws {
        let all = try await collect([
            "RHYMEAI_UITEST_SUGGESTION_HOLD": "0",
            "RHYMEAI_UITEST_SUGGESTION_INTERVAL": "0",
            "RHYMEAI_UITEST_SUGGESTION_COUNT": "99",
        ])
        #expect(all == UITestFlags.scriptedSuggestionLines)

        let none = try await collect([
            "RHYMEAI_UITEST_SUGGESTION_HOLD": "0",
            "RHYMEAI_UITEST_SUGGESTION_COUNT": "-2",
        ])
        #expect(none.isEmpty)
    }

    @Test
    func theFourthLineRunsLongEnoughToWrap() {
        #expect(UITestFlags.scriptedSuggestionLines.count == 6)
        #expect(UITestFlags.scriptedSuggestionLines[3].count > 60)
    }

    @Test
    func theStreamOnlyAnswersInAnIsolatedLaunch() {
        #expect(UITestFlags.scriptedSuggestionsEnabled(in: [UITestFlags.inMemoryStore, UITestFlags.scriptedSuggestions]))
        #expect(!UITestFlags.scriptedSuggestionsEnabled(in: [UITestFlags.scriptedSuggestions]))
        #expect(!UITestFlags.scriptedSuggestionsEnabled(in: [UITestFlags.inMemoryStore]))
    }

    @Test
    func anInMemoryLaunchKeepsEditorSettingsOutOfStandardDefaults() {
        #expect(UITestFlags.editorDefaults(arguments: []) === UserDefaults.standard)

        let isolated = UITestFlags.editorDefaults(arguments: [UITestFlags.inMemoryStore])
        #expect(isolated !== UserDefaults.standard)
        let key = "uiTestIsolation.\(UUID().uuidString)"
        isolated.set("LOCAL", forKey: key)
        defer { isolated.removeObject(forKey: key) }
        #expect(isolated.string(forKey: key) == "LOCAL")
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }
}
