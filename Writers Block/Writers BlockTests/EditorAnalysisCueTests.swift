import Foundation
import Testing
@testable import Writers_Block

struct EditorAnalysisCueTests {
    @Test func compactEditorStatsFormatsZeroAndMultiDigitCounts() {
        #expect(compactEditorStatsText(wordCount: 0, syllableCount: 0) == "0w · 0s")
        #expect(compactEditorStatsText(wordCount: 42, syllableCount: 108) == "42w · 108s")
    }

    @Test func rhymeFamiliesAreColouredAndSyllablesUnderlinedOnlyAlongsideThem() async {
        let text = "light night"
        let rhymeOnly = await LyricsHighlighting.spans(
            text: text, rhymeEnabled: true, syllablesEnabled: false, isDark: false
        )
        let both = await LyricsHighlighting.spans(
            text: text, rhymeEnabled: true, syllablesEnabled: true, isDark: false
        )
        let syllablesOnly = await LyricsHighlighting.spans(
            text: text, rhymeEnabled: false, syllablesEnabled: true, isDark: false
        )
        #expect(rhymeOnly.count == 2)
        #expect(rhymeOnly.allSatisfy { $0.foreground != nil && $0.underline == nil })
        #expect(rhymeOnly[0].foreground == rhymeOnly[1].foreground)
        #expect(both.map(\.foreground) == rhymeOnly.map(\.foreground))
        #expect(both.allSatisfy { $0.underline != nil })
        #expect(syllablesOnly.allSatisfy { $0.foreground != nil && $0.underline == nil })
    }

    @Test func rhymeFamilyHelpDescribesColour() {
        #expect(FeatureHelp.colorRhymes.title == "Rhyme Families")
        #expect(
            FeatureHelp.colorRhymes.message
                == "Colors identify words that share a rhyme sound. Matching colors belong to the same rhyme family."
        )
    }

    @Test func aStoredInkMarksChoiceIsDroppedAtLaunch() throws {
        // Given defaults written by a build that still had the Ink Marks style
        let suiteName = "EditorAnalysisCueTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("inkMarks", forKey: "analysisPresentationStyle")
        defaults.set(true, forKey: "editor.isRhymeHighlightEnabled")

        // When
        RetiredPreferences.remove(from: defaults)

        // Then the retired choice is gone and unrelated settings are kept
        #expect(defaults.object(forKey: "analysisPresentationStyle") == nil)
        #expect(defaults.bool(forKey: "editor.isRhymeHighlightEnabled"))
        RetiredPreferences.remove(from: defaults)
        #expect(defaults.object(forKey: "analysisPresentationStyle") == nil)
    }
}
