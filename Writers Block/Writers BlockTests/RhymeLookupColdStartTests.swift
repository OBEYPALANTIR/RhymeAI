import Foundation
import Testing
@testable import Writers_Block

/// The word inspector's first lookup after launch: what the bundled
/// dictionary returns, and what the sheet shows while it is still running.
struct RhymeLookupColdStartTests {
    @Test func bundledDictionaryFindsPerfectRhymesForYellow() {
        // The app's own lookup path, with the dictionary the app bundles.
        #expect(PronunciationDictionary.shared.wordCount > 100_000)

        let matches = ProsodyAnalyzer.findRhymes(for: "yellow")

        #expect(matches.perfect.contains("mellow"))
        #expect(matches.perfect.contains("fellow"))
        #expect(!matches.perfect.contains("yellow"))
        #expect(!matches.near.isEmpty)
    }

    @Test func firstLookupsOnAColdIndexReturnTheSameRhymesAsLaterOnes() async {
        // Given an index nothing has built yet, as at launch
        let index = RhymeIndex()
        #expect(RhymeResultPresentation.state(for: nil) == .finding)
        // An empty dictionary must not leave an empty index behind.
        #expect(index.find(word: "yellow", dictionary: PronunciationDictionary(entries: [:])).isEmpty)

        // When two lookups race to build it, then a third runs warm
        async let first = Task.detached { index.find(word: "yellow") }.value
        async let second = Task.detached { index.find(word: "yellow") }.value
        let cold = await [first, second]
        let warm = index.find(word: "yellow")

        // Then
        #expect(warm.perfect.contains("mellow"))
        #expect(warm.perfect.contains("fellow"))
        #expect(cold == [warm, warm])
        #expect(RhymeResultPresentation.state(for: warm) == .results(warm))
    }

    @Test func emptyTextIsOnlyForAFinishedLookup() {
        #expect(RhymeResultPresentation.state(for: nil) == .finding)
        #expect(RhymeResultPresentation.state(for: .empty) == .results(.empty))
        #expect(RhymeResultPresentation.findingMessage == "Finding rhymes…")
    }

    @Test func resultsAreAnnouncedOnlyAfterAnAudibleWait() {
        let found = RhymeMatches(perfect: ["mellow"], near: [], slant: [], multi: [])
        #expect(RhymeResultPresentation.announcement(for: found, waited: 0.2) == nil)
        #expect(RhymeResultPresentation.announcement(for: found, waited: 4) == "Rhymes loaded")
        #expect(RhymeResultPresentation.announcement(for: .empty, waited: 4) == "No rhymes found")
        // Slant rhymes are not shown in the inspector, so they do not count.
        let slantOnly = RhymeMatches(perfect: [], near: [], slant: ["hollow"], multi: [])
        #expect(RhymeResultPresentation.announcement(for: slantOnly, waited: 4) == "No rhymes found")
    }

    @Test func cancelledWarmUpLeavesTheIndexUsable() async {
        let dictionary = PronunciationDictionary.fromLines([
            "yellow\tY EH1 L OW0",
            "mellow\tM EH1 L OW0",
            "fellow\tF EH1 L OW0",
            "music\tM Y UW1 Z IH0 K",
        ])
        let index = RhymeIndex()

        await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            index.warmUp(dictionary: dictionary)
        }.value
        #expect(Set(index.find(word: "yellow", dictionary: dictionary).perfect) == ["mellow", "fellow"])

        let warmed = RhymeIndex()
        warmed.warmUp(dictionary: dictionary)
        #expect(Set(warmed.find(word: "yellow", dictionary: dictionary).perfect) == ["mellow", "fellow"])
    }
}
