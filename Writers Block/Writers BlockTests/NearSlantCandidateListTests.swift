import Foundation
import Testing
@testable import Writers_Block

/// The allowed end words the next-line prompt sends for Near and Slant, built
/// from the bundled dictionary and frequency list. Android asserts the same
/// lists in `NearSlantCandidateListTest.kt`.
struct NearSlantCandidateListTests {
    private func list(_ anchor: String, _ type: RhymeType) -> [String] {
        RhymeConstraint.candidateEndWords(targetWord: anchor, rhymeType: type)
    }

    @Test(arguments: [
        // anchor, near must include, near must exclude, slant must include, slant must exclude
        ("chair", ["shared", "scared", "stairs", "prepared"], ["then", "when", "as", "them", "very", "said"],
         ["far", "star", "war", "sure"], ["then", "for", "are", "or", "your", "our"]),
        ("would", ["look", "took", "book", "foot"], ["your", "sure", "good", "full"],
         ["said", "food", "need", "full"], ["had", "did", "good"]),
        ("night", ["like", "side", "high", "try"], ["time", "line", "life", "while", "live", "light"],
         ["time", "life", "out", "find"], ["that", "it", "at", "not", "but", "what"]),
        ("home", ["phone", "known", "alone", "go"], ["so", "no", "those", "though", "both", "most"],
         ["time", "same", "name", "hope"], ["from", "some", "them", "him", "am"]),
        ("river", ["silver", "differ", "scissor"], ["dinner", "bigger", "winner", "twitter", "rivers"],
         ["over", "never", "cover", "winter"], ["however", "whatever", "whoever", "whenever"]),
        ("alone", ["home", "know", "go", "below"], ["so", "no", "those", "job", "in", "on"],
         ["one", "down", "done", "seen"], ["in", "on", "an", "can", "when", "than", "then", "been"])
    ])
    func nearAndSlantListsHoldRealMatchesOnly(
        anchor: String,
        nearIncludes: [String],
        nearExcludes: [String],
        slantIncludes: [String],
        slantExcludes: [String]
    ) {
        let perfect = Set(list(anchor, .perfect))
        let near = list(anchor, .near)
        let slant = list(anchor, .slant)

        for word in nearIncludes { #expect(near.contains(word), "\(anchor) near \(near) lacks \(word)") }
        for word in nearExcludes { #expect(!near.contains(word), "\(anchor) near \(near) has \(word)") }
        for word in slantIncludes { #expect(slant.contains(word), "\(anchor) slant \(slant) lacks \(word)") }
        for word in slantExcludes { #expect(!slant.contains(word), "\(anchor) slant \(slant) has \(word)") }

        #expect(!near.contains(anchor) && !slant.contains(anchor))
        #expect(perfect.isDisjoint(with: near) && perfect.isDisjoint(with: slant))
        #expect(Set(near).isDisjoint(with: slant))
        for word in near {
            #expect(ProsodyAnalyzer.rhymeRelation(candidateWord: word, targetWord: anchor) == .near,
                    "\(word) is listed as near for \(anchor)")
        }
        for word in slant {
            #expect(ProsodyAnalyzer.rhymeRelation(candidateWord: word, targetWord: anchor) == .slant,
                    "\(word) is listed as slant for \(anchor)")
        }
        // Content words come before function words.
        for words in [near, slant] {
            let firstFunction = words.firstIndex(where: ProsodyAnalyzer.isFunctionWord) ?? words.endIndex
            #expect(words[firstFunction...].allSatisfy(ProsodyAnalyzer.isFunctionWord), "\(words)")
        }
    }

    @Test func theObservedChairEndingIsNoRhymeAtAll() {
        let matches = RhymeIndex.shared.find(word: "chair")
        #expect(ProsodyAnalyzer.rhymeRelation(candidateWord: "then", targetWord: "chair") == nil)
        #expect(!matches.near.contains("then"))
        #expect(!matches.slant.contains("then"))
    }

    @Test func perfectListsAreUnchanged() {
        #expect(list("would", .perfect) == [
            "good", "could", "should", "wood", "understood", "stood", "hollywood",
            "childhood", "neighborhood", "hood", "neighbourhood", "likelihood"
        ])
        #expect(list("night", .perfect) == [
            "right", "might", "white", "light", "quite", "fight", "site", "website",
            "tonight", "write", "despite", "flight"
        ])
        #expect(list("alone", .perfect) == [
            "own", "known", "phone", "shown", "stone", "zone", "loan", "grown",
            "unknown", "tone", "bone", "iphone"
        ])
    }

    @Test func tooFewMatchesReturnFewerWordsInsteadOfPadding() {
        let dictionary = PronunciationDictionary.fromLines([
            "road\tR OW1 D",
            "wrote\tR OW1 T",
            "then\tDH EH1 N",
            "chair\tCH EH1 R"
        ])
        #expect(RhymeConstraint.candidateEndWords(targetWord: "road", rhymeType: .near, dictionary: dictionary) == ["wrote"])
        #expect(RhymeConstraint.candidateEndWords(targetWord: "chair", rhymeType: .near, dictionary: dictionary).isEmpty)
        #expect(RhymeConstraint.candidateEndWords(targetWord: "chair", rhymeType: .slant, dictionary: dictionary).isEmpty)
    }

    @Test func relationsFollowTheSongwritingDefinitions() {
        func relation(_ candidate: String, _ target: String) -> RhymeType? {
            ProsodyAnalyzer.rhymeRelation(candidateWord: candidate, targetWord: target)
        }
        #expect(relation("ride", "night") == .near)    // same consonant family
        #expect(relation("stairs", "chair") == .near)  // added consonant
        #expect(relation("caring", "chair") == .near)  // extra unstressed syllable
        #expect(relation("happy", "free") == .near)    // stress falls differently
        #expect(relation("door", "chair") == .slant)   // consonance
        #expect(relation("time", "night") == .slant)   // assonance
        #expect(relation("then", "chair") == nil)      // R-coloured vowel differs, coda differs
    }
}
