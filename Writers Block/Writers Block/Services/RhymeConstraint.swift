import Foundation

/// Rhyme-word-first constrained generation helpers.
///
/// LLMs see BPE tokens, not phonetics, so they rhyme unreliably. Instead of
/// trusting the model, the pronunciation dictionary picks the allowed ending
/// words up front, the prompt over-generates 2x, and these helpers verify
/// and filter the results with the same deterministic analyzer the
/// editor already uses. Must stay behaviorally in lockstep with the Android
/// implementation.
nonisolated enum RhymeConstraint {

    /// Last lexical word of a line, lowercased, as Android `wordPattern` finds
    /// it, so punctuation attached to the word ("day—night", "line—") is not
    /// part of it.
    static func lineEndWord(_ line: String) -> String {
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let last = LyricRegex.word.matches(in: line, range: range).last else { return "" }
        return ProsodyAnalyzer.normalizeWord(nsLine.substring(with: last.range))
    }

    /// Allowed ending words for a target word, best rhymes first. Empty when
    /// the dictionary doesn't know the word — callers must then skip
    /// constraining entirely so the model isn't steered by bad data.
    ///
    /// Each requested relation has its own exclusive pool. Words within that
    /// pool are ranked by English frequency so common words surface first.
    /// `complexity` shapes the list the prompt sends (see `levelEndWords`);
    /// `.moderate` is the plain frequency order.
    static func candidateEndWords(
        targetWord: String,
        rhymeType: RhymeType,
        limit: Int = 12,
        dictionary: PronunciationDictionary = .shared,
        complexity: RhymeComplexity = .moderate
    ) -> [String] {
        let matches = RhymeIndex.shared.find(word: targetWord, dictionary: dictionary)
        let ordered = orderedCandidates(matches, rhymeType: rhymeType, excluding: targetWord)
        return levelEndWords(ordered, complexity: complexity, limit: limit, dictionary: dictionary)
    }

    /// A Simple list keeps only one-syllable words unless fewer than this many
    /// exist, in which case the remaining words follow in their original order
    /// (some anchors, "arrival" for one, have no one-syllable rhyme at all).
    static let simpleMinMonosyllables = 6

    /// The complexity level's view of a relation's ranked candidates, cut to
    /// `limit`. `.complex` puts words of two or more syllables first, then the
    /// rest, each group keeping its frequency order (a stable partition).
    /// `.simple` keeps one-syllable words only, unless fewer than
    /// `simpleMinMonosyllables` exist, when the remaining words follow in
    /// their original order. `.moderate` is unchanged. Syllables come from
    /// `ProsodyAnalyzer.analyzeWord` with the same dictionary, so Android
    /// (`RhymeConstraint.levelEndWords`) and the eval's
    /// `scoring.level_end_words` build identical lists.
    static func levelEndWords(
        _ ordered: [String],
        complexity: RhymeComplexity,
        limit: Int,
        dictionary: PronunciationDictionary = .shared
    ) -> [String] {
        guard complexity != .moderate else { return Array(ordered.prefix(limit)) }
        let syllables = Dictionary(
            ordered.map { ($0, ProsodyAnalyzer.analyzeWord($0, dictionary: dictionary).syllableCount) },
            uniquingKeysWith: { first, _ in first }
        )
        switch complexity {
        case .complex:
            let multi = ordered.filter { syllables[$0, default: 0] >= 2 }
            let rest = ordered.filter { syllables[$0, default: 0] < 2 }
            return Array((multi + rest).prefix(limit))
        case .simple:
            let mono = ordered.filter { syllables[$0, default: 0] == 1 }
            if mono.count >= simpleMinMonosyllables { return Array(mono.prefix(limit)) }
            let rest = ordered.filter { syllables[$0, default: 0] != 1 }
            return Array((mono + rest).prefix(limit))
        case .moderate:
            return Array(ordered.prefix(limit))
        }
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
}
