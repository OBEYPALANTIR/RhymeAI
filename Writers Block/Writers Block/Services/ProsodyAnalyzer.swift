import Foundation

struct WordProsody: Equatable, Sendable {
    let word: String
    let normalized: String
    let syllableCount: Int
    let stressPattern: [Int]
    let ipa: String
    let isFallback: Bool
}

struct LineProsody: Equatable, Sendable {
    let words: [WordProsody]
    let syllableCount: Int
    let stressPattern: [Int]
    let feet: String
    let ipa: String
}

nonisolated struct RhymeMatches: Equatable, Sendable {
    let perfect: [String]
    let near: [String]
    let slant: [String]
    let multi: [String]

    var isEmpty: Bool { perfect.isEmpty && near.isEmpty && slant.isEmpty && multi.isEmpty }

    static let empty = RhymeMatches(perfect: [], near: [], slant: [], multi: [])
}

nonisolated struct RhymeTail: Equatable, Hashable, Sendable {
    let vowel: String
    let coda: [String]
}

private struct RhymeTailEntry {
    let word: String
    let tail: RhymeTail
}

nonisolated final class RhymeIndex: @unchecked Sendable {
    static let shared = RhymeIndex()

    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var builtForWordCount: Int = -1
    nonisolated(unsafe) private var perfectByKey: [String: [String]] = [:]
    nonisolated(unsafe) private var multiByKey: [String: [String]] = [:]
    nonisolated(unsafe) private var nearByVowel: [String: [RhymeTailEntry]] = [:]
    nonisolated(unsafe) private var slantByCoda: [String: [RhymeTailEntry]] = [:]

    nonisolated func find(
        word: String,
        perfectLimit: Int = 60,
        nearLimit: Int = 30,
        multiLimit: Int = 30,
        dictionary: PronunciationDictionary = .shared,
        wordFrequency: WordFrequency = .shared
    ) -> RhymeMatches {
        let normalized = ProsodyAnalyzer.normalizeWord(word)
        guard normalized.count >= 2 else { return .empty }
        guard dictionary.wordCount > 0 else { return .empty }

        let keys = ProsodyAnalyzer.rhymeKeys(for: word, maxDepth: 2, dictionary: dictionary)
        guard let k0 = keys.first else { return .empty }
        let k1 = keys.count > 1 ? keys[1] : nil
        guard let targetTail = ProsodyAnalyzer.rhymeTail(for: word, dictionary: dictionary) else {
            return .empty
        }

        ensureBuilt(dictionary: dictionary)
        lock.lock()
        let perfectMap = perfectByKey
        let multiMap = multiByKey
        let nearMap = nearByVowel
        let slantMap = slantByCoda
        lock.unlock()

        let perfectAll = (perfectMap[k0] ?? []).filter { $0 != normalized }
        let multiAll: [String]
        if let k1 {
            let perfectSet = Set(perfectAll)
            multiAll = (multiMap[k1] ?? []).filter { $0 != normalized && !perfectSet.contains($0) }
        } else {
            multiAll = []
        }
        let exclude = Set(perfectAll).union(multiAll)
        let nearAll = Self.uniqueWords((nearMap[targetTail.vowel] ?? []).compactMap { entry in
            guard entry.word != normalized,
                  !exclude.contains(entry.word),
                  ProsodyAnalyzer.hasSingleCodaEdit(targetTail.coda, entry.tail.coda) else {
                return nil
            }
            return entry.word
        })
        let slantAll: [String]
        if targetTail.coda.isEmpty {
            slantAll = []
        } else {
            let nearSet = Set(nearAll)
            slantAll = Self.uniqueWords((slantMap[Self.codaKey(targetTail.coda)] ?? []).compactMap { entry in
                guard entry.word != normalized,
                      entry.tail.vowel != targetTail.vowel,
                      !exclude.contains(entry.word),
                      !nearSet.contains(entry.word) else {
                    return nil
                }
                return entry.word
            })
        }

        // Re-rank each pool by word frequency (most common first) before the
        // limit cut, so both candidateEndWords and the rhyme inspector surface
        // familiar words rather than dictionary-hash-order obscurities.
        return RhymeMatches(
            perfect: Array(wordFrequency.sortByFrequency(perfectAll).prefix(perfectLimit)),
            near: Array(wordFrequency.sortByFrequency(nearAll).prefix(nearLimit)),
            slant: Array(wordFrequency.sortByFrequency(slantAll).prefix(nearLimit)),
            multi: Array(wordFrequency.sortByFrequency(multiAll).prefix(multiLimit))
        )
    }

    nonisolated private func ensureBuilt(dictionary: PronunciationDictionary) {
        // Hold the lock for the whole build: releasing it here let two concurrent
        // first-callers each scan the full dictionary. Callers are off-main and a
        // second caller would have to wait for the index anyway.
        lock.lock()
        defer { lock.unlock() }
        if builtForWordCount == dictionary.wordCount {
            return
        }

        var perfectBuild: [String: [String]] = [:]
        var multiBuild: [String: [String]] = [:]
        var nearBuild: [String: [RhymeTailEntry]] = [:]
        var slantBuild: [String: [RhymeTailEntry]] = [:]
        perfectBuild.reserveCapacity(32_768)
        multiBuild.reserveCapacity(32_768)
        nearBuild.reserveCapacity(64)

        dictionary.forEachEntry { word, variants in
            guard word.count >= 2 else { return }
            var seenK0 = Set<String>()
            var seenK1 = Set<String>()
            var seenTails = Set<RhymeTail>()
            for phones in variants {
                let ks = ProsodyAnalyzer.rhymeKeysForPhonesPublic(phones, maxDepth: 2)
                guard let k0 = ks.first else { continue }
                if seenK0.insert(k0).inserted {
                    perfectBuild[k0, default: []].append(word)
                }
                if let tail = ProsodyAnalyzer.rhymeTailForPhonesPublic(phones), seenTails.insert(tail).inserted {
                    let entry = RhymeTailEntry(word: word, tail: tail)
                    nearBuild[tail.vowel, default: []].append(entry)
                    if !tail.coda.isEmpty {
                        slantBuild[Self.codaKey(tail.coda), default: []].append(entry)
                    }
                }
                if ks.count > 1 {
                    let k1 = ks[1]
                    if seenK1.insert(k1).inserted {
                        multiBuild[k1, default: []].append(word)
                    }
                }
            }
        }

        perfectByKey = perfectBuild
        multiByKey = multiBuild
        nearByVowel = nearBuild
        slantByCoda = slantBuild
        builtForWordCount = dictionary.wordCount
    }

    private static func codaKey(_ coda: [String]) -> String {
        coda.joined(separator: " ")
    }

    private static func uniqueWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
    }
}

