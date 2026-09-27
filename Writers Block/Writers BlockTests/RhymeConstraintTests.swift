import Foundation
import Testing
@testable import Writers_Block

/// Coverage for rhyme-word-first constrained generation: candidate ending
/// words, tier verification, and the over-generate-and-filter ranking.
/// These run against the bundled pronunciation dictionary because the rhyme
/// index caps its lists in hash order — assertions check phonetics and
/// ordering invariants, never specific capped-list members.
struct RhymeConstraintTests {

    /// A dictionary candidate that survives lineEndWord extraction unchanged.
    /// The dictionary holds a few words with hyphens or trailing apostrophes
    /// that can't round-trip from generated text, so tests skip those.
    private func roundTripSafeCandidate(for targetWord: String, rhymeType: RhymeType) -> String? {
        RhymeConstraint.candidateEndWords(targetWord: targetWord, rhymeType: rhymeType, limit: 60)
            .first { ProsodyAnalyzer.normalizeWord($0) == $0 }
    }

    @Test func lineEndWordStripsPunctuationAndQuotes() {
        #expect(RhymeConstraint.lineEndWord("alive through rain!") == "rain")
        #expect(RhymeConstraint.lineEndWord("she whispered \"goodbye\"") == "goodbye")
        #expect(RhymeConstraint.lineEndWord("hold the line—") == "line")
        #expect(RhymeConstraint.lineEndWord("ECHOES IN THE HALL...") == "hall")
        // Trailing punctuation-only tokens are skipped, not returned as empty words.
        #expect(RhymeConstraint.lineEndWord("carry me home —") == "home")
        #expect(RhymeConstraint.lineEndWord("— !!") == "")
        #expect(RhymeConstraint.lineEndWord("") == "")
    }

