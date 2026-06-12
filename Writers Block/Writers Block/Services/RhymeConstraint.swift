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
    static func candidateEndWords(
        targetWord: String,
        rhymeType: RhymeType,
        limit: Int = 12,
        dictionary: PronunciationDictionary = .shared
    ) -> [String] {
        let matches = RhymeIndex.shared.find(word: targetWord, dictionary: dictionary)
        return Array(orderedCandidates(matches, rhymeType: rhymeType, excluding: targetWord).prefix(limit))
    }

    /// 2 = perfect/multi rhyme with the target word, 1 = near rhyme, 0 = miss.
    /// Membership reuses RhymeIndex rather than re-deriving phonology so the
    /// verdict always agrees with what the prompt offered.
    static func rhymeTier(
        line: String,
        targetWord: String,
        dictionary: PronunciationDictionary = .shared
    ) -> Int {
        let matches = RhymeIndex.shared.find(word: targetWord, dictionary: dictionary)
        let endWord = lineEndWord(line)
        guard !endWord.isEmpty else { return 0 }
        if matches.perfect.contains(endWord) || matches.multi.contains(endWord) { return 2 }
        if matches.near.contains(endWord) { return 1 }
        return 0
    }

    /// Dedupe, then prefer verified rhymes (tier desc, syllable distance to
    /// the target line asc, arrival order asc), topping up with non-rhyming
    /// lines in arrival order. Never returns empty for non-empty input — a
    /// weak suggestion beats no suggestion.
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

    /// Selection order favors tighter rhymes: perfect-type requests never
    /// offer near rhymes, looser types accept them after perfect and multi.
    static func orderedCandidates(
        _ matches: RhymeMatches,
        rhymeType: RhymeType,
        excluding targetWord: String
    ) -> [String] {
        let ordered: [String]
        switch rhymeType {
        case .perfect:
            ordered = matches.perfect + matches.multi
        case .near, .slant:
            ordered = matches.perfect + matches.multi + matches.near
        }
        let exclude = ProsodyAnalyzer.normalizeWord(targetWord)
        var seen = Set<String>()
        return ordered.filter { $0 != exclude && seen.insert($0).inserted }
    }
}

/// Per-request rhyme verifier. Caches the RhymeIndex lookup once so tier
/// checks on streamed lines are set-membership tests, not index queries.
nonisolated struct RhymeLineFilter: Sendable {
    private let targetSyllables: Int
    private let perfectOrMulti: Set<String>
    private let near: Set<String>

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
        self.perfectOrMulti = Set(matches.perfect).union(matches.multi)
        self.near = Set(matches.near)
    }

    func tier(of line: String) -> Int {
        let endWord = RhymeConstraint.lineEndWord(line)
        guard !endWord.isEmpty else { return 0 }
        if perfectOrMulti.contains(endWord) { return 2 }
        if near.contains(endWord) { return 1 }
        return 0
    }

    /// The filterAndRank ordering, reusing this filter's cached rhyme sets.
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
        var result = rhyming.prefix(want).map(\.line)
        // Never starve the user: pad with unverified lines in arrival order.
        if result.count < want {
            for item in scored where item.tier == 0 {
                result.append(item.line)
                if result.count == want { break }
            }
        }
        return result
    }
}
