import Foundation

nonisolated enum SyllableCounter {
    static func count(_ word: String) -> Int {
        ProsodyAnalyzer.countWord(word)
    }

    static func countText(_ text: String) -> Int {
        ProsodyAnalyzer.countText(text)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func lyricSyllableCount(_ lyrics: String) -> Int {
        countText(SectionMap.lyricContent(lyrics))
    }

    static func lyricWordCount(_ lyrics: String) -> Int {
        wordCount(SectionMap.lyricContent(lyrics))
    }
}
