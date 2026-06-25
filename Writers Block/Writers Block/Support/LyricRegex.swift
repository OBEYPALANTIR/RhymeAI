import Foundation

nonisolated enum LyricRegex {
    static let word = try! NSRegularExpression(pattern: "[a-zA-Z']+")
    static let alphanumericWord = try! NSRegularExpression(pattern: "[a-zA-Z0-9']+")
    static let lastWord = try! NSRegularExpression(pattern: "(.*?)(\\b\\w+\\b)([^\\w]*)$")
}
