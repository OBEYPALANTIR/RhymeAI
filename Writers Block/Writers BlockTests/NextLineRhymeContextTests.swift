import Foundation
import Testing
@testable import Writers_Block

/// One table for both platforms. The Android copy is `NextLineRhymeContextTest.kt`;
/// keep the rows identical. `|` marks the cursor. `after` is the text once the
/// suggestion "NEW" is accepted, with `|` where the cursor lands.
struct NextLineCase: Sendable {
    let id: String
    let scheme: String
    let lyrics: String
    let letter: String
    let anchor: String?
    let after: String

    static let all: [NextLineCase] = [
        // AABB
        .init(id: "aabb-end-of-line-1", scheme: "AABB", lyrics: "first light|", letter: "A", anchor: "first light", after: "first light\nNEW\n|"),
        .init(id: "aabb-end-of-line-2", scheme: "AABB", lyrics: "first light\nsecond night|", letter: "B", anchor: nil, after: "first light\nsecond night\nNEW\n|"),
        .init(id: "aabb-end-of-line-3", scheme: "AABB", lyrics: "one\ntwo\nthree|", letter: "B", anchor: "three", after: "one\ntwo\nthree\nNEW\n|"),
        .init(id: "aabb-start-of-line-2", scheme: "AABB", lyrics: "one\n|two", letter: "B", anchor: nil, after: "one\ntwo\nNEW\n|"),
        // ABAB, including the three reported defects
        .init(id: "abab-end-of-line-2", scheme: "ABAB", lyrics: "first glow\nsecond rain|", letter: "A", anchor: "first glow", after: "first glow\nsecond rain\nNEW\n|"),
        .init(id: "abab-empty-line-3", scheme: "ABAB", lyrics: "first glow\nsecond rain\n|", letter: "A", anchor: "first glow", after: "first glow\nsecond rain\nNEW\n|"),
        .init(id: "abab-mid-line-3-of-4", scheme: "ABAB", lyrics: "first glow\nsecond rain\nthi|rd road\nfourth rain", letter: "B", anchor: "second rain", after: "first glow\nsecond rain\nthird road\nNEW|\nfourth rain"),
        .init(id: "abab-end-of-line-3", scheme: "ABAB", lyrics: "first glow\nsecond rain\nthird road|", letter: "B", anchor: "second rain", after: "first glow\nsecond rain\nthird road\nNEW\n|"),
        .init(id: "abab-end-of-line-1", scheme: "ABAB", lyrics: "first glow|", letter: "B", anchor: nil, after: "first glow\nNEW\n|"),
        // ABCB
        .init(id: "abcb-end-of-line-2", scheme: "ABCB", lyrics: "one\ntwo|", letter: "C", anchor: nil, after: "one\ntwo\nNEW\n|"),
        .init(id: "abcb-end-of-line-3", scheme: "ABCB", lyrics: "one\ntwo\nthree|", letter: "B", anchor: "two", after: "one\ntwo\nthree\nNEW\n|"),
        // Custom schemes
        .init(id: "abba-end-of-line-2", scheme: "ABBA", lyrics: "one\ntwo|", letter: "B", anchor: "two", after: "one\ntwo\nNEW\n|"),
        .init(id: "abba-end-of-line-3", scheme: "ABBA", lyrics: "one\ntwo\nthree|", letter: "A", anchor: "one", after: "one\ntwo\nthree\nNEW\n|"),
        .init(id: "aabccb-empty-line-6", scheme: "AABCCB", lyrics: "one\ntwo\nthree\nfour\nfive\n|", letter: "B", anchor: "three", after: "one\ntwo\nthree\nfour\nfive\nNEW\n|"),
        // First line of a song
        .init(id: "first-line-empty-song", scheme: "BABA", lyrics: "|", letter: "B", anchor: nil, after: "NEW\n|"),
        .init(id: "first-line-under-header", scheme: "ABAB", lyrics: "[Verse 1]\n|", letter: "A", anchor: nil, after: "[Verse 1]\nNEW\n|"),
        .init(id: "first-line-cursor-on-header", scheme: "ABAB", lyrics: "[Ver|se 1]", letter: "A", anchor: nil, after: "[Verse 1]\nNEW\n|"),
        // Second stanza: after a blank line, after a header
        .init(id: "stanza-2-first-line-after-blank", scheme: "ABAB", lyrics: "one\ntwo\n\n|", letter: "A", anchor: nil, after: "one\ntwo\n\nNEW\n|"),
        .init(id: "stanza-2-second-line-after-blank", scheme: "AABB", lyrics: "one\ntwo\n\nthree|", letter: "A", anchor: "three", after: "one\ntwo\n\nthree\nNEW\n|"),
        .init(id: "stanza-2-new-sound-after-blank", scheme: "ABAB", lyrics: "one\ntwo\n\nthree|", letter: "B", anchor: nil, after: "one\ntwo\n\nthree\nNEW\n|"),
        .init(id: "stanza-2-first-line-after-header", scheme: "ABAB", lyrics: "one\ntwo\n[Chorus]\n|", letter: "A", anchor: nil, after: "one\ntwo\n[Chorus]\nNEW\n|"),
        .init(id: "stanza-2-third-line-after-header", scheme: "ABAB", lyrics: "one\ntwo\n[Chorus]\nthree\nfour|", letter: "A", anchor: "three", after: "one\ntwo\n[Chorus]\nthree\nfour\nNEW\n|"),
        .init(id: "stanza-2-after-blank-and-header", scheme: "AABB", lyrics: "one\ntwo\n\n[Chorus]\nthree|", letter: "A", anchor: "three", after: "one\ntwo\n\n[Chorus]\nthree\nNEW\n|"),
        .init(id: "stanza-1-line-before-later-stanza", scheme: "ABAB", lyrics: "one\ntwo|\n\nthree", letter: "A", anchor: "one", after: "one\ntwo\nNEW|\n\nthree"),
        .init(id: "separator-line-continues-stanza-1", scheme: "ABAB", lyrics: "one\ntwo\n|\nthree", letter: "A", anchor: "one", after: "one\ntwo\nNEW\n|\nthree"),
        .init(id: "whitespace-only-cursor-line", scheme: "ABAB", lyrics: "one\ntwo\n  |", letter: "A", anchor: "one", after: "one\ntwo\nNEW\n|"),
        .init(id: "whitespace-only-separator", scheme: "AABB", lyrics: "one\ntwo\n \nthree|", letter: "A", anchor: "three", after: "one\ntwo\n \nthree\nNEW\n|"),
        // Stanza longer than the scheme: the scheme repeats
        .init(id: "aabb-line-5-wraps", scheme: "AABB", lyrics: "one\ntwo\nthree\nfour|", letter: "A", anchor: "two", after: "one\ntwo\nthree\nfour\nNEW\n|"),
        .init(id: "aabb-line-6-wraps", scheme: "AABB", lyrics: "one\ntwo\nthree\nfour\nfive\n|", letter: "A", anchor: "five", after: "one\ntwo\nthree\nfour\nfive\nNEW\n|"),
        // Emoji before the cursor (UTF-16 offsets)
        .init(id: "emoji-end-of-line-2", scheme: "AABB", lyrics: "🔥🔥 first light\nsecond night|", letter: "B", anchor: nil, after: "🔥🔥 first light\nsecond night\nNEW\n|"),
        .init(id: "emoji-empty-line-3", scheme: "ABAB", lyrics: "🔥🔥 first glow\n🎵 second rain\n|", letter: "A", anchor: "🔥🔥 first glow", after: "🔥🔥 first glow\n🎵 second rain\nNEW\n|"),
        .init(id: "emoji-mid-line-1", scheme: "AABB", lyrics: "🔥🔥 fi|rst light\nsecond night", letter: "A", anchor: "🔥🔥 first light", after: "🔥🔥 first light\nNEW|\nsecond night"),
    ]

