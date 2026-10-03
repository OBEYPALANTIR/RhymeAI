import Foundation
import Testing
@testable import Writers_Block

/// Regression coverage for the 2026-05 code audit fixes.
struct CodeAuditRegressionTests {

    @Test func fallbackSyllablesDistinguishSyllabicLeFromSilentE() {
        // Empty dictionary forces every word through the fallback counter.
        let dict = PronunciationDictionary.fromLines([String]())

        #expect(ProsodyAnalyzer.analyzeWord("tables", dictionary: dict).syllableCount == 2)
        #expect(ProsodyAnalyzer.analyzeWord("examples", dictionary: dict).syllableCount == 3)
        #expect(ProsodyAnalyzer.analyzeWord("miles", dictionary: dict).syllableCount == 1)
        #expect(ProsodyAnalyzer.analyzeWord("makes", dictionary: dict).syllableCount == 1)
    }

    @Test func rhymeContextHandlesEmojiBeforeCursor() {
        let viewModel = EditorViewModel()
        viewModel.rhymeScheme = .aabb
        viewModel.lyrics = "🔥🔥 first light\nsecond night"
        // UITextView reports UTF-16 offsets; each emoji is 2 UTF-16 units, so this
        // exceeds the Character count and used to skew the computed context.
        viewModel.cursorPosition = (viewModel.lyrics as NSString).length

        let context = viewModel.computeRhymeContext()

        #expect(context.currentLetter == "A")
        #expect(context.targetLine == "🔥🔥 first light")
    }

    @Test func currentLineUsesUTF16OffsetsAfterEmoji() {
        let viewModel = EditorViewModel()
        viewModel.lyrics = "🔥🔥 first light\nsecond night\nthird sight"
        let ns = viewModel.lyrics as NSString
        let word = ns.range(of: "night")

        // A Character-count line start would land mid-line-one and return both lines.
        #expect(viewModel.currentLine(for: word) == "second night")
        #expect(viewModel.currentLine(for: NSRange(location: ns.length, length: 0)) == "third sight")
    }

    @Test func characterOffsetClampsAndConvertsUTF16Offsets() {
        let text = "🔥abc"
        #expect(EditorViewModel.characterOffset(forUTF16Offset: 0, in: text) == 0)
        // Past the emoji (2 UTF-16 units) lands on the second Character.
        #expect(EditorViewModel.characterOffset(forUTF16Offset: 2, in: text) == 1)
        // Mid-surrogate snaps back to the previous boundary instead of trapping.
        #expect(EditorViewModel.characterOffset(forUTF16Offset: 1, in: text) == 0)
        // Out-of-range clamps to the end.
        #expect(EditorViewModel.characterOffset(forUTF16Offset: 99, in: text) == 4)
    }

    @Test func preChorusHeaderVariantsAreNotChorus() {
        #expect(SongSection.fromHeader("Pre-Chorus") == .unknown)
        #expect(SongSection.fromHeader("Pre Chorus 2") == .unknown)
        #expect(SongSection.fromHeader("PreChorus") == .unknown)
        #expect(SongSection.fromHeader("Chorus") == .chorus)
        #expect(SongSection.fromHeader("[Hook]") == .chorus)
    }
}
