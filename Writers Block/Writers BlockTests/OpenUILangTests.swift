import Foundation
import Testing
@testable import Writers_Block

@MainActor
struct OpenUILangTests {

    @Test func autoCloseClosesUnclosedQuotesAndBracketsMidStream() {
        let raw = "root = Stack([meter, g1\ns1 = SuggestionLine(\"The static on the pavement glowed"
        let closed = OpenUIParser.autoClose(raw)
        #expect(closed.hasSuffix("\")]" + ")"))
        #expect(closed.contains("s1 = SuggestionLine(\"The static on the pavement glowed\""))
    }

    @Test func streamingParserResolvesForwardReferencesProgressively() {
        let parser = OpenUIStreamingParser()

        // Chunk 1: root declared first referencing meter, g1, actions before they exist
        let step1 = parser.push("root = Stack([meter, g1, actions])\n")
        #expect(step1.root != nil)
        #expect(step1.root?.typeName == "Stack")
        #expect(step1.meta.unresolvedRefs.contains("meter"))
        #expect(step1.meta.unresolvedRefs.contains("g1"))
        #expect(step1.meta.unresolvedRefs.contains("actions"))

        // Chunk 2: meter arrives
        let step2 = parser.push(
            "meter = ProsodyMeter(7, \"da-DUM da-DUM\", \"A\", \"Verse\")\n"
        )
        let children2 = step2.root?.childrenProp("children") ?? []
        #expect(children2.count == 1)
        #expect(children2.first?.typeName == "ProsodyMeter")
        #expect(children2.first?.intProp("targetSyllables") == 7)
        #expect(children2.first?.stringProp("rhymeSchemeLetter") == "A")

        // Chunk 3: g1 arrives referencing s1 and s2, then s1 arrives mid-string
        _ = parser.push("g1 = RhymeGroup(\"Perfect Rhymes\", [s1, s2], \"Perfect\", \"Direct imagery\")\n")
        let step3 = parser.push("s1 = SuggestionLine(\"The static on the pavement glowed\", \"Sensory detail\", \"glowed\"")
        let children3 = step3.root?.childrenProp("children") ?? []
        #expect(children3.count == 2)
        let groupNode = children3[1]
        #expect(groupNode.typeName == "RhymeGroup")
        let groupSuggestions = groupNode.childrenProp("children")
        #expect(groupSuggestions.count == 1)
        #expect(groupSuggestions[0].stringProp("text") == "The static on the pavement glowed")
        #expect(step3.meta.unresolvedRefs.contains("s2"))

        // Chunk 4: finish s1, add s2 and actions
        let step4 = parser.push(
            ")\ns2 = SuggestionLine(\"A heavy promise that we owed\", \"Stakes\", \"owed\")\n" +
            "actions = ActionChipBar([\"More imagery\", \"Tighter meter\"], \"Refine\")\n"
        )
        #expect(step4.extractedSuggestions.count == 2)
        #expect(step4.extractedSuggestions[0].text == "The static on the pavement glowed")
        #expect(step4.extractedSuggestions[1].text == "A heavy promise that we owed")
        #expect(step4.meta.unresolvedRefs.isEmpty)
    }

    @Test func synthesizeTreeBuildsOpenUITreeFromVerifiedLines() {
        let result = OpenUILibrary.synthesizeTree(
            lines: [
                "The static on the pavement glowed",
                "A heavy promise that we owed"
            ],
            rhymeLetter: "A",
            rhymeTypeLabel: "Perfect",
            sectionName: "Verse",
            targetSyllables: 8
        )
        #expect(result.root != nil)
        #expect(result.root?.typeName == "Stack")
        #expect(result.extractedSuggestions.count == 2)
        #expect(result.extractedSuggestions[0].text == "The static on the pavement glowed")
    }
}