    @Test func candidateEndWordsOfferPerfectRhymesFromTheDictionary() {
        let candidates = RhymeConstraint.candidateEndWords(targetWord: "night", rhymeType: .perfect)

        #expect(!candidates.isEmpty)
        #expect(candidates.count <= 12)
        #expect(!candidates.contains("night"))
        let nightKeys = Set(ProsodyAnalyzer.rhymeKeys(for: "night"))
        // Hyphenated/apostrophe'd entries don't normalize back to their
        // dictionary spelling, so only phonetics-check the clean ones.
        for word in candidates where ProsodyAnalyzer.normalizeWord(word) == word {
            #expect(
                !Set(ProsodyAnalyzer.rhymeKeys(for: word)).intersection(nightKeys).isEmpty,
                "\(word) does not share a rhyme key with night"
            )
        }
    }

    @Test func candidateEndWordsReturnEmptyForUnknownWords() {
        #expect(RhymeConstraint.candidateEndWords(targetWord: "zzzqxv", rhymeType: .perfect).isEmpty)
        #expect(RhymeConstraint.candidateEndWords(targetWord: "zzzqxv", rhymeType: .slant).isEmpty)
        #expect(RhymeConstraint.candidateEndWords(targetWord: "", rhymeType: .near).isEmpty)
    }

    @Test func rhymeTierClassifiesPerfectNearAndMiss() throws {
        let perfectWord = try #require(roundTripSafeCandidate(for: "night", rhymeType: .perfect))
        #expect(RhymeConstraint.rhymeTier(line: "We chase the \(perfectWord)", targetWord: "night") == 2)

        let nearWord = try #require(
            RhymeIndex.shared.find(word: "night").near
                .first { ProsodyAnalyzer.normalizeWord($0) == $0 }
        )
        #expect(RhymeConstraint.rhymeTier(line: "Carried on the \(nearWord)", targetWord: "night") == 1)

        #expect(RhymeConstraint.rhymeTier(line: "Nothing here can save us", targetWord: "night") == 0)
        #expect(RhymeConstraint.rhymeTier(line: "", targetWord: "night") == 0)
    }

    @Test func filterAndRankPrefersRhymingLinesRegardlessOfOrder() throws {
        let rhymeWord = try #require(roundTripSafeCandidate(for: "night", rhymeType: .perfect))
        let rhyming = "We chase the fading \(rhymeWord)"
        let nonRhyming = "Nothing here can save us"

        #expect(RhymeConstraint.filterAndRank(
            lines: [nonRhyming, rhyming],
            targetLine: "We own the night",
            rhymeType: .perfect,
            want: 1
        ) == [rhyming])
        #expect(RhymeConstraint.filterAndRank(
            lines: [rhyming, nonRhyming],
            targetLine: "We own the night",
            rhymeType: .perfect,
            want: 1
        ) == [rhyming])
    }

    @Test func filterAndRankTopsUpWithNonRhymingLinesInOriginalOrder() throws {
        let rhymeWord = try #require(roundTripSafeCandidate(for: "night", rhymeType: .perfect))
        let rhyming = "Out beyond the \(rhymeWord)"
        let fillerA = "Nothing here can save us"
        let fillerB = "The morning comes too soon"

        let ranked = RhymeConstraint.filterAndRank(
            lines: [fillerA, rhyming, fillerB],
            targetLine: "We own the night",
            rhymeType: .perfect,
            want: 3
        )
        #expect(ranked == [rhyming, fillerA, fillerB])
    }

    @Test func filterAndRankNeverReturnsEmptyForNonEmptyInput() {
        let lines = ["The morning comes too soon", "Nothing here can save us"]

        // Nothing rhymes: keep arrival order rather than returning nothing.
        #expect(RhymeConstraint.filterAndRank(
            lines: lines,
            targetLine: "We own the night",
            rhymeType: .perfect,
            want: 2
        ) == lines)

        // Unknown target word: the constraint was never applied upstream.
        #expect(RhymeConstraint.filterAndRank(
            lines: lines,
            targetLine: "Surrounded by the zzzqxv",
            rhymeType: .perfect,
            want: 1
        ) == [lines[0]])
    }

    @Test func filterAndRankDedupesByNormalizedText() throws {
        let rhymeWord = try #require(roundTripSafeCandidate(for: "night", rhymeType: .perfect))
        let line = "We chase the \(rhymeWord)"
        let shoutedDupe = "WE CHASE THE \(rhymeWord.uppercased())!!"

        #expect(RhymeConstraint.filterAndRank(
            lines: [line, shoutedDupe],
            targetLine: "We own the night",
            rhymeType: .perfect,
            want: 6
        ) == [line])
    }

    @Test func constraintBlockAppearsOnlyForKnownTargetLines() {
        let block = AIService.rhymeConstraintBlock(
            targetRhymeLine: "We own the night",
            rhymeType: .perfect
        )
        #expect(block?.contains("The new line must rhyme with: \"We own the night\" (it ends with \"night\").") == true)
        #expect(block?.contains("End each line with one of these rhyming words:") == true)
        #expect(block?.contains("(choose the most natural fit)") == true)

        #expect(AIService.rhymeConstraintBlock(targetRhymeLine: nil, rhymeType: .perfect) == nil)
        #expect(AIService.rhymeConstraintBlock(targetRhymeLine: "   ", rhymeType: .perfect) == nil)
        #expect(AIService.rhymeConstraintBlock(targetRhymeLine: "Surrounded by the zzzqxv", rhymeType: .perfect) == nil)
    }

    @Test func suggestionPromptConstrainsEndingWordsOnlyWithTargetLine() {
        let service = AIService()
        let constrained = service.buildPrompt(
            theme: "late-night resolve",
            lyrics: "[Verse]\nWe own the night",
            targetRhymeLine: "We own the night",
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "A",
            currentSection: .verse,
            complexity: .moderate,
            useWholeSongContext: false
        )
        #expect(constrained.contains("(it ends with \"night\")"))
        #expect(constrained.contains("End each line with one of these rhyming words:"))
        #expect(constrained.contains("Respond with exactly 12 lines"))

        let unconstrained = service.buildPrompt(
            theme: "late-night resolve",
            lyrics: "[Verse]\nWe own the night",
            targetRhymeLine: nil,
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "B",
            currentSection: .verse,
            complexity: .moderate,
            useWholeSongContext: false
        )
        #expect(!unconstrained.contains("End each line with"))
        #expect(unconstrained.contains("Respond with exactly 6 lines"))

        // Dictionary miss on the ending word leaves the prompt untouched too.
        let unknownTarget = service.buildPrompt(
            theme: "late-night resolve",
            lyrics: "[Verse]\nSurrounded by the zzzqxv",
            targetRhymeLine: "Surrounded by the zzzqxv",
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "A",
            currentSection: .verse,
            complexity: .moderate,
            useWholeSongContext: false
        )
        #expect(!unknownTarget.contains("End each line with"))
        #expect(unknownTarget.contains("Respond with exactly 6 lines"))
    }

    @Test func suggestionPromptNamesStructuralSectionWithoutRhymeConstraint() {
        let prompt = AIService().buildPrompt(
            theme: "late-night resolve",
            lyrics: "[Pre-Chorus]\nBuild it higher",
            targetRhymeLine: nil,
            rhymeType: .perfect,
            rhymeScheme: "AABB",
            currentLetter: "A",
            currentSection: .unknown,
            complexity: .moderate,
            useWholeSongContext: true
        )

        #expect(
            prompt.contains(
                "Current section label: \"Pre-Chorus\". Treat this label as song structure, not lyric content."
            )
        )
        #expect(prompt.contains("Build momentum and tension toward the chorus"))
    }

    @Test func rewritePromptNamesCustomStructuralSection() {
        let prompt = AIService().buildRewritePrompt(
            action: .rephrase,
            lyrics: "[Post-Chorus]\nLet it ring",
            selection: "Let it ring",
            currentSection: .unknown,
            currentSectionLabel: "Post-Chorus"
        )

        #expect(prompt.contains("Current section label: \"Post-Chorus\""))
        #expect(prompt.contains("Treat this label as song structure, not lyric content."))
    }

    @Test func rhymeLineFilterMirrorsThePromptGate() {
        #expect(RhymeLineFilter(targetLine: "We own the night", rhymeType: .perfect) != nil)
        #expect(RhymeLineFilter(targetLine: nil, rhymeType: .perfect) == nil)
        #expect(RhymeLineFilter(targetLine: "  ", rhymeType: .perfect) == nil)
        #expect(RhymeLineFilter(targetLine: "Surrounded by the zzzqxv", rhymeType: .perfect) == nil)
    }
}
