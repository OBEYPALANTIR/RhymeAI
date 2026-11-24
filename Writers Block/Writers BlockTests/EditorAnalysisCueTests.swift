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
        // Each debounce reports the edit it was started for, and only while it is
        // still that edit's (a cancelled one never reports), then holds.
        let editUnderTest = HookBox("")
        let (debounceEntries, debounceEntered) = AsyncStream.makeStream(of: String.self)
        viewModel.derivedStateDebounce = { _ in
            try Task.checkCancellation()
            debounceEntered.yield(editUnderTest.value)
            try await Task.sleep(for: .seconds(3_600))
        }
        // An instant stand-in counter (characters for syllables), held at its edit's
        // own gate until the test opens it, so the header can be read while the count
        // is outstanding. A hold that times out instead is recorded and fails the edit.
        let count: @Sendable (String) -> (words: Int, syllables: Int) = { text in
            (SyllableCounter.lyricWordCount(text), text.utf16.count)
        }
        let (countStarts, countStarted) = AsyncStream.makeStream(of: String.self)
        let gates = HookBox<[String: (semaphore: DispatchSemaphore, deadline: DispatchTime)]>([:])
        let expiredHolds = HookBox<Set<String>>([])
        viewModel.countLyrics = { text in
            countStarted.yield(text)
            // The timeout only keeps a failed test from pinning a pool thread for good.
            if let gate = gates.value[text], gate.semaphore.wait(timeout: gate.deadline) == .timedOut {
                expiredHolds.value.insert(text) // one worker at a time: edits are serial
            }
            return count(text)
        }
        var beforeCounting: [(words: Int, syllables: Int)] = []
        var whileCounting: [(words: Int, syllables: Int)] = []
        // The gate and all observations share one hang guard for this edit.
        func edit(to text: String) async throws {
            editUnderTest.value = text
            let gate = DispatchSemaphore(value: 0)
            let perEditTimeoutSeconds = 600
            let deadline = DispatchTime.now() + .seconds(perEditTimeoutSeconds)
            gates.value[text] = (gate, deadline)
            viewModel.onLyricsChanged(text, timestampMilliseconds: 0)
            let countTask = try #require(viewModel.countTask)
            // On any early exit, cancel the count first so a late result is discarded,
            // then release its worker.
            var gateOpened = false
            defer {
                if !gateOpened {
                    countTask.cancel()
                    gate.signal()
                }
            }
            beforeCounting.append((viewModel.wordCount, viewModel.syllableCount))

            let started = await observed(until: deadline, onGiveUp: { countTask.cancel() }) {
                for await started in countStarts where started == text { return true }
                return false
            }
            try #require(started, "the count for \"\(text)\" never started")
            whileCounting.append((viewModel.wordCount, viewModel.syllableCount))
            let held = await observed(until: deadline) {
                for await entered in debounceEntries where entered == text { return true }
                return false
            }
            try #require(held, "the rhyme context's debounce never held for \"\(text)\"")
            gateOpened = true
            gate.signal()

            let landed = await observed(until: deadline, onGiveUp: { countTask.cancel() }) {
                await countTask.value
                return true
            }
            try #require(landed, "the count for \"\(text)\" did not finish within \(perEditTimeoutSeconds) s")
            try #require(
                !expiredHolds.value.contains(text),
                "the count for \"\(text)\" was never held: its gate timed out before the test opened it"
            )
            try #require(viewModel.lyrics == text)
            try #require(
                (viewModel.wordCount, viewModel.syllableCount) == count(text),
                "header counts after \"\(text)\""
            )
        }

        try await edit(to: "yellow music")
        beforeCounting = []
        whileCounting = []
        for text in ["yellow musi", "yellow mus", "yellow mu", "yellow m", "yellow"] {
            try await edit(to: text)
        }

        #expect(beforeCounting.count == 5 && whileCounting.count == 5)
        #expect(beforeCounting.allSatisfy { $0.words > 0 && $0.syllables > 0 }, "empty right after an edit")
        #expect(whileCounting.allSatisfy { $0.words > 0 && $0.syllables > 0 }, "empty while counting")
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

/// True only if `observe` reports its event before the deadline and the caller is
/// still running. On a miss `onGiveUp` runs and `observe` is cancelled and abandoned,
/// not awaited (a task group or timeout race would still await it at scope exit).
/// The deadline is fixed up front, but a starved scheduler can deliver it late.
private func observed(
    until deadline: DispatchTime,
    onGiveUp: @escaping @Sendable () -> Void = {},
    _ observe: @escaping @Sendable () async -> Bool
) async -> Bool {
    let (outcomes, outcome) = AsyncStream.makeStream(of: Bool.self)
    // Judged when the observation completes, so a late one fails even if delivered first.
    let work = Task { outcome.yield(await observe() && DispatchTime.now() < deadline) }
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.setEventHandler { outcome.yield(false) }
    timer.schedule(deadline: deadline)
    timer.activate()
    defer { work.cancel(); timer.cancel(); outcome.finish() }
    var outcomeIterator = outcomes.makeAsyncIterator()
    let saw = await outcomeIterator.next() ?? false
    guard saw, !Task.isCancelled else {
        onGiveUp()
        return false
    }
    return true
}

