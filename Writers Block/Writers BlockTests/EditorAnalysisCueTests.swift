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
        let (debounceEntries, debounceEntered) = AsyncStream.makeStream(of: Void.self)
        viewModel.derivedStateDebounce = { _ in
            debounceEntered.yield()
            try await Task.sleep(for: .seconds(3_600))
        }
        // An instant stand-in counter (characters for syllables).
        let count: @Sendable (String) -> (words: Int, syllables: Int) = { text in
            (SyllableCounter.lyricWordCount(text), text.utf16.count)
        }
        viewModel.countLyrics = count
        var seen: [(words: Int, syllables: Int)] = []
        // Waits on this edit's own count, not the clock. The bound is a hang guard far
        // above CI stalls seen so far (up to ~40 s) and far below the 3,600 s debounce.
        func edit(to text: String) async throws {
            viewModel.onLyricsChanged(text, timestampMilliseconds: 0)
            let countTask = try #require(viewModel.countTask)
            // Until this edit's count lands, the header still shows the previous text's.
            seen.append((viewModel.wordCount, viewModel.syllableCount))
            let landed = await finishes(within: .seconds(120)) { await countTask.value }
            try #require(landed, "the count for \"\(text)\" did not finish within 120 s")
            #expect(viewModel.lyrics == text)
            #expect((viewModel.wordCount, viewModel.syllableCount) == count(text))
        }

        try await edit(to: "yellow music")
        seen = []
        for text in ["yellow musi", "yellow mus", "yellow mu", "yellow m", "yellow"] {
            try await edit(to: text)
        }

        #expect(seen.count == 5)
        #expect(seen.allSatisfy { $0.words > 0 && $0.syllables > 0 })
        // The debounce was in force throughout, and the counts never waited on it.
        let debounceHeld = await finishes(within: .seconds(120)) {
            for await _ in debounceEntries { return }
        }
        #expect(debounceHeld, "the rhyme context's debounce never started")
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

/// True once `operation` returns, false after `limit` or if the caller is cancelled.
/// Never waits past `limit`: an operation that ignores cancellation is abandoned,
/// not awaited, which a task group or timeout race would still do at scope exit.
private func finishes(
    within limit: Duration,
    _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    let (results, result) = AsyncStream.makeStream(of: Bool.self)
    let work = Task { await operation(); result.yield(true) }
    let timer = Task { try? await Task.sleep(for: limit); result.yield(false) }
    defer { work.cancel(); timer.cancel(); result.finish() }
    for await finished in results { return finished }
    return false
}

