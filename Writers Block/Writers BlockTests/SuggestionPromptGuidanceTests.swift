import Foundation
import Testing
@testable import Writers_Block

/// Next-line guidance shared with Android `SuggestionPromptGuidanceTest.kt`:
/// per-level complexity wording, the inspire-not-finish rules, the on-device
/// lyric context budget, and the Whole Song Context default. Expected strings
/// are identical on both sides.
@MainActor
struct SuggestionPromptGuidanceTests {
    private static let rulesHead = """
    Rules:
    - Return exactly 6 lines.
    - One suggestion per line.
    - Return only candidate lyric lines.
    - Make the six lines six different directions: a different idea, image or angle in each. Do not write the same thought six ways.

    """
    private static let rulesTail = """
    - Write them as raw material in the writer's own voice: match the length, plainness and capitalisation of the lines around it.
    - Do not resolve or conclude the song, do not sum it up, and no grand statements.
    - Stay inside what the song is already about.
    - Do not copy any existing lyric line.
    - Do not repeat the same suggestion.
    - No numbering, bullets, quotes, markdown, labels, or explanation.
    - Do not apologize, explain limitations, or restate the rules.
    - Keep each suggestion under 16 words.
    """
    private static let rulesWithList = rulesHead + "- End each line on a different word from the allowed list.\n" + rulesTail
    private static let rulesWithoutList = rulesHead + "- End each line on a different word.\n" + rulesTail

    private let lyrics = "[Verse]\nI keep the porch light on at home"
    private let target = "I keep the porch light on at home"

    private func localPrompt(
        complexity: RhymeComplexity = .moderate,
        targetLine: String?,
        wholeSong: Bool = true
    ) -> String {
        AIService().buildLocalSuggestionPromptForTest(
            theme: "",
            lyrics: lyrics,
            stanzaLines: ["[Verse]", target],
            targetRhymeLine: targetLine,
            rhymeType: .near,
            rhymeScheme: "AABB",
            currentLetter: "A",
            currentSection: .verse,
            sectionOrdinal: 1,
            firstChorusLines: nil,
            complexity: complexity,
            useWholeSongContext: wholeSong
        )
    }

    @Test func complexityHintsOnlyAskForWordplayAtComplex() {
        #expect(RhymeComplexity.simple.promptHint == "Use plain, simple, everyday language. No wordplay, puns, or clever twists. Use clear rhymes that are easy to hear.")
        #expect(RhymeComplexity.moderate.promptHint == "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear rather than clever.")
        #expect(RhymeComplexity.complex.promptHint == "Use advanced, rich vocabulary with clever wordplay and intricate rhymes: multi-syllable rhymes, internal rhymes, and double meanings.")
        #expect(!RhymeComplexity.moderate.promptHint.contains("wordplay"))
        #expect(RhymeComplexity.allCases.map(\.rawValue) == [0, 1, 2])

        for level in RhymeComplexity.allCases {
            #expect(localPrompt(complexity: level, targetLine: target)
                .contains("\nComplexity: \(level.label). \(level.promptHint)\n"))
            let cloud = AIService().buildPrompt(
                theme: "", lyrics: lyrics, targetRhymeLine: target, rhymeType: .near,
                rhymeScheme: "AABB", currentLetter: "A", currentSection: .verse,
                complexity: level, useWholeSongContext: true
            )
            #expect(cloud.contains("Complexity level: \(level.label). \(level.promptHint)"))
            #expect(!cloud.contains("some clever wordplay"))
        }
    }

    @Test func localPromptAsksForIdeasNotAFinishedVerse() {
        let prompt = localPrompt(targetLine: target)
        print("NEAR_CASE_PROMPT_BEGIN\n\(prompt)\nNEAR_CASE_PROMPT_END")

        #expect(prompt.contains("\nThe writer is stuck on the next line and wants ideas to pick from, not a finished verse.\n"))
        #expect(prompt.contains("End each line with one of these rhyming words: "))
        #expect(prompt.hasSuffix(Self.rulesWithList))
        // Parser-facing count and format rules are unchanged.
        #expect(prompt.contains("Task: write exactly 6 next-line options for the song."))
    }

    @Test func localPromptWithoutWordListAsksForDifferentEndWords() {
        let noTarget = localPrompt(targetLine: nil)
        #expect(noTarget.hasSuffix(Self.rulesWithoutList))
        #expect(!noTarget.contains("allowed list"))
    }

    private func numberedSong(_ range: ClosedRange<Int>) -> String {
        range.map { String(format: "line %04d of the song", $0) }.joined(separator: "\n")
    }

    @Test func localContextKeepsWholeSongWithinBudget() {
        // 130 lines = 2,859 characters: over 2,600 but within head + tail, so sent whole.
        let medium = numberedSong(1...130)
        #expect(medium.count == 2859)
        #expect(AIService.trimmedWholeSongContext(medium) == medium)

        // 300 lines = 6,599 characters: opening 900 and closing 2,200 characters, cut to whole lines.
        let long = numberedSong(1...300)
        #expect(AIService.trimmedWholeSongContext(long)
            == numberedSong(1...40) + "\n\n[Middle lyrics trimmed for on-device speed]\n\n" + numberedSong(201...300))
        #expect(AIService.trimmedWholeSongContext("  a\nb \n") == "a\nb")

        // The built prompt carries the trimmed context, not the whole long song.
        let prompt = AIService().buildLocalSuggestionPromptForTest(
            theme: "", lyrics: long, targetRhymeLine: nil, rhymeType: .near,
            rhymeScheme: "AABB", currentLetter: "A", currentSection: .unknown, sectionOrdinal: 1,
            firstChorusLines: nil, useWholeSongContext: true
        )
        #expect(prompt.contains("[Middle lyrics trimmed for on-device speed]"))
        #expect(!prompt.contains("line 0150 of the song"))
    }

    @Test func wholeSongContextDefaultsOnAndRespectsSavedValue() {
        let unset = UserDefaults(suiteName: UUID().uuidString)!
        #expect(EditorViewModel(defaults: unset).useWholeSongContext)

        let savedOff = UserDefaults(suiteName: UUID().uuidString)!
        savedOff.set(false, forKey: "editor.useWholeSongContext")
        #expect(!EditorViewModel(defaults: savedOff).useWholeSongContext)

        let viewModel = EditorViewModel(defaults: unset)
        viewModel.saveUseWholeSongContext(false)
        #expect(!EditorViewModel(defaults: unset).useWholeSongContext)
        viewModel.saveUseWholeSongContext(true)
        #expect(EditorViewModel(defaults: unset).useWholeSongContext)
    }
}
