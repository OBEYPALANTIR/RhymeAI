import Foundation
import Testing
@testable import Writers_Block

@MainActor
struct LocalGenerationBoundaryTests {
    @Test func productionRequestUsesEarlierCursorStanza() {
        let viewModel = EditorViewModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        viewModel.saveUseWholeSongContext(false)
        viewModel.rhymeScheme = .abab
        viewModel.rhymeComplexity = .complex
        viewModel.lyrics = "[Verse 1]\nfirst glow\nsecond sky\nthird show\n\n[Chorus]\nlate refrain"
        viewModel.cursorPosition = ("[Verse 1]\nfirst glow\nsecond sky\nthird show" as NSString).length

        let input = viewModel.suggestionInputForTest()
        let prompt = AIService().buildLocalSuggestionPromptForTest(input: input)

        #expect(input.stanzaLines == ["[Verse 1]", "first glow", "second sky", "third show"])
        // The suggestion becomes line 4 of the verse: "B", rhyming with line 2.
        #expect(input.targetRhymeLine == "second sky")
        #expect(input.currentLetter == "B")
        #expect(input.rhymeScheme == "ABAB")
        #expect(input.complexity == .complex)
        #expect(prompt.contains("first glow\nsecond sky\nthird show"))
        #expect(!prompt.contains("late refrain"))
    }

    @Test func productionRequestKeepsEmptyEarlierStanzaEmpty() {
        let viewModel = EditorViewModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        viewModel.saveUseWholeSongContext(false)
        viewModel.lyrics = "[Verse 1]\n\n[Chorus]\nlate refrain"
        viewModel.cursorPosition = ("[Verse 1]\n" as NSString).length

        let input = viewModel.suggestionInputForTest()
        let prompt = AIService().buildLocalSuggestionPromptForTest(input: input)

        #expect(!input.stanzaLines.contains("late refrain"))
        #expect(!prompt.contains("late refrain"))
    }

    @Test func productionRequestPreservesNewSoundControls() {
        let viewModel = EditorViewModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        viewModel.rhymeScheme = .abab
        viewModel.rhymeComplexity = .simple
        // The suggestion becomes line 2 of the verse, which opens the "B" sound.
        viewModel.lyrics = "[Verse 1]\nfirst glow"
        viewModel.cursorPosition = (viewModel.lyrics as NSString).length

        let input = viewModel.suggestionInputForTest()
        let prompt = AIService().buildLocalSuggestionPromptForTest(input: input)

        #expect(input.targetRhymeLine == nil)
        #expect(input.currentLetter == "B")
        #expect(prompt.contains("Rhyme scheme: \"ABAB\"; next line is \"B\"."))
        #expect(prompt.contains("Start a new rhyme sound for letter \"B\"."))
        #expect(prompt.contains("Complexity: Simple."))
    }

    @Test func localStreamEmitsOnlySixDistinctCompleteLines() async throws {
        let chunks = [
            "Neon settles softly on the avenue\nStreetlights hold the secrets that we knew\n",
            "Midnight turns the windows into blue\nFootsteps stitch the silence running through\n",
            "Distant trains keep pulling memory through\nMorning waits beyond the final view"
        ]
        var lines: [String] = []

        for try await line in AIService().validatedLocalSuggestionStreamForTest(
            chunks: chunks,
            lyrics: "An existing lyric"
        ) {
            lines.append(line)
        }

        #expect(lines.count == 6)
        #expect(Set(lines).count == 6)
    }

    @Test func localStreamShowsThreeSurvivorsAfterFilteringAndAnEmptyRetry() async throws {
        let chunks = [
            "An existing lyric\nFresh line one\nFresh line one\nFresh line two\nFresh line three\n"
        ]
        var lines: [String] = []
        var calls = 0

        for try await line in AIService().validatedLocalSuggestionStreamForTest(
            chunks: chunks,
            lyrics: "An existing lyric",
            retryCalls: { calls = $0 }
        ) {
            lines.append(line)
        }

        #expect(lines == ["Fresh line one", "Fresh line two", "Fresh line three"])
        #expect(calls == 2)
    }

