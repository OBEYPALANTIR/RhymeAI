import Foundation

enum RhymePhonetics {
    static func rhymeKeys(for word: String, maxDepth: Int = 2) -> [String] {
        ProsodyAnalyzer.rhymeKeys(for: word, maxDepth: maxDepth)
    }
}
