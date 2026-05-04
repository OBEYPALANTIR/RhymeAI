import Foundation

enum SyllableCounter {

    static func count(_ word: String) -> Int {
        let w = word.lowercased().trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return 0 }
        if w.count <= 2 { return 1 }

        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var count = 0
        var prevVowel = false

        for ch in w {
            let isVowel = vowels.contains(ch)
            if isVowel && !prevVowel {
                count += 1
            }
            prevVowel = isVowel
        }

        // Silent 'e' at end
        if w.hasSuffix("e") && !w.hasSuffix("le") && count > 1 {
            count -= 1
        }
        // -les suffix
        if w.hasSuffix("les") && w.count > 4 && count > 1 {
            count -= 1
        }
        // -es suffix (not -ses or -zes)
        if w.hasSuffix("es") && !w.hasSuffix("ses") && !w.hasSuffix("zes") && count > 1 {
            count -= 1
        }
        // -ed suffix (not -ted or -ded)
        if w.hasSuffix("ed") && !w.hasSuffix("ted") && !w.hasSuffix("ded") && count > 1 {
            count -= 1
        }

        return max(count, 1)
    }

    private static let wordPattern = try! NSRegularExpression(pattern: "[a-zA-Z']+")

    static func countText(_ text: String) -> Int {
        let nsText = text as NSString
        let matches = wordPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.reduce(0) { total, match in
            let word = nsText.substring(with: match.range)
            return total + count(word)
        }
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace }.filter { !$0.isEmpty }.count
    }
}
