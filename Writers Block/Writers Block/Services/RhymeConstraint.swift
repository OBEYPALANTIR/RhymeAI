import Foundation

/// Rhyme-word-first constrained generation helpers.
///
/// LLMs see BPE tokens, not phonetics, so they rhyme unreliably. Instead of
/// trusting the model, the pronunciation dictionary picks the allowed ending
/// words up front, the prompt over-generates 2x, and these helpers verify,
/// rank, and filter the results with the same deterministic analyzer the
/// editor already uses. Must stay behaviorally in lockstep with the Android
/// implementation.
nonisolated enum RhymeConstraint {

    /// Last word of a line with punctuation/quotes stripped, lowercased.
    /// Skips trailing tokens that are pure punctuation (em-dashes, ellipses).
    static func lineEndWord(_ line: String) -> String {
        for token in line.split(whereSeparator: \.isWhitespace).reversed() {
            let normalized = ProsodyAnalyzer.normalizeWord(String(token))
            if !normalized.isEmpty {
                return normalized
            }
        }
        return ""
    }

    /// Allowed ending words for a target word, best rhymes first. Empty when
    /// the dictionary doesn't know the word — callers must then skip
    /// constraining entirely so the model isn't steered by bad data.
    ///
    /// Each requested relation has its own exclusive pool. Words within that
    /// pool are ranked by English frequency so common words surface first.
    static func candidateEndWords(
        targetWord: String,
        rhymeType: RhymeType,
        limit: Int = 12,
        dictionary: PronunciationDictionary = .shared
    ) -> [String] {
        let matches = RhymeIndex.shared.find(word: targetWord, dictionary: dictionary)
        return Array(orderedCandidates(matches, rhymeType: rhymeType, excluding: targetWord).prefix(limit))
    }

    /// 3 = slant rhyme, 2 = perfect/multi rhyme, 1 = near rhyme, 0 = miss.
    /// The actual ending is classified from its phonemes, independent of the
    /// candidate-list caps used to keep prompts small.
    static func rhymeTier(
        line: String,
        targetWord: String,
        dictionary: PronunciationDictionary = .shared
    ) -> Int {
        let endWord = lineEndWord(line)
        guard !endWord.isEmpty else { return 0 }
        switch ProsodyAnalyzer.rhymeRelation(
            candidateWord: endWord,
            targetWord: targetWord,
            dictionary: dictionary
        ) {
        case .perfect: return 2
        case .near: return 1
        case .slant: return 3
        case nil: return 0
        }
    }

    /// Dedupe, admit only the requested verified relation, then rank by
    /// syllable distance to the target line and arrival order.
    static func filterAndRank(
        lines: [String],
        targetLine: String,
        rhymeType: RhymeType,
        want: Int,
        dictionary: PronunciationDictionary = .shared
    ) -> [String] {
        guard want > 0, !lines.isEmpty else { return [] }
        guard let filter = RhymeLineFilter(targetLine: targetLine, rhymeType: rhymeType, dictionary: dictionary) else {
            // Unknown target word: the prompt was never constrained, so
            // there is nothing to verify against — keep arrival order.
            return Array(dedupe(lines).prefix(want))
        }
        return filter.rank(lines, want: want)
    }

    /// Same normalization the suggestion stream uses for dedupe keys.
    static func dedupeKey(_ line: String) -> String {
        line.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    static func dedupe(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { line in
            let key = dedupeKey(line)
            return key.isEmpty || seen.insert(key).inserted
        }
    }

    /// Each mode returns only its named phonetic relation. Perfect retains the
    /// existing exact and multisyllabic pools; Near and Slant remain exclusive.
    static func orderedCandidates(
        _ matches: RhymeMatches,
        rhymeType: RhymeType,
        excluding targetWord: String,
        wordFrequency: WordFrequency = .shared
    ) -> [String] {
        let ordered: [String]
        switch rhymeType {
        case .perfect:
            ordered = matches.perfect + matches.multi
        case .near:
            ordered = matches.near
        case .slant:
            ordered = matches.slant
        }
        let exclude = ProsodyAnalyzer.normalizeWord(targetWord)
        var seen = Set<String>()
        return ordered.filter { $0 != exclude && seen.insert($0).inserted }
    }
}

/// Per-request rhyme verifier.
nonisolated struct RhymeLineFilter: Sendable {
    private let targetSyllables: Int
    private let targetWord: String
    private let rhymeType: RhymeType
    private let dictionary: PronunciationDictionary

    /// Fails exactly when `rhymeConstraintBlock` would skip constraining the
    /// prompt, so an unconstrained generation is never filtered.
    init?(
        targetLine: String?,
        rhymeType: RhymeType,
        dictionary: PronunciationDictionary = .shared
    ) {
        guard let targetLine,
              !targetLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let targetWord = RhymeConstraint.lineEndWord(targetLine)
        guard !targetWord.isEmpty else { return nil }
        let matches = RhymeIndex.shared.find(word: targetWord, dictionary: dictionary)
        guard !RhymeConstraint.orderedCandidates(matches, rhymeType: rhymeType, excluding: targetWord).isEmpty else {
            return nil
        }
        self.targetSyllables = SyllableCounter.countText(targetLine)
        self.targetWord = targetWord
        self.rhymeType = rhymeType
        self.dictionary = dictionary
    }

    func tier(of line: String) -> Int {
        let tier = RhymeConstraint.rhymeTier(
            line: line,
            targetWord: targetWord,
            dictionary: dictionary
        )
        switch rhymeType {
        case .perfect:
            return tier == 2 ? tier : 0
        case .near:
            return tier == 1 ? tier : 0
        case .slant:
            return tier == 3 ? tier : 0
        }
    }

    /// The filterAndRank ordering for the requested relation.
    func rank(_ lines: [String], want: Int) -> [String] {
        guard want > 0, !lines.isEmpty else { return [] }

        var seen = Set<String>()
        var scored: [(line: String, tier: Int, syllableDistance: Int, index: Int)] = []
        for (index, line) in lines.enumerated() {
            let key = RhymeConstraint.dedupeKey(line)
            if !key.isEmpty, !seen.insert(key).inserted { continue }
            scored.append((
                line: line,
                tier: tier(of: line),
                syllableDistance: abs(SyllableCounter.countText(line) - targetSyllables),
                index: index
            ))
        }

        let rhyming = scored.filter { $0.tier > 0 }.sorted { a, b in
            if a.tier != b.tier { return a.tier > b.tier }
            if a.syllableDistance != b.syllableDistance { return a.syllableDistance < b.syllableDistance }
            return a.index < b.index
        }
        return rhyming.prefix(want).map(\.line)
    }
}
