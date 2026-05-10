import Foundation

enum RhymePhonetics {
    private static let vowelLetters: Set<Character> = ["a", "e", "i", "o", "u"]

    private static let substitutions: [(String, String)] = [
        ("tion", "shn"),
        ("sion", "shn"),
        ("cion", "shn"),
        ("cian", "shn"),
        ("tial", "shl"),
        ("cial", "shl"),
        ("ough", "of"),
        ("augh", "af"),
        ("eigh", "ay"),
        ("ight", "ite"),
        ("ph", "f"),
        ("ck", "k"),
        ("qu", "kw"),
        ("wh", "w"),
        ("x", "ks")
    ]

    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were",
        "be", "to", "of", "in", "on", "at", "by", "for", "with", "as",
        "it", "its", "this", "that", "these", "those", "i", "you", "he",
        "she", "we", "they", "them", "his", "her", "our", "their", "my",
        "do", "does", "did", "have", "has", "had", "not", "if", "so", "no"
    ]

    static func rhymeKeys(for word: String, maxDepth: Int = 2) -> [String] {
        guard let cleaned = normalize(word) else { return [] }
        if stopwords.contains(cleaned) { return [] }
        let phonetic = applyPhonetics(cleaned)
        let starts = vowelGroupStarts(in: phonetic)
        guard !starts.isEmpty else { return [] }

        let depthMax = min(maxDepth, starts.count)
        var keys: [String] = []
        for depth in 1...depthMax {
            let startIndexInt = starts[starts.count - depth]
            let startIdx = phonetic.index(phonetic.startIndex, offsetBy: startIndexInt)
            keys.append(String(phonetic[startIdx...]))
        }
        return keys
    }

    private static func normalize(_ word: String) -> String? {
        let lower = word.lowercased()
        let filtered = String(lower.filter { $0.isLetter })
        return filtered.count >= 2 ? filtered : nil
    }

    private static func applyPhonetics(_ input: String) -> String {
        var w = input
        for (from, to) in substitutions {
            if w.contains(from) {
                w = w.replacingOccurrences(of: from, with: to)
            }
        }
        if w.count > 2,
           w.hasSuffix("e"),
           !w.hasSuffix("le"),
           w.dropLast().contains(where: { isVowel($0, atStart: false) }) {
            w = String(w.dropLast())
        }
        return w
    }

    private static func vowelGroupStarts(in word: String) -> [Int] {
        var starts: [Int] = []
        var inGroup = false
        for (i, ch) in word.enumerated() {
            let v = isVowel(ch, atStart: i == 0)
            if v && !inGroup { starts.append(i) }
            inGroup = v
        }
        return starts
    }

    private static func isVowel(_ ch: Character, atStart: Bool) -> Bool {
        if vowelLetters.contains(ch) { return true }
        if ch == "y" { return !atStart }
        return false
    }
}
