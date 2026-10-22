import SwiftUI
import Testing
@testable import Writers_Block

struct RhymeMatchTextTests {
    private typealias SwiftUIKeys = AttributeScopes.SwiftUIAttributes
    private typealias UIKitKeys = AttributeScopes.UIKitAttributes

    private let violet = Color(hex: AppAppearanceStyle.ink.analysisRhymeHexValues[4])

    /// The text of every run carrying the highlight colour.
    private func highlightedRuns(_ text: AttributedString) -> [String] {
        text.runs.compactMap { run in
            run[SwiftUIKeys.ForegroundColorAttribute.self] == violet
                ? String(text[run.range].characters)
                : nil
        }
    }

    @Test
    func lastWordCarriesTheRhymeMatchStyle() throws {
        let line = "I walked along the shore"
        let result = RhymeMatchText.attributed(line, highlight: violet)

        #expect(String(result.characters) == line)
        #expect(highlightedRuns(result) == ["shore"])

        let word = try #require(result.runs.first { $0[SwiftUIKeys.ForegroundColorAttribute.self] == violet })
        #expect(word[SwiftUIKeys.UnderlineStyleAttribute.self] == .single)
        #expect(word[UIKitKeys.UnderlineColorAttribute.self] != nil)
        #expect(word[SwiftUIKeys.FontAttribute.self] == Font.system(.body, design: .serif).weight(.semibold))

        let prefix = try #require(result.runs.first)
        #expect(String(result[prefix.range].characters) == "I walked along the ")
        #expect(prefix[SwiftUIKeys.ForegroundColorAttribute.self] == nil)
        #expect(prefix[SwiftUIKeys.UnderlineStyleAttribute.self] == nil)
    }

    @Test
    func trailingPunctuationAndClosingQuoteStayPlain() throws {
        let line = "Hold on, don't let go!\""
        let result = RhymeMatchText.attributed(line, highlight: violet)

        #expect(String(result.characters) == line)
        #expect(highlightedRuns(result) == ["go"])

        let suffix = try #require(result.runs.last)
        #expect(String(result[suffix.range].characters) == "!\"")
        #expect(suffix[SwiftUIKeys.ForegroundColorAttribute.self] == nil)
    }

    @Test(arguments: [
        ("I know you're", "you're"),
        ("I know you\u{2019}re", "you\u{2019}re"),
        ("the band's", "band's"),
        ("singing \"I know you're\"", "you're"),
    ])
    func contractionsAndPossessivesHighlightTheWholeWord(line: String, expected: String) {
        let result = RhymeMatchText.attributed(line, highlight: violet)

        #expect(String(result.characters) == line)
        #expect(highlightedRuns(result) == [expected])
    }

    @Test
    func singleWordLineIsHighlightedWhole() {
        let result = RhymeMatchText.attributed("Midnight", highlight: violet)

        #expect(String(result.characters) == "Midnight")
        #expect(highlightedRuns(result) == ["Midnight"])
        #expect(result.runs.count == 1)
    }

    @Test
    func lineWithoutAWordIsPlainText() {
        for line in ["", "..."] {
            let result = RhymeMatchText.attributed(line, highlight: violet)

            #expect(String(result.characters) == line)
            #expect(highlightedRuns(result).isEmpty)
            #expect(result.runs.allSatisfy { $0[SwiftUIKeys.UnderlineStyleAttribute.self] == nil })
        }
    }

    @Test
    func callerFontKeepsItsStyleAtSemibold() throws {
        let italicSerif = Font.system(.body, design: .serif).italic()
        let result = RhymeMatchText.attributed("Say it back", highlight: violet, font: italicSerif)

        let word = try #require(result.runs.first { $0[SwiftUIKeys.ForegroundColorAttribute.self] == violet })
        #expect(word[SwiftUIKeys.FontAttribute.self] == italicSerif.weight(.semibold))
    }
}
