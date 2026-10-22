import Foundation

nonisolated enum LyricRegex {
    static let word = try! NSRegularExpression(pattern: "[a-zA-Z']+")
    static let alphanumericWord = try! NSRegularExpression(pattern: "[a-zA-Z0-9']+")
    // Internal straight or curly apostrophes stay in the word ("you're", "band's");
    // trailing quotes and punctuation fall to the third group.
    static let lastWord = try! NSRegularExpression(pattern: "(.*?)(\\b\\w+(?:['\u{2019}]\\w+)*)([^\\w]*)$")
}
