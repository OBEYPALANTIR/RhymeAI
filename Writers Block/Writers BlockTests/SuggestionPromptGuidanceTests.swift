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
            let song: String
            let cursorLine: Int?
            let useWholeSongContext: Bool
            let expected: String
        }
        let songs: [String: String]
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
        let song = try #require(fixture.songs["main"])
        let lines = song.components(separatedBy: "\n")
        #expect(lines.count == 300)
        #expect(fixture.songs["oneLongLine"]?.utf16.count == 4000)
        #expect(fixture.songs["longMiddleLine"]?.components(separatedBy: "\n").map(\.utf16.count) == [14, 4000, 16])
        // iOS only trims whole-song context; with it off the cursor's stanza is sent untrimmed.
        let cases = fixture.cases.filter(\.useWholeSongContext)
        #expect(cases.count == 11)
        #expect(fixture.songs["emojiLine"]?.utf16.count == 4000) // 2,000 non-BMP scalars
        for testCase in cases {
            let actual = AIService.localLyricWindow(
                try #require(fixture.songs[testCase.song]),
                cursorLine: testCase.cursorLine,
                budget: AIService.localWholeSongHeadChars + AIService.localWholeSongTailChars,
                headBudget: AIService.localWholeSongHeadChars
            )
            #expect(actual == testCase.expected, "\(testCase.name)")
            #expect(actual.utf16.count <= 3100, "\(testCase.name)")
            guard testCase.song == "main" else { continue }
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
        viewModel.lyrics = song
        viewModel.cursorPosition = lines[0...cursorLine].reduce(0) { $0 + $1.utf16.count + 1 } - 1
        let input = viewModel.suggestionInputForTest()
        #expect(input.useWholeSongContext)
        #expect(input.cursorLineIndex == cursorLine)
        let prompt = AIService().buildLocalSuggestionPromptForTest(input: input)
        #expect(prompt.contains("\"\"\"\n" + middle.expected + "\n\"\"\""))
    }

    @Test func everyWindowStaysWithinBudget() throws {
        let fixture = try windowFixture()
        for (id, song) in fixture.songs {
            let lineCount = song.components(separatedBy: "\n").count
            for cursor in (0..<lineCount).map(Optional.some) + [nil] {
                let window = AIService.localLyricWindow(
                    song,
                    cursorLine: cursor,
                    budget: AIService.localWholeSongHeadChars + AIService.localWholeSongTailChars,
                    headBudget: AIService.localWholeSongHeadChars
                )
                #expect(window.utf16.count <= 3100, "\(id) cursor=\(String(describing: cursor))")
            }
        }
    }


    /// Chorus consistency wins over the level: first-chorus end words stay at the
    /// front of the allowed list at Simple and Complex, unfiltered by the level,
    /// and the rest of the list follows the level rule (levelEndWords is not
    /// reapplied after the merge).
    @Test func chorusHookWordsStayInFrontAtEveryLevel() throws {
        let targetLine = "Yellow lights on a midnight road"
        for (level, hooks) in [
            (RhymeComplexity.simple, ["code", "explode"]),
            (RhymeComplexity.complex, ["code", "explode"]),
            (RhymeComplexity.moderate, ["code"])
        ] {
            let constraint = try #require(AIService.rhymeConstraintWords(
                targetRhymeLine: targetLine, rhymeType: .perfect, currentSection: .chorus,
                firstChorusEndWords: hooks, complexity: level
            ))
            #expect(Array(constraint.words.prefix(hooks.count)) == hooks, "\(level.label) \(constraint.words)")
            let rest = Array(constraint.words.dropFirst(hooks.count))
            let levelList = RhymeConstraint.candidateEndWords(targetWord: "road", rhymeType: .perfect, complexity: level)
            #expect(rest == levelList.filter { !hooks.contains($0) }, "\(level.label) \(rest)")
            #expect(!rest.contains { hooks.contains($0) })
            switch level {
            case .simple:
                #expect(rest.allSatisfy { SyllableCounter.count($0) == 1 }, "\(rest)")
            case .complex:
                #expect(rest.allSatisfy { SyllableCounter.count($0) >= 2 }, "\(rest)")
                #expect(!levelList.contains("code"), "the Complex cut drops the one-syllable hook, the prepend keeps it")
            case .moderate:
                break
            }
            let block = try #require(AIService.rhymeConstraintBlock(
                targetRhymeLine: targetLine, rhymeType: .perfect, currentSection: .chorus,
                firstChorusEndWords: hooks, complexity: level
            ))
            #expect(block.contains("rhyming words: \(constraint.words.joined(separator: ", ")) (choose"))
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
