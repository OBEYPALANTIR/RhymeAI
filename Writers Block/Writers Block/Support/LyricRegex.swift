import Foundation

nonisolated enum LyricRegex {
    // Curly (U+2019) and modifier (U+02BC) apostrophes are the same word
    // character as the straight one; `ProsodyAnalyzer.normalizeWord` folds them.
    static let word = try! NSRegularExpression(pattern: "[a-zA-Z'\u{2019}\u{02BC}]+")
    static let alphanumericWord = try! NSRegularExpression(pattern: "[a-zA-Z0-9'\u{2019}\u{02BC}]+")
    // Internal straight or curly apostrophes stay in the word ("you're", "band's");
    // trailing quotes and punctuation fall to the third group.
    static let lastWord = try! NSRegularExpression(pattern: "(.*?)(\\b\\w+(?:['\u{2019}]\\w+)*)([^\\w]*)$")
}
