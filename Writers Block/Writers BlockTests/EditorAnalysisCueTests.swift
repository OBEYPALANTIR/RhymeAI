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
    /// The rhyme context's debounce is held shut for the whole test, so counts
    /// that waited on it (as they did behind its 120ms sleep) would never land.
    @Test @MainActor func headerCountsFollowEachDeletionWithoutAnEmptyState() async throws {
        let viewModel = EditorViewModel()
        viewModel.newProject()
        let debounceWaits = HookBox(0)
        viewModel.derivedStateDebounce = { _ in
            debounceWaits.value += 1
            try await Task.sleep(for: .seconds(3_600))
        }
        // An instant stand-in counter (characters for syllables).
        let count: @Sendable (String) -> (words: Int, syllables: Int) = { text in
            (SyllableCounter.lyricWordCount(text), text.utf16.count)
        }
        viewModel.countLyrics = count
        var seen: [(words: Int, syllables: Int)] = []
        // A sanity bound only: a loaded machine can be slow, never stuck.
        func settle(on text: String) async throws {
            let expected = count(text)
            let deadline = ContinuousClock.now + .seconds(30)
            while (viewModel.wordCount, viewModel.syllableCount) != expected, ContinuousClock.now < deadline {
                seen.append((viewModel.wordCount, viewModel.syllableCount))
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect((viewModel.wordCount, viewModel.syllableCount) == expected)
        }

        viewModel.onLyricsChanged("yellow music", timestampMilliseconds: 0)
        try await settle(on: "yellow music")
        seen = []
        for text in ["yellow musi", "yellow mus", "yellow mu", "yellow m", "yellow"] {
            viewModel.onLyricsChanged(text, timestampMilliseconds: 0)
            try await settle(on: text)
        }

        #expect(seen.allSatisfy { $0.words > 0 && $0.syllables > 0 })
        // The debounce was in force throughout, and the counts never waited on it.
        #expect(debounceWaits.value > 0)
    }

    /// A slow count for an older text that finishes after the newer text's
    /// counts are on screen is dropped, and its work was told to stop.
    @Test @MainActor func aSlowCountForAnOlderTextNeverOverwritesANewerOne() async throws {
        let viewModel = EditorViewModel()
        viewModel.newProject()
        let slowStarted = DispatchSemaphore(value: 0)
        let releaseSlow = DispatchSemaphore(value: 0)
        let slowSawCancellation = HookBox(false)
        viewModel.countLyrics = { text in
            guard text == "slow long line" else {
                return (SyllableCounter.lyricWordCount(text), text.utf16.count)
            }
            slowStarted.signal()
            releaseSlow.wait()
            slowSawCancellation.value = Task.isCancelled
            // Answers anyway, so only the view model can keep it off the header.
            return (100, 100)
        }
        func wait(_ semaphore: DispatchSemaphore) async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    semaphore.wait()
                    continuation.resume()
                }
            }
        }

        // Given the older text's count running
        viewModel.onLyricsChanged("slow long line", timestampMilliseconds: 0)
        let slowTask = try #require(viewModel.countTask)
        await wait(slowStarted)

        // When a newer text is counted and published first
        viewModel.onLyricsChanged("quick", timestampMilliseconds: 0)
        let quickTask = try #require(viewModel.countTask)
        await quickTask.value
        #expect(viewModel.wordCount == 1)

        // And the older count then finishes
        releaseSlow.signal()
        await slowTask.value

        // Then the header still shows the newer text's counts
        #expect(viewModel.wordCount == 1)
        #expect(viewModel.syllableCount == 5)
        #expect(slowSawCancellation.value)
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

