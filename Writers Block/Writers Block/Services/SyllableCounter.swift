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

    /// `lyricSyllableCount` without the line's stress, feet and IPA, which the
    /// header does not show; nil once the calling task is cancelled.
    static func cancellableLyricSyllableCount(_ lyrics: String) -> Int? {
        let content = SectionMap.lyricContent(lyrics)
        let nsContent = content as NSString
        let words = LyricRegex.word.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        var total = 0
        for (index, word) in words.enumerated() {
            if index.isMultiple(of: 32), Task.isCancelled { return nil }
            total += count(nsContent.substring(with: word.range))
        }
        return total
    }

    static func lyricWordCount(_ lyrics: String) -> Int {
        wordCount(SectionMap.lyricContent(lyrics))
    }
}
