import XCTest
@testable import Writers_Block

final class RhymeSchemeRowsTests: XCTestCase {
    private func rows(_ lines: [String], current: Int, scheme: String, currentLetter: String = "C") -> [RhymeSchemeRow] {
        let context = RhymeContext(
            targetLine: nil,
            currentLetter: currentLetter,
            stanzaLines: lines,
            currentLineIndex: current,
            currentSection: .verse,
            sectionOrdinal: 1,
            firstChorusLines: nil
        )
        return rhymeSchemeRows(context: context, scheme: scheme)
    }

    func testAndroidHeaderAndCurrentBlankFixture() {
        let result = rows(["[Verse 1]", "first", "", "second"], current: 2, scheme: "AB")
        XCTAssertEqual(result.map(\.letter), [nil, "A", "C", "B"])
        XCTAssertEqual(result.map(\.isCurrent), [false, false, true, false])
        XCTAssertEqual(result.map(\.line), ["[Verse 1]", "first", "", "second"])
    }

    func testHeadersRestartTheSchemeAndNonCurrentBlanksDoNotConsumeLetters() {
        let result = rows(["first", "second", "  [Chorus]  ", " ", "third", "fourth", "Bridge", "fifth"], current: 7, scheme: "ABC")
        XCTAssertEqual(result.map(\.letter), ["A", "B", nil, nil, "A", "B", nil, "A"])
        XCTAssertTrue(result[7].isCurrent)
    }

    func testWhitespaceOnlyCurrentLineUsesCurrentLetterWithoutConsumingNextLyric() {
        let result = rows(["first", "\t \n", "second"], current: 1, scheme: "AB", currentLetter: "Z")
        XCTAssertEqual(result.map(\.letter), ["A", "Z", "B"])
        XCTAssertEqual(result.map(\.isCurrent), [false, true, false])
    }

    func testEmptySchemeOrEmptyStanzaReturnsNoRows() {
        XCTAssertTrue(rows(["first"], current: 0, scheme: "").isEmpty)
        XCTAssertTrue(rows([], current: 0, scheme: "AB").isEmpty)
    }

    func testLyricsWrapWithoutCountingBlankRowsAndRestartAfterHeader() {
        let result = rows(["one", "[Verse]", "two", "", "three", "four", "five"], current: 0, scheme: "AB")
        XCTAssertEqual(result.map(\.letter), ["A", nil, "A", nil, "B", "A", "B"])
    }
}
