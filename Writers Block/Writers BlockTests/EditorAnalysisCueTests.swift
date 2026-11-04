import Foundation
import Testing
@testable import Writers_Block

struct EditorAnalysisCueTests {
    @Test func compactEditorStatsFormatsZeroAndMultiDigitCounts() {
        #expect(compactEditorStatsText(wordCount: 0, syllableCount: 0) == "0w · 0s")
        #expect(compactEditorStatsText(wordCount: 42, syllableCount: 108) == "42w · 108s")
    }

    /// Each deletion updates the header's counts with no debounce, and the
    /// previous counts stay until the new ones are ready: never zero in between.
    @Test @MainActor func headerCountsFollowEachDeletionWithoutAnEmptyState() async throws {
        // An instant stand-in counter (characters for syllables), so only
        // scheduling separates the edit from its counts.
        let viewModel = EditorViewModel()
        viewModel.newProject()
        let count: @Sendable (String) -> (words: Int, syllables: Int) = { text in
            (SyllableCounter.lyricWordCount(text), text.utf16.count)
        }
        viewModel.countLyrics = count
        var seen: [(words: Int, syllables: Int)] = []
        var latencies: [Duration] = []
        func settle(on text: String) async throws {
            let expected = count(text)
            let start = ContinuousClock.now
            while (viewModel.wordCount, viewModel.syllableCount) != expected, ContinuousClock.now < start + .seconds(30) {
                seen.append((viewModel.wordCount, viewModel.syllableCount))
                try await Task.sleep(for: .milliseconds(1))
            }
            latencies.append(ContinuousClock.now - start)
            #expect((viewModel.wordCount, viewModel.syllableCount) == expected)
        }
        var text = "yellow music follow music mellow music"
        viewModel.onLyricsChanged(text, timestampMilliseconds: 0)
        try await settle(on: text)
        seen = []
        latencies = []

        // Delete one character at a time. Other suites can starve the
        // executors for seconds, so stop at the first edit counted quickly.
        while text.count > 1, latencies.allSatisfy({ $0 >= .milliseconds(110) }) {
            text.removeLast()
            viewModel.onLyricsChanged(text, timestampMilliseconds: 0)
            try await settle(on: text)
        }

        #expect(seen.allSatisfy { $0.words > 0 && $0.syllables > 0 })
        // The old refresh slept 120ms before counting, a floor no edit could beat.
        #expect(latencies.min()! < .milliseconds(110), "\(latencies)")
    }

    /// A slow count for an older text that finishes after a newer one is
    /// cancelled and dropped; the header ends on the newest text's counts.
    @Test @MainActor func aSlowCountForAnOlderTextNeverOverwritesANewerOne() async throws {
        let viewModel = EditorViewModel()
        viewModel.newProject()
        let cancelledSlowCount = UncheckedBox(false)
        viewModel.countLyrics = { text in
            if text == "slow long line" {
                for _ in 0..<50 {
                    if Task.isCancelled {
                        cancelledSlowCount.value = true
                        return nil
                    }
                    Thread.sleep(forTimeInterval: 0.004)
                }
                return (100, 100)
            }
            return (SyllableCounter.lyricWordCount(text), SyllableCounter.lyricSyllableCount(text))
        }

        viewModel.onLyricsChanged("slow long line", timestampMilliseconds: 0)
        viewModel.onLyricsChanged("quick", timestampMilliseconds: 0)
        var seen: [Int] = []
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            seen.append(viewModel.wordCount)
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(viewModel.wordCount == 1)
        #expect(!seen.contains(100))
        #expect(cancelledSlowCount.value)
    }

    @Test func rhymeFamiliesAreColouredAndSyllablesUnderlinedOnlyAlongsideThem() async {
        let text = "light night"
        let rhymeOnly = await LyricsHighlighting.spans(
            text: text, rhymeEnabled: true, syllablesEnabled: false, isDark: false
        )
        let both = await LyricsHighlighting.spans(
            text: text, rhymeEnabled: true, syllablesEnabled: true, isDark: false
        )
        let syllablesOnly = await LyricsHighlighting.spans(
            text: text, rhymeEnabled: false, syllablesEnabled: true, isDark: false
        )
        #expect(rhymeOnly.count == 2)
        #expect(rhymeOnly.allSatisfy { $0.foreground != nil && $0.underline == nil })
        #expect(rhymeOnly[0].foreground == rhymeOnly[1].foreground)
        #expect(both.map(\.foreground) == rhymeOnly.map(\.foreground))
        #expect(both.allSatisfy { $0.underline != nil })
        #expect(syllablesOnly.allSatisfy { $0.foreground != nil && $0.underline == nil })
    }

    @Test func rhymeFamilyHelpDescribesColour() {
        #expect(FeatureHelp.colorRhymes.title == "Rhyme Families")
        #expect(
            FeatureHelp.colorRhymes.message
                == "Colors identify words that share a rhyme sound. Matching colors belong to the same rhyme family."
        )
    }

    @Test func aStoredInkMarksChoiceIsDroppedAtLaunch() throws {
        // Given defaults written by a build that still had the Ink Marks style
        let suiteName = "EditorAnalysisCueTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("inkMarks", forKey: "analysisPresentationStyle")
        defaults.set(true, forKey: "editor.isRhymeHighlightEnabled")

        // When
        RetiredPreferences.remove(from: defaults)

        // Then the retired choice is gone and unrelated settings are kept
        #expect(defaults.object(forKey: "analysisPresentationStyle") == nil)
        #expect(defaults.bool(forKey: "editor.isRhymeHighlightEnabled"))
        RetiredPreferences.remove(from: defaults)
        #expect(defaults.object(forKey: "analysisPresentationStyle") == nil)
    }
}

/// A flag the counter closure flips from its detached task.
private final class UncheckedBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
