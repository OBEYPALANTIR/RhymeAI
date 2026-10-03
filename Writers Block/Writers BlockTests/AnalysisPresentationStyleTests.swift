import SwiftUI
import Testing
@testable import Writers_Block

struct AnalysisPresentationStyleTests {
    @Test func rawValuesAndFallbackAreStable() {
        #expect(AnalysisPresentationStyle.color.rawValue == "color")
        #expect(AnalysisPresentationStyle.inkMarks.rawValue == "inkMarks")
        #expect(AnalysisPresentationStyle.storageKey == "analysisPresentationStyle")
        #expect(AnalysisPresentationStyle.resolve(nil) == .color)
        #expect(AnalysisPresentationStyle.resolve("unknown") == .color)
    }

    @Test func rhymePatternsAreStableAndUseAllFourPatterns() {
        let keys = ["EY1", "AY1", "OW1", "IY1", "ER1", "EH1", "AE1", "UW1"]
        let first = keys.map(analysisInkPattern)
        #expect(first == keys.map(analysisInkPattern))
        #expect(Set(first) == Set(InkUnderlinePattern.allCases))
    }

    @Test func everyInkPatternMapsToADistinctLineStyle() {
        let styles = InkUnderlinePattern.allCases.map(\.lineStyle)
        #expect(Set(styles.map(String.init(describing:))).count == 4)
    }

    @Test func syllableWeightsUseFourProgressiveBuckets() {
        #expect(analysisFontWeight(syllableCount: 1) == .regular)
        #expect(analysisFontWeight(syllableCount: 2) == .medium)
        #expect(analysisFontWeight(syllableCount: 3) == .semibold)
        #expect(analysisFontWeight(syllableCount: 4) == .bold)
        #expect(analysisFontWeight(syllableCount: 8) == .bold)
    }

    @Test func rhymeOnlyInkMarksDoNotApplySyllableWeight() {
        #expect(analysisFontWeight(syllableCount: 3, syllableGuideEnabled: false) == nil)
        #expect(analysisFontWeight(syllableCount: 3, syllableGuideEnabled: true) == .semibold)
    }

    @Test func compactEditorStatsFormatsZeroAndMultiDigitCounts() {
        #expect(compactEditorStatsText(wordCount: 0, syllableCount: 0) == "0w · 0s")
        #expect(compactEditorStatsText(wordCount: 42, syllableCount: 108) == "42w · 108s")
    }

    @Test func liveEditorSpansFollowTheSelectedAnalysisStyle() async {
        let text = "light night"
        let color = await LyricsHighlighting.spans(
            text: text, rhymeEnabled: true, syllablesEnabled: false,
            isDark: false, style: .color
        )
        let ink = await LyricsHighlighting.spans(
            text: text, rhymeEnabled: true, syllablesEnabled: false,
            isDark: false, style: .inkMarks
        )
        #expect(color.count == 2)
        #expect(ink.count == 2)
        #expect(color.allSatisfy { $0.foreground != nil && $0.underlineStyle == nil })
        #expect(ink.allSatisfy { $0.foreground == nil && $0.underlineStyle != nil })
        #expect(ink[0].underlineStyle == ink[1].underlineStyle)
    }

    @Test func rhymeFamilyHelpMatchesTheSelectedAnalysisPresentation() {
        #expect(FeatureHelp.colorRhymes.title == "Rhyme Families")
        #expect(
            FeatureHelp.colorRhymes.message(for: .color)
                == "Colors identify words that share a rhyme sound. Matching colors belong to the same rhyme family."
        )
        #expect(
            FeatureHelp.colorRhymes.message(for: .inkMarks)
                == "Underline patterns identify words that share a rhyme sound. Matching patterns belong to the same rhyme family."
        )
    }
}