    // Resilient local rule (PARITY.md): < 6 survivors retries once and merges; 3-5 are shown;
    // < 3 after the retry is the existing error. Mirrors Android `LocalSuggestionRetryTest`.
    private static let target = "I wait beneath the rain"
    private static let rhymes = [
        "The ropes drip water on the train",
        "A gull cries out above the chain",
        "The boats lean out beyond the pane",
        "Your footsteps leave a fading stain",
        "The tide climbs slowly up the drain",
        "The windows face a narrow lane"
    ]
    private static let misses = [
        "The harbor sleeps beneath the stars",
        "Lanterns flicker on the pier",
        "A seagull circles overhead",
        "The fog rolls in across the bay"
    ]

    private func streamed(_ first: [String], retry: [String]? = nil, retryError: Error? = nil) async throws -> (lines: [String], calls: Int) {
        var lines: [String] = []
        var calls = 0
        for try await line in AIService().validatedLocalSuggestionStreamForTest(
            chunks: [first.joined(separator: "\n") + "\n"],
            retryChunks: retry.map { [$0.joined(separator: "\n") + "\n"] },
            retryError: retryError,
            lyrics: "Existing lyric",
            targetRhymeLine: Self.target,
            retryCalls: { calls = $0 }
        ) {
            lines.append(line)
        }
        return (lines, calls)
    }

    private func batched(_ first: [String], retry: [String]? = nil, retryError: Error? = nil) async throws -> (lines: [String], calls: Int) {
        var attempts = [first, retry ?? []]
        var calls = 0
        let lines = try await AIService().localSuggestionLines(
            generate: {
                calls += 1
                if calls > 1, let retryError { throw retryError }
                return attempts.removeFirst().joined(separator: "\n")
            },
            lyrics: "Existing lyric",
            filter: RhymeLineFilter(targetLine: Self.target, rhymeType: .perfect),
            rhymeType: .perfect
        )
        return (lines, calls)
    }

    @Test func localSixSurvivorsDoNotRetry() async throws {
        for run in [try await streamed(Self.rhymes), try await batched(Self.rhymes)] {
            #expect(run.lines == Self.rhymes)
            #expect(run.calls == 1)
        }
    }

    @Test func localFourSurvivorsRetryAndMergeToSixKeepingFirstAttemptFirst() async throws {
        let first = Array(Self.rhymes.prefix(4)) + Self.misses.prefix(2)
        // Retry repeats two first-attempt lines (deduped) and brings two new rhymes.
        let retry = Array(Self.rhymes.prefix(2)) + Self.misses.prefix(2) + Self.rhymes[4...]
        for run in [try await streamed(first, retry: retry), try await batched(first, retry: retry)] {
            #expect(run.lines == Self.rhymes)
            #expect(run.calls == 2)
        }
    }

    @Test func localFourSurvivorsWithEmptyRetryAreShown() async throws {
        let first = Array(Self.rhymes.prefix(4)) + Self.misses.prefix(2)
        for run in [try await streamed(first, retry: first), try await batched(first, retry: first)] {
            #expect(run.lines == Array(Self.rhymes.prefix(4)))
            #expect(run.calls == 2)
        }
    }

    @Test func localFourSurvivorsWithFailedRetryAreShown() async throws {
        let first = Array(Self.rhymes.prefix(4)) + Self.misses.prefix(2)
        let timeout = URLError(.timedOut)
        for run in [try await streamed(first, retryError: timeout), try await batched(first, retryError: timeout)] {
            #expect(run.lines == Array(Self.rhymes.prefix(4)))
            #expect(run.calls == 2)
        }
    }