    var text: String { lyrics.replacingOccurrences(of: "|", with: "") }
    var cursor: Int { Self.utf16Offset(ofMarkerIn: lyrics) }
    var textAfter: String { after.replacingOccurrences(of: "|", with: "") }
    var cursorAfter: Int { Self.utf16Offset(ofMarkerIn: after) }

    private static func utf16Offset(ofMarkerIn marked: String) -> Int {
        (marked as NSString).range(of: "|").location
    }
}

@MainActor
struct NextLineRhymeContextTests {
    private func makeViewModel(for testCase: NextLineCase) -> EditorViewModel {
        let viewModel = EditorViewModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        viewModel.rhymeScheme = .custom
        viewModel.customRhymeScheme = testCase.scheme
        viewModel.lyrics = testCase.text
        viewModel.cursorPosition = testCase.cursor
        return viewModel
    }

    @Test func letterAndAnchorDescribeTheLineThatWillBeInserted() {
        for testCase in NextLineCase.all {
            let viewModel = makeViewModel(for: testCase)
            #expect(viewModel.activeRhymeScheme == testCase.scheme, "\(testCase.id)")

            let context = viewModel.computeRhymeContext()
            #expect(context.currentLetter == testCase.letter, "\(testCase.id) letter")
            #expect(context.targetLine == testCase.anchor, "\(testCase.id) anchor")

            let input = viewModel.suggestionInputForTest()
            #expect(input.currentLetter == testCase.letter, "\(testCase.id) model letter")
            #expect(input.targetRhymeLine == testCase.anchor, "\(testCase.id) model anchor")
        }
    }

