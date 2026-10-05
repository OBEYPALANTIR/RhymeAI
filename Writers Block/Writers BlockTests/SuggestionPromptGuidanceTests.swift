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

    private struct WindowFixture: Decodable {
        struct Case: Decodable {
            let name: String
            let cursorLine: Int?
            let useWholeSongContext: Bool
            let expected: String
        }
        let song: String
        let cases: [Case]
    }

    private final class BundleToken {}

    /// Bundled copy of shared/fixtures/local-lyric-window-v1.json (the simulator
    /// cannot read the repo). Android `SuggestionPromptGuidanceTest` checks the
    /// two copies are byte-identical and runs the same cases.
    private func windowFixture() throws -> WindowFixture {
        let url = try #require(Bundle(for: BundleToken.self)
            .url(forResource: "local-lyric-window-v1", withExtension: "json"))
        return try JSONDecoder().decode(WindowFixture.self, from: Data(contentsOf: url))
    }

    @Test func localContextMatchesSharedCursorWindowFixture() throws {
        let fixture = try windowFixture()
        let lines = fixture.song.components(separatedBy: "\n")
        #expect(lines.count == 300)
        // iOS only trims whole-song context; with it off the cursor's stanza is sent untrimmed.
        let cases = fixture.cases.filter(\.useWholeSongContext)
        #expect(cases.count == 5)
        for testCase in cases {
            let actual = AIService.localLyricWindow(
                fixture.song,
                cursorLine: testCase.cursorLine,
                budget: AIService.localWholeSongHeadChars + AIService.localWholeSongTailChars,
                headBudget: AIService.localWholeSongHeadChars
            )
            #expect(actual == testCase.expected, "\(testCase.name)")
            #expect(actual.utf16.count <= 3100, "\(testCase.name)")
            let c = testCase.cursorLine ?? lines.count - 1
            let start = (0..<c).last(where: { lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }).map { $0 + 1 } ?? 0
            let stanza = lines[start...c].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(actual.contains(stanza), "\(testCase.name)")
        }
        #expect(AIService.localLyricWindow("  a\nb \n", cursorLine: nil, budget: 3100, headBudget: 900) == "a\nb")

        // Production path: the editor cursor reaches the built prompt.
        let middle = try #require(fixture.cases.first { $0.name == "middle_lyric_whole" })
        let cursorLine = try #require(middle.cursorLine)
        let viewModel = EditorViewModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        viewModel.lyrics = fixture.song
        viewModel.cursorPosition = lines[0...cursorLine].reduce(0) { $0 + $1.utf16.count + 1 } - 1
        let input = viewModel.suggestionInputForTest()
        #expect(input.useWholeSongContext)
        #expect(input.cursorLineIndex == cursorLine)
        let prompt = AIService().buildLocalSuggestionPromptForTest(input: input)
        #expect(prompt.contains("\"\"\"\n" + middle.expected + "\n\"\"\""))
    }

    @Test func themeIsSentWithWholeSongContext() {
        let song = "[Verse]\nI keep the porch light on at home\nThe kettle ticks beside the phone"
        for wholeSong in [true, false] {
            let local = AIService().buildLocalSuggestionPromptForTest(
                theme: "  leaving a small town ", lyrics: song, stanzaLines: song.components(separatedBy: "\n"),
                targetRhymeLine: nil, rhymeType: .near, rhymeScheme: "AABB", currentLetter: "A",
                currentSection: .verse, sectionOrdinal: 1, firstChorusLines: nil, useWholeSongContext: wholeSong
            )
            #expect(local.contains("\nTheme: leaving a small town\n"))
            #expect(local.contains("The kettle ticks beside the phone"))
            let cloud = AIService().buildPrompt(
                theme: "leaving a small town", lyrics: song, targetRhymeLine: nil, rhymeType: .near,
                rhymeScheme: "AABB", currentLetter: "A", currentSection: .verse,
                complexity: .moderate, useWholeSongContext: wholeSong
            )
            #expect(cloud.contains("theme/context: \"leaving a small town\""))
            #expect(cloud.contains("The kettle ticks beside the phone") == wholeSong)
        }
        let empty = AIService().buildLocalSuggestionPromptForTest(
            theme: " ", lyrics: song, targetRhymeLine: nil, rhymeType: .near, rhymeScheme: "AABB",
            currentLetter: "A", currentSection: .verse, sectionOrdinal: 1, firstChorusLines: nil,
            useWholeSongContext: true
        )
        #expect(empty.contains("\nTheme: Infer from the lyrics.\n"))
        let emptyCloud = AIService().buildPrompt(
            theme: "", lyrics: song, targetRhymeLine: nil, rhymeType: .near, rhymeScheme: "AABB",
            currentLetter: "A", currentSection: .verse, complexity: .moderate, useWholeSongContext: true
        )
        #expect(emptyCloud.contains("Whole song context enabled; infer the theme from the full lyrics."))

        // The production input carries the theme with Whole Song Context on (the default).
        let viewModel = EditorViewModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        viewModel.lyrics = song
        viewModel.theme = "leaving a small town"
        viewModel.cursorPosition = (song as NSString).length
        let input = viewModel.suggestionInputForTest()
        #expect(input.useWholeSongContext)
        #expect(AIService().buildLocalSuggestionPromptForTest(input: input).contains("\nTheme: leaving a small town\n"))
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
