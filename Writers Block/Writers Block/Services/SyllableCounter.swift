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
}