private final class PronunciationBundleMarker: NSObject {}

nonisolated struct PronunciationDictionary: Sendable {
    private let entries: [String: [[String]]]

    static let shared = PronunciationDictionary.loadBundled()

    init(entries: [String: [[String]]]) {
        self.entries = entries
    }

    func pronunciations(for normalizedWord: String) -> [[String]] {
        entries[normalizedWord] ?? []
    }

    var wordCount: Int { entries.count }

    func forEachEntry(_ action: (String, [[String]]) -> Void) {
        for (word, variants) in entries { action(word, variants) }
    }

    static func fromLines<S: Sequence>(_ lines: S) -> PronunciationDictionary where S.Element == String {
        var parsed: [String: [[String]]] = [:]
        for row in lines {
            guard !row.isEmpty, !row.hasPrefix("#"),
                  let tabIndex = row.firstIndex(of: "\t") else {
                continue
            }

            let word = String(row[..<tabIndex])
            let variants = row[row.index(after: tabIndex)...]
                .split(separator: "|")
                .map { variant in
                    variant.split(whereSeparator: \.isWhitespace).map(String.init)
                }
                .filter { !$0.isEmpty }

            if !variants.isEmpty {
                parsed[word] = variants
            }
        }
        return PronunciationDictionary(entries: parsed)
    }

    private static func loadBundled() -> PronunciationDictionary {
        let bundles = [Bundle.main, Bundle(for: PronunciationBundleMarker.self)]
        for bundle in bundles {
            guard let url = bundle.url(forResource: "cmudict-rhymeai", withExtension: "tsv"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            return fromLines(text.components(separatedBy: .newlines))
        }
        return PronunciationDictionary(entries: [:])
    }
}

nonisolated enum LexicalWordValidator {
    static func isKnownSpelling(_ word: String) -> Bool {
        let spelling = canonicalSpelling(word)
        let dictionaryKey = ProsodyAnalyzer.normalizeWord(spelling)
        return spelling == dictionaryKey
            && !PronunciationDictionary.shared.pronunciations(for: dictionaryKey).isEmpty
    }

    private static func canonicalSpelling(_ word: String) -> String {
        word.precomposedStringWithCompatibilityMapping.unicodeScalars.reduce(into: "") { result, scalar in
            switch scalar.value {
            case 0x2018, 0x2019, 0x02BC, 0xFF07:
                result.append("'")
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212:
                result.append("-")
            default:
                result.unicodeScalars.append(scalar)
            }
        }.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

nonisolated enum ProsodyAnalyzer {
    private static let vowels: Set<String> = [
        "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY",
        "OW", "OY", "UH", "UW"
    ]
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were",
        "be", "to", "of", "in", "on", "at", "by", "for", "with", "as",
        "it", "its", "this", "that", "these", "those", "i", "you", "he",
        "she", "we", "they", "them", "his", "her", "our", "their", "my",
        "do", "does", "did", "have", "has", "had", "not", "if", "so", "no"
    ]
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
    private static let ipaByPhone: [String: String] = [
        "AA": "ɑ",
        "AE": "æ",
        "AH": "ʌ",
        "AO": "ɔ",
        "AW": "aʊ",
        "AY": "aɪ",
        "EH": "ɛ",
        "ER": "ɝ",
        "EY": "eɪ",
        "IH": "ɪ",
        "IY": "i",
        "OW": "oʊ",
        "OY": "ɔɪ",
        "UH": "ʊ",
        "UW": "u",
        "B": "b",
        "CH": "tʃ",
        "D": "d",
        "DH": "ð",
        "F": "f",
        "G": "ɡ",
        "HH": "h",
        "JH": "dʒ",
        "K": "k",
        "L": "l",
        "M": "m",
        "N": "n",
        "NG": "ŋ",
        "P": "p",
        "R": "r",
        "S": "s",
        "SH": "ʃ",
        "T": "t",
        "TH": "θ",
        "V": "v",
        "W": "w",
        "Y": "j",
        "Z": "z",
        "ZH": "ʒ"
    ]

    static func analyzeWord(
        _ word: String,
        dictionary: PronunciationDictionary = .shared
    ) -> WordProsody {
        let normalized = normalizeWord(word)
        guard !normalized.isEmpty else {
            return WordProsody(word: word, normalized: normalized, syllableCount: 0, stressPattern: [], ipa: "", isFallback: true)
        }

        let variants = dictionary.pronunciations(for: normalized)
        guard let phones = variants.first else {
            let stressPattern = fallbackStressPattern(for: normalized)
            return WordProsody(
                word: word,
                normalized: normalized,
                syllableCount: stressPattern.count,
                stressPattern: stressPattern,
                ipa: "",
                isFallback: true
            )
        }

        let stressPattern = stressPatternForPhones(phones)
        return WordProsody(
            word: word,
            normalized: normalized,
            syllableCount: stressPattern.count,
            stressPattern: stressPattern,
            ipa: ipaForPhones(phones),
            isFallback: false
        )
    }

    static func analyzeLine(
        _ text: String,
        dictionary: PronunciationDictionary = .shared
    ) -> LineProsody {
        let nsText = text as NSString
        let words = LyricRegex.word.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map { match in
            analyzeWord(nsText.substring(with: match.range), dictionary: dictionary)
        }
        let stressPattern = words.flatMap(\.stressPattern)
        return LineProsody(
            words: words,
            syllableCount: words.reduce(0) { $0 + $1.syllableCount },
            stressPattern: stressPattern,
            feet: metricFeet(stressPattern),
            ipa: words.compactMap { word in
                let display = word.ipa.isEmpty ? word.normalized : word.ipa
                return display.isEmpty ? nil : display
            }.joined(separator: " ")
        )
    }

    static func countWord(_ word: String) -> Int {
        analyzeWord(word).syllableCount
    }

    static func countText(_ text: String) -> Int {
        analyzeLine(text).syllableCount
    }

    static func findRhymes(
        for word: String,
        perfectLimit: Int = 60,
        nearLimit: Int = 30,
        multiLimit: Int = 30,
        dictionary: PronunciationDictionary = .shared
    ) -> RhymeMatches {
        RhymeIndex.shared.find(
            word: word,
            perfectLimit: perfectLimit,
            nearLimit: nearLimit,
            multiLimit: multiLimit,
            dictionary: dictionary
        )
    }

    static func rhymeKeysForPhonesPublic(_ phones: [String], maxDepth: Int) -> [String] {
        rhymeKeysForPhones(phones, maxDepth: maxDepth)
    }

    static func rhymeTailForPhonesPublic(_ phones: [String]) -> RhymeTail? {
        rhymeTailForPhones(phones)
    }

    static func rhymeTail(
        for word: String,
        dictionary: PronunciationDictionary = .shared
    ) -> RhymeTail? {
        let normalized = normalizeWord(word)
        guard normalized.count >= 2, !stopwords.contains(normalized) else { return nil }
        return dictionary.pronunciations(for: normalized).first.flatMap(rhymeTailForPhones)
    }

    static func rhymeRelation(
        candidateWord: String,
        targetWord: String,
        dictionary: PronunciationDictionary = .shared
    ) -> RhymeType? {
        let normalizedCandidate = normalizeWord(candidateWord)
        let normalizedTarget = normalizeWord(targetWord)
        guard normalizedCandidate != normalizedTarget,
              let targetPhones = dictionary.pronunciations(for: normalizedTarget).first,
              let targetTail = rhymeTailForPhones(targetPhones) else {
            return nil
        }

        let targetKeys = rhymeKeysForPhones(targetPhones, maxDepth: 2)
        guard let targetKey = targetKeys.first else { return nil }
        let targetMultiKey = targetKeys.dropFirst().first
        var near = false
        var slant = false
        for candidatePhones in dictionary.pronunciations(for: normalizedCandidate) {
            let candidateKeys = rhymeKeysForPhones(candidatePhones, maxDepth: 2)
            if candidateKeys.first == targetKey ||
                (targetMultiKey != nil && candidateKeys.dropFirst().first == targetMultiKey) {
                return .perfect
            }
            guard let candidateTail = rhymeTailForPhones(candidatePhones) else { continue }
            if candidateTail.vowel == targetTail.vowel,
               hasSingleCodaEdit(targetTail.coda, candidateTail.coda) {
                near = true
            } else if !targetTail.coda.isEmpty,
                      candidateTail.vowel != targetTail.vowel,
                      candidateTail.coda == targetTail.coda {
                slant = true
            }
        }
        if near { return .near }
        if slant { return .slant }
        return nil
    }

    static func hasSingleCodaEdit(_ lhs: [String], _ rhs: [String]) -> Bool {
        let difference = lhs.count - rhs.count
        guard abs(difference) <= 1 else { return false }
        if difference == 0 {
            return zip(lhs, rhs).filter { $0.0 != $0.1 }.count == 1
        }

        let shorter = lhs.count < rhs.count ? lhs : rhs
        let longer = lhs.count < rhs.count ? rhs : lhs
        var shortIndex = 0
        var longIndex = 0
        var skipped = false
        while shortIndex < shorter.count, longIndex < longer.count {
            if shorter[shortIndex] == longer[longIndex] {
                shortIndex += 1
                longIndex += 1
            } else if skipped {
                return false
            } else {
                skipped = true
                longIndex += 1
            }
        }
        return true
    }

    static func rhymeKeys(
        for word: String,
        maxDepth: Int = 2,
        dictionary: PronunciationDictionary = .shared
    ) -> [String] {
        let normalized = normalizeWord(word)
        guard normalized.count >= 2, !stopwords.contains(normalized) else {
            return []
        }

        let variants = dictionary.pronunciations(for: normalized)
        guard !variants.isEmpty else {
            return fallbackRhymeKeys(for: normalized, maxDepth: maxDepth)
        }

        var keys: [String] = []
        for phones in variants {
            for key in rhymeKeysForPhones(phones, maxDepth: maxDepth) where !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    static func metricFeet(_ stressPattern: [Int]) -> String {
        stressPattern.map { stress in
            switch stress {
            case 1: return "ˈDA"
            case 2: return "ˌDA"
            default: return "da"
            }
        }.joined(separator: " ")
    }

    static func normalizeWord(_ word: String) -> String {
        let scalars = word.lowercased().unicodeScalars.filter { scalar in
            (97...122).contains(Int(scalar.value)) || scalar.value == 39
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    }

    private static func basePhone(_ phone: String) -> String {
        phone.replacingOccurrences(of: "[0-2]$", with: "", options: .regularExpression)
    }

    private static func stressForPhone(_ phone: String) -> Int? {
        guard let last = phone.last, let value = last.wholeNumberValue, (0...2).contains(value) else {
            return nil
        }
        return value
    }

    private static func stressPatternForPhones(_ phones: [String]) -> [Int] {
        phones.compactMap(stressForPhone)
    }

    private static func ipaForPhones(_ phones: [String]) -> String {
        let vowelIndexes = phones.indices.filter { vowels.contains(basePhone(phones[$0])) }
        var markers: [Int: String] = [:]

        for (vowelOffset, phoneIndex) in vowelIndexes.enumerated() {
            guard let stress = stressForPhone(phones[phoneIndex]), stress > 0 else {
                continue
            }
            let previousVowel = vowelOffset > 0 ? vowelIndexes[vowelOffset - 1] : nil
            let onsetIndex = previousVowel.map { $0 + 1 } ?? 0
            markers[onsetIndex] = stress == 1 ? "ˈ" : "ˌ"
        }

        return phones.indices.map { index in
            (markers[index] ?? "") + ipaForPhone(phones[index])
        }.joined()
    }

    private static func ipaForPhone(_ phone: String) -> String {
        let base = basePhone(phone)
        let stress = stressForPhone(phone)
        if base == "AH", stress == 0 { return "ə" }
        if base == "ER", stress == 0 { return "ɚ" }
        return ipaByPhone[base] ?? base.lowercased()
    }

    private static func fallbackStressPattern(for word: String) -> [Int] {
        let count = fallbackSyllableCount(word)
        guard count > 0 else { return [] }
        return (0..<count).map { $0 == 0 ? 1 : 0 }
    }

    private static func fallbackSyllableCount(_ word: String) -> Int {
        let w = normalizeWord(word)
        guard !w.isEmpty else { return 0 }
        if w.count <= 2 { return 1 }

        var count = 0
        var previousWasVowel = false
        let vowels = Set("aeiouy")

        for ch in w {
            let isVowel = vowels.contains(ch)
            if isVowel, !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }

        let syllabicLe: Bool = {
            if w.hasSuffix("le"), w.count >= 3 {
                return !vowels.contains(w[w.index(w.endIndex, offsetBy: -3)])
            }
            if w.hasSuffix("les"), w.count >= 4 {
                return !vowels.contains(w[w.index(w.endIndex, offsetBy: -4)])
            }
            return false
        }()

        if !syllabicLe {
            if w.hasSuffix("e"), count > 1 {
                count -= 1
            } else if w.hasSuffix("es"), !w.hasSuffix("ses"), !w.hasSuffix("zes"), count > 1 {
                count -= 1
            }
        }
        if w.hasSuffix("ed"), !w.hasSuffix("ted"), !w.hasSuffix("ded"), count > 1 { count -= 1 }

        return max(count, 1)
    }

    private static func fallbackRhymeKeys(for word: String, maxDepth: Int) -> [String] {
        var phonetic = normalizeWord(word)
        guard phonetic.count >= 2, !stopwords.contains(phonetic) else {
            return []
        }

        for (from, to) in substitutions {
            phonetic = phonetic.replacingOccurrences(of: from, with: to)
        }
        if phonetic.count > 2, phonetic.hasSuffix("e"), !phonetic.hasSuffix("le") {
            phonetic.removeLast()
        }

        var starts: [String.Index] = []
        var inGroup = false
        for index in phonetic.indices {
            let ch = phonetic[index]
            let offset = phonetic.distance(from: phonetic.startIndex, to: index)
            let isVowel = "aeiou".contains(ch) || (ch == "y" && offset > 0)
            if isVowel, !inGroup { starts.append(index) }
            inGroup = isVowel
        }

        return starts.suffix(maxDepth).reversed().map { String(phonetic[$0...]) }
    }

    private static func rhymeKeysForPhones(_ phones: [String], maxDepth: Int) -> [String] {
        let vowelIndexes = phones.indices.filter { vowels.contains(basePhone(phones[$0])) }
        guard !vowelIndexes.isEmpty else { return [] }

        let stressed = vowelIndexes.filter { (stressForPhone(phones[$0]) ?? 0) > 0 }
        let anchors = stressed.isEmpty ? vowelIndexes : stressed
        return anchors.suffix(maxDepth).reversed().map { index in
            phones[index...].map(basePhone).joined(separator: " ")
        }
    }

    private static func rhymeTailForPhones(_ phones: [String]) -> RhymeTail? {
        let vowelIndexes = phones.indices.filter { vowels.contains(basePhone(phones[$0])) }
        guard !vowelIndexes.isEmpty else { return nil }
        let stressed = vowelIndexes.filter { (stressForPhone(phones[$0]) ?? 0) > 0 }
        guard let vowelIndex = (stressed.isEmpty ? vowelIndexes : stressed).last else { return nil }
        return RhymeTail(
            vowel: basePhone(phones[vowelIndex]),
            coda: phones[(vowelIndex + 1)...].map(basePhone)
        )
    }
}
