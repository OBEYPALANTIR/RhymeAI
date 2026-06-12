import Foundation
import Testing
@testable import Writers_Block

/// Tests for WordFrequency and its integration with RhymeIndex.find (which
/// drives both the rhyme inspector and candidateEndWords).
struct WordFrequencyTests {

    /// Build a WordFrequency instance ranked by the given words (first = most frequent).
    private func buildFrequency(_ ranked: String...) -> WordFrequency {
        let wf = WordFrequency()
        wf.load(lines: ranked)
        return wf
    }

    private func smallDictionary() -> PronunciationDictionary {
        PronunciationDictionary.fromLines([
            "night\tN AY1 T",
            "light\tL AY1 T",
            "right\tR AY1 T",
            "sight\tS AY1 T",
            "rain\tR EY1 N",
        ])
    }

    // MARK: - Unit: WordFrequency itself

    @Test func rankOfReturnsPositionForKnownWords() {
        let wf = buildFrequency("right", "light", "sight")
        #expect(wf.rank(of: "right") == 1)
        #expect(wf.rank(of: "light") == 2)
        #expect(wf.rank(of: "sight") == 3)
    }

    @Test func rankOfReturnsMaxValueForUnknownWord() {
        let wf = buildFrequency("right", "light")
        #expect(wf.rank(of: "cocaine") == WordFrequency.unknownRank)
        #expect(wf.rank(of: "") == WordFrequency.unknownRank)
    }

    @Test func rankOfIsCaseInsensitive() {
        let wf = buildFrequency("right", "light")
        #expect(wf.rank(of: "RIGHT") == 1)
        #expect(wf.rank(of: "Right") == 1)
    }

    @Test func sortByFrequencyOrdersCommonWordsFirst() {
        let wf = buildFrequency("right", "light", "sight")
        let sorted = wf.sortByFrequency(["sight", "cocaine", "light", "right"])
        // right(1), light(2), sight(3), cocaine(MAX)
        #expect(sorted == ["right", "light", "sight", "cocaine"])
    }

    @Test func sortByFrequencyIsStableForEqualRanks() {
        // Words not in the list all get unknownRank; original input order preserved.
        let wf = buildFrequency("right")
        let input = ["cocaine", "arcane", "light"]
        let sorted = wf.sortByFrequency(input)
        #expect(sorted == ["cocaine", "arcane", "light"])
    }

    @Test func sortByFrequencyReturnsInputOrderWhenNotLoaded() {
        let wf = WordFrequency()   // not loaded — empty map
        let input = ["sight", "light", "right"]
        #expect(wf.sortByFrequency(input) == input)
    }

    // MARK: - Integration: frequency ordering in RhymeIndex.find

    @Test func commonNightRhymesRankBeforeObscureOnes() {
        let dict = smallDictionary()
        // right(rank 1) < light(rank 2) < sight(rank 3); rain absent → unknownRank
        let wf = buildFrequency("right", "light", "sight")
        let index = RhymeIndex()
        let matches = index.find(word: "night", dictionary: dict, wordFrequency: wf)

        let perfects = matches.perfect
        if let rightIdx = perfects.firstIndex(of: "right"),
           let lightIdx = perfects.firstIndex(of: "light") {
            #expect(rightIdx < lightIdx, "right (rank 1) must precede light (rank 2)")
        }
        if let lightIdx = perfects.firstIndex(of: "light"),
           let sightIdx = perfects.firstIndex(of: "sight") {
            #expect(lightIdx < sightIdx, "light (rank 2) must precede sight (rank 3)")
        }
    }

    @Test func wordMissingFromFrequencyListStillAppearsInCandidates() {
        // A word not in the frequency list gets unknownRank and sorts last, never dropped.
        let dict = smallDictionary()
        let wf = buildFrequency("right")    // only right is ranked; light and sight get MAX

        let index = RhymeIndex()
        let matches = index.find(word: "night", dictionary: dict, wordFrequency: wf)

        // right, light, sight all share the AY1 T rhyme key → all in perfect pool
        #expect(matches.perfect.contains("right"), "right must appear in perfect pool")
        #expect(matches.perfect.contains("light"), "light must still appear even with unknownRank")
        #expect(matches.perfect.contains("sight"), "sight must still appear even with unknownRank")
    }

    @Test func poolPrecedencePreservedNearRhymesNeverOutrankPerfect() {
        // rain has the highest frequency rank (1) but is only a near rhyme for night.
        // Perfect rhymes (light, right, sight) must still appear before rain.
        let dict = smallDictionary()
        // rain rank=1 (most common); light/right/sight absent → unknownRank
        let wf = buildFrequency("rain")

        let index = RhymeIndex()
        let matches = index.find(word: "night", dictionary: dict, wordFrequency: wf)

        // Verify at RhymeMatches level: perfect pool contains light/right/sight;
        // near pool contains rain. Pool precedence means perfect entries always
        // surface first in orderedCandidates.
        for perfect in ["light", "right", "sight"] where matches.perfect.contains(perfect) {
            #expect(!matches.near.contains(perfect), "\(perfect) must not be in near pool")
        }
        // Combine into candidate order the same way candidateEndWords would (NEAR type).
        let orderedNear = RhymeConstraint.orderedCandidates(
            matches,
            rhymeType: .near,
            excluding: "night"
        )
        if let rainIdx = orderedNear.firstIndex(of: "rain") {
            for perfect in ["light", "right", "sight"] {
                if let perfectIdx = orderedNear.firstIndex(of: perfect) {
                    #expect(
                        perfectIdx < rainIdx,
                        "Perfect rhyme '\(perfect)' must precede near rhyme 'rain' regardless of frequency"
                    )
                }
            }
        }
    }
}
