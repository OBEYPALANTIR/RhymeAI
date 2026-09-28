import Foundation
import Testing
@testable import Writers_Block

/// Coverage for rhyme-word-first constrained generation: candidate ending
/// words, tier verification, and the over-generate-and-filter ranking.
/// These run against the bundled pronunciation dictionary because the rhyme
/// index caps its lists in hash order — assertions check phonetics and
/// ordering invariants, never specific capped-list members.
struct RhymeConstraintTests {
    private let relationDictionary = PronunciationDictionary.fromLines([
        "road\tR OW1 D",
        "glowed\tG L OW1 D",
        "showed\tSH OW1 D",
        "stone\tS T OW1 N",
        "bones\tB OW1 N Z",
        "red\tR EH1 D",
        "night\tN AY1 T"
    ])

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

    @Test func candidateEndWordsKeepRhymeModesExclusive() {
        let perfect = Set(RhymeConstraint.candidateEndWords(
            targetWord: "road", rhymeType: .perfect, dictionary: relationDictionary
        ))
        let near = Set(RhymeConstraint.candidateEndWords(
            targetWord: "road", rhymeType: .near, dictionary: relationDictionary
        ))
        let slant = Set(RhymeConstraint.candidateEndWords(
            targetWord: "road", rhymeType: .slant, dictionary: relationDictionary
        ))

        #expect(perfect == ["glowed", "showed"])
        #expect(near == ["stone"])
        #expect(slant == ["red"])
        #expect(perfect.isDisjoint(with: near))
        #expect(perfect.isDisjoint(with: slant))
        #expect(near.isDisjoint(with: slant))
        #expect(!near.contains("bones"))
    }