    @Test func acceptedSuggestionLandsOnTheLineTheContextDescribed() {
        for testCase in NextLineCase.all {
            let viewModel = makeViewModel(for: testCase)

            viewModel.insertSuggestion("NEW")

            #expect(viewModel.lyrics == testCase.textAfter, "\(testCase.id) text")
            #expect(viewModel.cursorPosition == testCase.cursorAfter, "\(testCase.id) cursor")
            let inserted = viewModel.insertedLineRange.map { (viewModel.lyrics as NSString).substring(with: $0) }
            #expect(inserted == "NEW", "\(testCase.id) highlight")
        }
    }

    @Test func schemePreviewMarksTheNewLineWithTheLetterSentToTheModel() {
        for testCase in NextLineCase.all where !testCase.text.isEmpty {
            let viewModel = makeViewModel(for: testCase)
            let context = viewModel.computeRhymeContext()
            let rows = rhymeSchemeRows(context: context, scheme: testCase.scheme)
            let current = rows.filter(\.isCurrent)

            #expect(current.count == 1, "\(testCase.id) one current row")
            #expect(current.first?.letter == testCase.letter, "\(testCase.id) preview letter")
            #expect(current.first?.line.trimmingCharacters(in: .whitespaces).isEmpty == true, "\(testCase.id) preview row is the new line")

            // Every earlier row with the new line's letter, back to the stanza start, ends at the anchor.
            let currentIndex = rows.firstIndex(where: \.isCurrent) ?? 0
            let stanzaStart = rows[..<currentIndex].lastIndex { $0.letter == nil }.map { $0 + 1 } ?? 0
            let previewAnchor = rows[stanzaStart..<currentIndex].last { $0.letter == testCase.letter }?.line
            #expect(previewAnchor == testCase.anchor, "\(testCase.id) preview anchor")
        }
    }

    @Test func promptsNameTheInsertedLinesLetterAndAnchor() {
        let cases = NextLineCase.all.filter { ["abab-end-of-line-2", "abab-empty-line-3", "abab-mid-line-3-of-4"].contains($0.id) }
        #expect(cases.count == 3)
        for testCase in cases {
            let input = makeViewModel(for: testCase).suggestionInputForTest()
            let prompt = AIService().buildLocalSuggestionPromptForTest(input: input)
            let anchor = testCase.anchor ?? ""

            #expect(prompt.contains("Rhyme scheme: \"ABAB\"; next line is \"\(testCase.letter)\"."), "\(testCase.id)")
            #expect(prompt.contains("with: \"\(anchor)\""), "\(testCase.id)")
            #expect(!prompt.contains("Start a new rhyme sound"), "\(testCase.id)")
        }
    }
}