    @Test func localTwoSurvivorsWithFailedRetrySurfaceTheRetryError() async {
        let two = Array(Self.rhymes.prefix(2)) + Self.misses
        let timeout = URLError(.timedOut)
        for run in [{ try await self.streamed(two, retryError: timeout) }, { try await self.batched(two, retryError: timeout) }] {
            do {
                _ = try await run()
                Issue.record("Expected the retry's error")
            } catch let error as URLError {
                #expect(error.code == .timedOut)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    private static let overproducedMisses = [
        "Quiet lanterns drift across the bay",
        "Old ropes curl beside the door",
        "The sailors laugh into the night",
        "A bell rings out along the shore",
        "Gray clouds roll over every roof",
        "The nets hang heavy on the pier",
        "My coat still smells of salt and smoke",
        "The lighthouse blinks its steady eye",
        "We count the boats along the dock",
        "The gulls fight over scraps of bread"
    ]

    @Test func localBatchPassCapsAtTwelveCandidatesBeforeRanking() async throws {
        // Rhymes past the 12-candidate budget are not ranked; the retry supplies them.
        let first = Self.misses + Self.overproducedMisses + Self.rhymes
        let run = try await batched(first, retry: Self.rhymes)
        #expect(run.lines == Self.rhymes)
        #expect(run.calls == 2)
    }

    @Test func localRetryGetsItsOwnRawLineBudget() async throws {
        // The first pass spends the whole 12-line budget on two rhymes and ten misses.
        let first = Array(Self.rhymes.prefix(2)) + Self.overproducedMisses
        let run = try await streamed(first, retry: Array(Self.rhymes[2...]))
        #expect(run.lines == Self.rhymes)
        #expect(run.calls == 2)
    }

    @Test func localTwoSurvivorsAfterRetryStillFail() async {
        let two = Array(Self.rhymes.prefix(2)) + Self.misses
        for run in [{ try await self.streamed(two, retry: two) }, { try await self.batched(two, retry: two) }] {
            do {
                _ = try await run()
                Issue.record("Expected incomplete-response error")
            } catch AIServiceError.incompleteResponse(let expected, let actual) {
                #expect(expected == 6)
                #expect(actual == 2)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        for run in [{ try await self.streamed(Self.misses, retry: Self.misses) }, { try await self.batched(Self.misses, retry: Self.misses) }] {
            do {
                _ = try await run()
                Issue.record("Expected no-matching-rhymes error")
            } catch AIServiceError.noMatchingRhymes {
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func localStreamRejectsMarkersBeforeCleanup() async {
        for fragment in ["<|turn>model", "<end_", "<script"] {
            do {
                for try await _ in AIService().validatedLocalSuggestionStreamForTest(
                    chunks: ["Clean first line\n\(fragment)\nAnother line\n"],
                    lyrics: ""
                ) {}
                Issue.record("Expected marker rejection for \(fragment)")
            } catch AIServiceError.decodingError {
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func localStreamRejectsExplanationsAndOverlongWordCounts() async {
        let invalid = [
            "Sure, here are your lyrics",
            "Complexity: Simple. Keep the language clear",
            "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen",
            "[Verse 2]",
            "assistant: A borrowed line",
            "# Verse 2",
            "Moon **shines** above",
            "Moon _shines_ above"
        ]
        for candidate in invalid {
            var displayed: [String] = []
            do {
                for try await line in AIService().validatedLocalSuggestionStreamForTest(
                    chunks: [candidate + "\n"], lyrics: ""
                ) { displayed.append(line) }
                Issue.record("Expected invalid local output to fail")
            } catch {}
            #expect(displayed.isEmpty, "Invalid line reached display: \(candidate)")
        }
    }

    @Test func localSynonymsRejectTruncatedMarkersBeforeCleanup() {
        for fragment in ["<|turn>model", "<end_", "<script"] {
            let accepted = SynonymSanitizer.extract(
                "shine\n\(fragment)",
                excluding: "glow",
                limit: 3,
                validation: .knownWords
            )
            #expect(accepted.isEmpty)
        }
    }

    @Test func lexicalGateRejectsLossyPronunciationSpellings() {
        #expect(!LexicalWordValidator.isKnownSpelling("g-l-e-a-m"))
        #expect(!LexicalWordValidator.isKnownSpelling("a-skew"))
        #expect(LexicalWordValidator.isKnownSpelling("gleam"))
        #expect(LexicalWordValidator.isKnownSpelling("askew"))

        let accepted = SynonymSanitizer.extract(
            "g-l-e-a-m\na-skew\nshine",
            excluding: "glow",
            additionallyExcluding: ["gleam"],
            limit: 3,
            validation: .knownWords
        )
        #expect(accepted == ["shine"])
    }

    @Test func localStreamCapsExcessCountAndRejectsSplitMarkers() async throws {
        var lines: [String] = []
        for try await line in AIService().validatedLocalSuggestionStreamForTest(
            chunks: ["First new line\nSecond new line\nThird new line\nFourth new line\nFifth new line\nSixth new line\nSeventh new line"],
            lyrics: ""
        ) { lines.append(line) }
        #expect(lines.count == 6)
        #expect(!lines.contains("Seventh new line"))

        do {
            for try await _ in AIService().validatedLocalSuggestionStreamForTest(chunks: ["First new line\n<", "script>unsafe\n"], lyrics: "") {}
            Issue.record("Expected malformed response rejection")
        } catch is AIServiceError {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func localRewriteRejectsMalformedCountsMarkersAndFabricatedWords() throws {
        let service = AIService()
        #expect(try service.validatedLocalPassage("New first line\n\nNew last line", selection: "Old first line\n\nOld last line") == "New first line\n\nNew last line")
        #expect(try service.validatedLocalWord("gleam") == "gleam")
        for raw in ["gleam and shine", "zqxvplight", "<end_", "word: gleam"] {
            #expect(throws: AIServiceError.self) { try service.validatedLocalWord(raw) }
        }
        for raw in ["One line", "One\nTwo\nThree", "<script>first\nsecond", "Here are your lines\nsecond", "Old first\nOld last", "Instruction: use clearer language\nSecond line", "Action: Rephrase\nSecond line", "Current song section: Verse.\nSecond line"] {
            #expect(throws: AIServiceError.self) {
                try service.validatedLocalPassage(raw, selection: "Old first\nOld last")
            }
        }
    }

    @Test func localPromptRetainsLongStanzaAndWholeSongPolicy() {
        let service = AIService()
        let stanza = ["FIRST CONTEXT DETAIL", String(repeating: "midnight ", count: 350), "LAST CONTEXT DETAIL"]
        for wholeSong in [false, true] {
            let prompt = service.buildLocalSuggestionPromptForTest(
                theme: "quiet harbor", lyrics: "FULL SONG CONTEXT", stanzaLines: stanza,
                targetRhymeLine: nil, rhymeType: .perfect, rhymeScheme: "ABAB", currentLetter: "B",
                currentSection: .verse, sectionOrdinal: 1, firstChorusLines: nil,
                complexity: .complex, useWholeSongContext: wholeSong
            )
            #expect(prompt.contains("Rhyme scheme: \"ABAB\""))
            #expect(prompt.contains("Complexity: Complex"))
            #expect(prompt.contains(wholeSong ? "FULL SONG CONTEXT" : "FIRST CONTEXT DETAIL"))
            #expect(prompt.contains("Theme: quiet harbor"))
            if !wholeSong { #expect(!prompt.contains("FULL SONG CONTEXT")) }
        }
    }


    @Test func cumulativeLocalSnapshotsPreserveCombiningScalars() throws {
        let previous = "cafe"
        let next = "cafe\u{301}"
        #expect(previous + (try AIService.localSnapshotDelta(previous: previous, current: next)) == next)
        #expect(try AIService.localSnapshotDelta(previous: "🌒", current: "🌒\nDawn") == "\nDawn")
        #expect(throws: AIServiceError.self) {
            try AIService.localSnapshotDelta(previous: "old", current: "new")
        }
    }


    @Test func localListBulletsNeverReachSuggestionsOrRewritePreview() async {
        for bullet in ["•", "●", "‣", "◦", "⁃", "∙", "·", "▪", "▫", "⁌", "⁍", "○", "‒", "–", "—", "-", "*", "+", "1.", "2)", "3:", "a)"] {
            let line = "\(bullet) Moonlight settles on the shore"
            var displayed: [String] = []
            do {
                for try await candidate in AIService().validatedLocalSuggestionStreamForTest(chunks: [line + "\n"], lyrics: "") {
                    displayed.append(candidate)
                }
            } catch {}
            #expect(displayed.isEmpty)
            #expect(throws: AIServiceError.self) {
                try AIService().validatedLocalPassage(line, selection: "The moon above")
            }
        }
    }

    @Test func localMarkdownAndQuoteWrappersNeverReachPreview() async throws {
        let service = AIService()
        for line in ["~~Moonlight~~ settles on the shore", "~~~text", "| Moonlight | settles |", "---", "===", "~~~", "“Moonlight settles on the shore”", "‘Moonlight settles on the shore’", "«Moonlight settles on the shore»"] {
            var displayed: [String] = []
            do {
                for try await candidate in service.validatedLocalSuggestionStreamForTest(chunks: [line + "\n"], lyrics: "") {
                    displayed.append(candidate)
                }
            } catch {}
            #expect(displayed.isEmpty)
            #expect(throws: AIServiceError.self) {
                try service.validatedLocalPassage(line, selection: "The moon above")
            }
        }
        for line in ["2 + 2 makes four", "Moonlight—settles on the shore", "I’m waiting by the shore"] {
            #expect(try service.validatedLocalPassage(line, selection: "The moon above") == line)
        }
    }

}