    @Test func rhymeTailsUseTheLastStressedVowelAndPreserveSecondaryStress() {
        #expect(ProsodyAnalyzer.rhymeTailForPhonesPublic(["R", "EY1", "D", "IY0", "OW2"]) == RhymeTail(
            vowel: "OW", coda: []
        ))
        #expect(ProsodyAnalyzer.rhymeTail(for: "road", dictionary: relationDictionary) == RhymeTail(
            vowel: "OW", coda: ["D"]
        ))
    }

    @Test func filterAndRankAdmitsOnlyTheRequestedRelation() {
        let lines = [
            "The window glowed",
            "Cold as stone",
            "Everything burned red",
            "Walking through the night"
        ]

        #expect(RhymeConstraint.filterAndRank(
            lines: lines,
            targetLine: "Down the road",
            rhymeType: .near,
            want: 2,
            dictionary: relationDictionary
        ) == ["Cold as stone"])
        #expect(RhymeConstraint.filterAndRank(
            lines: lines,
            targetLine: "Down the road",
            rhymeType: .slant,
            want: 2,
            dictionary: relationDictionary
        ) == ["Everything burned red"])
    }

    @Test func rhymeTiersAndBadgesNameEveryRelationTruthfully() {
        #expect(RhymeConstraint.rhymeTier(
            line: "The window glowed", targetWord: "road", dictionary: relationDictionary
        ) == 2)
        #expect(RhymeConstraint.rhymeTier(
            line: "Cold as stone", targetWord: "road", dictionary: relationDictionary
        ) == 1)
        #expect(RhymeConstraint.rhymeTier(
            line: "Everything burned red", targetWord: "road", dictionary: relationDictionary
        ) == 3)
        #expect(suggestionRhymeBadgeLabel(rhymeTier: 2, isHookRepeat: false) == "perfect")
        #expect(suggestionRhymeBadgeLabel(rhymeTier: 1, isHookRepeat: false) == "near")
        #expect(suggestionRhymeBadgeLabel(rhymeTier: 3, isHookRepeat: false) == "slant")
        #expect(suggestionRhymeBadgeLabel(rhymeTier: 3, isHookRepeat: true) == "hook")
        #expect(suggestionRhymeBadgeLabel(rhymeTier: 0, isHookRepeat: false) == nil)
    }

    @Test func bundledAlternateTargetPronunciationCanMakeAPerfectRhyme() {
        let dictionary = PronunciationDictionary.shared
        #expect(dictionary.pronunciations(for: "abuse").count == 2)
        #expect(dictionary.pronunciations(for: "news").count == 2)
        #expect(dictionary.pronunciations(for: "blues").count == 1)
        #expect(RhymeConstraint.rhymeTier(line: "The evening news", targetWord: "abuse") == 2)
        #expect(RhymeConstraint.rhymeTier(line: "I sing the blues", targetWord: "abuse") == 2)
        #expect(RhymeConstraint.rhymeTier(line: "A little juice", targetWord: "abuse") == 2)
        #expect(RhymeConstraint.rhymeTier(line: "The long night", targetWord: "abuse") == 0)
        #expect(RhymeConstraint.rhymeTier(line: "The evening news", targetWord: "unknownzz") == 0)
        #expect(RhymeConstraint.rhymeTier(line: "My abuse", targetWord: "abuse") == 0)
        #expect(ProsodyAnalyzer.rhymeTail(for: "the") == nil)
    }

    @Test func alternateTargetAndCandidatePronunciationsPreserveNearAndSlant() {
        let dictionary = PronunciationDictionary.fromLines([
            "anchor\tR OW1 D|R AY1 M",
            "match\tK AY1 M",
            "alternate\tK EH1 P|K AY1 M",
            "nearword\tN OW1 T",
            "slantword\tS EH1 D",
            "miss\tM UW1 P"
        ])
        #expect(ProsodyAnalyzer.rhymeRelation(candidateWord: "match", targetWord: "anchor", dictionary: dictionary) == .perfect)
        #expect(ProsodyAnalyzer.rhymeRelation(candidateWord: "alternate", targetWord: "anchor", dictionary: dictionary) == .perfect)
        #expect(ProsodyAnalyzer.rhymeRelation(candidateWord: "nearword", targetWord: "anchor", dictionary: dictionary) == .near)
        #expect(ProsodyAnalyzer.rhymeRelation(candidateWord: "slantword", targetWord: "anchor", dictionary: dictionary) == .slant)
        #expect(ProsodyAnalyzer.rhymeRelation(candidateWord: "miss", targetWord: "anchor", dictionary: dictionary) == nil)
        #expect(ProsodyAnalyzer.rhymeRelation(candidateWord: "anchor", targetWord: "anchor", dictionary: dictionary) == nil)
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

    @Test func filterAndRankClassifiesReturnedEndingsOutsidePromptCap() throws {
        let words = (0..<61).map { "zz" + String(repeating: "a", count: $0 + 2) }
        let dictionary = PronunciationDictionary.fromLines(
            ["anchor\tR AY1 M"] + words.map { "\($0)\tR AY1 M" }
        )
        let capped = Set(RhymeIndex.shared.find(word: "anchor", dictionary: dictionary).perfect)
        let outsideCap = try #require(words.first { !capped.contains($0) })
        let line = "Beyond the \(outsideCap)"

        #expect(RhymeConstraint.rhymeTier(
            line: line,
            targetWord: "anchor",
            dictionary: dictionary
        ) == 2)
        #expect(RhymeConstraint.filterAndRank(
            lines: [line],
            targetLine: "Find the anchor",
            rhymeType: .perfect,
            want: 1,
            dictionary: dictionary
        ) == [line])
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

    @Test func filterAndRankRejectsKnownNonRhymingLines() throws {
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
        #expect(ranked == [rhyming])
    }

    @Test func filterAndRankReturnsEmptyWhenKnownTargetHasNoMatchingSuggestion() {
        let lines = ["The morning comes too soon", "Nothing here can save us"]

        #expect(RhymeConstraint.filterAndRank(
            lines: lines,
            targetLine: "We own the night",
            rhymeType: .perfect,
            want: 2
        ).isEmpty)

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
