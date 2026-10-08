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
        // Simple and Complex carry the numeric targets measured in the 2026-10-07
        // complexity experiments; byte-identical on Android and in finetune/eval/prompts.py.
        #expect(RhymeComplexity.simple.promptHint == "Each line must be 4 to 7 plain, everyday words. Prefer one-syllable end words. No wordplay.")
        #expect(RhymeComplexity.moderate.promptHint == "Use a balanced vocabulary and natural, conversational phrasing. Keep the rhymes clear rather than clever.")
        #expect(RhymeComplexity.complex.promptHint == "Each line must be 8 to 12 words. End each line on a word of two or more syllables, or put an internal rhyme inside the line. Use vivid, specific, less common words and double meanings.")
        #expect(!RhymeComplexity.moderate.promptHint.contains("wordplay"))
        #expect(!RhymeComplexity.simple.promptHint.contains("double meanings"))
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

    /// The level shapes the allowed end-word list (`RhymeConstraint.levelEndWords`)
    /// and both prompt paths carry that list.
    @Test func complexityLevelReachesTheAllowedEndWordList() throws {
        let moderate = try #require(AIService.rhymeConstraintWords(targetRhymeLine: target, rhymeType: .perfect))
        let complex = try #require(AIService.rhymeConstraintWords(
            targetRhymeLine: target, rhymeType: .perfect, complexity: .complex
        ))
        let simple = try #require(AIService.rhymeConstraintWords(
            targetRhymeLine: target, rhymeType: .perfect, complexity: .simple
        ))
        #expect(moderate.words == RhymeConstraint.candidateEndWords(targetWord: "home", rhymeType: .perfect))
        #expect(moderate.words == AIService.rhymeConstraintWords(
            targetRhymeLine: target, rhymeType: .perfect, complexity: .moderate
        )?.words)
        #expect(complex.words == RhymeConstraint.candidateEndWords(targetWord: "home", rhymeType: .perfect, complexity: .complex))
        #expect(simple.words == RhymeConstraint.candidateEndWords(targetWord: "home", rhymeType: .perfect, complexity: .simple))
        #expect(complex.words.allSatisfy { SyllableCounter.count($0) >= 2 }, "\(complex.words)")
        #expect(simple.words.allSatisfy { SyllableCounter.count($0) == 1 }, "\(simple.words)")
        #expect(complex.words != moderate.words)
        #expect(simple.words != moderate.words)

        for (level, words) in [(RhymeComplexity.complex, complex.words), (RhymeComplexity.simple, simple.words)] {
            let listLine = "End each line with one of these rhyming words: \(words.joined(separator: ", ")) (choose the most natural fit)."
            let local = AIService().buildLocalSuggestionPromptForTest(
                theme: "", lyrics: lyrics, stanzaLines: ["[Verse]", target], targetRhymeLine: target,
                rhymeType: .perfect, rhymeScheme: "AABB", currentLetter: "A", currentSection: .verse,
                sectionOrdinal: 1, firstChorusLines: nil, complexity: level, useWholeSongContext: true
            )
            #expect(local.contains(listLine), "local \(level.label)")
            #expect(local.contains("\nComplexity: \(level.label). \(level.promptHint)\n"))
            let cloud = AIService().buildPrompt(
                theme: "", lyrics: lyrics, targetRhymeLine: target, rhymeType: .perfect,
                rhymeScheme: "AABB", currentLetter: "A", currentSection: .verse,
                complexity: level, useWholeSongContext: false
            )
            #expect(cloud.contains(listLine), "cloud \(level.label)")
        }
    }

    private static let fewerThanSixRule =
        "- The allowed list has fewer than six words, so end words may repeat, but the six lines must still be six different ideas."

    @Test func endWordRuleFollowsAllowedListSize() throws {
        let sixWords = ["phone", "alone", "known", "own", "show", "go"]
        #expect(AIService.localEndWordRule(allowedWords: nil) == "- End each line on a different word.")
        #expect(AIService.localEndWordRule(allowedWords: Array(sixWords.prefix(3))) == Self.fewerThanSixRule)
        #expect(AIService.localEndWordRule(allowedWords: Array(sixWords.prefix(5))) == Self.fewerThanSixRule)
        #expect(AIService.localEndWordRule(allowedWords: sixWords) == "- End each line on a different word from the allowed list.")
        // Repeated (chorus hook) words count once, case-folded.
        #expect(AIService.localEndWordRule(allowedWords: Array(repeating: "night", count: 6) + ["Night", "light", "bright"])
            == Self.fewerThanSixRule)

        // Built prompts: a short dictionary list relaxes the rule, a long one keeps it.
        let short = try #require(AIService.rhymeConstraintWords(targetRhymeLine: "I hold the silver", rhymeType: .perfect))
        #expect((1..<6).contains(short.words.count), "silver list: \(short.words)")
        let shortPrompt = AIService().buildLocalSuggestionPromptForTest(
            theme: "", lyrics: "I hold the silver", targetRhymeLine: "I hold the silver", rhymeType: .perfect,
            rhymeScheme: "AABB", currentLetter: "A", currentSection: .verse, sectionOrdinal: 1,
            firstChorusLines: nil, useWholeSongContext: true
        )
        #expect(shortPrompt.hasSuffix(Self.rulesHead + Self.fewerThanSixRule + "\n" + Self.rulesTail))
        let long = try #require(AIService.rhymeConstraintWords(targetRhymeLine: target, rhymeType: .near))
        #expect(long.words.count >= 6)
        #expect(localPrompt(targetLine: target).hasSuffix(Self.rulesWithList))

        // A second chorus prepends every first-chorus end word, repeats included: six
        // copies of "night" plus a short list still give fewer than six endings.
        try #require(short.words.count <= 4, "silver list: \(short.words)")
        let chorusLines = Array(repeating: "We own the night", count: 6)
        let hook = try #require(AIService.rhymeConstraintWords(
            targetRhymeLine: "I hold the silver", rhymeType: .perfect,
            currentSection: .chorus, firstChorusEndWords: AIService.endWords(of: chorusLines)
        ))
        #expect(hook.words.count >= 6)
        #expect(Set(hook.words.map { $0.lowercased() }).count < 6)
        let hookPrompt = AIService().buildLocalSuggestionPromptForTest(
            theme: "", lyrics: "I hold the silver", targetRhymeLine: "I hold the silver", rhymeType: .perfect,
            rhymeScheme: "AABB", currentLetter: "A", currentSection: .chorus, sectionOrdinal: 2,
            firstChorusLines: chorusLines, useWholeSongContext: true
        )
        #expect(hookPrompt.contains("rhyming words: night, night, night, night, night, night, "))
        #expect(hookPrompt.hasSuffix(Self.rulesHead + Self.fewerThanSixRule + "\n" + Self.rulesTail))
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
